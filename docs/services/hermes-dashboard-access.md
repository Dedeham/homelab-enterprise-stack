# Hermes Dashboard Access

This homelab runs Hermes natively on the isolated Hermes VM, not in Docker.

Current addresses:

| Component | Address |
|---|---|
| Proxmox | `192.168.1.2` |
| Hermes VM | `10.10.100.3` |
| Hermes user | `alice` |
| Dashboard port | `9119` |

The dashboard must stay bound to localhost on the Hermes VM:

```text
127.0.0.1:9119
```

Do not expose it on `0.0.0.0`, Cloudflare Tunnel, or the LAN.

## Start The Dashboard

Run on the Hermes VM as `alice`:

```bash
set -a
. ~/.config/hermes/dashboard.env
set +a

hermes dashboard --host 127.0.0.1 --port 9119 --no-open
```

Leave this running unless `hermes-dashboard.service` has already been created.

Verify on the Hermes VM:

```bash
ss -ltnp | grep 9119
curl http://127.0.0.1:9119/
```

`curl -I` may return `405 Method Not Allowed`; that is okay because the dashboard expects `GET`, not `HEAD`.

## Open The SSH Tunnel

Run from Windows PowerShell:

```powershell
ssh -N -J root@192.168.1.2 -L 9119:127.0.0.1:9119 alice@10.10.100.3
```

After entering the passwords, the command appears to hang. That is normal. Keep the window open while using the dashboard.

Then open this in a browser:

```text
http://127.0.0.1:9119/
```

## Test The Tunnel

In a second PowerShell window:

```powershell
Test-NetConnection 127.0.0.1 -Port 9119
curl.exe -v http://127.0.0.1:9119/
```

Expected:

```text
TcpTestSucceeded : True
```

## If It Does Not Load

On the Hermes VM:

```bash
ss -ltnp | grep 9119
systemctl --user status hermes-gateway --no-pager
journalctl --user -u hermes-gateway -n 80 --no-pager
```

On Windows, close old tunnel windows with `Ctrl+C`, then check for old SSH tunnel processes:

```powershell
Get-CimInstance Win32_Process -Filter "name = 'ssh.exe'" | Select-Object ProcessId,CommandLine
```

Stop the wrong one if needed:

```powershell
Stop-Process -Id <PID>
```

Then reopen the tunnel with:

```powershell
ssh -N -J root@192.168.1.2 -L 9119:127.0.0.1:9119 alice@10.10.100.3
```

## Optional Persistent Dashboard Service

If the foreground dashboard test works, create a user service so it starts automatically:

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/hermes-dashboard.service <<'EOF'
[Unit]
Description=Hermes Web Dashboard
After=hermes-gateway.service
Wants=hermes-gateway.service

[Service]
Type=simple
WorkingDirectory=/home/alice/.hermes
EnvironmentFile=/home/alice/.config/hermes/dashboard.env
ExecStart=/home/alice/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now hermes-dashboard
systemctl --user status hermes-dashboard --no-pager
ss -ltnp | grep 9119
```

If the service is enabled, future access only needs the SSH tunnel command from Windows.
