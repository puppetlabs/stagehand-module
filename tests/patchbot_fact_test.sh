#!/bin/sh
# patchbot external fact (facts.d/patchbot.sh) test harness. Prints TAP: "ok N - name" or "not ok N - name",
# "# " comment lines, and the plan "1..N" as the last line. It keeps running after a failure and exits non-zero if any case failed.
#
# Replays RECORDED `dnf` output from testdata/<case>/ through a PATH-shimmed `dnf`, so the script's real parsing code runs without
# a package manager, a network or root. Follows tasks/patch_test.sh: POSIX sh, mktemp sandbox, PATH shim, content assertions.
#
# Cases:
#   (1) real AlmaLinux 8.10 capture, host A and host B: `security` equals the number of DISTINCT pending packages flagged
#       security in packages[]. (Before: it counted `updateinfo` ROWS, one per advisory and build: 37 reported for 19 packages
#       on host A, 42 for 24 on host B.)
#   (2) a package whose name is a prefix of a security package's name is not flagged by it: pending curl (no advisory) and
#       curl-minimal (security) -> only curl-minimal is security. (Before: `index(k, name "-") == 1` matched "curl-minimal-..."
#       for "curl".) The fixture is CONSTRUCTED; see testdata/prefix-collision/README.
#   (3) a failed `dnf check-update` (exit 1, empty stdout) reports status "check_failed" and no packages. (Before: output
#       identical to a fully patched host.)
#   (4) check-update ok but `updateinfo` fails: status "check_failed", not a real update list with silently false security flags.
#   (5) a host with nothing pending reports status "ok" with zero counts.
#   (6) the existing envelope is unchanged: available, security, reboot_required, last_checked, manager, repos, packages,
#       package_count, truncated all present, with the types the console's decoder reads (evaluatePatchbotPosture).
#
#   (11)-(15) the v2 reboot answer on every Linux branch (dnf, yum, apt, no package manager) by the shared rule: a node that cannot
#       tell reports unknown with a fixed reason, never no. The apt cases replay a recorded `apt-get -s dist-upgrade` and point the
#       two test-only path overrides (PATCHBOT_REBOOT_MARKER, PATCHBOT_MARKER_WRITER) at files this harness creates or omits.
#
# Needs GNU awk, as the target hosts have (the script passes a multi-line value through `awk -v`, which BSD awk on macOS rejects).
# Run it on a Linux host or in a container with gawk. Without gawk it exits 77 (skipped) rather than failing for the wrong reason.
#
# PATCHBOT_GOLDEN_DIR (test-only, read by this harness and never by the fact): when set to an existing directory, the cases named in
# `golden` calls below write their raw fact line there as patchbot-v2-<slug>.json. The v2 fixtures that
# backend/internal/httpapi/patchbot_fact_schema_test.go validates against docs/schemas/patchbot-fact-v2.schema.json are recorded by
# one run of this harness and never written by hand.
#
# Deliberately NOT covered: Windows (patchbot.ps1) and the lab module's separate copy of this script.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
TARGET="${PATCHBOT_SH:-$SCRIPT_DIR/../facts.d/patchbot.sh}"
DATA="$SCRIPT_DIR/testdata/patchbot"

N=0
FAILED=0
ok()   { N=$((N + 1)); printf 'ok %s - %s\n' "$N" "$*"; }
fail() { N=$((N + 1)); FAILED=$((FAILED + 1)); printf 'not ok %s - %s\n' "$N" "$*"; }
info() { printf '# %s\n' "$*"; }
GOLDEN="${PATCHBOT_GOLDEN_DIR:-}"

