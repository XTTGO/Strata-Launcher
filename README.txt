Strata 辅助启动器（适用于已经安装好 Strata 的 Windows 用户）
===========================================================

启动器版本：0.1.7-dev.1（开发分支；独立于 Strata 官方版本，基于 Strata v0.2.3 / 引擎 0.1.48）。更新内容与验证边界见 CHANGELOG.md。

这套启动器独立维护，但运行时依赖已经安装完成的 Strata。它不是模型、引擎或 Python 环境的替代安装包。
当前只支持通过 START-HERE.bat 从源码安装的 Windows 版 Strata；官方 App 和独立 Terminal 的目录及进程管理方式不同，不能把此包直接放进去使用。

安装位置
--------

把收到的整个 launcher 文件夹复制到 Strata 根目录下：

<Strata 根目录>\
  START-HERE.bat
  serve\
  engine\
  strata-模型名.json
  launcher\
    Strata-Launcher.bat

随后双击：

launcher\Strata-Launcher.bat

启动器会根据自身位置识别 Strata 根目录，因此 Strata 可以位于任意盘符，也可以位于带空格的路径中。首次打开时会检查官方入口、Python 环境、服务、引擎、测试工具和至少一个模型配置；如果位置不对或安装不完整，会列出缺少的项目。
启动器会读取官方源码的引擎目标版本，并核对 engine/BUILD.json；旧引擎会显示警告但仍可启动，安装信息缺失时会提示先检查更新。

前提
----

- Windows 10 或 Windows 11。
- 已经通过官方 START-HERE.bat 完成 Strata 和至少一个模型的安装。
- Strata 根目录中存在 .venv、serve、engine 和 strata-*.json。
- 模型文件继续使用接收者自己的 Strata 数据目录；分享包不包含模型文件。

主要文件
--------

- Strata-Launcher.bat：双击入口。
- Strata-Launcher.ps1：启动器界面和运行逻辑。
- Strata-Launcher-Environment.ps1：识别并检查接收者的 Strata 安装。
- model_catalog.py：从接收者当前的 setup.py 提取支持模型和显示来源。
- Strata-Launcher-GpuPower.ps1：可选的 NVIDIA 显卡功率上限与恢复逻辑。
- Strata-Launcher-GpuPlacement.ps1：读取 CUDA 显卡并校验、写入单模型显卡角色。
- Strata-Launcher-Lan.ps1、Strata-Launcher-LanFirewall.ps1：可选的局域网密钥和受限防火墙操作。
- Strata-Launcher-Update.ps1：执行安全的源码快进与官方安装更新；旧安装流程跳过新版引擎时调用官方签名更新源，并核对最终版本。
- Strata-Calibration-View.ps1：显示当前模型、上下文、视觉状态和完整校准结果。
- Strata-Launcher-Reload.ps1：切换模型后在当前 PowerShell 进程内重新载入。
- Strata-Launcher-Settings.ps1：合并采样设置，保留界面未展示的配置字段。
- Strata-Calibrate-Current.py：调用已安装 Strata 的官方校准能力。
- Benchmark-Launcher.ps1：批量 Benchmark 界面。
- benchmark\：测试编排、固定任务、官方测试工具适配和报告生成。
- VERSION.txt、CHANGELOG.md：启动器版本和更新日志。

本机数据
--------

首次运行后，启动器会在自己的目录中创建：

- data\：当前选择、进程记录、校准详情及 Benchmark 状态。
- backups\：启动器自动生成的设置备份。
- reports\：Benchmark 报告、日志、配置快照和模型输出。

这些目录属于当前电脑，不应随启动器再次分享。由 Build-Launcher-Package.ps1 生成的 ZIP 会自动排除它们以及测试、缓存和开发文档。

推理显卡分配（NVIDIA CUDA）
--------------------------

GPU PLACEMENT 区域列出当前 CUDA 引擎可用的 NVIDIA 显卡。未勾选“修改当前模型的推理显卡分配”时，保存生成参数不会改动模型配置中的选卡字段。要让一个模型跨多卡运行，勾选后给一张卡设 Main，其余参与分层的卡设 Helper，不参与的卡设 Off；保存或启动时写入当前模型的 strata-*.json。Main 是模型分层的最后一段，多卡默认由 Strata 自动分层。已有手工分层值在重新选卡后会改为自动分层；切回单卡时会清除分层值。

界面保留 Strata 使用的 GPU 编号，并把 PCI 地址转换为 Windows 设备管理器常见的十进制“PCI 总线、设备、功能”格式，便于区分同型号显卡。保存前会再次核对显卡编号、UUID、原始 PCI bus ID、CUDA 引擎及所选角色。显卡或硬件拓扑发生变化时，请重新打开启动器；不兼容的卡只能保持 Off。多卡并不保证比单卡更快，且每张卡都需要自己的运行缓冲区。此功能只管理一个模型跨卡运行；GPU POWER 是独立的系统级功率设置，不会随选卡自动更改。官方说明：https://github.com/Niko1221/Strata/blob/main/docs/MULTI_GPU.md 。

