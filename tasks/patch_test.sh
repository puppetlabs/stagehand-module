#!/bin/sh
# stagehand::patch (adapters/stagehand/tasks/patch.sh) test harness.
#
# History: ported from lab/code/modules/patchbot/tasks/patch_test.sh
# (999.46-01-PLAN.md Task 1), converted to TAP and extended for the reboot
# policies and the shared reboot-status rule (72.3-01-PLAN.md Tasks 2 and 3).
#
# Output is TAP so a RED run can be classified: each case prints
# "ok N - <name>" or "not ok N - <name>", informational lines start with "# ",
# the plan line "1..N" is printed last, every case runs even after a failure,
# and the exit status is non-zero when any case failed.
#
# Method: mktemp sandbox, a PATH-shimmed apt-get that records its argv, shims for
# systemctl / shutdown / reboot that record a reboot request per case, and
# env -i runs with the PT_* parameters (patch.json's input_method is
# "environment"). The test-only overrides PATCHBOT_REBOOT_MARKER and
# PATCHBOT_MARKER_WRITER point the apt reboot rule at files created or omitted
# in the sandbox. Run it on macOS or Linux; it needs jq for its own JSON
# assertions, but the task under test is always run with a curated PATH that
# contains no jq (patch_ids must work on a node without jq).
#
# Reboot assertions: the task schedules a reboot 3 seconds after it exits, so a
# positive case waits (at most 10 seconds) for the shim log to appear, and every
# negative case is re-checked once at the end, after a delay longer than that.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
TARGET_SH="$SCRIPT_DIR/patch.sh"
TARGET_JSON="$SCRIPT_DIR/patch.json"

N=0
FAILED=0
tap_ok() {
  N=$((N + 1))
  printf 'ok %s - %s\n' "$N" "$1"
}
tap_not_ok() {
  N=$((N + 1))
  FAILED=$((FAILED + 1))
  printf 'not ok %s - %s\n' "$N" "$1"
  shift
  # Detail lines, one TAP comment per line.
  printf '%s\n' "$@" | sed 's/^/# /'
}
info() { printf '# %s\n' "$*"; }

bail() {
  printf 'Bail out! %s\n' "$*"
  exit 1
}

[ -f "$TARGET_SH" ] || bail "patch.sh not found at $TARGET_SH"
[ -f "$TARGET_JSON" ] || bail "patch.json not found at $TARGET_JSON"
command -v jq >/dev/null 2>&1 || bail "jq is required to run this test harness"

WORK=$(mktemp -d) || bail "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

SHIMDIR="$WORK/shims"
mkdir -p "$SHIMDIR" || bail "could not create shim dir"

ARGV_LOG="$WORK/argv.log"
MARKER="$WORK/reboot-required"
WRITER="$WORK/notify-reboot-required"
DEFERRED="$WORK/deferred"
: > "$DEFERRED"

# make_pm_stub NAME FAIL_FLAG_VAR
# Writes a PATH shim for NAME that logs "NAME <argv>" to ARGV_LOG. If
# FAIL_FLAG_VAR is "1" the shim exits 1; otherwise it exits 0.
make_pm_stub() {
  name="$1"
  fail_var="$2"
  cat > "$SHIMDIR/$name" <<SHIM
#!/bin/sh
printf '$name %s\n' "\$*" >> "$ARGV_LOG"
if [ "\${$fail_var:-0}" = "1" ]; then
  exit 1
fi
exit 0
SHIM
  chmod +x "$SHIMDIR/$name"
}
make_pm_stub apt-get SHIM_APT_FAIL

# Reboot shims: each appends "NAME <argv>" to the per-case file named by
# REBOOT_LOG (passed through env -i), then exits 0.
for name in systemctl shutdown reboot; do
  cat > "$SHIMDIR/$name" <<SHIM
#!/bin/sh
printf '$name %s\n' "\$*" >> "\${REBOOT_LOG:-/dev/null}"
exit 0
SHIM
  chmod +x "$SHIMDIR/$name"
done

