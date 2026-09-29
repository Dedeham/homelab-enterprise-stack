# Jellyfin Intel iGPU Passthrough And Local Appdata Guide

Last updated: 2026-06-20

This guide records the working Intel HD Graphics P630 passthrough and Jellyfin
Quick Sync configuration for this homelab. It also moves Jellyfin's active
SQLite database and cache from TrueNAS NFS to a local virtual SSD while keeping
the media libraries on TrueNAS.

Use this guide after:

1. [Proxmox manual initial setup](../os-and-virtualization/proxmox-manual-initial-setup.md)
2. [Ubuntu Docker VM setup](../os-and-virtualization/ubuntu-docker-security-setup.md)
3. [ARR Stack Local-First Homelab Setup](arr-stack-homelab-fit-review-and-setup.md)
4. [Media Automation With Debrid](media-automation-debrid.md), if Jellyfin has
   already been split into its own stack

## Current Source-Of-Truth Values

These values come from the current repository guides and the working system:

| Item | Current value |
|---|---|
| Proxmox host | `192.168.1.2` |
| TrueNAS VM | VM `110`, `192.168.1.10` |
| Ubuntu Docker VM | VM `111`, `192.168.1.20` |
| CPU | Intel Xeon E3-1245 v6 |
| iGPU | Intel HD Graphics P630, PCI ID `8086:591d` |
| Proxmox iGPU address | `0000:00:02.0` |
| Jellyfin stack | `/opt/stacks/jellyfin-stack` |
| Container UID/GID | `3000:3000` |
| Existing NFS config | `/mnt/main/appdata/arr-stack/jellyfin` |
| New local config | `/srv/appdata/jellyfin` |
| TrueNAS media mount | `/mnt/media/data` |
| Movies | `/mnt/media/data/media/movies` |
| TV | `/mnt/media/data/media/tv` |
| Music | `/mnt/media/data/media/music` |

Do not use the older paths from `configs/docker/jellyfin` for this deployment.
That template still refers to `/opt/docker/jellyfin` and `/mnt/media/...`; the
running local-first stack uses `/opt/stacks/jellyfin-stack` and
`/mnt/media/data/media/...`.

## Why Jellyfin Appdata Moves Off NFS

The current compose variable resolves like this:

```text
JELLYFIN_CONFIG=/mnt/main/appdata/arr-stack/jellyfin
```

The Docker VM mounts `/mnt/main` from TrueNAS:

```text
192.168.1.10:/mnt/main -> /mnt/main (NFSv4.2)
```

Therefore Jellyfin currently places these active files on NFS:

```text
/config/data/data/jellyfin.db
/config/cache
/config/log
```

The observed Jellyfin log included:

```text
Storage path `/config/...` (Network)
SQLite Error 5: 'database is locked'
```

The media files belong on TrueNAS. The active SQLite database, metadata, logs,
and transcode cache should use local block storage. The local appdata must then
be protected by Proxmox VM backups and a separate application-consistent copy
to `/mnt/main/backups`.

## Phase 1: Record The Working Baseline

### 1.1 Proxmox checks

Run on the Proxmox host:

```bash
dmesg | grep -e DMAR -e IOMMU
lspci -nnk -s 00:02.0
find /sys/kernel/iommu_groups/ -type l | sort
qm config 111
```

Expected baseline:

- IOMMU is enabled.
- `00:02.0` is the P630 with device ID `8086:591d`.
- The iGPU is isolated in its own IOMMU group.
- VM `111` uses its existing legacy BIOS installation.
- Physical BIOS/UEFI has Intel VT-d and the integrated graphics device enabled.

This machine also reported a firmware `bad RMRR` warning. Do not assume that
warning alone makes passthrough impossible; the secondary-device configuration
below was tested successfully. Keep the rollback commands available.

### 1.2 Docker VM checks

Run in VM `111`:

```bash
cd /opt/stacks/jellyfin-stack
docker compose ps
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
findmnt -T /mnt/main/appdata/arr-stack/jellyfin
findmnt -T /mnt/media/data
sudo du -sh /mnt/main/appdata/arr-stack/jellyfin
df -h /
```

The media source must remain:

```text
192.168.1.10:/mnt/main/media/data -> /mnt/media/data
```

Do not continue if `/mnt/media/data` points somewhere else.

## Phase 2: Configure Proxmox iGPU Passthrough

### 2.1 Keep the existing VM firmware and machine type

VM `111` was installed in legacy BIOS mode. The working configuration does not
require changing it to OVMF or q35.

For this VM:

