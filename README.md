# yuseiito-wireguard-setup

Homelab 用の WireGuard VPN サーバを Proxmox VE の unprivileged LXC コンテナとして構築する Ansible IaC。
管理 UI は Cloudflare Tunnel + Access の裏に置き、VPN データプレーンは UDP/51820 を直に晒す構成。

## Prerequisites

- **Proxmox VE** ホスト一台。`pveam` で Debian 13 テンプレートを取得しておく。
- Proxmox ホスト側で **`wireguard` カーネルモジュールがロード済み** であること。unprivileged LXC からは `modprobe` できないため、ホスト側で `/etc/modules-load.d/wireguard.conf` などに登録する必要がある。
- 家庭ルーターで **UDP/51820** を LXC へ通すこと:
  - **IPv4**: ポートフォワード (LAN 内側 IP 宛)。MAP-E (IPv6 プラス等) 環境では割当ポート範囲外だと不可、その場合は v6 のみで運用。
  - **IPv6**: 家庭ルーターのファイアウォール pinhole を LXC の GUA に向けて開ける。v6 経路がメインになる前提。
- Cloudflare 側で:
  - Cloudflare Tunnel を作成し、`tunnel.json` (credentials) と `tunnel_id` を控える。
  - 管理 UI 用のホスト名を Cloudflare Access で保護。
  - VPN エンドポイント用の **A レコードと AAAA レコード** を両方作成 (proxied=false)。`zone_id`, `record_id` (A), `cf_record_id_v6` (AAAA) を控える。
  - DNS 編集権限のある API トークンを発行。

## Required vault variables

ansible-vault で暗号化された `group_vars/all/vault.yml` などに、CLAUDE.md "Required variables (vault)" セクションに列挙された変数 (`wg_public_hostname`, `wg_admin_hostname`, `wg_password_hash`, `tunnel_id`, `tunnel_cred_file`, `cf_ddns_token`, `cf_zone_id`, `cf_record_id`, `cf_record_id_v6`) を定義する。

## Bootstrap (Proxmox host 上で一度だけ)

```bash
pveam update
pveam download local debian-13-standard
./scripts/pct-create.sh
```

`pct-create.sh` は冪等。CT 200 が既にあれば作成をスキップし、`/dev/net/tun` のマウント設定が欠けていれば追記し、停止していれば start する。`SSH_KEYS=/path/to/keys` で公開鍵ファイルを上書きできる (デフォルトは `~/.ssh/authorized_keys`)。

## Deploy (ワークステーションから)

```bash
uv sync
uv run ansible-galaxy collection install -r requirements.yml
uv run ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
```

`--check` で dry-run できる。

## Post-deploy manual setup

wg-easy v15 では WireGuard サーバ側の v6 設定は admin UI 経由なので、初回適用後に管理 UI で:

1. IPv6 を有効化
2. クライアント用 ULA `/64` を割り当て。Docker bridge `fdcc:ad94:bacf:61a3::/64` と先頭 64 bit が異なる必要があるため、4 番目のハクテットを変えること (例: `fdcc:ad94:bacf:61a4::/64`)。`fdcc:ad94:bacf:61a3:1::/64` は host bit しか違わず /64 が衝突するので NG。
3. クライアント config を発行し `Address` に v4/v6 両方が、`AllowedIPs = 0.0.0.0/0, ::/0` が入っていることを確認

詳しい背景は [CLAUDE.md](./CLAUDE.md) の "Network family policy" と "Post-deploy manual UI setup" を参照。
