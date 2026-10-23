# stagehand::hiera_data — Hiera data_hash backend for the Puppet Core
# Console's Data Service (docs/design/data-service.md §5).
#
# Ships in the stagehand module at:
#   lib/puppet/functions/stagehand/hiera_data.rb
#
# hiera.yaml:
#   - name: "Console data"
#     data_hash: stagehand::hiera_data
#     uris:
#       - "nodes/%{trusted.certname}"
#       - "group/%{trusted.external.psh.primary_group}"
#       - "common"
#     options:
#       config: /etc/puppetlabs/psh/client.yaml   # baseuri, token, cache_dir
#       on_error: use_cache    # use_cache | continue | fail
#
# Behavior contract (mirrors internal/externaldata):
#   - 200 → fold [{level,key,value},…] to {key => value}, refresh the
#     per-level last-good cache, return it. An empty level is a real answer
#     (returns {}), refreshing the cache too.
#   - transport failure / non-200 → on_error:
#       use_cache (default): serve last-good cache; no cache → behave as
#                            "continue" (backend skipped for this level).
#       continue:            context.not_found (level contributes nothing).
#       fail:                raise (PDS-compatible strictness; compilation
#                            fails — opt-in only).
#   - Levels are opaque strings; they are URL-encoded into the query param.
require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'fileutils'

Puppet::Functions.create_function(:'stagehand::hiera_data') do
  dispatch :hiera_data do
    param 'Struct[{uri => String[1], Optional[config] => String[1], Optional[baseuri] => String[1], Optional[token] => String[1], Optional[cache_dir] => String[1], Optional[on_error] => Enum[use_cache, continue, fail], Optional[timeout] => Integer[1]}]', :options
    param 'Puppet::LookupContext', :context
  end

  DEFAULT_CONFIG    = '/etc/puppetlabs/psh/client.yaml'.freeze
  DEFAULT_CACHE_DIR = '/opt/puppetlabs/server/data/psh-hiera-cache'.freeze

  def hiera_data(options, context)
    level = options['uri']
    cfg   = load_config(options)

    if cfg['baseuri'].nil? || cfg['baseuri'].empty?
      context.explain { 'stagehand::hiera_data: no baseuri configured; skipping' }
      context.not_found
    end

    body = fetch(cfg, level, context)
    if body
      data = fold(body, level, context)
      write_cache(cfg, level, data, context) unless data.nil?
      return data unless data.nil?
      # Unparseable body counts as a failure below.
    end

    case options['on_error'] || 'use_cache'
    when 'fail'
      raise Puppet::DataBinding::LookupError,
            "stagehand::hiera_data: level '#{level}' unavailable from #{cfg['baseuri']} and on_error=fail"
    when 'continue'
      context.not_found
    else # use_cache
      cached = read_cache(cfg, level, context)
      return cached unless cached.nil?
      context.explain { "stagehand::hiera_data: no cache for level '#{level}'; continuing" }
      context.not_found
    end
  end

  private

  # Flat "key: value" subset parser — same file the Go client reads; no YAML
  # dependency by design.
  def load_config(options)
    cfg = { 'cache_dir' => DEFAULT_CACHE_DIR }
    path = options['config'] || DEFAULT_CONFIG
    if File.readable?(path)
      File.readlines(path).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        k, _, v = line.partition(':')
        next if v.empty?
        cfg[k.strip] = v.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      end
    end
    %w[baseuri token cache_dir].each do |k|
      cfg[k] = options[k] if options[k]
    end
    cfg
  end

  def fetch(cfg, level, context)
    uri = URI.parse(cfg['baseuri'].chomp('/') + '/api/v1/hiera-data?level=' + URI.encode_www_form_component(level))
    timeout = 10
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = timeout
    http.read_timeout = timeout
    if http.use_ssl? && cfg['ca_file'] && File.readable?(cfg['ca_file'])
      http.ca_file = cfg['ca_file']
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
    req = Net::HTTP::Get.new(uri.request_uri)
    req['Accept'] = 'application/json'
    req['Authorization'] = "Bearer #{cfg['token']}" if cfg['token'] && !cfg['token'].empty?
    resp = http.request(req)
    unless resp.is_a?(Net::HTTPOK)
      context.explain { "stagehand::hiera_data: #{uri.host}:#{uri.port} returned #{resp.code} for level '#{level}'" }
      return nil
    end
    resp.body
  rescue StandardError => e
    context.explain { "stagehand::hiera_data: fetch failed for level '#{level}': #{e.class}: #{e.message}" }
    nil
  end

  def fold(body, level, context)
    rows = JSON.parse(body)
    return nil unless rows.is_a?(Array)
    rows.each_with_object({}) { |row, h| h[row['key']] = row['value'] if row.is_a?(Hash) && row['key'] }
  rescue JSON::ParserError => e
    context.explain { "stagehand::hiera_data: bad JSON for level '#{level}': #{e.message}" }
    nil
  end

  def cache_path(cfg, level)
    File.join(cfg['cache_dir'], Digest::SHA256.hexdigest(level) + '.json')
  end

  def write_cache(cfg, level, data, context)
    dir = cfg['cache_dir']
    # The cache holds resolved secret:// values in plaintext (audit U31), so
    # nothing here may depend on the server's umask: a directory this function
    # creates is closed to group and others (a umask can only remove bits from
    # the mode, never add them), and the temp file is created 0600 with O_EXCL
    # (never reusing or following an existing path) before any byte is written.
    FileUtils.mkdir_p(dir, mode: 0o700) unless Dir.exist?(dir)
    tmp = File.join(dir, ".psh-hiera-#{Process.pid}-#{rand(1_000_000)}")
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.generate(data)) }
    File.rename(tmp, cache_path(cfg, level))
  rescue StandardError => e
    context.explain { "stagehand::hiera_data: cache write failed for '#{level}': #{e.message}" }
    begin
      File.delete(tmp) if tmp && File.exist?(tmp)
    rescue StandardError
      # best effort
    end
  end

  def read_cache(cfg, level, context)
    path = cache_path(cfg, level)
    return nil unless File.readable?(path)
    data = JSON.parse(File.read(path))
    context.explain { "stagehand::hiera_data: serving last-good cache for level '#{level}'" }
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end
end
