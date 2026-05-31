#!/bin/bash
set -euo pipefail

CTID=200
HOSTNAME=grumpy
TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
STORAGE=local-lvm
BRIDGE=vmbr0
LXC_CONF=/etc/pve/lxc/${CTID}.conf

# Operator's SSH public keys to seed into the CT. Defaults to the invoking
# user's authorized_keys; override with SSH_KEYS=/path env var if running via
# sudo without -H (where $HOME may point at the wrong user).
SSH_KEYS="${SSH_KEYS:-$HOME/.ssh/authorized_keys}"
if [[ ! -s "$SSH_KEYS" ]]; then
  echo "ERROR: SSH key file '$SSH_KEYS' missing or empty." >&2
  echo "       Populate ~/.ssh/authorized_keys, or set SSH_KEYS=/path/to/keys." >&2
  exit 1
fi

# Step 1: create CT if missing. pct status exits non-zero for unknown CTID.
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT ${CTID} already exists, skipping create." >&2
else
  # nesting=1 + keyctl=1 は unprivileged LXC で Docker を動かすために必須。
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores 1 \
    --memory 512 \
    --swap 512 \
    --rootfs "${STORAGE}:4" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --ssh-public-keys "$SSH_KEYS"
fi

# Step 2: ensure /dev/net/tun mount is present in the LXC conf. WireGuard needs
# this and unprivileged LXC does not expose it by default. Idempotent on its
# own — runs even when the CT pre-existed (e.g. created by a previous version
# of this script that exited early, or created manually) so re-running can
# repair a partially-configured CT. Note: lxc.mount.entry is read at CT start,
# so an append on a running CT requires a stop+start to take effect.
if ! grep -q '^lxc.mount.entry: /dev/net/tun' "$LXC_CONF"; then
  cat >> "$LXC_CONF" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  echo "Note: tun mount appended to ${LXC_CONF}; restart CT ${CTID} to apply." >&2
fi

# Step 3: start if not already running.
if [[ "$(pct status "$CTID")" != "status: running" ]]; then
  pct start "$CTID"
fi
