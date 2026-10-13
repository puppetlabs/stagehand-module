# Preparing a Puppet Core primary for the Advanced Code Manager pack (`stagehand::webhook`)

This guide is for someone who is new to Puppet and new to automation tools in
general. It walks you from a Puppet Core primary server that has never deployed
code with r10k to one that the Stagehand **Advanced Code Manager** expansion
pack can deploy to, and then gives a tester a list of checks to prove it works.

## What this does, in plain words

Your Puppet code lives in a git repository called the **control repository**.
The Puppet server can only use that code once it has been copied onto the
server, into its code directory. **r10k** is the tool that does the copying: it
reads the control repository and writes one folder per branch (each folder is a
Puppet "environment").

**webhook-go** is a small program that sits on the primary like a door. When the
Code Manager pack wants new code deployed, it knocks on that door and says
"please deploy `production`". webhook-go then runs r10k for it and reports back
whether it worked and which commit is now live.

The door has a strict guard. A visitor is only let in if they carry a Puppet
certificate that **your** Puppet certificate authority (CA) signed, that has not
been revoked, and whose name is on the guest list. The pack's certificate is
called `stagehand-code-manager`. Nobody else gets in, not even with a password.

`stagehand::webhook` is one Puppet class that sets all of this up for you:
it installs git and r10k, writes r10k's settings, installs Stagehand's version
of webhook-go (a "fork": a copy of the upstream project with the guard and the
deploy reporting added), writes its settings, and keeps it running.

## Words used here

| Word | Meaning |
|------|---------|
| Primary | The main Puppet server. It runs the certificate authority. |
| Control repository | The git repository holding your Puppet code and its module list (`Puppetfile`). |
| r10k | The tool that copies the control repository onto the primary, one folder per branch. |
| webhook-go | The small service the pack talks to; it runs r10k on request. |
| Fork | Stagehand's maintained copy of webhook-go with mutual TLS and deploy results added. |
| Mutual TLS (mTLS) | An encrypted connection where *both* sides show a certificate, not only the server. |
| Certname | The name inside a Puppet certificate, for example `stagehand-code-manager`. |
| CRL | Certificate revocation list: the CA's list of certificates it has cancelled. |
| sha256 digest | A 64-character fingerprint of a file. If even one byte changes, the digest changes. |

## Before you start

You need:

1. A Puppet Core primary (Puppet 7 or 8, or OpenVox 8) on Ubuntu/Debian or
   RHEL-family Linux, with a working agent (`puppet agent -t` runs cleanly).
2. This module (`stagehand-stagehand`) available to the primary's environment.
3. Your control repository's URL, and read access to it from the primary:
   - an **HTTPS** URL that needs no password, or
   - an **SSH** URL plus a read-only deploy key whose private half you have
     copied to the primary (for example `/root/.ssh/stagehand_deploy`, owned by
     root, mode `0600`).
4. The release URL and sha256 digest of the Stagehand webhook-go fork package
   for your operating system (see the next section).

## Step 1: pick the fork's package and its digest

1. Open the fork's releases page:
   `https://github.com/puppet-stagehand/webhook-go/releases`. Release tags look
   like `v2.15.1-stagehand.1`.
2. Choose the package that matches the primary: the `.deb` file for
   Ubuntu/Debian, the `.rpm` file for RHEL, Rocky or Alma, and the right CPU
   type (`amd64`/`x86_64` or `arm64`/`aarch64`). Copy its download link. That
   link is `webhook_package_source`.
3. Open the release's `checksums.txt`. Find the line for your file. The 64
   characters before the file name are `webhook_package_sha256`.

**Why the digest matters.** Puppet downloads the package and refuses to install
it unless its digest matches the one you wrote down. If anybody swaps the file
on the download server, or the download is damaged, nothing gets installed.

