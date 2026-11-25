#!/bin/sh
# stagehand::patch — apply OS package updates (all or security-only) and reboot
# according to the reboot policy (never, if-needed or always). Posture is
# reported back through the patchbot fact; this task's own output also carries
# the policy, the node's reboot status and whether a reboot was scheduled. When
# patch_ids is given the output also carries the per-package result contract
# (result_version 1, docs/design/patch-task-result-schema.md, D-16).
set -u

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SECURITY_ONLY="${PT_security_only:-false}"
PATCH_IDS_RAW="${PT_patch_ids:-}"

# Reboot policy. never: do not reboot. if-needed: reboot only when the node
# reports a reboot is required (when it cannot tell, do not reboot). always:
# reboot every patched node. The legacy Boolean is still accepted (true means
# if-needed, false means never). Anything else dies before any package-manager
# call. Bolt's typed parameter refuses unknown values first; this is the
# backstop for a caller that is not Bolt.
case "${PT_reboot:-never}" in
  true | if-needed) POLICY="if-needed" ;;
  false | never | '') POLICY="never" ;;
  always) POLICY="always" ;;
  *) die "reboot must be never, if-needed or always (or the legacy true or false)" ;;
esac

# patch_ids (JSON array of ids from the patchbot fact's packages[]) takes
# priority over security_only when both are set — installing an explicit
# list is inherently more specific than "security-only". Bolt's
# input_method=environment JSON-encodes array params into the env var. The
# array is split here with POSIX tools, not jq: stock RHEL and Debian/Ubuntu
# images do not carry jq, and a campaign always sends patch_ids. Safety does
# not rest on the split: every element is checked against the identifier
# allowlist below before anything reaches a package manager.
PATCH_IDS=""
if [ -n "$PATCH_IDS_RAW" ] && [ "$PATCH_IDS_RAW" != "null" ] && [ "$PATCH_IDS_RAW" != "[]" ]; then
  _ids_trimmed=$(printf '%s' "$PATCH_IDS_RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$_ids_trimmed" in
    \[*\]) : ;;
    *) die "patch_ids must be a JSON array of strings" ;;
  esac
  # Strip the brackets and double quotes, split on commas, trim each element,
  # drop empties.
  PATCH_IDS=$(printf '%s' "$_ids_trimmed" \
    | sed -e 's/^\[//' -e 's/\]$//' -e 's/"//g' \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$')
  [ -n "$PATCH_IDS" ] || die "patch_ids was provided but parsed to an empty list"

  # Every id is used below via unquoted, word-split expansion (apt-get -y
  # install --only-upgrade -- $PATCH_IDS) so it becomes one argv element per package-manager
  # invocation running as root. Validate BEFORE that happens, or this is an
  # argument-injection hole: an id of "--allow-downgrades" (or any Debian/
  # RPM package manager flag) is read as a flag, not a package name, and an
  # id containing embedded whitespace (e.g. "foo --reinstall") word-splits
  # into two argv entries and achieves the same thing even without a
  # leading "-". patch.json's Pattern-typed parameter rejects this too, but
  # this task must not trust that Bolt is always the caller.
  #
  # The class also refuses an id that ends in '-'. apt reads a trailing '-' on
  # a package argument as "remove this package" (apt-get install foo- removes
  # foo), so openssh-server- would remove openssh-server. A trailing '+' stays
  # legal (g++, libstdc++6). The same class is in patch.json and in the
  # console's patchPackageNameRe; a Go test pins the three together.
  if printf '%s\n' "$PATCH_IDS" | grep -qvE '^[A-Za-z0-9]([A-Za-z0-9._:+-]*[A-Za-z0-9._:+])?$'; then
    die "patch_ids contains an invalid identifier (must match [A-Za-z0-9]([A-Za-z0-9._:+-]*[A-Za-z0-9._:+])?, so it cannot end in '-')"
  fi
fi

# BEGIN reboot_status
# Reboot-pending detection shared by tasks/patch.sh and facts.d/patchbot.sh. A
# test keeps the two copies byte-identical: change both or neither.
#
# detect_reboot_status MANAGER   (MANAGER is apt, dnf, yum or anything else)
# sets REBOOT_STATUS and REBOOT_REASON:
#   REBOOT_STATUS  required | not_required | unknown   (unknown is never "no")
#   REBOOT_REASON  marker_present | marker_absent | no_marker_writer |
#                  needs_restarting | plugin_missing | needs_restarting_failed |
#                  no_package_manager
# PATCHBOT_REBOOT_MARKER and PATCHBOT_MARKER_WRITER override the apt paths and
# exist for tests only.
detect_reboot_status() {
  REBOOT_STATUS="unknown"
  REBOOT_REASON="no_package_manager"
  case "${1:-}" in
    apt)
      if [ -f "${PATCHBOT_REBOOT_MARKER:-/var/run/reboot-required}" ]; then
        REBOOT_STATUS="required"
        REBOOT_REASON="marker_present"
      elif [ -x "${PATCHBOT_MARKER_WRITER:-/usr/share/update-notifier/notify-reboot-required}" ]; then
        # A writer is installed, so the marker's absence is meaningful.
        REBOOT_STATUS="not_required"
        REBOOT_REASON="marker_absent"
      else
        # Nothing on this node would ever write the marker: cannot tell.
        REBOOT_REASON="no_marker_writer"
      fi
      ;;
    dnf)
      # dnf4 plugin / dnf5: exit 0 = no reboot needed; exit 1 WITH output = a
      # reboot is required; exit 1 with NO output is dnf4 saying "No such
      # command" because the plugin is not installed; any other exit (dnf5
      # reports an unknown argument as 2) means the probe itself failed. The
      # text of the output is never parsed: it is locale dependent.
      _nr_out=$(dnf -q needs-restarting -r 2>/dev/null)
      _nr_rc=$?
      case "$_nr_rc" in
        0)
          REBOOT_STATUS="not_required"
          REBOOT_REASON="needs_restarting"
          ;;
        1)
          if [ -n "$_nr_out" ]; then
            REBOOT_STATUS="required"
            REBOOT_REASON="needs_restarting"
          else
            REBOOT_REASON="plugin_missing"
          fi
          ;;
        *) REBOOT_REASON="needs_restarting_failed" ;;
      esac
      ;;
    yum)
      # yum hosts carry no dnf plugin; the standalone needs-restarting (from
      # yum-utils) answers with exit 0 (no) or 1 (yes). Absent: cannot tell.
      if command -v needs-restarting >/dev/null 2>&1; then
        needs-restarting -r >/dev/null 2>&1
        _nr_rc=$?
        case "$_nr_rc" in
          0)
            REBOOT_STATUS="not_required"
            REBOOT_REASON="needs_restarting"
            ;;
          1)
            REBOOT_STATUS="required"
            REBOOT_REASON="needs_restarting"
            ;;
          *) REBOOT_REASON="needs_restarting_failed" ;;
        esac
      else
        REBOOT_REASON="plugin_missing"
      fi
      ;;
    *) : ;;
  esac
}
# END reboot_status

