# Strata Launcher v0.1.9

引擎更新版本：官方更新只在预编译引擎低于兼容下限时才替换引擎，所以新版本随附的引擎到不了已装机器上——这一版给 Qwen 和 DeepSeek 两条引擎链各加了一个显式入口，取值全部走官方签名更新源。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata。本机 Strata `v0.2.6`、Qwen 引擎 `0.1.50`、DeepSeek 引擎 `0.1.49.2` 完成校验。

- **新增「更新引擎（Qwen）」：**官方 `UPDATE.bat` / `setup.py --update` 只在引擎低于 `MIN_ENGINE`（0.2.6 仍是 0.1.46）时替换，所以随附的 0.1.50 不会覆盖已装的 0.1.48。按钮调用 `setup.engine_from_feed`——与官方 0.2 组件更新同一套校验：Ed25519 签名、逐文件哈希、用已装模型试启动通过后才替换；旧引擎保留在 `engine\.previous`，可用 `setup.py --rollback-engine` 回退。本地编译引擎（`source=local`）拒绝被预编译包替换。
- **新增「更新引擎（DeepSeek）」：**DeepSeek-V4.1-Flash 的引擎是另一条链（`engine-dsv41\`、feed 成员 `dsv41`、`strata_control/dsv41_engine.py`），官方 `UPDATE.bat` 和 `strata update` 都不管它，官方只在 DeepSeek 安装流程末尾升级它。按钮直接调用同一个 `upgrade_dsv41_engine`：签名/逐文件哈希校验 → 只跑一次 `strata-dsv41 --version` 试启动 → 新包与旧包并存后删旧的一代（只保留一代，没有 `--rollback-engine`）；没有 DeepSeek 引擎的安装明确拒绝，不会顺手下载。
- **`-EngineOnly` / `-DeepSeekEngineOnly`：**两个新开关只更新引擎——不做源码快进、不运行官方 `UPDATE.bat`、不改模型配置与官方设置；引擎文件被占用时直接报错退出，不会半途替换。
- **升级后自动修正模型配置：**DeepSeek 的官方升级装到新的版本目录、随后删掉旧目录，但 `strata-*.json` 记的是引擎的绝对 `exe` 路径（还有 `lib_dirs`）——升级完模型就起不来。更新成功后启动器把配置里的旧引擎目录改成新目录，只替换这一条路径，文件其余字节不动。
- **断流自动续传：**官方下载器在一次运行内不重试（连接一断就以“装不上”结束，但残片保留）。启动器对两个引擎的更新都做最多 4 次续传（残片按包 SHA 命名，CDN 已实测支持 `Range`），并把官方给出的失败原因原样抛出，不再含糊地报“或本次更新未完成”。
- **官方更新链的三个坑已处理：**签名源默认按 id 挑已装模型做试启动，本机会挑到 DeepSeek 配置并把 `--eos` 交给 Qwen 引擎（`unknown argument: --eos`，看起来像引擎坏了）——现在显式传 `--model-config`；失败会留下 24 小时“试启动失败”标记——只在试启动失败时用一次 `--force` 重试，被回滚过的版本不强行覆盖；更新必须写进 `setup.home()\engine-feed`，否则会出现“下载成功但 `engine\` 没变”。
- **布局：**「官方工具」改为四列：第 1 行「导入本地模型」「官方 START-HERE」「环境检查」「立即备份设置」，第 2 行「官方更新」「更新引擎（Qwen）」「更新引擎（DeepSeek）」「刷新模型列表」。更新脚本默认根目录改为与启动器相同的识别规则，三个入口都显式传 `-StrataRoot`。

实机验收：本机 Strata v0.2.6 的 Qwen 引擎由 `0.1.48` 升级到 `0.1.50`，DeepSeek 引擎由 `0.1.49.2` 升级到 `0.1.51`（旧引擎留在 `engine\.previous`，`strata --version` 与 `BUILD.json` 一致）；升级后真实启动 DeepSeek 模型，`/health` 报 `loaded: true`、context 262144，`-CheckOnly` 报 `engine_version=0.1.50`、`deepseek_engine_version=0.1.51`。

验证：139 个 Python 测试、39 个 PowerShell 测试通过（新增 `tests\Test-Strata-Launcher-EngineOnly.ps1`，含断流重试与升级后配置改路径两条用例）；`-ExpandAllSections` 实窗口确认两个新按钮与四列布局。**DeepSeek 模型的长对话未做验收。**

ZIP SHA-256：`2D490B50FAFF69A5587A81B821C6B49ABBFF1F1D68BF8F7AC5CBA462DA2ED983`
