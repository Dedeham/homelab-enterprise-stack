# Server Security Hardening

This document describes the current security posture of the homelab's
infrastructure components: Proxmox, TrueNAS, the Ubuntu Docker VM, and the
network and application layers in front of them. For step-by-step setup and
testing procedures, see
[docs/setup-and-testing/security/](../setup-and-testing/security/).

## SSH Access

Remote command-line access to Proxmox, TrueNAS (where SSH is enabled), and
the Ubuntu Docker VM is key-only. Password authentication is disabled, so
brute-force attempts against SSH have nothing to guess. `PermitRootLogin` is
set to `prohibit-password`, so root can still log in with a key but never
with a password.

Setup steps: [ssh-key-authentication.md](../setup-and-testing/security/ssh-key-authentication.md).

## TrueNAS Hardening

TrueNAS is never exposed to the internet; administrative access is LAN-only
or through Tailscale. Current hardening measures:

- The WebGUI IPv4 address is bound to TrueNAS's static LAN IP rather than
  `0.0.0.0`.
- HTTP is redirected to HTTPS for the web UI.
- Two-factor authentication (TOTP) protects the management login.
- SSH on TrueNAS disallows root password login and password authentication;
  access uses an SSH public key on the admin/root user instead.
- Unused services (FTP, WebDAV, SNMP, and similar) are disabled and not set
  to start automatically. Only services actually in use (SMB, S.M.A.R.T.)
  remain enabled.
- Scheduled S.M.A.R.T. short/long tests run, with alert notifications
  configured so drive and security events are reported immediately.
- ZFS snapshots run on a periodic schedule (e.g. hourly kept 24h, daily kept
  2-4 weeks) as ransomware mitigation — since snapshots are read-only at the
  filesystem level, client-side ransomware cannot encrypt or delete them.
- GUI login uses the `admin` user rather than `root`, consistent with modern
  TrueNAS SCALE guidance; `su`/`sudo` from an SSH session is used instead of
  root GUI login when root-level access is required.
- The TrueNAS management UI sits on a dedicated/isolated subnet reachable
  only from admin devices or the Tailscale subnet.
- Integrations (e.g. Homepage, Promtail/Grafana) use scoped API keys rather
  than passwords, and TrueNAS syslog is forwarded to the centralized logging
  stack so an attacker can't erase local logs to cover their tracks.

Setup steps: [truenas-hardening.md](../setup-and-testing/security/truenas-hardening.md).

## Proxmox Firewall

The Proxmox firewall is enabled at the Datacenter and Node level, restricting
management interface access to the LAN (`192.168.1.0/24`) and the Tailscale
range (`100.64.0.0/10`). See
[../setup-and-testing/proxmox-initial-setup.md](../setup-and-testing/proxmox-initial-setup.md)
for the firewall rule details, and
[../networking/networking-plan.md](../networking/networking-plan.md) for the
broader network topology these rules sit inside.

## Docker VM / Reverse Proxy Layer

The VM hosting outward-facing services (Nextcloud, Jellyfin, and others) sits
behind Traefik as a reverse proxy, with intrusion prevention layered in front
of the services that need it. See
[../setup-and-testing/ubuntu-docker-security-setup.md](../setup-and-testing/ubuntu-docker-security-setup.md)
for the VM-level setup, and
[../networking/networking-plan.md](../networking/networking-plan.md) for how
Traefik, Cloudflare Tunnel, and Tailscale fit together.

### Authelia and CrowdSec

Before any service is moved behind a public Traefik route, two additional
layers sit in front of it:

- **Authelia** provides a login + 2FA (TOTP) gate for web apps that don't
  have strong built-in auth of their own (e.g. Grafana, Uptime Kuma). It is
  deliberately not placed in front of Jellyfin or Nextcloud by default,
  since both have their own account systems and non-browser clients that can
  break behind a generic forward-auth login.
