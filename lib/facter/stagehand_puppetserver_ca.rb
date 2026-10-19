# frozen_string_literal: true

# stagehand_puppetserver_ca: true when this node is the Puppet CA host, judged
# by the CA's own revocation list being present at puppetserver's default
# cadir (Puppet 7 and later, OpenVox 8).
#
# stagehand::webhook uses it to point the webhook-go fork at that CRL. The
# CA's file changes the moment `puppetserver ca revoke` runs; the agent's copy
# at /etc/puppetlabs/puppet/ssl/crl.pem is only refreshed on agent runs, so a
# revoked certificate could keep deploying until the next run.
#
# A CA with a non-default cadir reports false here; set
# stagehand::webhook::crl_path explicitly on such a host.
Facter.add(:stagehand_puppetserver_ca) do
  setcode do
    File.file?('/etc/puppetlabs/puppetserver/ca/ca_crl.pem')
  end
end
