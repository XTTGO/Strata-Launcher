# Strata Launcher

**为已经安装 Strata 的 Windows 用户提供图形化启动、模型设置和批量 Benchmark。**

最新正式版：**v0.1.10** · 针对 **Strata v0.2.6 / 引擎 0.1.50 / DeepSeek 0.1.51** 完成校验 · [安装包下载](https://github.com/XTTGO/Strata-Launcher/releases/tag/v0.1.10)

v0.1.10 修掉引擎升级后的一个启动坑：官方把 DeepSeek 引擎装到新的版本目录并删掉旧目录，而模型配置记的是绝对 `exe` 路径——升级时若启动器窗口已经开着，它的「保存并启动」会把旧路径写回，模型随后启动失败（`FileNotFoundError: [WinError 2]`）。现在启动器**打开时**和**保存前**都会把指向已删除引擎目录的配置改到已安装的那一份（只改 `engine-dsv41` 的路径，能用的配置与 Qwen 引擎不碰）。v0.1.9 的两个引擎更新入口（Qwen 走官方签名源、DeepSeek 走官方升级函数，含断流续传）都在这一版里。

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
2. 从 [v0.1.10 Release](https://github.com/XTTGO/Strata-Launcher/releases/tag/v0.1.10) 下载 `Strata-Launcher-v0.1.10-for-existing-install.zip`。
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
- **官方更新：**有上游分支时快进更新；没有上游时跟随官方最新稳定 Release。随后运行官方安装更新；若预编译引擎低于兼容下限，再调用官方签名更新源，并核对 `BUILD.json` 与可执行文件版本。分支冲突会安全停止。
- **更新引擎（Qwen / DeepSeek）：**官方更新只在引擎低于兼容下限时才替换，所以新版本随附的引擎不会自动到已装机器上。两个按钮各自从官方签名更新源取最新引擎：Qwen 用 `engine_from_feed`（Ed25519 签名、逐文件哈希、试启动通过后才替换，旧引擎留在 `engine\.previous`，可 `--rollback-engine` 回退），DeepSeek 用官方安装流程末尾同一个 `upgrade_dsv41_engine`（只跑 `strata-dsv41 --version` 试启动，只保留一代）。传输中断会自动续传；引擎文件被占用时直接报错，不会半途替换。
- **启动与管理：**保存设置后启动或停止本机 Strata；局域网访问和 NVIDIA 显卡功率设置均为可选操作。
- **批量 Benchmark：**按预设测试性能、缓存、Agent、长上下文召回和并发等项目；使用报告目录中的配置副本，不修改日常模型 JSON。
- **本机报告：**在 `launcher\reports` 保存 HTML 报告、原始结果和配置快照。

## 文档与验证

- [详细安装与功能说明](README.txt)
- [发布规则（怎么发一个版本）](docs/RELEASE.md)
- [版本更新记录](CHANGELOG.md)
- [v0.1.10 发布说明与 SHA-256](releases/v0.1.10/RELEASE_NOTES.md)
- [v0.1.9 发布说明与 SHA-256](releases/v0.1.9/RELEASE_NOTES.md)
- [v0.1.8 发布说明与 SHA-256](releases/v0.1.8/RELEASE_NOTES.md)
- [v0.1.7.5 发布说明与 SHA-256](releases/v0.1.7.5/RELEASE_NOTES.md)

v0.1.10 的发布验证记录见对应发布说明：40 个 PowerShell 与 139 个 Python 测试通过；本机 Strata v0.2.6 的 Qwen 引擎由 `0.1.48` 升到 `0.1.50`、DeepSeek 引擎由 `0.1.49.2` 升到 `0.1.51` 并真实启动成功（`/health loaded: true`）；把 DeepSeek 配置故意改回已删除的引擎目录后再打开启动器，路径被自动修正。
