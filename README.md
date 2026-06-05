# arclet

A small container image that gives any Docker-capable Linux host an
**Azure-RBAC-gated SSH endpoint** — reachable from anywhere your `az` is
logged in, without enrolling the host with Azure Arc, opening a firewall
port, configuring a VPN, or giving it a public IP.

The container runs the Azure Connected Machine agent (`azcmagent`) and
`sshd`. On startup it Arc-enrolls *itself* (not the host) against a
**pre-created** `Microsoft.HybridCompute/machines` resource using
`azcmagent connect existing` and a private key supplied via env var or
volume. Inbound SSH then rides Azure's HybridConnectivity relay, the same
channel that powers `az ssh arc`.

> **Status:** experimental / personal-use. Not affiliated with or
> supported by Microsoft. `azcmagent` here runs in a way Microsoft does
> not officially support.

## When you'd use this

- You have a host *somewhere* (on-prem, lab, third-party cloud, a
  bouncing-around laptop, …) and want to reach it by SSH from elsewhere
  without standing up a tunnel-VPN-bastion-cloud-relay yourself.
- You already live in Azure RBAC, so "who can `ssh` this thing" is best
  expressed as a role assignment, not as a global SSH-key file.
- You don't want to (or can't) enroll the host *itself* with Arc — but
  you can run a container on it.

It is also useful as a **disposable Arc-machine fixture** for local
development against anything that talks to `Microsoft.HybridCompute`
(extensions, policy, RBAC, etc.) — the agent is real, not a mock, so
ARM sees a real Connected resource.

## How it fits together

```
            ┌────────────────────────────────────────┐
            │ Azure                                  │
            │   Microsoft.HybridCompute/machines/X   │ ← arcify --precreate
            │   Microsoft.HybridConnectivity/.../SSH │ ← created on demand
            └─────────────▲──────────────────────────┘
                          │ HybridConnectivity relay
                          │ (outbound HTTPS from agent;
                          │  inbound via Azure Relay WS)
                          │
            ┌─────────────┴──────────────────────────┐
            │ your host (anywhere)                   │
            │  ┌───────────────────────────────────┐ │
            │  │ arclet container                  │ │
            │  │   azcmagent (Connected)           │ │
            │  │   sshd     (listens on :22)       │ │
            │  └───────────────────────────────────┘ │
            └────────────────────────────────────────┘

       you → az login → ssh root@/subscriptions/.../machines/X
       (via aztunnel arc connect or `az ssh arc`)
```

