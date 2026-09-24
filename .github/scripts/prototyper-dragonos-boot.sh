#!/usr/bin/env bash
#
# Boot DragonOS through RustSBI Prototyper in QEMU on the RISC-V `virt`
# machine.
#
# The bare path (`sbi`, the default and the only one implemented here) uses
# RustSBI's dynamic firmware: QEMU starts the next stage directly, `-bios`
# points at the firmware and `-kernel` at the DragonOS kernel image, and QEMU
# hands the kernel entry point to the firmware through the dynamic info
# structure. No bootloader takes part, so the boot path is short. This mirrors
# the `sbi` mode of prototyper-minimal-linux-boot.sh.
#
# DragonOS riscv64 caveats, tracked in rustsbi/rustsbi#331:
#   * Upstream documents `opensbi -> u-boot -> DragonStub -> kernel`, and the
#     kernel's only boot protocol is DragonStub (an EFI stub). Booting the
#     kernel straight from RustSBI is therefore experimental and may require an
#     upstream DragonOS change before it can pass reliably.
#   * The kernel links at physical 0x01000000, which is below QEMU virt RAM
#     (0x80000000+), so its ELF cannot be loaded at its link addresses. It is
#     flattened to a raw image and handed to `-kernel`, which QEMU places at
#     0x80200000; the entry code relocates itself to whatever 2 MiB-aligned
#     address it was loaded at.
#   * The riscv64 userspace has no shell. Its init stub prints
#     `rs: Hello, world!` and then spins forever, so success is that marker
#     line and the machine never powers off; the wait loop ends on the marker
#     or on the timeout, not on a clean QEMU exit.
#
# DragonOS is built inside its pinned development container so the pinned Rust
# nightly, riscv64 GCC/musl toolchains and DADK come from a reproducible image
# rather than being assembled on the runner. Prebuilt artifacts can be supplied
# through DRAGONOS_DISK and DRAGONOS_KERNEL to skip the build entirely.
#
# Requires: `cargo prototyper build` to have produced the dynamic firmware,
# plus qemu-system-riscv64 and docker (unless prebuilt artifacts are given).

set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [sbi]" >&2
  exit 2
fi

readonly BOOT_MODE="${1:-sbi}"
case "$BOOT_MODE" in
  sbi) ;;
  u-boot | edk2)
    echo "Boot mode '${BOOT_MODE}' is not implemented yet; only 'sbi' (bare) is available." >&2
    exit 2
    ;;
  *)
    echo "Unknown boot mode: ${BOOT_MODE}" >&2
    echo "Usage: $0 [sbi]" >&2
    exit 2
    ;;
esac

# DragonOS currently cannot boot to userspace from an SBI firmware without the
# riscv64 fixes in Pneuma-zy/DragonOS; use that fork until they land upstream
# in DragonOS-Community/DragonOS, then switch the repo and commit back.
readonly DRAGONOS_REPO="${DRAGONOS_REPO:-https://github.com/Pneuma-zy/DragonOS.git}"
readonly DRAGONOS_COMMIT="${DRAGONOS_COMMIT:-d1981efbf9b93da75f04cfa2845c152924c4600f}"
readonly DRAGONOS_DEV_IMAGE="${DRAGONOS_DEV_IMAGE:-dragonos/dragonos-dev:v1.23}"

# The dynamic firmware accepts the kernel entry through the fw_dynamic info
# structure; the bare path boots it as `-bios`.
readonly RUSTSBI="${DRAGONOS_RUSTSBI:-target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.elf}"

# The riscv64 init stub prints this and then spins forever.
readonly SMOKE_MARKER="rs: Hello, world!"
# A panic halts the machine while QEMU stays alive, so fail as soon as one of
# these appears instead of sitting out the whole boot timeout.
readonly BOOT_FAILURE_PATTERN="panicked at|Attempted to kill init|Kernel panic|not syncing"

