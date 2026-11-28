#!/usr/bin/env bash
# Build the OnePlus 8T (kebab) 4.19 kernel with KernelSU-Next + the
# Android-17 init.rc shim.
#
# Layout expected:
#   ./            this repo (scripts, patches)
#   ./kernel      LineageOS android_kernel_oneplus_sm8250 based tree
#                 (e.g. The-Anomalist/Singularity, branch event-horizon)
#   kernel/KernelSU-Next   KernelSU-Next, branch singularity-legacy-ksu342
#   ./rom/        boot.img + init.rc pulled from the target ROM
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build.sh [options]

Config:
  --config FILE        use FILE as the initial .config (e.g. a config pulled
                       from the target ROM: adb shell 'zcat /proc/config.gz')
  --defconfig NAME     start from arch/arm64/configs/NAME
  --fragment FILE      merge a config fragment; repeatable. A bare name is
                       looked up in arch/arm64/configs/ (e.g. vendor/oplus.config)
  --localversion STR   override CONFIG_LOCALVERSION. It must match the ROM's
                       kernel release, or vendor modules will not load.
  --config-only        write out/.config, print kernelrelease, then exit

Build:
  --regen-rc           regenerate ksu_rc_blob.h from ./rom/init.rc
  --ak3 DIR            also wrap Image into an AnyKernel3 zip
  -h, --help           show this help
EOF
}

ROOT="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$ROOT/kernel"
OUT="$ROOT/out"
JOBS="${JOBS:-$(nproc)}"
AK3_DIR=""
REGEN_RC=0
CONFIG_FILE=""
DEFCONFIG=""
FRAGMENTS=()
LOCALVERSION=""
CONFIG_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--ak3=*) AK3_DIR="${1#*=}"; shift ;;
	--config=*) CONFIG_FILE="${1#*=}"; shift ;;
	--defconfig=*) DEFCONFIG="${1#*=}"; shift ;;
	--fragment=*) FRAGMENTS+=("${1#*=}"); shift ;;
	--localversion=*) LOCALVERSION="${1#*=}"; shift ;;
	--ak3) AK3_DIR="$2"; shift 2 ;;
	--regen-rc) REGEN_RC=1; shift ;;
	--config) CONFIG_FILE="$2"; shift 2 ;;
	--defconfig) DEFCONFIG="$2"; shift 2 ;;
	--fragment) FRAGMENTS+=("$2"); shift 2 ;;
	--localversion) LOCALVERSION="$2"; shift 2 ;;
	--config-only) CONFIG_ONLY=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
	esac
done

if [ -n "$CONFIG_FILE" ] && [ -n "$DEFCONFIG" ]; then
	echo "error: --config and --defconfig are mutually exclusive" >&2
	exit 1
fi

MAKE=(make -C "$KERNEL" O="$OUT" ARCH=arm64)

# --- configuration ----------------------------------------------------------
# A fresh tree has no .config and Kbuild stops with "Configuration file
# \".config\" not found!". Prefer --config with the config pulled from the
# target ROM: that is what keeps vermagic and modversions CRCs aligned with
# the vendor modules under /vendor.
if [ -n "$CONFIG_FILE" ]; then
	[ -f "$CONFIG_FILE" ] || { echo "no such config: $CONFIG_FILE" >&2; exit 1; }
	mkdir -p "$OUT"
	if [ "$(readlink -f "$CONFIG_FILE")" != "$(readlink -f "$OUT/.config")" ]; then
		cp "$CONFIG_FILE" "$OUT/.config"
	fi
	"${MAKE[@]}" olddefconfig
elif [ -n "$DEFCONFIG" ]; then
	"${MAKE[@]}" "$DEFCONFIG"
fi

if [ ${#FRAGMENTS[@]} -gt 0 ]; then
	resolved=()
	for frag in "${FRAGMENTS[@]}"; do
		if [ ! -f "$frag" ] && [ -f "$KERNEL/arch/arm64/configs/$frag" ]; then
			frag="$KERNEL/arch/arm64/configs/$frag"
		fi
		[ -f "$frag" ] || { echo "no such config fragment: $frag" >&2; exit 1; }
		resolved+=("$frag")
	done
	"$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "${resolved[@]}"
	"${MAKE[@]}" olddefconfig
fi

if [ -n "$LOCALVERSION" ]; then
	"$KERNEL/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVERSION"
	"${MAKE[@]}" olddefconfig
fi

[ -f "$OUT/.config" ] || {
	echo "error: $OUT/.config is missing" >&2
	echo "       pull the ROM config:  adb shell 'zcat /proc/config.gz' > crdroid.config" >&2
	echo "       then:                 ./build.sh --config crdroid.config" >&2
	echo "       or start from vendor: ./build.sh --defconfig vendor/kona-perf_defconfig --fragment vendor/oplus.config" >&2
	exit 1
}

# refresh include/config/auto.conf so kernelrelease reflects the new config
"${MAKE[@]}" -s syncconfig >/dev/null

if [ "$CONFIG_ONLY" = 1 ]; then
	echo "config:        $OUT/.config"
	echo "kernelrelease: $("${MAKE[@]}" -s kernelrelease)"
	exit 0
fi

# --- blob -------------------------------------------------------------------
if [ "$REGEN_RC" = 1 ]; then
	INIT_RC="${INIT_RC:-$ROOT/rom/init.rc}"
	[ -f "$INIT_RC" ] || { echo "missing $INIT_RC (pull /system/etc/init/hw/init.rc)" >&2; exit 1; }
	python3 "$ROOT/gen_init_rc_blob.py" "$INIT_RC" \
		"$KERNEL/KernelSU-Next/kernel/runtime/ksu_rc_blob.h"
fi

[ -f "$KERNEL/KernelSU-Next/kernel/runtime/ksu_rc_blob.h" ] || {
	echo "missing ksu_rc_blob.h - run with --regen-rc first" >&2
	exit 1
}

# --- build ------------------------------------------------------------------
# bc is needed by Kbuild and is sometimes not installed
if ! command -v bc >/dev/null 2>&1; then
	if [ -x "$HOME/.local/bin/bc" ]; then
		export PATH="$HOME/.local/bin:$PATH"
	else
		echo "error: bc not found (install bc, or put it in ~/.local/bin)" >&2
		exit 1
	fi
fi

make -C "$KERNEL" O="$OUT" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
	CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
	OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
	LLVM_IAS=1 KCFLAGS="-Wno-error=visibility" -j"$JOBS"

echo "built: $OUT/arch/arm64/boot/Image"
echo "kernelrelease: $("${MAKE[@]}" -s kernelrelease)"
echo "compare with the ROM: adb shell uname -r"

if [ -n "$AK3_DIR" ]; then
	STAGE="$(mktemp -d)"
	cp -a "$AK3_DIR"/. "$STAGE"/
	cp "$OUT/arch/arm64/boot/Image" "$STAGE/Image"
	rm -rf "$STAGE/.git"
	ZIP="$ROOT/dist/$(date +%Y%m%d)-kebab-ksu-rcblob.zip"
	mkdir -p "$ROOT/dist"
	(cd "$STAGE" && zip -r9 "$ZIP" . -x '*.git*' >/dev/null)
	echo "flashable: $ZIP"
fi
