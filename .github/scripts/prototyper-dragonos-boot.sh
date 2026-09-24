#!/usr/bin/env bash
# Boot DragonOS directly or through U-Boot / EDK II and DragonStub.
# External build products are cached; RustSBI and the userspace smoke are built
# from the current repository commit on every workflow run.
set -euo pipefail

mode=${1:-sbi}
case "$mode" in sbi|u-boot|edk2) ;; *) echo "Usage: $0 [sbi|u-boot|edk2]" >&2; exit 2 ;; esac
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
if [[ "$mode" == sbi ]]; then
  readonly rustsbi=target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.elf
else
  readonly rustsbi=target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.bin
fi
test -s "$rustsbi" || { echo "Missing $rustsbi; run cargo prototyper build" >&2; exit 1; }

readonly DRAGONOS_REV=40572b4554bee5b0a46fb0eff17fdff3a4d74b5e
readonly STUB_REV=8515606674058ca81cd1c0b99453e326875c5c0d
readonly DRAGONOS_IMAGE=dragonos/dragonos-dev@sha256:de57dc949325dc94379defe710d973ba6531c322770d95aa265dd26709b0780a
readonly UBOOT_VERSION=2024.04
readonly UBOOT_SHA256=d6b57ce574a0a0504a5b6596644ceacb7f77bde9353779bcf2fde07c4b9a2b92
readonly EDK2_REV=6951dfe7d59d144a3a980bd7eda699db2d8554ac
readonly MUSL_URL=https://github.com/DragonOS-Community/musl-cross-make/releases/download/9.4.0-231114/riscv64-linux-musl-cross-gcc-9.4.0.tar.xz
readonly MUSL_SHA256=b3833579b91138e496d4bcbee74fa744cf3bff743e9b6f9d1094fb7c3057a93a
readonly work_dir="$(realpath -m "${DRAGONOS_WORK_DIR:-.dragonos/work}")"
readonly cache_dir="$(realpath -m "${DRAGONOS_CACHE_DIR:-.cache/dragonos-bootloaders}")"
readonly source_dir="${DRAGONOS_SOURCE_DIR:-$work_dir/DragonOS}"

mkdir -p "$work_dir" "$cache_dir"

if [[ ! -s "$cache_dir/bootriscv64.efi" || ! -s "$cache_dir/dragonos-kernel.bin" ]]; then
  if [[ ! -d "$source_dir/.git" ]]; then
    git init --quiet "$source_dir"
    git -C "$source_dir" remote add origin https://github.com/Pneuma-zy/DragonOS.git
    git -C "$source_dir" fetch --quiet --depth=1 origin "$DRAGONOS_REV"
    git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
  fi
  actual=$(git -C "$source_dir" rev-parse HEAD)
  [[ $actual == "$DRAGONOS_REV" ]] || {
    echo "DragonOS revision mismatch: $actual" >&2
    exit 1
  }
  git -C "$source_dir" submodule update --init --depth=1 kernel/submodules/DragonStub
  actual=$(git -C "$source_dir/kernel/submodules/DragonStub" rev-parse HEAD)
  [[ $actual == "$STUB_REV" ]] || {
    echo "DragonStub revision mismatch: $actual" >&2
    exit 1
  }

  # The verified S-mode boot uses the original DragonStub, packed around the
  # kernel ELF. The image digest fixes both the Rust and GCC 11 toolchains.
  docker run --rm --volume "$(realpath "$source_dir"):/work" \
    --volume /usr/riscv64-linux-gnu:/usr/riscv64-linux-gnu:ro \
    --workdir /work --entrypoint /bin/bash "$DRAGONOS_IMAGE" -lc '
      set -euo pipefail
      export CARGO_BUILD_JOBS=4
      make ARCH=riscv64 ROOTFS_MANIFEST=default NPROCS=4 kernel
      test -s bin/kernel/kernel.elf
      test -s bin/sysroot/efi/boot/bootriscv64.efi
    '
  cp "$source_dir/bin/sysroot/efi/boot/bootriscv64.efi" "$cache_dir/bootriscv64.efi"
  # DragonOS links below QEMU virt RAM. As in the teammate's bare path, QEMU
  # must receive a flattened image so it can place it at 0x80200000.
  rust-objcopy -O binary --binary-architecture=riscv64 \
    "$source_dir/bin/kernel/kernel.elf" "$cache_dir/dragonos-kernel.bin"
