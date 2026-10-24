# Strata Launcher v0.1.7.2

v0.1.7 的第二个增补补丁，修正 DeepSeek 导入预检的误报。适用于通过 `START-HERE.bat` 从源码安装的 Windows 版 Strata；本机 Strata `v0.2.4`（Qwen 预编译引擎 `0.1.48`）完成校验。

- **修复“找到多个模型”：**把 Engram、DSpark 草稿和 UD-Q8_K_XL 的元数据分片与 IST-DAS 分片放进同一目录时，元数据分片 `DeepSeek-V4.1-Flash-1017-UD-Q8_K_XL-00001-of-00009.gguf` 同时是 UD-Q8_K_XL 的第 1 片，旧预检会把它当成第二个模型，于是拒绝导入。
- **按分片数量判断：**4 个 IST-DAS 分片胜过 1 个 UD 元数据分片；两套模型的分片数量相同时仍按“多个模型”拒绝，避免悄悄选错。
- **兼容：**0.1.7.1 的 DeepSeek 多文件识别、单文件族（Qwen3.8、Swift、Unsloth、Qwen3.6）识别均不变。

验证：139 个 Python 测试、34 个 PowerShell 测试和 ZIP 内容核对通过；本机 `F:\AI\Strata-data\models\DeepSeek_IQ2_XXS`（4 个 IQ2_XXS 分片 + Engram + DSpark + 元数据分片，共 7 个文件）实测预检输出 `deepseek41 / IST-DAS-2.00bpw`。导入之后的官方下载、打包与推理不在本补丁的验证范围内。

ZIP SHA-256：`72ECBD02358A095502C49522F4D08313B5C12BEDB149141002B1F29AB62FC77B`
