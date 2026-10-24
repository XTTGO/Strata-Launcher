# Strata Launcher v0.1.7.3

v0.1.7 的第三个增补补丁：完整适配 DeepSeek-V4.1-Flash 的引擎命令行。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本机 Strata `v0.2.4`（Qwen 预编译引擎 `0.1.48`）完成校验。

- **只写 dsv41 认的参数：**DeepSeek 模型保存/启动时不再写入 Qwen 引擎专用的 `--kv`、`--kv-resident`、`--vram-reserve-mib`、`--pool-workers`、`--rope-scaling`、`--rope-scale`。`strata-dsv41` 把未知参数当成致命错误（`unknown option`，退出码 2），此前用启动器保存或启动 DeepSeek 会被这一行挡住。
- **DeepSeek 自己的运行参数：**

  | 界面 | 写入 | 说明 |
  |---|---|---|
  | 上下文长度 | `--max-context` | 8192 为官方默认；更高未验证 |
  | 显存预留 MiB | `--reserve-mib` | 0 表示不写，用引擎自动 |
  | CPU 线程数 | `--cpu-threads` | 0 表示引擎自动 |
  | DSpark 草稿 | `--dspark` | auto / on / off |
  | DSpark 置信度 | `--dspark-conf` | 官方 IST-DAS 用 0.65 |
  | SSD 专家缓存 | `--ssd-cache` | 留空 = auto，也可填 GB |
  | 预填充分块 | `--prefill-chunk` | 0 = 引擎自动 |

- **原样保留：**官方 setup 写入的 `--pack`、`--eos`、`--expert-profile` 等参数不重写；`--dspark` 只出现一次。
- **隐藏不适用项：**DeepSeek 下 KV cache 格式、驻留 KV、并行请求（官方会忽略）、视觉、显卡角色分配（引擎自行安排专家分层）均不参与保存；Qwen / Qwen3.6 的设置行为不变。

验证：139 个 Python 测试、35 个 PowerShell 测试通过（新增 `Test-Strata-Launcher-DeepSeekArgs.ps1` 覆盖官方参数集的读取、Qwen 参数剔除与 `--dspark` 去重）；用临时 DeepSeek 配置打开界面，确认显示 `DSpark 草稿`、`显存预留 MiB`、`SSD 专家缓存` 等控件，且不出现 KV/并行行。**DeepSeek 的完整加载与推理仍未在本机验收**（模型共享文件与引擎尚未下载完成）。

ZIP SHA-256：`F0190DD168978C7AFE109462E68F0B2A5A5E0D573DA35B75476E9428EC38A4ED`
