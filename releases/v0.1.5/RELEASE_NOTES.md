# Strata Launcher v0.1.5

适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本次针对 Strata `v0.2.1.3` 做离线适配。官方 App 和独立 Terminal 的安装方式暂不支持。

- 读取 Strata 0.2.1 的 `user_args` 后显示实际生效的引擎参数；保存设置时同步覆盖项和 `args_written`。
- Benchmark 从实际生效的参数制作独立临时配置，避免 `user_args` 改写测试选定的上下文、显存和视觉条件。原始模型配置不会被 Benchmark 修改。
- 更新安装范围说明。

验证：134 个 Python 测试、4 个相关 PowerShell 测试、启动器环境检查和 ZIP 内容核对通过。尚未使用 Strata 0.2.1 引擎完成实际启动或推理验收。

ZIP SHA-256：`d9930e4e332e9d449323c04bc87d5c759f14f07784e35fb727b0decb74035f3c`
