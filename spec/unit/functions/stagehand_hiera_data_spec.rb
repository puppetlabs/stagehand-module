# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'digest'

# U31 (audit finding): the Hiera fallback cache holds resolved `secret://`
# values in plaintext, so every file it writes must be private to the account
# that runs the lookup, whatever the process umask is.
describe 'stagehand::hiera_data (last-good cache permissions)' do
  let(:function) do
    klass = nil
    allow(Puppet::Functions).to receive(:create_function).and_wrap_original do |original, *args, &block|
      klass = original.call(*args, &block)
    end
    Kernel.load(File.expand_path('../../../lib/puppet/functions/stagehand/hiera_data.rb', __dir__))
    klass.new(nil, nil)
  end

  let(:context) do
    instance_double(Puppet::Pops::Lookup::Context).tap do |ctx|
      allow(ctx).to receive(:explain)
      allow(ctx).to receive(:not_found).and_raise(StopIteration, 'not_found')
    end
  end

  let(:level) { 'nodes/web01.example.com' }
  let(:secret_body) { JSON.generate([{ 'level' => level, 'key' => 'db::password', 'value' => 'hunter2-resolved' }]) }

  let(:workdir) { Dir.mktmpdir('psh-hiera-spec') }

  around do |example|
    old_umask = File.umask(0o022)
    begin
      example.run
    ensure
      File.umask(old_umask)
      FileUtils.rm_rf(workdir)
    end
  end

  def options(cache_dir)
    { 'uri' => level, 'baseuri' => 'https://console.example.test', 'cache_dir' => cache_dir, 'on_error' => 'use_cache' }
  end

  def cache_file(cache_dir)
    File.join(cache_dir, "#{Digest::SHA256.hexdigest(level)}.json")
  end

  def mode_of(path)
    File.stat(path).mode & 0o777
  end

  context 'when a lookup succeeds under the common 0022 umask' do
    let(:cache_dir) { File.join(workdir, 'psh-hiera-cache') }

    before { allow(function).to receive(:fetch).and_return(secret_body) }

    it 'returns the folded data unchanged' do
      expect(function.hiera_data(options(cache_dir), context)).to eq('db::password' => 'hunter2-resolved')
    end

    it 'writes the cache file readable only by its owner (0600)' do
      function.hiera_data(options(cache_dir), context)
      expect(mode_of(cache_file(cache_dir))).to eq(0o600)
    end

    it 'creates the cache directory closed to group and others (0700)' do
      function.hiera_data(options(cache_dir), context)
      expect(mode_of(cache_dir)).to eq(0o700)
    end

    it 'leaves no temporary file behind' do
      function.hiera_data(options(cache_dir), context)
      expect(Dir.children(cache_dir)).to eq([File.basename(cache_file(cache_dir))])
    end

    it 'replaces a world-readable cache file left by an earlier version with a 0600 one' do
      FileUtils.mkdir_p(cache_dir, mode: 0o750)
      File.write(cache_file(cache_dir), '{"stale":"value"}')
      File.chmod(0o644, cache_file(cache_dir))

      function.hiera_data(options(cache_dir), context)

      expect(mode_of(cache_file(cache_dir))).to eq(0o600)
      expect(JSON.parse(File.read(cache_file(cache_dir)))).to eq('db::password' => 'hunter2-resolved')
    end

    it 'still serves the last-good cache when the console is unreachable' do
      function.hiera_data(options(cache_dir), context)
      allow(function).to receive(:fetch).and_return(nil)

      expect(function.hiera_data(options(cache_dir), context)).to eq('db::password' => 'hunter2-resolved')
    end
  end

  context 'when the cache directory already exists' do
    let(:cache_dir) { File.join(workdir, 'existing-cache') }

    before do
      FileUtils.mkdir_p(cache_dir, mode: 0o750)
      allow(function).to receive(:fetch).and_return(secret_body)
    end

    it 'keeps the directory as it was and still writes the file as 0600' do
      function.hiera_data(options(cache_dir), context)
      expect(mode_of(cache_dir)).to eq(0o750)
      expect(mode_of(cache_file(cache_dir))).to eq(0o600)
    end
  end
end