[ -f "$TARGET" ] || { echo "patchbot.sh not found at $TARGET" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to read the JSON the script prints" >&2; exit 1; }
if ! awk --version 2>&1 | grep -q 'GNU Awk'; then
  echo "# SKIP: GNU awk is required (found: $(awk --version 2>&1 | head -1)); run on a Linux host or container with gawk" >&2
  exit 77
fi

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# run_case NAME [MANAGER [standalone]] -> prints the script's JSON line. A PATH containing only fake package-manager tools plus the
# standard tools, so the script takes the branch MANAGER names:
#   dnf (default)  a fake dnf; yum and apt-get are absent
#   yum            a fake yum, no dnf; `standalone` also installs a fake standalone needs-restarting (yum-utils) answering from the
#                  case's needs-restarting.exit and .out, otherwise the host has none
#   apt            a fake apt-get answering `-s dist-upgrade` from the case's apt-dist-upgrade.txt and a fake apt-cache; the caller
#                  sets PATCHBOT_REBOOT_MARKER and PATCHBOT_MARKER_WRITER (run_apt does)
#   none           no package manager at all
run_case() {
  case_dir="$DATA/$1"
  pm="${2:-dnf}"
  standalone="${3:-}"
  bin="$WORK/bin-$1-$pm${standalone:+-s}"; tools="$WORK/tools-$1-$pm${standalone:+-s}"
  mkdir -p "$bin" "$tools"
  case "$pm" in
    dnf|yum)
  cat > "$bin/$pm" <<EOF
#!/bin/sh
D="$case_dir"
[ "\${1:-}" = "-q" ] && shift
case "\$*" in
  "check-update")
    cat "\$D/check-update.txt"; exit \$(sed -n 's/^exit=//p' "\$D/check-update.exit") ;;
  "updateinfo list security --available")
    cat "\$D/updateinfo-security.txt"
    [ -f "\$D/updateinfo-security.exit" ] && exit \$(sed -n 's/^exit=//p' "\$D/updateinfo-security.exit")
    exit 0 ;;
  "needs-restarting -r")
    [ -f "\$D/needs-restarting.out" ] && cat "\$D/needs-restarting.out"
    exit \$(cat "\$D/needs-restarting.exit") ;;
  "repolist --enabled") printf 'repo id   repo name\nbaseos    BaseOS\nappstream AppStream\n' ;;
  *) echo "fake $pm: unexpected call: $pm \$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$bin/$pm"
  if [ -n "$standalone" ]; then
    cat > "$bin/needs-restarting" <<EOF
#!/bin/sh
D="$case_dir"
[ "\${1:-}" = "-r" ] || { echo "fake needs-restarting: unexpected call: \$*" >&2; exit 99; }
[ -f "\$D/needs-restarting.out" ] && cat "\$D/needs-restarting.out"
exit \$(cat "\$D/needs-restarting.exit")
EOF
    chmod +x "$bin/needs-restarting"
  fi
      ;;
    apt)
  cat > "$bin/apt-get" <<EOF
#!/bin/sh
D="$case_dir"
case "\$*" in
  "-s dist-upgrade") cat "\$D/apt-dist-upgrade.txt" ;;
  *) echo "fake apt-get: unexpected call: apt-get \$*" >&2; exit 99 ;;
esac
EOF
  cat > "$bin/apt-cache" <<'EOF'
#!/bin/sh
case "$*" in
  policy) printf 'Package files:\n 100 /var/lib/dpkg/status\n     release a=now\n 500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages\n     release v=24.04,o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=main,b=amd64\n 500 http://security.ubuntu.com/ubuntu noble-security/main amd64 Packages\n     release v=24.04,o=Ubuntu,a=noble-security,n=noble,l=Ubuntu,c=main,b=amd64\n' ;;
  *) echo "fake apt-cache: unexpected call: apt-cache $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$bin/apt-get" "$bin/apt-cache"
      ;;
    none) : ;;
  esac
  for t in awk grep sed tr wc date printf cat sh sort uniq head cut python3 mktemp; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$tools/$t"
  done
  # Bound every run: a script that loops forever must fail this suite, not hang it (a hung awk once pinned a core on a lab node).
  # Resolve timeout to a full path BEFORE PATH is restricted: `PATH=... $BOUND sh` applies the restricted PATH to the lookup of
  # $BOUND too, so a bare `timeout` is "command not found" (exit 127) and nothing runs.
  TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
  if [ -n "$TIMEOUT_BIN" ]; then BOUND="$TIMEOUT_BIN 60"; else BOUND=""; fi
  PATH="$bin:$tools" $BOUND sh "$TARGET" 2>"$WORK/stderr-$1" | grep '^{'
}