- Keep SeaBIOS/default BIOS.
- Keep the default machine type; do not force q35.
- Keep the virtual Bochs display for the Proxmox console.
- Add the Intel iGPU as a secondary PCI device.
- Do not enable `Primary GPU`.
- Do not enable `PCI-Express` for this tested legacy configuration.
- Do not add persistent `vfio-pci.ids` or blacklist `i915` while the current
  runtime handoff works.

Changing BIOS, machine type, and GPU passthrough at the same time can make an
existing legacy installation appear stuck even when the GPU is not the cause.

### 2.2 Attach the iGPU

Stop VM `111`, then attach only the P630:

```bash
qm shutdown 111
qm status 111
qm set 111 --hostpci0 0000:00:02.0
qm start 111
```

Wait until `qm status 111` reports `status: stopped` before running `qm set`.

Equivalent Proxmox GUI path:

```text
VM 111 -> Hardware -> Add -> PCI Device -> Raw Device -> 0000:00:02.0
```

Leave `Primary GPU`, `All Functions`, and `PCI-Express` disabled.

### 2.3 Immediate rollback if the VM does not boot

Run on Proxmox:

```bash
qm stop 111
qm set 111 -delete hostpci0
qm start 111
```

If the host still shows `Kernel driver in use: vfio-pci` after removing the
device, shut down the VMs cleanly and reboot Proxmox. With no persistent VFIO
binding rule, the host should return to:

```text
Kernel driver in use: i915
```

## Phase 3: Verify The P630 Inside VM 111

Run in the Docker VM:

```bash
lspci -nnk | grep -A4 -Ei 'HD Graphics|Kaby|8086:591d'
ls -l /dev/dri
getent group video
getent group render
```

The tested guest exposed:

```text
Intel Corporation Kaby Lake-DT GT2 [HD Graphics P630] [8086:591d]
Kernel driver in use: i915
/dev/dri/card1
/dev/dri/renderD128
video:x:44:
render:x:991:
```

`card0` is the virtual Bochs display. `card1` and `renderD128` belong to the
passed-through Intel iGPU.

Install the validation tools:

```bash
sudo apt update
sudo apt install -y vainfo intel-media-va-driver-non-free intel-gpu-tools
```

If `intel-media-va-driver-non-free` is unavailable, use:

```bash
sudo apt install -y vainfo intel-media-va-driver intel-gpu-tools
```

Allow the login user to test the device:

```bash
sudo usermod -aG video,render "$USER"
```

Log out and back in, then run:

```bash
id
vainfo --display drm --device /dev/dri/renderD128
```

The P630 should report hardware decode/encode profiles for H.264, HEVC,
MPEG-2, and other supported formats. AV1 support is not expected.

`intel_gpu_top` may report `Failed to detect engines` in this passed-through
guest because the i915 PMU engine data is not exposed as expected. That does not
invalidate passthrough. Use `vainfo` and the real Jellyfin FFmpeg command as the
authoritative tests.

## Phase 4: Give Jellyfin Access To The iGPU

### 4.1 Verify current group IDs

Do not assume group IDs on another installation. Run:

```bash
getent group video
getent group render
```

The tested VM uses `44` and `991`.

### 4.2 Current compose device configuration

In `/opt/stacks/jellyfin-stack/docker-compose.yml`, the Jellyfin service should
contain:

```yaml
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "44"
      - "991"
```

Keep the current media mappings:

```yaml
    volumes:
      - ${JELLYFIN_CONFIG}:/config
      - ${DATA_PATH}/media/movies:/media/movies:ro
      - ${DATA_PATH}/media/tv:/media/tv:ro
      - ${DATA_PATH}/media/music:/media/music:ro
```

Apply and verify:

```bash
cd /opt/stacks/jellyfin-stack
docker compose config
docker compose up -d
docker exec jellyfin id
docker exec jellyfin ls -l /dev/dri
```

LinuxServer may create an automatically named internal group for GID `991`.
The name is not important; the numeric group and access to `renderD128` are.

## Phase 5: Configure Quick Sync In Jellyfin

Open:

```text
Jellyfin -> Dashboard -> Playback -> Transcoding
```

Recommended starting configuration for the P630:

