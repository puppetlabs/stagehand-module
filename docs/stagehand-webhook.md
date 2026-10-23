# Preparing a Puppet Core primary for the Advanced Code Manager pack (`stagehand::webhook`)

This guide is for someone who is new to Puppet and new to automation tools in
general. It walks you from a Puppet Core primary server that has never deployed
code with r10k to one that the Stagehand **Advanced Code Manager** expansion
pack can deploy to, shows how to move a primary that already runs the old
service over to the new one, and then gives a tester a list of checks to prove
it works.

The pack is part of Stagehand Pro. The primary it deploys to runs Puppet Core
(open-source Puppet) or OpenVox.

## What this does, in plain words

Your Puppet code lives in a git repository called the **control repository**.
The Puppet server can only use that code once it has been copied onto the
server, into its code directory. **r10k** is the tool that does the copying: it
reads the control repository and writes one folder per branch (each folder is a
Puppet "environment").

The **Stagehand deploy agent** is a small program that sits on the primary like
a door. When the Code Manager pack wants new code deployed, it knocks on that
door and says "please deploy `production`". The agent runs r10k for it and
reports back whether it worked and which commit is now live. The pack can also
ask it to remove an environment whose branch is gone.

The door has a strict guard. A visitor is only let in if they carry a Puppet
certificate that **your** Puppet certificate authority (CA) signed, that has not
been revoked, and whose name is on the guest list. The pack's certificate is
called `stagehand-code-manager`. Nobody else gets in, not even with a password.

`stagehand::webhook` is one Puppet class that sets all of this up for you: it
installs git and r10k, writes r10k's settings, creates a user for the agent,
installs the agent from a release you pinned, writes its settings, hands the
agent the two folders it needs, and keeps it running.

