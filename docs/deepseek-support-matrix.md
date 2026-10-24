# DeepSeek 支持矩阵（启动器 v0.1.7.5-dev.1）

本机 Strata `v0.2.4` 同时存在两个引擎，启动器按当前模型配置识别，互不干扰：

| 引擎 | 可执行文件 | 配置识别 |
|---|---|---|
| Qwen / Flash-Next | `engine\strata.exe` | 默认分支；`arch` 为 `qwen` / `qwen35moe` 等 |
| DeepSeek-V4.1-Flash | `engine-dsv41\strata-dsv41.exe` | `arch == deepseek41`，或 `exe` 含 `engine-dsv41` / `strata-dsv41` |

新增模型时必须走官方 `START-HERE.bat --setup`；启动器只读写官方写出的配置，不改官方文件。

## 功能对照

| 启动器功能 | DeepSeek 状态 | 说明 |
|---|---|---|
| 本地模型导入预检 | ✅ 支持 | 识别 `deepseek41` 多文件族；按官方固定大小核对分片；共享文件（Engram、DSpark、元数据分片）可同目录 |
| 上下文长度 | ✅ 支持 | `--max-context`；官方默认 8192，模型 64K 原生、YaRN ×16 到 1M（更大均为未验证） |
| 显存预留 | ✅ 支持 | 写入 `--reserve-mib`（Qwen 的 `--vram-reserve-mib` 不适用） |
| CPU 线程数 | ✅ 支持 | 写入 `--cpu-threads`（Qwen 的 `--pool-workers` 不适用） |
| DSpark 草稿 | ✅ 支持 | `--dspark auto/on/off`，`--dspark-conf` 0–1；官方没写时不补默认值 |
| SSD 专家缓存 | ✅ 支持 | `--ssd-cache`；留空 = 引擎自动 |
| 预填充分块 | ✅ 支持 | `--prefill-chunk`；0 = 引擎自动 |
| 张量并行 | ✅ 支持 | `--tp`：自动（引擎默认，2 卡及以上为 2）/ 1 / 2 |
| 多卡选择 | ✅ 支持 | 勾选参与推理的显卡 → 配置 `gpu` 列表；服务器据此设置 `CUDA_VISIBLE_DEVICES`；不写 Qwen 的 `gpu_roles` / `layer_split` |
| 模型切换 | ✅ 支持 | 每个配置独立加载；切换后重新识别引擎 |
| 采样 / 思考强度 / 预设 | ✅ 支持 | 服务端参数，与引擎无关 |
| 局域网 / 端口 / API key | ✅ 支持 | 与模型无关 |
| 停止服务 | ✅ 支持 | 进程树同时识别 `strata.exe` 与 `strata-dsv41.exe` |
| Monitor 悬浮窗 | ⚠️ 待实测 | 读官方遥测接口，代码与模型无关 |
| GPU 功率 | ✅ 支持 | 系统级，与模型无关 |
| 性能校准 | ⛔ 禁用 | 启动器校准是 Qwen 口径；DeepSeek 用官方 `strata launch --tune`（`tools/dsv41/tune.py`） |
| 批量 Benchmark | ⛔ 排除 | Benchmark 的上下文档位、Needle、并发假设是 Qwen 口径；DeepSeek 模型不再出现在列表里 |
| 视觉 / 并行请求 | ⛔ 禁用 | 官方明确忽略（`--vision` / `--parallel`） |
| 使用 KG / MTP / DFlash2 | ⛔ 不适用 | dsv41 没有这些概念 |

## 多卡规则（官方依据）

- `docs/DEEPSEEK41.md`：引擎自行决定每张卡的专家数量，放不下的在 CPU 上算；`--tp` 在两张及以上卡时默认 2（成对共享每层矩阵）。
- `strata_control/dsv41_fit.py`：`tp_for()` 对 4 张及以上 **AMD** 卡给 1（纯层切分实测更快），2–3 卡保持 2；`_tp_args()` 只在 `tp<2` 且卡数 ≥2 时显式写 `--tp`。
- `serve/server.py`：`gpu_list(cfg)` 取配置的 `gpu`（或 `gpu_roles`），据此设置 `CUDA_VISIBLE_DEVICES` / `HIP_VISIBLE_DEVICES`；DeepSeek 引擎看到几张卡就自己分层。
- 因此启动器对 DeepSeek 只写两样：参与推理的卡（`gpu`）和可选的 `--tp`，并删除配置里可能残留的 `gpu_roles`、`gpu_order`、`gpu_cards`、`layer_split`。

## 仍待办

1. `engine-dsv41` 版本检查（目前 `-CheckOnly` 只报 Qwen 引擎版本）。
2. Monitor 悬浮窗在 dsv41 上的实测。
3. DeepSeek 导入后的完整加载 / 推理验收（依赖 118 GB 共享文件与引擎下载）。
4. 模型显示标签：官方清单没有 DeepSeek 条目，目前回退到 `model_name` + 配置名后缀。
