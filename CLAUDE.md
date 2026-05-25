# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Homelab WireGuard VPN server IaC. The VPN runs as an unprivileged LXC container on Proxmox VE, managed via Ansible from a workstation.

## Topology

Three concerns live side-by-side and intentionally have different trust boundaries:

1. **WireGuard data plane (`roles/wg_easy` — `wg-easy` container)** — UDP/51820 is exposed directly to the internet via the home router. This path must NOT depend on Cloudflare; if Cloudflare is down, the VPN itself keeps working.
2. **wg-easy admin UI** — port 51821 is deliberately NOT published to the host. Access is only via the `cloudflared` sidecar container (same compose file) which fronts it with a Cloudflare Tunnel. Authentication is enforced by Cloudflare Access at the edge, so the UI is never reachable from the public internet directly.
3. **DDNS (`roles/ddns`)** — a systemd timer (`cf-ddns.timer`, every 5 min) calls the Cloudflare API to point the VPN's A and AAAA records at the current public IPs (fetched from `api.ipify.org` and `api6.ipify.org`). Both records are `proxied:false` because WireGuard is UDP and must hit the origin directly.

When changing things, keep these boundaries intact: do not route 51820 through Cloudflare, do not publish 51821 to the host, and do not proxy the VPN DNS record.

## Layout

- `scripts/pct-create.sh` — run on the Proxmox host (not via Ansible) to create LXC 200 `grumpy`. Enables `nesting=1,keyctl=1` and binds `/dev/net/tun` — both required for Docker + WireGuard inside an unprivileged container.
- `inventory.yml` — single host `grumpy` at `192.168.19.2`.
- `roles/{base,docker,wg_easy,ddns}` — applied in that logical order. `base` sets timezone/UFW/unattended-upgrades; `docker` installs Docker CE; `wg_easy` deploys the compose stack; `ddns` installs the timer.
- `roles/wg_easy/templates/` — `docker-compose.yml.j2` and `cloudflared-config.yml.j2` are rendered with vars; `tunnel.json` (Cloudflare Tunnel credentials) is copied from the controller via `tunnel_cred_file`.

## Required variables (vault)

The roles reference these without defaults — they must be supplied via group_vars/host_vars/vault:

- `wg_easy`: `wg_public_hostname` (WG endpoint clients hit), `wg_admin_hostname` (Cloudflare Tunnel ingress hostname for the admin UI — intentionally different from `wg_public_hostname` because the UI is fronted by Access while the VPN endpoint is direct), `wg_password_hash` (bcrypt), `tunnel_id`, `tunnel_cred_file` (path on controller).
- `ddns`: `cf_ddns_token`, `cf_zone_id`, `cf_record_id` (A record ID), `cf_record_id_v6` (AAAA record ID), plus `wg_public_hostname` (shared with `wg-easy` — the hostname both records resolve to).

Optional:

- `cf_ddns_healthcheck_url`: a healthchecks.io (or compatible) base URL. When set, `ddns.sh` pings `<url>/0` on success and `<url>/1` on failure so silent DDNS breakage (expired token, drifted record ID) is alerted within ~10 min instead of being noticed only when the home IP next changes. Leave undefined to disable.

## Network family policy

This VPN is **dual-stack by design**. A VPN that only carries IPv4 is actively bad for the privacy use case (public Wi-Fi, café, hotel): modern clients use Happy Eyeballs and prefer v6 when both are advertised, so v4-only would let v6 traffic exit straight out of the local ISP interface, defeating the point of being on the VPN at all. Closing that leak requires the data path, the firewall, the host forwarding state, and DNS to all carry v6.

Concrete consequences enforced in code:

- `WG_ALLOWED_IPS=0.0.0.0/0, ::/0` is distributed to clients so both families route into the tunnel.
- The wg-easy Docker bridge has `enable_ipv6: true` with a ULA `/64`; the container has the v6 forwarding sysctls enabled.
- UFW is built with `IPV6=yes`, and the UDP/51820 allow rule applies to both families.
- Host-side sysctl persistently enables `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding`.
- The DDNS script (`roles/ddns/templates/ddns.sh.j2`) maintains both A and AAAA records.

