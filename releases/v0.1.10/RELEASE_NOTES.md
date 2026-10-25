# Strata Launcher v0.1.10

修复版：0.1.9 给两个引擎各加了更新入口，但漏了一种触发——**更新时启动器窗口已经开着**。这一版把 DeepSeek 引擎升级后的配置路径问题在所有时机都堵住。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata。本机 Strata `v0.2.6`、Qwen 引擎 `0.1.50`、DeepSeek 引擎 `0.1.51` 完成校验。

- **官方升级会删掉旧引擎目录：**DeepSeek 引擎按版本装在 `engine-dsv41\<版本>-<平台>-<后端>\`，升级时装新的、删旧的；而模型配置 `strata-*.json` 记的是绝对 `exe` 路径。配置没跟着改，模型就起不来，报 `FileNotFoundError: [WinError 2]`（出现在 `serve\server.py` 的 CreateProcess 里）。
- **三个时机都会修：**点「更新引擎（DeepSeek）」之后（0.1.9 已有）；**打开启动器时**（本版补上）；**保存设置之前**（本版补上——防止升级前就打开的窗口把内存里的旧路径写回）。状态栏会写“已修正 N 个模型配置的引擎路径”。
- **范围克制：**只处理 `engine-dsv41` 下的绝对路径，只在“配置里的引擎确实不存在”时动手，只替换引擎目录那一段（文件其余字节不动）；能正常启动的配置、以及 Qwen 的 `engine\strata.exe` 一概不碰；已经修好的文件再跑一次零改动。
- **发布工具（不打进分享包）：**`git tag -d` 在标签不存在时会向 stderr 写一行，PowerShell 5.1 在 `ErrorActionPreference=Stop` 下把它当终止错误，发布会在“打标签”这步中断；push / tag / fetch 改为 `Invoke-ReleaseGit`（Continue + 只看退出码）。
- **0.1.9 的内容也在这一版里：**「更新引擎（Qwen）」走官方签名更新源（旧引擎留在 `engine\.previous` 可回退）、「更新引擎（DeepSeek）」走官方安装流程末尾同一个升级函数、下载中断自动续传（最多 4 次）、只有 DeepSeek 的安装点 Qwen 按钮会明确拒绝而不是白下载。

实机验收：本机把 DeepSeek 配置故意改回已删除的 `0.1.49.2` → 打开启动器 → 自动改为 `0.1.51`（`lib_dirs` 同改）→ 模型启动成功，`/health` 报 `loaded: true`、context 262144。

验证：40 个 PowerShell、139 个 Python 测试通过（新增 `tests\Test-Strata-Launcher-EngineConfigPath.ps1`：内存对象、磁盘文件、能用的配置不动、Qwen 不动、二次执行无改动）；`-ExpandAllSections` 实窗口确认状态栏提示与两个引擎按钮。**DeepSeek 模型的长对话未做验收。**

ZIP SHA-256：`456EB97DDF7CA20A423661C0862DAF74EBF8DF50AE0595507698BD00603E1216`