显卡功率上限（NVIDIA）
---------------------

界面中的 GPU POWER 区域会读取当前功率、出厂默认值和驱动允许范围。输入范围内的整数瓦数，点击“应用”并确认后才会调用 nvidia-smi 设置；Windows 可能弹出管理员授权。功率上限是整张显卡的系统级设置，会影响其他程序；仅保存 Strata 设置、启动或停止 Strata、运行 Benchmark 都不会自动更改它。

第一次成功应用前的功率会记录在本机 launcher\data\gpu-power-restore.json。点击“恢复修改前”会恢复此值，而不是出厂默认值；关闭启动器不会自动恢复。若其他程序随后修改了显卡功率，启动器不会自动覆盖对方设置；想重新应用时必须明确确认接管，并以外部修改后的当前值作为新的恢复基线。该记录只属于本机，分享包不会包含。AMD 或无法读取完整功率范围的显卡会禁用此区域。

使用启动器设置功率后，Benchmark 会在报告的硬件信息中记录测试开始时读回的功率上限。报告中的值是当时快照，不保证测试期间没有被其他程序更改。

模型与设置
----------

模型配置仍由接收者的 Strata 根目录中的 strata-*.json 提供。官方全局设置仍位于当前 Windows 用户的 AppData\Roaming\Strata\settings.json。启动器没有自带模型路径，也不会使用打包者电脑上的选择、备份或报告。

“刷新模型列表”会重新读取配置并检查其引用的 GGUF 文件和专家包。组件缺失的配置暂时不会显示在可选列表，配置文件不会被删除；恢复组件并再次刷新即可重新出现。若当前模型已失效，刷新时会选择仍可用的模型；若全部模型组件都缺失，会提示先恢复或重新安装。

每次打开启动器时，会校验当前 setup.py 和 model_catalog.py 的内容：没有变化就复用 launcher\data\model-catalog-cache.json；变化后由 model_catalog.py 重新提取官方支持清单和下载来源。新增本地模型配置每次打开仍会立即扫描，不依赖目录缓存。能确认量化作者时显示作者；只能确认 Hugging Face 发布者时标为 HF: 发布者；来源不足时保留原始 model_name。提取失败时继续使用内置兼容映射，并在界面状态栏提示。显示名不写回配置，也不改变模型文件或 Benchmark 记录中的原始 model_name。

保存模型设置时，启动器只更新界面中可编辑的采样参数，并保留配置中未展示的参数。官方兼容别名 repeat_penalty / repeat_last_n 会在读取时识别、保存时统一为 repetition_penalty / penalty_last_n；惩罚回看 token 数为 0 时也会按 0 保存。

主启动器的“使用预设”分为“快速直答”（不思考）、“日常通用”（中等思考）和“Agent / 深度思考”（高强度思考）。按 Qwen3.8-Flash-Next 官方建议，快速直答使用非思考采样：Temperature 0.7、Top-p 0.8、Presence penalty 1.5；另外两档使用思考采样：Temperature 1、Top-p 0.95、Presence penalty 0。三档均使用 Top-k 20、Min-p 0、Repetition penalty 1、Frequency penalty 0，清除固定随机种子、API 默认输出上限与思考 token 上限。官方也提醒较高 Presence penalty 偶尔可能造成语言混杂或性能下降，遇到这种情况可手动调低并保存为“自定义”。预设只填入生成参数，不改上下文、KV、显存、并行请求数、端口或视觉配置。选择预设后仍需点击“仅保存设置”或“保存并启动”才会写入模型配置；保存时思考强度也写入模型配置。打开已有配置时按界面中的生成参数显示匹配预设；手动改动其中一项则显示“自定义”，恢复完全一致的参数后重新显示对应预设。客户端在请求中显式传入的参数仍优先。官方建议见 https://huggingface.co/Qwen/Qwen3.8-Flash-Next 。

视觉输入：如果官方安装已提供 strata-vision.exe、对应模型的 mmproj 和 engine\BUILD.json，首次在启动器中勾选“启用图像输入”并保存时，会按当前模型路径生成视觉配置和 --vision 参数；GPU/CPU 模式取自 BUILD.json。已有的视觉配置或备用 .vision.json 优先保留。启动器只编辑配置，不下载或编译缺少的视觉组件。若首次安装时未选择视觉，请先在 Strata 根目录运行 START-HERE.bat --setup --vision gpu（AMD 使用 cpu），完成官方安装后再打开启动器。

局域网访问（默认关闭）
--------------------