(The class is still called `webhook` for historical reasons. An earlier version
installed a different program, `webhook-go`, running as root. This guide calls
that the **old service**. Moving from it is covered under "Upgrading from the
old service" below.)

## Why it does not run as root

The old service ran as root, the all-powerful account. The agent does not, and
cannot be made to: the class refuses to compile if you set `run_as` to `root`,
and it checks again when it is applied, in case some other name turns out to be
user id 0. The agent program itself also refuses to start as root.

It runs as a system user called `stagehand-deploy-agent` whose main group is
`puppet`, the group Puppet Server itself runs as. That means:

- **What it owns.** Only three folders: the environments folder
  (`/etc/puppetlabs/code/environments`), r10k's cache
  (`/opt/puppetlabs/puppet/cache/r10k`) and its own state folder
  (`/var/lib/stagehand-deploy-agent`). Those are the only places it can write.
- **What it does not own.** `/etc/puppetlabs/code` itself, `hiera.yaml`, the
  shared `modules` folder, and everything under Puppet's `ssl` folder. The class
  does not change the owner or mode of any of those.
- **Why Puppet Server can still read what it deploys.** The agent writes files
  readable by group `puppet` (mode `0640`, folders `0750`), and Puppet Server is
  in that group.
- **How it gets its keys without being root.** See "Keys" below.

If the agent were ever tricked into running something harmful, the damage is
limited to those three folders instead of the whole machine.

## Words used here

| Word | Meaning |
|------|---------|
| Primary | The main Puppet server. It runs the certificate authority. |
| Control repository | The git repository holding your Puppet code and its module list (`Puppetfile`). |
| r10k | The tool that copies the control repository onto the primary, one folder per branch. |
| Deploy agent | The small service the pack talks to; it runs r10k on request. Package and service name: `stagehand-deploy-agent`. |
| Old service | `webhook-go`, the previous program, which ran as root. |
| Mutual TLS (mTLS) | An encrypted connection where *both* sides show a certificate, not only the server. |
| Certname | The name inside a Puppet certificate, for example `stagehand-code-manager`. |
| CRL | Certificate revocation list: the CA's list of certificates it has cancelled. |
| CA host | The server that runs the certificate authority. On a standard Puppet Core install this is the primary itself. |
| sha256 digest | A 64-character fingerprint of a file. If even one byte changes, the digest changes. |
| Certificate fingerprint | The same idea for a certificate: its SHA-256 digest, written as 32 pairs of hex characters joined by colons (`5B:9A:...:B5`). |
| State directory | The folder where the agent keeps its notes about each deploy (job records) and the lock that stops two deploys running at once. |
| Deploy lock | A lock file in the state directory. Whoever is deploying holds it; anything that must not happen during a deploy (stopping the service, changing file owners) asks for it first. |
| systemd credential | A way to hand a secret file to one service: systemd copies it into a private folder only that service's user can read, while the service runs. |
| systemd drop-in | A small extra settings file that changes how Linux starts and stops a service, without editing the service's own file. |

## Before you start

You need:

1. A Puppet Core primary (Puppet 7 or 8, or OpenVox 8) on Ubuntu/Debian or
   RHEL-family Linux, with a working agent (`puppet agent -t` runs cleanly) and
   Puppet Server installed, so that the group `puppet` exists. The class does
   not create that group.
2. **systemd 247 or later** (`systemctl --version`). The agent receives its
   keys through `LoadCredential=`, which older systemd does not have. Debian 12,
   Ubuntu 22.04 and later, and RHEL 9 and later are fine. RHEL 8 (systemd 239)
   and Ubuntu 20.04 (systemd 245) are **not supported**: the class refuses to
   compile there and says so.
3. This module (`stagehand-stagehand`) available to the primary's environment.
4. Your control repository's URL, and read access to it from the primary:
   - an **HTTPS** URL that needs no password, or
   - an **SSH** URL plus a read-only deploy key whose private half you have
     copied to the primary (for example `/etc/stagehand-deploy-agent/deploy_key`,
     owned by root, mode `0600`; see "Keys").
5. The release URL and sha256 digest of the Stagehand deploy agent package for
   your operating system (see the next section).

## Step 1: pick the agent's package and its digest

Releases are listed at
<https://github.com/puppet-stagehand/stagehand-deploy-agent/releases>. Pick the
release you want (`<version>` below stands for it, for example `1.0.0`), then
the file that matches the primary: the `.deb` for Ubuntu/Debian, the `.rpm` for
RHEL, Rocky or Alma, and the CPU type (`amd64`/`x86_64` or `arm64`/`aarch64`).

| Primary | Package | `agent_package_sha256` |
|---------|---------|------------------------|
| Debian/Ubuntu, Intel/AMD | `stagehand-deploy-agent_<version>_linux_amd64.deb` | `<sha256 from checksums.txt>` |
| Debian/Ubuntu, Arm | `stagehand-deploy-agent_<version>_linux_arm64.deb` | `<sha256 from checksums.txt>` |
| RHEL/Rocky/Alma, Intel/AMD | `stagehand-deploy-agent_<version>_linux_amd64.rpm` | `<sha256 from checksums.txt>` |
| RHEL/Rocky/Alma, Arm | `stagehand-deploy-agent_<version>_linux_arm64.rpm` | `<sha256 from checksums.txt>` |

The link is `agent_package_source` (the file's address under
`https://github.com/puppet-stagehand/stagehand-deploy-agent/releases/download/v<version>/`)
and the 64 characters are `agent_package_sha256`. Take the digest from the
release's own `checksums.txt`, after the signature below verified. A page like
this one can go stale; `checksums.txt` is the source of truth.

**Why the digest matters.** Puppet downloads the package and refuses to install
it unless its digest matches the one you wrote down. If anybody swaps the file
on the download server, or the download is damaged, nothing gets installed.

**Check the signature once, before you pin.** The digest only proves the file is
the one you pinned, so make sure what you pin is genuine. Stagehand signs each
release's `checksums.txt` with cosign (keyless: the signature is tied to the
agent's release workflow, not to a key someone could lose). You need
[cosign](https://docs.sigstore.dev/) 2.4 or newer. Download `checksums.txt` and
`checksums.txt.sigstore.json` from the release, then run:

```sh
TAG=v<version>
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity "https://github.com/puppet-stagehand/stagehand-deploy-agent/.github/workflows/release.yml@refs/tags/${TAG}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
```

It must print `Verified OK`. If it does not, stop and do not use that release.
The `--certificate-identity` value names the exact repository
(`puppet-stagehand/stagehand-deploy-agent`), workflow (`release.yml`) and tag,
so a look-alike release from another organisation or tag fails this check even
if it is signed.

Then check the package you downloaded against that signed file: run
`sha256sum -c --ignore-missing checksums.txt` in the folder that holds both; it
prints `OK` next to each package it finds. The `<sha256 from checksums.txt>` you
put in Hiera is the digest on that package's line.

## Step 2: write the settings (Hiera)

Put the settings in Hiera data for the primary, for example in
`data/nodes/<primary certname>.yaml` in your control repository. Every
parameter is shown here; the ones marked "default" can be left out.

```yaml
# Required
stagehand::webhook::control_remote: 'git@github.com:example/control-repo.git'
# Example for a Debian/Ubuntu Intel/AMD primary; pick your row from Step 1
stagehand::webhook::agent_package_source: 'https://github.com/puppet-stagehand/stagehand-deploy-agent/releases/download/v<version>/stagehand-deploy-agent_<version>_linux_amd64.deb'
stagehand::webhook::agent_package_sha256: '<sha256 from checksums.txt>'

# Only for an SSH control_remote (leave all three out for HTTPS)
stagehand::webhook::git_ssh_host: 'github.com'
stagehand::webhook::git_ssh_key: '/etc/stagehand-deploy-agent/deploy_key'
stagehand::webhook::git_ssh_known_host: 'github.com ssh-ed25519 <host key>'

# Who may call the deploy API (default shown)
stagehand::webhook::allowed_certnames:
  - 'stagehand-code-manager'
# Optional extra pin on the exact certificate (default: empty list).
# Format: the (SHA256) value from `puppetserver ca list --all`, see Step 5.
stagehand::webhook::allowed_fingerprints: []
# stagehand::webhook::allowed_fingerprints:
#   - '5B:9A:0C:41:7E:D2:13:88:6F:A4:20:C9:3B:E7:51:0D:94:2A:C6:7F:18:B3:E0:5D:72:9C:4E:A1:06:F8:3D:B5'

# Revocation list (default: chosen for you, see Step 5)
# stagehand::webhook::crl_path: '/etc/puppetlabs/puppetserver/ca/ca_crl.pem'

# Defaults; change only if you know you need to
stagehand::webhook::run_as: 'stagehand-deploy-agent'  # never root
stagehand::webhook::engine: 'r10k'                    # or 'g10k' with g10k_command_path
# stagehand::webhook::g10k_command_path: '/usr/local/bin/g10k'
# stagehand::webhook::r10k_version: '5.0.3'           # default: 5.0.3 on Puppet 8, 4.1.0 on Puppet 7
stagehand::webhook::r10k_config: '/etc/puppetlabs/r10k/r10k.yaml'
stagehand::webhook::cachedir: '/opt/puppetlabs/puppet/cache/r10k'
stagehand::webhook::basedir: '/etc/puppetlabs/code/environments'  # the agent's deploys.environments_dir and r10k's basedir
stagehand::webhook::port: 8088
stagehand::webhook::ops_listen: '127.0.0.1:8089'      # health and metrics, loopback only
stagehand::webhook::deploy_timeout: '15m'
stagehand::webhook::state_dir: '/var/lib/stagehand-deploy-agent'  # created 0700, owned by run_as
stagehand::webhook::max_jobs: 500                     # deploy records kept
stagehand::webhook::protected_environments: ['production']  # the agent refuses to remove these
stagehand::webhook::legacy_state_dir: '/var/lib/webhook-go'  # only used when moving off the old service
stagehand::webhook::manage_git: true
```

`r10k_config` must live in a folder of its own (for example
`/etc/stagehand/r10k.yaml`), because the class manages that folder; a shared
folder such as `/etc` is refused, and so is putting it in the same folder as
`cachedir`.

## Keys: how the agent proves who it is without being root

The agent needs this primary's Puppet private key (to show its certificate to
the pack) and, for an SSH control repository, your deploy key. Both are
root-only files, and the agent is not root. systemd bridges the gap with
**credentials**: when the service starts, systemd (running as root) copies each
file into a private folder, `/run/credentials/stagehand-deploy-agent.service/`,
that only the agent's user can read. The agent's config points there
(`server.key`, and `deploy_key` for SSH). The class never changes the owner or
mode of anything under Puppet's `ssl` folder, and no key ever enters the catalog
(only paths do).

Two things follow from "systemd copies it at start":

- The deploy key file you name in `git_ssh_key` must exist on the primary
  before the service starts, owned by root, mode `0600`.
- **Certificate renewal needs a service restart.** If the primary's
  certificate or key is renewed or re-issued, run
  `sudo systemctl restart stagehand-deploy-agent`. The agent loads the
  certificate when it starts and serves that one until the next restart. Its
  `/readyz` check and its certificate-expiry numbers re-read the file on disk,
  so they can look healthy while the connection still presents the old
  certificate. (This is a known limitation of this release, tracked as
  MOD-IN-01; the class does not restart the service when the certificate
  changes because the file lives outside the class's control.) The expiry
  number in `/metrics` is read from the file on disk, while `cert_not_after` in
  `/api/v1/info` is the certificate actually being served; if they differ, a
  restart is due. Restart after every renewal.

## Step 3: SSH or HTTPS remote

**HTTPS** (`https://...`): nothing else to do. Leave the three `git_ssh_*`
settings out.

**SSH** (`git@host:org/repo.git`): r10k runs `git`, and `git` runs `ssh`. With
`git_ssh_host` set, the class:

- writes a dedicated ssh settings file, `/etc/stagehand-deploy-agent/ssh_config`
  (owned by the agent user), with `Host *`, your deploy key (and only that key),
  `StrictHostKeyChecking yes` and `BatchMode yes`;
- writes your host key line to `/etc/stagehand-deploy-agent/known_hosts`;
- makes the agent run git as `ssh -F <that file>`, which tells ssh to read **only**
  that file. Nothing in root's `~/.ssh/config`, any other user's, or the
  system-wide `/etc/ssh/ssh_config` is read, so none of them can weaken the
  pinned host key. The class never reads or writes anything under root's home.

With that, git never stops to ask "are you sure you want to continue
connecting?" and never trusts an impostor server.

Get the host key line with `ssh-keyscan -t ed25519 github.com` (replace the
host), and compare its fingerprint with the one your git provider publishes
before you paste it. `git_ssh_known_host` is **one line**. The key file itself
never goes into Puppet: only its path does.

**Every other ssh host your `Puppetfile` uses.** The settings apply to *every*
host (`Host *`), because that is what makes them impossible to weaken. So if a
module in your `Puppetfile` is fetched over ssh from a different server, that
server's host key must be in `known_hosts` too, or its fetch fails closed with
"Host key verification failed". In this release `git_ssh_known_host` holds one
line, so a second ssh host is not supported through the class; use HTTPS URLs
for modules on other servers.

## Step 4: classify the primary and run the agent

Add the class to the primary, for example in its profile:

```puppet
include stagehand::webhook
```

or through the Stagehand console's node classification. Then, on the primary:

```sh
sudo puppet agent -t
```

The first run installs git, r10k and the agent, creates the `stagehand-deploy-agent`
user, writes the settings, hands the user the two folders and starts the
`stagehand-deploy-agent` service. A second run should report no changes.

## Step 5: let the pack in (sign its certificate)

The pack asks your Puppet Core CA for a certificate named `stagehand-code-manager`
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
  `sudo puppetserver ca list --all`. The line for `stagehand-code-manager`
  shows `(SHA256)` followed by 32 pairs of characters joined by colons. Copy
  only those pairs (not the `(SHA256)` label) into `allowed_fingerprints`.
  Then even a second certificate with the same name is refused.
  - Lower case is fine; the class writes every entry in upper case.
  - Puppet refuses the catalog, naming `allowed_fingerprints`, if an entry is
    not exactly 32 colon-separated pairs. That catches a SHA-1 fingerprint
    (20 pairs), hex without colons, the label left on, or a stray space.
  - When the pack's certificate is re-issued, its fingerprint changes. Update
    the list, or the new certificate is refused.
- **Revoke when needed.** `sudo puppetserver ca revoke --certname
  stagehand-code-manager` cancels it. The agent rereads its revocation list
  within a minute of the file changing, and then refuses that certificate.
  Which file it reads matters:
  - **On the CA host** (normally the primary), the class points the agent at
    the CA's own list, `/etc/puppetlabs/puppetserver/ca/ca_crl.pem`. The
    revoke command updates that file immediately, so the refusal follows
    within a minute.
  - **On any other node**, it uses the agent's copy,
    `/etc/puppetlabs/puppet/ssl/crl.pem`. That copy is only refreshed when the
    Puppet agent runs, so a revoked certificate can keep deploying until the
    next agent run. Run `sudo puppet agent -t` after revoking.
  - The class decides with a fact, `stagehand_puppetserver_ca`, which is
    `true` when `ca_crl.pem` exists at that path. If your CA keeps its files
    somewhere else (a custom `cadir`), set `crl_path` to its CRL.

The console's Certificates page can approve this request for you **only when
this Puppet Core estate is the console's active instance**. Otherwise, use the
`puppetserver ca sign` command above.

## Upgrading from the old service (`webhook-go` running as root)

If this primary already runs the old service, applying the new class does the
whole move in **one Puppet run**, in a fixed, careful order:

1. **Look for a running deploy.** The old service takes a lock while it deploys.
   The class asks for that same lock before it touches anything. If a deploy is
   running, the run **stops here**: Puppet reports the step as failed (exit
   code 75) with the single line `a deploy is running on webhook-go; apply again
   when it finishes (nothing was changed)`. Nothing was stopped, removed,
   installed or changed. Wait for the deploy to finish (the pack shows it; or
   `sudo journalctl -u webhook-go -n 50`) and apply again.
2. **Stop and disable the old service**, while holding that lock, after saving
   a copy of its config as `/var/lib/webhook-go/webhook.yml.pre-agent`
   (mode `0600`).
3. **Remove the old package, its config (`/etc/voxpupuli/webhook.yml`), its
   systemd drop-in and its package download folder
   (`/var/cache/stagehand-webhook`).** This happens *before* the agent is
   installed on purpose: installing the agent first would run the old package's
   removal script while a deploy might still be running.
4. **Install the agent** and write its settings.
5. **Copy the old deploy history across, once.** The finished deploys from
   `/var/lib/webhook-go/jobs` are copied into the agent's state folder, so the
   pack's history survives. The Puppet log shows one line, for example
   `imported 120; skipped 0 already present, 3 unfinished, 0 unreadable`. A
   marker file, `/etc/stagehand-deploy-agent/.webhook-go-history-imported`,
   records that this is done, and the copy is not repeated. The old records are
   only read, never changed. (If the old store held more than `max_jobs`
   records, the oldest are not copied; the agent says so.)
6. **Hand the folders to the agent's user.** The environments folder, r10k's
   cache and the agent's state folder (everything the old root-run service
   wrote) become owned by `stagehand-deploy-agent`, group `puppet`. This takes
   the *agent's* deploy lock first, so it never changes files under a running
   deploy; if one is running, the step stops with exit code 75 and `a deploy is
   running on the agent; apply again when it finishes (nothing was changed)`.
   It only runs when something in those folders is not already owned by the
   agent's user, so later runs skip it. (This is also what makes a **fresh**
   primary with root-owned environments work.)
