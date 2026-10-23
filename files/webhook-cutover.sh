#!/bin/sh
# stagehand-webhook-cutover: the guarded steps of moving a primary from the old
# webhook-go service (running as root) to the Stagehand deploy agent
# (Phase 57.6.2 D-02, D-01). Installed by stagehand::webhook at
# /usr/local/sbin/stagehand-webhook-cutover (root, 0750). Puppet calls it; it is
# safe for an operator to run by hand too.
#
# The rule it enforces: nothing destructive happens while a deploy is running.
# webhook-go takes flock(2) on <legacy state dir>/deploy.lock for the whole of
# an engine run, and so does the agent on <state dir>/deploy.lock. flock(1)
# takes the same lock, so holding it here is mutual exclusion with a deploy.
# When the lock is busy every subcommand that would change something exits 75,
# prints one line saying so ("nothing was changed"), and Puppet skips
# everything that depends on it.
#
# Subcommands:
#   has-legacy
#       exit 0 when the webhook-go.service unit exists (systemctl cat), else 1
#   stop-legacy LEGACY_STATE_DIR
#       no legacy unit: exit 0. Otherwise, holding LEGACY_STATE_DIR/deploy.lock
#       (flock -n, exit 75 when a deploy holds it): copy the legacy config to
#       LEGACY_STATE_DIR/webhook.yml.pre-agent (0600, the rollback copy), then
#       systemctl stop and disable webhook-go.service. If LEGACY_STATE_DIR does
#       not exist, a service that is not running is the never-started case: the
#       directory is created (0700) to hold the rollback copy and the steps
#       above run as normal. A running service is refused (exit 1, nothing
#       changed), because its lock lives somewhere else, which means
#       legacy_state_dir is wrong.
#   import LEGACY_STATE_DIR CONFIG MARKER
#       run `stagehand-deploy-agent import-history --from LEGACY/jobs --config
#       CONFIG` when LEGACY/jobs exists, then create MARKER. The legacy directory
#       is only read, never changed: it stays as the rollback source.
#   owned RUN_AS DIR...
#       exit 0 when nothing in any DIR, to a depth of 3, belongs to another user
#       than RUN_AS; exit 1 when something does, or when a DIR cannot be read
#   own LOCK RUN_AS GROUP DIR...
#       chown -R RUN_AS:GROUP DIR... while holding LOCK (the agent's deploy
#       lock), flock -n, exit 75 when a deploy holds it
#
# Environment overrides, for tests (the convention tasks/discover.sh follows):
#   STAGEHAND_CUTOVER_SYSTEMCTL   default /usr/bin/systemctl
#   STAGEHAND_CUTOVER_AGENT       default /usr/bin/stagehand-deploy-agent
#   STAGEHAND_CUTOVER_FLOCK       default /usr/bin/flock
#   STAGEHAND_CUTOVER_CHOWN       default /usr/bin/chown
#   STAGEHAND_CUTOVER_LEGACY_CONFIG  default /etc/voxpupuli/webhook.yml
#
# Exit codes: 0 done, 1 failed, 2 usage, 75 a deploy is running (nothing changed).
#
# It reads and writes nothing under any user's home directory (D-03).

set -eu

# Everything this script creates (the config copy, the marker, a lock file) is
# private to root unless a step below says otherwise.
umask 077

SYSTEMCTL=${STAGEHAND_CUTOVER_SYSTEMCTL:-/usr/bin/systemctl}
AGENT=${STAGEHAND_CUTOVER_AGENT:-/usr/bin/stagehand-deploy-agent}
FLOCK=${STAGEHAND_CUTOVER_FLOCK:-/usr/bin/flock}
CHOWN=${STAGEHAND_CUTOVER_CHOWN:-/usr/bin/chown}
LEGACY_CONFIG=${STAGEHAND_CUTOVER_LEGACY_CONFIG:-/etc/voxpupuli/webhook.yml}
LEGACY_UNIT=webhook-go.service

