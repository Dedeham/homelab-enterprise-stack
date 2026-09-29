# TrueNAS Security Hardening Guide

While TrueNAS is secure out of the box, exposing it on your local network still requires basic hardening. This guide ensures your TrueNAS installation is locked down securely.

## 1. Do Not Expose TrueNAS to the Internet
**Rule absolute:** Never forward ports 80 or 443 from your router directly to the TrueNAS management UI. Administrative access should always remain strictly local or through a VPN (like WireGuard/Tailscale).

## 2. Bind the Web Interface to a Specific IP
By default, TrueNAS listens on `0.0.0.0` (all network interfaces). You should lock this down to your trusted internal IP subnet.

1. Go to **Network** -> **Global Configuration** -> **Settings**.
2. Find the **WebGUI IPv4 Address** setting.
3. Change it from `0.0.0.0` to the specific static IP address assigned to TrueNAS (e.g., `192.168.1.10`).
4. Save and Test changes.

## 3. Disable HTTP (Force HTTPS)
TrueNAS should only be accessed via secure HTTPS.
1. Go to **System** -> **General** -> **GUI**.
2. Check the box for **WebGUI HTTP -> HTTPS Redirect**.
3. Save changes.

## 4. Enable Two-Factor Authentication (2FA/TOTP)
Protect the management login with an authenticator app (like Aegis, Authy, or Google Authenticator).

1. Go to **System Settings** -> **General** (or **System** -> **2FA**).
2. Click **Two-Factor Authentication**.
3. Scan the QR code with your authenticator mobile app.
4. Input the code to verify.
5. Save. *Ensure you download or write down the backup recovery codes!*

## 5. SSH Access Restrictions
If you need SSH access to TrueNAS, secure it similarly to Proxmox.

1. Go to **System Settings** -> **Services**.
2. Find **SSH** and click the pencil icon (Configure).
3. **Uncheck** `Log in as Root with Password`.
4. Ensure `Allow Password Authentication` is unchecked (once you have SSH keys set up).
5. Add your Public SSH Key to the `root` user or admin user via **Credentials** -> **Local Users** -> Edit User -> paste key in the `SSH Public Key` field.
6. Enable the SSH service and set it to "Start Automatically".

## 6. Disable Unused Services
Running unused services provides unnecessary attack vectors.
1. Go to **System Settings** -> **Services**.
2. Disable services you don't use (e.g., FTP, NFS, WebDAV, SNMP) by turning them off and disabling "Start Automatically".
3. Only leave essential services running, such as **SMB** for typical Windows file shares, or **S.M.A.R.T.** for drive health monitoring.

## 7. Setup Regular Smart Tests and Alerts
Security also encompasses data integrity.
1. Go to **Storage** -> **Disks**.
2. Create standard short (daily) and long (weekly) S.M.A.R.T. tests.
3. Go to **System Settings** -> **Alert Services** and ensure you have an email address configured so TrueNAS alerts you immediately if a security event or drive failure occurs.

## 8. Ransomware Mitigation via ZFS Snapshots
Since SMB/NFS shares can be targeted by ransomware from infected client machines, ZFS snapshots act as your ultimate fail-safe.
1. Go to **Data Protection** -> **Periodic Snapshot Tasks**.
2. Set up automated schedules: e.g., hourly snapshots kept for 24 hours, and daily snapshots kept for 2-4 weeks.
3. Because ZFS snapshots are read-only at the file system level, ransomware on a client machine cannot encrypt or delete them.

## 9. Transition to Admin User (No Root UI Login)
Modern TrueNAS versions (like TrueNAS SCALE) deprecate using `root` for Web UI logins.
1. Ensure your system is set up to use the `admin` user for GUI access.
2. Go to **Credentials** -> **Local Users** and ensure `root` password login is disabled for the GUI.
3. Only use `su` or `sudo` from an SSH session if root-level access is required.

## 10. Implement a Dedicated Management VLAN
Keep the management UI entirely off your main user network.
1. Following your isolated VLAN setup, place TrueNAS's management WebGUI onto your restricted network (e.g., Management VLAN).
2. Ensure firewall rules allow only specific admin devices (or your VPN/Tailscale subnet) to reach the TrueNAS management IP.

## 11. API Key Security & Centralized Logging
- **API Keys**: If you integrate TrueNAS with external monitoring (like Homepage or Promtail/Grafana), use API keys instead of passwords. Bind API keys to limited-permission roles if possible, and rotate them yearly.
- **Syslog**: Go to **System Settings** -> **Advanced** -> **Syslog** and forward your TrueNAS logs to your centralized logging stack. If an attacker gains access, they often wipe local logs—remote syslogging prevents this.
