# Changelog

## [Unreleased]

- feat(stagehand::webhook): prepare a Puppet Core primary for the Advanced Code Manager pack -- installs git and r10k (`puppet_gem`; 5.0.3 on Puppet 8, 4.1.0 on Puppet 7), writes `r10k.yaml`, installs the Stagehand webhook-go fork from a pinned HTTPS URL with a mandatory sha256, and configures its mutual-TLS deploy API on the primary's own Puppet certificate with a certname allow-list, optional fingerprint pins and the CA's CRL; SSH control repositories get a root ssh Host block with a pinned host key and `StrictHostKeyChecking yes`. Guide with human test steps: `docs/stagehand-webhook.md`.
- feat(stagehand::webhook): fork hardening hand-off -- on the CA host `server.tls.crl` defaults to the CA's own `/etc/puppetlabs/puppetserver/ca/ca_crl.pem` (new `stagehand_puppetserver_ca` fact; new `crl_path` override), because the agent's `crl.pem` only refreshes on agent runs; `allowed_fingerprints` takes the colon-hex SHA-256 form `puppetserver ca list --all` prints, in either case, validated by the new `Stagehand::Sha256_fingerprint` type and rendered upper case; new `state_dir` (created 0700, root) and `max_jobs` (default 500) parameters; a systemd drop-in for `webhook-go` sets `KillMode=mixed`, `TimeoutStopSec=60` and an empty `ExecReload=` so a reload never sends SIGHUP.

## [1.0.0] - 2026-08-25

- feat(tasks): add read-only r10k detection, deploy-key import, multi-host SSH staging, and explicit SSH-server remediation for the Stagehand control-repository setup flow
- feat(stagehand::console_integration): manage the SSH server by default so the dedicated Stagehand SSH identity can reach the primary without sharing the Puppet Core root identity
- feat(platform-lock): add the authoritative role-aware Puppet package contract, exact native package locks, Java/PostgreSQL family guards, desired/observed manifests, interruption recovery, and live-evidence schema
- feat(stagehand::console::docker): add the container integration consumed by installer-managed Stagehand deployments

## [0.2.3] - 2026-08-21

- fix(tasks): class_enumerate.rb required `english` (lowercase) instead of Ruby stdlib's actual `English` (capital E) file -- silently masked on case-insensitive filesystems (macOS, Windows) but a hard LoadError on every real Linux target, which is this task's actual deployment platform. Caught by running the CI just added against a real Linux runner for the first time; local macOS testing had given false confidence.

## [0.2.2] - 2026-08-21

- fix(console): reorder class parameters so required params precede optional ones (parameter_order lint fix, no behavior change -- Puppet class declarations are always named-parameter, never positional)
- fix(metadata): shorten summary to fit Forge's 144-char limit (metadata-json-lint now actually runs -- see CI notes)
- chore(ci): first-ever puppet-lint run against this module; add .puppet-lint.rc (--relative, fixes a false autoloader_layout error from the puppetlabs_spec_helper rake-task invocation path) and auto-fix all pre-existing arrow_alignment warnings

## [0.2.1] - 2026-08-21

- feat(tasks): add class_enumerate — read-only applied-classes report for the console's ENC discovery/import wizard, ported from puppet-console's pre-split adapters/pcm/ copy (added there post-split, never previously landed here)

## [0.2.0] - 2026-08-20

- refactor: rename pcm module to stagehand (puppetlabs-stagehand) (08ada86)
- feat(stagehand::console): optional hierascope staging + unconditional openssl (c4b3e29)
- test(stagehand::console): catalog-compile proof for hierascope staging + openssl (11782ca)
- refactor(02-02): add STAGEHAND_RECERT_PUPPET_BIN test-only override to recert.sh (bde2cc6)
- feat(02-02): recert.sh escapes YAML interpolation and embeds JSON on business-logic failure (cf424b5)
- test(02-02): add recert.sh test harness (RED confirmed pre-fix, now GREEN) (48ea8a5)
- test(02-03): add failing test for r10k_deploy.sh JSON-on-fail contract (a4ddb97)
- feat(02-03): r10k_deploy.sh embeds JSON on r10k failure instead of die (bddb950)
- test(02-03): add run_playbook_test.sh case (g) for the PT__installdir fallback branch (5858e7f)
- feat(02-03): run_playbook.sh resolves install_ansible.sh sibling-first (D-08), run_playbook.json marks ingest_token sensitive (58e5921)
- fix(quick): resolve discover.sh's RUBY interpreter instead of bare ruby (bef6f2b)
- fix(stagehand): correct metadata.json org to puppetlabs, fix README vendoring reference (SPLIT-01, D-01/D-07/D-12) (676845d)
- fix(stagehand): correct metadata.json/README to unified stagehand Forge author + puppet-stagehand org (SPLIT-01, D-16/D-17/D-18, supersedes D-01) (932d6a3)
