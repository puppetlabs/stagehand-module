# frozen_string_literal: true

require 'spec_helper'

# Covers stagehand::console::k3s -- the manifests-directory-rendering
# sibling of stagehand::console::docker (see console_docker_spec.rb).
# No hand-rolled Exec, no Kubernetes/Helm CLI invocation anywhere: this
# class's entire job is rendering Hiera-supplied values into `file`
# resources that k3s's own helm-controller / manifest-deploy controller
# reconciles.
#
# Plan 02 expands Plan 01's Zot-only tracer to the full Console profile:
# the console workload and PostgreSQL (CloudNativePG), plus the first
# Kubernetes Secret this class renders (db password, ingest token,
# dataservice token) -- the secret-handling path Zot's own configuration
# never exercised.
describe 'stagehand::console::k3s' do
  let(:valid_image_ref) do
    "ghcr.io/puppet-stagehand/console@sha256:#{'a' * 64}"
  end

  let(:test_db_password) { 's3cr3t-db-password' }
  let(:test_ingest_token) { 's3cr3t-ingest-token' }
  let(:test_dataservice_token) { 's3cr3t-dataservice-token' }

  let(:required_params) do
    {
      'sizing_tier' => 'small',
      'image_ref' => valid_image_ref,
      'db_password' => sensitive(test_db_password),
      'ingest_token' => sensitive(test_ingest_token),
      'dataservice_token' => sensitive(test_dataservice_token),
    }
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context "with ensure => 'present' (default)" do
        let(:params) { required_params }

        it { is_expected.to compile.with_all_deps }

        it { is_expected.to contain_class('stagehand::console::k3s') }

        # --- Plan 01's two Zot resources, unchanged ---

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml')
            .with_ensure('file')
            .with_owner('root')
            .with_group('root')
            .with_mode('0644')
        }

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml')
            .with_content(%r{0\.1\.124})
            .with_content(%r{v2\.1\.21})
        }

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot-networkpolicy.yaml')
            .with_ensure('file')
            .with_owner('root')
            .with_group('root')
            .with_mode('0644')
        }

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot-networkpolicy.yaml')
            .with_content(%r{Ingress})
        }

        # --- Plan 02's three new resources: console, PostgreSQL, Secret ---

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')
            .with_ensure('file')
            .with_owner('root')
            .with_group('root')
            .with_mode('0644')
        }

        it {
          is_expected.to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-postgresql.yaml')
            .with_ensure('file')
            .with_owner('root')
            .with_group('root')
            .with_mode('0644')
        }

        it 'renders exactly five File resources under manifests_dir' do
          file_resources = catalogue.resources.select do |r|
            r.type == 'File' && r.title.to_s.start_with?('/var/lib/rancher/k3s/server/manifests/')
          end
          expect(file_resources.length).to eq(5)
        end

        it 'declares no Exec resource for the apply loop' do
          catalogue.resources.each do |resource|
            expect(resource.type).not_to eq('Exec')
          end
        end

        describe 'the Secret manifest' do
          subject { catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-secrets.yaml') }

          it 'exists' do
            expect(subject).not_to be_nil
          end

          it 'is ensure file' do
            expect(subject[:ensure]).to eq('file')
          end

          it 'is owned by root:root' do
            expect(subject[:owner]).to eq('root')
            expect(subject[:group]).to eq('root')
          end

          it 'is mode 0600' do
            expect(subject[:mode]).to eq('0600')
          end

          it 'suppresses Puppet diff output' do
            expect(subject[:show_diff]).to be(false)
          end

          it 'renders the three secret values via stringData' do
            content = subject[:content]
            expect(content).to include(test_db_password)
            expect(content).to include(test_ingest_token)
            expect(content).to include(test_dataservice_token)
            expect(content).to include('stagehand-console-secrets')
          end
        end

        it 'is the only File resource carrying secret material (mode 0600)' do
          secret_mode_files = catalogue.resources.select { |r| r.type == 'File' && r[:mode] == '0600' }
          expect(secret_mode_files.length).to eq(1)
        end

        it 'is the only File resource with show_diff set' do
          with_show_diff = catalogue.resources.select { |r| r.type == 'File' && !r[:show_diff].nil? }
          expect(with_show_diff.length).to eq(1)
        end

        it 'does not leak the database password into the console manifest' do
          console_content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')[:content]
          expect(console_content).not_to include(test_db_password)
          expect(console_content).not_to include(test_ingest_token)
          expect(console_content).not_to include(test_dataservice_token)
        end

        it 'does not leak the database password into the PostgreSQL manifest' do
          pg_content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-postgresql.yaml')[:content]
          expect(pg_content).not_to include(test_db_password)
        end

        it 'the console manifest references the Secret by name (secretKeyRef)' do
          console_content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')[:content]
          expect(console_content).to match(%r{secretKeyRef})
          expect(console_content).to match(%r{stagehand-console-secrets})
          expect(console_content).to match(%r{PSH_DATABASE_URL})
        end

        it 'the console image is rendered from the typed, digest-pinned $image_ref' do
          console_content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')[:content]
          expect(console_content).to include("sha256:#{'a' * 64}")
        end
      end

      context 'with a non-default manifests_dir' do
        let(:params) { required_params.merge('manifests_dir' => '/opt/stagehand-lab-manifests') }

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/opt/stagehand-lab-manifests/stagehand-zot.yaml')
        }

        it {
          is_expected.to contain_file('/opt/stagehand-lab-manifests/stagehand-console.yaml')
        }

        it {
          is_expected.to contain_file('/opt/stagehand-lab-manifests/stagehand-postgresql.yaml')
        }

        it {
          is_expected.to contain_file('/opt/stagehand-lab-manifests/stagehand-secrets.yaml')
        }

        it {
          is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml')
        }
      end

      context "with ensure => 'absent'" do
        let(:params) { required_params.merge('ensure' => 'absent') }

        it { is_expected.to compile.with_all_deps }

        # Removal path: this class stops declaring the rendered files
        # entirely (a disclosed limitation, see k3s.pp's doc-comment) --
        # it does not retract already-applied k8s resources.
        it { is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml') }
        it { is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-zot-networkpolicy.yaml') }
        it { is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml') }
        it { is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-postgresql.yaml') }
        it { is_expected.not_to contain_file('/var/lib/rancher/k3s/server/manifests/stagehand-secrets.yaml') }

        it 'declares none of the five File resources' do
          file_resources = catalogue.resources.select do |r|
            r.type == 'File' && r.title.to_s.start_with?('/var/lib/rancher/k3s/server/manifests/')
          end
          expect(file_resources).to be_empty
        end
      end

      context "with sizing_tier => 'small'" do
        let(:params) { required_params.merge('sizing_tier' => 'small') }

        it 'renders the small-tier console resource requests' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')[:content]
          expect(content).to include('cpu: "250m"')
        end

        it 'renders the small-tier PostgreSQL storage size' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-postgresql.yaml')[:content]
          expect(content).to include('size: 10Gi')
        end

        it 'renders the small-tier Zot storage size (Plan 01, unmodified)' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml')[:content]
          expect(content).to include('storage: 5Gi')
        end
      end

      context "with sizing_tier => 'medium'" do
        let(:params) { required_params.merge('sizing_tier' => 'medium') }

        it 'renders different console resource requests than the small tier' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-console.yaml')[:content]
          expect(content).to include('cpu: "500m"')
          expect(content).not_to include('cpu: "250m"')
        end

        it 'renders different PostgreSQL storage than the small tier' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-postgresql.yaml')[:content]
          expect(content).to include('size: 50Gi')
          expect(content).not_to include('size: 10Gi')
        end

        it 'renders different Zot storage than the small tier (Plan 01, unmodified)' do
          content = catalogue.resource('File', '/var/lib/rancher/k3s/server/manifests/stagehand-zot.yaml')[:content]
          expect(content).to include('storage: 20Gi')
          expect(content).not_to include('storage: 5Gi')
        end
      end
    end
  end

  context 'with an out-of-enum sizing_tier' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('sizing_tier' => 'enormous') }

    it 'fails to compile' do
      expect { catalogue }.to raise_error(Puppet::Error, %r{sizing_tier})
    end
  end

  context 'with a relative manifests_dir' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('manifests_dir' => 'relative/path') }

    it 'fails to compile' do
      expect { catalogue }.to raise_error(Puppet::Error)
    end
  end

  context 'with manage_k3s => true (unimplemented escape hatch)' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('manage_k3s' => true) }

    it 'fails to compile with a message naming the deliberate omission' do
      expect { catalogue }.to raise_error(Puppet::Error, %r{k3s installation is deliberately unimplemented})
    end
  end

  context 'with a malformed image_ref (no digest suffix)' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('image_ref' => 'ghcr.io/puppet-stagehand/console:latest') }

    it 'fails to compile' do
      expect { catalogue }.to raise_error(Puppet::Error, %r{image_ref})
    end
  end

  context 'with a malformed image_ref (non-hex digest)' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('image_ref' => "ghcr.io/puppet-stagehand/console@sha256:#{'z' * 64}") }

    it 'fails to compile' do
      expect { catalogue }.to raise_error(Puppet::Error, %r{image_ref})
    end
  end

  context 'with a malformed image_ref (short digest)' do
    let(:facts) { on_supported_os.first[1] }
    let(:params) { required_params.merge('image_ref' => "ghcr.io/puppet-stagehand/console@sha256:#{'a' * 10}") }

    it 'fails to compile' do
      expect { catalogue }.to raise_error(Puppet::Error, %r{image_ref})
    end
  end
end
