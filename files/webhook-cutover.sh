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
#       refuse (exit 1, nothing changed) unless fs.protected_hardlinks is 1;
#       then, holding LOCK (the agent's deploy lock; flock -n, exit 75 when a
#       deploy holds it), chown -h RUN_AS:GROUP every directory and every singly
#       linked entry under each DIR on its own filesystem. Never chown -R: the
#       agent user can write in these trees. A file with more than one hard
#       link is left as it is and named on stderr (T-57.6.2-42).
#
# Environment overrides, for tests (the convention tasks/discover.sh follows):
#   STAGEHAND_CUTOVER_SYSTEMCTL   default /usr/bin/systemctl
#   STAGEHAND_CUTOVER_AGENT       default /usr/bin/stagehand-deploy-agent
#   STAGEHAND_CUTOVER_FLOCK       default /usr/bin/flock
#   STAGEHAND_CUTOVER_CHOWN       default /usr/bin/chown
#   STAGEHAND_CUTOVER_LEGACY_CONFIG  default /etc/voxpupuli/webhook.yml
#   STAGEHAND_CUTOVER_PROTECTED_HARDLINKS  default /proc/sys/fs/protected_hardlinks
#   STAGEHAND_CUTOVER_ID          default /usr/bin/id
#   STAGEHAND_CUTOVER_RUNUSER     default /usr/sbin/runuser
#   STAGEHAND_CUTOVER_LOCK_WAIT   default 30 (seconds own waits for the agent user's flock to answer)
#
# Exit codes: 0 done, 1 failed, 2 usage, 75 a deploy is running (nothing changed).
#
# It reads and writes nothing under any user's home directory (D-03).

set -eu

# Puppet and cron give a script a bare environment; find, cp and the rest come
# from the system directories.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Everything this script creates (the config copy, the marker, a lock file) is
# private to root unless a step below says otherwise.
umask 077

SYSTEMCTL=${STAGEHAND_CUTOVER_SYSTEMCTL:-/usr/bin/systemctl}
AGENT=${STAGEHAND_CUTOVER_AGENT:-/usr/bin/stagehand-deploy-agent}
FLOCK=${STAGEHAND_CUTOVER_FLOCK:-/usr/bin/flock}
CHOWN=${STAGEHAND_CUTOVER_CHOWN:-/usr/bin/chown}
LEGACY_CONFIG=${STAGEHAND_CUTOVER_LEGACY_CONFIG:-/etc/voxpupuli/webhook.yml}
PROTECTED_HARDLINKS=${STAGEHAND_CUTOVER_PROTECTED_HARDLINKS:-/proc/sys/fs/protected_hardlinks}
ID=${STAGEHAND_CUTOVER_ID:-/usr/bin/id}
RUNUSER=${STAGEHAND_CUTOVER_RUNUSER:-/usr/sbin/runuser}
LOCK_WAIT=${STAGEHAND_CUTOVER_LOCK_WAIT:-30}
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

  # flock(1) creates its lock path and follows symlinks. That is safe here only
  # because nobody but root can write this directory (webhook-go ran as root);
  # refuse rather than lock somewhere another user could plant a link
  # (T-57.6.2-53).
  [ -L "$legacy" ] && die "legacy_state_dir '$legacy' is a symlink; point it at the real directory (nothing was changed)"
  legacy_mode=$(stat -c '%u %a' "$legacy") || die "cannot read legacy_state_dir '$legacy' (nothing was changed)"
  case "$legacy_mode" in
    "$("$ID" -u) "[0-7][0-7][0-7]) ;;
    *) die "legacy_state_dir '$legacy' is not owned by root, so its deploy lock is not safe to take as root (nothing was changed)" ;;
  esac
  case "${legacy_mode#* }" in
    [0-7][0145][0145]) ;;
    *) die "legacy_state_dir '$legacy' is writable by its group or by everyone, so its deploy lock is not safe to take as root (nothing was changed)" ;;
  esac

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