- **CrowdSec** watches Traefik's access logs and blocks suspicious IPs via a
  bouncer. The current deployment applies CrowdSec globally through a Traefik
  plugin middleware on the `websecure` entrypoint, so every HTTPS router gets
  the protection automatically rather than needing a per-service label.
  CrowdSec only sees traffic that actually passes through Traefik — directly
  published container ports bypass it entirely, which is why those ports are
  never exposed beyond LAN/Tailscale. CrowdSec fails open: if the engine is
  down, Traefik keeps serving traffic rather than blocking everything.
  AppSec (request-body inspection) is intentionally left off so it doesn't
  interfere with Jellyfin/Emby streaming.

Setup steps: [authelia-crowdsec-setup.md](../setup-and-testing/security/authelia-crowdsec-setup.md)
and [crowdsec-all-services.md](../setup-and-testing/security/crowdsec-all-services.md).

## Downloaded Media Malware Scanning

Decision: a malware scanner is a useful additional layer for this stack, but
it is scoped to **newly completed downloads and their companion files**, not
a recurring full scan of the whole media library.

Reasoning for this stack (all Linux: Proxmox, TrueNAS, the Docker VM,
containers, and admin devices):

- Plain video files (MKV/MP4) don't execute native Linux code on their own.
  The bigger risk is ELF binaries, shell/Python/etc. scripts, AppImages,
  manipulated `.desktop` files, disk images, archives, and files with
  misleading extensions or an execute bit set.
- A signature-based scanner won't reliably catch future vulnerabilities in
  media parsers (FFmpeg, subtitle parsers); keeping those components updated
  matters more than scanning for that class of risk.
- The scanner earns its keep most clearly where raw downloads are reachable
  from Linux workstations, archives are auto-extracted, or admins manually
  inspect files.

Current/planned model:

- Download directories (`/mnt/media/data/torrents`, `/mnt/media/data/debrid`)
  are not exported as a user-facing share to Linux workstations.
- Jellyfin only ever mounts the finished media library, read-only.
- ClamAV runs against newly completed downloads only, not the full library,
  using `clamd` to keep the signature database resident in memory.
- File-type/extension checks and `ffprobe` validation (unprivileged, no
  write access, time-limited) run alongside ClamAV, since a scanner alone
  doesn't catch a renamed ELF binary or validate that a file is actually
  playable media.
- A quarantine path (`/mnt/media/data/quarantine`) holds flagged files;
  nothing is auto-deleted, and the quarantine path is never mounted into
  Jellyfin, Radarr, or Sonarr, nor exported to other systems.
- The rollout is staged: observe-and-alert first (no blocking), then a
  strict Download → Scan → Import gate later once the target downloader/ARR
  topology is finalized.
- `clamonacc` (fanotify-based on-access scanning) is intentionally not the
  starting point, since the media mounts are NFS + bind-mounted into
  containers and a blocking access scan could delay downloader/ARR imports.

Setup steps: [malware-scanning.md](../setup-and-testing/security/malware-scanning.md).

## Pentesting and Honeypot

The homelab is periodically tested against itself using a dedicated scanner
VM (never the Docker VM or Hermes), covering host/service discovery,
network segmentation (especially Hermes isolation and guest/IoT VLAN
boundaries), web application baselines (OWASP ZAP), and container image CVE
scanning (Trivy). Findings are confirmed, where risky, only against cloned,
isolated systems — never destructive testing on live systems.

An **OpenCanary** honeypot runs on its own small VM, disguised as a
NAS-like target with likely-attractive services (FTP, SSH, HTTP, Telnet,
MySQL, RDP, Redis, MongoDB). It is firewalled so inbound connections from
the LAN are allowed (to attract probes) but any outbound connection *from*
the canary toward Proxmox, TrueNAS, the Docker VM, or the Nextcloud VM is
blocked — a compromised honeypot should not be able to reach production
systems. Alerts are sent via webhook (e.g. to Discord) and logged locally.

An incident response plan exists for the case where the canary fires:
secure the alert evidence, contain the source, collect evidence from a known
clean admin device, determine scope, revoke credentials in a defined order,
rebuild from clean images rather than "cleaning" a compromised host, and
follow up with retests at 24 hours, 7 days, and 30 days.

Setup/testing procedure:
[pentest-and-honeypot-guide.md](../setup-and-testing/security/pentest-and-honeypot-guide.md).
