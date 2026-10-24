# Strata Launcher v0.1.7.1

v0.1.7 的增补补丁：本地模型导入支持 DeepSeek-V4.1-Flash（`deepseek41`，官方 IST-DAS 1.75 / 2.00 / 2.25 bpw 与 Unsloth UD-Q8_K_XL）。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本机 Strata `v0.2.4`（Qwen 预编译引擎 `0.1.48`）完成校验。官方 App 和独立 Terminal 的安装方式暂不支持。

- **DeepSeek 导入预检：**“导入本地模型”现在按官方分片文件名识别多文件模型族（如 `DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00001-of-00004.gguf`），核对分片是否齐全、大小是否与官方一致，再交给官方 setup 继续校验，并由它下载共享文件（Engram、DSpark 草稿、元数据分片）和 DeepSeek 专用引擎。
- **修复：**此前预检只认识单文件族，选择 DeepSeek 分片目录会直接报“没有匹配的 GGUF 文件名”，官方 setup 根本不会启动；本版修复该误报。
- **兼容：**单文件族（Qwen3.8、Swift、Unsloth、Qwen3.6）的识别与校验逻辑不变，原有模型目录的预检结果不变。
- **版本号：**启动器版本号现在允许 `0.1.7.1` 这样的四段增量版本，打包脚本的校验同步放宽。

验证：139 个 Python 测试、34 个 PowerShell 测试和 ZIP 内容核对通过；用本机 DeepSeek-V4.1-Flash IST-DAS 2.00bpw 的 4 个分片目录实测，预检输出 `deepseek41 / IST-DAS-2.00bpw`（4 个分片）。199 GB 级的共享文件与引擎仍由官方 setup 下载，本版不改变官方下载流程，也未在本机完成 DeepSeek 的完整推理验收。

ZIP SHA-256：`FD659A295D7168E2727D6BC006C47C511508E73EC0221878619A9D0CB68A0ED2`
