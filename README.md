# Strata Launcher

**为已经安装 Strata 的 Windows 用户提供图形化启动、模型设置和批量 Benchmark。**

最新正式版：**v0.1.12** · 针对 **Strata v0.2.7.1** 完成启动器兼容性校验 · [安装包下载](https://github.com/XTTGO/Strata-Launcher/releases/tag/v0.1.12)

v0.1.12 修复「更新引擎（Qwen）」在替换前核对签名暂存版本时的引号丢失：PowerShell 把交给 `python.exe` 的参数内层双引号删掉，Python 于是读到 `setup.home() / engine-feed` 并报 `NameError`，更新被误报成"暂存版本与官方不一致"而没有替换引擎（下载和验签其实已成功）。v0.1.11 对齐官方 0.2.7.1 的 Qwen / DeepSeek 引擎功能：按硬件和模型提供新版速度开关，DeepSeek 图像输入会检查引擎版本与模型包视觉塔；更新器只跟随官方稳定版标签，并在引擎更新时核对签名源与安装版本。本机已用修复后的入口把 Qwen 引擎升到 0.1.52 并真实启动模型（`/health` 报 `loaded: true`），但新版图像与速度收益没有做对照验收。

> 启动器依赖已有的 Strata 安装。打包版不包含模型、Strata 引擎或 Python 环境；官方 App 和独立 Terminal 的安装方式暂不支持。

## 界面预览

### 主界面

选择模型、调整生成参数并保存设置，或从同一窗口启动 Strata。

![Strata Launcher v0.1.5 主界面：模型选择和生成参数](docs/images/launcher-main-v0.1.5.png)

<sub>v0.1.5 实际界面截图。图中的模型名称和配置路径来自截图电脑，不随启动器分发。</sub>

### 运行设置与工具

在主界面下方设置局域网访问和 NVIDIA 显卡功率，并打开 Strata 官方工具。

![Strata Launcher 运行设置与工具界面，局域网 IP 地址已遮盖](docs/images/launcher-runtime-tools-v0.1.4-redacted.png)

<sub>v0.1.4 实际界面截图；两处局域网 IP 地址已遮盖。v0.1.5 的界面以程序实际显示为准。</sub>

### 批量 Benchmark

选择模型、预设、上下文上限和测试项目；运行后可查看本机生成的对比报告。

![Strata Launcher v0.1.5 批量 Benchmark 界面：模型、测试规模和项目选择](docs/images/benchmark-v0.1.5-opaque.png)

<sub>v0.1.5 实际界面截图。截图仅展示测试设置，没有启动 Benchmark。</sub>

## 快速开始

1. 在 Windows 10 或 11 上，通过 Strata 的 `START-HERE.bat` 完成源码安装，并安装至少一个模型。
2. 从 [v0.1.12 Release](https://github.com/XTTGO/Strata-Launcher/releases/tag/v0.1.12) 下载 `Strata-Launcher-v0.1.12-for-existing-install.zip`。
3. 解压后，将整个 `launcher` 文件夹放进 Strata 根目录，与 `START-HERE.bat` 并列。
4. 双击 `launcher\Strata-Launcher.bat`。

```text
<Strata 根目录>\
├─ START-HERE.bat
├─ serve\
├─ engine\
├─ strata-模型名.json
└─ launcher\
   └─ Strata-Launcher.bat
```

首次打开时会检查 Strata 目录、Python 环境、引擎和模型配置；缺少必需文件时会列出问题。

## 主要功能

- **模型与参数：**切换本机模型，调整生成参数、上下文、显存和视觉选项，并保留配置中未展示的字段。
- **模型列表刷新：**检查配置引用的 GGUF 和专家包；组件缺失时暂时隐藏该模型，保留官方配置，文件恢复后可再次刷新。
- **引擎版本检查：**官方预编译引擎对照 `setup.py` 的 `MIN_ENGINE` 兼容下限；本地编译引擎还对照源码构建目标。旧引擎显示警告并可继续启动，安装信息缺失时提示先检查更新。
- **新版引擎选项：**Qwen 长提示加速、部分 NVIDIA / Radeon 显卡回答加速和 DeepSeek 加速按适用条件显示；DeepSeek 图像输入还要求模型包含视觉塔。控件在对应 0.1.52 引擎安装前保持禁用。
- **官方更新（仓库开发版）：**始终以官方最新稳定 Release 及其同系列补丁标签为源码目标，使用 Git 快进更新；`main` 是否设置 upstream 不影响版本选择。源码目录需保留 Git 检出，非 Git 源码副本会明确提示手动迁移稳定版。随后运行官方安装更新；若预编译引擎低于兼容下限，再调用官方签名更新源，并核对 `BUILD.json` 与可执行文件版本。分支冲突会安全停止。
- **更新引擎（Qwen / DeepSeek）：**官方更新只在引擎低于兼容下限时才替换，所以新版本随附的引擎不会自动到已装机器上。两个按钮各自从官方签名更新源取最新引擎：Qwen 用 `engine_from_feed`（Ed25519 签名、逐文件哈希、试启动通过后才替换，旧引擎留在 `engine\.previous`，可 `--rollback-engine` 回退），DeepSeek 用官方安装流程末尾同一个 `upgrade_dsv41_engine`（只跑 `strata-dsv41 --version` 试启动，只保留一代）。传输中断会自动续传；引擎文件被占用时直接报错，不会半途替换。
- **启动与管理：**保存设置后启动或停止本机 Strata；局域网访问和 NVIDIA 显卡功率设置均为可选操作。
- **批量 Benchmark：**按预设测试性能、缓存、Agent、长上下文召回和并发等项目；使用报告目录中的配置副本，不修改日常模型 JSON。
- **本机报告：**在 `launcher\reports` 保存 HTML 报告、原始结果和配置快照。

## 文档与验证

- [详细安装与功能说明](README.txt)
- [发布规则（怎么发一个版本）](docs/RELEASE.md)
- [版本更新记录](CHANGELOG.md)
- [v0.1.12 发布说明与 SHA-256](releases/v0.1.12/RELEASE_NOTES.md)
- [v0.1.11 发布说明与 SHA-256](releases/v0.1.11/RELEASE_NOTES.md)
- [v0.1.10 发布说明与 SHA-256](releases/v0.1.10/RELEASE_NOTES.md)
- [v0.1.9 发布说明与 SHA-256](releases/v0.1.9/RELEASE_NOTES.md)
- [v0.1.8 发布说明与 SHA-256](releases/v0.1.8/RELEASE_NOTES.md)

v0.1.12 的发布验证范围见对应发布说明；本机 Strata v0.2.7.1 已安装 Qwen 引擎 `0.1.52`（旧引擎留在 `engine\.previous`）和 DeepSeek 引擎 `0.1.52`，模型已在 0.1.52 上真实启动，新版图像与速度收益未做对照验收。