| Option | Value |
|---|---|
| Hardware acceleration | Intel Quick Sync (QSV) |
| QSV device | `/dev/dri/renderD128` |
| H.264 decode | Enabled |
| HEVC decode | Enabled |
| MPEG-2 decode | Enabled |
| VC-1 decode | Enabled |
| VP8 decode | Enabled |
| VP9 decode | Enabled |
| HEVC 10-bit decode | Enabled |
| VP9 10-bit decode | Enabled |
| AV1 decode | Disabled |
| HEVC RExt profiles | Disabled |
| Prefer native VA-API decoders | Enabled |
| Hardware encoding | Enabled |
| Low-power H.264/HEVC encoding | Disabled initially |
| HEVC output encoding | Disabled initially for client compatibility |
| AV1 output encoding | Disabled |
| VPP/OpenCL tone mapping | Disabled initially |
| FFmpeg path | Leave the container default unchanged |
| Transcoding threads | Automatic/default |
| Audio downmix gain | `1` initially |
| Maximum muxing queue | `2048` |
| Transcoding throttling | Enabled |
| Delete old segments | Enabled |

The QSV device can sometimes be left empty, but this VM also has a virtual Bochs
GPU. Setting `/dev/dri/renderD128` explicitly avoids selecting the wrong device.

Tone mapping is only required when Jellyfin must convert HDR to SDR. Confirm
normal SDR and HEVC Main10 transcoding before testing tone mapping.

## Phase 6: Prove That QSV Is Really Used

Start a 4K HEVC video and lower the playback quality to force a transcode. In a
second shell run:

```bash
docker logs -f jellyfin
```

A successful hardware transcode includes arguments similar to:

```text
-init_hw_device vaapi=va:/dev/dri/renderD128,driver=iHD
-init_hw_device qsv=qs@va
-codec:v:0 h264_qsv
```

This proves that Jellyfin uses the Intel render node and QSV encoder. Merely
seeing `qsv` in Jellyfin's list of available encoders is not sufficient; verify
the command for an active transcode.

Direct Play is selected automatically when the client supports the original
video, audio, subtitle, and bitrate. In a Jellyfin client, use maximum/original
home-network quality. During playback, check:

```text
Dashboard -> Active devices -> open the active stream
```

The stream will report `Direct Play`, `Remux`, or `Transcoding` and the reason.

## Phase 7: Add A Local Appdata Disk In Proxmox

The Docker VM root filesystem was measured at 30 GB with only about 9 GB free.
Do not place growing Jellyfin metadata on that root filesystem.

Add a dedicated virtual disk:

```text
VM 111 -> Hardware -> Add -> Hard Disk
```

Recommended settings:

| Setting | Value |
|---|---|
| Bus/device | SCSI |
| Storage | `ssd-fast` if available, otherwise the intended SSD-backed LVM-thin storage |
| Size | 32 GB minimum; 64 GB if using extensive trickplay/chapter images |
| Cache | Default |
| Discard | Enabled |
| IO thread | Enabled |
| SSD emulation | Enabled |
| Backup | Enabled |

The architecture guide names the SSD-backed storage `ssd-fast`. Verify the
actual storage name in the Proxmox UI instead of assuming it exists.

## Phase 8: Format And Mount The New Disk

Install the required tools in VM `111`:

```bash
sudo apt update
sudo apt install -y parted rsync
```

Identify the new blank disk:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL
```

The commands below use `/dev/sdb` only as an example. Stop and replace it with
the actual new blank 32/64 GB disk. Never run `mkfs` against the existing root
disk.

```bash
sudo parted /dev/sdb --script mklabel gpt
sudo parted /dev/sdb --script mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L appdata /dev/sdb1
sudo mkdir -p /srv/appdata
sudo mount /dev/sdb1 /srv/appdata
sudo blkid /dev/sdb1
```

Add the reported UUID to `/etc/fstab`:

```fstab
UUID=REPLACE_WITH_REAL_UUID /srv/appdata ext4 defaults,noatime 0 2
```

Validate before copying data:

```bash
sudo umount /srv/appdata
sudo mount -a
findmnt -T /srv/appdata
df -h /srv/appdata
```

Expected filesystem type: `ext4`, not `nfs4` or `autofs`.

## Phase 9: Migrate Jellyfin Config From NFS To Local SSD

### 9.1 Stop Jellyfin and copy the complete config

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin

sudo mkdir -p /srv/appdata/jellyfin
sudo rsync -aH --numeric-ids \
  /mnt/main/appdata/arr-stack/jellyfin/ \
  /srv/appdata/jellyfin/
sudo chown -R 3000:3000 /srv/appdata/jellyfin
```

Compare the copy:

```bash
sudo du -sh /mnt/main/appdata/arr-stack/jellyfin
sudo du -sh /srv/appdata/jellyfin
sudo find /srv/appdata/jellyfin -maxdepth 3 -name jellyfin.db -ls
```

Do not delete or rename the NFS source. It is the rollback copy until all tests
and a full reboot pass.

### 9.2 Change the current stack variable

Edit `/opt/stacks/jellyfin-stack/.env`:

```text
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
JELLYFIN_CONFIG=/srv/appdata/jellyfin
DATA_PATH=/mnt/media/data
```

