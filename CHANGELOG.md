# Changelog

## [Unreleased]

- feat(stagehand::webhook): prepare a Puppet Core primary for the Advanced Code Manager pack with the Stagehand deploy agent (agent only; the class never installs or runs the old `webhook-go` service). Installs git and r10k (`puppet_gem`; 5.0.3 on Puppet 8, 4.1.0 on Puppet 7), writes `r10k.yaml`, installs the agent from a pinned HTTPS URL with a mandatory sha256 (`agent_package_source`, `agent_package_sha256`), and configures its mutual-TLS deploy API on the primary's own Puppet certificate with a certname allow-list, optional fingerprint pins and the CA's CRL (on the CA host `server.tls.crl` defaults to the CA's own `ca_crl.pem`; new `stagehand_puppetserver_ca` fact and `crl_path` override; `allowed_fingerprints` takes the colon-hex form `puppetserver ca list --all` prints, validated by `Stagehand::Sha256_fingerprint`). New parameters: `run_as`, `ops_listen`, `protected_environments`, `legacy_state_dir`, `state_dir` (default `/var/lib/stagehand-deploy-agent`), `max_jobs`. Guide with human test steps: `docs/stagehand-webhook.md`.
- feat(stagehand::webhook): the agent runs off root. A system user `stagehand-deploy-agent` (group `puppet`) owns only the environments directory, the r10k cache and its state directory; `run_as` root or uid 0 is refused at compile time and again at apply time, with no override. The primary's Puppet key (and the git deploy key for an SSH remote) reach the service as systemd credentials (`LoadCredential=`), and the class changes nothing under Puppet's ssl directory. New `stagehand_systemd_version` fact; the class refuses to compile on systemd older than 247 (EL8, Ubuntu 20.04). A loopback ops port serves `/healthz`, `/readyz` and `/metrics`.
- feat(stagehand::webhook): one-run cutover from the old `webhook-go` service running as root. A guarded stop (`files/webhook-cutover.sh`, installed as `/usr/local/sbin/stagehand-webhook-cutover`) holds the old service's own deploy lock; if a deploy is in flight the run fails with exit 75, `a deploy is running on webhook-go; apply again when it finishes (nothing was changed)`, and nothing that depends on it runs. Then the old package is removed (before the agent is installed, so its removal script cannot kill a deploy), its config, systemd drop-in and package cache are removed, the agent is installed, the finished deploy history is copied once with `import-history` (marker `/etc/stagehand-deploy-agent/.webhook-go-history-imported`), the environments directory, r10k cache and state directory are handed to `run_as` under the agent's own deploy lock, and the agent starts. `/var/lib/webhook-go` and a copy of the old config (`webhook.yml.pre-agent`) stay as the rollback source. Nothing under root's home is touched, including the ssh fragment and `Include` line an earlier `main` version left; the guide says how to remove them by hand. Shell test: `tests/webhook_cutover_test.sh`.
- fix(stagehand::webhook): MOD-WR-01 -- git over ssh is pinned in the agent's own `ssh_config` and `known_hosts` (`Host *`, `StrictHostKeyChecking yes`, `BatchMode yes`) passed with `ssh -F`, so no other ssh configuration can weaken it; `tests/ssh_pinning_test.sh` proves it with `ssh -G`, including against hostile root and system configs. MOD-WR-02 -- the directory of `r10k_config` is managed (root:puppet, 0750); a shared directory such as `/etc` is refused. MOD-WR-03 -- no `/root/.ssh` resource remains, and a `cachedir` equal to the `r10k_config` directory fails with a message naming both.
- fix(stagehand::webhook): MOD-IN-02 -- `port` is `Integer[1, 65535]` and `deploy_timeout` accepts only whole seconds, minutes and hours of at least one second. MOD-IN-03 -- the package download directory is purged to the current package file. MOD-IN-04 -- structural `YAML.safe_load` assertions on the rendered agent config and `r10k.yaml`, and specs for an unsupported OS family and for `g10k` with an SSH remote. An `http://` package source is refused, with a spec.
- Deferred: MOD-IN-01 -- the class does not restart the service when the primary's certificate or key is renewed. Reason: `LoadCredential=` copies the key when the service starts and the agent loads the certificate at start, and the certificate file is outside this class's control, so there is no event to subscribe to. Mitigation: restart the service after a renewal (`systemctl restart stagehand-deploy-agent`); `/readyz` and the `stagehand_deploy_agent_server_certificate_days_until_expiry` gauge re-read the file on disk, while `/api/v1/info` reports `cert_not_after` of the certificate being served, so a difference between the two shows that a restart is due. The guide says this plainly.

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