7. **Start the agent.**

On a primary that never ran the old service, steps 1 to 3 and 5 do nothing.

**If the run stops with exit code 75.** It is not an error in your setup; it is
the safety check working. Apply again when the deploy has finished. If it keeps
happening with no deploy running, check whether something still holds the lock:
`sudo flock -n /var/lib/webhook-go/deploy.lock true || echo held`.

**If it stops saying `legacy_state_dir ... does not exist`.** The old service is
running but keeps its records somewhere other than `/var/lib/webhook-go`. Set
`legacy_state_dir` to the `state_dir` value in `/etc/voxpupuli/webhook.yml`.

**What is left behind on purpose.**

- `/var/lib/webhook-go` (its `jobs` folder and `webhook.yml.pre-agent`): the
  rollback source. Delete it by hand when you are sure you will not go back.
- On Red Hat family systems, a modified `/etc/voxpupuli/webhook.yml` may also be
  saved by the package manager as `/etc/voxpupuli/webhook.yml.rpmsave`. The
  class does not touch that file.

**If an earlier version of this module (from the `main` branch) put ssh files
under root's home** (`/root/.ssh/config.d/stagehand-webhook.conf`,
`/root/.ssh/known_hosts_stagehand`, and an `Include config.d/*.conf` line in
`/root/.ssh/config`), the new class does **not** remove them: it never reads or
writes anything under root's home. They are no longer used by anything. You may
delete the two files and that one `Include` line by hand. Leave the `Match all`
line above it alone; it may be yours.

