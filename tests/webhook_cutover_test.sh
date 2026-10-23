#!/bin/sh
# Proof that files/webhook-cutover.sh never stops the old webhook-go service
# while a deploy holds its lock, and never hands over ownership while an agent
# deploy holds the agent's lock (Phase 57.6.2 D-02, D-01; threats T-57.6.2-38,
# T-57.6.2-39).
#
# POSIX sh. The script under test is driven through its environment overrides
# (STAGEHAND_CUTOVER_SYSTEMCTL, _AGENT, _CHOWN, _LEGACY_CONFIG), the same
# convention discover_test.sh uses, so nothing here touches a real service or a
# real file outside a mktemp sandbox. The lock cases use the real flock(1): a
# background holder keeps the lock file locked exactly as the fork (flock(2))
# and the agent do while they run an engine.
#
# Cases:
#   1  has-legacy: exit 0 when `systemctl cat webhook-go.service` succeeds, 1 when not
#   2  stop-legacy with no legacy unit: exit 0, no stop and no disable
#   3  stop-legacy, lock free: stop then disable (in that order), config copied
#      to webhook.yml.pre-agent with mode 0600, exit 0
#   4  stop-legacy, lock HELD: exit 75, message names the running deploy and
#      "nothing was changed", no stop, no disable, no copy
#   5  stop-legacy, state dir missing and service inactive (never started):
#      the directory is created, config copied, service stopped and disabled
#   6  stop-legacy, state dir missing and service active: exit 1, nothing called
#   7  import with a jobs directory: agent called with the exact arguments,
#      marker created; without one: agent not called, marker created; agent
#      failing: exit non-zero and no marker
#   8  owned: 0 when everything to depth 3 belongs to the user, 1 otherwise, 1
#      for a missing directory (as root also: depth 3 counts, depth 4 does not)
#   9  own, agent lock HELD: exit 75, no chown; lock free: chown -h user:group on
#      each directory and each singly linked entry, never -R, never a
#      hard-linked file (named on stderr instead); protected_hardlinks off or
#      unreadable: exit 1, no chown; chown only ever gets ./name from inside the
#      entry's own directory (find -execdir), never a multi-component path
#  10  usage: unknown subcommand and missing arguments exit 2
#
# The last line is `PASS: webhook cutover` on success.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
CUTOVER="$SCRIPT_DIR/../files/webhook-cutover.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*"; }

[ -f "$CUTOVER" ] || fail "webhook-cutover.sh not found at $CUTOVER"
command -v flock >/dev/null 2>&1 || fail "flock(1) not found; run this test where util-linux is installed (the module container, or CI)"

WORK=$(mktemp -d) || fail "mktemp -d failed"
HOLDER_PID=""
cleanup() {
  [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

SHIMDIR="$WORK/shims"
mkdir -p "$SHIMDIR" || fail "could not create shim dir"

SYSTEMCTL_LOG="$WORK/systemctl.log"
AGENT_LOG="$WORK/agent.log"
CHOWN_LOG="$WORK/chown.log"
export SYSTEMCTL_LOG AGENT_LOG CHOWN_LOG

# systemctl stub: logs its arguments; `cat` succeeds only when SHIM_LEGACY=present,
# `is-active` succeeds only when SHIM_ACTIVE=yes.
cat > "$SHIMDIR/systemctl" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
  cat) [ "${SHIM_LEGACY:-absent}" = present ] ;;
  is-active) [ "${SHIM_ACTIVE:-no}" = yes ] ;;
  *) exit 0 ;;
esac
SHIM

# agent stub: logs its arguments, exits SHIM_AGENT_RC (default 0), prints the
# one-line report the real import-history prints.
cat > "$SHIMDIR/stagehand-deploy-agent" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$AGENT_LOG"
printf 'imported 3; skipped 0 already present, 0 unfinished, 0 unreadable\n'
exit "${SHIM_AGENT_RC:-0}"
SHIM

