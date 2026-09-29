# 🛠️ Proxmox Initial Setup: Manual Step-by-Step Guide

This guide walks through the Proxmox base setup step by step. Going through this manually is a great way to learn exactly what is happening under the hood of your Proxmox server.

You will need to run these commands from the Proxmox Shell. You can access it by logging into the Proxmox Web UI, selecting your node on the left, and clicking **>_ Shell** in the top right.

---

## Step 1: Fix Package Repositories

**What happens here?**
By default, Proxmox is configured to use the "Enterprise" repository, which requires a paid subscription key. Without a key, attempting to update your system will result in `401 Unauthorized` errors. We will disable the enterprise repo and enable the free, community-maintained "no-subscription" repo.

**Action:**
1. Disable the Enterprise repo:
```bash
nano /etc/apt/sources.list.d/pve-enterprise.list
```
Add a `#` to the beginning of the `deb` line to comment it out, then save (Ctrl+O, Enter, Ctrl+X).

2. Disable the Ceph enterprise repo (we don't use Ceph):
```bash
nano /etc/apt/sources.list.d/ceph.list
```
Comment out the `deb` line as well.

3. Add the no-subscription repo:
```bash
nano /etc/apt/sources.list
```
Add this line to the bottom of the file:
```text
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
```

**How to verify:**
Run the update command:
```bash
apt update
```
*Success:* The command completes without any "Unauthorized" or "Failed to fetch" errors related to enterprise repositories.

---

## Step 2: Update System and Install Tools

**What happens here?**
Now that our repositories are correct, we will update the base system to the latest versions. We will also install some crucial administrative tools (like `htop` for monitoring, `smartmontools` for disk health, and `tmux` to keep our shell sessions alive).

**Action:**
```bash
apt full-upgrade -y
apt install -y htop iotop tmux smartmontools nvme-cli lm-sensors qrencode net-tools curl wget
```

**How to verify:**
Ensure one of the installed tools runs successfully:
```bash
htop --version
```
*Success:* You should see the version information for `htop` printed to the console.

---

## Step 3: Enable IOMMU (For HDD Passthrough)

**What happens here?**
IOMMU (Intel VT-d) allows Proxmox to hand over raw, direct hardware control of your HDDs to the TrueNAS VM. TrueNAS uses ZFS, which requires direct disk access to ensure data integrity. We have to tell the Linux kernel to enable IOMMU during the boot process via the GRUB bootloader.

**Action:**
1. Edit the GRUB configuration:
```bash
nano /etc/default/grub
```
Find the line that starts with `GRUB_CMDLINE_LINUX_DEFAULT`. Change it to look exactly like this:
```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

2. Apply the GRUB changes:
```bash
update-grub
```

3. Load the necessary kernel modules for device passthrough:
```bash
nano /etc/modules-load.d/vfio.conf
```
Add these lines to the file:
```text
vfio
vfio_iommu_type1
vfio_pci
```

**How to verify:**
This requires a reboot to take effect. *Do not reboot yet!* Finish the rest of the steps first. After you reboot at the very end, run:
```bash
dmesg | grep -e DMAR -e IOMMU
```
*Success:* You should see lines in the output saying `DMAR: IOMMU enabled`.

---

## Step 4: Setup LVM-Thin Pool (512 GB SSD)

**What happens here?**
We need to format your secondary 512 GB SSD so Proxmox can use it for VM disks. We use "LVM-Thin", which is a storage type that supports "thin provisioning" (VM disks only consume as much real space as the data inside them, rather than reserving the full size instantly).

**Action:**
1. Find your 512 GB SSD's device name:
```bash
lsblk
```
Look for the disk that is roughly ~476G in size (this will be your 512 GB drive). Let's assume it is `sdb` (it could be `sdc` or `nvme0n1`, replace `sdb` below accordingly).

2. Wipe and prepare the drive:
```bash
pvcreate /dev/sdb
vgcreate ssd-fast /dev/sdb
lvcreate -l 95%FREE --type thin-pool -Zn -n data ssd-fast
```

3. Finally, add it to the Proxmox UI:
Go to **Datacenter -> Storage -> Add -> LVM-Thin**.
- **ID:** `ssd-fast`
- **Volume Group:** `ssd-fast`
- **Thin Pool:** `data`
- **Content:** Disk image, Container

**How to verify:**
Run the following command to check your volume groups:
```bash
vgs
```
*Success:* You will see `ssd-fast` listed in the output alongside `pve`. In the Proxmox UI, you will now see `ssd-fast` appear under your node's storage on the left sidebar.

---

## Step 5: Create Isolated Network Bridge (vmbr1)

**What happens here?**
Your server already has `vmbr0`, which connects your VMs directly to your home LAN. We need to create `vmbr1`, a separate virtual switch specifically for your isolated Hermes VM. We use firewall (`iptables`) rules to allow Hermes to reach the internet, but strictly block it from talking to your home network.

**Action:**
1. Enable IP Forwarding (required for internet routing):
```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

2. Edit your network interfaces file:
```bash
nano /etc/network/interfaces
```
Append this entire block to the very end of the file:
```text
auto vmbr1
iface vmbr1 inet static
    address  10.10.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # NAT: allow internet access
    post-up   iptables -t nat -A POSTROUTING -s '10.10.100.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.100.0/24' -o vmbr0 -j MASQUERADE
    # BLOCK: prevent access to main LAN
    post-up   iptables -I FORWARD -s '10.10.100.0/24' -d '192.168.1.0/24' -j DROP
    post-down iptables -D FORWARD -s '10.10.100.0/24' -d '192.168.1.0/24' -j DROP
    # BLOCK: prevent inter-VM communication
    post-up   iptables -I FORWARD -i vmbr1 -o vmbr1 -j DROP
    post-down iptables -D FORWARD -i vmbr1 -o vmbr1 -j DROP
```

**How to verify:**
Run the following to restart the networking service and apply the changes:
```bash
systemctl restart networking
```
Then, check if the bridge is up:
```bash
ip a show vmbr1
```
*Success:* You should see `vmbr1` listed with the IP address `10.10.100.1/24`. 

---

## Step 6: Reboot!

You have completed all the manual configurations! Reboot the server so the IOMMU kernel changes take effect.

```bash
reboot
```

After the server comes back online, don't forget to run `dmesg | grep -e DMAR -e IOMMU` to finally verify Step 3.
