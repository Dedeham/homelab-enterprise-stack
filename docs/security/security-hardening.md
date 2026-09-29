# Server Security Hardening Guide

This document operates as the central hub for securing your infrastructure components (Proxmox, TrueNAS, Ubuntu VMs, and network).

## Step-by-Step Hardening Guides

We have broken down the security protocols into specific, step-by-step implementation guides. Please follow them in order:

### 1. SSH Hardening
The very first step is to secure remote command-line access. Passwords can be brute-forced; SSH keys cannot.
➡️ **[Read the SSH Key Authentication Guide](ssh-key-authentication-guide.md)**

### 2. Proxmox Firewall Restrictions
Enable the Proxmox firewall to lock down the Datacenter and individual Node, preventing external traffic from reaching the management interfaces. Use `192.168.1.0/24` for local LAN access and `100.64.0.0/10` for Tailscale management access.
➡️ See the firewall section in the [Proxmox Initial Setup Guide](../os-and-virtualization/proxmox-manual-initial-setup.md)

### 3. TrueNAS Security
Prevent unauthorized access to your file shares and storage management. Never expose TrueNAS to the internet.
➡️ **[Read the TrueNAS Hardening Guide](truenas-hardening-guide.md)**

### 4. Docker & Ubuntu Server Security
For the VM hosting your outward-facing services (Nextcloud, Jellyfin), you must implement reverse proxies and intrusion prevention.
➡️ **[Read the Ubuntu Docker & Security Setup Guide](../os-and-virtualization/ubuntu-docker-security-setup.md)**
