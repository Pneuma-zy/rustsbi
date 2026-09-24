#!/usr/bin/env bash
# A partitioned FAT32 disk is required by both U-Boot's fatload and DragonOS's
# root=/dev/vda1. mtools writes it without loop devices or privileged mounts.
set -euo pipefail

disk=${1:?usage: $0 DISK EFI SMOKE}
efi=${2:?usage: $0 DISK EFI SMOKE}
smoke=${3:?usage: $0 DISK EFI SMOKE}
mkdir -p "$(dirname "$disk")"
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
