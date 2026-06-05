# arclet — Azure Arc agent in a container, kind-style: real systemd as PID 1.
#
# Why systemd? The Connected Machine agent is designed to run as a set of
# systemd-managed services (himdsd, gcad, extd). With real systemd-as-PID-1
# we let systemctl do its normal job — graceful service lifecycle, dependency
# ordering, on-failure restarts — and the in-memory cloud-endpoints state
# survives the post-connect daemon restarts that azcmagent triggers.
#
# Why Azure Linux 3? It's Microsoft's own distribution, shipped from the
# same shop that publishes azcmagent — the agent RPM lives in the default
# `azurelinux-official-ms-non-oss` repo (same version cadence as the Ubuntu
# .deb at packages.microsoft.com). Two concrete wins over a Debian/Ubuntu
# base:
#   1. RPM scriptlets log-and-continue on error, so azcmagent's postinst
#      `systemctl daemon-reload / start himdsd` calls fail gracefully at
#      build time (no PID-1 systemd yet) instead of aborting the install.
#      The unit-file symlinks still get created, so the daemons start
#      correctly at runtime. No dpkg-divert systemctl shim needed.
#   2. The autoupgrade cron leak is auto-resolved: /etc/cron.d doesn't
#      exist on the AL3 base, so azcmagent's postinst attempt to install
#      /etc/cron.d/azcmagent_autoupgrade fails silently and the dead-letter
#      file never lands in the image.
#
# What's NOT free: the /opt/GC_*/install.sh `/proc/1/comm` check still
# requires PID 1's comm to be "systemd" or "init", or the script gives up
# and never writes /usr/lib/systemd/system/{gcad,extd}.service. Without
# that, the Guest Config + Extension Manager daemons are missing at
# runtime — a silent functional regression that breaks anything that
# wants to install an extension (AAD SSH login, AMA, Defender, etc.).
# Fix: exec the install layer under a bash whose argv[0] is `systemd`,
# so /proc/1/comm reads as "systemd" for the duration of the build.
#
# Build:  docker build -t arclet:dev .
# Run:    see README.md (requires --tmpfs /tmp /run /run/lock + --privileged,
#         or equivalent caps, plus cgroup mounts on older Dockers).

FROM mcr.microsoft.com/azurelinux/base/core:3.0

# Base runtime + azcmagent in one tdnf transaction, exec'd under a bash
# masquerading as systemd so the /proc/1/comm check in the Guest Config
# and Extension Manager install.sh scripts is satisfied (see header for
# why). RPM-the-package-manager doesn't care what comm PID 1 has; it's
# the bundled install scripts that do.
#
# Notes vs the historical Ubuntu base:
#   - No `systemd-sysv` equivalent: AL3's `systemd` RPM ships /sbin/init.
#   - No dpkg-divert systemctl shim needed: RPM postinst failures during
#     `systemctl daemon-reload` are tolerated.
#   - tdnf treats `clean all` as freeing repodata + cached packages; combine
#     with a single RUN layer so the cache doesn't bloat the image.
#
# hadolint ignore=DL3041
RUN mkdir -p /build-shims \
 && cp /usr/bin/bash /build-shims/systemd \
 && exec /build-shims/systemd -c '\
        set -euo pipefail; \
        tdnf install -y \
                systemd dbus \
                openssh-server \
                ca-certificates curl gnupg jq sudo \
                iproute procps-ng \
                shadow-utils \
                azcmagent; \
        systemctl enable himdsd.service arcproxyd.service gcad.service extd.service; \
        tdnf clean all; \
        rm -rf /var/cache/tdnf /var/log/*.log /build-shims; \
        :'

# Mask units that either don't make sense in a container or — critically —
# would reach into the host kernel's namespace-LESS state and clobber it.
#
# Two categories of risk this list addresses:
#
# 1. Kernel-global state clobbering. binfmt_misc is the canonical hazard:
#    the kernel exposes a single global /proc/sys/fs/binfmt_misc that every
#    container with CAP_SYS_ADMIN can write to. An unmasked in-container
#    systemd-binfmt does:
#      a) write -1 to every existing entry (flushing the host's
#         registrations, including WSLInterop on WSL — which breaks
#         host-side `az`, `gh.exe`, `docker.exe`, anything that interops
#         with Windows),
#      b) then re-register only what its own /usr/lib/binfmt.d/ ships.
#    Masking systemd-binfmt.service AND the auto/mount units stops the
#    container from ever touching that surface, regardless of --privileged.
#
# 2. Container-hostile units that block boot. AL3 enables systemd-networkd
#    by default, which has nothing to manage in a container (the runtime
#    owns the interface). Its dependent unit systemd-networkd-wait-online
#    sits in `activating` for its 2-minute timeout, blocks
#    network-online.target, and starves any unit that `Wants=` it
#    (himdsd, arcproxyd, sshd…). Masking systemd-networkd alone is
#    sufficient: systemd-networkd-wait-online has `Requires=systemd-
#    networkd` and auto-skips when networkd is masked. systemd-resolved is
#    deliberately NOT masked — it doesn't block boot, and the runtime-
#    provided /etc/resolv.conf works either way.
#
# Mask names that don't exist on the base image are silently skipped, so
# this list stays portable across small base-image package-set changes.
RUN systemctl mask \
        systemd-binfmt.service \
        proc-sys-fs-binfmt_misc.automount \
        proc-sys-fs-binfmt_misc.mount \
        sys-fs-fuse-connections.mount \
        sys-kernel-config.mount \
        systemd-modules-load.service \
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        getty.target \
        systemd-tmpfiles-setup-dev.service \
        systemd-networkd.service

# SSH: hardened config + persisted host keys.
#
# Delete any host keys generated by the openssh-server postinst: they would
# be baked into the image and shared by every container pulled from it,
# which breaks SSH host-key TOFU and lets anyone with the public image
# impersonate any deployed container. entrypoint.sh runs `ssh-keygen -A`
# at first boot to mint a unique set; mount /etc/ssh as a volume to
# persist them across container recreates.
COPY sshd_config /etc/ssh/sshd_config
RUN rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
 && mkdir -p /run/sshd /etc/ssh \
 && systemctl enable sshd.service

# Arc onboarding: oneshot unit invoked on every boot. Idempotency lives in
# the script (see /usr/local/bin/arc-connect), NOT in ConditionPathExists,
# because a partial connect can leave agentconfig.json present but
# cloudconfig.json missing — exactly the failure mode we want to recover
# from on the next boot.
COPY arc-connect /usr/local/bin/arc-connect
COPY arc-connect.service /etc/systemd/system/arc-connect.service
RUN chmod +x /usr/local/bin/arc-connect \
 && systemctl enable arc-connect.service

# Entrypoint wrapper materializes runtime config (SSH authorized keys,
# /etc/arc-connect.env from ARC_* env vars or mounts) BEFORE exec'ing
# /sbin/init.
COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# Clear the image-baked machine-id. systemd generates a fresh one at
# first boot when /etc/machine-id is empty. Without this, every
# container from this image shares one systemd/D-Bus identity, which
# confuses journald and any consumer that keys off machine-id.
RUN : >/etc/machine-id \
 && rm -f /var/lib/dbus/machine-id

# No EXPOSE / -p needed: SSH reaches this container over the Arc
# HybridConnectivity tunnel (`az ssh arc` / `aztunnel arc connect`), not
# from the Docker host.

# systemd uses SIGRTMIN+3 for graceful shutdown.
STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/sbin/init"]
