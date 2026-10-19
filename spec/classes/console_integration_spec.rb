# frozen_string_literal: true

require 'spec_helper'

describe 'stagehand::console_integration' do
  let(:hiera_yaml_path) { '/etc/puppetlabs/code/environments/production/hiera.yaml' }

  let(:params) do
    {
      'console_url' => 'https://console.example.test',
      'token'       => sensitive('test-token'),
    }
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }

      it 'manages the OpenSSH server package by default' do
        is_expected.to contain_package('openssh-server').with_ensure('installed')
      end

      context 'when SSH server management is disabled' do
        let(:params) { super().merge('manage_ssh_server' => false) }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('openssh-server') }
      end

      # 999.12-03 Task 2: hiera_uris typed-parameter delivery
      # (docs/design/module-architecture.md section 6, the Phase 19 Plan 03
      # checkpoint decision) -- restored from adapters/stagehand while
      # keeping manage_ssh_server, which has no adapters-side equivalent.
      context 'with no hiera_uris supplied' do
        it { is_expected.to compile.with_all_deps }

        it "renders today's three-tier default unchanged" do
          content = catalogue.resource('File', hiera_yaml_path)[:content]
          uris = content.scan(%r{^\s*- "(.+)"$}).flatten
          expect(uris).to eq([
                               'nodes/%{trusted.certname}',
                               'group/%{trusted.external.psh.primary_group}',
                               'common',
                             ])
        end
      end

      context 'with an ordered, four-element hiera_uris list' do
        let(:custom_uris) do
          [
            'nodes/%{trusted.certname}',
            'group/%{trusted.external.psh.primary_group}',
            'env/%{server_facts.environment}',
            'common',
          ]
        end
        let(:params) { super().merge('hiera_uris' => custom_uris) }

        it { is_expected.to compile.with_all_deps }

        it 'renders exactly those four entries, in that order' do
          content = catalogue.resource('File', hiera_yaml_path)[:content]
          uris = content.scan(%r{^\s*- "(.+)"$}).flatten
          expect(uris).to eq(custom_uris)
        end

        it 'renders exactly one common entry -- the template adds none of its own' do
          content = catalogue.resource('File', hiera_yaml_path)[:content]
          expect(content.scan('- "common"').length).to eq(1)
        end
      end

      context 'with an empty hiera_uris array' do
        let(:params) { super().merge('hiera_uris' => []) }

        it 'is rejected by the type, not silently rendered' do
          expect { is_expected.to compile }.to raise_error(%r{expects an Array\[String\[1\]\] value|parameter 'hiera_uris'})
        end
      end
    end
  end

  context 'manage_ssh_server on an OS family neither Debian nor RedHat' do
    let(:facts) do
      {
        'os' => { 'family' => 'Suse', 'name' => 'SLES', 'release' => { 'major' => '15', 'full' => '15.5' } },
        'networking' => { 'fqdn' => 'primary.example.test' },
      }
    end

    it { is_expected.not_to contain_package('openssh-server') }
  end
end
