# frozen_string_literal: true

require 'spec_helper'

# Covers stagehand::webhook (Phase 57.6, D-11 / D-31): one class that turns a
# Puppet Core primary with no code-deploy tool into one the Advanced Code
# Manager pack can deploy to -- r10k and its config, the Stagehand fork of
# webhook-go from a pinned, checksummed package, an mTLS config built on the
# primary's own Puppet certificate, and a running service.
describe 'stagehand::webhook' do
  let(:node) { 'primary.example.test' }
  let(:sha256) { 'a' * 64 }
  let(:control_remote) { 'https://git.example.test/puppet/control-repo.git' }
  let(:webhook_yml) { '/etc/voxpupuli/webhook.yml' }
  let(:r10k_yaml) { '/etc/puppetlabs/r10k/r10k.yaml' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:debian) { os_facts[:os]['family'] == 'Debian' }
      let(:pkg_basename) do
        debian ? 'webhook-go_2.15.1-stagehand.1_amd64.deb' : 'webhook-go-2.15.1-stagehand.1.x86_64.rpm'
      end
      let(:pkg_url) { "https://releases.example.test/webhook-go/v2.15.1-stagehand.1/#{pkg_basename}" }
      let(:pkg_path) { "/var/cache/stagehand-webhook/#{pkg_basename}" }
      let(:facts) { os_facts.merge(puppetversion: '8.10.0') }
      let(:params) do
        {
          'control_remote' => control_remote,
          'webhook_package_source' => pkg_url,
          'webhook_package_sha256' => sha256,
        }
      end

      def content_of(path)
        catalogue.resource('File', path)[:content]
      end

      context 'with only the required parameters' do
        it { is_expected.to compile.with_all_deps }

        it 'installs git for r10k shellgit' do
          is_expected.to contain_package('git').with_ensure('installed')
        end

        it 'installs r10k 5.0.3 with the puppet_gem provider on Puppet 8' do
          is_expected.to contain_package('r10k').with(ensure: '5.0.3', provider: 'puppet_gem')
        end

        it 'manages the r10k config and cache directories' do
          is_expected.to contain_file('/etc/puppetlabs/r10k').with(ensure: 'directory', owner: 'root', mode: '0750')
          is_expected.to contain_file('/opt/puppetlabs/puppet/cache/r10k').with(ensure: 'directory', owner: 'root', mode: '0750')
        end

        it 'writes r10k.yaml with the remote, the basedir, an explicit cachedir and no prefix' do
          is_expected.to contain_file(r10k_yaml).with(ensure: 'file', owner: 'root', mode: '0640')
          content = content_of(r10k_yaml)
          expect(content).to include("cachedir: '/opt/puppetlabs/puppet/cache/r10k'")
          expect(content).to include("remote: '#{control_remote}'")
          expect(content).to include("basedir: '/etc/puppetlabs/code/environments'")
          expect(content).to include('prefix: false')
        end

        it 'downloads the fork package into a managed cache directory, checked against the pinned sha256' do
          is_expected.to contain_file('/var/cache/stagehand-webhook').with(ensure: 'directory', owner: 'root', mode: '0750')
          is_expected.to contain_file(pkg_path).with(
            ensure: 'file',
            source: pkg_url,
            checksum: 'sha256',
            checksum_value: sha256,
          )
        end

        it 'installs the fork package from that file with the native provider' do
          is_expected.to contain_package('webhook-go').with(
            ensure: 'latest',
            provider: debian ? 'dpkg' : 'rpm',
            source: pkg_path,
          )
        end

        it 'writes webhook.yml (0640 root) with the node identity, the estate CA, the CRL and the allow-list' do
          is_expected.to contain_file(webhook_yml).with(ensure: 'file', owner: 'root', group: 'root', mode: '0640')
          content = content_of(webhook_yml)
          expect(content).to include('enabled: true')
          expect(content).to include("certificate: '/etc/puppetlabs/puppet/ssl/certs/primary.example.test.pem'")
          expect(content).to include("key: '/etc/puppetlabs/puppet/ssl/private_keys/primary.example.test.pem'")
          expect(content).to include("client_ca: '/etc/puppetlabs/puppet/ssl/certs/ca.pem'")
          expect(content).to include("crl: '/etc/puppetlabs/puppet/ssl/crl.pem'")
          expect(content).to match(%r{allowed_certnames:\n\s+- 'stagehand-code-manager'\n})
          expect(content).to include('allowed_fingerprints: []')
          expect(content).to include('port: 8088')
        end

        it 'points the fork at the Puppet Core r10k, never the PE path' do
          content = content_of(webhook_yml)
          expect(content).to include("command_path: '/opt/puppetlabs/puppet/bin/r10k'")
          expect(content).to include("config_path: '#{r10k_yaml}'")
          expect(content).to include('use_g10k_commands: false')
          expect(content).not_to include('puppetserver/bin/r10k')
        end

        it 'renders the deploy settings' do
          content = content_of(webhook_yml)
          expect(content).to include("basedir: '/etc/puppetlabs/code/environments'")
          expect(content).to include("timeout: '15m'")
          expect(content).to include("state_dir: '/var/lib/webhook-go'")
          expect(content).to include('output_limit: 262144')
        end

        it 'keeps the service running and enabled' do
          is_expected.to contain_service('webhook-go').with(ensure: 'running', enable: true)
        end

        it 'orders r10k package -> r10k config -> fork package -> webhook config -> service' do
          is_expected.to contain_file(r10k_yaml).that_requires('Package[r10k]')
          is_expected.to contain_package('webhook-go').that_requires("File[#{r10k_yaml}]")
          is_expected.to contain_package('webhook-go').that_requires("File[#{pkg_path}]")
          is_expected.to contain_file(webhook_yml).that_requires('Package[webhook-go]')
        end

        it 'restarts the service when the config or the package changes' do
          is_expected.to contain_service('webhook-go').that_subscribes_to("File[#{webhook_yml}]")
          is_expected.to contain_service('webhook-go').that_subscribes_to('Package[webhook-go]')
        end

        it 'manages no ssh configuration for an https remote' do
          is_expected.not_to contain_file('/root/.ssh')
          is_expected.not_to contain_file('/root/.ssh/config.d/stagehand-webhook.conf')
          is_expected.not_to contain_file('/root/.ssh/known_hosts_stagehand')
          is_expected.not_to contain_file_line('stagehand-webhook ssh include')
        end
      end

      context 'with a Puppet 7 agent' do
        let(:facts) { os_facts.merge(puppetversion: '7.30.0') }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('r10k').with(ensure: '4.1.0', provider: 'puppet_gem') }
      end

      context 'with an explicit r10k_version' do
        let(:params) { super().merge('r10k_version' => '5.0.2') }

        it { is_expected.to contain_package('r10k').with_ensure('5.0.2') }
      end

      context 'with manage_git => false' do
        let(:params) { super().merge('manage_git' => false) }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('git') }
      end

      context 'with a control remote containing a quote' do
        let(:params) { super().merge('control_remote' => "https://git.example.test/o'brien/control.git") }

        it 'is refused by the type before it can reach YAML' do
          is_expected.to compile.and_raise_error(%r{control_remote})
        end
      end

      context 'with an SSH control remote' do
        let(:known_host) { 'github.com ssh-ed25519 AAAAexamplehostkey' }
        let(:params) do
          super().merge(
            'control_remote' => 'git@github.com:example/control-repo.git',
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/root/.ssh/stagehand_deploy',
            'git_ssh_known_host' => known_host,
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'ensures root ssh directories exist with mode 0700' do
          is_expected.to contain_file('/root/.ssh').with(ensure: 'directory', owner: 'root', mode: '0700')
          is_expected.to contain_file('/root/.ssh/config.d').with(ensure: 'directory', owner: 'root', mode: '0700')
        end

        it 'writes a Host block fragment that uses the deploy key and strict host key checking' do
          is_expected.to contain_file('/root/.ssh/config.d/stagehand-webhook.conf').with(ensure: 'file', owner: 'root', mode: '0600')
          content = content_of('/root/.ssh/config.d/stagehand-webhook.conf')
          expect(content).to match(%r{^Host github\.com$})
          expect(content).to include('IdentityFile "/root/.ssh/stagehand_deploy"')
          expect(content).to include('IdentitiesOnly yes')
          expect(content).to include('UserKnownHostsFile "/root/.ssh/known_hosts_stagehand"')
          expect(content).to include('StrictHostKeyChecking yes')
        end

        it 'writes the operator-supplied host key line into a dedicated known_hosts file' do
          is_expected.to contain_file('/root/.ssh/known_hosts_stagehand').with(
            ensure: 'file', owner: 'root', mode: '0644', content: "#{known_host}\n",
          )
        end

        it "includes the fragment from root's ssh config without owning the rest of that file" do
          is_expected.to contain_file('/root/.ssh/config').with(ensure: 'file', owner: 'root', mode: '0600')
          is_expected.to contain_file('/root/.ssh/config').without_content
          is_expected.to contain_file_line('stagehand-webhook ssh match all').with(
            path: '/root/.ssh/config', line: 'Match all',
          )
          is_expected.to contain_file_line('stagehand-webhook ssh include').with(
            path: '/root/.ssh/config', line: 'Include config.d/*.conf', after: '^Match all$',
          ).that_requires('File_line[stagehand-webhook ssh match all]')
        end

        it 'has the ssh setup in place before the service starts' do
          is_expected.to contain_service('webhook-go').that_requires('File[/root/.ssh/config.d/stagehand-webhook.conf]')
          is_expected.to contain_service('webhook-go').that_requires('File[/root/.ssh/known_hosts_stagehand]')
          is_expected.to contain_service('webhook-go').that_requires('File_line[stagehand-webhook ssh include]')
        end
      end

      context 'with git_ssh_host but no git_ssh_key' do
        let(:params) { super().merge('git_ssh_host' => 'github.com', 'git_ssh_known_host' => 'github.com ssh-ed25519 AAAAx') }

        it { is_expected.to compile.and_raise_error(%r{git_ssh_key}) }
      end

      context 'with git_ssh_host but no git_ssh_known_host' do
        let(:params) { super().merge('git_ssh_host' => 'github.com', 'git_ssh_key' => '/root/.ssh/stagehand_deploy') }

        it { is_expected.to compile.and_raise_error(%r{git_ssh_known_host}) }
      end

      context 'with a known_hosts line containing a newline' do
        let(:params) do
          super().merge(
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/root/.ssh/stagehand_deploy',
            'git_ssh_known_host' => "github.com ssh-ed25519 AAAAx\nevil.example ssh-ed25519 AAAAy",
          )
        end

        it { is_expected.to compile.and_raise_error(%r{git_ssh_known_host}) }
      end

      context 'with a deploy key path containing whitespace' do
        let(:params) do
          super().merge(
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/root/.ssh/stagehand deploy',
            'git_ssh_known_host' => 'github.com ssh-ed25519 AAAAx',
          )
        end

        it { is_expected.to compile.and_raise_error(%r{git_ssh_key}) }
      end

      context 'with a sha256 that is not 64 hex characters' do
        let(:params) { super().merge('webhook_package_sha256' => 'abc') }

        it { is_expected.to compile.and_raise_error(%r{webhook_package_sha256}) }
      end

      context 'with engine g10k but no g10k_command_path' do
        let(:params) { super().merge('engine' => 'g10k') }

        it { is_expected.to compile.and_raise_error(%r{g10k_command_path}) }
      end

      context 'with engine g10k and a g10k_command_path' do
        let(:params) { super().merge('engine' => 'g10k', 'g10k_command_path' => '/usr/local/bin/g10k') }

        it { is_expected.to compile.with_all_deps }

        it 'points the fork at g10k and switches on the g10k commands' do
          content = content_of(webhook_yml)
          expect(content).to include("command_path: '/usr/local/bin/g10k'")
          expect(content).to include('use_g10k_commands: true')
        end
      end

      context 'with an empty allowed_certnames' do
        let(:params) { super().merge('allowed_certnames' => []) }

        it { is_expected.to compile.and_raise_error(%r{allowed_certnames}) }
      end

      context 'with allowed_fingerprints' do
        let(:fingerprint) { (['AB'] * 32).join(':') }
        let(:params) { super().merge('allowed_fingerprints' => [fingerprint]) }

        it 'renders them into webhook.yml' do
          expect(content_of(webhook_yml)).to match(%r{allowed_fingerprints:\n\s+- '#{fingerprint}'\n})
        end
      end

      context 'with a lowercase fingerprint' do
        let(:params) { super().merge('allowed_fingerprints' => [(['ab'] * 32).join(':')]) }

        it { is_expected.to compile.and_raise_error(%r{allowed_fingerprints}) }
      end

      context 'with a package source whose extension does not match the OS family' do
        let(:params) do
          super().merge('webhook_package_source' => "https://releases.example.test/webhook-go.#{debian ? 'rpm' : 'deb'}")
        end

        it { is_expected.to compile.and_raise_error(%r{webhook_package_source}) }
      end
    end
  end
end
