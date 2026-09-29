# Firewall Configuration

> This directory is intentionally empty.
>
> Firewall rules are managed in two places:
>
> 1. **Proxmox host** — iptables rules for Hermes VM isolation
>    (see `docs/os-and-virtualization/proxmox-manual-initial-setup.md`, stored in `/etc/network/interfaces`)
>
> 2. **CrowdSec** — Dynamic IP blocking based on intrusion detection
>    (configured in `configs/docker/crowdsec/`)
>
> 3. **Traefik** — IP whitelisting via middleware
>    (configured in `configs/docker/traefik/dynamic/middlewares.yml`)
>
> This directory exists as a placeholder for any future host-level firewall
> rules (e.g., nftables configs, ufw rules for the Docker VM).
>
> If you don't plan to use it, you can safely delete this directory.
