# @summary Install r10k and the Stagehand webhook-go fork on a Puppet Core primary.
#
# Classify a Puppet Core primary with this class to make it a deploy target for
# the Stagehand Advanced Code Manager pack. Starting from a primary that has no
# code-deploy tool at all (Phase 57.6 D-31), one agent run:
#
#   1. installs `git` (r10k's default `shellgit` provider needs it) and the
#      r10k gem into Puppet's own Ruby with the `puppet_gem` provider, so the
#      binary lands at `/opt/puppetlabs/puppet/bin/r10k` (the Puppet Core path;
#      upstream webhook-go defaults to the r10k that Puppet Enterprise bundles
#      with puppetserver, which does not exist on Core);
#   2. writes `r10k.yaml` with the control repository, the code directory and
#      an explicit cache directory;
#   3. downloads the Stagehand fork of webhook-go from a pinned HTTPS URL,
#      refuses it unless its SHA-256 matches the pinned digest, and installs it
#      with the native package tool (`dpkg` or `rpm`);
#   4. writes `/etc/voxpupuli/webhook.yml` so the fork serves its deploy API
#      over mutual TLS: the server identity is this node's own Puppet
#      certificate and key (D-11), clients must present a certificate signed by
#      this estate's CA, not revoked in its CRL, and named on
#      `allowed_certnames`;
#   5. keeps the `webhook-go` service running, restarting it whenever its
#      config or its package changes.
#
# **Runs as root (MD-04).** The fork's systemd unit has no `User=`, like
# upstream's. That is deliberate: r10k must write the Puppet code directory and
# the service must read this node's Puppet private key. Exposure is limited to
# mTLS clients on the allow-list; the accepted risk is AR-57.6-08.
#
# Step-by-step guide, prerequisites, signing the pack's certificate, and human
# test steps: `docs/stagehand-webhook.md`.
#
# @param control_remote
#   Git URL of the control repository r10k deploys from, for example
#   `git@github.com:example/control-repo.git` or
#   `https://github.com/example/control-repo.git`. Whitespace and quote
#   characters are refused.
# @param webhook_package_source
#   HTTPS URL of the Stagehand webhook-go fork package for this node: the `.deb`
#   on Debian-family systems, the `.rpm` on RedHat-family systems. Take it from
#   the fork's signed GitHub release. Changing it to a newer release upgrades
#   the package.
# @param webhook_package_sha256
#   SHA-256 digest (64 lowercase hex characters) of that exact package file,
#   from the release's checksums. Puppet refuses to install a download that
#   does not match.
# @param allowed_certnames
#   Certnames (certificate common names) allowed to call the deploy API. At
#   least one. Default: the pack's `stagehand-code-manager`.
# @param allowed_fingerprints
#   Optional pin: SHA-256 fingerprints of the exact client certificates
#   allowed, as 32 colon-separated hex pairs: the `(SHA256)` value
#   `puppetserver ca list --all` prints (copy the hex only, not the label).
#   Lower case is accepted; entries are rendered in upper case, once each.
#   Anything else (a SHA-1 fingerprint, hex without colons) fails the catalog.
#   Empty means any certificate with an allowed certname passes.
# @param crl_path
#   Certificate revocation list the fork checks every client certificate
#   against. Default (undef): on the CA host (the `stagehand_puppetserver_ca`
#   fact), the CA's own `/etc/puppetlabs/puppetserver/ca/ca_crl.pem`, which
#   changes the moment `puppetserver ca revoke` runs; on any other node, the
#   agent's copy `/etc/puppetlabs/puppet/ssl/crl.pem`. The agent copy is only
#   refreshed on agent runs, so a revocation reaches it late. Set this on a CA
#   with a non-default `cadir`. The fork rereads the file within a minute of a
#   change.
# @param engine
#   Deploy engine the fork runs: `r10k` (default) or `g10k`. The module never
#   installs g10k; with `g10k` you must also set `g10k_command_path`.
# @param g10k_command_path
#   Absolute path of an already-installed g10k binary. Required when `engine`
#   is `g10k`, ignored otherwise.
# @param r10k_version
#   Exact r10k gem version. Default (undef): 5.0.3 on Puppet 8 or later, 4.1.0
#   on Puppet 7 (r10k 5 needs Ruby 3.1, which Puppet 7 agents do not ship).
# @param r10k_config
#   Path of the r10k config file.
# @param cachedir
#   r10k's git cache directory. Set explicitly because r10k's own default is
#   the running user's home directory.
# @param basedir
#   The Puppet code directory r10k deploys environments into.
# @param port
#   TCP port the fork listens on.
# @param deploy_timeout
#   Longest a single environment deploy may run before the fork kills it, as a
#   Go duration such as `15m` or `1h`.
# @param manage_git
#   Install the `git` package (with `stdlib::ensure_packages`, so another class
#   that also wants git does not conflict). Set false if git is managed
#   elsewhere.
# @param git_ssh_host
#   Host name of the git server for an SSH `control_remote` (for example
#   `github.com`). When set, the class writes a `Host` block for it into
#   `/root/.ssh/config.d/stagehand-webhook.conf`, includes that directory from
#   root's `~/.ssh/config`, and pins the host key in
#   `/root/.ssh/known_hosts_stagehand` with `StrictHostKeyChecking yes` (MD-03).
#   Leave undef for an HTTPS remote. r10k's default `shellgit` provider ignores
#   r10k.yaml's `git: private_key`, so this is how an SSH remote works on the
#   first deploy.
# @param git_ssh_key
#   Absolute path of the deploy key's private half, already present on the
#   node (root-owned, mode 0600). Only the path enters the catalog, never the
#   key. Required with `git_ssh_host`. Whitespace and quotes are refused.
# @param git_ssh_known_host
#   The git host's public key as one known_hosts line, for example the output
#   of `ssh-keyscan -t ed25519 github.com` checked against the provider's
#   published fingerprints. Required with `git_ssh_host`. One line only.
#
# @example SSH control repository (Hiera)
#   stagehand::webhook::control_remote: 'git@github.com:example/control-repo.git'
#   stagehand::webhook::git_ssh_host: 'github.com'
#   stagehand::webhook::git_ssh_key: '/root/.ssh/stagehand_deploy'
#   stagehand::webhook::git_ssh_known_host: 'github.com ssh-ed25519 <key from ssh-keyscan>'
#
# @example Minimal Hiera for an HTTPS control repository
#   stagehand::webhook::control_remote: 'https://github.com/example/control-repo.git'
#   stagehand::webhook::webhook_package_source: 'https://github.com/puppet-stagehand/webhook-go/releases/download/v2.15.1-stagehand.1/webhook-go_2.15.1-stagehand.1_amd64.deb'
#   stagehand::webhook::webhook_package_sha256: '<64 hex characters from checksums.txt>'
#
# @example Classify the primary
#   include stagehand::webhook
class stagehand::webhook (
  Pattern[/\A[^\s'"]+\z/]          $control_remote,
  Stdlib::HTTPSUrl                 $webhook_package_source,
  Pattern[/\A[0-9a-f]{64}\z/]      $webhook_package_sha256,
  Array[Pattern[/\A[A-Za-z0-9._-]+\z/], 1] $allowed_certnames = ['stagehand-code-manager'],
  Array[Stagehand::Sha256_fingerprint] $allowed_fingerprints = [],
  Optional[Stdlib::Unixpath]       $crl_path             = undef,
  Enum['r10k', 'g10k']             $engine               = 'r10k',
  Optional[Stdlib::Unixpath]       $g10k_command_path    = undef,
  Optional[Pattern[/\A[0-9A-Za-z.]+\z/]] $r10k_version   = undef,
  Stdlib::Unixpath                 $r10k_config          = '/etc/puppetlabs/r10k/r10k.yaml',
  Stdlib::Unixpath                 $cachedir             = '/opt/puppetlabs/puppet/cache/r10k',
  Stdlib::Unixpath                 $basedir              = '/etc/puppetlabs/code/environments',
  Stdlib::Port                     $port                 = 8088,
  Pattern[/\A([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+\z/] $deploy_timeout = '15m',
  Boolean                          $manage_git           = true,
  Optional[Stdlib::Host]           $git_ssh_host         = undef,
  Optional[Stdlib::Unixpath]       $git_ssh_key          = undef,
  Optional[String[1]]              $git_ssh_known_host   = undef,
) {
  # --- Refuse unsafe combinations before anything is applied (MD-05). -------
  if $engine == 'g10k' and $g10k_command_path =~ Undef {
    fail("stagehand::webhook: engine 'g10k' needs g10k_command_path (the module does not install g10k)")
  }

  if $git_ssh_host =~ NotUndef {
    if $git_ssh_key =~ Undef {
      fail('stagehand::webhook: git_ssh_host is set, so git_ssh_key (path of the deploy key on this node) is required')
    }
    if $git_ssh_known_host =~ Undef {
      fail('stagehand::webhook: git_ssh_host is set, so git_ssh_known_host (the host key line) is required')
    }
    if $git_ssh_key =~ /[\s"']/ {
      fail("stagehand::webhook: git_ssh_key must not contain whitespace or quotes, got '${git_ssh_key}'")
    }
    if $git_ssh_known_host =~ /[[:cntrl:]]/ {
      fail('stagehand::webhook: git_ssh_known_host must be exactly one known_hosts line (no newlines)')
    }
  }

  # Every path below is rendered into YAML. Refuse control characters so a
  # value can never break out of its quoted scalar.
  [$r10k_config, $cachedir, $basedir, $g10k_command_path, $crl_path].filter |$path| { $path =~ NotUndef }.each |String $path| {
    if $path =~ /[[:cntrl:]]/ {
      fail("stagehand::webhook: path parameter '${path}' contains a control character")
    }
  }

  $core_r10k = '/opt/puppetlabs/puppet/bin/r10k'
  $ssldir    = '/etc/puppetlabs/puppet/ssl'
  $certname  = $trusted['certname']

  # Revocation list: the CA's own file on the CA host, because the agent's copy
  # only refreshes on agent runs and a revoked pack certificate would keep
  # deploying until then.
  if $crl_path =~ NotUndef {
    $crl = $crl_path
  } elsif $facts['stagehand_puppetserver_ca'] == true {
    $crl = '/etc/puppetlabs/puppetserver/ca/ca_crl.pem'
  } else {
    $crl = "${ssldir}/crl.pem"
  }

  # --- Package format follows the OS family. --------------------------------
  case $facts['os']['family'] {
    'Debian': {
      $package_provider  = 'dpkg'
      $package_extension = 'deb'
    }
    'RedHat': {
      $package_provider  = 'rpm'
      $package_extension = 'rpm'
    }
    default: {
      fail("stagehand::webhook: unsupported OS family '${facts['os']['family']}'; the webhook-go fork ships .deb and .rpm only")
    }
  }

  # The URL's last path segment (query string stripped) names the cached file.
  $package_basename = $webhook_package_source.split(/[?#]/)[0].split('/')[-1]
  $package_name_ok = $package_basename =~ /\A[A-Za-z0-9._+~-]+\z/
  unless $package_name_ok and $package_basename.split('\.')[-1] == $package_extension {
    fail(@("MSG"/L))
      stagehand::webhook: webhook_package_source must end in a .${package_extension} file name \
      on ${facts['os']['family']} systems, got '${webhook_package_source}'
      | MSG
  }

  # --- r10k ------------------------------------------------------------------
  if $r10k_version =~ NotUndef {
    $_r10k_version = $r10k_version
  } elsif versioncmp($facts['puppetversion'], '8.0.0') >= 0 {
    $_r10k_version = '5.0.3'
  } else {
    $_r10k_version = '4.1.0'
  }

  if $manage_git {
    stdlib::ensure_packages(['git'])
    $git_dependency = [Package['git']]
  } else {
    $git_dependency = []
  }

  package { 'r10k':
    ensure   => $_r10k_version,
    provider => 'puppet_gem',
    require  => $git_dependency,
  }

  file { ['/etc/puppetlabs/r10k', $cachedir]:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }

  file { $r10k_config:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
    content => epp('stagehand/webhook/r10k.yaml.epp', {
      'control_remote' => $control_remote,
      'basedir'        => $basedir,
      'cachedir'       => $cachedir,
    }),
    require => [Package['r10k'], File['/etc/puppetlabs/r10k', $cachedir]],
  }

  # --- The fork's package: pinned URL, mandatory digest (MD-02). -------------
  $package_dir  = '/var/cache/stagehand-webhook'
  $package_file = "${package_dir}/${package_basename}"

  file { $package_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }

  file { $package_file:
    ensure         => file,
    owner          => 'root',
    group          => 'root',
    mode           => '0640',
    source         => $webhook_package_source,
    checksum       => 'sha256',
    checksum_value => $webhook_package_sha256,
    require        => File[$package_dir],
  }

  # `latest` is relative to the pinned local file in `source`, not to a
  # repository: the dpkg/rpm providers compare the installed version with that
  # file's, so changing webhook_package_source to a newer release upgrades.
  package { 'webhook-go':
    ensure   => latest, # lint:ignore:package_ensure
    provider => $package_provider,
    source   => $package_file,
    require  => [File[$r10k_config], File[$package_file]],
  }

  # --- The fork's config: mTLS on this node's own Puppet identity. ----------
  $command_path = $engine ? {
    'g10k'  => $g10k_command_path,
    default => $core_r10k,
  }

  file { '/etc/voxpupuli/webhook.yml':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
    content => epp('stagehand/webhook/webhook.yml.epp', {
      'port'                 => $port,
      'certificate'          => "${ssldir}/certs/${certname}.pem",
      'key'                  => "${ssldir}/private_keys/${certname}.pem",
      'client_ca'            => "${ssldir}/certs/ca.pem",
      'crl'                  => $crl,
      'allowed_certnames'    => $allowed_certnames,
      'allowed_fingerprints' => $allowed_fingerprints.map |$fingerprint| { $fingerprint.upcase }.unique,
      'command_path'         => $command_path,
      'config_path'          => $r10k_config,
      'use_g10k_commands'    => $engine == 'g10k',
      'basedir'              => $basedir,
      'deploy_timeout'       => $deploy_timeout,
    }),
    require => Package['webhook-go'],
  }

  # --- Git over SSH (MD-03): root's ssh setup for the control repo's host. ---
  if $git_ssh_host =~ NotUndef {
    $ssh_fragment    = '/root/.ssh/config.d/stagehand-webhook.conf'
    $ssh_known_hosts = '/root/.ssh/known_hosts_stagehand'

    file { ['/root/.ssh', '/root/.ssh/config.d']:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0700',
    }

    file { $ssh_fragment:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => epp('stagehand/webhook/ssh_config.epp', {
        'host'             => $git_ssh_host,
        'identity_file'    => $git_ssh_key,
        'known_hosts_file' => $ssh_known_hosts,
      }),
    }

    file { $ssh_known_hosts:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "${git_ssh_known_host}\n",
    }

    # Root's own ssh config: make sure it exists, but leave its content alone.
    file { '/root/.ssh/config':
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0600',
    }

    # An Include line inside a Host block only applies to that host, and
    # file_line can only append. So anchor the Include under `Match all`
    # (which matches every host) wherever that line already is, appending
    # both when it is absent.
    file_line { 'stagehand-webhook ssh match all':
      path => '/root/.ssh/config',
      line => 'Match all',
    }

    file_line { 'stagehand-webhook ssh include':
      path    => '/root/.ssh/config',
      line    => 'Include config.d/*.conf',
      after   => '^Match all$',
      require => File_line['stagehand-webhook ssh match all'],
    }

    $ssh_dependency = [
      File[$ssh_fragment],
      File[$ssh_known_hosts],
      File_line['stagehand-webhook ssh include'],
    ]
  } else {
    $ssh_dependency = []
  }

  service { 'webhook-go':
    ensure    => running,
    enable    => true,
    subscribe => [File['/etc/voxpupuli/webhook.yml'], Package['webhook-go']],
    require   => $ssh_dependency,
  }
}
