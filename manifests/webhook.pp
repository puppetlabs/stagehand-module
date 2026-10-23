# @summary Install r10k and the Stagehand deploy agent on a Puppet Core primary.
#
# Classify a Puppet Core primary with this class to make it a deploy target for
# the Stagehand Advanced Code Manager pack. Starting from a primary that has no
# code-deploy tool at all (Phase 57.6 D-31), one agent run:
#
#   1. installs `git` (r10k's default `shellgit` provider needs it) and the
#      r10k gem into Puppet's own Ruby with the `puppet_gem` provider, so the
#      binary lands at `/opt/puppetlabs/puppet/bin/r10k` (the Puppet Core path);
#   2. writes `r10k.yaml` with the control repository, the code directory and
#      an explicit cache directory;
#   3. downloads the Stagehand deploy agent from a pinned HTTPS URL, refuses it
#      unless its SHA-256 matches the pinned digest, and installs it with the
#      native package tool (`dpkg` or `rpm`);
#   4. writes `/etc/stagehand-deploy-agent/config.yml` so the agent serves its
#      deploy API over mutual TLS: the server identity is this node's own Puppet
#      certificate and key (D-11), clients must present a certificate signed by
#      this estate's CA, not revoked in its CRL, and named on
#      `allowed_certnames`. On the CA host the CRL is the CA's own
#      `ca_crl.pem`, which a revocation updates at once;
#   5. writes a systemd drop-in that names the service user and passes this
#      node's Puppet private key (and the git deploy key, for an SSH remote) to
#      the service as systemd credentials;
#   6. keeps the `stagehand-deploy-agent` service running, restarting it
#      whenever its config, its drop-in or its package changes.
#
# **Moving off the old webhook-go service (D-02).** On a primary that already
# runs webhook-go as root, the same run does the cutover, in this order: stop
# and disable webhook-go while holding its own deploy lock (a deploy in flight
# makes the run fail with "a deploy is running on webhook-go; apply again when
# it finishes", having changed nothing); remove the webhook-go package, its
# config, its systemd drop-in and its package cache; install the agent; copy
# the finished deploy records across once (`import-history`); hand the
# environments directory, the r10k cache and the agent's state directory to
# `run_as` under the agent's own deploy lock; start the agent. The old state
# directory and a copy of the old config stay in place for a rollback. On a
# primary that never ran webhook-go every one of these steps does nothing.
#
# **The agent does not run as root (D-01, D-04).** It runs as `run_as` (default
# `stagehand-deploy-agent`, primary group `puppet`). The class hands that user
# the environments directory (`basedir`), the r10k cache (`cachedir`) and the
# agent's own state directory, and nothing else: it does not manage
# `/etc/puppetlabs/code` itself, the global `hiera.yaml` or `modules/`. There is
# no parameter that allows root or uid 0; a catalog naming `root` fails to
# compile, and an apply-time guard ordered before the user, the directories,
# the package and the service fails the run if `run_as` resolves to uid 0.
#
# **Keys arrive through systemd credentials (D-20).** The service never reads
# Puppet's `ssl/private_keys` directory, and this class changes no ownership or
# mode under Puppet's ssl directory. systemd copies the key into a private
# directory that only the service user can read. That feature (`LoadCredential=`)
# needs systemd 247 or later, so the class refuses to compile on a node whose
# `stagehand_systemd_version` fact is missing or lower (EL8 and Ubuntu 20.04).
#
# **Git over ssh is pinned in the agent's own file (D-03).** With `git_ssh_host`
# set, the class writes `ssh_config` and `known_hosts` into the agent's
# configuration directory and the agent runs git with `ssh -F` on that file, so
# no other ssh configuration on the primary (a user's or the system's) is read.
# This class never reads or writes any user's ssh setup.
#
# Step-by-step guide, prerequisites, signing the pack's certificate, and human
# test steps: `docs/stagehand-webhook.md`.
#
# @param control_remote
#   Git URL of the control repository r10k deploys from, for example
#   `git@github.com:example/control-repo.git` or
#   `https://github.com/example/control-repo.git`. Whitespace and quote
#   characters are refused.
# @param agent_package_source
#   HTTPS URL of the Stagehand deploy agent package for this node: the `.deb`
#   on Debian-family systems, the `.rpm` on RedHat-family systems. Take it from
#   the agent's signed GitHub release. Changing it to a newer release upgrades
#   the package.
# @param agent_package_sha256
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
#   Certificate revocation list the agent checks every client certificate
#   against. Default (undef): on the CA host (the `stagehand_puppetserver_ca`
#   fact), the CA's own `/etc/puppetlabs/puppetserver/ca/ca_crl.pem`, which
#   changes the moment `puppetserver ca revoke` runs; on any other node, the
#   agent's copy `/etc/puppetlabs/puppet/ssl/crl.pem`. The agent copy is only
#   refreshed on agent runs, so a revocation reaches it late. Set this on a CA
#   with a non-default `cadir`. The agent rereads the file within a minute of a
#   change.
# @param engine
#   Deploy engine the agent runs: `r10k` (default) or `g10k`. The module never
#   installs g10k; with `g10k` you must also set `g10k_command_path`.
# @param g10k_command_path
#   Absolute path of an already-installed g10k binary. Required when `engine`
#   is `g10k`, ignored otherwise.
# @param r10k_version
#   Exact r10k gem version. Default (undef): 5.0.3 on Puppet 8 or later, 4.1.0
#   on Puppet 7 (r10k 5 needs Ruby 3.1, which Puppet 7 agents do not ship).
# @param r10k_config
#   Path of the r10k config file. The agent user reads it through the `puppet`
#   group (it holds the control repository URL, no secret). The class manages
#   the file's directory (root:puppet, 0750), so the file must sit in a
#   directory of its own, such as `/etc/stagehand/r10k.yaml`; a shared
#   directory such as `/etc` or `/etc/puppetlabs` is refused. That directory
#   must not be `cachedir`.
# @param cachedir
#   r10k's git cache directory, owned by `run_as`. Set explicitly because
#   r10k's own default is the running user's home directory.
# @param basedir
#   The Puppet environments directory r10k deploys into, owned by `run_as`.
#   Only this directory is handed over, never `/etc/puppetlabs/code` itself.
# @param port
#   TCP port the agent listens on, 1 to 65535.
# @param ops_listen
#   `host:port` of the agent's plain-HTTP ops listener (`/healthz`, `/readyz`,
#   `/metrics`). It has no authentication, so the default is loopback only.
# @param deploy_timeout
#   Longest a single environment deploy may run before the agent kills it, as a
#   duration made of whole seconds, minutes and hours, such as `15m`, `1h` or
#   `2m30s`. At least one second: the agent refuses zero, a sub-second unit
#   (`500ms`) and a bare number.
# @param state_dir
#   The agent's state directory (`deploys.state_dir`): job records
#   (`jobs/<id>.json`), the cross-process deploy lock and one lock file per
#   running process (`instances/`). The class creates it with mode 0700, owned
#   by `run_as`.
# @param max_jobs
#   How many job records the agent keeps (`deploys.max_jobs`); the oldest
#   finished ones beyond this are deleted, and their ids then answer 404. At
#   least 1. Default 500.
# @param protected_environments
#   Environments the agent refuses to remove (`deploys.protected_environments`).
#   Lower-case letters, digits and underscores. Default `['production']`.
# @param run_as
#   The user the agent runs as. Default `stagehand-deploy-agent`, a system user
#   whose primary group is `puppet`, so Puppet Server reads what the agent
#   deploys. `root` is refused when the catalog compiles, and a name that
#   resolves to uid 0 is refused when it is applied (D-04); there is no way to
#   turn either check off.
# @param legacy_state_dir
#   Where an earlier webhook-go install kept its job records and its deploy
#   lock (`state_dir` in its `webhook.yml`). The cutover takes that lock before
#   it stops the old service, imports the finished records from
#   `<legacy_state_dir>/jobs` once, and leaves the directory in place as the
#   rollback source. Only matters on a primary that ran webhook-go.
# @param manage_git
#   Install the `git` package (with `stdlib::ensure_packages`, so another class
#   that also wants git does not conflict). Set false if git is managed
#   elsewhere.
# @param git_ssh_host
#   Host name of the git server for an SSH `control_remote` (for example
#   `github.com`). When set, the class writes the agent's `ssh_config` and
#   `known_hosts` (`StrictHostKeyChecking yes`, pinned host key) and passes the
#   deploy key as a systemd credential. The `ssh_config` applies to every host
#   (`Host *`), so a Puppetfile module fetched over ssh from another host fails
#   closed unless its key is in `known_hosts` too. Leave undef for an HTTPS
#   remote. r10k's default `shellgit` provider ignores r10k.yaml's
#   `git: private_key`, so this is how an SSH remote works on the first deploy.
# @param git_ssh_key
#   Absolute path of the deploy key's private half, already present on the
#   node (root-owned, mode 0600). systemd reads it at service start and gives
#   the agent a private copy; only the path enters the catalog, never the key.
#   Required with `git_ssh_host`. Whitespace and quotes are refused.
# @param git_ssh_known_host
#   The git host's public key as one known_hosts line, for example the output
#   of `ssh-keyscan -t ed25519 github.com` checked against the provider's
#   published fingerprints. Required with `git_ssh_host`. One line only.
#
# @example SSH control repository (Hiera)
#   stagehand::webhook::control_remote: 'git@github.com:example/control-repo.git'
#   stagehand::webhook::git_ssh_host: 'github.com'
#   stagehand::webhook::git_ssh_key: '/etc/stagehand-deploy-agent/deploy_key'
#   stagehand::webhook::git_ssh_known_host: 'github.com ssh-ed25519 <key from ssh-keyscan>'
#
# @example Minimal Hiera for an HTTPS control repository
#   stagehand::webhook::control_remote: 'https://github.com/example/control-repo.git'
#   stagehand::webhook::agent_package_source: 'https://github.com/puppet-stagehand/stagehand-deploy-agent/releases/download/v1.0.0/stagehand-deploy-agent_1.0.0_linux_amd64.deb'
#   stagehand::webhook::agent_package_sha256: 'f81c7827ab962dbdb048f92508433abecd2ecbed3611a15c19aa2700be249987'
#
# @example Classify the primary
#   include stagehand::webhook
class stagehand::webhook (
  Pattern[/\A[^\s'"]+\z/]          $control_remote,
  Stdlib::HTTPSUrl                 $agent_package_source,
  Pattern[/\A[0-9a-f]{64}\z/]      $agent_package_sha256,
  Array[Pattern[/\A[A-Za-z0-9._-]+\z/], 1] $allowed_certnames = ['stagehand-code-manager'],
  Array[Stagehand::Sha256_fingerprint] $allowed_fingerprints = [],
  Optional[Stdlib::Unixpath]       $crl_path             = undef,
  Enum['r10k', 'g10k']             $engine               = 'r10k',
  Optional[Stdlib::Unixpath]       $g10k_command_path    = undef,
  Optional[Pattern[/\A[0-9A-Za-z.]+\z/]] $r10k_version   = undef,
  Stdlib::Unixpath                 $r10k_config          = '/etc/puppetlabs/r10k/r10k.yaml',
  Stdlib::Unixpath                 $cachedir             = '/opt/puppetlabs/puppet/cache/r10k',
  Stdlib::Unixpath                 $basedir              = '/etc/puppetlabs/code/environments',
  Integer[1, 65535]                $port                 = 8088,
  Pattern[/\A(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}\z/] $ops_listen = '127.0.0.1:8089',
  Pattern[/\A(?=.*[1-9])([0-9]+(s|m|h))+\z/] $deploy_timeout = '15m',
  Stdlib::Unixpath                 $state_dir            = '/var/lib/stagehand-deploy-agent',
  Integer[1]                       $max_jobs             = 500,
  Array[Pattern[/\A[a-z0-9_]+\z/]] $protected_environments = ['production'],
  Pattern[/\A[a-z_][a-z0-9_-]{0,31}\z/] $run_as          = 'stagehand-deploy-agent',
  Stdlib::Unixpath                 $legacy_state_dir     = '/var/lib/webhook-go',
  Boolean                          $manage_git           = true,
  Optional[Stdlib::Host]           $git_ssh_host         = undef,
  Optional[Stdlib::Unixpath]       $git_ssh_key          = undef,
  Optional[String[1]]              $git_ssh_known_host   = undef,
) {
  # --- Refuse unsafe combinations before anything is applied (MD-05). -------
  # D-04: the agent never runs as root. The type already refuses a name that
  # starts with a digit ('0'); this names the common case in plain words.
  if $run_as == 'root' {
    fail('stagehand::webhook: run_as must not be root; the deploy agent refuses to run as root (D-04)')
  }

  # D-20: LoadCredential= needs systemd 247. An absent fact (no systemd, or the
  # module's fact not yet synced) is refused too: guessing would start a unit
  # that fails with an unknown directive.
  $systemd_version = $facts['stagehand_systemd_version']
  unless $systemd_version =~ Integer[247] {
    $systemd_found = $systemd_version ? {
      Integer => String($systemd_version),
      default => 'none',
    }
    fail("stagehand::webhook: the deploy agent needs systemd 247 or later for LoadCredential= (found ${systemd_found}); EL8 and Ubuntu 20.04 are not supported")
  }

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
  [$r10k_config, $cachedir, $basedir, $g10k_command_path, $crl_path, $state_dir].filter |$path| { $path =~ NotUndef }.each |String $path| {
    if $path =~ /[[:cntrl:]]/ {
      fail("stagehand::webhook: path parameter '${path}' contains a control character")
    }
  }

  # These three are also written into a systemd ReadWritePaths= line, where a
  # space would split one path into two.
  [$basedir, $cachedir, $state_dir].each |String $path| {
    if $path =~ /\s/ {
      fail("stagehand::webhook: path parameter '${path}' must not contain whitespace (it is written into a systemd unit)")
    }
  }

  # The class owns the directory of r10k_config (root:puppet, 0750). Refuse a
  # directory shared with the rest of the system, and one that is also the
  # agent-owned cache, instead of changing the ownership of either.
  $r10k_dir    = dirname($r10k_config)
  $shared_dirs = ['/', '/etc', '/opt', '/usr', '/var', '/etc/puppetlabs', '/opt/puppetlabs', '/usr/local', '/usr/local/etc', '/var/lib', '/var/cache']
  if $r10k_dir in $shared_dirs {
    fail("stagehand::webhook: r10k_config '${r10k_config}' must be in its own directory (the class manages that directory, and '${r10k_dir}' is shared with the system), for example /etc/stagehand/r10k.yaml")
  }
  if $r10k_dir == $cachedir {
    fail("stagehand::webhook: cachedir and the directory of r10k_config are both '${cachedir}'; the cache belongs to ${run_as} and the config directory to root, so set them apart")
  }

  $core_r10k    = '/opt/puppetlabs/puppet/bin/r10k'
  $ssldir       = '/etc/puppetlabs/puppet/ssl'
  $certname     = $trusted['certname']
  $config_dir   = '/etc/stagehand-deploy-agent'
  $credentials  = '/run/credentials/stagehand-deploy-agent.service'
  $default_state_dir = '/var/lib/stagehand-deploy-agent'

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
      fail("stagehand::webhook: unsupported OS family '${facts['os']['family']}'; the deploy agent ships .deb and .rpm only")
    }
  }

  # The URL's last path segment (query string stripped) names the cached file.
  $package_basename = $agent_package_source.split(/[?#]/)[0].split('/')[-1]
  $package_name_ok = $package_basename =~ /\A[A-Za-z0-9._+~-]+\z/
  unless $package_name_ok and $package_basename.split('\.')[-1] == $package_extension {
    fail(@("MSG"/L))
      stagehand::webhook: agent_package_source must end in a .${package_extension} file name \
      on ${facts['os']['family']} systems, got '${agent_package_source}'
      | MSG
  }

  # --- D-04 apply-time guard: run_as must not be uid 0. ---------------------
  # The type and the check above catch the name 'root'. A different name can
  # still be uid 0 (an alias in /etc/passwd), which only the node can tell. A
  # user that does not exist yet passes: `id` fails, so the check succeeds and
  # the user is created below. The name is passed as an argument, never spliced
  # into the script text.
  exec { 'stagehand-deploy-agent-run-as-not-uid0':
    command => ['/bin/sh', '-c', 'echo "stagehand::webhook: run_as $1 resolves to uid 0; refusing" >&2; exit 1', 'sh', $run_as],
    unless  => [['/bin/sh', '-c', 'u=$(/usr/bin/id -u "$1" 2>/dev/null) || exit 0; [ "$u" != 0 ]', 'sh', $run_as]],
    before  => [
      User[$run_as],
      File[$basedir],
      File[$cachedir],
      File[$state_dir],
      Package['stagehand-deploy-agent'],
      Service['stagehand-deploy-agent'],
    ],
  }

  # --- The cutover from webhook-go (D-02, D-01, RESEARCH Pitfall 3). ----------
  # Order is the whole point. Installing the agent package while webhook-go runs
  # would run the old package's removal script, which stops the service and kills
  # a deploy that is in flight. So: stop it first, under its own deploy lock
  # (exit 75 and a refusal when a deploy holds the lock, and then nothing below
  # runs); remove the old package and its leftovers; only then install the agent
  # (further down, ordered after this package). Every step is a no-op on a
  # primary that never ran webhook-go.
  $cutover_script = '/usr/local/sbin/stagehand-webhook-cutover'
  $import_marker  = "${config_dir}/.webhook-go-history-imported"

  file { $cutover_script:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
    source => 'puppet:///modules/stagehand/webhook-cutover.sh',
  }

  exec { 'stagehand-webhook-stop-legacy':
    command => [$cutover_script, 'stop-legacy', $legacy_state_dir],
    onlyif  => [[$cutover_script, 'has-legacy']],
    require => [File[$cutover_script], Exec['stagehand-deploy-agent-run-as-not-uid0']],
    before  => [User[$run_as], File[$basedir], File[$cachedir], File[$state_dir]],
  }

  package { 'webhook-go':
    ensure   => absent,
    provider => $package_provider,
    require  => Exec['stagehand-webhook-stop-legacy'],
    before   => Package['stagehand-deploy-agent'],
  }

  # What the old package and the old module left behind. The state directory
  # (`legacy_state_dir`, with webhook.yml.pre-agent in it) is deliberately not
  # here: it is the rollback source.
  file { '/etc/systemd/system/webhook-go.service.d':
    ensure  => absent,
    force   => true,
    backup  => false,
    require => Exec['stagehand-webhook-stop-legacy'],
    notify  => Exec['stagehand-deploy-agent-systemd-reload'],
  }

  file { '/etc/voxpupuli/webhook.yml':
    ensure  => absent,
    require => [Exec['stagehand-webhook-stop-legacy'], Package['webhook-go']],
  }

  file { '/var/cache/stagehand-webhook':
    ensure  => absent,
    force   => true,
    backup  => false,
    require => Exec['stagehand-webhook-stop-legacy'],
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

  # --- The agent's user, and the two directories it owns (D-01). ------------
  # The group `puppet` is Puppet Server's own; the class does not create it, so
  # on a node without Puppet Server the user resource fails with a clear error.
  user { $run_as:
    ensure     => present,
    system     => true,
    gid        => 'puppet',
    home       => $default_state_dir,
    managehome => false,
    shell      => '/usr/sbin/nologin',
    comment    => 'Stagehand deploy agent',
  }

  file { [$basedir, $cachedir]:
    ensure => directory,
    owner  => $run_as,
    group  => 'puppet',
    mode   => '0750',
  }

  # Job records (0600) and the deploy lock live here. systemd's StateDirectory=
  # would create the default location too; owning it here keeps its mode at
  # 0700 even if a package or an operator loosens it.
  file { $state_dir:
    ensure => directory,
    owner  => $run_as,
    group  => 'puppet',
    mode   => '0700',
  }

  file { $r10k_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'puppet',
    mode   => '0750',
  }

  file { $r10k_config:
    ensure  => file,
    owner   => 'root',
    group   => 'puppet',
    mode    => '0640',
    content => epp('stagehand/webhook/r10k.yaml.epp', {
      'control_remote' => $control_remote,
      'basedir'        => $basedir,
      'cachedir'       => $cachedir,
    }),
    require => [Package['r10k'], File[$r10k_dir, $cachedir]],
  }

  # --- The agent's package: pinned URL, mandatory digest (MD-02). ------------
  $package_dir  = '/var/cache/stagehand-deploy-agent'
  $package_file = "${package_dir}/${package_basename}"

  # Only the current package file is managed inside, and purge removes every
  # other file: a release bump would otherwise leave the previous package here
  # for ever (MOD-IN-03).
  file { $package_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    purge   => true,
    recurse => true,
    force   => true,
  }

  file { $package_file:
    ensure         => file,
    owner          => 'root',
    group          => 'root',
    mode           => '0640',
    source         => $agent_package_source,
    checksum       => 'sha256',
    checksum_value => $agent_package_sha256,
    require        => File[$package_dir],
  }

  # `latest` is relative to the pinned local file in `source`, not to a
  # repository: the dpkg/rpm providers compare the installed version with that
  # file's, so changing agent_package_source to a newer release upgrades.
  package { 'stagehand-deploy-agent':
    ensure   => latest, # lint:ignore:package_ensure
    provider => $package_provider,
    source   => $package_file,
    require  => [File[$r10k_config], File[$package_file], User[$run_as]],
  }

  # --- Git over SSH (D-03, MD-03): a dedicated file, not any user's. ---------
  # The agent runs git as `ssh -F <ssh_config>`, so ssh reads this file and no
  # other: nothing in a user's ssh directory or the system ssh_config can weaken
  # the pin. The files belong to the agent user (ssh refuses a config owned by
  # anyone else) and live in the agent's own configuration directory.
  if $git_ssh_host =~ NotUndef {
    $ssh_config      = "${config_dir}/ssh_config"
    $ssh_known_hosts = "${config_dir}/known_hosts"

    file { $ssh_config:
      ensure  => file,
      owner   => $run_as,
      group   => 'puppet',
      mode    => '0600',
      content => epp('stagehand/webhook/ssh_config.epp', {
        'identity_file'    => "${credentials}/deploy_key",
        'known_hosts_file' => $ssh_known_hosts,
      }),
      require => File[$config_dir],
    }

    file { $ssh_known_hosts:
      ensure  => file,
      owner   => $run_as,
      group   => 'puppet',
      mode    => '0644',
      content => "${git_ssh_known_host}\n",
      require => File[$config_dir],
    }

    $ssh_files = [File[$ssh_config], File[$ssh_known_hosts]]
  } else {
    $ssh_config = undef
    $ssh_files  = []
  }

  # --- The agent's config: mTLS on this node's own Puppet identity. ---------
  $command_path = $engine ? {
    'g10k'  => $g10k_command_path,
    default => $core_r10k,
  }

  file { $config_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'puppet',
    mode   => '0750',
  }

  file { "${config_dir}/config.yml":
    ensure  => file,
    owner   => 'root',
    group   => 'puppet',
    mode    => '0640',
    content => epp('stagehand/webhook/config.yml.epp', {
      'port'                   => $port,
      'certificate'            => "${ssldir}/certs/${certname}.pem",
      'key'                    => "${credentials}/server.key",
      'client_ca'              => "${ssldir}/certs/ca.pem",
      'crl'                    => $crl,
      'allowed_certnames'      => $allowed_certnames,
      'allowed_fingerprints'   => $allowed_fingerprints.map |$fingerprint| { $fingerprint.upcase }.unique,
      'ops_listen'             => $ops_listen,
      'engine'                 => $engine,
      'command_path'           => $command_path,
      'config_path'            => $r10k_config,
      'basedir'                => $basedir,
      'state_dir'              => $state_dir,
      'deploy_timeout'         => $deploy_timeout,
      'max_jobs'               => $max_jobs,
      'protected_environments' => $protected_environments,
      'ssh_config'             => $ssh_config,
    }),
    require => [File[$config_dir], Package['stagehand-deploy-agent']],
  }

  # --- History and ownership after the install, before the service starts. --
  # Copy the old service's finished deploy records once (the marker records it;
  # the legacy directory is only read). `import-history` is allowed as root; the
  # records it writes are root's until the next step.
  exec { 'stagehand-deploy-agent-import-history':
    command => [$cutover_script, 'import', $legacy_state_dir, "${config_dir}/config.yml", $import_marker],
    onlyif  => [['/usr/bin/test', '-d', "${legacy_state_dir}/jobs"]],
    creates => $import_marker,
    require => [Package['stagehand-deploy-agent'], File["${config_dir}/config.yml"]],
    before  => Exec['stagehand-deploy-agent-own'],
  }

  # D-01: hand the environments directory, the r10k cache and the state directory
  # to run_as, recursively, but only when something in them is not already
  # theirs, and only while no deploy holds the agent's lock (exit 75 otherwise).
  # After the cutover from root, or on a fresh primary with root-owned
  # environments, this runs once; afterwards the `unless` skips it.
  exec { 'stagehand-deploy-agent-own':
    command => [$cutover_script, 'own', "${state_dir}/deploy.lock", $run_as, 'puppet', $basedir, $cachedir, $state_dir],
    unless  => [[$cutover_script, 'owned', $run_as, $basedir, $cachedir, $state_dir]],
    require => [Package['stagehand-deploy-agent'], File[$basedir, $cachedir, $state_dir]],
    before  => Service['stagehand-deploy-agent'],
  }

  # --- systemd drop-in: the service user and the credentials (D-20). --------
  # The packaged unit already carries the hardening and the default paths. This
  # file adds what is specific to this node: the user, the Puppet private key
  # (its path contains the certname) and the writable directories. No restart
  # logic lives here; the service subscribes to the file.
  $dropin_dir = '/etc/systemd/system/stagehand-deploy-agent.service.d'
  $dropin     = "${dropin_dir}/50-stagehand.conf"

  if $state_dir == $default_state_dir {
    $writable = [$basedir, $cachedir]
  } else {
    $writable = [$basedir, $cachedir, $state_dir]
  }

  file { $dropin_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { $dropin:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('stagehand/webhook/systemd-dropin.conf.epp', {
      'run_as'           => $run_as,
      'server_key'       => "${ssldir}/private_keys/${certname}.pem",
      'read_write_paths' => $writable,
      'deploy_key'       => $git_ssh_key,
    }),
    require => File[$dropin_dir],
    notify  => Exec['stagehand-deploy-agent-systemd-reload'],
  }

  exec { 'stagehand-deploy-agent-systemd-reload':
    command     => '/bin/systemctl daemon-reload',
    refreshonly => true,
    path        => ['/usr/bin', '/bin'],
  }

  service { 'stagehand-deploy-agent':
    ensure    => running,
    enable    => true,
    subscribe => [File["${config_dir}/config.yml"], File[$dropin], Package['stagehand-deploy-agent']] + $ssh_files,
    require   => [
      File[$basedir, $cachedir, $state_dir],
      Exec['stagehand-deploy-agent-systemd-reload'],
    ] + $ssh_files,
  }
}
