# @summary Converge one approved Puppet package release set for one or more VM roles.
#
# The installer selects entries from data/platform_contract_v1.json and passes
# them here. This class deliberately does not infer versions, repository tracks,
# or package placement. Role entries are validated and merged before any
# privileged package-manager resource is declared.
class stagehand::platform_lock (
  String[1]                  $release_set_id,
  Integer[1]                 $puppet_track,
  Array[Hash]                $roles,
  Pattern[/\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z/] $target_id,
  Pattern[/\A[0-9a-f]{64}\z/] $evidence_sha256,
  Boolean                    $write_manifest = true,
) {
  if $roles.empty {
    fail('stagehand::platform_lock requires at least one role')
  }
  $role_names = $roles.map |Hash $entry| { $entry['role'] }
  if $role_names.any |$role| { $role !~ Enum['agent', 'postgresql', 'puppet_server', 'puppetdb'] } {
    fail('stagehand::platform_lock received an unknown role')
  }
  if unique($role_names).length != $role_names.length {
    fail('stagehand::platform_lock received a duplicate role')
  }

  $allowed_packages = {
    'agent'         => ['puppet-agent'],
    'postgresql'    => ['puppet-agent'],
    'puppet_server' => ['puppet-agent', 'puppetdb-termini', 'puppetserver'],
    'puppetdb'      => ['puppet-agent', 'puppetdb'],
  }
  $required_packages = {
    'agent'         => ['puppet-agent'],
    'postgresql'    => [],
    'puppet_server' => ['puppet-agent', 'puppetserver'],
    'puppetdb'      => ['puppetdb'],
  }

  $roles.each |Hash $entry| {
    $role = $entry['role']
    unless $entry['packages'] =~ Array[Hash] and $entry['runtime'] =~ Hash {
      fail("stagehand::platform_lock role ${role} is missing packages or runtime data")
    }
    $entry['packages'].each |Hash $package| {
      unless $package['name'] =~ Pattern[/\A[a-zA-Z0-9][a-zA-Z0-9+_.-]*\z/] and $package['evr'] =~ Pattern[/\A[a-zA-Z0-9][a-zA-Z0-9+_.:~-]*\z/] {
        fail("stagehand::platform_lock invalid package identity for role ${role}")
      }
    }
    $names = $entry['packages'].map |Hash $package| { $package['name'] }
    if unique($names).length != $names.length {
      fail("stagehand::platform_lock role ${role} contains a duplicate package")
    }
    if $names.any |$name| { !($name in $allowed_packages[$role]) } or !$required_packages[$role].all |$name| { $name in $names } {
      fail("stagehand::platform_lock package ownership violation for role ${role}")
    }
  }

  # A fixed role order plus a sorted package map makes equal inputs produce the
  # same resource and manifest ordering even when the caller reverses roles.
  $ordered_roles = ['agent', 'postgresql', 'puppet_server', 'puppetdb'].filter |$name| { $name in $role_names }
  $package_records = $ordered_roles.map |$role_name| {
    $roles.filter |Hash $entry| { $entry['role'] == $role_name }[0]['packages']
  }.flatten
  $package_versions = $package_records.reduce({}) |Hash $memo, Hash $package| {
    $name = $package['name']
    if $memo[$name] and $memo[$name] != $package['evr'] {
      fail("stagehand::platform_lock conflicting EVRs for package ${name}")
    }
    $memo + { $name => $package['evr'] }
  }
  $package_sources = $package_records.reduce({}) |Hash $memo, Hash $package| {
    $package['source'] ? {
      undef   => $memo,
      default => $memo + { $package['name'] => {
        'source'        => $package['source'],
        'source_sha256' => $package['source_sha256'],
      } },
    }
  }

  case $facts['os']['family'] {
    'Debian': {
      class { 'stagehand::platform_lock::apt':
        packages => $package_versions,
      }
    }
    'RedHat': {
      class { 'stagehand::platform_lock::rpm':
        packages => $package_versions,
      }
    }
    'Suse': {
      class { 'stagehand::platform_lock::zypper':
        packages => $package_versions,
      }
    }
    'windows': {
      if $package_versions.keys.any |$name| {
        !$package_sources[$name] or
        $package_sources[$name]['source'] !~ Pattern[/\Ahttps:\/\/[^[:space:]]+\.msi\z/] or
        $package_sources[$name]['source_sha256'] !~ Pattern[/\A[0-9a-f]{64}\z/]
      } {
        fail('stagehand::platform_lock Windows packages require an immutable MSI source and SHA-256')
      }
      class { 'stagehand::platform_lock::windows':
        packages => $package_versions,
        sources  => $package_sources,
      }
    }
    default: {
      fail("stagehand::platform_lock unsupported OS family ${facts['os']['family']}")
    }
  }

  $server_entries = $roles.filter |Hash $entry| { $entry['role'] == 'puppet_server' }
  $puppetdb_entries = $roles.filter |Hash $entry| { $entry['role'] == 'puppetdb' }

  if !$server_entries.empty {
    $server_runtime = $server_entries[0]['runtime']
    if $server_runtime['java_major'] != 21 {
      fail('stagehand::platform_lock Puppet Server requires approved Java major 21')
    }
    $server_java_home = $server_runtime['java_home'] ? {
      undef   => $facts['os']['family'] ? {
        'Debian' => "/usr/lib/jvm/java-21-openjdk-${facts['os']['architecture']}",
        default  => '/usr/lib/jvm/java-21-openjdk',
      },
      default => $server_runtime['java_home'],
    }
    unless $server_java_home =~ Pattern[/\A\/usr\/lib\/jvm\/java-21-[a-zA-Z0-9_.-]+\z/] {
      fail('stagehand::platform_lock invalid JAVA_HOME for Puppet Server')
    }
  }

  if !$puppetdb_entries.empty {
    $puppetdb_runtime = $puppetdb_entries[0]['runtime']
    if $puppetdb_runtime['java_major'] != 17 {
      fail('stagehand::platform_lock PuppetDB requires approved Java major 17')
    }
    $puppetdb_java_home = $puppetdb_runtime['java_home'] ? {
      undef   => $facts['os']['family'] ? {
        'Debian' => "/usr/lib/jvm/java-17-openjdk-${facts['os']['architecture']}",
        default  => '/usr/lib/jvm/java-17-openjdk',
      },
      default => $puppetdb_runtime['java_home'],
    }
    unless $puppetdb_java_home =~ Pattern[/\A\/usr\/lib\/jvm\/java-17-[a-zA-Z0-9_.-]+\z/] {
      fail('stagehand::platform_lock invalid JAVA_HOME for PuppetDB')
    }
  }

  $java_majors = unique([
    !$server_entries.empty ? { true => 21, false => undef },
    !$puppetdb_entries.empty ? { true => 17, false => undef },
  ].filter |$major| { $major != undef }).sort
  $java_majors.each |Integer $major| {
    $java_package = $facts['os']['family'] ? {
      'Debian' => "openjdk-${major}-jre-headless",
      'RedHat' => "java-${major}-openjdk-headless",
      'Suse'   => "java-${major}-openjdk-headless",
      default  => undef,
    }
    if $java_package == undef {
      fail("stagehand::platform_lock unsupported Java runtime on ${facts['os']['family']}")
    }
    package { "stagehand-platform-lock-java-${major}":
      ensure => installed,
      name   => $java_package,
    }
  }

  if !$server_entries.empty {
    file { '/etc/systemd/system/puppetserver.service.d':
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    file { '/etc/systemd/system/puppetserver.service.d/20-stagehand-java.conf':
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0644',
      content   => "[Service]\nEnvironment=\"JAVA_HOME=${server_java_home}\"\n",
      require   => [File['/etc/systemd/system/puppetserver.service.d'], Package['stagehand-platform-lock-java-21']],
      notify    => Exec['stagehand-platform-lock-systemd-reload'],
      show_diff => false,
    }
  }
  if !$puppetdb_entries.empty {
    file { '/etc/systemd/system/puppetdb.service.d':
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    file { '/etc/systemd/system/puppetdb.service.d/20-stagehand-java.conf':
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0644',
      content   => "[Service]\nEnvironment=\"JAVA_HOME=${puppetdb_java_home}\"\n",
      require   => [File['/etc/systemd/system/puppetdb.service.d'], Package['stagehand-platform-lock-java-17']],
      notify    => Exec['stagehand-platform-lock-systemd-reload'],
      show_diff => false,
    }
  }
  if !$java_majors.empty {
    exec { 'stagehand-platform-lock-systemd-reload':
      command     => '/bin/systemctl daemon-reload',
      refreshonly => true,
      path        => ['/usr/bin', '/bin'],
    }
  }
  if !$server_entries.empty {
    exec { 'stagehand-platform-lock-restart-puppetserver':
      command     => '/bin/systemctl try-restart puppetserver',
      refreshonly => true,
      path        => ['/usr/bin', '/bin'],
      subscribe   => File['/etc/systemd/system/puppetserver.service.d/20-stagehand-java.conf'],
      require     => Exec['stagehand-platform-lock-systemd-reload'],
    }
  }
  if !$puppetdb_entries.empty {
    exec { 'stagehand-platform-lock-restart-puppetdb':
      command     => '/bin/systemctl try-restart puppetdb',
      refreshonly => true,
      path        => ['/usr/bin', '/bin'],
      subscribe   => File['/etc/systemd/system/puppetdb.service.d/20-stagehand-java.conf'],
      require     => Exec['stagehand-platform-lock-systemd-reload'],
    }
  }

  $postgresql_majors = unique($roles.map |Hash $entry| { $entry['runtime']['postgresql_major'] }.filter |$major| { $major != undef })
  if $postgresql_majors.length > 1 {
    fail('stagehand::platform_lock roles disagree on PostgreSQL major')
  }
  if !$postgresql_majors.empty {
    $postgresql_major = $postgresql_majors[0]
    unless $postgresql_major in [16, 17] {
      fail("stagehand::platform_lock unsupported PostgreSQL major ${postgresql_major}")
    }
    $postgresql_packages = $facts['os']['family'] ? {
      'Debian' => {
        'server'  => "postgresql-${postgresql_major}",
        'client'  => "postgresql-client-${postgresql_major}",
      },
      'RedHat' => {
        'server'  => "postgresql${postgresql_major}-server",
        'client'  => "postgresql${postgresql_major}",
        'contrib' => "postgresql${postgresql_major}-contrib",
      },
      'Suse' => {
        'server'  => "postgresql${postgresql_major}-server",
        'client'  => "postgresql${postgresql_major}",
        'contrib' => "postgresql${postgresql_major}-contrib",
      },
      default => undef,
    }
    if $postgresql_packages == undef {
      fail("stagehand::platform_lock unsupported PostgreSQL runtime on ${facts['os']['family']}")
    }
    $postgresql_packages.keys.sort.each |String $component| {
      package { "stagehand-platform-lock-postgresql-${component}":
        ensure => installed,
        name   => $postgresql_packages[$component],
      }
    }
    $pg_trgm_check_command = $facts['os']['family'] ? {
      'RedHat' => "/usr/sbin/runuser -u postgres -- /usr/pgsql-${postgresql_major}/bin/psql --no-psqlrc --tuples-only --dbname puppetdb --command \"SELECT extversion FROM pg_extension WHERE extname='pg_trgm'\"",
      default  => "/usr/sbin/runuser -u postgres -- /usr/bin/psql --no-psqlrc --tuples-only --dbname puppetdb --command \"SELECT extversion FROM pg_extension WHERE extname='pg_trgm'\"",
    }
    exec { 'stagehand-platform-lock-observe-pg-trgm-extension':
      command     => $pg_trgm_check_command,
      refreshonly => true,
      logoutput   => false,
      path        => ['/usr/bin', '/bin'],
      require     => Package['stagehand-platform-lock-postgresql-server'],
    }
  }

  if $write_manifest {
    $ordered_role_entries = $ordered_roles.map |String $role_name| {
      $entry = $roles.filter |Hash $candidate| { $candidate['role'] == $role_name }[0]
      $ordered_packages = $entry['packages'].map |Hash $package| { $package['name'] }.sort.map |String $name| {
        $entry['packages'].filter |Hash $package| { $package['name'] == $name }[0]
      }
      $canonical_runtime = $role_name ? {
        'puppet_server' => $entry['runtime'] + { 'java_home' => $server_java_home },
        'puppetdb'      => $entry['runtime'] + { 'java_home' => $puppetdb_java_home },
        default         => $entry['runtime'],
      }
      $canonical_role = {
        'role'     => $role_name,
        'packages' => $ordered_packages,
        'runtime'  => $canonical_runtime,
      }
      $canonical_role
    }
    $generation_projection = {
      'schema_version' => 1,
      'target_id'        => $target_id,
      'release_set_id'   => $release_set_id,
      'evidence_sha256'  => $evidence_sha256,
      'repository_track' => $puppet_track,
      'roles'            => $ordered_role_entries,
      'os'               => {
        'family'       => downcase($facts['os']['family']),
        'name'         => $facts['os']['name'],
        'version'      => $facts['os']['release']['full'],
        'architecture' => $facts['os']['architecture'],
      },
    }
    $generation_json = inline_template('<% require "json"; canonical = lambda { |value| value.is_a?(Hash) ? value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical.call(value[key]) } : (value.is_a?(Array) ? value.map { |item| canonical.call(item) } : value) }; %><%= JSON.generate(canonical.call(@generation_projection)) %>')
    $desired_snapshot = {
      'schema_version' => 1,
      'kind'           => 'desired',
      'desired'        => $generation_projection + {
        'desired_generation_sha256' => sha256($generation_json),
      },
    }

    $package_after = $package_versions.keys.map |String $name| { Package["stagehand-platform-lock-${name}"] }
    $lock_after = $facts['os']['family'] ? {
      'Debian' => $package_versions.keys.map |String $name| { Exec["stagehand-platform-lock-apt-${name}"] },
      'RedHat' => [File['/etc/dnf/plugins/versionlock.list']],
      'Suse'   => $package_versions.keys.map |String $name| { Exec["stagehand-platform-lock-zypper-${name}"] },
      default  => [],
    }
    $runtime_after = $java_majors.map |Integer $major| { Package["stagehand-platform-lock-java-${major}"] }
    $java_config_after = [
      # lint:ignore:unquoted_string_in_selector
      !$server_entries.empty ? { true => File['/etc/systemd/system/puppetserver.service.d/20-stagehand-java.conf'], false => undef },
      !$puppetdb_entries.empty ? { true => File['/etc/systemd/system/puppetdb.service.d/20-stagehand-java.conf'], false => undef },
      # lint:endignore
    ].filter |$resource| { $resource != undef }
    $reload_after = $java_majors.empty ? { true => [], false => [Exec['stagehand-platform-lock-systemd-reload']] }
    # lint:ignore:unquoted_string_in_selector
    $restart_after = [
      !$server_entries.empty ? { true => Exec['stagehand-platform-lock-restart-puppetserver'], false => undef },
      !$puppetdb_entries.empty ? { true => Exec['stagehand-platform-lock-restart-puppetdb'], false => undef },
    ].filter |$resource| { $resource != undef }
    # lint:endignore
    $postgres_after = $postgresql_majors.empty ? {
      true    => [],
      default => $postgresql_packages.keys.map |String $component| { Package["stagehand-platform-lock-postgresql-${component}"] } + [Exec['stagehand-platform-lock-observe-pg-trgm-extension']],
    }
    class { 'stagehand::platform_lock::observe':
      desired => $desired_snapshot,
      after   => $package_after + $lock_after + $runtime_after + $java_config_after + $reload_after + $restart_after + $postgres_after,
    }
  }
}
