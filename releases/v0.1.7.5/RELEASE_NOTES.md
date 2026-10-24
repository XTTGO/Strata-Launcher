# Strata Launcher v0.1.7.5

DeepSeek-V4.1-Flash 的完整接入版本：与 Qwen 模型共用同一个启动器，按当前模型自动切换规则；适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata。本机 Strata `v0.2.4.2`、Qwen 引擎 `0.1.48`、DeepSeek 引擎 `0.1.49.2` 完成校验。

- **双引擎识别：** 按 `arch == deepseek41` 或 `engine-dsv41` 的 exe 路径识别 DeepSeek；环境检查允许“只有 DeepSeek 引擎”的安装；主界面版本行显示所选模型的引擎（如 `DeepSeek 引擎 0.1.49.2`）。
- **导入：** 本地导入预检识别 DeepSeek 的多文件分片与共享文件（Engram、DSpark、元数据分片），按官方固定大小核对后再交给官方 setup。
- **运行参数：** 只写 `strata-dsv41` 支持的项——`--max-context`、`--reserve-mib`、`--cpu-threads`、`--dspark`、`--dspark-conf`、`--ssd-cache`、`--prefill-chunk`、`--tp`；剔除 Qwen 专用的 `--kv`、`--kv-resident`、`--vram-reserve-mib`、`--pool-workers`、`--rope-*`；官方写入的 `--pack`、`--eos`、`--expert-profile` 原样保留。
- **多卡：** 勾选参与推理的显卡（写配置 `gpu`，服务器据此设置 `CUDA_VISIBLE_DEVICES`），选择 `--tp`（自动 / 1 / 2）；不写 Qwen 的 `gpu_roles` / `layer_split`。
- **上下文：** 8K（官方默认）、16K、32K、64K（模型原生）、128K–1M（YaRN ×2–×16，均标未验证）；引擎 `--max-context` 不设上限，KV 占用随上下文增长。
- **停止服务：** 进程树同时识别 `engine\strata.exe` 与 `engine-dsv41\<版本>\strata-dsv41.exe`。
- **性能入口：** 原“保存并校准”对 DeepSeek 变为「官方调优」（`tools/dsv41/tune.py --config <配置> --mode quick`，等同 `strata launch --tune quick`）；新增「规划预测」（`strata launch --model <规格> --family deepseek41 --data-dir <数据> --plan`，只读）。
- **明确禁用：** DeepSeek 下 Qwen 口径的批量 Benchmark、视觉、并行请求均禁用并写明原因。
- **官方更新：** 无上游分支时也会采用带发布说明的最新官方标签（例如 `v0.2.4.2`），不再被“Release 页面仍是 v0.2.4”卡住。
- **显示：** 模型标签显示 `DeepSeek-V4.1-Flash`，多套时自动加配置名后缀。

验证：139 个 Python 测试、37 个 PowerShell 测试通过；`-CheckOnly` 输出 `deepseek_engine_version: 0.1.49.2`；本机 DeepSeek 官方导入（4 个分片 + 共享文件）与 16 token 冒烟测试通过。**启动器内的完整加载、长对话与停止未做完整验收；Monitor 悬浮窗尚未在 dsv41 上实测。**

ZIP SHA-256：`4FBD366D814BB49E0C4BA821EA1553A2BFA75129491133A660FEA22306AD274E`