Do not change `DATA_PATH`; the media libraries remain on TrueNAS.

Validate the rendered compose configuration before starting:

```bash
cd /opt/stacks/jellyfin-stack
docker compose config
```

The `/config` source must now be `/srv/appdata/jellyfin` while the media sources
must still begin with `/mnt/media/data/media/`.

### 9.3 Start and verify

```bash
docker compose up -d
docker compose ps
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker logs --tail=150 jellyfin
```

Expected mapping:

```text
/srv/appdata/jellyfin -> /config
/mnt/media/data/media/movies -> /media/movies
/mnt/media/data/media/tv -> /media/tv
/mnt/media/data/media/music -> /media/music
```

Check for recurring database errors:

```bash
docker logs --since 30m jellyfin 2>&1 | grep -Ei 'database is locked|SqliteException'
```

No output is the expected result.

Verify in the Jellyfin UI:

- Existing users are present.
- Libraries and watch history are present.
- Movies, TV, and music open normally.
- `/dev/dri/renderD128` remains visible in the container.
- A forced transcode still uses `h264_qsv` or `hevc_qsv`.

## Phase 10: Reboot Tests

Test the Docker VM first:

```bash
sudo reboot
```

After reconnecting:

```bash
findmnt -T /srv/appdata/jellyfin
findmnt -T /mnt/media/data/media/movies
lspci -nnk | grep -A4 -Ei 'HD Graphics|Kaby|8086:591d'
ls -l /dev/dri
docker compose -f /opt/stacks/jellyfin-stack/docker-compose.yml ps
docker exec jellyfin ls -l /dev/dri
```

After the VM reboot succeeds, schedule a maintenance window for one full
Proxmox reboot. TrueNAS VM `110` must start before Docker VM `111`; the existing
architecture uses start order `1` for TrueNAS and order `2` with a 60-second
delay for the Docker VM.

After the Proxmox reboot, repeat the checks above and force one QSV transcode.

## Phase 11: Back Up The New Local Appdata

Moving `/config` local removes it from TrueNAS `main/appdata` snapshots. Protect
it with both:

1. Proxmox backups of VM `111`, including the new virtual disk.
2. An application-consistent Jellyfin config archive stored under
   `/mnt/main/backups/docker-volumes` for TrueNAS snapshots and off-server copy.

Create the backup target:

```bash
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/jellyfin
```

Manual consistent backup:

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin
sudo -u mediauser tar --xattrs --acls --exclude='jellyfin/cache' \
  -czf "/mnt/main/backups/docker-volumes/jellyfin/jellyfin-config-$(date +%F-%H%M).tar.gz" \
  -C /srv/appdata jellyfin
docker compose start jellyfin
```

Verify the archive:

```bash
ls -lh /mnt/main/backups/docker-volumes/jellyfin
sudo tar -tzf /mnt/main/backups/docker-volumes/jellyfin/jellyfin-config-YYYY-MM-DD-HHMM.tar.gz | head
```

Replace the example archive name with the actual generated file. Add retention
and scheduling only after one archive has been successfully restored in a test
directory. The TrueNAS snapshot and off-server backup plan should include
`/mnt/main/backups`.

## Rollback: Return Jellyfin To The NFS Config

If users, libraries, or settings are missing after migration:

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin
```

Restore this value in `.env`:

```text
JELLYFIN_CONFIG=/mnt/main/appdata/arr-stack/jellyfin
```

Then restart:

```bash
docker compose up -d
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker logs --tail=100 jellyfin
```

Do not copy the new local database back over the NFS rollback copy until the
cause of the failed migration is understood.

## Final Checklist

- [ ] Proxmox IOMMU is enabled.
- [ ] VM `111` has only `hostpci0: 0000:00:02.0` for the P630.
- [ ] VM `111` remains on its existing legacy BIOS/default machine type.
- [ ] `/dev/dri/renderD128` exists in VM `111` and the Jellyfin container.
- [ ] `vainfo` succeeds against `/dev/dri/renderD128`.
- [ ] Jellyfin QSV device is `/dev/dri/renderD128`.
- [ ] A real transcode uses `h264_qsv` or `hevc_qsv`.
- [ ] `/config` maps from `/srv/appdata/jellyfin` on ext4.
- [ ] Media paths still map from `/mnt/media/data/media/...` on TrueNAS NFS.
- [ ] `database is locked` does not recur.
- [ ] VM and full Proxmox reboot tests pass.
- [ ] The new virtual disk is included in Proxmox backups.
- [ ] A stopped-container config backup exists under `/mnt/main/backups`.
