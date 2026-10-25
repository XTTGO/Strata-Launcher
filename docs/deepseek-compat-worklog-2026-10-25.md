# DeepSeek 兼容与官方参数预设：开发记录（2026-10-25）

此文档用于后续 agent 接手。记录的是当前开发分支的实际状态；验证结论与待办分开列出。用户本轮要求：优先彻查 DeepSeek 启动代码，修复或屏蔽不支持的参数；然后引入官方参数预设，并严格区分 DeepSeek 与 Qwen 两套引擎。用户此前明确只讨论官方 Terminal/CLI 能力，不纳入仅 App 提供的功能。

## 工作位置与边界

- 开发源：`D:\AI\Strata-Launcher`，分支 `codex/deepseek-compat-presets`，从 `main` 的 `5543b1f` 建立。本轮仅在开发分支提交，未推送、未发布。
- 本机 Strata 源与安装：`D:\AI\Strata`；本次以官方仓库 `v0.2.5` tag 的 `serve/server.py`、`docs/DEEPSEEK41.md`、`docs/TERMINAL_LAUNCH.md`、`strata_cli/launch/cmd.py` 以及引擎解析代码为准。该本地源码 HEAD 比 tag 领先 6 个提交，不能把 HEAD 的 CLI 参数直接当作 v0.2.5 的能力。
- 实际运行副本 `D:\AI\Strata\launcher`、现有模型 JSON、模型权重均未更新。本机 `-CheckOnly` 在开发源识别到 Strata `v0.2.4.2`、Qwen 引擎 `0.1.48`、DeepSeek 引擎 `0.1.49.2`。没有进行真实模型加载或显存验收。
- 工作开始前已有未跟踪文件 `docs/strata-v0.2.5-presets-and-launcher-gap.md`、`docs/superpowers/verification/2026-10-24-*` 与 `tools/`，本次没有改动它们。不要在提交时顺手包含这些文件。

## 已修改的代码

### DeepSeek 启动与参数

- `Strata-Launcher-Settings.ps1`：集中定义已知 Qwen 专用 flags；DeepSeek 保存时从 `args`/`user_args` 去除这些 flags 和会向 DeepSeek 注入错误参数的配置字段，保留 `--pack`、`--eos`、`--tp` 等 DeepSeek 支持的项。若未编辑 GPU 选择，保留服务端仍会使用的 `gpu_roles`/`gpu_cards`/`gpu_order`；用户显式改卡时由现有 `Set-StrataDeepSeekGpuConfig` 改写为 `gpu` 并移除旧角色信息。
- `--max-context` 缺失时，DeepSeek UI 初值改为官方 8192，而 Qwen 保持原家族值。`--dspark none` 现可选择；与 `off` 不同，`none` 不加载草稿权重。`--ssd-cache auto` 不再作为字面参数写给旧引擎，留空即不写该参数。取消启动器自行计算显式 RAM 缓存容量的“尽可能快”预设，保留引擎自动容量、可选 LFU 淘汰策略、关闭 RAM 缓存三种清晰选择。缓存预设只改缓存容量与淘汰策略，不重置 GPU 专家份额、mmap 模式或已经调优的 DSpark 草稿块。
- `--experts 5/6` 增加 Faster/Full 控件，但只按**当前配置所指向的可执行文件版本**启用；本机配置的 `0.1.49.2` 不支持，保存不会写 `--experts`。仅 `0.1.50+` 允许。`--tp` 的现有自定义值（如 4）不再因打开 UI 而丢失，DSpark block 上限与引擎的 16 对齐。
- DeepSeek 的 NVIDIA 勾选状态以 UI 实际初始状态为保存比较基准；未检测到 NVIDIA（例如 AMD）或未改卡时保留现有 GPU 配置，避免保存普通设置时误写 GPU 列表。

### 生成参数与官方模型卡

- 加入 `deepseek41`、`qwen4exp`（Qwen3.8）、`qwen35moe`（Qwen3.6）的独立模型卡采样数据。DeepSeek thinking/instruct 都是 `temperature=1.0, top_p=1.0`，模型卡不指定 `top_k` 或惩罚项；Qwen3.8 thinking 为 `1.0/.95/20`，instruct 为 `.7/.8/20` 且 presence penalty `1.5`；Qwen3.6 thinking 还带 presence penalty `1.5`。这与本地官方 `serve.server.model_card_sampling()` 返回值核对过。
- 使用预设新增“官方默认”：保存时清除旧的模型采样覆盖和共享默认覆盖，让服务端选当前家族模型卡。另三个预设按家族写值。DeepSeek 隐藏且不再保存引擎会忽略的 presence/repetition/frequency/last-n 惩罚设置。
- “思考预算”分成未设置、显式 `0`（取消固定预算）、正数上限。DeepSeek 未设置由服务端使用其默认预算；过去的 UI 把显式 0 删除，现已区分。
- 配置文件与 shared settings 的 `reasoning_effort` 仅允许 `none/low/medium/high`。DeepSeek 文档中的 `max` 与整数 `1..100` **只适用于 API 请求**；官方 `clean_shared_defaults()` 不接受它们作为保存的默认值。启动器 UI 明确显示这条边界。
- shared settings 保存改为保留未知字段、清除旧的受管理覆盖（包括 `experimental_speed_projection`），并与选择的家族预设同步。UI 载入采样值优先显示 shared settings，因为服务端的覆盖顺序是“模型卡 → 模型 JSON → shared → 请求”。

