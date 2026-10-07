# Network Reference

This is the canonical IP reference for the homelab.

| Component | Address |
|---|---|
| Home LAN | `192.168.1.0/24` |
| Router / gateway | `192.168.1.1` |
| Proxmox | `192.168.1.2` |
| TrueNAS | `192.168.1.10` |
| Docker VM | `192.168.1.20` |
| Nextcloud VM | `192.168.1.30` |
| Isolated bridge | `10.10.100.0/24` |
| Isolated bridge gateway | `10.10.100.1` |
| Hermes VM | `10.10.100.2` |
| Tailscale CGNAT range | `100.64.0.0/10` |

Current rules in effect:

- `192.168.1.0/24` is the trusted LAN.
- `10.10.100.0/24` is reserved for the isolated bridge only.
- TrueNAS is storage only.
- Docker services run on `192.168.1.20`.
- The dedicated Nextcloud VM, where deployed for stronger isolation, runs on
  `192.168.1.30`; public `cloud.*` traffic still enters through Traefik on the
  Docker VM.
- Hermes does not mount or reach TrueNAS, Docker, or other LAN services.
