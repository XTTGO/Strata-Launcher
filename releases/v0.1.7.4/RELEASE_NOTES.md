# Strata Launcher v0.1.7.4

v0.1.7 的第四个增补补丁：修正 DeepSeek 参数保存时的默认值行为，并补齐 `user_args` 同步。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本机 Strata `v0.2.4`（Qwen 预编译引擎 `0.1.48`）完成校验。

- **不擅自补默认值：**官方配置没有 `--dspark-conf` 时（例如 Unsloth UD-Q8_K_XL），启动器不再自动写 0.65；该行留空即保留官方值/引擎默认。显存预留、CPU 线程、预填充分块为 0 时同样不写参数，`--ssd-cache` 留空或填 `auto` 也不写。
- **输入校验：**DSpark 置信度只接受 0–1，SSD 缓存只接受 GB 数字（或留空），填错会明确报错，不会把无效值写进官方配置。
- **`user_args` 同步：**DeepSeek 的 `--dspark`、`--dspark-conf`、`--reserve-mib`、`--cpu-threads`、`--ssd-cache`、`--prefill-chunk` 纳入保存同步；官方配置里原有这些覆盖项时，启动器修改后会覆盖旧值，避免“界面改了但启动仍用旧值”。
- **保留未编辑的引擎参数：**`--pack`、`--eos`、`--expert-profile`、`--tp`、`--vram-experts`、`--ssd-policy`、`--mmap-experts` 等启动器没有编辑的项原样保留。

关于“支持哪些命令”：`strata-dsv41` 自身还有 `--ssd-policy`、`--mmap-experts`、`--vram-experts`、`--threads`、`--dspark-block`、`--no-expert-cache` 等高级/调试开关，以及 `--ids`、`--score`、`--profile-run` 等基准用途开关；本启动器只把常用运行参数放上界面，其余保持透传，不删除、不改写。

验证：139 个 Python 测试、35 个 PowerShell 测试通过；新增用例覆盖“缺失的 `--dspark-conf` 保持缺失”“`--tp` 与 `--vram-experts` 保留”“user_args 从旧值同步到新值”；用临时 DeepSeek 配置打开界面，确认 DSpark 置信度与 SSD 缓存默认为空、KV 行不存在。**DeepSeek 的完整加载与推理仍未在本机验收。**

ZIP SHA-256：`B6682BDDF486619881FC3D0F6DB1DA0149300284F6ACA3E00A6CAF8673C36D50`