# The apt probes read two files the real node has or lacks; the fact lets a test point them elsewhere. The harness owns three paths:
# a marker that exists, a path that never exists, and an executable standing in for update-notifier's notify-reboot-required.
: > "$WORK/marker-present"
printf '#!/bin/sh\nexit 0\n' > "$WORK/marker-writer"; chmod +x "$WORK/marker-writer"
NOPE="$WORK/does-not-exist"

# run_apt CASE MARKER WRITER -> run_case on the apt branch with the two path overrides set (in a subshell, so they never leak).
run_apt() {
  ( PATCHBOT_REBOOT_MARKER="$2"; PATCHBOT_MARKER_WRITER="$3"; export PATCHBOT_REBOOT_MARKER PATCHBOT_MARKER_WRITER
    run_case "$1" apt )
}

# field NAME PATH-EXPR -> reads one value from the JSON on stdin.
# A missing key prints nothing (stderr is dropped), so the assertion that wanted it fails as an ordinary "not ok" line.
field() { python3 -c "import sys, json; d = json.load(sys.stdin)['patchbot']; print($1)" 2>/dev/null; }

assert_eq() {  # label got want
  if [ "$2" = "$3" ]; then ok "$1 = $3"; else fail "$1: wanted $3, got $2"; fi
}

# golden SLUG FACT-LINE: records the fact line as a fixture of the published contract; a no-op unless PATCHBOT_GOLDEN_DIR is set.
golden() {
  [ -n "$GOLDEN" ] || return 0
  printf '%s\n' "$2" > "$GOLDEN/patchbot-v2-$1.json"
}

# The v2 envelope: schema_version 2, and the boolean follows the three-state answer. The key list is the documented v2 list for the
# case (assert_keys), so a key that appears or disappears fails here before a reader finds out.
V2_KEYS="'schema_version','available','security','reboot_required','reboot_status','reboot_status_reason','last_checked','manager','repos','packages','package_count','truncated'"
assert_v2() {  # label fact-line
  assert_eq "$1: schema_version" "$(printf '%s' "$2" | field "d.get('schema_version')")" 2
  assert_eq "$1: reboot_required is true only when reboot_status is required" "$(printf '%s' "$2" | field "d['reboot_required'] == (d['reboot_status'] == 'required')")" True
}
assert_keys() {  # label fact-line extra-keys (a python list body, may be empty)
  assert_eq "$1: v2 key list" "$(printf '%s' "$2" | field "sorted(d) == sorted([$V2_KEYS${3:+,$3}])")" True
}
# assert_reboot LABEL FACT-LINE STATUS REASON
assert_reboot() {
  assert_eq "$1: reboot_status" "$(printf '%s' "$2" | field "d['reboot_status']")" "$3"
  assert_eq "$1: reboot_status_reason" "$(printf '%s' "$2" | field "d.get('reboot_status_reason', 'absent')")" "$4"
}

for host in almalinux8-openvox8-01 almalinux8-openvox8-02; do
  info "(1) $host"
  out=$(run_case "$host")
  pk_flagged=$(printf '%s' "$out" | field "sum(1 for p in d['packages'] if p['security'])")
  assert_eq "$host: security == packages flagged security" "$(printf '%s' "$out" | field "d['security']")" "$pk_flagged"
  assert_eq "$host: available == package_count" "$(printf '%s' "$out" | field "d['available']")" "$(printf '%s' "$out" | field "d['package_count']")"
  assert_eq "$host: packages listed == available" "$(printf '%s' "$out" | field "len(d['packages'])")" "$(printf '%s' "$out" | field "d['available']")"
done
# The two hosts' independently-derived expected counts (distinct pending packages with a security advisory).
assert_eq "host A: security packages" "$(run_case almalinux8-openvox8-01 | field "d['security']")" 19
assert_eq "host B: security packages" "$(run_case almalinux8-openvox8-02 | field "d['security']")" 24