### Qwen 审核中顺带修正

- Qwen KV 格式新增官方默认 `fp16`；若不显式选择量化，保存不写 `--kv`。
- `--kv-resident` 未设置时保持关闭；移除 UI 原有的 8192/16384 选项，因为官方引擎实际最小驻留值为 20480。旧配置低于此值时 UI 显示其实际生效的 20480；更大的自定义值保留。
- 未设置 `--vram-reserve-mib` 时保留引擎默认，不再自动写入启动器原来的 990。并发选项扩到 1–8，现有大于 8 的合法值也可保留；DeepSeek 仍禁用并移除并发。

## 已核对的启动路径与官方边界

- 现有 `Strata-Launcher-Lan.ps1` 用 `python serve/server.py --engine strata --config <模型 JSON> --port ... --host ...` 启动。`--engine strata` 对 DeepSeek 和 Qwen 都正确，实际引擎由配置里的 `arch`/`exe` 选择。无需改写为官方 App 的内部流程。
- 本机 `strata-dsv41.exe --help/--version` 返回 `0.1.49.2`；直接探测 `--experts 5` 返回 `unknown option --experts`，验证版本门槛确实必要。
- 官方 `docs/DEEPSEEK41.md` 说明该版本 DeepSeek 不支持同时处理多个请求与图片；启动器继续禁用其并发和视觉入口。
- “最快”没有适用于所有机器的固定 RAM 容量。新版 DeepSeek 自动缓存以可用 RAM/模型大小决定容量；固定数字会覆盖该逻辑。官方调优入口仍在启动器中，性能选择需要在目标机实测。

## 已执行的验证

- 开发源 `Strata-Launcher.ps1 -CheckOnly`：通过，报告 `ready=true`、3 个可用模型配置。
- `tests/Test-Strata-Launcher-DeepSeekArgs.ps1`、`UsagePresets.ps1`、`NativeContext.ps1`：针对新增行为均已见到先失败后通过。还执行过 `Sampling.ps1`、`UserArgs.ps1`、GPU 相关测试，均通过。
- `Run-Launcher-Tests.py --strata-root D:\AI\Strata`：在最终 UI/GPU 细节调整后重跑，139 个 Python 测试通过。DeepSeek 参数、DeepSeek 引擎、家族预设、Qwen 原生上下文、采样、`user_args`、GPU 布局与 GPU UI 的 8 组 PowerShell 定向测试也全部通过。
- 31 个 PowerShell 测试初轮：24 个直接通过；7 个测试假定工作目录下存在 `launcher/`，开发源目录布局不符合该前提。针对这 7 个，6 个用临时自引用测试路径运行通过；`LanUi` 在该路径下因环境根目录识别不匹配失败，随后用开发源真实路径适配同一 UI 测试，**通过**。临时 junction 与探针脚本已清理。该失败不是 LAN 功能回归。
- 官方 `serve.server.clean_shared_defaults()` 接受本次写出的 `high`、`temperature=1`、`top_p=1`、`reasoning_budget_tokens=0`；官方 `model_card_sampling()` 三个家族的返回值已核对。`git -c core.whitespace=cr-at-eol diff --check` 通过。
- 用临时 DeepSeek 模型 JSON、临时 shared settings 和开发版启动器执行过真实 `Save-Settings` 路径：先注入旧 Qwen 的 `top_p=.95`、`top_k=20`、惩罚项、`--kv`/`--prefill`、旧预算等，再选择“官方默认”保存。回读 JSON 确认这些覆盖已清除，`--pack`/`--eos`/`--max-context`、模型架构和无关 shared 字段保留；未写旧引擎不支持的 `--experts`。测试副本及其备份已清理，原有模型配置未改动。
- 最后分别以 Qwen 默认配置与 DeepSeek 配置打开开发源 WinForms，复用 UI 探针检查窗口与 LAN 控件，均通过；`-CheckOnly` 也在最终代码上通过。

## 接下来继续完成

1. 完成最终差异审阅和 Git 状态检查，更新 `docs/superpowers/plans/2026-10-25-deepseek-compat-official-presets.md`，必要时补使用说明/更新日志。
2. 当前没有真实 DeepSeek/Qwen 模型加载验收，也没有同步 `D:\AI\Strata\launcher` 或发布；这两项与本次源代码/临时配置验证不同，应在后续运行验证或更新运行副本时单独记录。
3. 本分支提交范围仅含本次代码、测试、计划与这份记录；工作开始前已有的未跟踪文件留在本地，后续不要顺手纳入提交。

## 直接续做的命令

在 `D:\AI\Strata-Launcher`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Strata-Launcher-DeepSeekArgs.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Strata-Launcher-UsagePresets.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Strata-Launcher-NativeContext.ps1
& 'D:\AI\Strata\.venv\Scripts\python.exe' Run-Launcher-Tests.py --strata-root D:\AI\Strata
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Strata-Launcher.ps1 -CheckOnly
git -c core.whitespace=cr-at-eol diff --check
git status --short --branch
```

注意：上面的 `-CheckOnly` 不执行 WinForms 初始化；本轮已经用测试中的 Win32 控件探针按开发源真实路径打开 UI 并通过 LAN 入口检查。需要再次 UI 验证时复用该办法，不要把运行副本当作开发源测试结果。