## Rolling back to the old service

Rolling back means putting the old service and the old version of the module
back together; if you only reinstall the old service, the next Puppet run with
the new class removes it again.

1. Stop applying the new class on this primary (pin the module to the version
   or commit you used before, or remove the class).
2. Stop the agent: `sudo systemctl disable --now stagehand-deploy-agent`, then
   remove its package (`sudo dpkg -r stagehand-deploy-agent` or
   `sudo rpm -e stagehand-deploy-agent`).
3. Put the old config back:
   `sudo cp /var/lib/webhook-go/webhook.yml.pre-agent /etc/voxpupuli/webhook.yml`
   (root, mode `0640`).
4. Give root its folders back:
   `sudo chown -R root:root /etc/puppetlabs/code/environments /opt/puppetlabs/puppet/cache/r10k`.
5. Install the old service's package and apply the old module version; it
   starts `webhook-go` again.

Deploys the agent recorded after the cutover live in
`/var/lib/stagehand-deploy-agent/jobs`; they are not copied back.

## Where it keeps its records, and how it stops

**State directory.** The agent writes a small record for every deploy into
`state_dir` (default `/var/lib/stagehand-deploy-agent`), so a deploy's result
can still be read after a restart. The same folder holds the deploy lock. The
class creates it with mode `0700`, owned by the agent's user. The newest
`max_jobs` records (default 500) are kept; older finished ones are deleted.
If the agent finds a record it cannot read, it moves it to
`<state_dir>/jobs/.corrupt/` and logs that; it never deletes that folder, so
look at what is in it and remove it yourself when you are done.

