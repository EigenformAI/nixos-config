# Storage & disk maintenance for limiting-factor.
#
# Single source of truth for every NON-root filesystem, plus the housekeeping
# that keeps the disks from silently filling up (nix store GC/optimise and a
# per-boot /tmp wipe). Root/boot/swap stay in hardware-configuration.nix — this
# module is only the data disks and maintenance timers.
#
# Conventions for the data mounts:
#   * pinned by-uuid — stable across controller/port renumbering, unlike
#     /dev/sdX or by-label (labels collide and can be cloned).
#   * `nofail` + a short device-timeout so a missing or unhealthy data disk can
#     NEVER block boot; none of these are on the root path.
{ config, lib, pkgs, ... }:

let
  dataMountOpts = [ "nofail" "x-systemd.device-timeout=10s" ];
in
{
  # ── Data filesystems ──────────────────────────────────────────────────────

  # 2TB NVMe (Samsung) — bulk data / archived run snapshots.
  fileSystems."/mnt/data2t" = {
    device = "/dev/disk/by-uuid/1d653f23-fd54-4373-904d-72cd34341136";
    fsType = "ext4";
    options = dataMountOpts;
  };

  # 1TB Micron SATA SSD — long-term "as-is" archive (GCP backups, a100 runs).
  # Was mounted by hand (absent from config, so lost on every reboot) until now.
  fileSystems."/mnt/asis-archive" = {
    device = "/dev/disk/by-uuid/2e89141a-0a97-4bc3-9e71-a9805cb974c4";
    fsType = "ext4";
    options = dataMountOpts;
  };

  # 2TB WD SATA — cold backup store (nvme root backup, mame.zip, usercache).
  # Formerly labelled "docker-backup"; now a general-purpose backup mount.
  fileSystems."/mnt/backup" = {
    device = "/dev/disk/by-uuid/3d1669a6-4b8e-4f6c-a751-31b7b7b49716";
    fsType = "ext4";
    options = dataMountOpts;
  };

  # 1.5TB Intel SATA SSD — bulk storage. Reformatted 2026-07-16 from the old
  # pre-migration Ubuntu install (salvaged to /mnt/backup/salvage-sdb2 first);
  # made with `-m 0` (no reserved blocks — bulk data, not a root fs).
  fileSystems."/mnt/bulk" = {
    device = "/dev/disk/by-uuid/0b56d38f-b381-40e5-b3b4-1c05a0482c13";
    fsType = "ext4";
    options = dataMountOpts;
  };

  # ── Disk hygiene ──────────────────────────────────────────────────────────

  # Wipe /tmp on every boot. Long ML jobs spill GBs of torch/triton JIT `.so`
  # kernels into /tmp; without this they pile up across reboots (was ~24G).
  # NOT tmpfs on purpose — tmp peaks are far too large to sit in RAM.
  boot.tmp.cleanOnBoot = true;

  # Automatic nix store maintenance so /nix never creeps back to filling root.
  # GC keeps 14 days of generations for rollback; optimise hardlinks duplicate
  # store paths. Both run weekly, off the hot path.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };
}
