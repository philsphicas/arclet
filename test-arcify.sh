#!/usr/bin/env bash
# test-arcify.sh — end-to-end test of the arcify + arclet integration.
#
# Flow:
#   1. Build the arclet image (or pull --image).
#   2. Create a fresh, randomly-named resource group in the current
#      `az` subscription.
#   3. arcify --precreate         -> arc.env (Docker --env-file format)
#   4. docker run --env-file arc.env <image>
#   5. Poll Azure until the Arc machine reports Connected.
#   6. Print an ssh command you can paste to reach the container through
#      aztunnel arc connect (your ~/.ssh/config ProxyCommand).
#
# Defaults (override via env or flags):
#   LOCATION=eastus
#   BASE=azl3                     azl3 | ubuntu — which images/<base>/Dockerfile to build
#   IMAGE=arclet:dev             (built locally from images/$BASE/Dockerfile by default)
#   RG_LIFECYCLE=keep            keep | delete-on-success | always-delete
#   POLL_TIMEOUT=300             seconds to wait for Connected
#   MODE=own-key                 own-key | aad-ssh | both
#                                 own-key: inject SSH_AUTHORIZED_KEYS,
#                                          verify SSH as root via az ssh arc.
#                                 aad-ssh: do NOT inject any key, install
#                                          AADSSHLoginForLinux extension,
#                                          verify Entra ID SSH login.
#                                 both:    run both checks; both must pass.
#   SSH_PUBKEY_FILE             defaults to ~/.ssh/id_ed25519.pub, then
#                                ecdsa, then rsa (first one that's readable).
#                                Only required when MODE includes own-key.
#   KEEP_CONTAINER              default ON only when RG_LIFECYCLE=keep
#   KEEP_WORK_DIR               default OFF; set to 1 to retain the env-file
#                                (which holds the Arc private-key material)
#
# Requirements: docker, az (logged in), arcify on PATH or at $ARCIFY_BIN, jq.

set -euo pipefail

# ---------- config ----------
LOCATION="${LOCATION:-eastus}"
BASE="${BASE:-azl3}"
IMAGE="${IMAGE:-arclet:dev}"
RG_LIFECYCLE="${RG_LIFECYCLE:-keep}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"
MODE="${MODE:-own-key}"
ARCIFY_BIN="${ARCIFY_BIN:-arcify}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
if [ -z "$SSH_PUBKEY_FILE" ]; then
    # Prefer modern key types over rsa; fall back to whatever the user has.
    for _candidate in \
        "$HOME/.ssh/id_ed25519.pub" \
        "$HOME/.ssh/id_ecdsa.pub" \
        "$HOME/.ssh/id_rsa.pub"; do
        if [ -r "$_candidate" ]; then
            SSH_PUBKEY_FILE="$_candidate"
            break
        fi
    done
fi
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
    # editorconfig-checker-disable
    cat <<EOF
Usage: $0 [--image <image-ref>]
          [--base <azl3|ubuntu>]
          [--location <azure-region>]
          [--rg-lifecycle <keep|delete-on-success|always-delete>]
          [--mode <own-key|aad-ssh|both>]
          [--timeout <seconds>]
          [--pubkey-file <path>]
          [--rebuild]
          [--pull]
          [-h|--help]

All flags also accept the equivalent env vars (see top of script).

Modes:
  own-key (default)  Inject SSH_AUTHORIZED_KEYS from --pubkey-file; verify
                     SSH as root via 'az ssh arc --local-user root
                     --private-key-file <derived from --pubkey-file>'.
  aad-ssh            Do NOT inject any local key. Install the
                     AADSSHLoginForLinux extension on the Arc resource,
                     grant the caller 'Virtual Machine Administrator
                     Login' on the resource, then verify Entra ID SSH
                     login via 'az ssh arc' (no --local-user).
  both               Run own-key first, then aad-ssh on top. Both must
                     pass.