info "(2) prefix collision"
out=$(run_case prefix-collision)
assert_eq "security count" "$(printf '%s' "$out" | field "d['security']")" 1
assert_eq "curl is not flagged by curl-minimal" "$(printf '%s' "$out" | field "[p['security'] for p in d['packages'] if p['name']=='curl'][0]")" False
assert_eq "curl-minimal is flagged" "$(printf '%s' "$out" | field "[p['security'] for p in d['packages'] if p['name']=='curl-minimal'][0]")" True

info "(3) check-update fails"
out=$(run_case broken-dnf)
assert_eq "status" "$(printf '%s' "$out" | field "d.get('status')")" check_failed
assert_eq "no packages listed" "$(printf '%s' "$out" | field "len(d['packages'])")" 0

info "(4) updateinfo fails"
out=$(run_case updateinfo-fails)
assert_eq "status" "$(printf '%s' "$out" | field "d.get('status')")" check_failed
assert_eq "no packages listed" "$(printf '%s' "$out" | field "len(d['packages'])")" 0

info "(5) nothing pending"
out=$(run_case fully-patched)
assert_eq "status" "$(printf '%s' "$out" | field "d.get('status')")" ok
assert_eq "available" "$(printf '%s' "$out" | field "d['available']")" 0
assert_eq "no packages listed" "$(printf '%s' "$out" | field "len(d['packages'])")" 0
assert_eq "security" "$(printf '%s' "$out" | field "d['security']")" 0

info "(6) envelope"
out=$(run_case almalinux8-openvox8-01)
assert_eq "types the console reads" "$(printf '%s' "$out" | field "[type(d['available']).__name__, type(d['security']).__name__, type(d['reboot_required']).__name__, type(d['last_checked']).__name__, d['manager']]")" "['int', 'int', 'bool', 'str', 'dnf']"
assert_eq "keys present" "$(printf '%s' "$out" | field "all(k in d for k in ('repos','packages','package_count','truncated'))")" True

info "(7) reboot_required without dnf-utils"
# The fake PATH has no standalone needs-restarting, like a host without dnf-utils (the lab hosts have none). The reboot answer
# must still come from `dnf needs-restarting -r`. (Before: only the standalone binary was tried, so a host that needed a reboot
# reported reboot_required false.)
assert_eq "host A needs a reboot" "$(run_case almalinux8-openvox8-01 | field "d['reboot_required']")" True
assert_eq "clean host does not" "$(run_case fully-patched | field "d['reboot_required']")" False

