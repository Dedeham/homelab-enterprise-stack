# Hermes

Hermes ([Hermes Agent](https://github.com/NousResearch/hermes-agent)) is an AI agent gateway (Telegram/Discord/etc.) that runs on its own network-isolated Proxmox VM, kept deliberately separate from the general Docker VM (Nextcloud/Jellyfin/ARR) and TrueNAS.

## Isolation Architecture

```text
Layer 1: Proxmox VM on vmbr1     -> isolates Hermes from TrueNAS, Docker VM, LAN
Layer 2: Hermes IN Docker        -> (if the Docker deployment mode is used) isolates the agent from the VM host
Layer 3: (optional) terminal.backend: docker -> extra command sandbox inside the container
```

| Setting | Value |
|---|---|
| VM name / ID | `Hermes`, VM `120` |
| OS | Debian 12 |
| Network | `vmbr1` (isolated bridge, never `vmbr0`/LAN) |
| CPU / RAM | 1-2 cores / 2-3 GB |
| Boot order | 3 (after TrueNAS at 1, Docker VM at 2) |

`vmbr1` puts the VM on an isolated network with no route to TrueNAS, the Docker VM, or the rest of the LAN. Outbound internet access works; inbound LAN access does not. Management happens through the Proxmox console or an SSH jump through Proxmox, not directly from the LAN.

Two deployment modes exist for running Hermes itself:

| Mode | Description | Used for |
|---|---|---|
| Hermes IN Docker | The whole agent (gateway, CLI, memory, skills) runs inside the official `nousresearch/hermes-agent` container, with `~/.hermes` bind-mounted to `/opt/data` and s6 supervision for auto-restart. | Nous Research's recommended production/always-on path. |
| Native install + Docker terminal backend | Hermes runs natively on the VM via `curl \| bash` and a systemd `hermes-gateway` service; only shell commands execute inside a sandboxed Docker container (`terminal.backend: docker`). | First-time setup/debugging, or a simpler ongoing operational model once working. |

Running Hermes on the Docker VM (`vmbr0`) is explicitly avoided, since that would give the agent LAN access to TrueNAS, Nextcloud, and Vaultwarden. Running multiple Hermes profiles in one container, or running native with no Docker sandbox at all, are both avoided for this homelab's current simple single-instance setup.

Approvals are configured conservatively: `approvals.mode: manual`, a 60s timeout, and `cron_mode: deny` (so cron-triggered actions cannot silently approve themselves).

## Dashboard Access

Hermes currently runs natively on the isolated Hermes VM (not in Docker).

| Component | Address |
|---|---|
| Proxmox | `192.168.1.2` |
| Hermes VM | `10.10.100.3` |
| Dashboard port | `9119` |

The web dashboard is bound only to `127.0.0.1:9119` on the Hermes VM — it is never exposed on `0.0.0.0`, the LAN, or through Cloudflare Tunnel. The only access path is an SSH tunnel from a management workstation through the Proxmox host as a jump host into the Hermes VM:

```text
ssh -N -J <proxmox-user>@192.168.1.2 -L 9119:127.0.0.1:9119 <hermes-user>@10.10.100.3
```

Once the tunnel is open, the dashboard is reached at `http://127.0.0.1:9119/` on the management workstation. `HERMES_DASHBOARD_INSECURE=1` is never set, since it would expose API keys and session data without authentication.

A `hermes-dashboard` systemd user service can keep the dashboard process running persistently on the Hermes VM so only the SSH tunnel step is needed for future access.

Note: the VM's provisioning documentation (above) describes a Proxmox build with address `10.10.100.2`; the dashboard-access configuration documents the VM's current operational address as `10.10.100.3`. Both values exist in the source material for this homelab and should be reconciled against the live environment rather than assumed.

## Backups

All Hermes state lives under `~/.hermes/` on the VM (`.env` with API keys, `config.yaml`, `sessions/`, `memories/`, `skills/`, and — for the Docker deployment — `logs/`). This is backed up with a weekly tarball of `~/.hermes`, or by snapshotting the whole VM in Proxmox. TrueNAS NFS is never mounted on the Hermes VM.