usage() {
  cat >&2 <<'EOF'
usage: stagehand-webhook-cutover has-legacy
       stagehand-webhook-cutover stop-legacy LEGACY_STATE_DIR
       stagehand-webhook-cutover import LEGACY_STATE_DIR CONFIG MARKER
       stagehand-webhook-cutover owned RUN_AS DIR...
       stagehand-webhook-cutover own LOCK RUN_AS GROUP DIR...
EOF
  exit 2
}

die() {
  printf 'stagehand-webhook-cutover: %s\n' "$*" >&2
  exit 1
}

has_legacy() {
  "$SYSTEMCTL" cat "$LEGACY_UNIT" >/dev/null 2>&1
}

# Runs with the legacy deploy lock held (re-executed under flock by stop-legacy,
# which is why this is a subcommand and not just a function).
stop_locked() {
  if [ -f "$LEGACY_CONFIG" ]; then
    cp "$LEGACY_CONFIG" "$1/webhook.yml.pre-agent"
    chmod 0600 "$1/webhook.yml.pre-agent"
  fi
  "$SYSTEMCTL" stop "$LEGACY_UNIT"
  "$SYSTEMCTL" disable "$LEGACY_UNIT"
}

cmd_stop_legacy() {
  [ $# -eq 1 ] || usage
  legacy=$1
  has_legacy || exit 0

  if [ ! -d "$legacy" ]; then
    # No state directory means no lock file to hold. That is only believable
    # for a unit that never ran; a running one is using some other directory.
    if "$SYSTEMCTL" is-active --quiet "$LEGACY_UNIT"; then
      die "$LEGACY_UNIT is running but legacy_state_dir '$legacy' does not exist, so its deploy lock cannot be located; set legacy_state_dir to the state directory webhook-go uses (nothing was changed)"
    fi
    mkdir -p "$legacy"
  fi

  rc=0
  "$FLOCK" -n -E 75 "$legacy/deploy.lock" /bin/sh "$0" _stop-locked "$legacy" || rc=$?
  if [ "$rc" -eq 75 ]; then
    printf 'stagehand-webhook-cutover: a deploy is running on webhook-go; apply again when it finishes (nothing was changed)\n' >&2
    exit 75
  fi
  exit "$rc"
}

cmd_import() {
  [ $# -eq 3 ] || usage
  legacy=$1
  config=$2
  marker=$3
  if [ -d "$legacy/jobs" ]; then
    "$AGENT" import-history --from "$legacy/jobs" --config "$config"
  fi
  : > "$marker"
}

cmd_owned() {
  [ $# -ge 2 ] || usage
  run_as=$1
  shift
  for dir in "$@"; do
    # A directory that is missing or unreadable counts as not owned, so the
    # chown step runs (and fails loudly) instead of the check passing on nothing.
    [ -d "$dir" ] || return 1
    found=$(find "$dir" -maxdepth 3 ! -user "$run_as" -print -quit 2>/dev/null) || return 1
    [ -z "$found" ] || return 1
  done
  return 0
}

cmd_own() {
  [ $# -ge 4 ] || usage
  lock=$1
  run_as=$2
  group=$3
  shift 3
  rc=0
  "$FLOCK" -n -E 75 "$lock" "$CHOWN" -R "$run_as:$group" "$@" || rc=$?
  if [ "$rc" -eq 75 ]; then
    printf 'stagehand-webhook-cutover: a deploy is running on the agent; apply again when it finishes (nothing was changed)\n' >&2
    exit 75
  fi
  exit "$rc"
}

[ $# -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  has-legacy)
    [ $# -eq 0 ] || usage
    has_legacy
    ;;
  stop-legacy) cmd_stop_legacy "$@" ;;
  _stop-locked)
    [ $# -eq 1 ] || usage
    stop_locked "$1"
    ;;
  import) cmd_import "$@" ;;
  owned)
    cmd_owned "$@"
    ;;
  own) cmd_own "$@" ;;
  *) usage ;;
esac