**Stopping and reloading.** The package's systemd unit stops the agent
politely: systemd first asks only the agent to stop, the agent stops any deploy
in progress (including r10k and the git commands it started) and writes down
that the deploy was cut short; if anything is still running a minute later,
systemd ends it by force. The unit has no "reload" command, so
`systemctl reload stagehand-deploy-agent` is refused. To apply new settings,
restart the service; Puppet does that for you whenever the config, the drop-in
or the package changes.

A deploy that was running when the service stopped is reported as failed
(`interrupted by a restart` or `... shutting down`). r10k may have been
stopped part-way, so deploy that environment again.

## Health and metrics (the ops port)

The agent also listens on a **second, plain-HTTP port for monitoring**,
`ops_listen`, which defaults to `127.0.0.1:8089` (loopback only). It has no
authentication, which is why it only listens on the local machine by default;
if you change it to another address, the agent logs a warning that it is
unauthenticated. It serves exactly three things:

| Address | What it tells you |
|---------|-------------------|
| `GET /healthz` | `ok` while the process is alive. |
| `GET /readyz` | `200` with `{"ready":true,"failing":[]}` when the agent can do its job, or `503` naming what is wrong (`engine`, `environments_dir`, `certificate`, `crl`, or `draining` while shutting down). |
| `GET /metrics` | Prometheus text: deploy counts and durations, refusals, and the seconds left on the server certificate (`stagehand_deploy_agent_server_certificate_seconds_until_expiry`) and on the CRL (`stagehand_deploy_agent_crl_seconds_until_expiry`). |

