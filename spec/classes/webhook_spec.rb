# frozen_string_literal: true

require 'spec_helper'

# Covers stagehand::webhook (Phase 57.6 D-11 / D-31, Phase 57.6.2 D-01 / D-04 /
# D-12 / D-20): one class that turns a Puppet Core primary with no code-deploy
# tool into one the Advanced Code Manager pack can deploy to -- r10k and its
# config, the Stagehand deploy agent from a pinned, checksummed package, run as
# its own user (never root), an mTLS config built on the primary's own Puppet
# certificate, both keys passed by systemd credentials, and a running service.
describe 'stagehand::webhook' do
  let(:node) { 'primary.example.test' }

  def sha256
    'a' * 64
  end

  def control_remote
    'https://git.example.test/puppet/control-repo.git'
  end

  def agent_config
    '/etc/stagehand-deploy-agent/config.yml'
  end

  def agent_user
    'stagehand-deploy-agent'
  end

  def r10k_yaml
    '/etc/puppetlabs/r10k/r10k.yaml'
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:debian) { os_facts[:os]['family'] == 'Debian' }
      let(:pkg_basename) do
        debian ? 'stagehand-deploy-agent_1.1.0_linux_amd64.deb' : 'stagehand-deploy-agent-1.1.0-1.x86_64.rpm'
      end
      let(:pkg_url) { "https://releases.example.test/stagehand-deploy-agent/v1.1.0/#{pkg_basename}" }
      let(:pkg_path) { "/var/cache/stagehand-deploy-agent/#{pkg_basename}" }
      let(:facts) { os_facts.merge(puppetversion: '8.10.0', stagehand_systemd_version: 255) }
      let(:params) do
        {
          'control_remote' => control_remote,
          'agent_package_source' => pkg_url,
          'agent_package_sha256' => sha256,
        }
      end

      def dropin_dir
        '/etc/systemd/system/stagehand-deploy-agent.service.d'
      end

      def dropin
        "#{dropin_dir}/50-stagehand.conf"
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

        it 'creates the agent user as a system user in group puppet, with no login shell' do
          is_expected.to contain_user(agent_user).with(
            ensure: 'present',
            system: true,
            gid: 'puppet',
            home: '/var/lib/stagehand-deploy-agent',
            shell: '/usr/sbin/nologin',
            managehome: false,
          )
        end

        it 'hands the agent user the environments directory and the r10k cache, group puppet, 0750' do
          is_expected.to contain_file('/etc/puppetlabs/code/environments').with(
            ensure: 'directory', owner: agent_user, group: 'puppet', mode: '0750',
          )
          is_expected.to contain_file('/opt/puppetlabs/puppet/cache/r10k').with(
            ensure: 'directory', owner: agent_user, group: 'puppet', mode: '0750',
          )
        end

        it 'does not manage the code directory itself, the global hiera.yaml or modules' do
          is_expected.not_to contain_file('/etc/puppetlabs/code')
          is_expected.not_to contain_file('/etc/puppetlabs/code/hiera.yaml')
          is_expected.not_to contain_file('/etc/puppetlabs/code/modules')
        end

        it 'changes nothing under the Puppet ssl directory' do
          ssl = '/etc/puppetlabs/puppet/ssl'
          paths = catalogue.resources.select { |r| r.type == 'File' }.map { |r| (r[:path] || r.title).to_s }
          expect(paths.grep(%r{\A#{ssl}})).to be_empty
        end

        it 'lets the agent read the r10k config through the puppet group' do
          is_expected.to contain_file('/etc/puppetlabs/r10k').with(ensure: 'directory', owner: 'root', group: 'puppet', mode: '0750')
          is_expected.to contain_file(r10k_yaml).with(ensure: 'file', owner: 'root', group: 'puppet', mode: '0640')
        end

        it 'writes r10k.yaml with the remote, the basedir, an explicit cachedir and no prefix' do
          content = content_of(r10k_yaml)
          expect(content).to include("cachedir: '/opt/puppetlabs/puppet/cache/r10k'")
          expect(content).to include("remote: '#{control_remote}'")
          expect(content).to include("basedir: '/etc/puppetlabs/code/environments'")
          expect(content).to include('prefix: false')
        end

        it 'downloads the agent package into a managed cache directory, checked against the pinned sha256' do
          is_expected.to contain_file('/var/cache/stagehand-deploy-agent').with(ensure: 'directory', owner: 'root', mode: '0750')
          is_expected.to contain_file(pkg_path).with(
            ensure: 'file',
            source: pkg_url,
            checksum: 'sha256',
            checksum_value: sha256,
          )
        end

        it 'installs the agent package from that file with the native provider' do
          is_expected.to contain_package('stagehand-deploy-agent').with(
            ensure: 'latest',
            provider: debian ? 'dpkg' : 'rpm',
            source: pkg_path,
          )
        end

        it 'does not manage the old webhook-go service, package or config' do
          is_expected.not_to contain_service('webhook-go')
          is_expected.not_to contain_package('webhook-go')
          is_expected.not_to contain_file('/etc/voxpupuli/webhook.yml')
        end

        it 'writes the agent config (0640 root:puppet) exactly as the reviewed fixture' do
          is_expected.to contain_file(agent_config).with(ensure: 'file', owner: 'root', group: 'puppet', mode: '0640')
          expect(content_of(agent_config)).to eq(File.read(File.join(__dir__, '..', 'expected', 'webhook', 'config.yml')))
        end

        it 'renders YAML the agent can read, with the nested keys of its strict schema' do
          config = YAML.safe_load(content_of(agent_config))
          expect(config.keys).to contain_exactly('server', 'ops', 'engine', 'deploys')
          expect(config.dig('server', 'tls', 'key')).to eq('/run/credentials/stagehand-deploy-agent.service/server.key')
          expect(config.dig('server', 'tls', 'certificate')).to eq('/etc/puppetlabs/puppet/ssl/certs/primary.example.test.pem')
          expect(config.dig('server', 'tls', 'allowed_certnames')).to eq(['stagehand-code-manager'])
          expect(config.dig('engine', 'command_path')).to eq('/opt/puppetlabs/puppet/bin/r10k')
          expect(config.dig('deploys', 'state_dir')).to eq('/var/lib/stagehand-deploy-agent')
          expect(config.dig('deploys', 'protected_environments')).to eq(['production'])
        end

        it 'creates the state directory 0700, owned by the agent user' do
          is_expected.to contain_file('/var/lib/stagehand-deploy-agent').with(
            ensure: 'directory', owner: agent_user, group: 'puppet', mode: '0700',
          )
        end

        it 'keeps the service running and enabled' do
          is_expected.to contain_service('stagehand-deploy-agent').with(ensure: 'running', enable: true)
        end

        it 'has the directories in place before the service starts' do
          %w[/etc/puppetlabs/code/environments /opt/puppetlabs/puppet/cache/r10k /var/lib/stagehand-deploy-agent].each do |dir|
            is_expected.to contain_service('stagehand-deploy-agent').that_requires("File[#{dir}]")
          end
        end

        it 'orders r10k package -> r10k config -> agent package -> agent config -> service' do
          is_expected.to contain_file(r10k_yaml).that_requires('Package[r10k]')
          is_expected.to contain_package('stagehand-deploy-agent').that_requires("File[#{r10k_yaml}]")
          is_expected.to contain_package('stagehand-deploy-agent').that_requires("File[#{pkg_path}]")
          is_expected.to contain_file(agent_config).that_requires('Package[stagehand-deploy-agent]')
        end

        it 'restarts the service when the config, the drop-in or the package changes' do
          is_expected.to contain_service('stagehand-deploy-agent').that_subscribes_to("File[#{agent_config}]")
          is_expected.to contain_service('stagehand-deploy-agent').that_subscribes_to("File[#{dropin}]")
          is_expected.to contain_service('stagehand-deploy-agent').that_subscribes_to('Package[stagehand-deploy-agent]')
        end

        it 'keeps the agent config directory root:puppet 0750' do
          is_expected.to contain_file('/etc/stagehand-deploy-agent').with(ensure: 'directory', owner: 'root', group: 'puppet', mode: '0750')
        end

        context 'systemd drop-in for stagehand-deploy-agent' do
          it 'manages the drop-in directory and file' do
            is_expected.to contain_file(dropin_dir).with(ensure: 'directory', owner: 'root', group: 'root', mode: '0755')
            is_expected.to contain_file(dropin).with(ensure: 'file', owner: 'root', group: 'root', mode: '0644')
                                               .that_requires("File[#{dropin_dir}]")
          end

          it 'names the service user' do
            expect(content_of(dropin)).to match(%r{^\[Service\]$})
            expect(content_of(dropin)).to match(%r{^User=stagehand-deploy-agent$})
          end

          it "passes this node's Puppet private key as a systemd credential and nothing else" do
            content = content_of(dropin)
            expect(content).to match(%r{^LoadCredential=server\.key:/etc/puppetlabs/puppet/ssl/private_keys/primary\.example\.test\.pem$})
            expect(content.scan(%r{^LoadCredential=}).length).to eq(1)
          end

          it 'clears the packaged ReadWritePaths and sets the environments directory and the r10k cache' do
            content = content_of(dropin)
            expect(content).to match(%r{^ReadWritePaths=$})
            expect(content).to match(%r{^ReadWritePaths=/etc/puppetlabs/code/environments /opt/puppetlabs/puppet/cache/r10k$})
          end

          it 'explains each setting in a comment' do
            content = content_of(dropin)
            expect(content).to match(%r{^#.*never root}i)
            expect(content).to match(%r{^#.*systemd 247}i)
            expect(content).to match(%r{^#.*read-only}i)
          end

          it 'reloads systemd when the drop-in changes, before the service is managed' do
            is_expected.to contain_exec('stagehand-deploy-agent-systemd-reload').with(
              command: '/bin/systemctl daemon-reload', refreshonly: true,
            ).that_subscribes_to("File[#{dropin}]")
            is_expected.to contain_service('stagehand-deploy-agent').that_requires('Exec[stagehand-deploy-agent-systemd-reload]')
          end
        end

        context 'the run_as guard (D-04)' do
          it 'fails the run at apply time if run_as resolves to uid 0, before anything the agent needs' do
            guard = 'stagehand-deploy-agent-run-as-not-uid0'
            is_expected.to contain_exec(guard)
            is_expected.to contain_exec(guard).that_comes_before("User[#{agent_user}]")
            is_expected.to contain_exec(guard).that_comes_before('File[/etc/puppetlabs/code/environments]')
            is_expected.to contain_exec(guard).that_comes_before('File[/opt/puppetlabs/puppet/cache/r10k]')
            is_expected.to contain_exec(guard).that_comes_before('Package[stagehand-deploy-agent]')
            is_expected.to contain_exec(guard).that_comes_before('Service[stagehand-deploy-agent]')
          end

          it 'passes the user name as an argument, never splicing it into the script' do
            exec = catalogue.resource('Exec', 'stagehand-deploy-agent-run-as-not-uid0')
            expect(exec[:command]).to eq(['/bin/sh', '-c', 'echo "stagehand::webhook: run_as $1 resolves to uid 0; refusing" >&2; exit 1', 'sh', agent_user])
            expect(exec[:unless].flatten).to include('sh', agent_user)
            expect(exec[:unless].flatten.join(' ')).not_to include("id -u #{agent_user}")
          end
        end
      end

      context 'with run_as root' do
        let(:params) { super().merge('run_as' => 'root') }

        it { is_expected.to compile.and_raise_error(%r{run_as must not be root}) }
      end

      context 'with run_as 0' do
        let(:params) { super().merge('run_as' => '0') }

        it { is_expected.to compile.and_raise_error(%r{run_as}) }
      end

      context 'with a run_as that is not a user name' do
        let(:params) { super().merge('run_as' => 'agent user; id') }

        it { is_expected.to compile.and_raise_error(%r{run_as}) }
      end

      context 'with another run_as' do
        let(:params) { super().merge('run_as' => 'deployer') }

        it 'owns the directories and names the user in the drop-in' do
          is_expected.to contain_user('deployer')
          is_expected.to contain_file('/etc/puppetlabs/code/environments').with_owner('deployer')
          expect(content_of(dropin)).to match(%r{^User=deployer$})
          is_expected.to contain_exec('stagehand-deploy-agent-run-as-not-uid0').that_comes_before('User[deployer]')
        end
      end

      context 'with systemd 245 (Ubuntu 20.04)' do
        let(:facts) { super().merge(stagehand_systemd_version: 245) }

        it { is_expected.to compile.and_raise_error(%r{systemd 247.*found 245}) }
      end

      context 'with systemd 247' do
        let(:facts) { super().merge(stagehand_systemd_version: 247) }

        it { is_expected.to compile.with_all_deps }
      end

      context 'without the systemd version fact' do
        let(:facts) { os_facts.merge(puppetversion: '8.10.0') }

        it { is_expected.to compile.and_raise_error(%r{systemd 247.*found none}) }
      end

      context 'on the CA host' do
        let(:facts) { super().merge(stagehand_puppetserver_ca: true) }

        it { is_expected.to compile.with_all_deps }

        it "reads the CA's own CRL, which `puppetserver ca revoke` updates at once" do
          content = content_of(agent_config)
          expect(content).to include("crl: '/etc/puppetlabs/puppetserver/ca/ca_crl.pem'")
          expect(content).not_to include("crl: '/etc/puppetlabs/puppet/ssl/crl.pem'")
        end
      end

      context 'on a node that is not the CA host' do
        let(:facts) { super().merge(stagehand_puppetserver_ca: false) }

        it "falls back to the agent's CRL copy" do
          expect(content_of(agent_config)).to include("crl: '/etc/puppetlabs/puppet/ssl/crl.pem'")
        end
      end

      context 'with an explicit crl_path' do
        let(:facts) { super().merge(stagehand_puppetserver_ca: true) }
        let(:params) { super().merge('crl_path' => '/etc/pki/stagehand/ca_crl.pem') }

        it 'renders that path, even on the CA host' do
          expect(content_of(agent_config)).to include("crl: '/etc/pki/stagehand/ca_crl.pem'")
        end
      end

      context 'with a relative crl_path' do
        let(:params) { super().merge('crl_path' => 'ca_crl.pem') }

        it { is_expected.to compile.and_raise_error(%r{crl_path}) }
      end

      context 'with a crl_path containing a control character' do
        let(:params) { super().merge('crl_path' => "/etc/pki/stagehand/ca\tcrl.pem") }

        it { is_expected.to compile.and_raise_error(%r{control character}) }
      end

      context 'with a custom state_dir, max_jobs and protected_environments' do
        let(:params) do
          super().merge('state_dir' => '/srv/stagehand/state', 'max_jobs' => 50, 'protected_environments' => %w[production staging])
        end

        it 'creates that directory, renders the keys and lets the unit write there' do
          is_expected.to contain_file('/srv/stagehand/state').with(ensure: 'directory', owner: agent_user, mode: '0700')
          is_expected.to contain_service('stagehand-deploy-agent').that_requires('File[/srv/stagehand/state]')
          config = YAML.safe_load(content_of(agent_config))
          expect(config.dig('deploys', 'state_dir')).to eq('/srv/stagehand/state')
          expect(config.dig('deploys', 'max_jobs')).to eq(50)
          expect(config.dig('deploys', 'protected_environments')).to eq(%w[production staging])
          expect(content_of(agent_config)).not_to include('/var/lib/stagehand-deploy-agent')
          expect(content_of(dropin)).to match(%r{^ReadWritePaths=/etc/puppetlabs/code/environments /opt/puppetlabs/puppet/cache/r10k /srv/stagehand/state$})
        end
      end

      context 'with no protected environments' do
        let(:params) { super().merge('protected_environments' => []) }

        it 'renders an empty list the agent accepts' do
          expect(YAML.safe_load(content_of(agent_config)).dig('deploys', 'protected_environments')).to eq([])
        end
      end

      context 'with a protected environment that is not a valid name' do
        let(:params) { super().merge('protected_environments' => ['Prod uction']) }

        it { is_expected.to compile.and_raise_error(%r{protected_environments}) }
      end

      context 'with a state_dir containing whitespace' do
        let(:params) { super().merge('state_dir' => '/srv/stagehand state') }

        it { is_expected.to compile.and_raise_error(%r{whitespace}) }
      end

      context 'with an ops_listen on another interface' do
        let(:params) { super().merge('ops_listen' => '[::1]:9100') }

        it 'renders it' do
          expect(YAML.safe_load(content_of(agent_config)).dig('ops', 'listen')).to eq('[::1]:9100')
        end
      end

      context 'with an ops_listen that is not host:port' do
        let(:params) { super().merge('ops_listen' => 'localhost') }

        it { is_expected.to compile.and_raise_error(%r{ops_listen}) }
      end

      context 'with max_jobs below 1' do
        let(:params) { super().merge('max_jobs' => 0) }

        it { is_expected.to compile.and_raise_error(%r{max_jobs}) }
      end

      context 'with a relative state_dir' do
        let(:params) { super().merge('state_dir' => 'var/lib/webhook-go') }

        it { is_expected.to compile.and_raise_error(%r{state_dir}) }
      end

      context 'with a state_dir containing a control character' do
        let(:params) { super().merge('state_dir' => "/var/lib/webhook\tgo") }

        it { is_expected.to compile.and_raise_error(%r{control character}) }
      end

      context 'with a Puppet 7 agent' do
        let(:facts) { os_facts.merge(puppetversion: '7.30.0', stagehand_systemd_version: 255) }

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

      context 'with git_ssh_host but no git_ssh_key' do
        let(:params) { super().merge('git_ssh_host' => 'github.com', 'git_ssh_known_host' => 'github.com ssh-ed25519 AAAAx') }

        it { is_expected.to compile.and_raise_error(%r{git_ssh_key}) }
      end

      context 'with git_ssh_host but no git_ssh_known_host' do
        let(:params) { super().merge('git_ssh_host' => 'github.com', 'git_ssh_key' => '/etc/stagehand-deploy-agent/deploy_key') }

        it { is_expected.to compile.and_raise_error(%r{git_ssh_known_host}) }
      end

      context 'with a known_hosts line containing a newline' do
        let(:params) do
          super().merge(
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/etc/stagehand-deploy-agent/deploy_key',
            'git_ssh_known_host' => "github.com ssh-ed25519 AAAAx\nevil.example ssh-ed25519 AAAAy",
          )
        end

        it { is_expected.to compile.and_raise_error(%r{git_ssh_known_host}) }
      end

      context 'with a deploy key path containing whitespace' do
        let(:params) do
          super().merge(
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/etc/stagehand-deploy-agent/deploy key',
            'git_ssh_known_host' => 'github.com ssh-ed25519 AAAAx',
          )
        end

        it { is_expected.to compile.and_raise_error(%r{git_ssh_key}) }
      end

      context 'with a sha256 that is not 64 hex characters' do
        let(:params) { super().merge('agent_package_sha256' => 'abc') }

        it { is_expected.to compile.and_raise_error(%r{agent_package_sha256}) }
      end

      context 'with engine g10k but no g10k_command_path' do
        let(:params) { super().merge('engine' => 'g10k') }

        it { is_expected.to compile.and_raise_error(%r{g10k_command_path}) }
      end

      context 'with engine g10k and a g10k_command_path' do
        let(:params) { super().merge('engine' => 'g10k', 'g10k_command_path' => '/usr/local/bin/g10k') }

        it { is_expected.to compile.with_all_deps }

        it 'points the agent at g10k' do
          config = YAML.safe_load(content_of(agent_config))
          expect(config.dig('engine', 'name')).to eq('g10k')
          expect(config.dig('engine', 'command_path')).to eq('/usr/local/bin/g10k')
        end
      end

      context 'with an empty allowed_certnames' do
        let(:params) { super().merge('allowed_certnames' => []) }

        it { is_expected.to compile.and_raise_error(%r{allowed_certnames}) }
      end

      context 'with allowed_fingerprints' do
        def fingerprint
          (['AB'] * 32).join(':')
        end
        let(:params) { super().merge('allowed_fingerprints' => [fingerprint]) }

        it 'renders them into config.yml' do
          expect(content_of(agent_config)).to match(%r{allowed_fingerprints:\n\s+- '#{fingerprint}'\n})
        end
      end

      context 'with a fingerprint copied from `puppetserver ca list --all`' do
        # The (SHA256) value as puppetserver prints it: 32 upper-case hex
        # pairs joined by colons.
        def fingerprint
          '5B:9A:0C:41:7E:D2:13:88:6F:A4:20:C9:3B:E7:51:0D:94:2A:C6:7F:18:B3:E0:5D:72:9C:4E:A1:06:F8:3D:B5'
        end
        let(:params) { super().merge('allowed_fingerprints' => [fingerprint]) }

        it { is_expected.to compile.with_all_deps }

        it 'renders it unchanged' do
          expect(content_of(agent_config)).to include("- '#{fingerprint}'")
        end
      end

      context 'with a lower-case or mixed-case fingerprint' do
        let(:params) do
          super().merge('allowed_fingerprints' => [(['ab'] * 32).join(':'), (['cD'] * 32).join(':')])
        end

        it 'is accepted, as the agent accepts it, and rendered in upper case' do
          content = content_of(agent_config)
          expect(content).to include("- '#{(['AB'] * 32).join(':')}'")
          expect(content).to include("- '#{(['CD'] * 32).join(':')}'")
          expect(content).not_to include((['ab'] * 32).join(':'))
          expect(content).not_to include((['cD'] * 32).join(':'))
        end
      end

      context 'with the same fingerprint in two cases' do
        let(:params) do
          super().merge('allowed_fingerprints' => [(['ab'] * 32).join(':'), (['AB'] * 32).join(':')])
        end

        it 'renders it once' do
          expect(content_of(agent_config).scan((['AB'] * 32).join(':')).length).to eq(1)
        end
      end

      {
        'a SHA-1 fingerprint (20 pairs)' => (['AB'] * 20).join(':'),
        'a fingerprint without colons' => 'AB' * 32,
        'a fingerprint with the (SHA256) label left on' => "(SHA256) #{(['AB'] * 32).join(':')}",
        'a fingerprint with a non-hex character' => ((['AB'] * 31) + ['AG']).join(':'),
        'a fingerprint with a trailing newline' => "#{(['AB'] * 32).join(':')}\n",
        'a fingerprint with dashes instead of colons' => (['AB'] * 32).join('-'),
      }.each do |label, value|
        context "with #{label}" do
          let(:params) { super().merge('allowed_fingerprints' => [value]) }

          it { is_expected.to compile.and_raise_error(%r{allowed_fingerprints}) }
        end
      end

      context 'with a package source whose extension does not match the OS family' do
        let(:params) do
          super().merge('agent_package_source' => "https://releases.example.test/webhook-go.#{debian ? 'rpm' : 'deb'}")
        end

        it { is_expected.to compile.and_raise_error(%r{agent_package_source}) }
      end
    end
  end
end
