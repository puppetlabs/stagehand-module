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
#
# Per-package result contract (77.1-02, D-16). When patch_ids is given the task
# queries the package database before and after the package-manager call
# (dpkg-query on apt, rpm -q on dnf and yum) and prints result_version 1 with one
# entry per requested package. The shims answer from a per-case state file
# (PKG_STATE, one "name|arch|version[|dpkg status]" line per installed package) and
# the manager shims apply the per-case upgrade list (PKG_UPGRADES, "name|new
# version") to it, so the "after" query sees what the "install" call did. Both
# query shims refuse a query-format string other than the one patch.sh is pinned
# to, so a drifted format fails here, not on a node.
#
# PATCH_RESULT_GOLDEN_DIR (test-only, read by this harness and never by the task):
# when set to an existing directory, the cases named in `golden` calls write the
# task's raw result line there as patch-result-v1-<slug>.json. The fixtures that
# backend/internal/httpapi/patch_task_result_schema_test.go validates against
# docs/schemas/patch-task-result-v1.schema.json are recorded by one run of this
# harness and never written by hand:
#   PATCH_RESULT_GOLDEN_DIR=$PWD/backend/internal/httpapi/testdata sh adapters/stagehand/tasks/patch_test.sh

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
QUERY_LOG="$WORK/query.log"
PKG_STATE="$WORK/pkgstate"
PKG_UPGRADES="$WORK/pkgupgrades"
PM_HELPER="$WORK/pmhelper.sh"
GOLDEN="${PATCH_RESULT_GOLDEN_DIR:-}"
MARKER="$WORK/reboot-required"
WRITER="$WORK/notify-reboot-required"
DEFERRED="$WORK/deferred"
: > "$DEFERRED"

# pmhelper.sh: sourced by the manager shims. apply_upgrades ID... rewrites the
# state file so every named, installed package takes its version from the
# per-case upgrade list. Only sh builtins and the tools on the curated PATH.
cat > "$PM_HELPER" <<'HELPER'
upgrade_version() {
  [ -f "${PKG_UPGRADES:-}" ] || return 0
  while IFS='|' read -r _un _uv; do
    if [ "$_un" = "$1" ]; then
      printf '%s' "$_uv"
      return 0
    fi
  done < "$PKG_UPGRADES"
}
apply_upgrades() {
  [ -f "${PKG_STATE:-}" ] || return 0
  _out=""
  while IFS='|' read -r _n _a _v _s; do
    [ -n "$_n" ] || continue
    for _id in "$@"; do
      if [ "$_id" = "$_n" ]; then
        _nv=$(upgrade_version "$_n")
        [ -n "$_nv" ] && _v=$_nv
      fi
    done
    _out="${_out}${_n}|${_a}|${_v}|${_s}
"
  done < "$PKG_STATE"
  printf '%s' "$_out" > "$PKG_STATE"
}
HELPER

