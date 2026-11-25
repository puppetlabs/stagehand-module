#!/bin/sh
# patchbot — external fact (facts.d, pluginsynced from the stagehand module;
# formerly named pcm_patch, from before the pcm -> stagehand rename).
#
# Patch posture the console reads (Patching page, Action Center, and — when
# the Labs `computed_findings` flag is on — the correlation engine). The
# console's PQL queries (backend/internal/httpapi/patching.go, dashboard.go,
# hipogamo.go) already query this fact by its `patchbot` name.
#
#   {"patchbot": {
#      "schema_version": 2,
#      "available": 12, "security": 3, "reboot_required": false,
#      "reboot_status": "not_required", "reboot_status_reason": "marker_absent",
#      "last_checked": "<ISO8601 UTC>", "manager": "apt",
#      "repos": ["noble","noble-updates","noble-security"],
#      "packages": [
#        {"name":"openssl","arch":"amd64","current":"3.0.2-0ubuntu1.15",
#         "available":"3.0.2-0ubuntu1.18","repo":"noble-security","security":true}
#      ],
#      "package_count": 12, "truncated": false
#   }}
#
# Schema version 2 (Phase 72.3, published as docs/schemas/patchbot-fact-v2.schema.json). `reboot_status` is a three-state answer:
# required, not_required, or unknown. Unknown means this node cannot tell (the tool that reports it is missing or failed, or no
# supported package manager is present); it is never reported as not_required. `reboot_required` is kept for readers of version 1
# and is true only when reboot_status is required. `reboot_status_reason` is a fixed code, never raw command output. A fact without
# schema_version is version 1.
#
# `available` / `security` / `reboot_required` / `last_checked` are unchanged in meaning from the counts-only version, so the
# Patching page keeps working untouched. The reboot decision itself lives in the shared block below, which is byte-identical to
# the one in tasks/patch.sh (a Go test keeps the two the same).
#
# `packages` and `repos` are what make fix state computable. Given an
# advisory that says "fixed in 3.0.7-28", the console can answer three
# different questions per node, and only with BOTH fields:
#
#   fixable_now  — an update at or above the fixed version is available from
#                  a repo this node actually has configured
#   repo_gap     — the vendor published a fix, but no configured repo carries
#                  it. A stale mirror wearing a CVE costume; no other tool on
#                  the market can tell you this, because none of them know
#                  what repos your node has.
#   no_fix       — nothing published. Track it, don't nag about it.
#
# Structured JSON output requires Facter 4 (Puppet 8 — i.e. Puppet Core; the
# only stack we target, see docs: NO OpenVox).
#
# Cost note: this fact is per-node state in PuppetDB, so the package list is
# capped (PCM_PATCH_MAX_PACKAGES, default 500) and reports `truncated` when it
# bites. The counts are always exact — only the detail array is capped.
#
# Renamed from the legacy `patches` fact at the pcm cutover (2026-07-21).
# Deploy: pcm/facts.d via pluginsync once pcm is in the environment
# modulepath, or drop into /etc/puppetlabs/facter/facts.d/ (chmod 755).
set -u

LIMIT=${PCM_PATCH_MAX_PACKAGES:-500}

AVAILABLE=0
SECURITY=0
# REBOOT_STATUS and REBOOT_REASON come from detect_reboot_status (the shared block above) on every branch; the boolean is derived
# from the status in one place, further down. The defaults are the cannot-tell answer, so a path that forgot to ask never says "no".
REBOOT_STATUS=unknown
REBOOT_REASON=no_package_manager
MANAGER=""
PACKAGES=""
REPOS=""
TOTAL=0
# status: ok = the check ran and the numbers are real (zero included); check_failed = it could not run, so the numbers say
# nothing about the node. check_error names why, from a fixed set, never raw command output. Additive: the console's decoder
# reads a fixed set of keys (available, security, reboot_required, last_checked) and ignores the rest.
STATUS=ok
CHECK_ERROR=""

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

