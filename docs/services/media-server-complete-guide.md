# Media Server Guide

This file used to contain a large standalone media-server walkthrough. It has been compressed because it duplicated the current ARR guide and still used older assumptions.

Use these current guides instead:

1. [ARR Stack Local-First Homelab Setup](arr-stack-homelab-fit-review-and-setup.md)
2. [ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md)
3. [ARR Stack Gluetun VPN Gateway Guide](arr-stack-gluetun-vpn-gateway-guide.md), later if you want a dedicated VPN gateway
4. [Media Automation With Debrid](media-automation-debrid.md), only if you intentionally want a debrid workflow

Current rules:

- Docker services run on the Ubuntu Docker VM, not on TrueNAS.
- Storage comes from TrueNAS over NFS.
- ARR media paths use `/mnt/media/data`.
- Internet exposure comes last.
