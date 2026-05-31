# yuseiito-wireguard-setup

yuseiitoの自宅に設定している WireGuard VPNサーバの構成.

> [!NOTE]
> このリポジトリは、もっぱら @yuseiito 自身の個人的な記録として公開しているものです。私の環境に特化した内容であり、 **一般的なガイドや推奨構成を意図していません** 。
> 参考にする場合は、自分の環境に適合させるための十分な理解と注意をもって行ってください。


**含まれるもの**:
- Proxmox VE 上に起動するLXCコンテナ
- wg-easy を使った WireGuard VPN サーバ

## Prerequisites

- **Proxmox VE** の動作中のノードがあること
- Proxmox ホスト側で **`wireguard` カーネルモジュールがロード済み**かつ**永続化済み**であること:
    ```bash
    echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf
    sudo modprobe wireguard
    ```
    `wg_easy` ロール先頭の preflight が runtime load を grep で確認するが、永続化は人間の責任。host 再起動後に load されないと wg-easy は silently 沈黙する
- Map-E接続の家庭回線.
- 家庭ルーター (RTX830) で、LXC の IPv6 GUA と IPv4 (MAP-E 経由) の両方に対して WireGuard の UDP ポート (`wg_port`) を通す設定ができること.  `wg_port` を割当ポート範囲内から選ぶ。 (任意ポートでは v4 着信不可)。具体的な投入コマンドは後述の [RTX830 設定例](#rtx830-設定例) を参照:
- Cloudflare 側で:
  - Zero Trust で **Cloudflare Tunnel (remotely-managed)** を作成し、Configure の install コマンドに含まれる **接続トークン (`--token eyJ...`)** を控える 
  - そのトンネルに **Public Hostname** を追加: 管理 UI ホスト名 (apex 直下 1 ラベル、例 `wg-admin.yuseiito.com`) → `http://wg-easy:51821`。
  - 管理 UI 用ホスト名を **Cloudflare Access** で保護。
  - VPN エンドポイント用の **A レコードと AAAA レコード** を両方作成 (proxied=false)。`cf_zone_id`, `cf_record_id` (A), `cf_record_id_v6` (AAAA) を控える。両レコードとも DDNS が現在の公開 IP に更新する。
  - DNS 編集権限 (Zone:DNS:Edit を対象ゾーンに限定) の API トークンを発行。

## 必須変数

詳細は CLAUDE.md "必須変数" 節。配置は秘密か否かで分ける:

- **`group_vars/all/vars.yml`** (平文 commit 可): `wg_public_hostname`, `wg_port` (**MAP-E 割当ポート範囲内であること**), `cf_zone_id`, `cf_record_id`, `cf_record_id_v6`
- **`group_vars/all/vault.yml`** (ansible-vault で暗号化): `vault_wg_password`, `vault_cf_tunnel_token`, `vault_cf_ddns_token` (`vault_` prefix で定義 → vars.yml が `wg_password: "{{ vault_wg_password }}"` の形で bridge する)

`vault.yml` の雛形は `group_vars/all/vault.yml.example` を参照。管理 UI のホスト名はリポジトリ変数ではなく、Cloudflare ダッシュボードの Public Hostname 側で設定する (apex 直下 1 ラベル、例 `wg-admin.yuseiito.com`)。

## Bootstrap (Proxmox host 上で一度だけ)

```bash
pveam update
pveam download local debian-13-standard
./scripts/pct-create.sh
```

`pct-create.sh` は冪等。CT 200 が既にあれば features (`nesting=1,keyctl=1`) の整合性を確認し補修、`/dev/net/tun` のマウント設定が欠けていれば追記し、停止していれば start する。`unprivileged: 1` が崩れていた場合は明示的に fail する (作成後変更不可なので operator 判断が必要)。

環境変数で上書き可能:

- `SSH_KEYS=/path/to/keys` … 公開鍵ファイル (デフォルト `~/.ssh/authorized_keys`)
- `CT_IP=192.168.x.y/24` / `CT_GW=192.168.x.1` … CT の静的 IP / デフォルトゲートウェイ (デフォルト `192.168.19.2/24` / `192.168.19.1`)。`inventory.yml` の `ansible_host` と RTX830 の `nat descriptor masquerade static` の宛先もこの IP に揃えること

## Deploy (ワークステーションから)

1. このリポジトリをクローン
2. `.vault_pass` ファイルを作成し、ansible-vault のパスワードを保存
    (こちらのパスワードはBitwarden等に安全に保管し、commitしないこと)
3. ansible vaultで必要な変数を定義
- `group_vars/all/vault.yml` に暗号化して保存する
- `uv ansible-vault edit group_vars/all/vault.yml` で編集できる
- `group_vars/all/vault.yml`の形式は `group_vars/all/vault.yml.example` にある
4. 以下を実行
```bash
uv sync
uv run ansible-galaxy collection install -r requirements.yml
uv run ansible-playbook -i inventory.yml playbook.yml
```

## 運用上の注意

`docker compose` の `restart: unless-stopped` は exit でのみ反応し、healthcheck 失敗 (= WG IF が落ちた等) では再起動しない。Ansible deploy 後の runtime 障害は `docker ps --filter health=unhealthy` を定期チェックするか、外部監視と接続させる必要がある。詳細は CLAUDE.md "ランタイム監視" を参照。

## RTX830 設定例

家庭ルーターが Yamaha RTX830 + MAP-E の場合. 環境依存値は適宜読み替えること:

- `2400:xxxx:xxxx:xxxx::yyyy` … LXC の IPv6 GUA (`ip -6 addr` で確認)
- `192.168.19.2` … LXC の LAN 内 IPv4
- `1953` … `wg_port` (下記の割当ポートから選定)
- NAT ディスクリプタ番号 `20000` / トンネル番号 `1` … `show nat descriptor address` で確認
- `ipv6 lan2 secure filter in` / `ip tunnel secure filter in` の既存番号列 … `show config | grep "secure filter in"` で確認し、**末尾の reject の前に新規 pass を足す**

```
# 0. MAP-E 割当ポートを確認し、その範囲内から wg_port を選ぶ. ここでは65533を選定
show nat descriptor address

# 1. IPv6 着信を許可 (WAN=lan2 の secure filter in に pass を先頭追加。out/dynamic は触らない)
ipv6 filter 101010 pass * 2400:xxxx:xxxx:xxxx::yyyy udp * 65533
ipv6 lan2 secure filter in 101010 101000 101001 101002 101003

# 2. IPv4 着信: MAP-E 割当ポートの静的 NAPT
nat descriptor masquerade static 20000 1 192.168.19.2 udp 65533

# 3. IPv4 着信: トンネルの secure filter in にも pass を追加 (静的 NAT だけでは
#    トンネルの着信フィルタで落ちる)。tunnel コンテキストに入って実行する
ip filter 400100 pass * * udp * 65533
tunnel select 1
ip tunnel secure filter in 400100 400003 400020 400021 400022 400023 400024 400025 400030 400032 200099
tunnel select none

# 4. 保存
save
```