fi

cat >"$work_dir/smoke-init.c" <<'C_SOURCE'
/* DragonOS init for the RustSBI bootloader smoke test. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int emit(const char *message) {
    size_t remaining = strlen(message);
    while (remaining) {
        ssize_t written = write(STDOUT_FILENO, message, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        message += written;
        remaining -= (size_t)written;
    }
    return 0;
}

int main(void) {
    char command[128];
    size_t length = 0;
    int overflow = 0;
    if (emit("RUSTSBI_DRAGONOS_READY v1\n")) return 1;
    for (;;) {
        char c;
        ssize_t count = read(STDIN_FILENO, &c, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            emit("RUSTSBI_DRAGONOS_ERROR stdin\n");
            return 1;
        }
        if (c != '\n' && c != '\r') {
            if (length + 1 < sizeof(command)) command[length++] = c;
            else overflow = 1;
            continue;
        }
        if (!length && !overflow) continue;
        command[length] = '\0';
        int valid = !overflow && length == 38 && !memcmp(command, "smoke ", 6);
        for (size_t i = 6; valid && i < length; i++) {
            if (!((command[i] >= '0' && command[i] <= '9') ||
                  (command[i] >= 'a' && command[i] <= 'f'))) valid = 0;
        }
        if (!valid) {
            if (emit("RUSTSBI_DRAGONOS_ERROR command\n")) return 1;
        } else {
            const char expected[] = "rustsbi-dragonos-ci-v1\n";
            char data[sizeof(expected)];
            size_t used = 0;
            int fd = open("/etc/rustsbi-smoke.txt", O_RDONLY);
            int good = fd >= 0;
            while (good && used < sizeof(data)) {
                ssize_t n = read(fd, data + used, sizeof(data) - used);
                if (n < 0 && errno == EINTR) continue;
                if (n < 0) good = 0;
                if (n <= 0) break;
                used += (size_t)n;
            }
            if (fd >= 0 && close(fd)) good = 0;
            good = good && used == sizeof(expected) - 1 &&
                   !memcmp(data, expected, sizeof(expected) - 1);
            char reply[100];
            snprintf(reply, sizeof(reply), "RESULT %s %s\n", command + 6, good ? "PASS" : "FAIL");
            if (emit(reply)) return 1;
        }
        length = 0;
        overflow = 0;
    }
}
C_SOURCE

# Rebuild the init on every run, so a changed assertion cannot be hidden by a
# cached guest. Static linking avoids requiring a guest dynamic loader.
if [[ -n ${DRAGONOS_MUSL_GCC:-} ]]; then
  smoke_compiler=$DRAGONOS_MUSL_GCC
else
  tarball="$cache_dir/riscv64-linux-musl-cross-gcc-9.4.0.tar.xz"
  if [[ ! -f "$tarball" ]] || ! printf '%s  %s\n' "$MUSL_SHA256" "$tarball" | sha256sum --check --status; then
    curl --fail --location --retry 3 --output "$tarball" "$MUSL_URL"
  fi
  printf '%s  %s\n' "$MUSL_SHA256" "$tarball" | sha256sum --check
  smoke_compiler="$work_dir/riscv64-linux-musl-cross-gcc-9.4.0/bin/riscv64-linux-musl-gcc"
  if [[ ! -x "$smoke_compiler" ]]; then
    tar -xJf "$tarball" -C "$work_dir"
  fi
fi
"$smoke_compiler" -static -O2 -Wall -Wextra -Werror \
  "$work_dir/smoke-init.c" -o "$work_dir/smoke"

if [[ "$mode" == u-boot ]]; then
  if [[ ! -s "$cache_dir/u-boot.bin" ]]; then
    if [[ -n ${DRAGONOS_UBOOT_SOURCE_DIR:-} ]]; then
      tree=$DRAGONOS_UBOOT_SOURCE_DIR
      [[ $(git -C "$tree" rev-parse HEAD) == 25049ad560826f7dc1c4740883b0016014a59789 ]]
    else
      tarball="$work_dir/u-boot-${UBOOT_VERSION}.tar.gz"
      curl --fail --location --retry 3 --output "$tarball" \
        "https://github.com/u-boot/u-boot/archive/refs/tags/v${UBOOT_VERSION}.tar.gz"
      printf '%s  %s\n' "$UBOOT_SHA256" "$tarball" | sha256sum --check
      tar -xzf "$tarball" -C "$work_dir"
      tree="$work_dir/u-boot-${UBOOT_VERSION}"
    fi
    make -C "$tree" O="$work_dir/uboot-build" ARCH=riscv \
      CROSS_COMPILE=riscv64-linux-gnu- qemu-riscv64_smode_defconfig
    make -C "$tree" O="$work_dir/uboot-build" ARCH=riscv \
      CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)"
    cp "$work_dir/uboot-build/u-boot.bin" "$cache_dir/u-boot.bin"
  fi
elif [[ "$mode" == edk2 ]]; then
  if [[ $(stat -c %s "$cache_dir/RISCV_VIRT_CODE.fd" 2>/dev/null || true) != 33554432 ||
        $(stat -c %s "$cache_dir/RISCV_VIRT_VARS.fd" 2>/dev/null || true) != 33554432 ]]; then
    tree="$work_dir/edk2"
    if [[ ! -d "$tree/.git" ]]; then
      git init --quiet "$tree"
      git -C "$tree" remote add origin https://github.com/tianocore/edk2.git
    fi
    git -C "$tree" fetch --quiet --depth=1 origin "$EDK2_REV"
    git -C "$tree" checkout --detach "$EDK2_REV"
    [[ $(git -C "$tree" rev-parse HEAD) == "$EDK2_REV" ]]
    git -C "$tree" submodule update --init --depth=1
    (
      cd "$work_dir"
      export WORKSPACE="$PWD" PACKAGES_PATH="$tree" EDK_TOOLS_PATH="$tree/BaseTools"
      export GCC5_RISCV64_PREFIX=riscv64-linux-gnu-
      set +u
      # shellcheck disable=SC1090
      source "$tree/edksetup.sh" --reconfig
      set -u
      make -C "$tree/BaseTools" -j"$(nproc)"
      set +u
      # shellcheck disable=SC1090
      source "$tree/edksetup.sh" BaseTools
      set -u
      build -a RISCV64 -b RELEASE -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc -t GCC5
    )
    fv="$work_dir/Build/RiscVVirtQemu/RELEASE_GCC5/FV"
    cp "$fv/RISCV_VIRT_CODE.fd" "$cache_dir/RISCV_VIRT_CODE.fd"
    cp "$fv/RISCV_VIRT_VARS.fd" "$cache_dir/RISCV_VIRT_VARS.fd"
    truncate -s 32M "$cache_dir/RISCV_VIRT_CODE.fd" "$cache_dir/RISCV_VIRT_VARS.fd"
  fi
fi

test -s "$cache_dir/bootriscv64.efi"
test -s "$cache_dir/dragonos-kernel.bin"
test -s "$work_dir/smoke"
if [[ "$mode" == u-boot ]]; then
  test -s "$cache_dir/u-boot.bin"
elif [[ "$mode" == edk2 ]]; then
  [[ $(stat -c %s "$cache_dir/RISCV_VIRT_CODE.fd") == 33554432 ]]
  [[ $(stat -c %s "$cache_dir/RISCV_VIRT_VARS.fd") == 33554432 ]]
fi

# Both bootloaders and root=/dev/vda1 use this per-run partitioned FAT disk.
# mtools avoids privileged loop mounts. An empty volume label avoids a known
# FAT directory bug in the pinned DragonOS commit.
run_dir="$(realpath -m "${DRAGONOS_LOG_DIR:-qemu-logs/dragonos}/$mode")"
mkdir -p "$run_dir"
disk="$run_dir/disk.img"
efi="$cache_dir/bootriscv64.efi"
smoke="$work_dir/smoke"
fat=$(mktemp "${disk}.fat.XXXXXX")
trap 'rm -f "$fat" "${disk}.smoke-data"' EXIT
rm -f "$disk"
truncate -s 2147483648 "$disk"
printf 'label: dos\nunit: sectors\n\nstart=2048, size=4192256, type=c, bootable\n' \
  | sfdisk "$disk" >/dev/null
truncate -s 2146435072 "$fat"
# The pinned DragonOS commit does not yet include the FAT volume-label fix.
# An empty label leaves the root directory without a volume-label entry.
mkfs.fat -F 32 -S 512 -h 2048 --invariant -n '' "$fat" >/dev/null
mmd -i "$fat" ::/efi ::/efi/boot ::/bin ::/etc
mcopy -i "$fat" "$efi" ::/efi/boot/bootriscv64.efi
mcopy -i "$fat" "$smoke" ::/bin/smoke
printf 'rustsbi-dragonos-ci-v1\n' >"${disk}.smoke-data"
mcopy -i "$fat" "${disk}.smoke-data" ::/etc/rustsbi-smoke.txt
dd if="$fat" of="$disk" bs=1M seek=1 conv=notrunc,sparse status=none
mdir -i "${disk}@@1048576" ::/efi/boot/bootriscv64.efi
mdir -i "${disk}@@1048576" ::/bin/smoke

rm -f "$fat" "${disk}.smoke-data"
trap - EXIT
if [[ ${DRAGONOS_CORRUPT_SMOKE_DATA:-0} == 1 ]]; then
  printf 'wrong data\n' >"$run_dir/corrupt-smoke-data.txt"
  mcopy -o -i "${disk}@@1048576" "$run_dir/corrupt-smoke-data.txt" ::/etc/rustsbi-smoke.txt
fi

# The small Python probe lives here so this OS adds only one script to CI.
# It owns both QEMU sockets, sends a fresh nonce after READY, and fails on a
# trap, early exit, wrong reply, or timeout. Serial logs are uploaded by YAML.
python3 - "$mode" "$rustsbi" "$efi" "$cache_dir/dragonos-kernel.bin" "$cache_dir/u-boot.bin" \
  "$cache_dir/RISCV_VIRT_CODE.fd" "$cache_dir/RISCV_VIRT_VARS.fd" \
  "$smoke" "$(dirname "$run_dir")" "${DRAGONOS_BOOT_TIMEOUT_SECS:-180}" <<'PY_PROBE'
import json
import os
from types import SimpleNamespace
import pathlib
import re
import secrets
import select
import shutil
import socket
import subprocess
import sys
import time


def main():
    args = SimpleNamespace(
        mode=sys.argv[1], rustsbi=pathlib.Path(sys.argv[2]),
        efi=pathlib.Path(sys.argv[3]), kernel=pathlib.Path(sys.argv[4]),
        uboot=pathlib.Path(sys.argv[5]), code=pathlib.Path(sys.argv[6]),
        vars=pathlib.Path(sys.argv[7]), smoke=pathlib.Path(sys.argv[8]),
        log_dir=pathlib.Path(sys.argv[9]), timeout=int(sys.argv[10]),
        expect=os.environ.get("DRAGONOS_EXPECT_RESULT", "PASS"),
    )
    if args.expect not in ("PASS", "FAIL"):
        raise SystemExit("DRAGONOS_EXPECT_RESULT must be PASS or FAIL")
    run = args.log_dir.resolve() / args.mode
    run.mkdir(parents=True, exist_ok=True)
    inputs = (args.rustsbi, args.efi, args.smoke,
              args.kernel if args.mode == "sbi" else (
                  args.uboot if args.mode == "u-boot" else args.code),
              *(() if args.mode != "edk2" else (args.vars,)))
    for path in inputs:
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"Missing input: {path}")

    # Every boot uses its own disk and writable EDK II variables.
    disk = run / "disk.img"
    if not disk.is_file():
        raise SystemExit(f"Missing disk: {disk}")
    if args.mode == "edk2":
        shutil.copyfile(args.vars, run / "VARS.fd")

    bootargs = "root=/dev/vda1 console=/dev/hvc0 init=/bin/smoke rw"
    machine = "virt" if args.mode != "edk2" else "virt,pflash0=pflash0,pflash1=pflash1,acpi=off"
    cmd = ["qemu-system-riscv64", "-machine", machine, "-accel", "tcg",
           "-m", "2G", "-smp", "1", "-no-reboot", "-display", "none",
           "-monitor", "none", "-bios", str(args.rustsbi.resolve()),
           "-chardev", f"socket,id=uart,path={run / 'uart.sock'},server=on,wait=on",
           "-chardev", f"socket,id=guest,path={run / 'guest.sock'},server=on,wait=on",
           "-serial", "chardev:uart", "-device", "virtio-serial-device",
           "-device", "virtconsole,chardev=guest",
           "-drive", f"if=none,id=hd0,format=raw,file={disk}",
           "-device", "virtio-blk-device,drive=hd0"]
    if args.mode == "sbi":
        cmd += ["-kernel", str(args.kernel.resolve()), "-append", bootargs]
    elif args.mode == "u-boot":
        cmd += ["-kernel", str(args.uboot.resolve())]
    else:
        cmd += ["-blockdev", f"node-name=pflash0,driver=file,read-only=on,filename={args.code.resolve()}",
                "-blockdev", f"node-name=pflash1,driver=file,filename={run / 'VARS.fd'}",
                "-kernel", str(args.efi.resolve())]
        # QEMU's -append becomes EFI LoadOptions, which the fixed DragonStub
        # does not parse for this path. Put bootargs in the actual FDT instead.
        dtb = run / "guest.dtb"
        dump = cmd.copy()
        dump[dump.index("-machine") + 1] += f",dumpdtb={dtb}"
        dump = [item.replace("wait=on", "wait=off") for item in dump]
        with (run / "dump-dtb.log").open("wb") as log:
            subprocess.run(dump, stdout=log, stderr=subprocess.STDOUT, timeout=20, check=True)
        subprocess.run(["fdtput", "-t", "s", str(dtb), "/chosen", "bootargs", bootargs], check=True)
        actual = subprocess.check_output(["fdtget", str(dtb), "/chosen", "bootargs"], text=True).strip()
        if actual != bootargs:
            raise RuntimeError(f"FDT bootargs mismatch: {actual!r}")
        cmd += ["-dtb", str(dtb)]

    (run / "command.json").write_text(json.dumps(cmd, indent=2) + "\n")
    result = {"mode": args.mode, "status": "failed", "expect": args.expect}
    started = time.monotonic()
    deadline = started + args.timeout
    buffers = {"uart": b"", "guest": b""}
    positions = {"uart": 0, "guest": 0}
    sockets = {}
    logs = {name: (run / f"{name}.log").open("wb") for name in buffers}
    failure = re.compile(rb"Unhandled exception:|EXCEPT_RISCV_ILLEGAL_INST|Kernel Panic Occurred|do_trap_(?:insn|load|store)_page_fault(?:\(user mode\)|:)")

    def receive(process):
        if time.monotonic() >= deadline:
            raise TimeoutError(f"No smoke result within {args.timeout}s")
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited before smoke result: {process.returncode}")
        ready, _, _ = select.select(list(sockets.values()), [], [], 0.2)
        for sock in ready:
            name = next(key for key, value in sockets.items() if value is sock)
            data = sock.recv(65536)
            if not data:
                raise RuntimeError(f"{name} console closed")
            logs[name].write(data)
            logs[name].flush()
            buffers[name] += data
            if failure.search(buffers[name]):
                raise RuntimeError(f"Fatal exception on {name}; inspect {run / (name + '.log')}")

    def expect(process, name, pattern):
        regex = re.compile(pattern)
        while True:
            match = regex.search(buffers[name], positions[name])
            if match:
                positions[name] = match.end()
                return match
            receive(process)

    def send_uart(command):
        sockets["uart"].sendall(command.encode() + b"\r")

    with (run / "qemu-stderr.log").open("wb") as stderr:
        process = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=stderr)
        try:
            for name in ("uart", "guest"):
                while True:
                    sock = socket.socket(socket.AF_UNIX)
                    try:
                        sock.connect(str(run / f"{name}.sock"))
                        sockets[name] = sock
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        sock.close()
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("QEMU console did not start")
                        time.sleep(0.05)
            expect(process, "uart", rb"Hello RustSBI!")
            if args.mode == "u-boot":
                expect(process, "uart", rb"Hit any key to stop autoboot:")
                sockets["uart"].sendall(b"\r")
                expect(process, "uart", rb"=> ")
                for command, marker in (
                    ("version", rb"U-Boot 2024\.04"),
                    ("virtio scan", None),
                    ("fatls virtio 0:1 /efi/boot", rb"bootriscv64\.efi"),
                    ("fatload virtio 0:1 0x84000000 /efi/boot/bootriscv64.efi", rb"bytes read"),
                    ("setenv bootargs", None),
                    ("fdt move ${fdtcontroladdr} 0x88000000 0x10000", None),
                    ("fdt addr 0x88000000", None),
                    (f'fdt set /chosen bootargs "{bootargs}"', None),
                    ("fdt print /chosen bootargs", re.escape(bootargs.encode())),
                ):
                    send_uart(command)
                    if marker:
                        expect(process, "uart", marker)
                    expect(process, "uart", rb"=> ")
                send_uart("bootefi 0x84000000 0x88000000")
            expect(process, "guest", rb"RUSTSBI_DRAGONOS_READY v1\r?\n")
            sockets["guest"].sendall(b"invalid-command\n")
            expect(process, "guest", rb"(?:^|\n)RUSTSBI_DRAGONOS_ERROR command\r?\n")
            nonce = secrets.token_hex(16)
            result["nonce"] = nonce
            sockets["guest"].sendall(f"smoke {nonce}\n".encode())
            reply = expect(process, "guest", rb"(?:^|\n)RESULT " + nonce.encode() + rb" (PASS|FAIL)\r?\n")
            result["guest_result"] = reply.group(1).decode()
            if result["guest_result"] != args.expect:
                raise RuntimeError(f"Guest returned {result['guest_result']}, expected {args.expect}")
            result["status"] = "passed"
            print(f"DragonOS {args.mode}: userspace smoke {result['guest_result']} ({nonce})", flush=True)
        except Exception as error:
            result["error"] = str(error)
            print(f"DragonOS {args.mode}: {error}", file=sys.stderr, flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for sock in sockets.values():
                sock.close()
            for stream in logs.values():
                stream.close()
            result["elapsed_seconds"] = round(time.monotonic() - started, 2)
            (run / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    if result["status"] != "passed":
        for name in ("uart", "guest", "qemu-stderr"):
            print(f"--- {name} ---", file=sys.stderr)
            print((run / f"{name}.log").read_text(errors="replace")[-4000:], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY_PROBE