# Runs with the agent's deploy lock held (re-executed under flock by own). The
# agent user can write inside these trees, so root never follows a link out of
# them and never hands over a file that has a second name: chown -h on each
# directory and each singly linked entry, on this filesystem only. A file with
# more than one link is left alone and named, because its other name may be
# /etc/shadow (T-57.6.2-42).
#
# -execdir, not -exec: find runs chown from inside the directory it already
# opened, with a ./name argument, so chown resolves one component and -h stops
# it following that one. With -exec, chown would re-resolve the whole path,
# and a directory on it swapped for a symlink after find looked would send a
# root chown anywhere (T-57.6.2-43). PATH is absolute above, which -execdir
# requires.
own_locked() {
  run_as=$1
  group=$2
  shift 2
  for dir in "$@"; do
    find "$dir" -xdev \( -type d -o -links 1 \) -execdir "$CHOWN" -h "$run_as:$group" {} +
    find "$dir" -xdev ! -type d -links +1 -print | while IFS= read -r skipped; do
      printf 'stagehand-webhook-cutover: left %s as it is: it has more than one hard link\n' "$skipped" >&2
    done
  done
}

cmd_own() {
  [ $# -ge 4 ] || usage
  lock=$1
  run_as=$2
  group=$3
  shift 3
  # Skipping hard-linked files is only a backstop. With protected_hardlinks on
  # (the systemd default) the agent user cannot link to a file it does not own
  # at all; without it, refuse rather than walk a tree it could have seeded.
  hardlinks=$(cat "$PROTECTED_HARDLINKS" 2>/dev/null) || hardlinks=
  [ "$hardlinks" = 1 ] || die "fs.protected_hardlinks is not 1 (read '${hardlinks:-nothing}' from $PROTECTED_HARDLINKS), so handing these directories to $run_as as root is not safe; set it with sysctl and apply again (nothing was changed)"
  # The lock lives in a directory the agent user can write. Root never opens
  # that path: flock(1) would create it and follow a symlink (T-57.6.2-53), and
  # even a read-only open after a check can be raced onto a device node or a
  # FIFO (T-57.6.2-54). The agent user's own flock(1) takes the lock instead,
  # with only that user's rights (creating the file, 0600, if the agent has not
  # deployed yet), and holds it while root works: it reports "locked" through a
  # pipe in a root-only temporary directory, and the lock is released when root
  # closes the other pipe. flock(2) on the same file excludes a deploy whichever
  # process holds it. The checks below only give a clear message for the
  # common cases; the safety comes from who opens the file.
  agent_uid=$("$ID" -u "$run_as") || die "user $run_as does not exist (nothing was changed)"
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    [ -L "$lock" ] && die "the deploy lock $lock is a symlink; remove it and apply again (nothing was changed)"
    [ -f "$lock" ] || die "the deploy lock $lock is not a regular file; remove it and apply again (nothing was changed)"
    [ "$(stat -c '%u' "$lock")" = "$agent_uid" ] || die "the deploy lock $lock is not owned by $run_as; remove it and apply again (nothing was changed)"
  fi
  pipes=$(mktemp -d) || die "cannot create a private directory for the lock handshake (nothing was changed)"
  trap 'rm -rf "$pipes"' EXIT
  mkfifo "$pipes/ready" "$pipes/release" || die "cannot create the lock handshake pipes (nothing was changed)"
  # shellcheck disable=SC2016 # $0 and the redirections are for the inner sh, on purpose
  "$RUNUSER" -u "$run_as" -- "$FLOCK" -n -E 75 "$lock" \
    /bin/sh -c 'printf "locked\n"; read -r _ <&3' 3<"$pipes/release" >"$pipes/ready" 2>/dev/null &
  holder=$!
  exec 8>"$pipes/release"
  exec 7<"$pipes/ready"
  answer=$(timeout "$LOCK_WAIT" head -n 1 <&7) || answer=
  if [ "$answer" != locked ]; then
    exec 8>&-
    hrc=0
    if kill -0 "$holder" 2>/dev/null; then
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      die "the deploy lock $lock did not answer within ${LOCK_WAIT}s (nothing was changed)"
    fi
    wait "$holder" || hrc=$?
    if [ "$hrc" -eq 75 ]; then
      printf 'stagehand-webhook-cutover: a deploy is running on the agent; apply again when it finishes (nothing was changed)\n' >&2
      exit 75
    fi
    die "could not take the deploy lock $lock as $run_as (exit $hrc; nothing was changed)"
  fi
  rc=0
  /bin/sh "$0" _own-locked "$run_as" "$group" "$@" || rc=$?
  exec 8>&-
  wait "$holder" 2>/dev/null || true
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
  _own-locked)
    [ $# -ge 3 ] || usage
    own_locked "$@"
    ;;
  *) usage ;;
esac