If you ever flip back, **all five** of the above need to move together — do not flip just one.

**MAP-E (IPv6 プラス) caveat:** the operator's home ISP is on MAP-E. v6 is delivered natively and is generally stable enough to publish in AAAA. v4 reachability uses a shared, port-restricted public IPv4 — UDP/51820 inbound on v4 may or may not work depending on the assigned port range; treat the v4 path as best-effort and assume real-world clients connect via v6.

## Host prerequisites

The Proxmox host must have the `wireguard` kernel module loaded (e.g. via `/etc/modules-load.d/wireguard.conf`) before the wg-easy container starts. The container is unprivileged so it cannot `modprobe` itself; this is why the compose file deliberately does not bind `/lib/modules` or grant `SYS_MODULE` — both would be no-ops here.

The home router must forward UDP/51820 to the LXC on **both** IPv4 (port-forward, subject to MAP-E port restrictions) and IPv6 (firewall pinhole to the LXC's GUA). Without the v6 pinhole, Happy Eyeballs will silently fall back to v4 every connect, which usually works but masks the real failure mode if v4 also breaks.

## Post-deploy manual UI setup

wg-easy v15 stores per-server WireGuard config in its own database — env vars only seed initial defaults. After the first `ansible-playbook` run, log into the admin UI (via the Cloudflare Tunnel hostname) and:

1. Enable IPv6 on the WireGuard server config.
2. Assign a ULA `/64` for client v6 addresses, disjoint from the Docker bridge subnet `fdcc:ad94:bacf:61a3::/64`. The prefix differs in the *first 64 bits*, so the 4th hextet must change — e.g. `fdcc:ad94:bacf:61a4::/64`. (Writing `fdcc:ad94:bacf:61a3:1::/64` does NOT create a disjoint prefix: bits after the first 64 are host bits and the resulting `/64` collides with the bridge.)
3. Verify the generated client config includes `Address` lines for both v4 and v6 and `AllowedIPs = 0.0.0.0/0, ::/0`.

This is a one-time setup per deployment; the wg-easy data volume persists it.

## Design principles

This is a personal homelab, so two forces pull against each other and both must be respected:

- **Security first.** Default-deny on UFW, unprivileged LXC, secrets only via Ansible Vault (never committed plaintext), admin UI never publicly reachable, WireGuard keys/bcrypt hashes treated as vault material. When a change weakens any of these, push back or call it out explicitly.
- **Low maintenance.** One person operates this. Prefer boring, upstream-default choices over clever ones; prefer a handful of well-named roles over many tiny ones; lean on `unattended-upgrades`, `restart: unless-stopped`, and systemd timers instead of building bespoke supervision. Don't add a knob unless it's actually needed — every variable is something future-you has to remember.

When the two conflict, security wins, but find the least-moving-parts way to achieve it.

## Ansible conventions

Ansible's recommended patterns shift between major versions (collections, FQCN, `ansible.builtin.*`, role argument specs, etc.). Before making non-trivial changes to roles or playbook structure, **consult the current upstream docs** (`context7` MCP for `ansible` and `ansible-collections/*`, or the official `docs.ansible.com` user guide) rather than relying on memorized patterns — what was idiomatic two years ago is often deprecated now. Specifically check current guidance on:

- FQCN for builtin modules (`ansible.builtin.apt` vs bare `apt`) — this repo currently mixes styles; new code should use FQCN.
- `apt_key` / `apt_repository` are deprecated in newer Ansible; the Docker role should migrate to the keyring + `deb [signed-by=...]` pattern when touched.
- Role layout (`meta/argument_specs.yml`, `defaults/main.yml`) for any variable that gains a sensible default.

Keep diffs minimal and don't refactor unrelated roles in passing — the maintenance budget is small.

## Common commands

```bash
# On the Proxmox host, one-time container creation:
pveam update && pveam download local debian-13-standard
bash scripts/pct-create.sh

# From the workstation (repo root):
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
```