**Check the signature once, before you pin.** The digest only proves the file is
the one you pinned, so make sure what you pin is genuine. Stagehand signs each
release's `checksums.txt` with cosign. On any machine with
[cosign](https://docs.sigstore.dev/) installed, download `checksums.txt` and its
signature files from the same release, then run the verification command shown
in the release notes. It looks like this:

```sh
cosign verify-blob \
  --certificate checksums.txt.pem \
  --signature checksums.txt.sig \
  --certificate-identity-regexp '^https://github.com/puppet-stagehand/webhook-go/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
```

It must print `Verified OK`. If it does not, stop and do not use that release.

## Step 2: write the settings (Hiera)

Put the settings in Hiera data for the primary, for example in
`data/nodes/<primary certname>.yaml` in your control repository. Every
parameter is shown here; the ones marked "default" can be left out.

```yaml
# Required
stagehand::webhook::control_remote: 'git@github.com:example/control-repo.git'
stagehand::webhook::webhook_package_source: 'https://github.com/puppet-stagehand/webhook-go/releases/download/<tag>/<package file>'
stagehand::webhook::webhook_package_sha256: '<64 hex characters from checksums.txt>'

# Only for an SSH control_remote (leave all three out for HTTPS)
stagehand::webhook::git_ssh_host: 'github.com'
stagehand::webhook::git_ssh_key: '/root/.ssh/stagehand_deploy'
stagehand::webhook::git_ssh_known_host: 'github.com ssh-ed25519 <host key>'

# Who may call the deploy API (default shown)
stagehand::webhook::allowed_certnames:
  - 'stagehand-code-manager'
# Optional extra pin on the exact certificate (default: empty list)
stagehand::webhook::allowed_fingerprints: []

# Defaults; change only if you know you need to
stagehand::webhook::engine: 'r10k'                # or 'g10k' with g10k_command_path
# stagehand::webhook::g10k_command_path: '/usr/local/bin/g10k'
# stagehand::webhook::r10k_version: '5.0.3'       # default: 5.0.3 on Puppet 8, 4.1.0 on Puppet 7
stagehand::webhook::r10k_config: '/etc/puppetlabs/r10k/r10k.yaml'
stagehand::webhook::cachedir: '/opt/puppetlabs/puppet/cache/r10k'
stagehand::webhook::basedir: '/etc/puppetlabs/code/environments'
stagehand::webhook::port: 8088
stagehand::webhook::deploy_timeout: '15m'
stagehand::webhook::manage_git: true
```

## Step 3: SSH or HTTPS remote

**HTTPS** (`https://...`): nothing else to do. Leave the three `git_ssh_*`
settings out.

**SSH** (`git@host:org/repo.git`): r10k runs `git`, and `git` uses root's ssh
settings. (r10k's `git: private_key` setting is ignored by the default git
provider, so it cannot be used here.) With `git_ssh_host` set, the class:

- writes `/root/.ssh/config.d/stagehand-webhook.conf` with a `Host` block that
  uses your deploy key and only that key;
- adds the line `Include config.d/*.conf` to root's `~/.ssh/config`, under a
  `Match all` line, and leaves everything else in that file alone;
- writes your host key line to `/root/.ssh/known_hosts_stagehand` and sets
  `StrictHostKeyChecking yes`, so git never stops to ask "are you sure you want
  to continue connecting?" and never trusts an impostor server.

Get the host key line with `ssh-keyscan -t ed25519 github.com` (replace the
host), and compare its fingerprint with the one your git provider publishes
before you paste it. The key file itself never goes into Puppet: only its path
does.

## Step 4: classify the primary and run the agent

Add the class to the primary, for example in its profile:

```puppet
include stagehand::webhook
```

or through the Stagehand console's node classification. Then, on the primary:

```sh
sudo puppet agent -t
```

The first run installs git, r10k and the fork, writes the settings and starts
the `webhook-go` service. A second run should report no changes.

## Step 5: let the pack in (sign its certificate)

The pack asks your Core CA for a certificate named `stagehand-code-manager`
(a certificate signing request, or CSR). Sign it **by hand** on the primary:

```sh
sudo puppetserver ca list
sudo puppetserver ca sign --certname stagehand-code-manager
```

**Never autosign this certname.** Anything your CA signs with the name
`stagehand-code-manager` can deploy code to this primary. If your primary uses
`autosign = true` or an `autosign.conf` with `*`, anyone who can reach the CA
could get that name. Exclude it from autosigning.

Two extra protections:

- **Pin the exact certificate.** After signing, print its fingerprint with
  `sudo puppetserver ca list --all` (the `(SHA256)` value) and put it in
  `allowed_fingerprints`. Then even a second certificate with the same name is
  refused.
- **Revoke when needed.** `sudo puppetserver ca revoke --certname
  stagehand-code-manager` cancels it. The fork reads the CA's revocation list
  (`/etc/puppetlabs/puppet/ssl/crl.pem`) and refuses revoked certificates once
  the primary's copy of the list updates.

The console's Certificates page can approve this request for you **only when
this Core estate is the console's active instance**. Otherwise, use the
`puppetserver ca sign` command above.

## Why it runs as root

The `webhook-go` service runs as root, as upstream's does. r10k has to write
the Puppet code directory, and the service has to read this primary's Puppet
private key to prove who it is. To keep that safe, only callers with an allowed
certificate can reach it, environment names are checked before use, and r10k is
started directly, never through a shell.

## What the pack sends (for troubleshooting)

Because `client_ca` is set, the fork runs in **mTLS-only mode**. The old
git-provider webhook routes (`/api/v1/r10k/...`) are switched off, and the only
routes are:

| Route | What it does |
|-------|--------------|
| `POST /api/v1/deploys` | Deploy one or more environments. |
| `GET /api/v1/deploys/<id>` | Read one deploy's result. |
| `GET /api/v1/deploys?limit=N` | List recent deploys, newest first. |

A deploy request looks like this:

```json
{"environments":[{"name":"production","expected_sha":"<40-character commit id>"}],"wait":true}
```

- `name` must be lower-case letters, digits and underscores only.
- `expected_sha` is required for every environment: it is the commit the pack
  expects to see live afterwards. A deploy whose result does not match is
  reported as failed (`deployed <x>, expected <y>`), not as deployed.
- `wait` must be `true` for now: the request waits until r10k has finished.

Each result says `deployed` only if r10k exited 0 **and** rewrote the
environment's `.r10k-deploy.json` marker during this run with
`deploy_success: true` and the expected commit. Otherwise the `error` field
names the first thing that was wrong, for example `engine exited 1`,
`no deploy marker` or `engine timed out after 15m0s`.

## Troubleshooting

| Symptom | What to check |
|---------|---------------|
| Service will not start | `sudo journalctl -u webhook-go -n 100`. In mTLS mode the fork refuses to start, with `invalid configuration: ...`, if the server certificate or key is missing, `allowed_certnames` is empty, or a deploy setting is invalid. A missing certificate or CRL file is logged there too. |
| Port 8088 answers but every deploy is refused with 422 | The client sent a request the fork rejects; the response names the field (`environments[0].expected_sha`, `wait`, ...). |
| Deploys fail with "command not found" | The config must point at `/opt/puppetlabs/puppet/bin/r10k` (Puppet Core), not `/opt/puppetlabs/puppetserver/bin/r10k` (Puppet Enterprise). Check `/etc/voxpupuli/webhook.yml`. |
| Deploys hang or fail on "Host key verification failed" | The `git_ssh_known_host` line is missing or wrong. Re-run `ssh-keyscan` for the right host and port. Test with `sudo git ls-remote <control_remote>`. |
| "Permission denied (publickey)" | The deploy key path is wrong, its mode is not `0600`, or the key is not added to the repository. |
| Root's ssh config has more than one `Match all` line | The Include step fails on purpose. Leave one `Match all` line, then run the agent again. |
| git says "detected dubious ownership" | The code directory belongs to another user. Run `sudo git config --global --add safe.directory '*'` only if you accept that, or give root ownership of the code directory. |
| A client is refused | Its certname is not in `allowed_certnames`, its fingerprint is not pinned in `allowed_fingerprints`, or it is revoked. |

## Human test steps

Run these on a lab primary that has had the class applied. Each step says what
you should see.

1. Run `sudo puppet agent -t` twice.
   **Expect:** the first run makes changes and finishes without errors; the
   second run makes no changes.
2. Run `/opt/puppetlabs/puppet/bin/r10k version`.
   **Expect:** `r10k 5.0.3` on Puppet 8 (or `4.1.0` on Puppet 7).
3. Run `sudo cat /etc/puppetlabs/r10k/r10k.yaml`.
   **Expect:** your control repository URL under `remote`, the `basedir` and
   `cachedir` paths, and `prefix: false`.
4. Run `sudo cat /etc/voxpupuli/webhook.yml` and `ls -l /etc/voxpupuli/webhook.yml`.
   **Expect:** mode `-rw-r-----` owned by root; `certificate` and `key` name
   this primary's certname; `client_ca`, `crl` and `allowed_certnames` are set;
   `command_path` is `/opt/puppetlabs/puppet/bin/r10k`.
5. Run `systemctl status webhook-go` and `sudo ss -ltnp | grep 8088`.
   **Expect:** the service is `active (running)` and `enabled`, listening on
   port 8088.
6. Run (no client certificate):
   `curl -v --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem https://$(sudo puppet config print certname):8088/api/v1/deploys`
   **Expect:** the TLS handshake is refused (an error mentioning a required
   certificate); no deploy list comes back.
7. Repeat with the primary's own certificate, which is signed but not on the
   allow-list (add `--cert` and `--key` pointing at
   `/etc/puppetlabs/puppet/ssl/certs/<certname>.pem` and
   `/etc/puppetlabs/puppet/ssl/private_keys/<certname>.pem`, with `sudo`).
   **Expect:** refused.
8. For an SSH remote: run `sudo git ls-remote <control_remote>`.
   **Expect:** a list of branches, with no host-key question.
9. Sign the pack's CSR (Step 5), then start a deploy of `production` from the
   Code Manager pack in the console.
   **Expect:** the deploy finishes as deployed, the reported commit matches the
   tip of the `production` branch, and
   `/etc/puppetlabs/code/environments/production/.r10k-deploy.json` shows
   `"deploy_success": true`.
10. Revoke the pack's certificate (`sudo puppetserver ca revoke --certname
    stagehand-code-manager`), wait a minute, and try another deploy.
    **Expect:** the deploy is refused. Re-issue and re-sign the certificate
    afterwards to restore access.