# ---------------------------------------------------------------- apt -----
if command -v apt-get >/dev/null 2>&1; then
  MANAGER="apt"

  # Simulated dist-upgrade against the package cache only (no network). The
  # pcm patch task and the pcm::patching refresh timer keep the cache fresh.
  #
  #   Inst sed [4.9-2build1] (4.9-2ubuntu0.24.04.1 Ubuntu:24.04/noble-updates,
  #                           Ubuntu:24.04/noble-security [amd64])
  #
  # A package pulled in fresh as a dependency has no [current] bracket, so the
  # third field is parsed defensively rather than positionally.
  UPGR=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)

  if [ -n "$UPGR" ]; then
    TOTAL=$(printf '%s\n' "$UPGR" | wc -l | tr -d ' ')
    AVAILABLE=$TOTAL
    SECURITY=$(printf '%s\n' "$UPGR" | grep -c -- '-security' || true)
    PACKAGES=$(printf '%s\n' "$UPGR" | awk -v lim="$LIMIT" '
      function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
      NR > lim { exit }
      {
        name = $2
        cur  = ""
        if ($3 ~ /^\[/) { cur = $3; gsub(/[][]/, "", cur) }

        p = index($0, "(")
        rest = (p ? substr($0, p + 1) : "")
        split(rest, r, " ")
        avail = r[1]

        # Origins look like "Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security".
        # Take the suite of the first one as the repo; the whole list decides
        # the security flag.
        repo = ""
        if (match(rest, /\/[A-Za-z0-9._-]+/)) {
          repo = substr(rest, RSTART + 1, RLENGTH - 1)
        }
        sec = (rest ~ /-security/) ? "true" : "false"

        arch = ""
        if (match(rest, /\[[A-Za-z0-9_-]+\][)]?[ ]*$/)) {
          arch = substr(rest, RSTART + 1, RLENGTH - 1)
          gsub(/[])] */, "", arch)
        }

        printf "%s{\"name\":\"%s\",\"arch\":\"%s\",\"current\":\"%s\",\"available\":\"%s\",\"repo\":\"%s\",\"security\":%s}",
               (NR > 1 ? "," : ""), esc(name), esc(arch), esc(cur), esc(avail), esc(repo), sec
      }')
  fi

  # Configured suites, from the resolved policy rather than sources.list, so
  # pinning and deb822 sources are both accounted for.
  REPOS=$(apt-cache policy 2>/dev/null \
    | grep -o 'a=[A-Za-z0-9._-]*' | cut -d= -f2 \
    | grep -v '^now$' | sort -u \
    | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')

  # apt: the reboot-required marker, read through the shared block. A node with no marker and nothing installed that would ever
  # write one reports unknown rather than "no".
  detect_reboot_status apt

# ---------------------------------------------------------- dnf / yum -----
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then MANAGER="dnf"; else MANAGER="yum"; fi

  # Capture the exit codes the old pipelines discarded: `check-update` exits 0 with nothing pending, 100 with updates pending,
  # and anything else when it could not run (measured on AlmaLinux 8.10: 1 when repo metadata is unreachable). Without this a
  # failed check printed exactly what a fully patched host prints.
  #
  # Only dnf's exit codes are VERIFIED, so only dnf can report a failure. Real yum (EL7) has no host or fixture here (on the lab,
  # yum is dnf under another name and this script takes its dnf branch), and a wrong guess would mark a whole EL7 fleet
  # check_failed. yum keeps its old behaviour for status (none claimed) but gets the count and exact-name fixes below, which are
  # plain string handling.
  CHECK_OUT=$($MANAGER -q check-update 2>/dev/null)
  CHECK_RC=$?
  if [ "$MANAGER" = dnf ]; then
    case "$CHECK_RC" in
      0|100) ;;
      *) STATUS=check_failed; CHECK_ERROR=metadata_unavailable ;;
    esac
  fi
  LIST=$(printf '%s\n' "$CHECK_OUT" \
         | awk 'NF>=3 && $1 !~ /^Obsoleting/ && $1 !~ /^Last/ && $1 ~ /\./ {print}' || true)

  # Security advisories name their packages as full NEVRA. If this lookup fails the update list is real but every security flag
  # would silently be false, so on dnf a failure here fails the whole check.
  SEC_OUT=$($MANAGER -q updateinfo list security --available 2>/dev/null)
  SEC_RC=$?
  if [ "$MANAGER" = dnf ] && [ "$SEC_RC" -ne 0 ] && [ "$STATUS" = ok ]; then
    STATUS=check_failed; CHECK_ERROR=package_manager_error
  fi
  SECLIST=$(printf '%s\n' "$SEC_OUT" | awk 'NF>=3 {print $NF}' || true)

  # One definition of "this pending package has a security advisory", shared by the per-package flag and the count so the two
  # cannot disagree. An advisory row is a NEVRA: name-[epoch:]version-release.arch. Strip the last two hyphen fields and the arch
  # to get the exact name, then compare whole names. (Matching on the prefix "name-" let curl be flagged by curl-minimal.)
  SEC_AWK='
    function nevra_name(s,   n, parts, i) {
      sub(/\.[^.-]+$/, "", s)               # drop .arch
      n = split(s, parts, "-")
      if (n < 3) return s
      s = parts[1]; for (i = 2; i <= n - 2; i++) s = s "-" parts[i]
      return s
    }
    function load_security(sec,   n, s, i) {
      n = split(sec, s, "\n")
      for (i = 1; i <= n; i++) if (s[i] != "") secname[nevra_name(s[i])] = 1
    }
    function pkg_name(nv,   idx, i) {       # rsplit on the last dot: package names contain dots, arches do not
      idx = 0
      for (i = length(nv); i > 0; i--) if (substr(nv, i, 1) == ".") { idx = i; break }
      return idx ? substr(nv, 1, idx - 1) : nv
    }'

  if [ -n "$LIST" ] && [ "$STATUS" = ok ]; then
    TOTAL=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    AVAILABLE=$TOTAL
    PACKAGES=$(printf '%s\n' "$LIST" | awk -v lim="$LIMIT" -v sec="$SECLIST" "$SEC_AWK"'
      function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
      BEGIN { load_security(sec) }
      NR > lim { exit }
      {
        nv = $1                       # name.arch
        arch = ""
        idx = 0
        # rsplit on the last dot: package names contain dots, arches do not.
        for (i = length(nv); i > 0; i--) if (substr(nv, i, 1) == ".") { idx = i; break }
        if (idx) { arch = substr(nv, idx + 1); name = substr(nv, 1, idx - 1) } else { name = nv }

        avail = $2
        repo  = $3
        isec = (name in secname) ? "true" : "false"

        printf "%s{\"name\":\"%s\",\"arch\":\"%s\",\"current\":\"\",\"available\":\"%s\",\"repo\":\"%s\",\"security\":%s}",
               (NR > 1 ? "," : ""), esc(name), esc(arch), esc(avail), esc(repo), isec
      }')
    # Counted over the WHOLE list, not the capped loop above: the header promises the counts stay exact when the detail array is
    # capped. Distinct pending packages with an advisory, never advisory rows (one package can sit under several).
    SECURITY=$(printf '%s\n' "$LIST" | awk -v sec="$SECLIST" "$SEC_AWK"'
      BEGIN { load_security(sec) }
      { if (pkg_name($1) in secname) n++ }
      END { print n + 0 }')
  fi

  REPOS=$($MANAGER -q repolist --enabled 2>/dev/null \
    | awk 'NR>1 && NF>=1 && $1 !~ /^repo[ -]?id/ {print $1}' \
    | sort -u | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')

  # The reboot answer comes from the shared block. On dnf the probe is the dnf plugin (`dnf needs-restarting`), which ships with
  # dnf; the standalone `needs-restarting` binary needs the separate dnf-utils package, and a host without it used to skip this
  # check and report reboot_required false. A host without the plugin (dnf4 exits 1 with no output) or without the standalone tool
  # on yum reports unknown, never "no" and never "required". needs-restarting does not depend on repository metadata, so the
  # answer is valid even when the update check above failed.
  detect_reboot_status "$MANAGER"

# ----------------------------------------------- no supported manager -----
else
  # No apt, dnf or yum on PATH: this node cannot tell, and must not look like a clean one.
  detect_reboot_status ""
fi

TRUNCATED=false
[ "$TOTAL" -gt "$LIMIT" ] && TRUNCATED=true

# The one place the boolean is derived: true only when the status is required (unknown and not_required are both false).
REBOOT=false
[ "$REBOOT_STATUS" = required ] && REBOOT=true
# Only a non-empty reason is written; the key is absent, not empty, when there is none.
REASON_FIELD=""
[ -n "$REBOOT_REASON" ] && REASON_FIELD=", \"reboot_status_reason\": \"$REBOOT_REASON\""

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A check that did not run knows nothing about the node's updates: report no packages and zero counts, never a partial list. The
# reboot answer is the exception. needs-restarting does not depend on repository metadata (measured: with every repo disabled it
# still exits 1 when a reboot is pending), so it is reported truthfully even when the update check failed.
if [ "$STATUS" != ok ]; then
  printf '{"patchbot": {"schema_version": 2, "status": "%s", "check_error": "%s", "available": 0, "security": 0, "reboot_required": %s, "reboot_status": "%s"%s, "last_checked": "%s", "manager": "%s", "repos": [], "packages": [], "package_count": 0, "truncated": false}}\n' \
    "$STATUS" "$CHECK_ERROR" "$REBOOT" "$REBOOT_STATUS" "$REASON_FIELD" "$NOW" "$MANAGER"
  exit 0
fi

# status is only claimed where this script checks for failure with VERIFIED exit codes: the dnf branch. The apt branch captures no
# exit codes yet and real yum's are unverified, so their output stays as before rather than asserting a status never measured.
STATUS_FIELD=""
case "$MANAGER" in dnf) STATUS_FIELD='"status": "ok", ' ;; esac

printf '{"patchbot": {"schema_version": 2, %s"available": %s, "security": %s, "reboot_required": %s, "reboot_status": "%s"%s, "last_checked": "%s", "manager": "%s", "repos": [%s], "packages": [%s], "package_count": %s, "truncated": %s}}\n' \
  "$STATUS_FIELD" "${AVAILABLE:-0}" "${SECURITY:-0}" "$REBOOT" "$REBOOT_STATUS" "$REASON_FIELD" "$NOW" "$MANAGER" \
  "$REPOS" "$PACKAGES" "${TOTAL:-0}" "$TRUNCATED"
