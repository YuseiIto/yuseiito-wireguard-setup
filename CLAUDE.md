# CLAUDE.md

## 目的

Homelab 用の WireGuard VPN サーバを Proxmox VE の unprivileged LXC コンテナとして構築する Ansible IaC。ワークステーションから Ansible で管理する。

## トポロジ

意図的に信頼境界の異なる 3 つの関心事が並んでいる:

1. **WireGuard データプレーン (`roles/wg_easy` — `wg-easy` コンテナ)** — WireGuard の UDP ポート (`wg_port`。MAP-E 割当ポート、現状 1953) を家庭ルーター経由で直接インターネットに晒す。この経路は **Cloudflare に依存させない**。Cloudflare が落ちても VPN 自体は動き続けること。
2. **wg-easy 管理 UI** — 51821 は意図的にホストへ publish しない。アクセスは同じ compose にある `cloudflared` サイドカー経由のみ。Cloudflare Tunnel が前段になり、認証は edge の Cloudflare Access で行うので、管理 UI が公開インターネットから直接到達することは無い。
3. **DDNS (`roles/ddns`)** — systemd timer (`cf-ddns.timer`、5 分毎) が Cloudflare API を叩き、VPN の A / AAAA レコードを現在の公開 IP (`api.ipify.org` / `api6.ipify.org` から取得) に向ける。WireGuard は UDP で origin に直接届く必要があるため、両レコードとも `proxied: false`。

変更時はこの境界を崩さないこと: WireGuard のポートを Cloudflare 経由にしない / 51821 をホストに publish しない / VPN の DNS レコードを proxied にしない。

## 構成

- `scripts/pct-create.sh` — Proxmox ホスト上で実行し、LXC 200 `grumpy` を作成する。`nesting=1,keyctl=1` を有効化し `/dev/net/tun` を bind する — どちらも unprivileged コンテナ内で Docker + WireGuard を動かすのに必要。
- `inventory.yml` — 単一ホスト `grumpy`、`192.168.19.2` (デフォルト。`CT_IP` env で `pct-create.sh` の作成 IP を上書き可。変える場合は `inventory.yml` と RTX830 NAPT static の宛先も揃える)。
- `roles/{base,docker,wg_easy,ddns}` — この論理順で適用。`base` はタイムゾーン/UFW/unattended-upgrades を設定、`docker` は Docker CE を入れ、`wg_easy` は compose スタックをデプロイ、`ddns` は systemd timer を導入する。
- `roles/wg_easy/templates/` — `docker-compose.yml.j2` を変数で render する。wg-easy (v15、`INIT_*` でシード) と、`cf_tunnel_token` で接続する `cloudflared` サイドカーが動く (remotely-managed トンネル。ingress は Cloudflare ダッシュボードで設定するので、ローカルの cloudflared config も credentials ファイルも持たない)。

## 必須変数

ロールはこれらをデフォルト無しで参照する。配置は秘密か否かで決める — `group_vars/all/vars.yml` (平文 commit 可) と `group_vars/all/vault.yml` (ansible-vault で暗号化) を使い分ける。

### `vars.yml` に置く (平文 commit 可)

- `wg_public_hostname` — クライアントが叩く WG エンドポイント。`wg_easy` (INIT_HOST) と `ddns` (A/AAAA レコード名) で共有
- `wg_port` — UDP 待受ポート。**MAP-E 割当ポート範囲内であること** (v4 着信のため)。v4/v6 で同一ポートを使う
- `cf_zone_id` — Cloudflare ゾーン ID
- `cf_record_id` — A レコード ID (v4)
- `cf_record_id_v6` — AAAA レコード ID (v6)

### `vault.yml` に置く (秘密)

vault.yml では `vault_<name>` の prefix で定義し、`vars.yml` 側で `<name>: "{{ vault_<name> }}"` の bridge を 1 行入れる (`wg_password` / `cf_tunnel_token` / `cf_ddns_token` は既にこの形)。bare 名で書くと `vars.yml` の参照が解決できず、テンプレートが空文字でレンダされる。

- `wg_password` (= `vault_wg_password`) — 管理 UI ログインの平文パスワード。wg-easy v15 は初回 boot で `INIT_PASSWORD` 経由でシードし内部で hash 保存する (v14 の `PASSWORD_HASH`/bcrypt env は廃止)
- `cf_tunnel_token` (= `vault_cf_tunnel_token`) — ダッシュボードで作った remotely-managed Cloudflare Tunnel の接続トークン
- `cf_ddns_token` (= `vault_cf_ddns_token`) — Cloudflare API トークン (Zone:DNS:Edit を対象ゾーンに限定して発行)

管理 UI の ingress ホスト名はリポジトリ変数ではなく、Cloudflare ダッシュボードの Public Hostname で設定する (apex 直下の 1 ラベル、例 `wg-admin.yuseiito.com`。無料の Universal SSL 証明書がカバーする範囲)。

任意:

- `cf_ddns_healthcheck_url`: healthchecks.io (or compatible) のベース URL。設定すると `ddns.sh` が成功時に `<url>/0`、失敗時に `<url>/1` を ping するので、DDNS のサイレント故障 (トークン失効、レコード ID ずれ等) を ~10 分以内にアラートできる (家の IP が次に変わって初めて気付く、という事故を防ぐ)。**`vars.yml` の bare 名と `vault.yml` の `vault_cf_ddns_healthcheck_url` の両方を有効化する必要がある** (片側だけだと bare 名が未定義のままで `default('')` で空に解決され ping が一度も発火しない)。定義しなければ無効。

## ネットワークファミリポリシ

この VPN は **設計上 dual-stack**。IPv4 だけ運ぶ VPN はプライバシ用途 (公衆 Wi-Fi、カフェ、ホテル) で実害がある: 最近のクライアントは Happy Eyeballs で v6 を優先するため、v4-only にすると v6 トラフィックがローカル ISP の interface から直接抜けていき、VPN を張った意味そのものが消える。このリークを塞ぐには、データ経路 / ファイアウォール / ホストの forwarding 状態 / DNS すべてが v6 を運ぶ必要がある。

コードで強制している具体的な帰結:

- `WG_ALLOWED_IPS=0.0.0.0/0, ::/0` をクライアントに配布し、両ファミリをトンネルへ流す。
- wg-easy の Docker bridge は `enable_ipv6: true` + ULA `/64`、コンテナの v6 forwarding sysctl を有効化。
- UFW は `IPV6=yes` でビルド、WireGuard UDP ポートの許可ルールは両ファミリに適用される。
- ホスト側 sysctl で `net.ipv4.ip_forward` と `net.ipv6.conf.all.forwarding` を永続的に有効化。
- DDNS スクリプト (`roles/ddns/templates/ddns.sh.j2`) は A / AAAA の両方を維持する。

## ホスト前提条件

Proxmox ホストは、wg-easy コンテナが起動する前に `wireguard` カーネルモジュールがロード済みであること (`/etc/modules-load.d/wireguard.conf` 等)。コンテナは unprivileged なので自分で `modprobe` できない — これが、compose ファイルが `/lib/modules` を bind せず `SYS_MODULE` も付与しない理由 (どちらもここでは no-op になる)。

家庭ルーターは WireGuard の UDP ポート (`wg_port`) を LXC に **両ファミリ** で通すこと:

- **IPv6** — ファイアウォール pinhole (`ipv6 ... secure filter in` に pass) を LXC の GUA 向けに開ける。NAT が無いので、クライアントは `wg_port` で GUA に直接到達する。
- **IPv4 (MAP-E)** — `wg_port` を LXC の LAN アドレス宛に転送する `nat descriptor masquerade static`、**加えて** トンネルの `ip tunnel secure filter in` に pass を追加 (静的 NAT は宛先を書き換えるだけで、トンネルの着信フィルタは依然として default-reject)。

## ランタイム監視

wg-easy compose の healthcheck (`wg show interfaces`) は **deploy gate 専用**。Docker の `restart: unless-stopped` は exit でのみ反応し、healthcheck 失敗では再起動しない:

- runtime で WG IF だけ落ちると、コンテナは `health=unhealthy` のまま走り続け Ansible deploy 完了後の障害検知は外部に委ねる。外形監視するなら `docker ps --filter health=unhealthy`、もしくは autoheal サイドカーを足す。
- wg-easy UI から peer を追加・編集する瞬間 wg-quick が IF を down/up するので healthcheck が一時的に unhealthy にフリップする (~90s 以内に self-recover)。アラートを組むなら "5 分以上連続で unhealthy" を条件にする。

## 設計原則

これは個人の homelab なので、相反する 2 つの力が働く。両方を尊重すること:

- **セキュリティ優先。** UFW は default-deny、LXC は unprivileged、秘密情報は Ansible Vault 経由のみ (平文を commit しない)、管理 UI は公開到達不可、WireGuard 鍵や bcrypt ハッシュは vault 扱い。これらを弱める変更があれば、押し返すか明示的に指摘すること。
- **低メンテ。** 1 人で運用している。賢い選択より退屈で upstream のデフォルトに寄せる、ロールは小さくたくさんではなく適度な数で名前が分かりやすい、独自の supervision を組まず `unattended-upgrades` / `restart: unless-stopped` / systemd timer に乗る。**本当に必要でない限り変数を増やさない** — 1 つ増やすたびに未来の自分が覚えておく必要が生まれる。

両者が衝突したらセキュリティが勝つが、可動部品が一番少ない方法でそれを達成する。

## Ansible のベストプラクティスに従うこと

ロールや playbook 構造に非自明な変更を入れる前に、**現行 upstream のドキュメント** を当たること (`ansible` および `ansible-collections/*` の `context7` MCP、もしくは公式 `docs.ansible.com` のユーザガイド) 

- builtin モジュールもベアの名前(`apt`) でなくFQCN (`ansible.builtin.apt` ) で書く
- `apt_key` / `apt_repository` は新しい Ansible で deprecated。Docker ロールを触る際に keyring + `deb [signed-by=...]` パターンへ移行する。
- ロールレイアウト (`meta/argument_specs.yml`、`defaults/main.yml`)。妥当なデフォルトを持てる変数があるとき。