# The apt-get shim logs its argv. SHIM_APT_FAIL=1 makes the install call fail
# (update still succeeds, as it does on a node whose archive is reachable but
# whose install breaks). A successful install applies the upgrade list to the
# ids after "--".
cat > "$SHIMDIR/apt-get" <<'SHIM'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$ARGV_LOG"
case "$*" in
  *install*)
    if [ "${SHIM_APT_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    . "$PM_HELPER"
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
    shift
    apply_upgrades "$@"
    ;;
esac
exit 0
SHIM
chmod +x "$SHIMDIR/apt-get"

# dpkg-query shim: answers the one query format patch.sh is pinned to from the
# state file. A missing package prints dpkg's message on stderr and exits 1.
cat > "$SHIMDIR/dpkg-query" <<'SHIM'
#!/bin/sh
printf 'dpkg-query %s\n' "$*" >> "${QUERY_LOG:-/dev/null}"
want='${Package}|${Architecture}|${Version}|${db:Status-Abbrev}\n'
if [ "${1:-}" != "-W" ] || [ "${2:-}" != "-f=$want" ]; then
  echo "dpkg-query shim: unexpected arguments: $*" >&2
  exit 2
fi
shift 2
rc=0
for name in "$@"; do
  qn=${name%%:*}
  qa=${name#*:}
  [ "$qa" = "$name" ] && qa=""
  found=0
  while IFS='|' read -r n a v s; do
    [ "$n" = "$qn" ] || continue
    [ -z "$qa" ] || [ "$qa" = "$a" ] || continue
    printf '%s|%s|%s|%s \n' "$n" "$a" "$v" "${s:-ii}"
    found=1
  done < "${PKG_STATE:-/dev/null}"
  if [ "$found" = 0 ]; then
    echo "dpkg-query: no packages found matching $name" >&2
    rc=1
  fi
done
exit "$rc"
SHIM
chmod +x "$SHIMDIR/dpkg-query"

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
  *" -- "*)
    # "dnf -y upgrade -- ID..." / "yum -y update -- ID...": SHIM_PM_FAIL=1
    # fails the call; otherwise the upgrade list is applied to the ids.
    if [ "${SHIM_PM_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    . "$PM_HELPER"
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
    shift
    apply_upgrades "$@"
    ;;
esac
exit 0
SHIM
  chmod +x "$1"
}
# rpm shim: answers the one query format patch.sh is pinned to from the state
# file (the version column already carries the epoch prefix when it is non-zero).
# A missing package prints rpm's message on stdout and exits 1, as real rpm does.
make_rpm_shim() { # PATH
  cat > "$1" <<'SHIM'
#!/bin/sh
printf 'rpm %s\n' "$*" >> "${QUERY_LOG:-/dev/null}"
want='%{NAME}|%{ARCH}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}\n'
if [ "${1:-}" != "-q" ] || [ "${2:-}" != "--qf" ] || [ "${3:-}" != "$want" ]; then
  echo "rpm shim: unexpected arguments: $*" >&2
  exit 2
fi
shift 3
rc=0
for name in "$@"; do
  found=0
  while IFS='|' read -r n a v s; do
    [ "$n" = "$name" ] || continue
    printf '%s|%s|%s\n' "$n" "$a" "$v"
    found=1
  done < "${PKG_STATE:-/dev/null}"
  if [ "$found" = 0 ]; then
    printf 'package %s is not installed\n' "$name"
    rc=1
  fi
done
exit "$rc"
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
make_rpm_shim "$DNFDIR/rpm"
make_rpm_shim "$YUMDIR/rpm"
make_rpm_shim "$YUMNONRDIR/rpm"

# A curated PATH: symlinks to only the tools patch.sh needs, resolved with
# command -v BEFORE any PATH is narrowed (so it also works on a merged-/usr
# Linux host where /bin is /usr/bin). No jq is ever linked in. The task is run
# with the shim directory first and this directory after it.
CURATED="$WORK/curated"
mkdir -p "$CURATED" || bail "could not create the curated PATH directory"
for tool in sh grep sed tr awk sleep cat nohup setsid mktemp rm; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  case "$tool_path" in /*) ln -s "$tool_path" "$CURATED/$tool" ;; esac
done
for need in sh grep sed tr sleep mktemp rm; do
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
  SHIM_PM_FAIL=0
  : > "$QUERY_LOG"
  : > "$PKG_STATE"
  : > "$PKG_UPGRADES"
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

# pkg_installed NAME ARCH VERSION [DPKG_STATUS]: a package the node has (apt: dpkg
# status ii unless given; dnf and yum: put the epoch in VERSION as rpm prints it).
pkg_installed() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-ii}" >> "$PKG_STATE"
}
# pkg_upgrade NAME VERSION: the version a successful manager call installs.
pkg_upgrade() {
  printf '%s|%s\n' "$1" "$2" >> "$PKG_UPGRADES"
}
assert_one_line() { # stdout is exactly one line (the Bolt contract)
  assert_eq "stdout line count" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
}
assert_no_queries() {
  if [ -s "$QUERY_LOG" ]; then
    case_err "the package database was queried but should not have been: $(tr '\n' '|' < "$QUERY_LOG")"
  fi
}
# golden SLUG: record this case's raw result line as a fixture of the published
# contract; a no-op unless PATCH_RESULT_GOLDEN_DIR names an existing directory.
golden() {
  [ -n "$GOLDEN" ] && [ -d "$GOLDEN" ] || return 0
  printf '%s\n' "$OUT" > "$GOLDEN/patch-result-v1-$1.json"
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
    SHIM_PM_FAIL="$SHIM_PM_FAIL" \
    QUERY_LOG="$QUERY_LOG" \
    PKG_STATE="$PKG_STATE" \
    PKG_UPGRADES="$PKG_UPGRADES" \
    PM_HELPER="$PM_HELPER" \
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
assert_no_queries
grep -q '^apt-get -qq update' "$ARGV_LOG" || case_err "apt-get update was not invoked"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "install "
defer_no_reboot
end_case

begin_case "patch_ids=[openssl,curl], both installed: apt-get installs exactly those two names, no dist-upgrade"
PT_patch_ids='["openssl","curl"]'
pkg_installed openssl amd64 3.0.2-0ubuntu1.15
pkg_installed curl amd64 7.88.1-10
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- openssl curl"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "dist-upgrade"
end_case

begin_case "patch_ids=[openssl, curl] with spaces and no jq anywhere on PATH: selected install works"
PT_patch_ids='["openssl", "curl"]'
pkg_installed openssl amd64 3.0.2-0ubuntu1.15
pkg_installed curl amd64 7.88.1-10
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
pkg_installed g++ amd64 4:12.2.0-3
pkg_installed libstdc++6 amd64 12.2.0-14
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "apt argv" "$(cat "$ARGV_LOG")" "apt-get -y install --only-upgrade -- g++ libstdc++6"
end_case

begin_case "patch_ids=[a] (single character) is accepted"
PT_patch_ids='["a"]'
pkg_installed a amd64 1.0-1
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
pkg_installed openssl x86_64 1:3.5.1-1.el9
pkg_installed curl x86_64 7.76.1-29.el9
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "applied" "$(jf applied)" "selected"
assert_contains "dnf argv" "$(cat "$ARGV_LOG")" "dnf -y upgrade -- openssl curl"
end_case

begin_case "yum selected ids: the argv has -- before the ids"
PT_patch_ids='["openssl","curl"]'
RUN_PATH="$YUM_PATH"
pkg_installed openssl x86_64 1:3.5.1-1.el9
pkg_installed curl x86_64 7.76.1-29.el9
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

# --- per-package result contract v1 (77.1-02, D-16) ---------------------------------

# Every key of a v1 line: the seven existing keys, unchanged, plus the four new ones.
V1_KEYS='["applied","package_count","packages","packages_truncated","reboot_policy","reboot_required","reboot_status","reboot_status_reason","rebooting","result_version","status"]'

# check_v1_envelope APPLIED...: the run-level keys of a v1 line when nothing asked for a reboot.
check_v1_envelope() { # STATUS
  assert_eq "result keys" "$(printf '%s' "$OUT" | jq -c 'keys | sort' 2>/dev/null)" "$V1_KEYS"
  assert_eq "result_version" "$(jf result_version)" "1"
  assert_eq "status" "$(jf status)" "$1"
  assert_eq "applied" "$(jf applied)" "selected"
  assert_eq "reboot_policy" "$(jf reboot_policy)" "never"
  assert_eq "rebooting" "$(jf rebooting)" "false"
}

begin_case "campaign ids [openssl,curl] on apt: openssl updated with before and after, curl skipped not_installed and never reaches apt"
PT_patch_ids='["openssl","curl"]'
pkg_installed openssl amd64 3.0.2-0ubuntu1.15
pkg_upgrade openssl 3.0.2-0ubuntu1.18
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
check_v1_envelope patched
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl","arch":"amd64","before":"3.0.2-0ubuntu1.15","after":"3.0.2-0ubuntu1.18","status":"updated"},{"name":"curl","arch":"","before":"","after":"","status":"skipped","reason":"not_installed"}]'
assert_eq "package_count" "$(jf package_count)" "2"
assert_eq "packages_truncated" "$(jf packages_truncated)" "false"
assert_eq "apt install argv" "$(grep '^apt-get -y install' "$ARGV_LOG")" "apt-get -y install --only-upgrade -- openssl"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "curl"
golden apt-updated
defer_no_reboot
end_case

begin_case "campaign ids with nothing installed (one missing, one removed with config files left): apt install is never called, every entry skipped not_installed, exit 0"
PT_patch_ids='["openssl","curl"]'
pkg_installed curl amd64 7.88.1-10 rc
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
check_v1_envelope patched
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl","arch":"","before":"","after":"","status":"skipped","reason":"not_installed"},{"name":"curl","arch":"","before":"","after":"","status":"skipped","reason":"not_installed"}]'
assert_eq "package_count" "$(jf package_count)" "2"
assert_not_contains "apt argv" "$(cat "$ARGV_LOG")" "install "
golden apt-skipped
defer_no_reboot
end_case

begin_case "campaign id installed with no newer version: unchanged, before equals after"
PT_patch_ids='["openssl"]'
pkg_installed openssl amd64 3.0.2-0ubuntu1.18
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl","arch":"amd64","before":"3.0.2-0ubuntu1.18","after":"3.0.2-0ubuntu1.18","status":"unchanged"}]'
defer_no_reboot
end_case

begin_case "campaign id installed for two architectures: one entry per architecture, each with its own versions"
PT_patch_ids='["libc6"]'
pkg_installed libc6 amd64 2.36-9
pkg_installed libc6 i386 2.36-9
pkg_upgrade libc6 2.36-9+deb12u14
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"libc6","arch":"amd64","before":"2.36-9","after":"2.36-9+deb12u14","status":"updated"},{"name":"libc6","arch":"i386","before":"2.36-9","after":"2.36-9+deb12u14","status":"updated"}]'
assert_eq "package_count" "$(jf package_count)" "2"
defer_no_reboot
end_case

begin_case "the same id twice is queried and reported once"
PT_patch_ids='["openssl","openssl"]'
pkg_installed openssl amd64 3.0.2-0ubuntu1.15
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "package_count" "$(jf package_count)" "1"
defer_no_reboot
end_case

begin_case "hostile version text (quote, backslash, control byte) stays valid one-line JSON"
PT_patch_ids='["openssl"]'
printf 'openssl|amd64|1.0"x\\y\001z|ii\n' >> "$PKG_STATE"
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
assert_eq "before" "$(printf '%s' "$OUT" | jq -r '.packages[0].before' 2>/dev/null)" '1.0"x\yz'
assert_eq "status" "$(printf '%s' "$OUT" | jq -r '.packages[0].status' 2>/dev/null)" "unchanged"
defer_no_reboot
end_case

begin_case "security_only=true with no patch_ids: the legacy key set, no result_version, no packages, no package database query"
PT_security_only=true
run_patch
assert_eq "exit status" "$RC" "0"
assert_eq "stdout" "$OUT" '{"status": "patched", "applied": "security", "reboot_policy": "never", "reboot_status": "unknown", "reboot_status_reason": "no_marker_writer", "reboot_required": false, "rebooting": false}'
assert_no_queries
defer_no_reboot
end_case

begin_case "dnf campaign ids [openssl-libs,nano]: openssl-libs updated with epoch-prefixed versions, nano skipped not_installed and never reaches dnf"
PT_patch_ids='["openssl-libs","nano"]'
RUN_PATH="$DNF_PATH"
pkg_installed openssl-libs x86_64 1:3.5.1-1.el9
pkg_upgrade openssl-libs 1:3.5.9-1.el9_9
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
check_v1_envelope patched
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl-libs","arch":"x86_64","before":"1:3.5.1-1.el9","after":"1:3.5.9-1.el9_9","status":"updated"},{"name":"nano","arch":"","before":"","after":"","status":"skipped","reason":"not_installed"}]'
assert_eq "package_count" "$(jf package_count)" "2"
assert_eq "dnf install argv" "$(grep '^dnf -y upgrade' "$ARGV_LOG")" "dnf -y upgrade -- openssl-libs"
assert_not_contains "dnf argv" "$(cat "$ARGV_LOG")" "nano"
golden dnf-updated
defer_no_reboot
end_case

begin_case "yum campaign ids [openssl-libs,nano]: openssl-libs updated with epoch-prefixed versions, nano skipped not_installed and never reaches yum"
PT_patch_ids='["openssl-libs","nano"]'
RUN_PATH="$YUM_PATH"
pkg_installed openssl-libs x86_64 1:3.5.1-1.el9
pkg_upgrade openssl-libs 1:3.5.9-1.el9_9
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
check_v1_envelope patched
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl-libs","arch":"x86_64","before":"1:3.5.1-1.el9","after":"1:3.5.9-1.el9_9","status":"updated"},{"name":"nano","arch":"","before":"","after":"","status":"skipped","reason":"not_installed"}]'
assert_eq "yum install argv" "$(grep '^yum -y update' "$ARGV_LOG")" "yum -y update -- openssl-libs"
assert_not_contains "yum argv" "$(cat "$ARGV_LOG")" "nano"
golden yum-updated
defer_no_reboot
end_case

begin_case "dnf campaign ids with nothing installed: dnf upgrade is never called, every entry skipped not_installed, exit 0"
PT_patch_ids='["openssl-libs","nano"]'
RUN_PATH="$DNF_PATH"
run_patch
assert_eq "exit status" "$RC" "0"
check_v1_envelope patched
assert_eq "package_count" "$(jf package_count)" "2"
assert_not_contains "dnf argv" "$(cat "$ARGV_LOG")" "upgrade"
defer_no_reboot
end_case

begin_case "apt failure: one line with status failed, the unchanged package failed package_manager_error, exit 1, no reboot even with reboot=always"
PT_patch_ids='["openssl"]'
PT_reboot=always
SHIM_APT_FAIL=1
writer_present
pkg_installed openssl amd64 3.0.2-0ubuntu1.15
pkg_upgrade openssl 3.0.2-0ubuntu1.18
run_patch
assert_eq "exit status" "$RC" "1"
assert_one_line
assert_eq "result keys" "$(printf '%s' "$OUT" | jq -c 'keys | sort' 2>/dev/null)" "$V1_KEYS"
assert_eq "status" "$(jf status)" "failed"
assert_eq "result_version" "$(jf result_version)" "1"
assert_eq "rebooting" "$(jf rebooting)" "false"
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl","arch":"amd64","before":"3.0.2-0ubuntu1.15","after":"3.0.2-0ubuntu1.15","status":"failed","reason":"package_manager_error"}]'
assert_not_contains "stdout" "$OUT" "E: "
golden apt-failed
defer_no_reboot
end_case

begin_case "dnf failure: one line with status failed, exit 1, the package that did not change failed package_manager_error"
PT_patch_ids='["openssl-libs"]'
RUN_PATH="$DNF_PATH"
SHIM_PM_FAIL=1
pkg_installed openssl-libs x86_64 1:3.5.1-1.el9
pkg_upgrade openssl-libs 1:3.5.9-1.el9_9
run_patch
assert_eq "exit status" "$RC" "1"
assert_one_line
assert_eq "status" "$(jf status)" "failed"
assert_eq "packages" "$(printf '%s' "$OUT" | jq -c '.packages' 2>/dev/null)" '[{"name":"openssl-libs","arch":"x86_64","before":"1:3.5.1-1.el9","after":"1:3.5.1-1.el9","status":"failed","reason":"package_manager_error"}]'
defer_no_reboot
end_case

begin_case "501 installed ids: packages is capped at 500, package_count 501, packages_truncated true"
_ids=""
_i=1
while [ "$_i" -le 501 ]; do
  _ids="${_ids}${_ids:+,}\"pkg$_i\""
  pkg_installed "pkg$_i" amd64 1.0-1
  _i=$((_i + 1))
done
PT_patch_ids="[$_ids]"
run_patch
assert_eq "exit status" "$RC" "0"
assert_one_line
assert_eq "packages listed" "$(printf '%s' "$OUT" | jq '.packages | length' 2>/dev/null)" "500"
assert_eq "package_count" "$(jf package_count)" "501"
assert_eq "packages_truncated" "$(jf packages_truncated)" "true"
golden truncated
defer_no_reboot
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
