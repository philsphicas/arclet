#!/bin/bash
# Pre-init wrapper: runs as the container's initial PID 1 (briefly),
# materializes runtime config files, then exec's /sbin/init so real
# systemd takes over.
#
# This is the kind-style pattern: docker's CMD is /sbin/init, and the
# entrypoint runs imperative setup once before handing off.

set -euo pipefail

log() { printf '[arc-init] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}

#------------------------------------------------------------------------
# 1. SSH user + authorized_keys
#
# A non-root SSH_USER does NOT get passwordless sudo by default. Set
# SSH_USER_SUDO=1 to grant NOPASSWD: ALL — this is useful for ephemeral
# debug containers but dangerous for "an Azure-RBAC-gated SSH endpoint"
# where the point of using a non-root account is to NOT have ambient
# root from every authenticated SSH session.
#------------------------------------------------------------------------
ARC_USER="${SSH_USER:-root}"
if [ "$ARC_USER" != "root" ]; then
    if ! id -u "$ARC_USER" >/dev/null 2>&1; then
        log "creating user $ARC_USER"
        useradd -m -s /bin/bash "$ARC_USER"
        if [ "${SSH_USER_SUDO:-0}" = 1 ]; then
            log "granting passwordless sudo to $ARC_USER (SSH_USER_SUDO=1)"
            usermod -aG sudo "$ARC_USER" || true
            printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$ARC_USER" \
                >"/etc/sudoers.d/90-${ARC_USER}"
            chmod 440 "/etc/sudoers.d/90-${ARC_USER}"
        fi
    fi
fi

home="$(getent passwd "$ARC_USER" | cut -d: -f6)"
[ -n "$home" ] || die "cannot resolve home directory for user $ARC_USER"

install -d -m 0700 -o "$ARC_USER" -g "$ARC_USER" "$home/.ssh"

auth_keys=""
if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    auth_keys="$SSH_AUTHORIZED_KEYS"
    log "using SSH_AUTHORIZED_KEYS from environment"
elif [ -f /run/secrets/ssh_authorized_keys ]; then
    auth_keys="$(cat /run/secrets/ssh_authorized_keys)"
    log "using SSH authorized_keys from /run/secrets/ssh_authorized_keys"
elif [ -f /etc/arc-container/authorized_keys ]; then
    auth_keys="$(cat /etc/arc-container/authorized_keys)"
    log "using SSH authorized_keys from /etc/arc-container/authorized_keys"
else
    log "WARNING: no SSH_AUTHORIZED_KEYS provided; sshd will accept no logins"
fi

if [ -n "$auth_keys" ]; then
    printf '%s\n' "$auth_keys" >"$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    chown "$ARC_USER:$ARC_USER" "$home/.ssh/authorized_keys"
fi

#------------------------------------------------------------------------
# 2. SSH host keys (ssh-keygen -A only creates missing ones, so this
#    is idempotent — and if /etc/ssh is mounted as a volume, persists.)
#------------------------------------------------------------------------
ssh-keygen -A >/dev/null

#------------------------------------------------------------------------
# 3. Arc onboarding env file (consumed by /usr/local/bin/arc-connect,
#    which is exec'd by arc-connect.service after systemd boot).
#
#    We write to /etc/arc-connect.env only when at least one of the
#    required ARC_* inputs is present. If none are set, arc-connect.service
#    will skip the connect gracefully (the script exits 0 if no inputs).
#------------------------------------------------------------------------
arc_inputs_present=false
for v in ARC_SUBSCRIPTION_ID ARC_RESOURCE_GROUP ARC_RESOURCE_NAME \
    ARC_LOCATION ARC_TENANT_ID ARC_VMID ARC_PRIVATE_KEY \
    ARC_PRIVATE_KEY_FILE; do
    if [ -n "${!v:-}" ]; then
        arc_inputs_present=true
        break
    fi
done

if $arc_inputs_present; then
    log "materializing /etc/arc-connect.env"
    # install -m sets the mode atomically; avoids any race between
    # creating the file at the inherited umask and chmod'ing it.
    install -m 0600 /dev/null /etc/arc-connect.env
    for v in ARC_SUBSCRIPTION_ID ARC_RESOURCE_GROUP ARC_RESOURCE_NAME \
        ARC_LOCATION ARC_TENANT_ID ARC_VMID ARC_CLOUD \
        ARC_CORRELATION_ID ARC_PRIVATE_KEY ARC_PRIVATE_KEY_FILE \
        ARC_ALLOW_AZURE_VM_TEST; do
        val="${!v:-}"
        if [ -n "$val" ]; then
            # %q quotes for safe bash sourcing. arc-connect uses `source`,
            # never EnvironmentFile=, so this is consumed by bash only.
            printf '%s=%q\n' "$v" "$val" >>/etc/arc-connect.env
        fi
    done
else
    log "no ARC_* env or mounted private key; arc-connect.service will be a no-op"
fi

#------------------------------------------------------------------------
# 4. Hand off to systemd. From here on, /sbin/init is PID 1.
#------------------------------------------------------------------------
log "exec'ing $*"
exec "$@"
