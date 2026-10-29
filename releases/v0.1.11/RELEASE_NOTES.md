# Strata Launcher v0.1.11

适配 Strata 官方 `v0.2.7.1` 源码安装版，支持 Qwen 和 DeepSeek 的 0.1.52 引擎功能。分享包供已安装 Strata 的 Windows 用户使用，不包含 Strata 引擎、模型或 Python 环境。

- **新版速度开关：**按模型、引擎和显卡显示 Qwen 长提示、12 GB NVIDIA、Radeon RX 9000 与 DeepSeek 加速选项；未修改的开关保持引擎默认值和已有配置。
- **DeepSeek 图像输入：**引擎达到 0.1.52 且模型包包含视觉塔时可配置；保存为 `--vision on/off`，旧版引擎和纯文本模型包不会收到不适用的参数。
- **稳定版更新：**官方源码更新只跟随最新稳定 Release 及同系列补丁标签，不依赖本机 `main` 的 upstream，也不会拉取未发布的上游 `main`。
- **引擎更新校验：**先比较签名源所提供的版本，已最新时不重复替换；检查、下载或安装失败时明确报错，并核对最终版本。

验证：41 个 PowerShell 与 139 个 Python 测试通过；本机 Strata `v0.2.7.1` 的运行目录 `-CheckOnly` 就绪，Qwen 引擎兼容性 `-VerifyOnly` 通过。同步复制 39 个文件、删除 0 个。

验证边界：本机安装的 Qwen 引擎为 `0.1.50`、DeepSeek 引擎为 `0.1.51`。本次未安装官方 `0.1.52` 引擎，未实测新引擎的图像推理或速度收益；当前 DeepSeek 模型包也未包含视觉塔。

ZIP SHA-256：`731CDD0D940F3553D8818D0C6E8D987424494BD34ED918494E888ED43ED9B208`
