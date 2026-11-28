## 一加 8T (kebab) — crDroid 13.x 内核，2026-11-28 (v1.1.1)

基于 crDroid 官方 `17.0` 内核树，适配 **crDroid 17.0-20261126**。

**这是 v1.1.0 的修正版**：修复了 SELinux 隐藏失效的问题。

## 相比 v1.1.0 改了什么

v1.1.0 在 rebase 时，为了绕过 KernelSU-Next 3.4.2 移除的旧 API
`ksu_selinux_hide_state_for_current()`，在内核树里加了一个直接 `return NULL`
的占位实现。这个 stub 让 **SELinux 隐藏完全失效**，导致普通应用探测能直接
看到 KSU 专属的 SELinux context。

本版删除：

- `security/selinux/hooks.c` 中的 `ksu_selinux_hide_state_for_current()` stub
- `security/selinux/selinuxfs.c` 中的 extern 声明和 3 处调用
  （`sel_read_handle_status`、`sel_read_handle_unknown`、`sel_read_policy`）

KernelSU-Next 3.4.2 早已改用新机制：`ksu_selinux_hide_init()`
（由 `core/init.c` 调用）通过 `ksu_patch_fops_slot()` 直接 patch 三处
`file_operations`：

| 目标 | 作用 |
|---|---|
| `/proc/<pid>/attr/current` 的 `write` | 拦截 context 写入探测 |
| selinuxfs 的 `write` | 拦截 policy/context 查询 |
| status 节点的 `open` | 返回伪造的 status page |

`ksu_selinux_hide_enabled` 默认 `true`，且仅在 `uid >= 10000`（普通应用）
生效——正好覆盖安全检查类应用常用的探测路径。

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

`ak3-kebab-cip136-ksu-shim-20261128b.zip` — 24,962,346 字节

```
sha256: ef514d5e0f5a8f945bf16adbfa04c2e044dfb12297b46511c2c2e758bdc328e0
```

## 安装

**前提**：已刷 crDroid 17.0-20261126（或其内核仍为 `cip136-st20` 的版本），
bootloader 已解锁。

```bash
adb reboot recovery
# recovery → Apply update → Apply from ADB
adb sideload ak3-kebab-cip136-ksu-shim-20261128b.zip
# 重启
```

首次开机会慢（3–10 分钟），这是 ART 重新编译，**不要强制关机**。

## 验证

```bash
adb shell uname -r
# 4.19.325-cip136-st20-perf-g078365e5318d

adb shell cat /proc/version
# ... (zysftd@kebab) ... #2 SMP PREEMPT ...

adb shell su -c id
# uid=0(root) —— 需先在 KernelSU-Next 管理器授权
```

SELinux 隐藏是否生效，用安全检测类应用重新扫描对比：KSU 专属 context
（`u:r:ksu:s0`、`u:object_r:ksu_file:s0`）不应再被 app 探测识别。

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
- **内核侧管不到的两类痕迹**：用户态日志泄漏（如 Zygisk 自己的 logcat
  输出）和 Binder 广播行为（如应用被 HMA 从 PackageManager 隐藏但仍
  发送广播）。SUSFS 的 `SUS_PATH` 只覆盖文件路径。

## 感谢

- **DeepSeek** — 日志分析定位单次 `read_iter` 行为、同长度 `init.rc`
  替换方案、内核补丁、SUSFS 移植、构建与打包脚本
- [LineageOS](https://github.com/LineageOS/android_kernel_oneplus_sm8250) /
  [crDroid](https://github.com/crdroidandroid) — kebab 4.19 树
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — 内核内 root
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) — root 痕迹隐藏
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) — 免重打包写入
- [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) /
  [Vector](https://github.com/JingMatrix/Vector) — 用户态部分
