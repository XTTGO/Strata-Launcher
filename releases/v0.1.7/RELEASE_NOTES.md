# Strata Launcher v0.1.7

适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本次针对 Strata `v0.2.4`（Qwen 预编译引擎 `0.1.48`）完成校验。官方 App 和独立 Terminal 的安装方式暂不支持。

- **多卡分配：**为一个模型按卡选择 Main、Helper、Off，写入 Strata 的 `gpu_roles`、`gpu`、`gpu_order`；多卡时使用自动分层，GPU 角色区域以 Windows 十进制 PCI 总线位置区分同型号显卡。未明确勾选“修改当前模型的推理显卡分配”时，保存其他设置不会改动原有 GPU 选择。
- **Monitor 悬浮窗：**独立的 Strata Monitor 从官方只读遥测接口显示生成速度、每张 GPU 的负载与显存、系统内存和近期请求摘要，不显示请求正文；可调透明度、始终置顶，鼠标穿透可通过系统托盘解除或退出，断线时显示状态并重试。
- **引擎版本规则：**适配 Strata `v0.2.4`：官方 Qwen 预编译引擎按 `setup.py` 的 `MIN_ENGINE` 判断兼容性，本地编译引擎仍与源码构建目标比较；避免把 0.1.49 源码目标误判成必须升级的 Qwen 引擎。
- **更新校验：**更新脚本新增 `-VerifyOnly`，核对 `BUILD.json`、可执行文件版本和兼容下限，不触发源码或安装更新；签名源补装只在预编译引擎低于官方下限时运行。
- **版本显示：**主界面同时显示 Strata 源码版本、引擎版本和启动器版本，`-CheckOnly` 输出对应版本字段；源码没有可识别的 Git 版本标签时显示“未知”。
- **可折叠分组：**生成参数、运行设置、显卡分配、网络、显卡功率和工具整理为可折叠分组并记住展开状态；显卡功率信息在展开时读取，性能校准摘要改为展开工具分组时计算，停止服务所需的进程树辅助代码按需加载。

验证：138 个 Python 测试、34 个 PowerShell 测试、`-CheckOnly` 环境检查和 ZIP 内容核对通过。双卡 NVIDIA 分层已在本机真实模型推理中验收（记录见 `docs/superpowers/verification/2026-10-24-multi-gpu-live.md`）；**完整日常推理未在本版重新验收。**

ZIP SHA-256：`FA20738CF32110D8311D2FC02A517F0BAE348C3ED386972AF1EE894DD8541CCB`
