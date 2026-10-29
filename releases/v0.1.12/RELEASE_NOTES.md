# Strata Launcher v0.1.12

修复 0.1.11 引入的「更新引擎（Qwen）」故障：更新在替换前的版本核对这一步被误报成"签名暂存引擎版本与官方提供的版本不一致"，本机引擎因此没有被替换。分享包供已安装 Strata 的 Windows 用户使用，不包含 Strata 引擎、模型或 Python 环境。

- **故障表现：**点「更新引擎（Qwen）」后报 `签名暂存引擎版本 python.exe : Traceback … NameError: name 'engine' is not defined … 与官方提供的 0.1.52 不一致；未替换本机 engine`。下载、逐文件哈希与签名校验其实已经成功，只是没走到替换那一步。
- **原因：**替换前那条核对暂存版本的 `python -c` 命令用双引号写 `engine-feed`；PowerShell 5.1 在拼装原生进程的参数表时会删掉参数内部的双引号，Python 于是把 `setup.home() / engine-feed` 按减法解析并报 NameError。同一函数里取暂存目录的命令用的是单引号，所以没有受影响。
- **修复：**该命令改为外层 PowerShell 双引号、内层 Python 单引号；退出码非 0 时单独报错（`无法核对签名暂存引擎的版本：…`），不再把捕获到的 traceback 当成版本号显示。
- **回归测试：**断言替身 python **实际收到的参数**里必须是 `'engine-feed'`。原来的替身只判断参数中含 `ec.resolve`，引号被丢掉也照样返回版本号，所以 0.1.11 的 41 个 PowerShell 测试没能拦住这个故障。

验证：`Test-Strata-Launcher-EngineOnly`（含新断言）与 `EngineVersion` / `EngineFeatures` / `EngineConfigPath` / `DeepSeekEngine` 共 5 个 PowerShell 测试通过；用本机真实暂存包实测修复后的命令返回 `0.1.52`（退出码 0），并以参数回显确认旧写法的引号在到达 python.exe 之前已经丢失；同步到运行目录复制 39 个文件、删除 0 个。**本次按要求省略完整本地验证**：Python 测试套件与其余 PowerShell 测试未重跑。

实机验收：修复后的「更新引擎（Qwen）」在本机走通，Qwen 引擎 `0.1.50 → 0.1.52`（`engine\BUILD.json` 版本 `0.1.52`、commit `a42cc3d7df70`；旧引擎保留在 `engine\.previous`，其 `BUILD.json` 为 `0.1.50`）。升级后真实启动 `qwen3.8-flash-next-iq3_s`，`/health` 报 `loaded: true`、`max_context: 262144`、`images: true`；日志记录一次 145,744 token 提示下生成 2,022 token / 22.975 s（88.0 tok/s，草稿接受 1,222/1,788）。本机 DeepSeek 引擎为 `0.1.52`（`engine-dsv41\0.1.52-windows-x86_64-cuda-cuda13`，模型配置已指向该目录）。

验证边界：没有做与 `0.1.50` 的速度对照，没有做长对话与停止验收；DeepSeek 的 0.1.52 升级不走本次改动的代码（它用原有的 `upgrade_dsv41_engine` 路径），本次只确认了版本与配置指向。

ZIP SHA-256：`9194FB2A7A944CF2CA82F698BC1853B11C35BA51E851EB2729D9356DC4720080`