# schedule_reboot: restart the node a few seconds after this task has returned
# its result. Detached so the restart survives the end of the Bolt session.
schedule_reboot() {
  _reboot_cmd='sleep 3; systemctl reboot 2>/dev/null || shutdown -r now 2>/dev/null || reboot'
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$_reboot_cmd" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup sh -c "$_reboot_cmd" </dev/null >/dev/null 2>&1 &
  else
    sh -c "$_reboot_cmd" </dev/null >/dev/null 2>&1 &
  fi
}

# Per-package result contract (77.1-02, D-16). Only when patch_ids is given: ask
# the package database what is installed before the package-manager call, hand
# the manager only the ids that are installed (one unknown name makes apt exit
# 100 for the whole node), ask again afterwards, and report one entry per
# requested package. The manager's own output stays in /dev/null and stdout stays
# exactly one JSON line; reason is a fixed code, never command output.
PATCH_RESULT_MAX_PACKAGES=500
PM_FAILED=0
RESULT_V1=0
INSTALLED_IDS=""
RESDIR=""
PKG_JSON=""
PKG_COUNT=0
PKG_TRUNCATED="false"
NL='
'

# json_str TEXT: TEXT as the inside of a JSON string. Backslash and double quote
# are escaped and every control byte is dropped, so a node's package database
# cannot break out of the line.
json_str() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

