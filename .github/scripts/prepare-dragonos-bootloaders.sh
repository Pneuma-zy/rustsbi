#!/usr/bin/env bash
# Build the fixed guest/bootloader inputs. RustSBI itself is always built by
# the workflow from the commit being tested, never fetched from this cache.
set -euo pipefail

mode=${1:?usage: $0 u-boot|edk2}
case "$mode" in u-boot|edk2) ;; *) exit 2 ;; esac

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

if [[ ! -s "$cache_dir/bootriscv64.efi" ]]; then
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
fi

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
  .github/dragonos/smoke-init.c -o "$work_dir/smoke"

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
else
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
test -s "$work_dir/smoke"
if [[ "$mode" == u-boot ]]; then
  test -s "$cache_dir/u-boot.bin"
else
  [[ $(stat -c %s "$cache_dir/RISCV_VIRT_CODE.fd") == 33554432 ]]
  [[ $(stat -c %s "$cache_dir/RISCV_VIRT_VARS.fd") == 33554432 ]]
fi