# chown stub: logs its arguments, with each ./name argument resolved against
# the directory it ran in, and records any path argument that has a directory
# part (a root chown must only ever see ./name, T-57.6.2-43).
cat > "$SHIMDIR/chown" <<'SHIM'
#!/bin/sh
here=$(pwd -P)
line=""
for a in "$@"; do
  case "$a" in
    ./*/*) printf '%s\n' "$a" >> "$CHOWN_LOG.multi" ; line="$line $a" ;;
    ./*) line="$line $here/${a#./}" ;;
    /*) printf '%s\n' "$a" >> "$CHOWN_LOG.multi" ; line="$line $a" ;;
    *) line="$line $a" ;;
  esac
done
printf '%s\n' "${line# }" >> "$CHOWN_LOG"
SHIM

chmod 0755 "$SHIMDIR/systemctl" "$SHIMDIR/stagehand-deploy-agent" "$SHIMDIR/chown"

STAGEHAND_CUTOVER_SYSTEMCTL="$SHIMDIR/systemctl"
STAGEHAND_CUTOVER_AGENT="$SHIMDIR/stagehand-deploy-agent"
STAGEHAND_CUTOVER_CHOWN="$SHIMDIR/chown"
export STAGEHAND_CUTOVER_SYSTEMCTL STAGEHAND_CUTOVER_AGENT STAGEHAND_CUTOVER_CHOWN

reset_logs() { : > "$SYSTEMCTL_LOG"; : > "$AGENT_LOG"; : > "$CHOWN_LOG"; rm -f "$CHOWN_LOG.multi"; }

# run_cutover <stderr file> <args...>: runs the script, sets RC.
run_cutover() {
  errfile=$1
  shift
  RC=0
  sh "$CUTOVER" "$@" >"$WORK/stdout" 2>"$errfile" || RC=$?
}

expect_rc() { # <label> <wanted>
  [ "$RC" -eq "$2" ] || fail "$1: expected exit $2, got $RC (stderr: $(cat "$WORK/stderr" 2>/dev/null))"
}

# hold_lock <file>: a real flock(1) holder in the background, and wait until the
# lock is really taken, so the case under test cannot race the holder. The
# holder runs until its sentinel file is removed (release_lock); killing it
# would not do, because flock(1) may run its command as a child and the child
# would keep the lock.
hold_lock() {
  : > "$WORK/hold"
  # shellcheck disable=SC2016 # $0 is expanded by the inner sh, on purpose
  flock "$1" sh -c 'while [ -e "$0" ]; do sleep 0.05; done' "$WORK/hold" &
  HOLDER_PID=$!
  tries=0
  while flock -n "$1" true 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "the lock holder never took $1"
    sleep 0.05
  done
}
release_lock() {
  rm -f "$WORK/hold"
  wait "$HOLDER_PID" 2>/dev/null
  HOLDER_PID=""
}

LEGACY="$WORK/webhook-go"
mkdir -p "$LEGACY" || fail "mkdir legacy"
LEGACY_CONFIG="$WORK/webhook.yml"
printf 'server:\n  port: 8088\n' > "$LEGACY_CONFIG"
STAGEHAND_CUTOVER_LEGACY_CONFIG="$LEGACY_CONFIG"
export STAGEHAND_CUTOVER_LEGACY_CONFIG

# fs.protected_hardlinks, as own reads it; on (1) unless a case says otherwise.
HARDLINKS_ON="$WORK/protected_hardlinks"
printf '1\n' > "$HARDLINKS_ON"
STAGEHAND_CUTOVER_PROTECTED_HARDLINKS="$HARDLINKS_ON"
export STAGEHAND_CUTOVER_PROTECTED_HARDLINKS

# --- 1. has-legacy ---------------------------------------------------------
info "1. has-legacy"
reset_logs
SHIM_LEGACY=present run_cutover "$WORK/stderr" has-legacy
expect_rc "has-legacy with the unit present" 0
grep -qx 'cat webhook-go.service' "$SYSTEMCTL_LOG" || fail "has-legacy did not ask systemctl cat webhook-go.service"
SHIM_LEGACY=absent run_cutover "$WORK/stderr" has-legacy
expect_rc "has-legacy with no unit" 1

# --- 2. stop-legacy, nothing to stop ----------------------------------------
info "2. stop-legacy with no legacy unit"
reset_logs
SHIM_LEGACY=absent run_cutover "$WORK/stderr" stop-legacy "$LEGACY"
expect_rc "stop-legacy with no unit" 0
grep -Eq '^(stop|disable) ' "$SYSTEMCTL_LOG" && fail "stop-legacy stopped or disabled something although there is no legacy unit"
[ -e "$LEGACY/webhook.yml.pre-agent" ] && fail "stop-legacy copied a config although there is no legacy unit"

# --- 3. stop-legacy, lock free ----------------------------------------------
info "3. stop-legacy with the lock free"
reset_logs
SHIM_LEGACY=present run_cutover "$WORK/stderr" stop-legacy "$LEGACY"
expect_rc "stop-legacy, lock free" 0
stop_line=$(grep -n '^stop webhook-go.service$' "$SYSTEMCTL_LOG" | cut -d: -f1)
disable_line=$(grep -n '^disable webhook-go.service$' "$SYSTEMCTL_LOG" | cut -d: -f1)
[ -n "$stop_line" ] || fail "stop-legacy did not call: systemctl stop webhook-go.service"
[ -n "$disable_line" ] || fail "stop-legacy did not call: systemctl disable webhook-go.service"
[ "$stop_line" -lt "$disable_line" ] || fail "stop-legacy disabled before it stopped"
[ -f "$LEGACY/webhook.yml.pre-agent" ] || fail "stop-legacy did not copy the legacy config to webhook.yml.pre-agent"
cmp -s "$LEGACY_CONFIG" "$LEGACY/webhook.yml.pre-agent" || fail "the config copy differs from the original"
[ -n "$(find "$LEGACY/webhook.yml.pre-agent" -perm 600)" ] || fail "webhook.yml.pre-agent must be mode 0600"
[ -f "$LEGACY_CONFIG" ] || fail "the original legacy config must stay in place"

# --- 4. stop-legacy, lock HELD ----------------------------------------------
info "4. stop-legacy with a deploy holding the fork's lock"
rm -f "$LEGACY/webhook.yml.pre-agent"
reset_logs
hold_lock "$LEGACY/deploy.lock"
SHIM_LEGACY=present run_cutover "$WORK/stderr" stop-legacy "$LEGACY"
release_lock
expect_rc "stop-legacy, lock held" 75
grep -q 'a deploy is running on webhook-go' "$WORK/stderr" || fail "the refusal does not say 'a deploy is running on webhook-go': $(cat "$WORK/stderr")"
grep -q 'nothing was changed' "$WORK/stderr" || fail "the refusal does not say 'nothing was changed': $(cat "$WORK/stderr")"
[ "$(wc -l < "$WORK/stderr" | tr -d ' ')" -eq 1 ] || fail "the refusal must be exactly one line: $(cat "$WORK/stderr")"
grep -Eq '^(stop|disable) ' "$SYSTEMCTL_LOG" && fail "a service was stopped or disabled while the fork's deploy lock was held: $(cat "$SYSTEMCTL_LOG")"
[ -e "$LEGACY/webhook.yml.pre-agent" ] && fail "the config was copied although the deploy lock was held"

# --- 5. state dir missing, service inactive -----------------------------------
info "5. stop-legacy, state directory missing, service not running"
reset_logs
SHIM_LEGACY=present SHIM_ACTIVE=no run_cutover "$WORK/stderr" stop-legacy "$WORK/never-started-state-dir"
expect_rc "stop-legacy, no state dir, inactive" 0
[ -f "$WORK/never-started-state-dir/webhook.yml.pre-agent" ] || fail "the rollback copy should be kept even when the state directory had to be created"
grep -qx 'stop webhook-go.service' "$SYSTEMCTL_LOG" || fail "an inactive unit with no state dir should still be stopped"
grep -qx 'disable webhook-go.service' "$SYSTEMCTL_LOG" || fail "an inactive unit with no state dir should still be disabled"

# --- 6. state dir missing, service active ------------------------------------
info "6. stop-legacy, state directory missing, service running"
reset_logs
SHIM_LEGACY=present SHIM_ACTIVE=yes run_cutover "$WORK/stderr" stop-legacy "$WORK/wrong-state-dir"
[ -e "$WORK/wrong-state-dir" ] && fail "a refused run must not create the state directory"
expect_rc "stop-legacy, no state dir, active" 1
grep -q 'legacy_state_dir' "$WORK/stderr" || fail "the message must name legacy_state_dir: $(cat "$WORK/stderr")"
grep -Eq '^(stop|disable) ' "$SYSTEMCTL_LOG" && fail "a running unit was stopped although its lock could not be located"

# --- 7. import ---------------------------------------------------------------
info "7. import"
CONFIG="$WORK/config.yml"
: > "$CONFIG"
MARKER="$WORK/imported.marker"
mkdir -p "$LEGACY/jobs"
reset_logs
run_cutover "$WORK/stderr" import "$LEGACY" "$CONFIG" "$MARKER"
expect_rc "import with jobs" 0
[ "$(cat "$AGENT_LOG")" = "import-history --from $LEGACY/jobs --config $CONFIG" ] || fail "import called the agent with the wrong arguments: $(cat "$AGENT_LOG")"
[ -f "$MARKER" ] || fail "import did not create the marker"
grep -q '^imported 3; skipped' "$WORK/stdout" || fail "the agent's one-line report should reach stdout: $(cat "$WORK/stdout")"

rm -f "$MARKER"
rm -rf "$LEGACY/jobs"
reset_logs
run_cutover "$WORK/stderr" import "$LEGACY" "$CONFIG" "$MARKER"
expect_rc "import without jobs" 0
[ -s "$AGENT_LOG" ] && fail "import called the agent although there is no jobs directory"
[ -f "$MARKER" ] || fail "import without jobs did not create the marker"

rm -f "$MARKER"
mkdir -p "$LEGACY/jobs"
reset_logs
SHIM_AGENT_RC=1 run_cutover "$WORK/stderr" import "$LEGACY" "$CONFIG" "$MARKER"
[ "$RC" -ne 0 ] || fail "import must fail when the agent fails"
[ -e "$MARKER" ] && fail "the marker was written although the import failed"

# --- 8. owned ----------------------------------------------------------------
info "8. owned"
me=$(id -un)
other=nobody
[ "$me" = nobody ] && other=root
TREE="$WORK/tree"
mkdir -p "$TREE/a" "$TREE/b/c/d" || fail "mkdir tree"
: > "$TREE/a/file"
run_cutover "$WORK/stderr" owned "$me" "$TREE" "$TREE/a"
expect_rc "owned, everything mine" 0
run_cutover "$WORK/stderr" owned "$other" "$TREE"
expect_rc "owned, everything somebody else's" 1
run_cutover "$WORK/stderr" owned "$me" "$TREE" "$WORK/no-such-dir"
expect_rc "owned, one directory missing" 1
if [ "$(id -u)" -eq 0 ]; then
  # Depth is counted from the directory itself: TREE/b/c is depth 2, TREE/b/c/d depth 3.
  mkdir -p "$TREE/b/c/d/e/f"
  chown "$other" "$TREE/b/c/d/e" || fail "chown for the depth case"
  run_cutover "$WORK/stderr" owned "$me" "$TREE"
  expect_rc "owned, a stranger's entry at depth 4 is outside the check" 0
  chown "$other" "$TREE/b/c/d" || fail "chown for the depth case"
  run_cutover "$WORK/stderr" owned "$me" "$TREE"
  expect_rc "owned, a stranger's entry at depth 3 is found" 1
else
  info "   (not root: the depth-3 boundary cases need chown, skipped here; the container run covers them)"
fi

# --- 9. own ---------------------------------------------------------------------
info "9. own"
AGENT_LOCK="$WORK/agent-deploy.lock"
reset_logs
hold_lock "$AGENT_LOCK"
run_cutover "$WORK/stderr" own "$AGENT_LOCK" agentuser puppet "$WORK/d1" "$WORK/d2"
release_lock
expect_rc "own, agent lock held" 75
grep -q 'a deploy is running on the agent' "$WORK/stderr" || fail "the refusal does not say 'a deploy is running on the agent': $(cat "$WORK/stderr")"
grep -q 'nothing was changed' "$WORK/stderr" || fail "the refusal does not say 'nothing was changed': $(cat "$WORK/stderr")"
[ -s "$CHOWN_LOG" ] && fail "chown ran while the agent's deploy lock was held: $(cat "$CHOWN_LOG")"

# Lock free. The trees hold a plain file, a nested directory, a symlink and a
# hard-linked pair. A root walk must not follow the link or hand over a file
# with a second name: on a box without protected_hardlinks the agent user could
# make that second name point at /etc/shadow (T-57.6.2-42).
mkdir -p "$WORK/d1/sub" "$WORK/d2" || fail "mkdir own trees"
: > "$WORK/d1/a"
: > "$WORK/d1/sub/b"
ln -s /etc/passwd "$WORK/d1/link" || fail "symlink fixture"
: > "$WORK/d2/x"
ln "$WORK/d2/x" "$WORK/d2/x.link" || fail "hard link fixture"
printf '1\n' > "$HARDLINKS_ON"

reset_logs
run_cutover "$WORK/stderr" own "$AGENT_LOCK" agentuser puppet "$WORK/d1" "$WORK/d2"
expect_rc "own, lock free" 0
grep -q -- '-R' "$CHOWN_LOG" && fail "own used a recursive chown: $(cat "$CHOWN_LOG")"
grep -v -q -- '^-h agentuser:puppet ' "$CHOWN_LOG" && fail "own called chown without -h user:group: $(cat "$CHOWN_LOG")"
for p in "$WORK/d1" "$WORK/d1/a" "$WORK/d1/sub" "$WORK/d1/sub/b" "$WORK/d1/link" "$WORK/d2"; do
  tr ' ' '\n' < "$CHOWN_LOG" | grep -qx "$p" || fail "own did not hand over $p: $(cat "$CHOWN_LOG")"
done
tr ' ' '\n' < "$CHOWN_LOG" | grep -q "^$WORK/d2/x" && fail "own handed over a hard-linked file: $(cat "$CHOWN_LOG")"
grep -q "$WORK/d2/x" "$WORK/stderr" || fail "own did not name the skipped hard-linked file: $(cat "$WORK/stderr")"
[ -s "$CHOWN_LOG.multi" ] && fail "own passed chown a path with directory parts, which a swapped symlink in the tree could redirect: $(cat "$CHOWN_LOG.multi")"

# protected_hardlinks off, or unreadable: refuse before any chown.
printf '0\n' > "$HARDLINKS_ON"
reset_logs
run_cutover "$WORK/stderr" own "$AGENT_LOCK" agentuser puppet "$WORK/d1" "$WORK/d2"
expect_rc "own, protected_hardlinks off" 1
grep -q 'protected_hardlinks' "$WORK/stderr" || fail "the refusal does not name protected_hardlinks: $(cat "$WORK/stderr")"
[ -s "$CHOWN_LOG" ] && fail "chown ran with protected_hardlinks off: $(cat "$CHOWN_LOG")"

rm -f "$HARDLINKS_ON"
reset_logs
run_cutover "$WORK/stderr" own "$AGENT_LOCK" agentuser puppet "$WORK/d1" "$WORK/d2"
expect_rc "own, protected_hardlinks unreadable" 1
[ -s "$CHOWN_LOG" ] && fail "chown ran with protected_hardlinks unreadable: $(cat "$CHOWN_LOG")"
printf '1\n' > "$HARDLINKS_ON"

# --- 10. usage --------------------------------------------------------------
info "10. usage"
run_cutover "$WORK/stderr" frobnicate
expect_rc "unknown subcommand" 2
run_cutover "$WORK/stderr"
expect_rc "no subcommand" 2
run_cutover "$WORK/stderr" stop-legacy
expect_rc "stop-legacy without its argument" 2
run_cutover "$WORK/stderr" import "$LEGACY"
expect_rc "import without its arguments" 2
run_cutover "$WORK/stderr" owned "$me"
expect_rc "owned without a directory" 2
run_cutover "$WORK/stderr" own "$AGENT_LOCK" agentuser puppet
expect_rc "own without a directory" 2

printf 'PASS: webhook cutover\n'
