## 一加 8T (kebab) — crDroid 13.x 内核，2026-11-28

基于 crDroid 官方 `17.0` 内核树重建，适配 **crDroid 17.0-20261126**。

这是「InitRC-Shim」项目的延续版本。上一版针对 11-10 的 ROM 构建
（`cip135-st19`），crDroid 在 11-26 的包里把内核升到了 `cip136-st20`，
vermagic 变化导致旧内核无法加载 `/vendor` 下的模块，因此重建。

## 包含

| 组件 | 版本 |
|---|---|
| 内核 | 4.19.325-cip136-st20-perf-g078365e5318d |
| KernelSU-Next | 3.4.2（内联，手动钩子） |
| SUSFS | 2.2.0（11 项特性全开） |
| InitRC-Shim | `ksu_rc_blob.h`，同长度替换 `init.rc` |

内核版本串与 crDroid 2026-11-26 包**完全一致**，`/vendor` 下的
`.ko`（Wi-Fi、相机、传感器）可以正常加载。

## 为什么要重建

crDroid 11-26 构建把内核从 `cip135-st19` 升到 `cip136-st20`
（合并了 `v4.19.325-cip136` 和 `lineage-24.0`）。

内核 ABI 变了，vermagic 是模块加载的硬门槛：

```
旧内核: 4.19.325-cip135-st19-perf-g66e230426430
新 ROM: 4.19.325-cip136-st20-perf-g078365e5318d   ← /vendor 模块要求
```

不匹配的后果是 Wi-Fi 打不开、相机崩溃，严重时开不了机。

## InitRC-Shim 解决什么

Android 17 的 `init` 用 `fstat()` 取文件大小，再用**单次 `read_iter()`**
读完整份 `init.rc`。KernelSU 的注入逻辑是「读到 EOF 时追加」，在这种读法下
永远不触发，而且目标缓冲区也没有多余空间。

结果（无任何报错）：

- `ksud post-fs-data` 不执行
- `modules_update/` 不生效，模块显示已装但实际未激活
- Zygisk 不 attach 到 zygote（`znctl status` → `Could not connect`）

本内核改为**整文件替换**：把 `init.rc` 的注释行换成 ksud 的 `exec` 行，
再补注释把长度填回原值。init 按 `fstat()` 的字节数读，解析行为不变，
但能读到三行额外的 `exec`。

```
read init.rc, comm: init, has_read=0 has_read_iter=1
read_iter_proxy: served blob ret=58444 pos=58444
```

## 产物

`ak3-kebab-cip136-ksu-shim-20261128.zip` — 24,961,893 字节

```
sha256: 69ee9bdee302198c450a0d420a41eaab7541c6775fb25031d1f71b67cd2cc07b
```

## 安装

**前提**：已刷 crDroid 17.0-20261126（或其内核仍为 `cip136-st20` 的版本），
bootloader 已解锁。

```bash
adb reboot recovery
# recovery → Apply update → Apply from ADB
adb sideload ak3-kebab-cip136-ksu-shim-20261128.zip
# 重启
```

首次开机会慢（3–10 分钟），这是 ART 重新编译，**不要强制关机**。

## 验证

```bash
adb shell uname -r
# 4.19.325-cip136-st20-perf-g078365e5318d

adb shell su -c id
# uid=0(root)

adb shell dmesg | grep 'init.rc read hook'
# comm=init read=0 read_iter=1

adb shell ls /data/adb/modules
# 模块应处于启用并挂载状态
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
- 配置：从 ROM 内核 `IKCONFIG` 提取（`/proc/config.gz` 等价），
  再叠加 KSU/SUSFS 选项
- 工具链：clang 23.1.5 / LLD
- 构建标记固定为 `zysftd@kebab`；源码在纯 ASCII 路径下编译，
  镜像内不含构建机的用户名、主机名或家目录路径

复现步骤见 [initrc-shim](https://github.com/zysftd/initrc-shim) 仓库，
补丁在 `patches/`。

## 已知限制

- **只适配 cip136-st20 这一基线**。crDroid 下次升内核需要重新改基。
- `init.rc` blob 与 ROM 绑定。ROM 的 `init.rc` 变了（本次没变，仍是
  58444 字节）必须用 `./build.sh --regen-rc` 重生成。
- 未包含 Singularity 的调优（ICC 重写、OPP 降压等），因为是官方树基线。

## 感谢

- **DeepSeek** — 日志分析定位单次 `read_iter` 行为、同长度 `init.rc`
  替换方案、内核补丁、构建与打包脚本
- [LineageOS](https://github.com/LineageOS/android_kernel_oneplus_sm8250) /
  [crDroid](https://github.com/crdroidandroid) — kebab 4.19 树
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — 内核内 root
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) — root 痕迹隐藏
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) — 免重打包写入
- [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) /
  [Vector](https://github.com/JingMatrix/Vector) — 用户态部分
