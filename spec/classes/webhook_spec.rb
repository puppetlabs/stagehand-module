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

      def ssh_config_path
        '/etc/stagehand-deploy-agent/ssh_config'
      end

      def known_hosts_path
        '/etc/stagehand-deploy-agent/known_hosts'
      end

      def resources_under_root
        catalogue.resources.select do |r|
          [r.title, r[:path]].compact.any? { |value| value.to_s.start_with?('/root') }
        end
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

        it 'manages no ssh files, no deploy key credential and no engine.ssh_config for an https remote' do
          is_expected.not_to contain_file(ssh_config_path)
          is_expected.not_to contain_file(known_hosts_path)
          expect(content_of(dropin)).not_to include('deploy_key')
          expect(YAML.safe_load(content_of(agent_config)).fetch('engine')).not_to have_key('ssh_config')
        end

        it 'declares nothing under /root and no File_line (root ssh setup is never touched)' do
          expect(resources_under_root).to be_empty
          expect(catalogue.resources.select { |r| r.type == 'File_line' }).to be_empty
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

      context 'with an r10k_config outside /etc/puppetlabs/r10k (MOD-WR-02)' do
        let(:params) { super().merge('r10k_config' => '/etc/stagehand/r10k.yaml') }

        it { is_expected.to compile.with_all_deps }

        it "manages that file's own directory, readable through the puppet group, before the file" do
          is_expected.to contain_file('/etc/stagehand').with(ensure: 'directory', owner: 'root', group: 'puppet', mode: '0750')
          is_expected.to contain_file('/etc/stagehand/r10k.yaml').that_requires('File[/etc/stagehand]')
        end

        it 'no longer manages the default r10k directory' do
          is_expected.not_to contain_file('/etc/puppetlabs/r10k')
        end

        it 'points the agent at that file' do
          expect(YAML.safe_load(content_of(agent_config)).dig('engine', 'config_path')).to eq('/etc/stagehand/r10k.yaml')
        end
      end

      context 'with the default r10k_config' do
        it 'manages the directory of the config file exactly once' do
          expect(catalogue.resources.select { |r| r.type == 'File' && r.title == '/etc/puppetlabs/r10k' }.length).to eq(1)
          is_expected.to contain_file(r10k_yaml).that_requires('File[/etc/puppetlabs/r10k]')
        end
      end

      context 'with a cachedir that is the r10k_config directory (MOD-WR-03)' do
        let(:params) { super().merge('cachedir' => '/etc/puppetlabs/r10k') }

        it { is_expected.to compile.and_raise_error(%r{cachedir.*r10k_config|r10k_config.*cachedir}) }
      end

      ['/etc/r10k.yaml', '/r10k.yaml', '/etc/puppetlabs/r10k.yaml', '/opt/puppetlabs/r10k.yaml'].each do |config|
        context "with r10k_config #{config}, whose directory is shared with the rest of the system" do
          let(:params) { super().merge('r10k_config' => config) }

          it 'is refused rather than taking ownership of that directory' do
            is_expected.to compile.and_raise_error(%r{r10k_config.*own directory})
          end
        end
      end

      context 'with port 0 (MOD-IN-02)' do
        let(:params) { super().merge('port' => 0) }

        it { is_expected.to compile.and_raise_error(%r{port}) }
      end

      context 'with port 65536' do
        let(:params) { super().merge('port' => 65_536) }

        it { is_expected.to compile.and_raise_error(%r{port}) }
      end

      %w[0s 0m 0h 00s 500ms 2us 1.5s 15 m].each do |timeout|
        context "with deploy_timeout #{timeout.inspect}" do
          let(:params) { super().merge('deploy_timeout' => timeout) }

          it { is_expected.to compile.and_raise_error(%r{deploy_timeout}) }
        end
      end

      %w[1s 90s 15m 1h 2m30s 1h0m1s].each do |timeout|
        context "with deploy_timeout #{timeout.inspect}" do
          let(:params) { super().merge('deploy_timeout' => timeout) }

          it { is_expected.to compile.with_all_deps }

          it 'renders it for the agent' do
            expect(YAML.safe_load(content_of(agent_config)).dig('deploys', 'timeout')).to eq(timeout)
          end
        end
      end

      context 'the package cache directory (MOD-IN-03)' do
        it 'is purged down to the current package file' do
          is_expected.to contain_file('/var/cache/stagehand-deploy-agent').with(
            ensure: 'directory', owner: 'root', group: 'root', mode: '0750', purge: true, recurse: true, force: true,
          )
        end

        it 'has the current package file as its only managed child' do
          children = catalogue.resources.select do |r|
            r.type == 'File' && (r[:path] || r.title).to_s.start_with?('/var/cache/stagehand-deploy-agent/')
          end
          expect(children.map(&:title)).to eq([pkg_path])
        end
      end

      context 'the rendered r10k.yaml (MOD-IN-04)' do
        it 'is structurally valid YAML with the control source nested under sources' do
          config = YAML.safe_load(content_of(r10k_yaml))
          expect(config.dig('sources', 'control', 'remote')).to eq(control_remote)
          expect(config.dig('sources', 'control', 'basedir')).to eq('/etc/puppetlabs/code/environments')
          expect(config.dig('sources', 'control', 'prefix')).to be(false)
          expect(config['cachedir']).to eq('/opt/puppetlabs/puppet/cache/r10k')
        end
      end

      context 'with an http:// agent_package_source (T-57.6-18)' do
        let(:params) { super().merge('agent_package_source' => "http://releases.example.test/stagehand-deploy-agent.#{debian ? 'deb' : 'rpm'}") }

        it { is_expected.to compile.and_raise_error(%r{agent_package_source}) }
      end

      context 'on an unsupported OS family' do
        let(:facts) do
          os_facts.merge(puppetversion: '8.10.0', stagehand_systemd_version: 255, os: os_facts[:os].merge('family' => 'Suse'))
        end

        it { is_expected.to compile.and_raise_error(%r{unsupported OS family 'Suse'}) }
      end

      context 'with engine g10k and an SSH control remote' do
        let(:params) do
          super().merge(
            'engine' => 'g10k',
            'g10k_command_path' => '/usr/local/bin/g10k',
            'control_remote' => 'git@github.com:example/control-repo.git',
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/etc/stagehand-deploy-agent/deploy_key',
            'git_ssh_known_host' => 'github.com ssh-ed25519 AAAAexamplehostkey',
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'renders g10k and the pinned ssh_config together' do
          engine = YAML.safe_load(content_of(agent_config)).fetch('engine')
          expect(engine).to include('name' => 'g10k', 'command_path' => '/usr/local/bin/g10k', 'ssh_config' => ssh_config_path)
          is_expected.to contain_file(ssh_config_path)
          expect(content_of(dropin)).to include('LoadCredential=deploy_key:/etc/stagehand-deploy-agent/deploy_key')
        end
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

      context 'with an SSH control remote' do
        def known_host
          'github.com ssh-ed25519 AAAAexamplehostkey'
        end
        let(:params) do
          super().merge(
            'control_remote' => 'git@github.com:example/control-repo.git',
            'git_ssh_host' => 'github.com',
            'git_ssh_key' => '/etc/stagehand-deploy-agent/deploy_key',
            'git_ssh_known_host' => known_host,
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes the agent ssh_config (owner the agent user, 0600) exactly as the reviewed fixture' do
          is_expected.to contain_file(ssh_config_path).with(ensure: 'file', owner: agent_user, group: 'puppet', mode: '0600')
          expect(content_of(ssh_config_path)).to eq(File.read(File.join(__dir__, '..', 'expected', 'webhook', 'ssh_config')))
        end

        it 'pins every host, refuses unknown ones and ignores every other ssh configuration' do
          content = content_of(ssh_config_path)
          expect(content).to match(%r{^Host \*$})
          expect(content).to include('StrictHostKeyChecking yes')
          expect(content).to include('UserKnownHostsFile "/etc/stagehand-deploy-agent/known_hosts"')
          expect(content).to include('GlobalKnownHostsFile /dev/null')
          expect(content).to include('IdentitiesOnly yes')
          expect(content).to include('IdentityAgent none')
          expect(content).to include('BatchMode yes')
          expect(content).to include('IdentityFile "/run/credentials/stagehand-deploy-agent.service/deploy_key"')
        end

        it 'writes the operator-supplied host key line into the pinned known_hosts file' do
          is_expected.to contain_file(known_hosts_path).with(
            ensure: 'file', owner: agent_user, group: 'puppet', mode: '0644', content: "#{known_host}\n",
          )
        end

        it 'passes the deploy key as a second systemd credential, after the Puppet key' do
          lines = content_of(dropin).lines.grep(%r{^LoadCredential=}).map(&:chomp)
          expect(lines).to eq([
                                'LoadCredential=server.key:/etc/puppetlabs/puppet/ssl/private_keys/primary.example.test.pem',
                                'LoadCredential=deploy_key:/etc/stagehand-deploy-agent/deploy_key',
                              ])
        end

        it 'tells the agent which ssh_config to use' do
          expect(YAML.safe_load(content_of(agent_config)).dig('engine', 'ssh_config')).to eq(ssh_config_path)
        end

        it 'has both ssh files in place before the service starts, and restarts it when they change' do
          [ssh_config_path, known_hosts_path].each do |path|
            is_expected.to contain_service('stagehand-deploy-agent').that_requires("File[#{path}]")
            is_expected.to contain_service('stagehand-deploy-agent').that_subscribes_to("File[#{path}]")
          end
        end

        it 'declares nothing under /root and no File_line' do
          expect(resources_under_root).to be_empty
          expect(catalogue.resources.select { |r| r.type == 'File_line' }).to be_empty
        end

        it 'does not change anything under the Puppet ssl directory' do
          paths = catalogue.resources.select { |r| r.type == 'File' }.map { |r| (r[:path] || r.title).to_s }
          expect(paths.grep(%r{\A/etc/puppetlabs/puppet/ssl})).to be_empty
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

      # Phase 57.6.2 D-02 / D-01 / RESEARCH Pitfall 3: one Puppet run takes a
      # primary that runs webhook-go as root to the agent. The order is the
      # point: stop the old service under its own deploy lock, remove its
      # package, install the agent, import the history, hand over ownership
      # under the agent's lock, start the agent.
      context 'the cutover from webhook-go (D-02)' do
        let(:cutover) { '/usr/local/sbin/stagehand-webhook-cutover' }
        let(:stop_legacy) { 'Exec[stagehand-webhook-stop-legacy]' }
        let(:old_package) { 'Package[webhook-go]' }
        let(:agent_package) { 'Package[stagehand-deploy-agent]' }
        let(:import) { 'Exec[stagehand-deploy-agent-import-history]' }
        let(:own) { 'Exec[stagehand-deploy-agent-own]' }
        let(:marker) { '/etc/stagehand-deploy-agent/.webhook-go-history-imported' }

        it { is_expected.to compile.with_all_deps }

        it 'installs the cutover script root-only from the module' do
          is_expected.to contain_file(cutover).with(
            ensure: 'file', owner: 'root', group: 'root', mode: '0750',
            source: 'puppet:///modules/stagehand/webhook-cutover.sh',
          )
        end

        it 'stops the old service only when a legacy unit exists, through the script, with the legacy state dir' do
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').with(
            command: [cutover, 'stop-legacy', '/var/lib/webhook-go'],
            onlyif: [[cutover, 'has-legacy']],
          ).that_requires("File[#{cutover}]")
        end

        it 'runs the run_as guard first, so nothing is stopped for a catalog that would be refused anyway' do
          is_expected.to contain_exec('stagehand-deploy-agent-run-as-not-uid0').that_comes_before(stop_legacy)
        end

        it 'stops the old service before anything is removed, installed or handed over' do
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before(old_package)
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before(agent_package)
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before('File[/etc/puppetlabs/code/environments]')
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before('File[/opt/puppetlabs/puppet/cache/r10k]')
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before(import)
          is_expected.to contain_exec('stagehand-webhook-stop-legacy').that_comes_before(own)
        end

        it 'removes the old package with the OS provider, before the agent package is installed (Pitfall 3)' do
          is_expected.to contain_package('webhook-go').with(ensure: 'absent', provider: debian ? 'dpkg' : 'rpm')
                                                      .that_comes_before(agent_package)
        end

        it 'removes the old drop-in directory, config and package cache only after the guarded stop' do
          is_expected.to contain_file('/etc/systemd/system/webhook-go.service.d').with(ensure: 'absent', force: true)
                                                                                 .that_requires(stop_legacy)
          is_expected.to contain_file('/etc/voxpupuli/webhook.yml').with(ensure: 'absent').that_requires(stop_legacy)
          is_expected.to contain_file('/var/cache/stagehand-webhook').with(ensure: 'absent', force: true).that_requires(stop_legacy)
        end

        it 'reloads systemd when the old drop-in directory goes' do
          is_expected.to contain_file('/etc/systemd/system/webhook-go.service.d').that_notifies('Exec[stagehand-deploy-agent-systemd-reload]')
        end

        it 'imports the history once, after the agent and its config exist, using the legacy state dir' do
          is_expected.to contain_exec('stagehand-deploy-agent-import-history').with(
            command: [cutover, 'import', '/var/lib/webhook-go', agent_config, marker],
            onlyif: [['/usr/bin/test', '-d', '/var/lib/webhook-go/jobs']],
            creates: marker,
          ).that_requires(agent_package).that_requires("File[#{agent_config}]")
        end

        it 'imports before ownership is handed over, and hands over before the service starts' do
          is_expected.to contain_exec('stagehand-deploy-agent-import-history').that_comes_before(own)
          is_expected.to contain_exec('stagehand-deploy-agent-own').that_comes_before('Service[stagehand-deploy-agent]')
        end

        it 'hands over only when something is not owned, under the agent deploy lock, for the three directories' do
          dirs = ['/etc/puppetlabs/code/environments', '/opt/puppetlabs/puppet/cache/r10k', '/var/lib/stagehand-deploy-agent']
          is_expected.to contain_exec('stagehand-deploy-agent-own').with(
            command: [cutover, 'own', '/var/lib/stagehand-deploy-agent/deploy.lock', agent_user, 'puppet'] + dirs,
            unless: [[cutover, 'owned', agent_user] + dirs],
          ).that_requires(agent_package)
        end

        it 'needs the directories to exist before it hands them over' do
          is_expected.to contain_exec('stagehand-deploy-agent-own').that_requires('File[/etc/puppetlabs/code/environments]')
          is_expected.to contain_exec('stagehand-deploy-agent-own').that_requires('File[/opt/puppetlabs/puppet/cache/r10k]')
          is_expected.to contain_exec('stagehand-deploy-agent-own').that_requires('File[/var/lib/stagehand-deploy-agent]')
        end

        it 'touches nothing under /root and no File_line (D-03)' do
          expect(resources_under_root).to be_empty
          expect(catalogue.resources.select { |r| r.type == 'File_line' }).to be_empty
        end

        context 'with legacy_state_dir set' do
          let(:params) { super().merge('legacy_state_dir' => '/srv/webhook-state') }

          it 'uses it for the stop and the import' do
            is_expected.to contain_exec('stagehand-webhook-stop-legacy').with(command: [cutover, 'stop-legacy', '/srv/webhook-state'])
            is_expected.to contain_exec('stagehand-deploy-agent-import-history').with(
              command: [cutover, 'import', '/srv/webhook-state', agent_config, marker],
              onlyif: [['/usr/bin/test', '-d', '/srv/webhook-state/jobs']],
            )
          end
        end

        context 'with a state_dir that is not the default' do
          let(:params) { super().merge('state_dir' => '/srv/stagehand/state') }

          it 'takes the agent deploy lock from that directory' do
            is_expected.to contain_exec('stagehand-deploy-agent-own').with_command(
              [cutover, 'own', '/srv/stagehand/state/deploy.lock', agent_user, 'puppet',
               '/etc/puppetlabs/code/environments', '/opt/puppetlabs/puppet/cache/r10k', '/srv/stagehand/state'],
            )
          end
        end

        context 'with a run_as that is not the default' do
          let(:params) { super().merge('run_as' => 'deployer') }

          it 'hands over to that user' do
            is_expected.to contain_exec('stagehand-deploy-agent-own').with_command(
              [cutover, 'own', '/var/lib/stagehand-deploy-agent/deploy.lock', 'deployer', 'puppet',
               '/etc/puppetlabs/code/environments', '/opt/puppetlabs/puppet/cache/r10k', '/var/lib/stagehand-deploy-agent'],
            )
          end
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
