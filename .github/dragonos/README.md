# DragonOS bootloader smoke test

The [DragonOS bootloaders workflow](../workflows/dragonos-bootloaders.yml)
checks two QEMU `virt` paths:

| Path | Handoff |
| --- | --- |
| U-Boot | QEMU `-bios` → RustSBI dynamic firmware → S-mode U-Boot `-kernel` → `fatload`/`bootefi` DragonStub → DragonOS |
| EDK II | QEMU `-bios` → RustSBI dynamic firmware → EDK II pflash → EFI payload from QEMU fw_cfg `-kernel` → DragonStub → DragonOS |

Both use one CPU, 2 GiB RAM and a per-run, 2 GiB MBR disk with a FAT32
partition at sector 2048. The disk contains the original DragonStub EFI image,
`/bin/smoke` and `/etc/rustsbi-smoke.txt`. DragonStub embeds the DragonOS kernel
ELF. The kernel command line is placed in the FDT `/chosen/bootargs`; `-append`
would instead reach DragonStub as EFI LoadOptions on the EDK II path.

The pinned DragonOS commit has not yet received the FAT volume-label fix. The
disk therefore has an empty label; this preserves the real partitioned boot
path without adding an unreviewed kernel patch to this CI job.

The source inputs are fixed in
[`prepare-dragonos-bootloaders.sh`](../scripts/prepare-dragonos-bootloaders.sh):
DragonOS and DragonStub commits, the DragonOS container digest, U-Boot
v2024.04 with an archive SHA-256, EDK II's commit and DragonOS's musl cross
toolchain with an archive SHA-256. CI caches only these guest/bootloader build
products. It rebuilds RustSBI from the tested commit and recompiles this
directory's `smoke-init.c` on every run.

The [probe](../scripts/prototyper-dragonos-bootloaders.py) connects to QEMU's
UART and virtio console, waits for the userspace READY marker, sends an invalid
command and verifies its rejection, then sends `smoke <random nonce>`. A PASS
requires the matching nonce in the guest response after the command was sent.
The guest checks the disk file's exact contents before replying. A fatal trap,
early QEMU exit, wrong reply or timeout fails the job. Serial logs, QEMU's
command and a JSON result are uploaded even after failure; disk images and
writable EDK II variables remain runner-local and are discarded with the job.

To run locally from the repository root after `cargo prototyper build`:

```sh
bash .github/scripts/prepare-dragonos-bootloaders.sh u-boot
python3 .github/scripts/prototyper-dragonos-bootloaders.py u-boot
bash .github/scripts/prepare-dragonos-bootloaders.sh edk2
python3 .github/scripts/prototyper-dragonos-bootloaders.py edk2
```

Local builds can reuse an existing exact DragonOS checkout with
`DRAGONOS_SOURCE_DIR` and the exact U-Boot checkout with
`DRAGONOS_UBOOT_SOURCE_DIR`. `DRAGONOS_MUSL_GCC` can point to an installed copy
of the pinned musl compiler. Each run writes under `qemu-logs/dragonos/`.
