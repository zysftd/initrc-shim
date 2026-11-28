## 一加 8T (kebab) — crDroid 13.x 内核，2026-11-28 (v1.1.3)

基于 crDroid 官方 `17.0` 内核树，适配 **crDroid 17.0-20261126**。

本版把 SELinux context 探测这一层彻底关掉，并如实说明剩下的告警为什么修不了。

## 相比 v1.1.1 改了什么

两处漏洞让应用能探测到 KSU 和 LSPosed 的 SELinux context：

**① manual-hook 内核上，两个 hook 根本没装**

`ksu_hook_proc_attr_write()` 和 `ksu_hook_transaction_write()` 里有一段：

```c
#if defined(CONFIG_KSU_MANUAL_HOOK) && LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
    /* Preserve legitimate Android 17 app context transactions... */
    return;
#endif
```

我们的配置正好命中（`CONFIG_KSU_MANUAL_HOOK=y` + 4.19），导致
`/proc/self/attr/current` 和 `/sys/fs/selinux/context` 从未被 patch。

这个 guard 的本意是保护 Android 17 的 app context transaction，但 hook
只拒绝「包含隐藏类型名」的写入，其余一律 passthrough 给原函数——合法
transaction 本来就不受影响。移除。

**② `xposed_file` 漏在隐藏列表外**

`ksu_selinux_hide_init_thread()` 预填了 `xposed_data` 却没有
`xposed_file`，所以兄弟 context 都返回 EINVAL 时，它仍然被识别。补上。

## 实测效果

同一台设备、同一个检测器，四版内核对比：

| 内核 | Context oracle | attr/current write | 被识别的 context |
|---|---|---|---|
| `#1` (v1.1.0) | — | — | 4 个 |
| `#2` (v1.1.1) | `11` 两个 KSU context 被接受 | Context recognized | 4 个 |
| `#3` (v1.1.2) | **`00` 全部拒绝** | Xposed file | **1 个** |
| **`#4` (本版)** | **`00`** | **Tested contexts not recognized** | **0 个** ✅ |

探测的 10 个 context 现在全部返回 `NORMAL_EINVAL`：

```
KernelSU, KernelSU file, Magisk, Magisk file, LSPosed file,
Xposed data, Xposed file, DroidSpaces daemon, MSD app, MSD daemon
```

## 剩余告警（无法消除）

扫描器仍会报告 SELinux 为 DANGER，标题是
`Enforcing with DirtySepolicy anomaly`。只剩两条规则，**都不是本内核引入的**：

**`kernel -> adb_data_file read: Allowed`**

KernelSU 保存授权列表到 `/data/adb/ksu` 所必需
（见 `selinux/rules.c`：`// we need to save allowlist in /data/adb/ksu`）。
删掉这条规则，KSU 就无法保存授权，root 直接失效。

**`system_server execmem: Allowed`**

**这不是本内核加的。** 它来自 crDroid 官方 ROM 的 sepolicy。
用完全未修改的 crDroid 官方内核扫描，这条同样会出现。

其余三条属于 `SELinux policy observation`（仅信息，不参与判定）：
`dex2oat execute`、`fsck_untrusted sys_admin`、`system_server -> apk_data_file execute`。

**结论：kernel 能做的到此为止。** 继续压只有两个方向，都不是好选择——
删 adb_data_file 规则会废掉 root，改 system_server execmem 是动 ROM 的
policy。

## 其他仍会报红但与本内核无关的项

- **Dangerous Apps**：Scene 广播。该应用并未安装（`pm path` 为空、
  `dumpsys package` 报 `Unable to find package`、`pm list packages -u`
  也查不到），属于扫描器利用 HMA 存在做出的推断，是假阳性。
- **LSPosed**：`D/zygisk-core64(...)` 这类 logcat 泄漏由 Zygisk Next
  用户态进程产生，内核无法干预。

## 包含

| 组件 | 版本 |
|---|---|
| 内核 | 4.19.325-cip136-st20-perf-g078365e5318d |
| KernelSU-Next | 3.4.2（内联，手动钩子） |
| SUSFS | 2.2.0（11 项特性全开） |
| InitRC-Shim | `ksu_rc_blob.h`，同长度替换 `init.rc` |

内核版本串与 crDroid 2026-11-26 包**完全一致**，`/vendor` 下的 `.ko`
（Wi-Fi、相机、传感器）正常加载。

## 产物

`ak3-kebab-cip136-ksu-shim-20261128d.zip` — 24,965,646 字节

```
sha256: d5bf5dcdf0d4ed22fc0482cf4b626603d0fb18917c4abb6377f19195f19fdd42
```

## 安装

**前提**：已刷 crDroid 17.0-20261126（或其内核仍为 `cip136-st20` 的版本），
bootloader 已解锁。

```bash
adb reboot recovery
# recovery → Apply update → Apply from ADB
adb sideload ak3-kebab-cip136-ksu-shim-20261128d.zip
# 重启
```

首次开机会慢（3–10 分钟），这是 ART 重新编译，**不要强制关机**。

## 验证

```bash
adb shell uname -r
# 4.19.325-cip136-st20-perf-g078365e5318d

adb shell cat /proc/version
# ... (zysftd@kebab) ... #4 SMP PREEMPT ...

adb shell su -c id
# uid=0(root) —— 需先在 KernelSU-Next 管理器授权
```

## 回滚

刷回 crDroid ROM 即可恢复官方内核：

```bash
adb sideload crDroidAndroid-17.0-20261126-kebab-v13.1.zip
```

注意 gapps 会被一并冲掉，需要重刷。

## 构建来源

- 内核树：[crdroidandroid/android_kernel_oneplus_sm8250](https://github.com/crdroidandroid/android_kernel_oneplus_sm8250) `17.0` @ `078365e53`
- KernelSU-Next：`singularity-legacy-ksu342` @ `3e4677584`
- SUSFS：2.2.0，从 Singularity 移植
- 配置：从 ROM 内核的 `IKCONFIG` 提取，再叠加 KSU/SUSFS 选项
- 工具链：clang 23.1.5 / LLD
- 构建标记固定为 `zysftd@kebab`；源码在纯 ASCII 路径下编译，
  镜像内不含构建机的用户名、主机名或家目录路径

复现步骤见 [initrc-shim](https://github.com/zysftd/initrc-shim) 仓库，
补丁在 `patches/`（`0003` 是完整的 cip136 rebase）。

## 已知限制

- **只适配 cip136-st20 这一基线**。crDroid 下次升内核需要重新改基。
- `init.rc` blob 与 ROM 绑定。ROM 的 `init.rc` 变了必须用
  `./build.sh --regen-rc` 重生成。
- 未包含 Singularity 的调优（ICC 重写、OPP 降压等），因为是官方树基线。

## 感谢

- **DeepSeek** — 日志分析定位单次 `read_iter` 行为、同长度 `init.rc`
  替换方案、内核补丁、SUSFS 移植、SELinux hide 修复、构建与打包脚本
- [LineageOS](https://github.com/LineageOS/android_kernel_oneplus_sm8250) /
  [crDroid](https://github.com/crdroidandroid) — kebab 4.19 树
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — 内核内 root
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) — root 痕迹隐藏
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) — 免重打包写入
- [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) /
  [Vector](https://github.com/JingMatrix/Vector) — 用户态部分
