require 'spec_helper'
require 'digest'

# Covers stagehand::console (Tasks 2.1-2.3): binary/user/service/env install on the
# 'present'/'latest' path, and the 'absent' removal path (with the opt-in
# purge_data Postgres drop). console.pp has no OS-conditional logic (systemd
# paths and /usr/local/bin are hardcoded, independent of $facts['os']), so a
# single representative facts set is used rather than the full
# on_supported_os matrix -- that matrix earns its cost when a manifest
# branches on osfamily/release; this one doesn't.
describe 'stagehand::console' do
  let(:facts) { on_supported_os.first[1] }

  let(:required_params) do
    {
      'console_binary_source' => '/opt/staging/puppet-console',
      'db_password'           => sensitive('s3cr3t-db-password'),
      'ingest_token'          => sensitive('s3cr3t-ingest-token'),
      'dataservice_token'     => sensitive('s3cr3t-dataservice-token'),
    }
  end

  context "with ensure => 'present' (default)" do
    let(:params) { required_params }

    it { is_expected.to compile.with_all_deps }

    it { is_expected.to contain_class('stagehand::console') }

    it {
      is_expected.to contain_user('psh').with(
        ensure: 'present',
        system: true,
        home: '/var/lib/puppet-console',
        shell: '/bin/false',
      )
    }

    it {
      is_expected.to contain_file('/usr/local/bin/puppet-console').with(
        ensure: 'file',
        owner: 'root',
        group: 'root',
        mode: '0755',
        source: '/opt/staging/puppet-console',
      ).that_notifies('Service[puppet-console]')
    }

    it {
      is_expected.to contain_service('puppet-console').with(
        ensure: 'running',
        enable: true,
      )
    }

    it { is_expected.to contain_file('/etc/puppet-console').with_ensure('directory') }

    it {
      is_expected.to contain_file('/etc/puppet-console/console.env').with(
        ensure: 'file',
        show_diff: false,
      ).that_requires('File[/etc/puppet-console]').that_notifies('Service[puppet-console]')
    }

    it {
      is_expected.to contain_file('/etc/systemd/system/puppet-console.service').with(
        ensure: 'file',
      ).that_notifies('Exec[puppet-console-systemd-reload]')
    }

    it {
      is_expected.to contain_exec('puppet-console-systemd-reload').that_notifies('Service[puppet-console]')
    }

    it { is_expected.to contain_exec('stagehand::console::ca_cert').with_creates(%r{/etc/puppetlabs/puppet/ssl/certs/console\..+\.pem}) }

    it {
      is_expected.to contain_file('/etc/puppet-console/bolt-project').with_ensure('directory')
    }

    it {
      is_expected.to contain_file('/etc/puppet-console/bolt-project/bolt-project.yaml').with(
        ensure: 'file',
        require: 'File[/etc/puppet-console/bolt-project]',
      )
    }

    it {
      is_expected.to contain_file('/etc/puppet-console/bolt-project/inventory.yaml').with(
        ensure: 'file',
        require: 'File[/etc/puppet-console/bolt-project]',
      )
    }

    it {
      is_expected.to contain_exec('stagehand::console::pg_role').with(
        user: 'postgres',
        unless: %r{SELECT 1 FROM pg_roles WHERE rolname='psh'},
      )
    }

    it {
      is_expected.to contain_exec('stagehand::console::pg_role_password_sync').with(
        user: 'postgres',
        unless: %r{db_password\.sha256},
      )
    }

    it {
      is_expected.to contain_file('/etc/puppet-console-pg-state').with(
        ensure: 'directory',
        owner: 'postgres',
        group: 'postgres',
        mode: '0700',
      )
    }

    it {
      is_expected.to contain_exec('stagehand::console::pg_role_password_hash_record').with(
        user: 'postgres',
        refreshonly: true,
      ).that_subscribes_to('Exec[stagehand::console::pg_role_password_sync]')
    }

    it {
      is_expected.to contain_exec('stagehand::console::pg_db').with(
        command: 'createdb -O psh psh',
        unless: %r{SELECT 1 FROM pg_database WHERE datname='psh'},
        require: 'Exec[stagehand::console::pg_role]',
      )
    }

    # Since 7e72aaf1 the pg_hba append runs a script file via /bin/sh (the
    # exec provider can't run a command whose first word is a shell
    # variable assignment), so the exec requires that file as well as the
    # database. The reload notify is the part that matters most: a pg_hba
    # change that never reloads postgres leaves the console unable to log in.
    it {
      is_expected.to contain_exec('stagehand::console::pg_hba').with(
        command: '/bin/sh /etc/puppet-console-pg-state/pg_hba.sh',
      ).that_requires(
        [
          'Exec[stagehand::console::pg_db]',
          'File[/etc/puppet-console-pg-state/pg_hba.sh]',
        ],
      ).that_notifies('Exec[stagehand::console::pg_hba_reload]')
    }

    it {
      is_expected.to contain_file('/etc/puppet-console-pg-state/pg_hba.sh').with(
        ensure: 'file',
        owner: 'postgres',
        group: 'postgres',
        mode: '0700',
        content: %r{host    psh    psh    127\.0\.0\.1/32    scram-sha-256},
      )
    }

    it { is_expected.not_to contain_exec('stagehand::console::pg_db_drop') }
    it { is_expected.not_to contain_exec('stagehand::console::pg_role_drop') }

    it {
      is_expected.to contain_service('puppet-console').that_requires(
        [
          'Exec[stagehand::console::pg_role_password_sync]',
          'Exec[stagehand::console::pg_db]',
          'Exec[stagehand::console::pg_hba]',
        ],
      )
    }

    # 43-04: no-op proof -- a console-only install (no hierascope_* params)
    # declares no hierascope file resource, while still always ensuring
    # openssl (T-43-11, Phase 41's EYAML PKCS7 dependency).
    it { is_expected.not_to contain_file('/usr/local/bin/hierascope') }
    it { is_expected.to contain_package('openssl') }
  end

  # 43-04: hierascope staging + metadata pass-through. Values below are the
  # real known digest/key_id from 43-01/43-02 (d7508cc1...83868f,
  # FC69CC1D307726F5) for cross-plan consistency, even though this is a
  # Puppet-side unit test, not a live verification.
  context 'with hierascope configured' do
    let(:params) do
      required_params.merge(
        'hierascope_binary_source' => '/opt/staging/hierascope',
        'hierascope_version'       => '0.1.0',
        'hierascope_protocol'      => 'hierascope/v1',
        'hierascope_sha256'        => 'd7508cc1ffc11fed213a46c982e79b694a74726598e834358687a4dfce83868f',
        'hierascope_key_id'        => 'FC69CC1D307726F5',
        'hierascope_signature'     => 'line1\nline2',
        'hierascope_goos'          => 'linux',
        'hierascope_goarch'        => 'amd64',
      )
    end

    it { is_expected.to compile.with_all_deps }

    it {
      is_expected.to contain_file('/usr/local/bin/hierascope').with(
        ensure: 'file',
        owner: 'root',
        group: 'root',
        mode: '0755',
        source: '/opt/staging/hierascope',
      )
    }

    it { is_expected.to contain_package('openssl') }

    it 'renders console.env with all ten PSH_HIERASCOPE_* lines carrying the supplied values' do
      content = catalogue.resource('File', '/etc/puppet-console/console.env')[:content]
      expect(content).to include('PSH_HIERASCOPE_PATH=/usr/local/bin/hierascope')
      expect(content).to include('PSH_HIERASCOPE_VERSION=0.1.0')
      expect(content).to include('PSH_HIERASCOPE_PROTOCOL=hierascope/v1')
      expect(content).to include('PSH_HIERASCOPE_SHA256=d7508cc1ffc11fed213a46c982e79b694a74726598e834358687a4dfce83868f')
      expect(content).to include('PSH_HIERASCOPE_KEY_ID=FC69CC1D307726F5')
      expect(content).to include('PSH_HIERASCOPE_SIGNATURE=line1\nline2')
      expect(content).to include('PSH_HIERASCOPE_GOOS=linux')
      expect(content).to include('PSH_HIERASCOPE_GOARCH=amd64')
      expect(content).to include('PSH_HIERASCOPE_HIERA_CONFIG=')
      expect(content).to include('PSH_HIERASCOPE_PUPPET_MAJOR=')
    end
  end

  context "with ensure => 'absent'" do
    let(:params) { required_params.merge('ensure' => 'absent') }

    it { is_expected.to compile.with_all_deps }

    it {
      is_expected.to contain_service('puppet-console').with(
        ensure: 'stopped',
        enable: false,
      )
    }

    it { is_expected.to contain_file('/usr/local/bin/puppet-console').with_ensure('absent') }
    it { is_expected.to contain_file('/etc/systemd/system/puppet-console.service').with_ensure('absent') }
    it { is_expected.to contain_file('/etc/puppet-console').with_ensure('absent').with_force(true) }
    it { is_expected.to contain_file('/var/lib/puppet-console').with_ensure('absent').with_force(true) }
    # The pg-state marker dir lives outside config_dir (postgres can't
    # traverse config_dir's root:psh 0750), so it isn't swept up by
    # config_dir's recursive removal above and needs this dedicated cleanup.
    it { is_expected.to contain_file('/etc/puppet-console-pg-state').with_ensure('absent').with_force(true) }

    # Medium #2 fix: the service must actually stop before its unit file (and
    # binary) are removed, otherwise systemd may not be able to cleanly
    # stop/disable a service whose unit file is already gone. Assert the
    # explicit ordering edges rather than relying on declaration order, which
    # Puppet does not guarantee absent any relationship.
    it {
      is_expected.to contain_service('puppet-console').that_comes_before('File[/etc/systemd/system/puppet-console.service]')
    }

    it {
      is_expected.to contain_service('puppet-console').that_comes_before('File[/usr/local/bin/puppet-console]')
    }

    # Postgres role/db provisioning execs only exist on the present branch --
    # absent leaves any existing role/database alone.
    it { is_expected.not_to contain_exec('stagehand::console::pg_role') }
    it { is_expected.not_to contain_exec('stagehand::console::pg_role_password_sync') }
    it { is_expected.not_to contain_exec('stagehand::console::pg_db') }
    it { is_expected.not_to contain_exec('stagehand::console::pg_hba') }

    # purge_data defaults false, so the destructive drop execs are absent too.
    it { is_expected.not_to contain_exec('stagehand::console::pg_db_drop') }
    it { is_expected.not_to contain_exec('stagehand::console::pg_role_drop') }

    it { is_expected.not_to contain_user('psh') }

    it {
      is_expected.to contain_service('puppet-console').without_require
    }
  end

  context "with ensure => 'absent', purge_data => true" do
    let(:params) { required_params.merge('ensure' => 'absent', 'purge_data' => true) }

    it { is_expected.to compile.with_all_deps }

    it {
      is_expected.to contain_exec('stagehand::console::pg_db_drop').with(
        command: 'dropdb psh',
        user: 'postgres',
        onlyif: %r{SELECT 1 FROM pg_database WHERE datname='psh'},
      )
    }

    it {
      is_expected.to contain_exec('stagehand::console::pg_role_drop').with(
        command: 'dropuser psh',
        user: 'postgres',
        onlyif: %r{SELECT 1 FROM pg_roles WHERE rolname='psh'},
        require: 'Exec[stagehand::console::pg_db_drop]',
      )
    }
  end

  # "Idempotency" for a unit spec: rspec-puppet compiles a catalog once per
  # example -- it does not shell out to `puppet apply` twice against a real
  # system (that's an acceptance-test/onceover concern, out of scope here).
  # The unit-level proxy for idempotency is asserting that every exec that
  # runs an inherently non-idempotent shell command (CREATE ROLE, createdb,
  # dropdb/dropuser, appending to pg_hba.conf) carries the guard
  # (unless/onlyif/creates) that makes repeated Puppet runs a no-op. That's
  # what's asserted above (pg_role/pg_db/pg_hba unless, ca_cert creates,
  # pg_db_drop/pg_role_drop onlyif); this block asserts the two remaining
  # guarded execs not already covered per-branch above, plus confirms none
  # of the console's execs are missing a guard where the manifest intends one.
  context 'idempotency guards' do
    let(:params) { required_params }

    it 'guards the pg_hba append with a grep-based unless' do
      expect(subject).to contain_exec('stagehand::console::pg_hba').with_unless(%r{grep -q 'puppet-console'})
    end

    it 'guards the TLS cert generation with a creates-based check' do
      expect(subject).to contain_exec('stagehand::console::ca_cert').with_creates(%r{\.pem\z})
    end

    it 'the pg_hba reload exec is refresh-only (never runs standalone)' do
      expect(subject).to contain_exec('stagehand::console::pg_hba_reload').with_refreshonly(true)
    end

    it 'the systemd-reload exec is refresh-only (never runs standalone)' do
      expect(subject).to contain_exec('puppet-console-systemd-reload').with_refreshonly(true)
    end
  end

  # Medium #1 fix: pg_role_password_sync previously had no `unless` guard at
  # all, so it reported `changed` on every single apply. It's now guarded by
  # a SHA-256 marker file of the last-synced password -- a second apply with
  # an unchanged $db_password must compile the exact same `unless` guard
  # (deterministic, so it short-circuits and reports no change), while a
  # changed $db_password must produce a different guard (so the sync
  # actually re-runs).
  context 'pg_role_password_sync idempotency guard, unchanged password' do
    let(:params) { required_params }

    it 'compiles a deterministic unless guard containing the sha256 of the current password' do
      expected_hash = Digest::SHA256.hexdigest('s3cr3t-db-password')
      unless_guard = catalogue.resource('Exec', 'stagehand::console::pg_role_password_sync')[:unless]
      expect(unless_guard).to include(expected_hash)
    end
  end

  context 'pg_role_password_sync idempotency guard, changed password' do
    let(:params) { required_params.merge('db_password' => sensitive('a-totally-different-password')) }

    it 'compiles a different unless guard (containing the new password hash, not the old one)' do
      old_hash = Digest::SHA256.hexdigest('s3cr3t-db-password')
      new_hash = Digest::SHA256.hexdigest('a-totally-different-password')
      unless_guard = catalogue.resource('Exec', 'stagehand::console::pg_role_password_sync')[:unless]

      expect(unless_guard).to include(new_hash)
      expect(unless_guard).not_to include(old_hash)
    end
  end
end
