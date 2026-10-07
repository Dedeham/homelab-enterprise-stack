# Proxmox Initial Setup: Manual Step-by-Step Guide

This guide walks through the Proxmox base setup step by step. Going through this manually is a good way to learn exactly what's happening under the hood of the Proxmox server.

Run these commands from the Proxmox Shell: log into the Proxmox Web UI, select the node on the left, and click **>_ Shell** in the top right.

## Step 1: Fix Package Repositories

**What happens here?** By default, Proxmox is configured to use the "Enterprise" repository, which requires a paid subscription key. Without a key, attempting to update the system results in `401 Unauthorized` errors. The enterprise repo is disabled here, and the free, community-maintained "no-subscription" repo is enabled.

**Action:**

1. Disable the Enterprise repo:

```bash
nano /etc/apt/sources.list.d/pve-enterprise.list
```

Add a `#` to the beginning of the `deb` line to comment it out, then save (Ctrl+O, Enter, Ctrl+X).

2. Disable the Ceph enterprise repo (unused here):

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

```bash
apt update
```

Success: the command completes without any "Unauthorized" or "Failed to fetch" errors related to enterprise repositories.

## Step 2: Update System And Install Tools

**What happens here?** With repositories corrected, the base system is updated to the latest versions, along with crucial administrative tools (`htop` for monitoring, `smartmontools` for disk health, `tmux` to keep shell sessions alive).

**Action:**

```bash
apt full-upgrade -y
apt install -y htop iotop tmux smartmontools nvme-cli lm-sensors qrencode net-tools curl wget
```

**How to verify:**

```bash
htop --version
```

Success: version information for `htop` prints to the console.

## Step 3: Enable IOMMU (For HDD Passthrough)

**What happens here?** IOMMU (Intel VT-d) lets Proxmox hand over raw, direct hardware control of the HDDs to the TrueNAS VM. TrueNAS uses ZFS, which requires direct disk access to ensure data integrity. The Linux kernel needs IOMMU enabled during boot via the GRUB bootloader.

**Action:**

1. Edit the GRUB configuration:

```bash
nano /etc/default/grub
```

Find the line starting with `GRUB_CMDLINE_LINUX_DEFAULT` and change it to:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

2. Apply the GRUB changes:

```bash
update-grub
```

3. Load the kernel modules needed for device passthrough:

```bash
nano /etc/modules-load.d/vfio.conf
```

Add these lines:

```text
vfio
vfio_iommu_type1
vfio_pci
```

**How to verify:** this requires a reboot to take effect — don't reboot yet, finish the rest of the steps first. After rebooting at the very end:

```bash
dmesg | grep -e DMAR -e IOMMU
```

Success: output includes `DMAR: IOMMU enabled`.

## Step 4: Set Up LVM-Thin Pool (512 GB SSD)

**What happens here?** The secondary 512 GB SSD is formatted so Proxmox can use it for VM disks, using "LVM-Thin" — a storage type that supports thin provisioning (VM disks only consume as much real space as the data inside them, rather than reserving the full size instantly).

**Action:**

1. Find the 512 GB SSD's device name:

```bash
lsblk
```

Look for the disk that is roughly ~476G in size. The examples below assume `sdb` (it could be `sdc` or `nvme0n1` — adjust accordingly).

2. Wipe and prepare the drive:

```bash
pvcreate /dev/sdb
vgcreate ssd-fast /dev/sdb
lvcreate -l 95%FREE --type thin-pool -Zn -n data ssd-fast
```

3. Add it to the Proxmox UI: Datacenter → Storage → Add → LVM-Thin.
   - ID: `ssd-fast`
   - Volume Group: `ssd-fast`
   - Thin Pool: `data`
   - Content: Disk image, Container

**How to verify:**

```bash
vgs
```

Success: `ssd-fast` is listed alongside `pve`. In the Proxmox UI, `ssd-fast` appears under the node's storage in the left sidebar.

## Step 5: Create Isolated Network Bridge (vmbr1)

**What happens here?** The server already has `vmbr0`, connecting VMs directly to the home LAN. `vmbr1` is a separate virtual switch specifically for the isolated Hermes VM, using firewall (`iptables`) rules to allow Hermes outbound internet access while strictly blocking it from talking to the home network.

**Action:**

1. Enable IP Forwarding (required for internet routing):

```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

2. Edit the network interfaces file:

```bash
nano /etc/network/interfaces
```

Append this block to the end of the file:

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

```bash
systemctl restart networking
ip a show vmbr1
```

Success: `vmbr1` is listed with IP address `10.10.100.1/24`.

## Step 6: Reboot

All manual configuration is complete. Reboot the server so the IOMMU kernel changes take effect:

```bash
reboot
```

After the server comes back online, run `dmesg | grep -e DMAR -e IOMMU` to finally verify Step 3.
