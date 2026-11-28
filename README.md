# InitRC-Shim

### Fix KernelSU module loading on Android 17 (non-GKI)

**Author:** zysftd
**Assisted by:** DeepSeek (analysis, kernel patching, build and packaging)

The idea, the hardware, the testing and the final judgement are the author's;
DeepSeek helped read the kernel logs, work out why the existing injection
silently fails on Android 17, write the shim and lay out this repository.

Working around a silent failure that breaks module loading (and therefore
Zygisk, LSPosed, …) on kernels where init no longer reads `init.rc` the way
KernelSU expects.

Tested on: **OnePlus 8T (kebab), crDroid 13.1 / Android 17, Linux 4.19.325,
KernelSU-Next 3.4.2 (legacy, in-kernel), Zygisk Next 1.5.3**.

## The problem

KernelSU starts its boot stages by injecting a few lines into the `init.rc`
stream while init parses it:

```
on post-fs-data
    exec u:r:ksu:s0 root -- /data/adb/ksud post-fs-data
```

The kernel installs a proxy on the file operations of `init.rc` and appends
that text **when a read returns 0 (EOF)**.

Android 17's init does something different: it `fstat()`s the file, sizes its
buffer accordingly and reads the whole file with a **single `read_iter()`**.
The first read already lands on the end of the file, so the `ret == 0` branch
never runs, and there is no spare room in the destination buffer to append
into anyway.

Result, with no error anywhere:

