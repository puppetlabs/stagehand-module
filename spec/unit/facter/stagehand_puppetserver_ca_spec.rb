# frozen_string_literal: true

require 'spec_helper'

# stagehand_puppetserver_ca tells stagehand::webhook whether this node is the
# Puppet CA host, so the fork can read the CA's own CRL (updated the moment
# `puppetserver ca revoke` runs) instead of the agent's copy (refreshed only
# on agent runs).
describe 'stagehand_puppetserver_ca' do
  let(:ca_crl) { '/etc/puppetlabs/puppetserver/ca/ca_crl.pem' }

  before do
    Facter.clear
    allow(File).to receive(:file?).and_call_original
  end

  after { Facter.clear }

  it 'is true when the CA directory holds the CA CRL' do
    allow(File).to receive(:file?).with(ca_crl).and_return(true)
    expect(Facter.fact(:stagehand_puppetserver_ca).value).to be(true)
  end

  it 'is false when there is no CA CRL on this node' do
    allow(File).to receive(:file?).with(ca_crl).and_return(false)
    expect(Facter.fact(:stagehand_puppetserver_ca).value).to be(false)
  end
end
