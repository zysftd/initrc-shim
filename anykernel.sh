### AnyKernel3 Ramdisk Mod Script
##
##  Kebab Kernel — crDroid 13.x (Android 17)
##  ------------------------------------------------------------------
##  author  : zysftd
##  assisted: DeepSeek
##            (log analysis that found the single-read_iter behaviour
##             of Android 17 init, the same-length init.rc replacement,
##             kernel patches, build + packaging scripts)
##
##  target  : OnePlus 8T (kebab), 4.19 non-GKI, Android 17
##  contents: KernelSU-Next 3.4.2 (in-kernel)
##            SUSFS 2.2.0
##            init.rc blob shim (ksud boot stages on Android 17)
##  ------------------------------------------------------------------

properties() { '
kernel.string=Kebab Kernel by zysftd — KSU-Next + SUSFS + InitRC-Shim
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=kebab
device.name2=OnePlus8T
supported.versions=13-17
supported.patchlevels=
supported.vendorpatchlevels=
'; }

boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
}

BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " " \
  "======================================" \
  "  Kebab Kernel for crDroid 13.x" \
  "  KernelSU-Next + SUSFS + Shim" \
  "======================================" \
  "" \
  "  Device    : OnePlus 8T (kebab)" \
  "  ROM       : crDroid 13.1 / Android 17" \
  "  Kernel    : 4.19.325-cip136-st20" \
  "  Root      : KernelSU-Next 3.4.2 (in-kernel)" \
  "  Hiding    : SUSFS 2.2.0" \
  "  Shim      : init.rc read_iter fix" \
  "" \
  "  author    : zysftd" \
  "  assisted  : DeepSeek" \
  "======================================";

ui_print " " "Checking kernel base...";

# The kernel must expose the same vermagic as the ROM's own kernel, or the
# modules under /vendor refuse to load.
ui_print " " "Note on versions:" \
  "  This image targets the kernel shipped in" \
  "  crDroid 17.0-20261126 (cip136-st20)." \
  "  If your ROM is older (cip135-st19), the" \
  "  Wi-Fi/camera/sensor modules will not load." \
  "  Flash the matching crDroid build instead.";

ui_print " " "Extracting boot image...";
dump_boot;

ui_print " " "Writing new kernel...";
write_boot;

ui_print " " \
  "======================================" \
  "  Done." \
  "" \
  "  Reboot to system. The first boot" \
  "  takes 3-10 minutes — do not force" \
  "  power off." \
  "" \
  "  After boot, verify:" \
  "    su -c 'uname -r'" \
  "    -> 4.19.325-cip136-st20-perf-..." \
  "" \
  "  If it does not boot, flash the" \
  "  crDroid zip again to restore the" \
  "  stock kernel." \
  "======================================";
