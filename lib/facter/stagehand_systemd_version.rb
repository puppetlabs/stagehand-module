# frozen_string_literal: true

# stagehand_systemd_version: the major version of systemd on this node as an
# Integer (255 for `systemd 255 (255.4-1ubuntu8)`), or nil when systemctl is
# missing or prints something unexpected.
#
# stagehand::webhook gates on it: the deploy agent's unit passes the Puppet
# private key and the git deploy key with LoadCredential=, which needs systemd
# 247. EL8 (239) and Ubuntu 20.04 (245) are below that line. A nil fact makes
# the class refuse to compile rather than guess.
Facter.add(:stagehand_systemd_version) do
  confine kernel: 'Linux'
  setcode do
    output = Facter::Core::Execution.execute('systemctl --version', on_fail: nil, timeout: 5)
    first_line = output.to_s.lines.first.to_s
    match = first_line.match(%r{\Asystemd\s+(\d+)})
    match ? match[1].to_i : nil
  end
end