Pairs naturally with [`arcify`](https://github.com/philsphicas/arcify),
which generates the keypair, pre-creates the Arc resource, and emits an
env-file in the exact shape arclet consumes. You can also pre-create the
resource yourself via `az rest` / Bicep / Terraform.

## Quick start

Assuming `arcify` is on `$PATH` and you're `az login`'d:

```sh
# 1. Pre-create the Arc resource + emit an env-file with identity+key
arcify --precreate \
    --arc-subscription "$(az account show --query id -o json | jq -r)" \
    --arc-rg my-arclet-rg \
    --arc-name my-host \
    --arc-location eastus \
  > arc.env

# 2. Add your SSH public key to the env-file
#    (Skip this step if you only ever want to log in via Entra ID — see
#    "Entra ID SSH login" below.)
echo "SSH_AUTHORIZED_KEYS=$(cat ~/.ssh/id_ed25519.pub)" >> arc.env

# 3. Run the container
docker run -d --name arclet \
    --privileged --cgroupns=private \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    --env-file arc.env \
    ghcr.io/philsphicas/arclet:dev

# 4. SSH in from anywhere your `az` is logged in
az ssh arc \
    --resource-group   my-arclet-rg \
    --name             my-host \
    --local-user       root \
    --private-key-file ~/.ssh/id_ed25519
```

`az ssh arc` is the default because it works out of the box: it
discovers the HybridConnectivity endpoint, mints a short-lived cert if
needed, and tunnels through the Arc relay — no local proxy setup
required. If you already use [`aztunnel`](https://github.com/microsoft/azure-relay-bridge-go)
as a `~/.ssh/config` `ProxyCommand`, that works too (see [SSH access
(how the tunnel works)](#ssh-access-how-the-tunnel-works) below).

Onboarding takes ~30–90 s (network checks + MSI cert retrieval). After
that, agent heartbeats stay current and the SSH relay route remains
live.

## Image tags

Two base images are published in parallel. **Azure Linux 3** is the
default — its build is Microsoft's own distro shipping the agent from
the same package source — and owns the unsuffixed tags. **Ubuntu 24.04**
is also maintained as a second variant under a `-ubuntu` suffix; use it
if you have a specific reason to prefer a Debian-family userland.

Published to GHCR:

| Tag | Base | Updated | Notes |
|---|---|---|---|
| `ghcr.io/philsphicas/arclet:dev` | Azure Linux 3 | every push to `main` | rolling; expect breakage |
| `ghcr.io/philsphicas/arclet:latest` | Azure Linux 3 | on each `vX.Y.Z` tag | most recent stable release |
| `ghcr.io/philsphicas/arclet:vX.Y.Z` | Azure Linux 3 | on tag | immutable semver pin |
| `ghcr.io/philsphicas/arclet:vX.Y` | Azure Linux 3 | on tag | major.minor floating pin |
| `ghcr.io/philsphicas/arclet:dev-ubuntu` | Ubuntu 24.04 | every push to `main` | rolling; expect breakage |
| `ghcr.io/philsphicas/arclet:latest-ubuntu` | Ubuntu 24.04 | on each `vX.Y.Z` tag | most recent stable release |
| `ghcr.io/philsphicas/arclet:vX.Y.Z-ubuntu` | Ubuntu 24.04 | on tag | immutable semver pin |
| `ghcr.io/philsphicas/arclet:vX.Y-ubuntu` | Ubuntu 24.04 | on tag | major.minor floating pin |

Both variants are built `linux/amd64` and `linux/arm64`, ship the same
shared scripts (`entrypoint.sh`, `arc-connect`, `arc-connect.service`,
`sshd_config`), and accept the same `ARC_*` and `SSH_*` inputs.

## Inputs

| Input | Env var | File-mount fallback (first match wins) |
| --- | --- | --- |
| Arc subscription ID | `ARC_SUBSCRIPTION_ID` | — |
| Arc resource group | `ARC_RESOURCE_GROUP` | — |
| Arc resource name | `ARC_RESOURCE_NAME` | — |
| Arc location | `ARC_LOCATION` | — |
| Arc tenant ID | `ARC_TENANT_ID` | — |
| Arc VM ID (UUID stamped on the resource) | `ARC_VMID` | — |
| Arc private key (base64 PKCS#1 DER) | `ARC_PRIVATE_KEY` | `/run/secrets/arc_private_key`, `/etc/arc-container/private-key` |
| SSH authorized keys *(optional if you log in only via Entra ID)* | `SSH_AUTHORIZED_KEYS` | `/run/secrets/ssh_authorized_keys`, `/etc/arc-container/authorized_keys` |

Optional:

| Env var | Default | Notes |
| --- | --- | --- |
| `ARC_CLOUD` | `AzureCloud` | Passed to `azcmagent connect existing --cloud` |
| `ARC_CORRELATION_ID` | unset | Optional GUID for `azcmagent connect existing --correlation-id` |
| `SSH_USER` | `root` | Non-root: entrypoint creates the account at first boot |
| `SSH_USER_SUDO` | unset | When set to `1` *and* `SSH_USER` is non-root, grant the user passwordless `sudo`. Off by default — the point of a non-root account is to gate root |
| `ARC_ALLOW_AZURE_VM_TEST` | unset | Set to `true` to export `MSFT_ARC_TEST=true`. Only needed if the *container host* is itself an Azure VM. See <https://aka.ms/azcmagent-testwarning>. |

## Where the private key comes from

The private key is the second half of the RSA-2048 keypair whose public
half was uploaded to the Arc resource's `properties.clientPublicKey` (as
PKCS#1 DER, base64). `arcify` generates the pair in memory, uploads the
public half, and hands the private half to you in the env-file. For
arclet you re-use that same private key on every container start.

If you're rolling your own pre-create flow with `az rest`:

```sh
openssl genrsa -out arc.key 2048
PRIVKEY_B64=$(openssl rsa -in arc.key -outform DER -traditional 2>/dev/null | base64 -w0)
PUBKEY_B64=$(openssl rsa -in arc.key -RSAPublicKey_out -outform DER 2>/dev/null | base64 -w0)
VMID=$(uuidgen)
# PUT the Arc machine with properties.clientPublicKey=$PUBKEY_B64
# and properties.vmId=$VMID. See api-version 2024-07-10.
# Then save $PRIVKEY_B64 and $VMID for the container.
```

## Why `--privileged`

systemd-as-PID-1 needs cgroup write access and a few additional mounts
that Docker by default doesn't give containers. This matches `kind`'s
recommendation for "real Linux init in a container."

- `--privileged` is the simplest knob.
- `--cap-add SYS_ADMIN` alone is *not* enough on most current Dockers.
- `--cgroupns=private --tmpfs /tmp --tmpfs /run --tmpfs /run/lock` are
  also required.

Don't run untrusted workloads in this image.

The Dockerfile masks `systemd-binfmt.service` and the binfmt_misc
auto/mount units. This is critical on WSL: an unmasked in-container
`systemd-binfmt` would flush the host's `/proc/sys/fs/binfmt_misc/` (it's
kernel-global, not namespaced) and clobber `WSLInterop`, breaking
host-side `az`, `gh.exe`, `docker.exe`, etc.

## SSH access (how the tunnel works)

`az ssh arc` is the default. It targets the Arc resource by ARM name,
creates the HybridConnectivity SSH service config on demand, and tunnels
your local SSH client through the Arc relay:

```sh
az ssh arc \
    --resource-group   "$ARC_RESOURCE_GROUP" \
    --name             "$ARC_RESOURCE_NAME" \
    --local-user       root \
    --private-key-file ~/.ssh/id_ed25519
```

If you'd rather use a regular `ssh` client (e.g. for `scp`/`rsync`,
`ssh -L`, multiplexing, etc.), [`aztunnel`](https://github.com/microsoft/azure-relay-bridge-go)
gives you a drop-in `ProxyCommand`:

```sshconfig
Host /subscriptions/*
    ProxyCommand aztunnel arc connect --resource-id %n --port %p
    User root
```

Then:

```sh
ssh root@/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/machines/<name>
```

First connection through the relay sometimes takes ~30 s for the SSH
service config to propagate; a second attempt right after succeeds.

## Entra ID SSH login (no local SSH key needed)

Because arclet is a real Arc machine, you can install Microsoft's AAD
SSH extension on it and then log in with your Entra ID — no SSH key
exchange, no `SSH_AUTHORIZED_KEYS`. The extension drops a small
`AuthorizedKeysCommand` helper into sshd that validates an Entra ID
short-lived cert against the caller's Azure RBAC role on the resource.

One-time per container:

```sh
# 1. Install the extension on the Arc resource.
az connectedmachine extension create \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --machine-name   "$ARC_RESOURCE_NAME" \
    --name           AADSSHLoginForLinux \
    --publisher      Microsoft.Azure.ActiveDirectory \
    --type           AADSSHLoginForLinux \
    --auto-upgrade-minor-version true

# 2. Grant yourself (or the principal who will SSH in) a login role.
#    "Virtual Machine User Login"  → unprivileged shell
#    "Virtual Machine Administrator Login" → shell + passwordless sudo
ARC_ID=$(az connectedmachine show \
    -g "$ARC_RESOURCE_GROUP" -n "$ARC_RESOURCE_NAME" \
    --query id -o json | jq -r)
ME=$(az ad signed-in-user show --query id -o json | jq -r)
az role assignment create \
    --assignee-object-id "$ME" \
    --assignee-principal-type User \
    --role "Virtual Machine Administrator Login" \
    --scope "$ARC_ID"
```

Then, from any machine you're `az login`'d on:

```sh
az ssh arc -g "$ARC_RESOURCE_GROUP" -n "$ARC_RESOURCE_NAME"
```

No `--local-user`, no `--private-key-file`. The extension auto-creates
a Linux account for you on first login (username = your UPN), puts you
in the `aad_admins` group for the admin role (or `aad_users` for the
user role), and `aad_admins` has passwordless `sudo` via
`/etc/sudoers.d/aad_admins`.

A few timing caveats:

- The extension install can take a couple of minutes on a freshly-Connected
  machine; the agent's extension manager polls.
- `az role assignment create` returns instantly, but ARM data-plane reads
  may take a handful of seconds to see the new assignment. If the first
  `az ssh arc` returns a permission error, wait ~10 s and try again.
- The same "first call sometimes 404s while the SSH service config
  propagates" caveat from the previous section still applies.

## Persisting state across container restarts

The agent stores its identity, certs, and config under `/var/opt/azcmagent`.
SSH host keys live in `/etc/ssh`. Mount volumes to skip re-registration
(and the host-key warning) when you recreate the container:

```sh
docker run -d --name arclet \
    --privileged --cgroupns=private \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    -v arclet-state:/var/opt/azcmagent \
    -v arclet-sshd:/etc/ssh \
    --env-file arc.env \
    ghcr.io/philsphicas/arclet:dev
```

When the container restarts with the state volume present,
`/usr/local/bin/arc-connect` finds an existing `Connected` registration
whose `resourceId` and `vmId` match the requested target and exits
without re-running `connect`. If the existing registration points at a
*different* resource, the script refuses to clobber it; either recreate
the volume empty, or `docker exec` in and run
`azcmagent disconnect --force-local-only` first.

## Verifying

Inside the container:

```sh
docker exec arclet azcmagent show
# Agent Status            : Connected
# Resource Id             : /subscriptions/.../machines/<name>
# Agent Last Heartbeat    : <recent timestamp, updates every ~5 min>
```

From Azure:

```sh
az connectedmachine show \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --name           "$ARC_RESOURCE_NAME" \
    --query 'status' -o json | jq -r
# "Connected"
```

systemd journals (everything except the brief pre-init wrapper output
lives in the journal, not `docker logs`):

```sh
docker exec arclet journalctl -fu arc-connect.service
docker exec arclet journalctl -fu himdsd.service
docker exec arclet tail -f /var/opt/azcmagent/log/himds.log
```

## Limitations

- **Private key on the command line.** `azcmagent connect existing` takes
  the key as a `--private-key <base64>` flag (no `--private-key-file`),
  so the value is briefly visible in `/proc/<pid>/cmdline` while connect
  runs. Mitigation: use a short-lived keypair and rotate after enrollment.
- **`--privileged` required.** Don't run untrusted code in the container.
- **Not a production agent.** This image runs `azcmagent` in a way
  Microsoft does not officially support.

## Files

| File | Purpose |
|---|---|
| `images/azl3/Dockerfile` | Image definition for the default Azure Linux 3 variant |
| `images/ubuntu/Dockerfile` | Image definition for the Ubuntu 24.04 variant |
| `images/ubuntu/systemctl-install-shim` | Build-time-only no-op `systemctl` used during apt-install of azcmagent on the Ubuntu variant |
| `entrypoint.sh` | Pre-init wrapper: writes config + authorized_keys, then `exec /sbin/init` (shared across bases) |
| `arc-connect` | Onboarding script — run once at boot by `arc-connect.service` (shared across bases) |
| `arc-connect.service` | systemd unit for the above, ordered after `himdsd.service` (shared across bases) |
| `sshd_config` | Hardened sshd config, key-only auth (shared across bases) |
| `test-arcify.sh` | End-to-end integration test: builds the image, calls `arcify --precreate`, runs the container, polls for `Connected`, then verifies SSH (own-key, Entra ID, or both) |
| `.dockerignore` | Build-context filter |

Both Dockerfiles are built with the repository root as the build context:

```sh
docker build -f images/azl3/Dockerfile   -t arclet:dev .
docker build -f images/ubuntu/Dockerfile -t arclet:dev-ubuntu .
```

## Testing

`test-arcify.sh` runs the full integration loop against a real Azure
subscription. It creates a randomly-named resource group, calls
`arcify --precreate` to mint a fresh Arc resource + payload, runs the
container, polls until the agent reports `Connected`, and then verifies
that SSH actually works through the relay.

```sh
# Default: build the azl3 image locally, eastus, verify own-key SSH (via
# az ssh arc), keep the RG and container so you can SSH in again later.
./test-arcify.sh

# Test the Ubuntu variant instead
./test-arcify.sh --base ubuntu

# Verify Entra ID SSH login (no local key needed — installs the
# AADSSHLoginForLinux extension, grants you the admin login role,
# then attempts `az ssh arc`).
./test-arcify.sh --mode aad-ssh

# Verify both paths in one container.
./test-arcify.sh --mode both

# Pull the published image instead of building
./test-arcify.sh --pull --image ghcr.io/philsphicas/arclet:dev

# Clean up on success
./test-arcify.sh --rg-lifecycle delete-on-success
```

Useful env vars (in addition to flags shown by `--help`):

- `BASE` — same as `--base`: `azl3` (default) or `ubuntu`. Selects which `images/<base>/Dockerfile` is built when not using `--pull`.
- `MODE` — same as `--mode`: `own-key` (default), `aad-ssh`, or `both`
- `SSH_PUBKEY_FILE` — pubkey to inject (default: `~/.ssh/id_ed25519.pub`, then ecdsa, then rsa). Not used when `MODE=aad-ssh`.
- `KEEP_CONTAINER=1` — leave the container running at the end (only honored when the Arc resource is also being kept, i.e. `--rg-lifecycle keep`)
- `KEEP_WORK_DIR=1` — keep the per-run scratch dir (contains the Arc onboarding env-file with the private-key material). Off by default.

Requires `arcify` on `$PATH`, a logged-in `az`, `docker`, `jq`. See
`./test-arcify.sh --help` for all flags.

## License

MIT — see `LICENSE`.