After PASS the script prints the az ssh arc command(s) you can paste
to reach the container. (aztunnel is supported too if your ~/.ssh/config
sets it as a ProxyCommand for Host /subscriptions/*.)
EOF
    # editorconfig-checker-enable
}

REBUILD=0
PULL=0
require_value() {
    [ -n "${2:-}" ] || {
        echo "$1 requires a value" >&2
        exit 2
    }
}
while [ $# -gt 0 ]; do
    case "$1" in
        --image)
            require_value "$1" "${2:-}"
            IMAGE="$2"
            shift 2
            ;;
        --base)
            require_value "$1" "${2:-}"
            BASE="$2"
            shift 2
            ;;
        --location)
            require_value "$1" "${2:-}"
            LOCATION="$2"
            shift 2
            ;;
        --rg-lifecycle)
            require_value "$1" "${2:-}"
            RG_LIFECYCLE="$2"
            shift 2
            ;;
        --mode)
            require_value "$1" "${2:-}"
            MODE="$2"
            shift 2
            ;;
        --timeout)
            require_value "$1" "${2:-}"
            POLL_TIMEOUT="$2"
            shift 2
            ;;
        --pubkey-file)
            require_value "$1" "${2:-}"
            SSH_PUBKEY_FILE="$2"
            shift 2
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        --pull)
            PULL=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            usage
            exit 2
            ;;
    esac
done

case "$RG_LIFECYCLE" in
    keep | delete-on-success | always-delete) ;;
    *)
        echo "--rg-lifecycle must be keep|delete-on-success|always-delete" >&2
        exit 2
        ;;
esac

case "$MODE" in
    own-key | aad-ssh | both) ;;
    *)
        echo "--mode must be own-key|aad-ssh|both" >&2
        exit 2
        ;;
esac

# ---------- helpers ----------
ts() { date +%H:%M:%S; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
die() {
    printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
    exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need docker
need az
need jq
command -v "$ARCIFY_BIN" >/dev/null 2>&1 \
    || die "arcify not on PATH (set ARCIFY_BIN= or go install)"

if [ "$MODE" != "aad-ssh" ]; then
    if [ -z "$SSH_PUBKEY_FILE" ] || [ ! -r "$SSH_PUBKEY_FILE" ]; then
        die "SSH public key not readable: ${SSH_PUBKEY_FILE:-<none found>} (set SSH_PUBKEY_FILE= or --pubkey-file)"
    fi
    SSH_PUB="$(cat "$SSH_PUBKEY_FILE")"
    # `az ssh arc --private-key-file` wants the matching private key.
    SSH_PRIVKEY_FILE="${SSH_PUBKEY_FILE%.pub}"
    if [ "$SSH_PRIVKEY_FILE" = "$SSH_PUBKEY_FILE" ] || [ ! -r "$SSH_PRIVKEY_FILE" ]; then
        die "Could not locate private key matching $SSH_PUBKEY_FILE (expected $SSH_PRIVKEY_FILE)"
    fi
fi

# ---------- preflight ----------
log "verifying az login + subscription"
# The Windows-WSL `az` shim emits CRLF, so trim trailing CR on every capture.
strip_cr() { tr -d '\r'; }
acct_json="$(az account show -o json)" \
    || die "az account show failed — are you logged in?"
SUB_ID="$(printf '%s' "$acct_json" | jq -r '.id' | strip_cr)"
SUB_NAME="$(printf '%s' "$acct_json" | jq -r '.name' | strip_cr)"
log "  subscription: $SUB_NAME ($SUB_ID)"
log "  mode:         $MODE"

RUN_ID="$(openssl rand -hex 3 2>/dev/null || head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c6)"
RG_NAME="arclet-test-${RUN_ID}"
ARC_NAME="arclet-test-${RUN_ID}"
CONTAINER_NAME="arclet-test-${RUN_ID}"
WORK_DIR="$(mktemp -d -t arclet-test.XXXXXX)"
ENV_FILE="$WORK_DIR/arc.env"

if [ "$MODE" != "aad-ssh" ]; then
    log "using SSH public key from $SSH_PUBKEY_FILE"
fi

# Only keep the container running at the end if the matching Arc resource
# is also kept; otherwise we'd leave a container Connected to a deleted RG.
if [ -z "${KEEP_CONTAINER:-}" ] && [ "$RG_LIFECYCLE" = "keep" ]; then
    KEEP_CONTAINER=1
elif [ "${KEEP_CONTAINER:-0}" = 1 ] && [ "$RG_LIFECYCLE" != "keep" ]; then
    log "NOTE: KEEP_CONTAINER=1 ignored because RG_LIFECYCLE=$RG_LIFECYCLE (Arc resource won't survive cleanup)"
    KEEP_CONTAINER=0
fi

# ---------- cleanup ----------
test_ok=0
arm_id=""
# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    set +e
    log "cleanup phase"

    # On failure, dump the systemd journal from inside the container BEFORE
    # we remove it — the agent's interesting output lives in journald, not
    # in `docker logs`, and the 40 lines of `docker logs --tail` we already
    # printed are mostly the entrypoint preamble.
    if [ "$test_ok" != 1 ] \
        && docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log "  capturing systemd journal from container for diagnosis"
        docker exec "$CONTAINER_NAME" journalctl --no-pager \
            -u arc-connect.service -u himdsd.service -u arcproxyd.service \
            2>&1 | sed 's/^/    [journal] /' || true
    fi

    if [ "${KEEP_CONTAINER:-0}" = 1 ] && [ "$test_ok" = 1 ]; then
        log "  KEEPING container $CONTAINER_NAME (KEEP_CONTAINER=1, test passed)"
    elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log "  stop+rm container $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi

    case "$RG_LIFECYCLE" in
        always-delete)
            log "  deleting RG $RG_NAME (always-delete)"
            az group delete -n "$RG_NAME" --yes --no-wait >/dev/null 2>&1
            ;;
        delete-on-success)
            if [ "$test_ok" = 1 ]; then
                log "  deleting RG $RG_NAME (test passed)"
                az group delete -n "$RG_NAME" --yes --no-wait >/dev/null 2>&1
            else
                log "  KEEPING RG $RG_NAME (test failed) for debugging"
            fi
            ;;
        keep)
            log "  KEEPING RG $RG_NAME (RG_LIFECYCLE=keep)"
            ;;
    esac

    # Work dir contains the env-file with ARC_PRIVATE_KEY material. Default
    # to deleting it; keep only if explicitly requested for debugging.
    if [ "${KEEP_WORK_DIR:-0}" = 1 ]; then
        log "  KEEPING work dir for inspection: $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
        log "  removed work dir $WORK_DIR (set KEEP_WORK_DIR=1 to retain)"
    fi
}
trap cleanup EXIT

# ---------- image: pull or build ----------
if [ "$PULL" = 1 ]; then
    log "pulling image $IMAGE"
    docker pull "$IMAGE" >/dev/null
elif [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # BASE / Dockerfile-on-disk only matter when we actually build. In --pull
    # mode the local repo layout is irrelevant; the image comes from a registry.
    case "$BASE" in
        azl3 | ubuntu) ;;
        *)
            die "--base must be azl3|ubuntu (got: $BASE)"
            ;;
    esac
    DOCKERFILE="$REPO_ROOT/images/$BASE/Dockerfile"
    [ -f "$DOCKERFILE" ] || die "Dockerfile not found at $DOCKERFILE"
    log "building $IMAGE from $DOCKERFILE"
    docker build -t "$IMAGE" -f "$DOCKERFILE" "$REPO_ROOT" >/dev/null
else
    log "image $IMAGE already present (use --rebuild to force, --pull to fetch)"
fi

# ---------- resource group ----------
log "creating resource group $RG_NAME in $LOCATION"
az group create -n "$RG_NAME" -l "$LOCATION" --tags \
    test=arclet owner="${USER:-unknown}" run="$RUN_ID" >/dev/null

# ---------- arcify --precreate ----------
log "arcify --precreate -> $ENV_FILE"
umask 077
"$ARCIFY_BIN" --precreate \
    --arc-subscription "$SUB_ID" \
    --arc-rg "$RG_NAME" \
    --arc-name "$ARC_NAME" \
    --arc-location "$LOCATION" \
    >"$ENV_FILE"

# Capture the ARM resource ID for the SSH summary.
arm_id="$(grep -m1 '^ARC_RESOURCE_ID=' "$ENV_FILE" | cut -d= -f2-)"

# Append the user's SSH pubkey so the entrypoint installs it as
# /root/.ssh/authorized_keys (default user is root). In aad-ssh mode we
# deliberately omit this so the only path to a shell is via Entra ID.
if [ "$MODE" != "aad-ssh" ]; then
    printf 'SSH_AUTHORIZED_KEYS=%s\n' "$SSH_PUB" >>"$ENV_FILE"
fi

log "payload keys: $(grep -E '^ARC_|^SSH_' "$ENV_FILE" | cut -d= -f1 | tr '\n' ' ')"

# ---------- docker run ----------
log "docker run --env-file $ENV_FILE $IMAGE"
# NOTE: no --rm. We want the container to stick around on failure so the
# cleanup trap can collect logs; the trap removes it explicitly.
docker run -d \
    --name "$CONTAINER_NAME" \
    --env-file "$ENV_FILE" \
    --privileged \
    --cgroupns=private \
    --tmpfs /tmp \
    --tmpfs /run \
    --tmpfs /run/lock \
    "$IMAGE" >/dev/null

# ---------- poll for Connected ----------
log "waiting for Arc resource $ARC_NAME to reach Connected (timeout ${POLL_TIMEOUT}s)"
deadline=$(($(date +%s) + POLL_TIMEOUT))
status="" prev_status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    # Bail early if the container died — no point waiting for Connected.
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log "  container exited before reaching Connected"
        break
    fi

    status="$(az resource show \
        -g "$RG_NAME" \
        -n "$ARC_NAME" \
        --resource-type Microsoft.HybridCompute/machines \
        -o json 2>/dev/null \
        | jq -r '.properties.status // empty' \
        | strip_cr || true)"

    if [ "$status" != "$prev_status" ]; then
        log "  status=${status:-<empty>}"
        prev_status="$status"
    fi
    if [ "$status" = "Connected" ]; then
        break
    fi
    sleep 5
done

# ---------- result: Arc Connected? ----------
if [ "$status" = "Connected" ]; then
    log "agent reached Connected"
    test_ok=1
else
    log "FAIL — final status=${status:-<empty>}"
    log "last 40 lines of container log:"
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 | sed 's/^/  /' || true
fi

# ---------- SSH verification ----------
# Strip CR once now so we can interpolate safely below.
arm_id="$(printf '%s' "$arm_id" | strip_cr)"

# az ssh arc through the relay sometimes 404s on the first call while
# the HybridConnectivity SSH service config propagates; retry up to 2x
# after the initial attempt (3 total, ~40s of wall-clock for retries).
az_ssh_arc_retry() {
    local label="$1"
    shift
    local out status max_attempts=3
    for attempt in $(seq 1 "$max_attempts"); do
        out="$("$@" 2>&1)" && status=0 || status=$?
        if [ "$status" = 0 ]; then
            printf '%s' "$out"
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            # Retry diagnostics go to stderr so they reach the user even
            # though the helper's stdout is captured via command substitution.
            printf '[%s]   %s SSH attempt %d/%d failed (rc=%s); retrying in 20s\n' \
                "$(ts)" "$label" "$attempt" "$max_attempts" "$status" >&2
            sleep 20
        fi
    done
    printf '%s' "$out"
    return 1
}

ssh_own_key_ok=0
ssh_aad_ok=0
me_upn=""

if [ "$test_ok" = 1 ] && { [ "$MODE" = "own-key" ] || [ "$MODE" = "both" ]; }; then
    log "verifying own-key SSH via 'az ssh arc --local-user root'"
    # SC2016: $(whoami) is intentionally expanded on the remote sshd, not locally.
    # shellcheck disable=SC2016
    if out="$(az_ssh_arc_retry own-key \
        az ssh arc \
        -g "$RG_NAME" -n "$ARC_NAME" \
        --local-user root \
        --private-key-file "$SSH_PRIVKEY_FILE" \
        -- -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -- 'echo ARCLET_OK_$(whoami)')" \
        && printf '%s' "$out" | grep -q '^ARCLET_OK_root$'; then
        ssh_own_key_ok=1
        log "  PASS — own-key SSH landed as root"
    else
        log "  FAIL — own-key SSH did not succeed"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
fi

if [ "$test_ok" = 1 ] && { [ "$MODE" = "aad-ssh" ] || [ "$MODE" = "both" ]; }; then
    log "installing AADSSHLoginForLinux extension on $ARC_NAME (~30s)"
    if az connectedmachine extension create \
        -g "$RG_NAME" --machine-name "$ARC_NAME" \
        --name AADSSHLoginForLinux \
        --publisher Microsoft.Azure.ActiveDirectory \
        --type AADSSHLoginForLinux \
        --auto-upgrade-minor-version true \
        -o none 2>&1 | sed 's/^/    /'; then
        log "  extension provisioned"

        # One call, both fields, friendly guard for service-principal contexts
        # (where `signed-in-user show` returns nothing and would otherwise kill
        # the script via `set -e` with no actionable message).
        me_json="$(az ad signed-in-user show \
            --query '{id:id,upn:userPrincipalName}' -o json 2>/dev/null \
            || true)"
        me_oid="$(printf '%s' "$me_json" | jq -r '.id // empty' | strip_cr)"
        me_upn="$(printf '%s' "$me_json" | jq -r '.upn // empty' | strip_cr)"
        if [ -z "$me_oid" ] || [ -z "$me_upn" ]; then
            log "  FAIL — could not resolve signed-in user (aad-ssh mode needs a user context, not a service principal)"
        else
            log "  granting 'Virtual Machine Administrator Login' to $me_upn on $ARC_NAME"
            if ! az role assignment create \
                --assignee-object-id "$me_oid" \
                --assignee-principal-type User \
                --role "Virtual Machine Administrator Login" \
                --scope "$arm_id" \
                -o none 2>&1 | sed 's/^/    /'; then
                log "  (role assignment skipped; may already exist or you may lack RBAC write)"
                log "  if the next check FAILs with 'Permission denied', verify the login role has propagated"
            fi

            log "verifying aad-ssh login via 'az ssh arc' (no local-user)"
            # Remote assertion: must land as the AAD UPN (id -un), be in the
            # aad_admins group (admin login role), AND have passwordless sudo
            # (the && chain means ARCLET_OK only prints if all three hold).
            # SC2016: $(id -un) is expanded by the remote shell.
            # shellcheck disable=SC2016
            if out="$(az_ssh_arc_retry aad-ssh \
                az ssh arc \
                -g "$RG_NAME" -n "$ARC_NAME" \
                -- -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                -- 'set -e; id -nG | grep -qw aad_admins && sudo -n /bin/true && echo ARCLET_OK_$(id -un)')" \
                && printf '%s' "$out" | grep -qFx "ARCLET_OK_${me_upn}"; then
                ssh_aad_ok=1
                log "  PASS — aad-ssh SSH landed as $me_upn (in aad_admins, passwordless sudo)"
            else
                log "  FAIL — aad-ssh SSH did not satisfy: landed-as-${me_upn} && in-aad_admins && passwordless-sudo"
                printf '%s\n' "$out" | sed 's/^/    /'
            fi
        fi
    else
        log "  FAIL — extension install did not succeed"
    fi
fi

# Final verdict: SSH check is part of PASS only if it was requested.
case "$MODE" in
    own-key) [ "$ssh_own_key_ok" = 1 ] || test_ok=0 ;;
    aad-ssh) [ "$ssh_aad_ok" = 1 ] || test_ok=0 ;;
    both)
        if [ "$ssh_own_key_ok" != 1 ] || [ "$ssh_aad_ok" != 1 ]; then
            test_ok=0
        fi
        ;;
esac

# ---------- summary ----------
log "===== summary ====="
log "  RG:           $RG_NAME"
log "  Subscription: $SUB_NAME"
log "  Run ID:       $RUN_ID"
log "  Work dir:     $WORK_DIR"
log "  Mode:         $MODE"
if [ "$MODE" = "own-key" ] || [ "$MODE" = "both" ]; then
    log "  own-key SSH:  $([ "$ssh_own_key_ok" = 1 ] && echo PASS || echo FAIL)"
fi
if [ "$MODE" = "aad-ssh" ] || [ "$MODE" = "both" ]; then
    log "  aad-ssh SSH:  $([ "$ssh_aad_ok" = 1 ] && echo PASS || echo FAIL)"
fi
log "  Result:       $([ "$test_ok" = 1 ] && echo PASS || echo FAIL)"

if [ "$test_ok" = 1 ] && [ "${KEEP_CONTAINER:-0}" = 1 ]; then
    log ""
    log "SSH into the container:"
    if [ "$MODE" != "aad-ssh" ]; then
        log "  az ssh arc -g $RG_NAME -n $ARC_NAME --local-user root \\"
        log "      --private-key-file $SSH_PRIVKEY_FILE"
        log ""
        log "Or, if you have aztunnel set as a ProxyCommand for Host /subscriptions/*:"
        log "  ssh root@${arm_id}"
    fi
    if [ "$MODE" != "own-key" ]; then
        log "  az ssh arc -g $RG_NAME -n $ARC_NAME    # Entra ID; no local key needed"
    fi
fi

if [ "$test_ok" = 1 ]; then
    exit 0
else
    exit 1
fi