在“RUNTIME & MEMORY”区域勾选“LAN access：允许局域网设备访问”，然后使用“保存并启动”。仅保存设置不会改变正在运行的服务；要让当前服务切换监听方式，先正常停止，再由启动器启动。关闭该选项后，下次由启动器启动时会明确使用 127.0.0.1。官方 START-HERE 入口不受此选项影响。

首次启用时，启动器生成随机 256 位 API key，使用 Windows 当前用户的 DPAPI 加密，保存在本机 launcher\data\lan-key.dpapi。可通过“Copy API key”按需复制给可信设备；密钥不会写入模型 JSON、启动命令行、报告或分享 ZIP。若把整个 data 目录复制到另一台电脑/另一个 Windows 用户，旧密钥可能无法解密，启动器会拒绝无密钥对外启动；分享时应只用生成的 ZIP。恢复时先停止 Strata，再把 launcher\data\lan-key.dpapi 移到备份位置，重新启动以生成新密钥，并更新可信客户端；启动器不会自行覆盖无法解密的旧密钥。

启动器将本机私有 IPv4 候选地址显示为可点击链接；点哪条就复制哪条到剪贴板，不会打开浏览器，端口变化时链接也会更新。未发现私有 IPv4 时只显示提示文字。远端可打开 http://本机局域网IP:端口/，并在网页 About > Settings 填入 API key；OpenAI 兼容客户端使用 http://本机局域网IP:端口/v1 和同一密钥。HTTP 不加密，仅限可信局域网；不要做路由器公网端口转发。

Windows 防火墙规则不会因勾选或保存而自动修改。点击“Firewall · 放行”并确认管理员授权后，才会创建限于专用网络、本地子网、当前端口和实际 Python 进程映像的入站规则；“撤销放行”只移除该端口由启动器创建的规则。关闭局域网模式或更改端口不会自动删除旧规则，请按需手动撤销。若 Windows 网络配置为“公用网络”，专用网络规则不会生效。实际连通性仍需在另一台设备上验证。

官方实时监控
------------

在“官方工具”区域点击“官方实时监控”，启动器会检查当前所选端口上是否运行 Strata，然后用默认浏览器打开该服务的 #monitor 页面。服务未运行时只显示提示，不会自动启动。此入口不启用会保存请求内容的独立 /api-monitor 功能。

点击旁边的“悬浮监控”会打开独立的置顶小窗。它按当前服务端口读取 Strata 官方只读遥测，显示生成速度、各张选中显卡的负载与显存、系统内存及近期请求的数量和耗时，不读取请求正文。服务未运行时小窗等待并重试。底部可调透明度；勾选“鼠标穿透”后，小窗不会拦截鼠标，可在 Windows 系统托盘右键 Strata Monitor 图标解除穿透或退出。关闭小窗不会停止 Strata。若服务要求密钥，小窗使用当前用户本地加密保存的启动器 LAN 密钥，或启动环境中的 `STRATA_TELEMETRY_KEY`；密钥不写入命令行和监控画面。

批量 Benchmark
--------------

1. 先使用启动器停止正在运行的 Strata。
2. 在“官方工具”区域打开“批量 Benchmark 与对比报告”。
3. 选择模型和预设；预设已设置好轮数、上下文上限、输入长度、并发与测试项目，可直接开始。高级选项仍可单独调整。
4. 开始测试；需要中止时使用“安全停止”以保留部分报告。
5. 完成后打开本机 launcher\reports 中的 HTML 报告。

Benchmark 只读取接收者自己的官方程序和根目录模型配置。测试设置写入本次报告目录中的临时配置副本，不修改原始模型 JSON 或官方 settings.json。

分享包内带有本版 Benchmark 使用的 Needle 与并发测量脚本；Benchmark 优先使用包内版本，不要求修改接收者 Strata 根目录的同名官方工具。

预设分为五档：“日常速测”（1 轮、1K/4K 性能、4K 并发）、“日常完整”（3 轮、1K/4K/32K 性能、4K 并发、缓存、Agent、召回与短时稳定性）、“长文对照”（1 轮、32K/128K 性能与召回）、“并发专项”（4K/32K 输入，1 路和 2 路各 2 组）和“容量极限”（256K 性能、召回及近上限容量探测）。五档默认均使用原生 256K 模型上限，不自动开启实验性 512K YaRN。长文与容量结果应单独解释；旧版保存的昂贵矩阵按新预设迁移，旧报告不变。

Benchmark 默认在报告目录中生成受控配置副本：统一 KV 格式、驻留量、显存预留、所选上下文上限、缓存状态和并发槽数；关闭视觉编码器。各模型原有的 PCIe 分担、MTP、CPU 工作线程、专家缓存、自适应参数、环境变量与采样设置保留并在报告中列出。这是在共同测量条件下比较各模型的原有调优表现，并非剥离调优后的纯模型速度。不选择“模型上限”档位时，所有原配置的上限与 YaRN/ROPE 缩放设置必须一致。

