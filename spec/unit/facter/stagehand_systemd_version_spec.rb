# frozen_string_literal: true

require 'spec_helper'

# stagehand_systemd_version tells stagehand::webhook whether the node's systemd
# is new enough (247) for LoadCredential=. The fact reads the first line of
# `systemctl --version`.
describe 'stagehand_systemd_version' do
  before do
    Facter.clear
    allow(Facter.fact(:kernel)).to receive(:value).and_return('Linux')
  end

  after { Facter.clear }

  def stub_systemctl(output)
    allow(Facter::Core::Execution).to receive(:execute)
      .with('systemctl --version', hash_including(on_fail: nil))
      .and_return(output)
  end

  it 'is the major version as an Integer' do
    stub_systemctl("systemd 255 (255.4-1ubuntu8)\n+PAM +AUDIT +SELINUX\n")
    expect(Facter.fact(:stagehand_systemd_version).value).to eq(255)
  end

  it 'reads an EL9 build the same way' do
    stub_systemctl("systemd 252 (252-32.el9_4)\n+PAM +AUDIT\n")
    expect(Facter.fact(:stagehand_systemd_version).value).to eq(252)
  end

  it 'is nil when systemctl is missing' do
    stub_systemctl(nil)
    expect(Facter.fact(:stagehand_systemd_version).value).to be_nil
  end

  it 'is nil when the first line is not a systemd banner' do
    stub_systemctl("Failed to connect to bus\n")
    expect(Facter.fact(:stagehand_systemd_version).value).to be_nil
  end
end