From the primary: `curl -s http://127.0.0.1:8089/readyz`. These three paths are
not available on the deploy port (8088), which answers only to allow-listed
certificates.

The deploy port also answers `GET /api/v1/info` to an allow-listed client: the
agent's version, the engine and its version, the environments folder, when the
server certificate and CRL expire, and which config file it loaded. The pack
uses it to show you what is on the other end.

## What the pack sends (for troubleshooting)

Because a client CA is configured, the agent runs in **mTLS-only mode**: every
route is behind the certificate check. The routes are:

| Route | What it does |
|-------|--------------|
| `POST /api/v1/deploys` | Deploy one or more environments. |
| `GET /api/v1/deploys/<id>` | Read one deploy's result. |
| `GET /api/v1/deploys?limit=N` | List recent deploys, newest first. |
| `DELETE /api/v1/environments/<name>` | Remove an environment (see below). |
| `GET /api/v1/removals/<id>` | Read one removal's result. |
| `GET /api/v1/info` | Describe the agent. |

A deploy request looks like this:

```json
{"environments":[{"name":"production","expected_sha":"<40-character commit id>"}],"wait":true}
```

- `name` must be lower-case letters, digits and underscores only.
- `expected_sha` is required for every environment: it is the commit the pack
  expects to see live afterwards. A deploy whose result does not match is
  reported as failed (`deployed <x>, expected <y>`), not as deployed.
- `wait` must be `true` or `false`. With `true`, the request waits until
  r10k has finished. With `false`, it answers at once (`202`) with the
  deploy's id, and the pack then reads `GET /api/v1/deploys/<id>` until the
  deploy is `deployed` or `failed`. Ids are 32 hex characters; treat them as
  opaque.

Each result says `deployed` only if r10k exited 0 **and** rewrote the
environment's `.r10k-deploy.json` marker during this run with
`deploy_success: true` and the expected commit. Otherwise the `error` field
names the first thing that was wrong, for example `engine exited 1`,
`no deploy marker` or `engine timed out after 15m0s`.

**Removing an environment.** `DELETE /api/v1/environments/<name>` renames the
environment's folder aside and deletes it, under the same deploy lock, so it
never runs during a deploy. It answers `202` with a `Location` header for
`/api/v1/removals/<id>`. Environments listed in `protected_environments`
(default `production`) are refused with `403`. The agent does this; the pack
does not have a button for it yet, so for now it is something you call yourself
with the pack's client certificate (see the human test steps). Delete the git
branch first, otherwise the next deploy of everything brings the environment
back.

## Troubleshooting