普通性能、Agent、Needle、容量和稳定性关闭提示词缓存并使用单槽；对话缓存阶段单独开启缓存；并发阶段关闭缓存并申请“最大并发”对应的引擎槽数。程序核对 /v1/status 的实际 serving 槽数、每条请求的缓存复用 token 数和输出时间重叠情况；条件不成立时将该档标记失败。阶段重启会增加总耗时。报告列出每阶段配置副本与并发核验数据；原始模型配置不受影响。日常档并发只跑 4K，并发专项跑 4K/32K；输入勾选与预设阶段长度取交集，交集为空时启动前报错。

“模型上限”可选择 32K、64K、128K、256K、384K、512K。普通模式只能选一个；不勾选时沿用原配置。开启“多档上限测试”后至少选择两个档位，各档分别执行当前预设及已选项目。低档位容纳不下的输入会标为“档位不适用”，不算请求失败。开始前会显示计划服务启动次数（含缓存和并发阶段重启）、性能与召回请求数、并发组数和容量请求数。384K/512K 使用实验性 YaRN，可能耗时很久或因内存不足无法启动。

勾选“上下文容量探测”后，每个实际运行档位会用接近上限的真实长输入，在前、中、后各重复两次信息召回。六次都正确、正常结束且服务返回的实际输入 token 数达到该档上限的 90%，报告才标为“已验证可用”。报告会列出真实 token 范围和失败原因；此结论只代表本次所选档位的这类召回任务，不等于模型理论极限，也不会自动修改日常启动配置。

缓存测试先用当前模型 tokenizer 校准首轮约 32K 输入，并核对服务返回的真实 token 数在目标的 ±5% 内。首轮只允许不超过目标 1% 的公共前缀复用；两次追问各需复用至少目标 40% 的 token，缺少复用计数或有效输出会标为失败。报告区分总 prompt token、新读取 token 和已复用 token。历史报告不会被自动重算。

性能和预设选定的并发输入会先用当前模型的 tokenizer 校准同一份本地语料，再核对正式请求中服务返回的真实输入 token 数；1K 性能输入的校准包含实际发送的请求标识。不同 tokenizer 可能使语料截断位置略有差异。若偏离所选档位或冷输入被缓存复用，该档不会计为成功。基础性能还需有有效输出、输出 token 数和 Prompt/Decode 速度指标。性能报告中的“引擎预填充”来自 prompt_ms；并发报告中的 TTFT 才是客户端计时。

Benchmark 的长上下文召回在每道题发出前用服务端 tokenizer 校准提示词，并以响应中的真实输入 token 数核验所选档位，偏差超过 5% 标为失败。召回统计按应测题数计算，请求失败或缺题不会被排除出分母；工具单独运行时不自动启用这项校准。短时稳定性只把返回有效内容和输出 token 数的请求计为成功。容量探测已发请求但证据不足时，阶段显示“部分完成”，不会显示“未执行”。

每次运行和手动重新生成报告时，report.md 都按同一套摘要格式导出：开头是一句不超过 180 字、可直接用于评论的分享总结，只引用已取得的有效结果，并标出样本数或题数；正文只列本次选中项目的常规对照数据、状态和必要口径。配置上限与实测输入 token 分开显示，未勾选容量探测时不会给出容量结论。详细结果见 report.html、summary.json 和 raw-results.jsonl，完整配置副本见本次报告目录的 configs\；历史报告不会自动改写。

重新生成分享包
--------------

在 Strata 根目录的 PowerShell 中运行：

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\Build-Launcher-Package.ps1

生成文件：

launcher\dist\Strata-Launcher-v0.1.5-for-existing-install.zip

接收者只需解压 ZIP，并把其中的 launcher 文件夹复制到自己的 Strata 根目录。

独立开发与同步
--------------

开发仓库可放在 Strata 安装目录外，例如与安装目录并列。运行副本仍位于 <Strata 根目录>\launcher；模型配置、data\、backups\ 和 reports\ 留在安装目录。

在独立开发仓库中运行：

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<启动器开发目录>\Sync-Strata-Launcher.ps1" -StrataRoot "<Strata 根目录>"

同步脚本用开发仓库的源码构建便携包，再复制其中的程序文件到目标；它不会复制开发仓库的 Git、测试、营销稿或本机报告，也不会删除目标的本机数据。下次同步只清理上次清单中记录、且本版包已移除的程序文件。同步前请关闭启动器与 Benchmark。

开发目录中的 Python 测试可用 `python Run-Launcher-Tests.py --strata-root "<Strata 根目录>"` 运行；它直接加载开发目录的代码。运行副本的 Windows PowerShell 检查仍在同步后执行。
