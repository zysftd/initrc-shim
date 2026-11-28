## What this is

A shim that makes KernelSU's `ksud` boot stages actually run on ROMs where
Android 17's `init` reads `init.rc` in a single `read_iter()`.

Without it, on such ROMs:

- `ksud post-fs-data` never executes
- `modules_update/` is never applied — modules look installed but stay inactive
- Zygisk never attaches to zygote (`znctl status` → `Could not connect`)
- the manager still shows modules as enabled, because that only reflects files on disk

## How it works

KernelSU appends its `exec … ksud …` lines when a read of `init.rc` returns 0.
Android 17's init `fstat()`s the file, sizes its buffer from that and consumes
the whole file in one call — no EOF read, and no spare room to append into.

This shim instead replaces the file **contents** with a same-length variant of
the ROM's `init.rc`: whole comment lines are swapped for the ksud exec lines and
the length is padded back with comments. init still reads exactly the number of
bytes it asked for.

```
read init.rc, comm: init, has_read=0 has_read_iter=1
read_iter_proxy: served blob ret=58444 pos=58444
```

## Verified on this exact artifact

Flashed the zip attached below on the device listed here, then read the state
back from it — not a "should work" claim:

| | |
|---|---|
| Device | OnePlus 8T (kebab) |
| ROM | crDroid 13.1 / Android 17 |
| Kernel | 4.19.325 non-GKI, `CONFIG_KSU_MANUAL_HOOK=y`, no LTO |
| KernelSU-Next | 3.4.2 (legacy, in-kernel) |
| Zygisk Next | 1.5.3 |
| Modules | Zygisk Next + Vector (LSPosed) active |

Result after reboot:

```
init.rc read hook: comm=init read=0 read_iter=1
znctl status:
  zygote_states:2
  inject_state:1
  root_status: KernelSU (33355)
/data/adb/modules:  zygisk_lsposed, zygisksu
```

## ⚠️ Important

- The bundled `init.rc` blob is **generated from this specific ROM**. After any
  ROM update you must regenerate it (`./build.sh --regen-rc`) and rebuild,
  otherwise the injected lines disappear.
- Flash with AnyKernel3 / on-device patching. A hand-rebuilt `boot.img` without
  a valid AVB footer is rejected on this device and drops back to fastboot.
- Keep a stock boot image around. If a build does not boot, flash stock boot —
  do not format data.

## Artifact

`initrc-shim-v1.0.0-ak3.zip` — AnyKernel3 package (kernel image only).

```
sha256: 4dd8055f941814d8d26bde0ff2856cb38d0957c1b4d87059b83e22303affaae9
```

Flash: recovery → Apply update → Apply from ADB → `adb sideload <zip>`.

## Credits

- LineageOS / Singularity for the kebab 4.19 tree
- KernelSU-Next for the root implementation these hooks extend
- Zygisk Next / Vector for the userspace side

Analysis and patches assisted by DeepSeek.
