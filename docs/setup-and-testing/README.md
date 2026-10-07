# Setup and Testing

Step-by-step setup, configuration, and test procedures. For a description of what is deployed, see [docs/](../README.md).

## Suggested Order

1. [Proxmox initial setup](proxmox-initial-setup.md)
2. [TrueNAS storage setup](truenas-storage-setup.md)
3. [TrueNAS hardening](security/truenas-hardening.md)
4. [Docker VM setup and security](ubuntu-docker-security-setup.md)
5. [Backup and monitoring setup](monitoring-and-updates.md)
6. Service setup, see [services](services/)
7. [Internet exposure](networking/cloudflare-tunnel-public-access.md), only after the above is working locally

## Contents

| Area | Procedures |
|---|---|
| Base platform | [Proxmox](proxmox-initial-setup.md), [TrueNAS storage](truenas-storage-setup.md), [Docker VM](ubuntu-docker-security-setup.md) |
| Networking | [SSL/TLS with Traefik and Cloudflare](networking/ssl-traefik-cloudflare.md), [Cloudflare Tunnel public access](networking/cloudflare-tunnel-public-access.md) |
| Security | [SSH keys](security/ssh-key-authentication.md), [TrueNAS hardening](security/truenas-hardening.md), [Authelia and CrowdSec](security/authelia-crowdsec-setup.md), [CrowdSec for all services](security/crowdsec-all-services.md), [Malware scanning](security/malware-scanning.md), [Pentest and honeypot](security/pentest-and-honeypot-guide.md) |
| Services | [services/](services/) |
| Operations | [Monitoring and updates](monitoring-and-updates.md), [Disaster recovery](disaster-recovery.md) |