# capture_versions MANAGER ID: one name|arch|version line per installed instance
# of ID (several on a multi-arch or install-only package), nothing when ID is not
# installed. apt: dpkg-query, keeping only status ii (an rc package, removed with
# its configuration left behind, is not installed). dnf and yum: rpm -q, with the
# epoch printed only when non-zero. Never fails the script: a tool that is
# missing or a package that is absent both read as "not installed".
capture_versions() {
  case "$1" in
    apt)
      dpkg-query -W -f="\${Package}|\${Architecture}|\${Version}|\${db:Status-Abbrev}\\n" "$2" </dev/null 2>/dev/null \
        | while IFS='|' read -r _cn _ca _cv _cs; do
            case "$_cs" in
              ii*) [ -n "$_cn" ] && [ -n "$_cv" ] && printf '%s|%s|%s\n' "$_cn" "$_ca" "$_cv" ;;
            esac
          done
      ;;
    dnf | yum)
      rpm -q --qf '%{NAME}|%{ARCH}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}\n' "$2" </dev/null 2>/dev/null \
        | while IFS='|' read -r _cn _ca _cv _cx; do
            [ -z "$_cx" ] && [ -n "$_cn" ] && [ -n "$_ca" ] && [ -n "$_cv" ] && printf '%s|%s|%s\n' "$_cn" "$_ca" "$_cv"
          done
      ;;
  esac
  return 0
}

# filter_installed MANAGER: sets INSTALLED_IDS (space separated, each id once, in
# request order) to the ids of PATCH_IDS that are installed, and records the
# before-versions of every id in $RESDIR (ids is the request order, b.N the
# before lines of id number N).
filter_installed() {
  INSTALLED_IDS=""
  _seen="|"
  _idx=0
  : > "$RESDIR/ids"
  while IFS= read -r _fid; do
    [ -n "$_fid" ] || continue
    case "$_seen" in *"|$_fid|"*) continue ;; esac
    _seen="${_seen}${_fid}|"
    _idx=$((_idx + 1))
    printf '%s\n' "$_fid" >> "$RESDIR/ids"
    capture_versions "$1" "$_fid" > "$RESDIR/b.$_idx"
    if [ -s "$RESDIR/b.$_idx" ]; then
      INSTALLED_IDS="${INSTALLED_IDS}${INSTALLED_IDS:+ }${_fid}"
    fi
  done <<EOF_IDS
$PATCH_IDS
EOF_IDS
}

# versions_for LINES NAME ARCH: the versions listed in LINES (name|arch|version
# per line) for that name and arch.
versions_for() {
  while IFS='|' read -r _vn _va _vv; do
    if [ "$_vn" = "$2" ] && [ "$_va" = "$3" ]; then
      printf '%s\n' "$_vv"
    fi
  done <<EOF_VERSIONS
$1
EOF_VERSIONS
}

# add_entry NAME ARCH BEFORE AFTER STATUS [REASON]: count one package entry and,
# up to PATCH_RESULT_MAX_PACKAGES, append it to PKG_JSON. The count keeps going
# past the cap so the line says how many were found.
add_entry() {
  PKG_COUNT=$((PKG_COUNT + 1))
  if [ "$PKG_COUNT" -gt "$PATCH_RESULT_MAX_PACKAGES" ]; then
    PKG_TRUNCATED="true"
    return 0
  fi
  _entry=$(printf '{"name": "%s", "arch": "%s", "before": "%s", "after": "%s", "status": "%s"' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")" "$5")
  if [ -n "${6:-}" ]; then
    _entry="${_entry}, \"reason\": \"$6\""
  fi
  PKG_JSON="${PKG_JSON}${PKG_JSON:+, }${_entry}}"
}