| Symptom | What to check |
|---------|---------------|
| The Puppet run fails at compile time mentioning systemd 247 | The primary's systemd is older than 247 (RHEL 8, Ubuntu 20.04), or the `stagehand_systemd_version` fact has not synced yet (run `puppet agent -t` once more). The class cannot run on old systemd. |
| The Puppet run says `run_as must not be root` | You set `run_as` to `root`, or to a name that resolves to user id 0. The agent never runs as root; remove the setting or pick a normal system user. |
| The Puppet run fails with exit code 75 | A deploy is running. See "Upgrading from the old service". Nothing was changed; apply again when it finishes. |
| Service will not start | `sudo journalctl -u stagehand-deploy-agent -n 100`. The agent refuses to start with a message naming the first problem in its config. To check the file without starting: `sudo stagehand-deploy-agent --check-config --config /etc/stagehand-deploy-agent/config.yml`; the two warnings about the certificate and `server.key` not being readable are expected outside the service. |
| `/readyz` answers 503 | Its `failing` list says which check: `engine` (r10k not found), `environments_dir` (not writable by the agent's user), `certificate` or `crl` (file missing or unreadable). |
| Port 8088 answers but every deploy is refused with 422 | The client sent a request the agent rejects; the response names the field (`environments[0].expected_sha`, `wait`, ...). |
| Deploys fail with "command not found" | The config must point at `/opt/puppetlabs/puppet/bin/r10k` (Puppet Core), not `/opt/puppetlabs/puppetserver/bin/r10k` (Puppet Enterprise). Check `/etc/stagehand-deploy-agent/config.yml`. |
| Deploys hang or fail on "Host key verification failed" | The `git_ssh_known_host` line is missing or wrong, or a `Puppetfile` module comes from a second ssh host (see Step 3). Re-run `ssh-keyscan` for the right host and port. |
| "Permission denied (publickey)" | The `git_ssh_key` path is wrong, the file is not root-owned mode `0600`, or the key is not added to the repository. Restart the service after fixing it (systemd copies the key at start). |
| git says "detected dubious ownership" | A repository under the cache or the environments folder is still owned by another user. Run `sudo puppet agent -t`: the hand-over step re-runs when it finds a mismatch. Do not fix it with `chown -R` by hand; the hand-over step skips files with more than one hard link on purpose, and names each one in the run's output. |
| The Puppet run fails naming `fs.protected_hardlinks` | The hand-over step refuses to give folders to the agent's user while the kernel lets any user hard-link to files it does not own (a recursive hand-over as root could then give that user a file such as `/etc/shadow`). Turn the protection on with `sudo sysctl -w fs.protected_hardlinks=1` (and set it in `/etc/sysctl.d/` so it survives a reboot), then apply again. Nothing was changed. |
| The run output says a file was "left as it is: it has more than one hard link" | Something under the environments, cache or state folder has a second name. The hand-over step leaves it alone rather than risk handing over a file outside those folders. Find out what created it; if it is safe, give it a single name (copy it, then remove the original) and apply again. |
| A client is refused | Its certname is not in `allowed_certnames`, its fingerprint is not pinned in `allowed_fingerprints`, or it is revoked. |
| The agent run fails naming `allowed_fingerprints` | An entry is not 32 colon-separated hex pairs. Copy only the pairs after `(SHA256)` from `puppetserver ca list --all`. |
| A revoked certificate can still deploy | Check the `crl:` line (under `server:` then `tls:`) in `/etc/stagehand-deploy-agent/config.yml`. If it is the agent copy (`/etc/puppetlabs/puppet/ssl/crl.pem`), run `sudo puppet agent -t` to refresh it, or set `crl_path` to the CA's file if this node is the CA host with a custom `cadir`. |
| The pack still sees the old certificate after a renewal | Restart the service: `sudo systemctl restart stagehand-deploy-agent` (see "Keys"). |
| `systemctl reload stagehand-deploy-agent` fails with "Job type reload is not applicable" | Expected: there is no reload. Use `sudo systemctl restart stagehand-deploy-agent`. |
| A deploy reads `interrupted by a restart` | The service stopped or the server restarted mid-deploy. Deploy that environment again. |

## Human test steps

Run these on a lab primary. Steps 1 to 7 are for a **fresh** primary that has
had the class applied; steps 8 to 10 need a lab primary that was running the
old service. Each step says what you should see.

1. Run `sudo puppet agent -t` twice.
   **Expect:** the first run makes changes and finishes without errors; the
   second run makes no changes.
2. Run `systemctl status stagehand-deploy-agent`,
   `ps -o user=,group= -C stagehand-deploy-agent` and
   `ls -ld /etc/puppetlabs/code/environments /opt/puppetlabs/puppet/cache/r10k /var/lib/stagehand-deploy-agent`.
   **Expect:** `active (running)` and `enabled`; the process runs as user
   `stagehand-deploy-agent`, group `puppet` (never root); the three folders are
   owned by `stagehand-deploy-agent:puppet` with modes `drwxr-x---`, `drwxr-x---`
   and `drwx------`.
3. Run `curl -s http://127.0.0.1:8089/healthz`, `curl -s http://127.0.0.1:8089/readyz`
   and `curl -s http://127.0.0.1:8089/metrics | grep seconds_until_expiry`.
   **Expect:** `ok`; `{"ready":true,"failing":[]}`; the certificate expiry
   number is positive.
4. Run (no client certificate):
   `curl -v --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem https://$(sudo puppet config print certname):8088/api/v1/deploys`
   **Expect:** the TLS handshake is refused (an error mentioning a required
   certificate); no deploy list comes back. Repeat with the primary's own
   certificate (it is signed but not on the allow-list; add `--cert` and `--key`
   pointing at `/etc/puppetlabs/puppet/ssl/certs/<certname>.pem` and
   `/etc/puppetlabs/puppet/ssl/private_keys/<certname>.pem`, with `sudo`).
   **Expect:** refused.
5. For an SSH remote: run
   `sudo -u stagehand-deploy-agent ssh -G -F /etc/stagehand-deploy-agent/ssh_config git.example.test | grep -iE 'stricthostkeychecking|batchmode|userknownhostsfile'`,
   then start a deploy of `production` from the Code Manager pack.
   **Expect:** `stricthostkeychecking true`, `batchmode yes`, the known-hosts
   file under `/etc/stagehand-deploy-agent`; the deploy finishes as deployed with
   no host-key question. Now put a hostile `Host *` / `StrictHostKeyChecking no`
   block in `/root/.ssh/config` and deploy again.
   **Expect:** unchanged: the deploy still verifies the host key.
6. Sign the pack's CSR (Step 5), then start a deploy of `production` from the
   Code Manager pack in the console, and run
   `ls -l /etc/puppetlabs/code/environments/production | head`.
   **Expect:** the deploy finishes as deployed, the reported commit matches the
   tip of the `production` branch,
   `/etc/puppetlabs/code/environments/production/.r10k-deploy.json` shows
   `"deploy_success": true`, the files are owned by `stagehand-deploy-agent:puppet`
   and Puppet Server compiles a catalog from that environment.
7. Using the pack's certificate and key (`--cert` and `--key` as in step 4),
   delete a throwaway environment whose branch you already removed:
   `curl -i --cacert <ca.pem> --cert <pack.pem> --key <pack.key> -X DELETE https://<primary>:8088/api/v1/environments/feature_x`,
   then read the `Location` it returns. Try the same for `production`, and call
   `GET /api/v1/info`.
   **Expect:** `202` with `Location: /api/v1/removals/<id>`; the removal reads
   `deployed` and the folder is gone; `production` is refused with `403`
   (`environment production is protected`); `info` lists the version, `r10k` and
   the engine's version.
8. On a lab primary running the old service as root, hold its deploy lock to
   imitate a deploy in flight: in a second terminal run
   `sudo flock /var/lib/webhook-go/deploy.lock sleep 600`, then in the first run
   `sudo puppet agent -t` with the new class.
   **Expect:** the run fails at the stop step with exit code 75 and the line
   `a deploy is running on webhook-go; apply again when it finishes (nothing was
   changed)`. Check that nothing changed: `systemctl is-active webhook-go` still
   says `active`, `dpkg -l webhook-go` (or `rpm -q webhook-go`) still shows it
   installed, and `stagehand-deploy-agent` is not installed. Press Ctrl-C in the second
   terminal to release the lock.
9. Run `sudo puppet agent -t` again.
   **Expect:** the run completes: one line `imported N; skipped ...` in the
   output; `webhook-go` is no longer installed or enabled;
   `/var/lib/webhook-go/webhook.yml.pre-agent` exists (mode `-rw-------`) and so
   does the rest of `/var/lib/webhook-go`; the environments, cache and state
   folders are owned by `stagehand-deploy-agent:puppet`; the agent is running;
   the pack's deploy history still lists the old deploys. A third run changes
   nothing. Start a deploy straight away.
   **Expect:** it succeeds (no "dubious ownership" error).
10. Rehearse the rollback from "Rolling back to the old service" on a lab
    primary, then check that the old service answers on port 8088 again with
    its previous config.
11. After renewing or re-issuing the primary's certificate on a lab primary,
    note what `echo | openssl s_client -connect <primary>:8088 2>/dev/null | openssl x509 -noout -serial`
    shows, run `sudo systemctl restart stagehand-deploy-agent` and run it again.
    **Expect:** the serial changes only after the restart.
