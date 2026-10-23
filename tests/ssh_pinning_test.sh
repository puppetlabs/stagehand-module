#!/bin/sh
# Proof that the ssh_config stagehand::webhook renders pins git's host-key
# checking no matter what other ssh configuration exists (D-03, MOD-WR-01).
#
# `ssh -G` prints the options ssh would use for a host, without connecting.
# This test feeds it the fixture spec/expected/webhook/ssh_config (rspec asserts
# the class renders exactly that file) with `-F`, which makes ssh ignore both
# ~/.ssh/config and /etc/ssh/ssh_config, and checks the pinned options.
#
# Cases:
#   1. the pinned file reports the pinned options, for the control repository's
#      host and for an unrelated host (the file says `Host *`);
#   2. control: a file with `Host *` and `StrictHostKeyChecking no` reports
#      stricthostkeychecking false, so this test can see a weakening;
#   3. with STAGEHAND_SSH_PINNING_DISPOSABLE=1 and uid 0 (run it in a
#      throwaway container, never on a real host): hostile `Host *` blocks are
#      written into /root/.ssh/config and /etc/ssh/ssh_config; plain `ssh -G`
#      is weakened by them (the hostile files are live), and the pinned file
#      still reports the pinned values.
#
# POSIX sh. The last line is `PASS: ssh pinning` on success.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
FIXTURE="$SCRIPT_DIR/../spec/expected/webhook/ssh_config"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*"; }

command -v ssh >/dev/null 2>&1 || fail "ssh not found"
[ -f "$FIXTURE" ] || fail "fixture not found at $FIXTURE"

WORK=$(mktemp -d) || fail "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

# ssh wants a config it owns that others cannot write; copy the fixture.
PINNED="$WORK/ssh_config"
cp "$FIXTURE" "$PINNED" || fail "could not copy the fixture"
chmod 600 "$PINNED" || fail "chmod failed"

# expect_line <label> <ssh -G output> <exact line>
expect_line() {
  printf '%s\n' "$2" | grep -qx -- "$3" || fail "$1: expected the line '$3' in the ssh -G output:
$2"
}

PINNED_HOST=github.com
OTHER_HOST=git.example.test

check_pinned() {
  label=$1
  host=$2
  out=$(ssh -G -F "$PINNED" "$host" 2>&1) || fail "$label: ssh -G failed: $out"
  expect_line "$label" "$out" "stricthostkeychecking true"
  expect_line "$label" "$out" "userknownhostsfile /etc/stagehand-deploy-agent/known_hosts"
  expect_line "$label" "$out" "globalknownhostsfile /dev/null"
  expect_line "$label" "$out" "batchmode yes"
  expect_line "$label" "$out" "identitiesonly yes"
  expect_line "$label" "$out" "identityagent none"
  expect_line "$label" "$out" "identityfile /run/credentials/stagehand-deploy-agent.service/deploy_key"
}

info "pinned file, control repository host"
check_pinned "pinned $PINNED_HOST" "$PINNED_HOST"
info "pinned file, unrelated host (Host *)"
check_pinned "pinned $OTHER_HOST" "$OTHER_HOST"

info "control: a weakening file is visible to this test"
WEAK="$WORK/weak_config"
printf 'Host *\n  StrictHostKeyChecking no\n' > "$WEAK" || fail "could not write the control file"
chmod 600 "$WEAK" || fail "chmod failed"
out=$(ssh -G -F "$WEAK" "$PINNED_HOST" 2>&1) || fail "control: ssh -G failed: $out"
expect_line "control" "$out" "stricthostkeychecking false"

if [ "${STAGEHAND_SSH_PINNING_DISPOSABLE:-}" = "1" ]; then
  [ "$(id -u)" = "0" ] || fail "STAGEHAND_SSH_PINNING_DISPOSABLE=1 needs uid 0 inside a disposable container"
  info "disposable: hostile Host * blocks in root's and the system ssh config"
  HOSTILE='Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  GlobalKnownHostsFile /tmp/hostile_known_hosts
  IdentityAgent /tmp/hostile-agent.sock
  BatchMode no
'
  mkdir -p /root/.ssh /etc/ssh || fail "could not create the ssh directories"
  printf '%s' "$HOSTILE" > /root/.ssh/config || fail "could not write /root/.ssh/config"
  chmod 600 /root/.ssh/config || fail "chmod failed"
  printf '%s' "$HOSTILE" > /etc/ssh/ssh_config || fail "could not write /etc/ssh/ssh_config"
  # Without -F the hostile files are what ssh reads: they must be live, or
  # the pinned result below proves nothing.
  out=$(HOME=/root ssh -G "$PINNED_HOST" 2>&1) || fail "hostile control: ssh -G failed: $out"
  expect_line "hostile control" "$out" "stricthostkeychecking false"
  expect_line "hostile control" "$out" "batchmode no"
  HOME=/root check_pinned "pinned despite hostile configs ($PINNED_HOST)" "$PINNED_HOST"
  HOME=/root check_pinned "pinned despite hostile configs ($OTHER_HOST)" "$OTHER_HOST"
else
  info "skipping the hostile-config case (set STAGEHAND_SSH_PINNING_DISPOSABLE=1 in a throwaway container as root)"
fi

printf 'PASS: ssh pinning\n'
