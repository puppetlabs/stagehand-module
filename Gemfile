# Managed by modulesync - DO NOT EDIT
# https://voxpupuli.org/docs/updating-files-managed-with-modulesync/

source ENV['GEM_SOURCE'] || 'https://rubygems.org'

# CI_PUPPET_GEM_NAME/CI_PUPPET_GEM_VERSION let the release CI matrix (see
# .github/workflows/ci.yml) select Puppet Core vs OpenVox and a version
# range without editing this file per leg. OpenVox ships as the "openvox"
# gem but is a drop-in for the "puppet" gem's own Puppet:: Ruby namespace,
# so rspec-puppet/rspec-puppet-facts work unchanged against either — this
# is purely a gem-name/version swap, no test code branches on which one is
# loaded. Local `bundle install` with no env vars keeps the split repo's
# supported Puppet range (>= 7, < 9).

group :test do
  gem 'voxpupuli-test', '~> 14.0',  :require => false
  gem 'puppet_metadata', '~> 6.1',  :require => false
  # Without this gem, puppetlabs_spec_helper's metadata_lint rake task
  # silently skips ("the metadata-json-lint gem was not found") instead of
  # failing -- a validate/lint/metadata_lint CI job that can't actually
  # fail on bad metadata.json is a check in name only.
  gem 'metadata-json-lint', '~> 4.0', :require => false
end

group :development do
  gem 'guard-rake',               :require => false
  gem 'overcommit', '>= 0.39.1',  :require => false
end

# puppet_litmus pulls in `bolt`, which hard-requires the `puppet` gem
# (`puppet >= 6.18.0`), which in turn caps puppet-resource_api at `~> 1.5`.
# openvox >= 8.24 (which includes every openvox9 pre-release currently on
# rubygems.org -- 9.0.0.pre.alpha2/pre.beta1/pre.beta2) requires
# puppet-resource_api `~> 2.0`, so the two are mutually unresolvable in one
# bundle. There is no meaningful litmus/acceptance target for the openvox9
# beta line anyway (see ci.yml's openvox9-beta job: dependency-resolution
# only, continue-on-error), so skip this group entirely for that scenario
# rather than let Bundler's resolver fail closed on an unresolvable graph.
# The version can arrive as a requirement ("~> 9.0", ">= 9.0" from the
# voxpupuli matrix's OPENVOX_GEM_VERSION) as well as a bare "9.0.1", so 9.
# is matched at the start or after whitespace.
openvox_gem_version = ENV['OPENVOX_GEM_VERSION'] ||
                      (ENV['CI_PUPPET_GEM_NAME'] == 'openvox' ? ENV['CI_PUPPET_GEM_VERSION'] : nil)
skip_system_tests_for_openvox_beta = openvox_gem_version && openvox_gem_version.match?(/(\A|\s)9\.|pre|beta|alpha/i)

group :system_tests do
  gem 'puppet_litmus', '~> 2.5', :require => false
  gem 'voxpupuli-acceptance', '~> 4.4',  :require => false
end unless skip_system_tests_for_openvox_beta

group :release do
  gem 'voxpupuli-release', '~> 5.3',  :require => false
end

gem 'rake', :require => false

# `puppet` and `openvox` cannot be declared into the bundle at the same
# time once openvox reaches its >= 8.24 line: those releases require
# puppet-resource_api ~> 2.0, while every released `puppet` gem (up to the
# current 8.10.0 ceiling -- there is no puppet9 rubygem yet) requires
# puppet-resource_api ~> 1.5, so bundler cannot satisfy both at once. Each
# CI leg (puppet7/puppet8 vs openvox8/openvox9) only ever sets ONE of
# PUPPET_GEM_VERSION/OPENVOX_GEM_VERSION, so select exactly one gem here
# rather than declaring both unconditionally.
if ENV['CI_PUPPET_GEM_NAME'] == 'openvox' || ENV['OPENVOX_GEM_VERSION']
  gem 'openvox', ENV['CI_PUPPET_GEM_VERSION'] || ENV['OPENVOX_GEM_VERSION'], :require => false, :groups => [:test]
else
  gem 'puppet', ENV['CI_PUPPET_GEM_VERSION'] || ENV.fetch('PUPPET_GEM_VERSION', [">= 7", "< 9"]), :require => false, :groups => [:test]
end

# vim: syntax=ruby
