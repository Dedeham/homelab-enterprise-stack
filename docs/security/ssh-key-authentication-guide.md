# Restricting SSH to Keys Only

This guide details how to secure your server's SSH access by disabling password logins and relying exclusively on cryptographic SSH keys. Password logins are vulnerable to brute-force attacks, whereas SSH keys are virtually uncrackable.

**Note:** Perform these steps on your Proxmox server, TrueNAS (if using SSH), and Ubuntu Docker server.

## Step 1: Generate an SSH Key Pair on your Local PC

If you already have an SSH key, skip this step.

1. Open a terminal or PowerShell on your local Windows PC.
2. Run the key generation command:
   ```bash
   ssh-keygen -t ed25519 -C "admin@home-pc"
   ```
   *(ed25519 is the modern, highly secure standard)*
3. Follow the prompts. It will save the key to `C:\Users\YourUser\.ssh\id_ed25519`.
4. Add a strong passphrase when prompted for extra security.

## Step 2: Copy the Public Key to the Server

You need to put your "Public" key onto the server so the server recognizes your PC.

**On Windows (PowerShell):**
1. Read your public key:
   ```powershell
   Get-Content ~/.ssh/id_ed25519.pub
   ```
2. Copy the output text.
3. SSH into your server the old way (with password):
   ```bash
   ssh root@192.168.1.X
   ```
4. Create the SSH folder and file, and paste your key in:
   ```bash
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   nano ~/.ssh/authorized_keys
   ```
5. Paste your public key text into the editor. Press `Ctrl+O`, `Enter`, and `Ctrl+X` to save and exit.
6. Set correct permissions:
   ```bash
   chmod 600 ~/.ssh/authorized_keys
   ```

*Alternative (if using Git Bash on Windows or Linux/Mac):*
Run `ssh-copy-id root@192.168.1.X` to do this automatically.

## Step 3: Test Key Authentication

**CRITICAL:** Before proceeding to Step 4, open a **brand new** terminal window and try to SSH into the server:
```bash
ssh root@192.168.1.X
```
It should log you in immediately (or ask for your key passphrase) without asking for the server's password. If this works, proceed to Step 4 safely.

## Step 4: Disable Password Authentication

Now that keys work, we disable passwords completely in the SSH configuration.

1. On the server, open the SSH configuration file:
   ```bash
   nano /etc/ssh/sshd_config
   ```
2. Find the line that says `PasswordAuthentication`. Make sure it is uncommented (no `#` at the start) and set to `no`:
   ```text
   PasswordAuthentication no
   ```
3. Find the line that says `PermitRootLogin`. Set it to `prohibit-password`. This allows root to log in with keys, but blocks root passwords:
   ```text
   PermitRootLogin prohibit-password
   ```
4. Find the line `PubkeyAuthentication` and ensure it is set to `yes`.
5. Save the file (`Ctrl+O`, `Enter`, `Ctrl+X`).

## Step 5: Restart the SSH Service

Apply the changes by restarting the SSH daemon:
```bash
systemctl restart sshd
```

Your server is now protected against password-based brute force attacks!