# Manager shims for the dnf and yum cases. Each gets its own directory (with the
# reboot shims) so no apt-get is visible there and the task takes that branch.
# The needs-restarting answer is configured per case: NR_RC and NR_OUT.
make_dir_with_reboot_shims() {
  mkdir -p "$1" || bail "could not create $1"
  for rname in systemctl shutdown reboot; do
    cp "$SHIMDIR/$rname" "$1/$rname"
  done
}
make_needs_restarting_shim() { # PATH
  cat > "$1" <<'SHIM'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$ARGV_LOG"
case "$*" in
  *needs-restarting*|-r) [ -n "${NR_OUT:-}" ] && printf '%s\n' "$NR_OUT"; exit "${NR_RC:-0}" ;;
esac
exit 0
SHIM
  chmod +x "$1"
}
DNFDIR="$WORK/shims-dnf"
YUMDIR="$WORK/shims-yum"
YUMNONRDIR="$WORK/shims-yum-no-needs-restarting"
make_dir_with_reboot_shims "$DNFDIR"
make_dir_with_reboot_shims "$YUMDIR"
make_dir_with_reboot_shims "$YUMNONRDIR"
make_needs_restarting_shim "$DNFDIR/dnf"
make_needs_restarting_shim "$YUMDIR/yum"
make_needs_restarting_shim "$YUMDIR/needs-restarting"
make_needs_restarting_shim "$YUMNONRDIR/yum"