# build_package_results MANAGER: ask again after the package-manager call and
# fill PKG_JSON, PKG_COUNT and PKG_TRUNCATED, one entry per requested id and
# installed architecture. Per name and arch: before is the last version listed
# before; after is the first version listed now that was not listed before (an
# install-only package keeps its old versions), else the last one listed now.
#   updated    a version appeared that was not there before
#   unchanged  nothing new appeared and the manager did not fail
#   failed     package_manager_error: the manager failed and nothing new
#              appeared, or the package can no longer be read from the database
#   skipped    not_installed: never handed to the manager
build_package_results() {
  _idx=0
  while IFS= read -r _rid; do
    _idx=$((_idx + 1))
    if [ ! -s "$RESDIR/b.$_idx" ]; then
      add_entry "$_rid" "" "" "" skipped not_installed
      continue
    fi
    _blines=$(cat "$RESDIR/b.$_idx")
    _alines=$(capture_versions "$1" "$_rid")
    _keys="$NL"
    while IFS='|' read -r _bn _ba _bv; do
      case "$_keys" in *"$NL$_bn|$_ba$NL"*) continue ;; esac
      _keys="${_keys}${_bn}|${_ba}${NL}"
      _bset=$(versions_for "$_blines" "$_bn" "$_ba")
      _aset=$(versions_for "$_alines" "$_bn" "$_ba")
      _before=$(printf '%s\n' "$_bset" | sed -n '$p')
      _after=$(printf '%s\n' "$_aset" | sed -n '$p')
      _new=""
      if [ -n "$_aset" ]; then
        while IFS= read -r _av; do
          case "$NL$_bset$NL" in
            *"$NL$_av$NL"*) : ;;
            *)
              _new="$_av"
              break
              ;;
          esac
        done <<EOF_AFTER
$_aset
EOF_AFTER
      fi
      if [ -z "$_aset" ]; then
        add_entry "$_bn" "$_ba" "$_before" "" failed package_manager_error
      elif [ -n "$_new" ]; then
        add_entry "$_bn" "$_ba" "$_before" "$_new" updated
      elif [ "$PM_FAILED" = "1" ]; then
        add_entry "$_bn" "$_ba" "$_before" "$_after" failed package_manager_error
      else
        add_entry "$_bn" "$_ba" "$_before" "$_after" unchanged
      fi
    done <<EOF_BEFORE
$_blines
EOF_BEFORE
  done < "$RESDIR/ids"
}

APPLIED="unknown"
MANAGER=""

# Work files for the per-package result, removed on every exit path.
if [ -n "$PATCH_IDS" ]; then
  RESDIR=$(mktemp -d 2>/dev/null) || die "could not create a work directory"
  trap '[ -z "$RESDIR" ] || rm -rf "$RESDIR"' EXIT
