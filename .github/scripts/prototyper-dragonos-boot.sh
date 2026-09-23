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

readonly DRAGONOS_REPO="https://github.com/DragonOS-Community/DragonOS.git"
readonly DRAGONOS_COMMIT="c917a92db9710be8e65c9fd60422c3ca44b0e88e"
readonly DRAGONOS_DEV_IMAGE="dragonos/dragonos-dev:v1.23"

# The dynamic firmware accepts the kernel entry through the fw_dynamic info
# structure; the bare path boots it as `-bios`.
readonly RUSTSBI="${DRAGONOS_RUSTSBI:-target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.elf}"

# The riscv64 init stub prints this and then spins forever.
readonly SMOKE_MARKER="rs: Hello, world!"
# A panic halts the machine while QEMU stays alive, so fail as soon as one of
# these appears instead of sitting out the whole boot timeout.
readonly BOOT_FAILURE_PATTERN="panicked at|Attempted to kill init|Kernel panic|not syncing"

readonly WORK_DIR="${DRAGONOS_WORK_DIR:-.dragonos/work}"
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

  # `make clean` first: a cached x86_64 build tree breaks the riscv64 build.
  docker run --rm \
    -v "${source}:/workspace/DragonOS" \
    -w /workspace/DragonOS \
    "$DRAGONOS_DEV_IMAGE" \
    bash -lc 'git submodule update --init --recursive --force && make clean && make ARCH=riscv64 build -j"$(nproc)"'

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