# A curated PATH: symlinks to only the tools patch.sh needs, resolved with
# command -v BEFORE any PATH is narrowed (so it also works on a merged-/usr
# Linux host where /bin is /usr/bin). No jq is ever linked in. The task is run
# with the shim directory first and this directory after it.
CURATED="$WORK/curated"
mkdir -p "$CURATED" || bail "could not create the curated PATH directory"
for tool in sh grep sed tr awk sleep cat nohup setsid; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  case "$tool_path" in /*) ln -s "$tool_path" "$CURATED/$tool" ;; esac
done
for need in sh grep sed tr sleep; do
  [ -e "$CURATED/$need" ] || bail "the curated PATH could not resolve $need"
done
TEST_PATH="$SHIMDIR:$CURATED"
DNF_PATH="$DNFDIR:$CURATED"
YUM_PATH="$YUMDIR:$CURATED"
YUMNONR_PATH="$YUMNONRDIR:$CURATED"
if PATH="$TEST_PATH" command -v jq >/dev/null 2>&1; then
  bail "the curated PATH contains jq; the task must be tested without it"
fi

# --- case helpers -------------------------------------------------------------

CASE_NAME=""
CASE_ERRS=""
CASE_ID=0
REBOOT_LOG=""

begin_case() {
  CASE_NAME="$1"
  CASE_ERRS=""
  CASE_ID=$((CASE_ID + 1))
  REBOOT_LOG="$WORK/reboot.$CASE_ID.log"
  : > "$REBOOT_LOG"
  : > "$ARGV_LOG"
  unset PT_patch_ids PT_security_only PT_reboot
  RUN_PATH="$TEST_PATH"
  SHIM_APT_FAIL=0
  NR_RC=0
  NR_OUT=""
  rm -f "$MARKER" "$WRITER"
}
case_err() {
  CASE_ERRS="${CASE_ERRS}${CASE_ERRS:+
}$*"
}
end_case() {
  if [ -z "$CASE_ERRS" ]; then
    tap_ok "$CASE_NAME"
  else
    tap_not_ok "$CASE_NAME" "$CASE_ERRS"
  fi
}
assert_eq() { # DESC ACTUAL EXPECTED
  [ "$2" = "$3" ] || case_err "$1: expected [$3], got [$2]"
}
assert_contains() { # DESC HAYSTACK NEEDLE
  case "$2" in
    *"$3"*) : ;;
    *) case_err "$1: expected to contain [$3], got [$2]" ;;
  esac
}
assert_not_contains() { # DESC HAYSTACK NEEDLE
  case "$2" in
    *"$3"*) case_err "$1: expected NOT to contain [$3], got [$2]" ;;
    *) : ;;
  esac
}
assert_apt_never_called() {
  if [ -s "$ARGV_LOG" ]; then
    case_err "apt-get shim was invoked but should not have been: $(tr '\n' '|' < "$ARGV_LOG")"
  fi
}

marker_present() { : > "$MARKER"; }
writer_present() {
  : > "$WRITER"
  chmod +x "$WRITER"
}

# run_patch: run patch.sh in a clean environment. Only the PT_* variables the
# case actually set are passed, so "unset" and "empty" stay distinguishable.
# Sets OUT, ERR and RC.
run_patch() {
  set -- \
    PATH="$RUN_PATH" \
    HOME="$HOME" \
    ARGV_LOG="$ARGV_LOG" \
    REBOOT_LOG="$REBOOT_LOG" \
    PATCHBOT_REBOOT_MARKER="$MARKER" \
    PATCHBOT_MARKER_WRITER="$WRITER" \
    SHIM_APT_FAIL="$SHIM_APT_FAIL" \
    NR_RC="$NR_RC" \
    NR_OUT="$NR_OUT"
  [ -n "${PT_patch_ids+x}" ] && set -- "$@" PT_patch_ids="$PT_patch_ids"
  [ -n "${PT_security_only+x}" ] && set -- "$@" PT_security_only="$PT_security_only"
  [ -n "${PT_reboot+x}" ] && set -- "$@" PT_reboot="$PT_reboot"
  OUT=$(env -i "$@" sh "$TARGET_SH" 2>"$WORK/stderr")
  RC=$?
  ERR=$(cat "$WORK/stderr")
}

# jf KEY: a top-level key of the last result line, as plain text.
jf() {
  printf '%s' "$OUT" | jq -r --arg k "$1" '.[$k] | tostring' 2>/dev/null
}

# wait_for_reboot: wait up to 10 seconds for this case's reboot shim to be called.
wait_for_reboot() {
  i=0
  while [ "$i" -lt 10 ]; do
    [ -s "$REBOOT_LOG" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# defer_no_reboot: re-check at the end of the run that this case never reached
# a reboot shim (the task would have called it 3 seconds after exiting).
defer_no_reboot() {
  printf '%s\t%s\n' "$CASE_NAME" "$REBOOT_LOG" >> "$DEFERRED"
}

RESULT_KEYS='["applied","reboot_policy","reboot_required","reboot_status","reboot_status_reason","rebooting","status"]'

# check_result POLICY STATUS REASON REQUIRED REBOOTING: the common result assertions.
check_result() {
  assert_eq "exit status" "$RC" "0"
  assert_eq "result keys" "$(printf '%s' "$OUT" | jq -c 'keys | sort' 2>/dev/null)" "$RESULT_KEYS"
  assert_eq "reboot_policy" "$(jf reboot_policy)" "$1"
  assert_eq "reboot_status" "$(jf reboot_status)" "$2"
  assert_eq "reboot_status_reason" "$(jf reboot_status_reason)" "$3"
  assert_eq "reboot_required" "$(jf reboot_required)" "$4"
  assert_eq "rebooting" "$(jf rebooting)" "$5"
}

# --- patch_ids safety (security gate 3 of 3) -------------------------------------

begin_case "patch_ids=[--allow-downgrades] is rejected before any package-manager call"
PT_patch_ids='["--allow-downgrades"]'
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "patch_ids contains an invalid identifier"
assert_apt_never_called
end_case

begin_case "patch_ids=[foo --reinstall] (embedded whitespace) is rejected before any package-manager call"
PT_patch_ids='["foo --reinstall"]'
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "patch_ids contains an invalid identifier"
assert_apt_never_called
end_case

# --- unchanged success paths -----------------------------------------------------

begin_case "no patch_ids: unchanged success path with the v2 result shape"
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "stdout" "$OUT" '{"status": "patched", "applied": "all", "reboot_policy": "never", "reboot_status": "unknown", "reboot_status_reason": "no_marker_writer", "reboot_required": false, "rebooting": false}'
grep -q '^apt-get -qq update' "$ARGV_LOG" || case_err "apt-get update was not invoked"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "install "
defer_no_reboot
end_case

begin_case "patch_ids=[openssl,curl]: apt-get installs exactly those two names, no dist-upgrade"
PT_patch_ids='["openssl","curl"]'
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- openssl curl"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "dist-upgrade"
end_case

begin_case "patch_ids=[openssl, curl] with spaces and no jq anywhere on PATH: selected install works"
PT_patch_ids='["openssl", "curl"]'
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- openssl curl"
end_case

begin_case "patch_ids=[] is no selection: full upgrade, no install token"
PT_patch_ids='[]'
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "all"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "install "
end_case

begin_case "patch_ids=null is no selection: full upgrade, no install token"
PT_patch_ids='null'
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "all"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "install "
end_case

begin_case "patch_ids=[openssh-server-] (trailing dash is apt's remove syntax) is rejected before any package-manager call"
PT_patch_ids='["openssh-server-"]'
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "patch_ids contains an invalid identifier"
assert_apt_never_called
end_case

begin_case "patch_ids=[openssl,nginx-] (one bad id in a list) rejects the whole list before any package-manager call"
PT_patch_ids='["openssl","nginx-"]'
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "patch_ids contains an invalid identifier"
assert_apt_never_called
end_case

begin_case "patch_ids=[g++,libstdc++6] (real names ending or containing +) are accepted, after the -- terminator"
PT_patch_ids='["g++","libstdc++6"]'
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- g++ libstdc++6"
end_case

begin_case "patch_ids=[a] (single character) is accepted"
PT_patch_ids='["a"]'
run_patch
assert_eq "exit status" "$RC" "0"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- a"
end_case

begin_case "patch_ids that is not a JSON array is rejected before any package-manager call"
PT_patch_ids='openssl'
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "patch_ids must be a JSON array of strings"
assert_apt_never_called
end_case

# --- reboot policy matrix (apt) --------------------------------------------------

begin_case "reboot=never with the marker present: required, reboot_required true, no reboot"
PT_reboot=never
marker_present
writer_present
run_patch
check_result never required marker_present true false
defer_no_reboot
end_case

begin_case "reboot=if-needed with the marker present: reboots"
PT_reboot=if-needed
marker_present
writer_present
run_patch
check_result if-needed required marker_present true true
wait_for_reboot || case_err "no reboot shim call within 10 seconds"
assert_contains "reboot shim" "$(cat "$REBOOT_LOG")" "reboot"
end_case

begin_case "reboot=if-needed with a marker writer and no marker: not_required, no reboot"
PT_reboot=if-needed
writer_present
run_patch
check_result if-needed not_required marker_absent false false
defer_no_reboot
end_case

begin_case "reboot=if-needed with neither marker nor writer: unknown, no reboot (cannot tell never reboots)"
PT_reboot=if-needed
run_patch
check_result if-needed unknown no_marker_writer false false
defer_no_reboot
end_case

begin_case "reboot=always with no marker: reboots"
PT_reboot=always
writer_present
run_patch
check_result always not_required marker_absent false true
wait_for_reboot || case_err "no reboot shim call within 10 seconds"
assert_contains "reboot shim" "$(cat "$REBOOT_LOG")" "reboot"
end_case

begin_case "legacy reboot=true behaves as if-needed"
PT_reboot=true
marker_present
writer_present
run_patch
check_result if-needed required marker_present true true
wait_for_reboot || case_err "no reboot shim call within 10 seconds"
end_case

begin_case "legacy reboot=false behaves as never"
PT_reboot=false
marker_present
writer_present
run_patch
check_result never required marker_present true false
defer_no_reboot
end_case

begin_case "reboot unset behaves as never"
marker_present
writer_present
run_patch
check_result never required marker_present true false
defer_no_reboot
end_case

begin_case "reboot=sometimes: exit 1, stderr names the accepted values, apt-get never invoked"
PT_reboot=sometimes
run_patch
assert_eq "exit status" "$RC" "1"
assert_contains "stderr" "$ERR" "never, if-needed or always"
assert_apt_never_called
end_case

# --- reboot rule on dnf and yum (shared reboot_status block) -----------------------

RECORDED_REQUIRED='Core libraries or services have been updated since boot-up:
  * glibc

Reboot is required to fully utilize these updates.'

begin_case "dnf needs-restarting exit 0: not_required, no reboot under if-needed"
PT_reboot=if-needed
RUN_PATH="$DNF_PATH"
NR_RC=0
NR_OUT='No core libraries or services have been updated since boot-up.'
run_patch
check_result if-needed not_required needs_restarting false false
assert_contains "dnf argv" "$(cat "$ARGV_LOG")" "dnf -q needs-restarting -r"
defer_no_reboot
end_case

begin_case "dnf needs-restarting exit 1 with output: required, if-needed reboots"
PT_reboot=if-needed
RUN_PATH="$DNF_PATH"
NR_RC=1
NR_OUT="$RECORDED_REQUIRED"
run_patch
check_result if-needed required needs_restarting true true
wait_for_reboot || case_err "no reboot shim call within 10 seconds"
end_case

begin_case "dnf needs-restarting exit 1 with NO output (plugin missing): unknown, if-needed does NOT reboot"
PT_reboot=if-needed
RUN_PATH="$DNF_PATH"
NR_RC=1
NR_OUT=""
run_patch
check_result if-needed unknown plugin_missing false false
defer_no_reboot
end_case

begin_case "dnf needs-restarting exit 2 (dnf5 unknown argument): unknown, needs_restarting_failed"
PT_reboot=if-needed
RUN_PATH="$DNF_PATH"
NR_RC=2
NR_OUT=""
run_patch
check_result if-needed unknown needs_restarting_failed false false
defer_no_reboot
end_case

begin_case "yum with standalone needs-restarting exit 0: not_required"
PT_reboot=if-needed
RUN_PATH="$YUM_PATH"
NR_RC=0
run_patch
check_result if-needed not_required needs_restarting false false
defer_no_reboot
end_case

begin_case "yum with standalone needs-restarting exit 1: required, if-needed reboots"
PT_reboot=if-needed
RUN_PATH="$YUM_PATH"
NR_RC=1
NR_OUT="$RECORDED_REQUIRED"
run_patch
check_result if-needed required needs_restarting true true
wait_for_reboot || case_err "no reboot shim call within 10 seconds"
end_case

begin_case "yum with no needs-restarting on PATH: unknown, plugin_missing, no reboot"
PT_reboot=if-needed
RUN_PATH="$YUMNONR_PATH"
run_patch
check_result if-needed unknown plugin_missing false false
defer_no_reboot
end_case

# --- selected ids end option parsing and only upgrade what is installed ------------

begin_case "dnf selected ids: the argv has -- before the ids"
PT_patch_ids='["openssl","curl"]'
RUN_PATH="$DNF_PATH"
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "dnf argv" "$(cat "$ARGV_LOG")" "dnf -y upgrade -- openssl curl"
end_case

begin_case "yum selected ids: the argv has -- before the ids"
PT_patch_ids='["openssl","curl"]'
RUN_PATH="$YUM_PATH"
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "yum argv" "$(cat "$ARGV_LOG")" "yum -y update -- openssl curl"
end_case

begin_case "dnf and yum refuse a trailing-dash id before any package-manager call"
PT_patch_ids='["openssh-server-"]'
RUN_PATH="$DNF_PATH"
run_patch
assert_eq "dnf exit status" "$RC" "1"
assert_contains "dnf stderr" "$ERR" "patch_ids contains an invalid identifier"
assert_apt_never_called
RUN_PATH="$YUM_PATH"
run_patch
assert_eq "yum exit status" "$RC" "1"
assert_apt_never_called
end_case

# --- deferred negative reboot assertions -------------------------------------------

info "waiting 4 seconds before re-checking that no negative case rebooted"
sleep 4
while IFS="$(printf '\t')" read -r dname dlog; do
  [ -n "$dname" ] || continue
  if [ -s "$dlog" ]; then
    tap_not_ok "no reboot scheduled: $dname" "reboot shim was called: $(tr '\n' '|' < "$dlog")"
  else
    tap_ok "no reboot scheduled: $dname"
  fi
done < "$DEFERRED"

cat <<PLAN
1..$N
PLAN
[ "$FAILED" -eq 0 ]
