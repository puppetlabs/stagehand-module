# Changelog

## [1.1.2] - 2026-11-17

- feat(facts): patchbot fact schema version 2 with a three-state reboot_status (required, not_required, unknown) and fixed reboot_status_reason codes; the boolean reboot_required is kept and is true only when the status is required; a node that cannot tell reports unknown, never "no". The contract is the patch fact schema document (patch-fact-schema) in the console repository.
- fix(facts): the Windows fact and its refresh script keep counting past the 500-entry detail cap, so available, security and package_count stay exact on a node far behind and truncated is true when missing is shorter than the total (the refresh records missing_total and security_total in its cache); a cache written by an older refresh reports its listed count until the next refresh
- test: the fact harness (tests/patchbot_fact_test.sh, needs GNU awk, exits 77 when it is missing) and the Windows pwsh test (tests/patchbot_reboot_test.ps1) live in tests/, never in facts.d (Facter runs every executable in facts.d); CI counts exit 77 from tests/*.sh as a skip

## [1.1.1] - 2026-11-17

- fix(tasks): patch accepts the reboot policies never, if-needed and always (legacy true and false still accepted), declares patch_ids, no longer needs jq on the target, decides reboot needed with the shared reboot rule, and reports reboot_policy, reboot_status, reboot_status_reason and rebooting
- fix(tasks): patch refuses a patch_ids entry that ends in '-' (apt reads a trailing '-' as remove, so openssh-server- would remove the package), upgrades selected packages only when they are already installed (apt-get install --only-upgrade; matches dnf upgrade and yum update) and ends option parsing with -- before the ids

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