fi

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  MANAGER="apt"
  apt-get -qq update >/dev/null 2>&1 || die "apt-get update failed"
  if [ -n "$PATCH_IDS" ]; then
    RESULT_V1=1
    filter_installed apt
    # Only ids that are installed reach apt: an unknown name makes apt-get exit
    # 100 for the whole node. A failure is recorded, not fatal, so the result
    # line below can still say what happened (the task then exits 1).
    if [ -n "$INSTALLED_IDS" ]; then
      # shellcheck disable=SC2086
      # --only-upgrade: upgrade packages that are already installed, never
      # install new ones (matches dnf upgrade / yum update). -- ends option
      # parsing so no id can be read as a flag.
      apt-get -y install --only-upgrade -- $INSTALLED_IDS >/dev/null 2>&1 || PM_FAILED=1
    fi
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    if command -v unattended-upgrade >/dev/null 2>&1; then
      unattended-upgrade >/dev/null 2>&1 || die "unattended-upgrade failed"
      APPLIED="security"
    else
      # Approximate security-only: upgrade packages from a *-security suite.
      PKGS=$(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / && /security/i {print $2}')
      if [ -n "$PKGS" ]; then
        # shellcheck disable=SC2086
        apt-get -y install -- $PKGS >/dev/null 2>&1 || die "apt security upgrade failed"
      fi
      APPLIED="security"
    fi
  else
    apt-get -y dist-upgrade >/dev/null 2>&1 || die "apt dist-upgrade failed"
    APPLIED="all"
  fi

elif command -v dnf >/dev/null 2>&1; then
  MANAGER="dnf"
  if [ -n "$PATCH_IDS" ]; then
    RESULT_V1=1
    filter_installed dnf
    # Only installed ids reach dnf: an available-but-not-installed name makes
    # dnf exit 1 ("No packages marked for upgrade"). -- ends option parsing.
    if [ -n "$INSTALLED_IDS" ]; then
      # shellcheck disable=SC2086
      dnf -y upgrade -- $INSTALLED_IDS >/dev/null 2>&1 || PM_FAILED=1
    fi
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    dnf -y --security upgrade >/dev/null 2>&1 || die "dnf security upgrade failed"
    APPLIED="security"
  else
    dnf -y upgrade >/dev/null 2>&1 || die "dnf upgrade failed"
    APPLIED="all"
  fi

elif command -v yum >/dev/null 2>&1; then
  MANAGER="yum"
  if [ -n "$PATCH_IDS" ]; then
    RESULT_V1=1
    filter_installed yum
    if [ -n "$INSTALLED_IDS" ]; then
      # shellcheck disable=SC2086
      yum -y update -- $INSTALLED_IDS >/dev/null 2>&1 || PM_FAILED=1
    fi
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    yum -y --security update >/dev/null 2>&1 || die "yum security update failed"
    APPLIED="security"
  else
    yum -y update >/dev/null 2>&1 || die "yum update failed"
    APPLIED="all"
  fi
else
  die "no supported package manager (apt/dnf/yum) found"
fi

# Reboot decision, after the package manager has run.
detect_reboot_status "$MANAGER"
REBOOT_REQUIRED="false"
if [ "$REBOOT_STATUS" = "required" ]; then
  REBOOT_REQUIRED="true"
fi
DO_REBOOT="false"
case "$POLICY" in
  always) DO_REBOOT="true" ;;
  if-needed)
    # Only a definite "required" reboots. "unknown" never does.
    if [ "$REBOOT_STATUS" = "required" ]; then DO_REBOOT="true"; fi
    ;;
esac

# Refresh the patchbot external fact cache best-effort so PuppetDB/console see
# the new posture promptly (the fact also self-reports on the next agent run).
if [ -x /etc/puppetlabs/facter/facts.d/patchbot.sh ]; then
  /etc/puppetlabs/facter/facts.d/patchbot.sh >/dev/null 2>&1 || true
fi

if [ "$RESULT_V1" = "1" ]; then
  build_package_results "$MANAGER"
  # A failed package-manager call never reboots the node: the line below says
  # what happened and the task exits 1, so Bolt records a failure.
  RESULT_STATUS="patched"
  if [ "$PM_FAILED" = "1" ]; then
    RESULT_STATUS="failed"
    DO_REBOOT="false"
  fi
  printf '{"status": "%s", "applied": "%s", "reboot_policy": "%s", "reboot_status": "%s", "reboot_status_reason": "%s", "reboot_required": %s, "rebooting": %s, "result_version": 1, "packages": [%s], "package_count": %s, "packages_truncated": %s}\n' \
    "$RESULT_STATUS" "$APPLIED" "$POLICY" "$REBOOT_STATUS" "$REBOOT_REASON" "$REBOOT_REQUIRED" "$DO_REBOOT" "$PKG_JSON" "$PKG_COUNT" "$PKG_TRUNCATED"
  if [ "$PM_FAILED" = "1" ]; then
    exit 1
  fi
else
  printf '{"status": "patched", "applied": "%s", "reboot_policy": "%s", "reboot_status": "%s", "reboot_status_reason": "%s", "reboot_required": %s, "rebooting": %s}\n' \
    "$APPLIED" "$POLICY" "$REBOOT_STATUS" "$REBOOT_REASON" "$REBOOT_REQUIRED" "$DO_REBOOT"
fi

if [ "$DO_REBOOT" = "true" ]; then
  # Give Bolt time to collect the result before the link drops.
  schedule_reboot
fi
exit 0