info "(8) the shared awk helpers do not leak variables into their caller"
# The helpers in SEC_AWK are called from loops that use `i`. nevra_name used a global `i`, so a caller looping on `i` never saw it
# advance past the helper's own range and spun forever (found by a probe that pinned a core on a lab node). The loop below is
# bounded by timeout, so a regression fails this case instead of hanging the suite.
SEC_AWK_SRC=$(sed -n "/^  SEC_AWK='/,/^    }'\$/p" "$TARGET" | sed "1s/^  SEC_AWK='//; \$s/'\$//")
if command -v timeout >/dev/null 2>&1; then
  ran=$(timeout 10 awk -v sec="a-1-1.x86_64" "$SEC_AWK_SRC"'
    BEGIN { for (i = 1; i <= 3; i++) { load_security(sec); n++ } print n }' 2>/dev/null || true)
  assert_eq "a caller looping on i still runs 3 times" "${ran:-hung-or-failed}" 3
else
  ok "a caller looping on i still runs 3 times # SKIP no timeout command; cannot bound the loop safely"
fi

info "(9) yum branch: the security count is right; status is deliberately not claimed"
# Real yum (EL7) has no fixture here: on the lab, yum is dnf under another name and the script takes its dnf branch. So this case
# uses the dnf fixtures through a shim named yum with dnf absent, which proves the SHARED parsing (count, exact names) but says
# nothing about real yum's exit codes. The script therefore does not emit status for yum, rather than guess it.
out=$(run_case almalinux8-openvox8-01 yum)
assert_eq "yum: manager" "$(printf '%s' "$out" | field "d['manager']")" yum
assert_eq "yum: security counts distinct packages" "$(printf '%s' "$out" | field "d['security']")" 19
assert_eq "yum: no status claimed" "$(printf '%s' "$out" | field "d.get('status', 'absent')")" absent

info "(10) a failed check still reports the reboot answer"
# needs-restarting does not depend on repository metadata (measured on a lab host: with every repo disabled it still exits 1 when a
# reboot is pending), so a failed update check can still answer the reboot question truthfully. Forcing reboot_required false on
# failure threw away a real signal: a host with broken repositories that needs a reboot said it did not. Every other field of a
# failed check stays empty, because those really are unknown.
assert_eq "check-update fails, host needs a reboot" "$(run_case broken-dnf | field "d['reboot_required']")" True
assert_eq "updateinfo fails, host needs a reboot" "$(run_case updateinfo-fails | field "d['reboot_required']")" True
assert_eq "a failed check keeps the other fields empty" "$(run_case broken-dnf | field "[d['available'], d['security'], len(d['packages'])]")" "[0, 0, 0]"

info "(11) dnf without its needs-restarting plugin cannot tell: unknown, never no (D-09)"
# dnf4 reports a missing plugin as exit 1 with EMPTY stdout, so the old fact called that "reboot required" and an if-needed policy
# would have rebooted the node for nothing. The shared rule reads exit 1 with output as required and exit 1 with none as unknown.
out=$(run_case plugin-missing)
assert_v2 "plugin missing" "$out"
assert_reboot "plugin missing" "$out" unknown plugin_missing
assert_eq "plugin missing: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" False
assert_keys "plugin missing" "$out" "'status'"
golden dnf-plugin-missing "$out"

info "(12) the shared rule on dnf: required, not required, and a failing probe"
out=$(run_case reboot-required)
assert_v2 "dnf reboot required" "$out"
assert_reboot "dnf reboot required" "$out" required needs_restarting
assert_eq "dnf reboot required: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" True
golden dnf-reboot-required "$out"
out=$(run_case no-reboot)
assert_v2 "dnf no reboot" "$out"
assert_reboot "dnf no reboot" "$out" not_required needs_restarting
golden dnf-no-reboot "$out"
out=$(run_case needs-restarting-fails)
assert_v2 "dnf needs-restarting fails" "$out"
assert_reboot "dnf needs-restarting fails" "$out" unknown needs_restarting_failed
assert_eq "dnf needs-restarting fails: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" False
golden dnf-needs-restarting-fails "$out"
out=$(run_case broken-dnf)
assert_v2 "dnf broken" "$out"
assert_reboot "dnf broken" "$out" required needs_restarting
assert_keys "dnf broken" "$out" "'status','check_error'"
golden dnf-broken-dnf "$out"

info "(13) apt: the reboot marker, and a node with nothing that writes it cannot tell"
out=$(run_apt apt-marker-present "$WORK/marker-present" "$NOPE")
assert_v2 "apt marker present" "$out"
assert_reboot "apt marker present" "$out" required marker_present
assert_eq "apt marker present: manager" "$(printf '%s' "$out" | field "d['manager']")" apt
assert_eq "apt marker present: counts from the recorded dist-upgrade" "$(printf '%s' "$out" | field "[d['available'], d['security'], d['package_count']]")" "[2, 2, 2]"
assert_keys "apt marker present" "$out" ""
golden apt-marker-present "$out"
out=$(run_apt apt-marker-absent "$NOPE" "$WORK/marker-writer")
assert_v2 "apt marker absent" "$out"
assert_reboot "apt marker absent" "$out" not_required marker_absent
assert_keys "apt marker absent" "$out" ""
golden apt-marker-absent "$out"
# D-09: no marker and nothing that would write one is "cannot tell", not "no".
out=$(run_apt apt-no-marker-writer "$NOPE" "$NOPE")
assert_v2 "apt no marker writer" "$out"
assert_reboot "apt no marker writer" "$out" unknown no_marker_writer
assert_eq "apt no marker writer: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" False
assert_keys "apt no marker writer" "$out" ""
golden apt-no-marker-writer "$out"

info "(14) yum: the standalone needs-restarting, and its absence is unknown"
out=$(run_case reboot-required yum standalone)
assert_v2 "yum reboot required" "$out"
assert_reboot "yum reboot required" "$out" required needs_restarting
assert_eq "yum reboot required: manager" "$(printf '%s' "$out" | field "d['manager']")" yum
assert_keys "yum reboot required" "$out" ""
golden yum-reboot-required "$out"
out=$(run_case no-reboot yum standalone)
assert_v2 "yum no reboot" "$out"
assert_reboot "yum no reboot" "$out" not_required needs_restarting
golden yum-no-reboot "$out"
out=$(run_case plugin-missing yum)
assert_v2 "yum without needs-restarting" "$out"
assert_reboot "yum without needs-restarting" "$out" unknown plugin_missing
assert_eq "yum without needs-restarting: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" False
golden yum-plugin-missing "$out"

info "(15) no supported package manager: unknown, with an empty manager"
out=$(run_case no-package-manager none)
assert_v2 "no package manager" "$out"
assert_reboot "no package manager" "$out" unknown no_package_manager
assert_eq "no package manager: manager" "$(printf '%s' "$out" | field "repr(d['manager'])")" "''"
assert_eq "no package manager: reboot_required" "$(printf '%s' "$out" | field "d['reboot_required']")" False
assert_keys "no package manager" "$out" ""
golden none-no-package-manager "$out"

info "(16) every dnf case reports the v2 envelope and the answer its recorded probe gives"
for c in almalinux8-openvox8-01 almalinux8-openvox8-02 prefix-collision fully-patched; do
  out=$(run_case "$c")
  assert_v2 "$c" "$out"
  assert_keys "$c" "$out" "'status'"
done
assert_reboot "host A" "$(run_case almalinux8-openvox8-01)" required needs_restarting
assert_reboot "clean host" "$(run_case fully-patched)" not_required needs_restarting
out=$(run_case updateinfo-fails)
assert_v2 "updateinfo fails" "$out"
assert_reboot "updateinfo fails" "$out" required needs_restarting
assert_keys "updateinfo fails" "$out" "'status','check_error'"
out=$(run_case almalinux8-openvox8-01 yum)
assert_v2 "yum host A" "$out"
assert_reboot "yum host A without needs-restarting" "$out" unknown plugin_missing

info "(17) the package cap: counts stay exact and truncated says the list was capped"
full=$(run_case almalinux8-openvox8-01)
capped=$( PCM_PATCH_MAX_PACKAGES=5; export PCM_PATCH_MAX_PACKAGES; run_case almalinux8-openvox8-01 )
assert_eq "uncapped: truncated" "$(printf '%s' "$full" | field "d['truncated']")" False
assert_eq "capped: packages listed" "$(printf '%s' "$capped" | field "len(d['packages'])")" 5
assert_eq "capped: available is the true total" "$(printf '%s' "$capped" | field "d['available']")" "$(printf '%s' "$full" | field "d['available']")"
assert_eq "capped: package_count is the true total" "$(printf '%s' "$capped" | field "d['package_count']")" "$(printf '%s' "$full" | field "d['available']")"
assert_eq "capped: security is the true total" "$(printf '%s' "$capped" | field "d['security']")" 19
assert_eq "capped: truncated" "$(printf '%s' "$capped" | field "d['truncated']")" True
capped=$( PCM_PATCH_MAX_PACKAGES=5; export PCM_PATCH_MAX_PACKAGES; run_apt apt-marker-present "$WORK/marker-present" "$NOPE" )
assert_eq "apt capped: packages listed" "$(printf '%s' "$capped" | field "len(d['packages'])")" "$(printf '%s' "$capped" | field "min(5, d['package_count'])")"
assert_eq "apt capped: truncated follows the total" "$(printf '%s' "$capped" | field "d['truncated'] == (d['package_count'] > 5)")" True

[ "$FAILED" -eq 0 ] || printf '# %s failed\n' "$FAILED"
cat <<PLAN
1..$N
PLAN
[ "$FAILED" -eq 0 ]
