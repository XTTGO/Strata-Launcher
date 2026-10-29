# Strata 0.2.7.1 启动器适配记录（2026-10-29）

## 基线

- 本机官方 Strata 源码为 `v0.2.7.1`。官方发布说明写明 Windows 的 Qwen 与 DeepSeek 引擎仍为 `0.1.52`；`0.2.7.1` 对 Windows 没有新的引擎或速度变更。
- 开发仓库：`D:\AI\Strata-Launcher`；运行副本：`D:\AI\Strata\launcher`。本次只更新启动器代码，不安装引擎、不重新下载模型。
- 验证时本机 Qwen 引擎 `0.1.50`、DeepSeek 引擎 `0.1.51`。当前 DeepSeek pack 的 `ds4.txt` 不含 `image_token_id` 和 `vision.num_hidden_layers`，为纯文本模型包。

## 已实现

1. 对齐官方 `apps/host/server/native-settings.mjs` 中四个速度开关及其默认值、适用模型和显卡条件：Qwen 长提示加速、12 GiB 以下 NVIDIA 回答加速、Radeon RX 9000 回答加速、DeepSeek 新版加速。需要引擎 `0.1.52+`，旧引擎的控件保持禁用。保存设置时，只写入用户改动过的开关；其他环境变量保留。
2. DeepSeek 图像输入按引擎版本和 pack 元数据门控。可用时保存 `--vision on/off`；旧版引擎、纯文本 pack 或遗留的裸 `--vision` 不会被错误传给 DeepSeek。Qwen 仍使用自己的视觉组件与配置。
3. Qwen 引擎更新先读官方签名源的 `--check` 结果，再比较已安装、签名暂存和安装后的版本。已经最新时不重新复制引擎或覆盖 `engine/.previous`。
4. DeepSeek 引擎更新先从官方签名源选择适合本机的包，再调用官方升级函数；若源无法检查、下载失败或安装版本低于所提供的版本，明确报错，不报告为“已是最新”。引擎目录切换后继续修复失效的模型配置路径。
5. 独立源码同步改用系统临时目录构建包，避免用未发布的开发代码覆盖 `dist` 中已有的同版本发布 ZIP。

## 已验证

- PowerShell 解析、`git diff --check`（按 CRLF 规则）、启动器 `-CheckOnly` 通过。
- 41 项 PowerShell 脚本测试通过，覆盖引擎版本/更新、DeepSeek 参数、视觉、速度开关、设置保存、源码稳定标签和其他启动器功能。
- 使用 Strata `.venv` 运行 `Run-Launcher-Tests.py --strata-root D:\AI\Strata`：139 项 Python 测试通过。系统 Python 缺少 `psutil`，不用于此项目测试。

## 尚未验证

- 未下载或安装 Qwen/DeepSeek `0.1.52` 引擎；未实测新引擎上的模型启动、图像推理或速度收益。
- 当前 DeepSeek pack 无视觉塔。要实测图像输入，需使用官方 setup 补齐图像权重并重新生成 pack，再安装对应新引擎。
- 启动器按 `v0.1.11` 发布；本记录中的新版引擎实机验证边界仍适用。
