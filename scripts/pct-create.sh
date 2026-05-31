#!/bin/bash
set -euo pipefail

CTID=200
HOSTNAME=grumpy
TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
STORAGE=local-lvm
BRIDGE=vmbr0
LXC_CONF=/etc/pve/lxc/${CTID}.conf

# 静的 IP にする (DHCP は MAC 予約が外れた瞬間に Ansible 不通 + RTX830 の v4
# masquerade static が宛先不在の IP を指す二重事故になる)。inventory.yml と
# RTX830 の static の宛先もこの値に揃える。
CT_IP="${CT_IP:-192.168.19.2/24}"
CT_GW="${CT_GW:-192.168.19.1}"

SSH_KEYS="${SSH_KEYS:-$HOME/.ssh/authorized_keys}"
if [[ ! -s "$SSH_KEYS" ]]; then
  echo "ERROR: SSH key file '$SSH_KEYS' missing or empty." >&2
  echo "       Populate ~/.ssh/authorized_keys, or set SSH_KEYS=/path/to/keys." >&2
  exit 1
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW},ip6=auto,firewall=1"

# Step 1: create CT if missing. pct status exits non-zero for unknown CTID.
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT ${CTID} already exists, skipping create." >&2
  config=$(pct config "$CTID")

  # unprivileged は Proxmox の仕様で作成後変更不可。
  if ! grep -qE '^unprivileged:\s*1\s*$' <<<"$config"; then
    echo "ERROR: CT ${CTID} is not unprivileged. Cannot change at runtime; recreate the CT or fix manually." >&2
    exit 1
  fi

  # features: 不足検知時は **既存の他 features (fuse=1 等) を保ったまま** nesting と keyctl を強制する。
  features_line=$(grep -E '^features:' <<<"$config" || true)
  if [[ "$features_line" != *"nesting=1"* || "$features_line" != *"keyctl=1"* ]]; then
    existing="${features_line#features: }"
    merged="nesting=1,keyctl=1"
    if [[ -n "$existing" ]]; then
      IFS=, read -ra parts <<<"$existing"
      for p in "${parts[@]}"; do
        key="${p%=*}"
        [[ "$key" == "nesting" || "$key" == "keyctl" ]] && continue
        merged+=",${p}"
      done
    fi
    echo "CT ${CTID} reconciling features to ${merged}" >&2
    pct set "$CTID" --features "$merged"
  fi

  # net0 drift (UI で DHCP に切替えられた等) を検知して静的に戻す。
  net0_line=$(grep -E '^net0:' <<<"$config" || true)
  if [[ "$net0_line" != *"ip=${CT_IP}"* || "$net0_line" != *"gw=${CT_GW}"* || "$net0_line" != *"ip6=auto"* ]]; then
    echo "CT ${CTID} net0 drifted; reconciling to ${NET0}" >&2
    pct set "$CTID" --net0 "$NET0"
  fi
else
  # DAD: 別ホストが既に CT_IP を握っていたら silently 競合する前に止める。
  # arping -D は重複検知 (= reply 受信) で exit 1。
  ip_only="${CT_IP%/*}"
  if ! arping -D -I "$BRIDGE" -c 2 -w 3 "$ip_only" >/dev/null 2>&1; then
    echo "ERROR: ${ip_only} is already in use on ${BRIDGE}. Pick another CT_IP or free the address." >&2
    exit 1
  fi

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores 1 \
    --memory 512 \
    --swap 512 \
    --rootfs "${STORAGE}:4" \
    --net0 "$NET0" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --ssh-public-keys "$SSH_KEYS"
fi

tun_changed=0
if ! grep -q '^lxc.mount.entry: /dev/net/tun' "$LXC_CONF"; then
  cat >> "$LXC_CONF" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  echo "Note: tun mount appended to ${LXC_CONF}." >&2
  tun_changed=1
fi

# Step 3: start (or reboot if tun config just changed on a running CT).
if [[ "$(pct status "$CTID")" != "status: running" ]]; then
  pct start "$CTID"
elif (( tun_changed )); then
  echo "Rebooting CT ${CTID} so newly-appended tun mount takes effect." >&2
  pct reboot "$CTID"
fi