# Docker rejects relative host paths for bind mounts, so resolve the work
# directory against the current directory even when the caller leaves it at the
# default relative value.
WORK_DIR="${DRAGONOS_WORK_DIR:-.dragonos/work}"
case "$WORK_DIR" in
  /*) ;;
  *) WORK_DIR="${PWD}/${WORK_DIR}" ;;
esac
readonly WORK_DIR
readonly LOG_DIR="${QEMU_LOG_DIR:-qemu-logs}"
readonly LOG_FILE="${LOG_DIR}/prototyper-dragonos-${BOOT_MODE}.log"
readonly BOOT_TIMEOUT_SECS="${DRAGONOS_BOOT_TIMEOUT_SECS:-300}"

# Prebuilt DragonOS inputs. When both are set the build step is skipped.
DRAGONOS_KERNEL="${DRAGONOS_KERNEL:-}"
DRAGONOS_DISK="${DRAGONOS_DISK:-}"

# Raw kernel image QEMU places at 0x80200000.
KERNEL_IMAGE="${WORK_DIR}/dragonos-kernel.bin"

QEMU_PID=""

# DragonOS links at physical 0x01000000, below QEMU virt RAM, so the ELF is
# flattened to a raw image before it is handed to `-kernel`. An input that is
# already raw is copied through unchanged.
flatten_kernel() {
  local input=$1
  local output=$2
  local magic

  if [[ -s "$output" && "$output" -nt "$input" ]]; then
    echo "Using existing flattened DragonOS kernel image" >&2
    return
  fi

  mkdir -p "$(dirname "$output")"
  magic=$(od -An -tx1 -N4 "$input" | tr -d ' \n')
  if [[ "$magic" = 7f454c46 ]]; then
    rust-objcopy -O binary --binary-architecture=riscv64 "$input" "$output"
  else
    cp "$input" "$output"
  fi
  test -s "$output" || {
    echo "failed to flatten DragonOS kernel image '$input'" >&2
    return 1
  }
}

# Build DragonOS for riscv64 from the pinned commit, unless the caller already
# supplied the kernel and disk image. The development container carries every
# build prerequisite, so the runner only needs docker.
prepare_dragonos() {
  local source="${WORK_DIR}/DragonOS"
  local head

  if [[ -n "$DRAGONOS_KERNEL" && -n "$DRAGONOS_DISK" ]]; then
    test -s "$DRAGONOS_KERNEL" || {
      echo "Missing DragonOS kernel: $DRAGONOS_KERNEL" >&2
      return 1
    }
    test -s "$DRAGONOS_DISK" || {
      echo "Missing DragonOS disk image: $DRAGONOS_DISK" >&2
      return 1
    }
    echo "Using prebuilt DragonOS artifacts" >&2
    flatten_kernel "$DRAGONOS_KERNEL" "$KERNEL_IMAGE"
    return
  fi

  command -v docker >/dev/null 2>&1 || {
    echo "docker is required to build DragonOS; set DRAGONOS_KERNEL and DRAGONOS_DISK to use prebuilt artifacts" >&2
    return 1
  }

  mkdir -p "$WORK_DIR"
  if [[ ! -d "${source}/.git" ]]; then
    git init --quiet "$source"
    git -C "$source" remote add origin "$DRAGONOS_REPO"
  fi
  git -C "$source" fetch --quiet --depth=1 origin "$DRAGONOS_COMMIT"
  git -C "$source" checkout --quiet --detach FETCH_HEAD
  head=$(git -C "$source" rev-parse HEAD)
  if [[ "$head" != "$DRAGONOS_COMMIT" ]]; then
    echo "DragonOS checkout mismatch: expected ${DRAGONOS_COMMIT}, got ${head}" >&2
    return 1
  fi

  # The bare-boot smoke test only needs /bin/riscv_rust_init. Building the full
  # default userspace pulls in C/C++ apps whose toolchain headers are incomplete
  # in the development image, so install a minimal config set with just the init
  # stub and build against it. The files live in the (throwaway) checkout.
  mkdir -p "${source}/user/dadk/config/sets/ci-smoke"
  cp "${source}"/user/dadk/config/sets/default/riscv_init-*.toml \
    "${source}/user/dadk/config/sets/ci-smoke/"
  printf '%s\n' \
    '[metadata]' 'name = "ci-smoke"' 'arch = "riscv64"' '' \
    '[rootfs]' 'fs_type = "fat32"' 'size = "2G"' 'partition = "mbr"' '' \
    '[base]' 'image = ""' 'pull_policy = "if-not-present"' '' \
    '[user]' 'config_dir = "user/dadk/config/sets/ci-smoke"' \
    >"${source}/config/rootfs-manifests/ci-smoke.toml"

  # Build the kernel and userspace inside the pinned development container.
  # Two container-specific quirks are handled here:
  #   * `make -C kernel all` also links DragonStub, which this checkout does not
  #     carry, so it fails after producing bin/kernel/kernel.elf. The failure is
  #     tolerated as long as the ELF exists.
  #   * dadk's partition-based disk image cannot be created in the container: it
  #     needs udev/loop-partition nodes, so it fails with "Partition not exist".
  #     A partitionless whole-disk FAT32 image is assembled instead, which the
  #     kernel mounts as the whole device.
  # The container is privileged so `mount -o loop` works for the partitionless
  # image (no partition node is needed for a whole-disk filesystem).
  docker run --rm --privileged \
    -v "${source}:/workspace/DragonOS" \
    -w /workspace/DragonOS \
    "$DRAGONOS_DEV_IMAGE" \
    bash -lc '
      set -euo pipefail
      # The dev image installs the cross toolchains under /root/opt and only
      # puts them on PATH from an interactive ~/.bashrc, which a non-interactive
      # shell skips. Add them explicitly so the userspace build works.
      for d in /root/opt/*/bin; do export PATH="$d:$PATH"; done
      git submodule update --init --recursive --force
      make clean
      # `make -C kernel all` bypasses the top-level Makefile step `mkdir -p
      # bin/kernel`, so create it here or the final objcopy cannot write the ELF.
      mkdir -p bin/kernel
      make ROOTFS_MANIFEST=ci-smoke ARCH=riscv64 prepare_rootfs_manifest
      make -C kernel all ARCH=riscv64 -j"$(nproc)" || true
      test -s bin/kernel/kernel.elf
      make -C user all ARCH=riscv64 -j"$(nproc)"

      img=bin/disk-image-riscv64.img
      rm -f "$img"
      dd if=/dev/zero of="$img" bs=1M count=2048 status=none
      mkfs.vfat -F 32 -n DRAGONOS "$img" >/dev/null
      mnt=$(mktemp -d)
      mount -o loop "$img" "$mnt"
      # The root directory must start with a file entry, so write the sysroot
      # install marker (what dadk would have written) before the directories.
      if [[ -f bin/sysroot/.dadk_install_marker ]]; then
        cp -a bin/sysroot/.dadk_install_marker "$mnt/"
      else
        printf "manifest=default;layout=2\n" > "$mnt/.dadk_install_marker"
      fi
      cp -a bin/sysroot/bin "$mnt/"
      [[ -d bin/sysroot/efi ]] && cp -a bin/sysroot/efi "$mnt/"
      mkdir -p "$mnt/proc" "$mnt/dev" "$mnt/sys"
      sync
      umount "$mnt"
      # The image is created by root inside the container. Hand it to the
      # checkout owner and make it writable: QEMU opens the drive read-write.
      chown --reference=/workspace/DragonOS "$img"
      chmod 0644 "$img"
    '

  DRAGONOS_KERNEL="${source}/bin/kernel/kernel.elf"
  DRAGONOS_DISK="${source}/bin/disk-image-riscv64.img"
  test -s "$DRAGONOS_KERNEL" || {
    echo "DragonOS kernel was not produced at $DRAGONOS_KERNEL" >&2
    return 1
  }
  test -s "$DRAGONOS_DISK" || {
    echo "DragonOS disk image was not produced at $DRAGONOS_DISK" >&2
    return 1
  }
  flatten_kernel "$DRAGONOS_KERNEL" "$KERNEL_IMAGE"
}

