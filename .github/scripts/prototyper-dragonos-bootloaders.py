#!/usr/bin/env python3
"""Boot DragonOS through U-Boot or EDK II and exercise its userspace console."""

import argparse
import json
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("u-boot", "edk2"))
    parser.add_argument("--rustsbi", type=pathlib.Path, default=pathlib.Path(
        "target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.bin"))
    parser.add_argument("--efi", type=pathlib.Path, default=pathlib.Path(
        ".cache/dragonos-bootloaders/bootriscv64.efi"))
    parser.add_argument("--uboot", type=pathlib.Path, default=pathlib.Path(
        ".cache/dragonos-bootloaders/u-boot.bin"))
    parser.add_argument("--code", type=pathlib.Path, default=pathlib.Path(
        ".cache/dragonos-bootloaders/RISCV_VIRT_CODE.fd"))
    parser.add_argument("--vars", type=pathlib.Path, default=pathlib.Path(
        ".cache/dragonos-bootloaders/RISCV_VIRT_VARS.fd"))
    parser.add_argument("--smoke", type=pathlib.Path, default=pathlib.Path(".dragonos/work/smoke"))
    parser.add_argument("--log-dir", type=pathlib.Path, default=pathlib.Path("qemu-logs/dragonos"))
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--expect", choices=("PASS", "FAIL"), default="PASS")
    parser.add_argument("--corrupt-data", action="store_true", help="Local negative check")
    args = parser.parse_args()
    run = args.log_dir.resolve() / args.mode
    run.mkdir(parents=True, exist_ok=True)
    inputs = (args.rustsbi, args.efi, args.smoke,
              args.uboot if args.mode == "u-boot" else args.code,
              *(() if args.mode == "u-boot" else (args.vars,)))
    for path in inputs:
        if not path.is_file() or path.stat().st_size == 0:
            parser.error(f"Missing input: {path}")

    # Recreate per-run state. EDK II variables and the disk are never shared
    # with other boots or copied back into the cached firmware products.
    disk = run / "disk.img"
    subprocess.run(["bash", ".github/scripts/make-dragonos-smoke-disk.sh",
                    str(disk), str(args.efi.resolve()), str(args.smoke.resolve())], check=True)
    if args.corrupt_data:
        bad_data = run / "corrupt-smoke-data.txt"
        bad_data.write_text("wrong data\n")
        subprocess.run(["mcopy", "-o", "-i", f"{disk}@@1048576",
                        str(bad_data), "::/etc/rustsbi-smoke.txt"], check=True)
    if args.mode == "edk2":
        shutil.copyfile(args.vars, run / "VARS.fd")

    bootargs = "root=/dev/vda1 console=/dev/hvc0 init=/bin/smoke rw"
    machine = "virt" if args.mode == "u-boot" else "virt,pflash0=pflash0,pflash1=pflash1,acpi=off"
    cmd = ["qemu-system-riscv64", "-machine", machine, "-accel", "tcg",
           "-m", "2G", "-smp", "1", "-no-reboot", "-display", "none",
           "-monitor", "none", "-bios", str(args.rustsbi.resolve()),
           "-chardev", f"socket,id=uart,path={run / 'uart.sock'},server=on,wait=on",
           "-chardev", f"socket,id=guest,path={run / 'guest.sock'},server=on,wait=on",
           "-serial", "chardev:uart", "-device", "virtio-serial-device",
           "-device", "virtconsole,chardev=guest",
           "-drive", f"if=none,id=hd0,format=raw,file={disk}",
           "-device", "virtio-blk-device,drive=hd0"]
    if args.mode == "u-boot":
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