- `ksud post-fs-data` never executes
- `modules_update/` is never applied (modules appear installed but stay
  inactive, a symptom also reported as
  [KernelSU-Next#1107](https://github.com/KernelSU-Next/KernelSU-Next/issues/1107))
- Zygisk never attaches to zygote → `znctl status` reports
  `Could not connect to service`
- The manager still shows modules as enabled, because that only reflects
  files on disk

Observed trace from a stock 4.19 + Android 17 device:

```
read init.rc, comm: init, has_read=0 has_read_iter=1
read_iter_proxy: ret=58444 pos=58444 size=58444     <- whole file, once
```

## The workaround

Do not append. **Replace the file contents with a same-length variant.**

1. Take `init.rc` from the target ROM.
2. Drop whole comment lines until enough space is freed (instructions are
   never touched).
3. Append the KernelSU `exec … ksud …` lines.
4. Pad back with comment lines so the byte length is *exactly* the original,
   because init sized its buffer from `fstat()`.
5. Compile that blob into the kernel and have the read hook serve it instead
   of the on-disk file.

init still reads the same number of bytes it asked for, parses it as before,
and simply finds three extra `exec` lines.

```
read init.rc, comm: init, has_read=0 has_read_iter=1
read_iter_proxy: served blob ret=58444 pos=58444
```

After that, `ksud post-fs-data` runs from init, modules are mounted, and
Zygisk loads:

```
znctl status
  inject_state: 1
  zygote_state_0: zygote
  zygote_state_1: zygote_secondary
```

## Requirements

- `CONFIG_KSU_MANUAL_HOOK=y` (this shim hooks the manual read path)
- `CONFIG_KSU_KPROBES_HOOK` unset — KernelSU-Next's own Kconfig says kprobe
  hooks "should not be used on kernel below 5.10"
- A writable/custom kernel: KernelSU must be built in (non-GKI)

On GKI 5.10+ devices KernelSU uses LKM and this is not needed.

## Files

```
gen_init_rc_blob.py   builds ksu_rc_blob.h from a ROM init.rc
build.sh              config + kernel build + optional AnyKernel3 packaging
patches/
  0000-kernel-build-and-kebab-fixes.patch   build fixes for this 4.19 tree
  0001-ksu-init-rc-blob.patch               the init.rc shim (KernelSU side)
  0002-ksu-patch-memory-4.19.patch          drop a stale pre-5.8 compat macro
```

## Host requirements

- clang/LLVM with `LLVM_IAS=1` support, plus `ld.lld`, `llvm-ar`, `llvm-nm`,
  `llvm-objcopy`, `llvm-objdump`, `llvm-strip`
- `aarch64-linux-gnu-` binutils for `CROSS_COMPILE`
- `bc` (Arch packages it separately; `build.sh` also accepts a copy in
  `~/.local/bin`), `zip`, `python3`, `adb`

## Tested baseline

| component | revision |
|---|---|
| Singularity (kernel) | `event-horizon` @ `7c2b1aedb` |
| KernelSU-Next | `singularity-legacy-ksu342` @ `3e4677584` |
| ROM | crDroid 13.1 (Android 17), firmware 14.1.0.603 |
| toolchain | clang 23.1.5, LLD, `aarch64-linux-gnu` binutils |

## Building

```bash
git clone -b event-horizon https://github.com/The-Anomalist/Singularity.git kernel
git clone -b singularity-legacy-ksu342 \
    https://github.com/The-Anomalist/KernelSU-Next.git kernel/KernelSU-Next
# drivers/kernelsu is already a tracked symlink in the Singularity tree
#   drivers/kernelsu -> ../KernelSU-Next/kernel
# so there is nothing to create here.

patch -p1 -d kernel < patches/0000-kernel-build-and-kebab-fixes.patch
patch -p1 -d kernel/KernelSU-Next < patches/0001-ksu-init-rc-blob.patch
patch -p1 -d kernel/KernelSU-Next < patches/0002-ksu-patch-memory-4.19.patch
```

### Configuration

Kbuild stops on a fresh tree with `Configuration file ".config" not found!`,
and the config is not interchangeable: `CONFIG_MODVERSIONS=y` means the
kernel must expose the same symbol CRCs as the ROM's own kernel, or the
`.ko` files under `/vendor` fail to load. Take the config from the target
ROM:

```bash
adb shell 'zcat /proc/config.gz' > crdroid-13.1.config

./build.sh --config crdroid-13.1.config --config-only
# config:        .../out/.config
# kernelrelease: 4.19.325-cip135-st19-perf-g66e230426430
```

`kernelrelease` must equal `adb shell uname -r`. If it does not, adjust the
suffix with `--localversion`: this tree already adds `-cip135` and `-st19`
from its `localversion-*` files, so pass only the rest (e.g.
`--localversion=-perf`). If the ROM's release ends in `-g<hash>` and your
tree's `scripts/setlocalversion` does not produce it, pass the whole suffix
with `--localversion=-perf-g<hash>`.

Without a device you can start from the vendor defconfig, but the result is
unlikely to match the ROM's kernel byte for byte:

```bash
./build.sh --defconfig vendor/kona-perf_defconfig \
           --fragment vendor/oplus.config --localversion=-perf --config-only
```

### Build and package

```bash
mkdir -p rom && adb pull /system/etc/init/hw/init.rc rom/init.rc
./build.sh --config crdroid-13.1.config --regen-rc
```

`--regen-rc` writes `kernel/KernelSU-Next/kernel/runtime/ksu_rc_blob.h`;
after that `./build.sh --config crdroid-13.1.config` alone rebuilds
`out/arch/arm64/boot/Image`. Both modes print `kernelrelease`.

The Singularity tree carries `KernelSU-Next` as a submodule, so once a
branch is cloned into that path `git -C kernel status` reports it as
modified (it has its own `.git`). That is expected — don't commit it.

Then package and flash with AnyKernel3 (recovery sideload). The packaging
step copies the AnyKernel3 directory and drops `Image` into it, so the
repo's `anykernel.sh` has to be put in place first:

```bash
git clone https://github.com/osm0sis/AnyKernel3.git anykernel3
cp anykernel.sh anykernel3/anykernel.sh
./build.sh --config crdroid-13.1.config --ak3 anykernel3

adb reboot recovery            # recovery → Apply update → Apply from ADB
adb sideload dist/*.zip
```

The zip lands in `dist/<date>-kebab-ksu-rcblob.zip`.

## Porting to a new ROM release

The hook is ROM-agnostic; the kernel binary is not. When crDroid publishes
a new build (e.g. 13.2):

1. **Base tree** — check out the kernel tree matching that release. If
   Singularity has moved, re-checkout `event-horizon` and resolve conflicts
   in `0000`–`0002`.
2. **Config** — pull the new `/proc/config.gz` and pass it with `--config`.
   Without it the build either stops at `.config not found` or produces a
   kernel whose vermagic/CRCs do not match `/vendor`.
3. **Release string** — `--config-only` prints `kernelrelease`; it must be
   identical to `adb shell uname -r`.
4. **Blob** — `--regen-rc` with the new `init.rc`. If it reports "too few
   comment bytes", the snippet must shrink or move; the file length has to
   stay unchanged.
5. **Flash and test** — rebuild the AnyKernel3 zip, then check module mount,
   Zygisk and Wi-Fi (vendor `.ko` loading) on the new ROM.

## Important caveats

- **The blob is ROM-specific.** Regenerate `ksu_rc_blob.h` (`--regen-rc`)
  whenever the ROM's `init.rc` changes, or the injected lines disappear.
- **Flash with AnyKernel3 / on-device patching, not with a hand-rebuilt
  boot.img.** On this device a self-built boot image without a valid AVB
  footer is rejected and the phone drops back to fastboot; AnyKernel3
  rewrites the existing partition in place and keeps the structure intact.
- **This only fixes boot-stage execution.** Root itself (`su`) works without
  it; what breaks without the shim is module mounting and Zygisk.
- Keep a stock boot image around. If a build does not boot, flash the stock
  boot (or use the AnyKernel3 zip built from the stock kernel) — do not
  format data.

## Credits

- **DeepSeek** — log analysis that located the single-`read_iter` behaviour,
  the same-length init.rc replacement, kernel patches, build/packaging scripts
  and this document. Verified end to end on the author's device.
- [LineageOS android_kernel_oneplus_sm8250](https://github.com/LineageOS/android_kernel_oneplus_sm8250)
  and [Singularity](https://github.com/The-Anomalist/Singularity) for the
  kebab 4.19 tree and its tuning
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) for the
  root implementation these hooks extend
- [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) and
  [Vector](https://github.com/JingMatrix/Vector) for the userspace side

## License

GPL-2.0-only. The patches modify the Linux kernel and KernelSU-Next, both
GPL-2.0; the scripts and the blob generator are released under the same
terms. See [LICENSE](LICENSE).