check_prerequisites() {
  test -s "$RUSTSBI" || {
    echo "Missing $RUSTSBI; run 'cargo prototyper build' first" >&2
    return 1
  }
  qemu-system-riscv64 --version
}

stop_qemu() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}

cleanup() {
  stop_qemu
}

start_qemu_sbi() {
  mkdir -p "$LOG_DIR"
  # Truncate any stale log from a previous run before QEMU starts, so the wait
  # loop cannot mistake an old success marker for this boot's.
  : >"$LOG_FILE"
  # DragonOS's console is the virtio console (console=/dev/hvc0), so serial and
  # the virtconsole share one mux on stdio; the whole boot lands in one log.
  qemu-system-riscv64 \
    -machine virt \
    -cpu sifive-u54 \
    -smp 1 \
    -m 2G \
    -display none \
    -no-reboot \
    -nic none \
    -bios "$RUSTSBI" \
    -kernel "$KERNEL_IMAGE" \
    -append "console=/dev/hvc0 rw init=/bin/riscv_rust_init" \
    -drive id=disk,file="$DRAGONOS_DISK",if=none,format=raw \
    -device virtio-blk-device,drive=disk \
    -chardev stdio,id=mux,mux=on,signal=off \
    -serial chardev:mux \
    -device virtio-serial-device \
    -device virtconsole,chardev=mux \
    >"$LOG_FILE" 2>&1 &
  QEMU_PID=$!
}

userspace_is_ready() {
  grep -Fq "$SMOKE_MARKER" "$LOG_FILE"
}

boot_has_failed() {
  grep -Eq "$BOOT_FAILURE_PATTERN" "$LOG_FILE"
}

report_boot_failure() {
  echo "DragonOS failed to boot:" >&2
  grep -E --max-count=5 "$BOOT_FAILURE_PATTERN" "$LOG_FILE" >&2 || true
  tail -n 120 "$LOG_FILE" || true
}

report_early_exit() {
  local qemu_exit
  set +e
  wait "$QEMU_PID"
  qemu_exit=$?
  set -e

  echo "QEMU exited before DragonOS reached userspace (exit=${qemu_exit})" >&2
  tail -n 120 "$LOG_FILE" || true
}

wait_for_userspace() {
  local elapsed
  for ((elapsed = 0; elapsed < BOOT_TIMEOUT_SECS; elapsed++)); do
    # The marker is checked first so a boot that succeeds just before a late
    # panic is still reported as the success it was.
    if userspace_is_ready; then
      return 0
    fi
    if boot_has_failed; then
      report_boot_failure
      return 1
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      if userspace_is_ready; then
        return 0
      fi
      report_early_exit
      return 1
    fi
    sleep 1
  done

  # Check once more after the final sleep, including the timeout boundary.
  if userspace_is_ready; then
    return 0
  fi

  echo "DragonOS did not reach userspace within ${BOOT_TIMEOUT_SECS}s" >&2
  tail -n 120 "$LOG_FILE" || true
  return 1
}

main() {
  trap cleanup EXIT

  check_prerequisites
  prepare_dragonos
  start_qemu_sbi
  wait_for_userspace

  echo "RustSBI booted DragonOS to userspace successfully (${BOOT_MODE})"
  echo "QEMU log: ${LOG_FILE}"
}

main "$@"
