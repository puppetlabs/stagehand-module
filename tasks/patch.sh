#!/bin/sh
# stagehand::patch — apply OS package updates (all or security-only) and reboot
# according to the reboot policy (never, if-needed or always). Posture is
# reported back through the patchbot fact; this task's own output also carries
# the policy, the node's reboot status and whether a reboot was scheduled.
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

APPLIED="unknown"
MANAGER=""

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  MANAGER="apt"
  apt-get -qq update >/dev/null 2>&1 || die "apt-get update failed"
  if [ -n "$PATCH_IDS" ]; then
    # shellcheck disable=SC2086
    # --only-upgrade: upgrade packages that are already installed, never
    # install new ones (matches dnf upgrade / yum update). -- ends option
    # parsing so no id can be read as a flag.
    apt-get -y install --only-upgrade -- $PATCH_IDS >/dev/null 2>&1 || die "apt install of selected patch_ids failed"
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
    # shellcheck disable=SC2086
    dnf -y upgrade -- $PATCH_IDS >/dev/null 2>&1 || die "dnf upgrade of selected patch_ids failed"
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
    # shellcheck disable=SC2086
    yum -y update -- $PATCH_IDS >/dev/null 2>&1 || die "yum update of selected patch_ids failed"
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

printf '{"status": "patched", "applied": "%s", "reboot_policy": "%s", "reboot_status": "%s", "reboot_status_reason": "%s", "reboot_required": %s, "rebooting": %s}\n' \
  "$APPLIED" "$POLICY" "$REBOOT_STATUS" "$REBOOT_REASON" "$REBOOT_REQUIRED" "$DO_REBOOT"

if [ "$DO_REBOOT" = "true" ]; then
  # Give Bolt time to collect the result before the link drops.
  schedule_reboot
fi
exit 0
