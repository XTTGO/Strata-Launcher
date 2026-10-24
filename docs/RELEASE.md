# 发布规则

这个仓库是 **启动器独立仓库**：发布产物只有启动器本身（不含模型、引擎或 Python 环境），版本号与 Strata 官方版本无关。

一个版本 = **一条命令 + 一份发布说明 + 一个可校验的包**。规则写在这里，任何人（或 agent）照着做，结果一致。

---

## 1. 版本号规则

| 场景 | 写法 | 是否进 Release 页面 |
|---|---|---|
| 正式发布 | `0.1.9` | 是 |
| 迭代中（未发布） | `0.1.9-dev.1` | 否（本地包即可） |

- `VERSION.txt` 是唯一权威，构建脚本要求它匹配 `^\d+(\.\d+)+(?:-[0-9A-Za-z.-]+)?$`。
- 标签与版本号同名，前缀 `v`：`v0.1.9`。
- 标签是**轻量标签**（`git tag`，非 `-a`），与历史版本一致。

## 2. 发布前检查（缺一项就不要发）

- [ ] `VERSION.txt` == 目标版本
- [ ] `CHANGELOG.md` 顶部有该版本小节，且写了**验证**（测试数量 + 实机结论 + 未验收项）
- [ ] `README.md` / `README.txt` / `docs/deepseek-support-matrix.md` 里的版本字样已同步
- [ ] `releases/v<版本>/RELEASE_NOTES.md` 已写（首行 `# Strata Launcher v<版本>`，末行 ZIP SHA-256）
- [ ] 测试通过：
  - Python：`D:\AI\Strata\.venv\Scripts\python.exe Run-Launcher-Tests.py`（**必须用 Strata 的 venv**，`py -3` 缺 `psutil` 会报 12 个错）
  - PowerShell：全部 `tests\Test-*.ps1`（**工作目录必须是 Strata 根**，这些测试用相对路径 `launcher\...`）
- [ ] 已同步到运行目录：`Sync-Strata-Launcher.ps1 -StrataRoot D:\AI\Strata`，且 `-CheckOnly` 报出新版本号

## 3. 一条命令发布

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Release-Launcher.ps1 -Version 0.1.9
```

它依次做：

1. 检查 `VERSION.txt` / 发布说明是否存在（不一致直接停）
2. 构建启动器包（`Build-Launcher-Package.ps1`）
3. 把 zip 放进 `releases\v<版本>\`，写 `SHA256SUMS.txt`
4. 打开 zip 核对内部的 `VERSION.txt`（防止包里是旧版本）
5. `git add` → `commit`（`Release Strata Launcher v<版本> for Strata <官方版本>`）→ 重建标签
6. 推送 `main` 与标签（**openssl 后端**，凭据取自 Windows 凭据管理器）
7. 建 GitHub Release 并上传 zip 资产

参数：

| 参数 | 用途 |
|---|---|
| `-Version 0.1.9` | 必填，目标版本 |
| `-VerifyOnly` | 只做一致性检查（哈希、包内版本、标签指向），不构建不推送 |
| `-NoPush` | 构建 + 提交 + 打标签，停在本地 |
| `-NoRelease` | 推送 main 与标签，但不建 Release |
| `-Bump` | 版本号与 `VERSION.txt` 不一致时，由脚本改写 `VERSION.txt`（**CHANGELOG/README 仍需手工同步**） |
| `-StrataRoot` | Strata 安装根目录，默认 `D:\AI\Strata` |
| `-PythonPath` | 带 `requests` 的 Python，默认取 `<StrataRoot>\.venv\Scripts\python.exe` |

> 发布脚本是开发者工具，**不打进分享包**：`Build-Launcher-Package.ps1` 的文件清单里没有它。放在仓库根目录（与 `Build-Launcher-Package.ps1`、`Sync-Strata-Launcher.ps1` 并列），`tools\` 下也能运行。

## 4. 手工流程（脚本不可用时，规则完全一样）

```powershell
# 1) 构建（输出一行：dist\Strata-Launcher-v<版本>-for-existing-install.zip）
powershell -NoProfile -ExecutionPolicy Bypass -File Build-Launcher-Package.ps1 -StrataRoot D:\AI\Strata

# 2) 放进发布目录，写 SHA256SUMS.txt（大写哈希 + 两个空格 + 文件名，LF 换行）
#    releases\v<版本>\ 三件套：RELEASE_NOTES.md / SHA256SUMS.txt / 那个 zip

# 3) 核对包内版本（必须等于目标版本）
#    用 ZipFile 打开，读 launcher\VERSION.txt

# 4) 提交并打标签
git add releases/v<版本> VERSION.txt
git commit -m "Release Strata Launcher v<版本> for Strata <官方版本>"
git tag -d v<版本> ; git tag v<版本>

# 5) 推送：必须关掉 schannel
git -c http.sslBackend=openssl push https://<user>:<token>@github.com/XTTGO/Strata-Launcher.git main
git -c http.sslBackend=openssl push https://<user>:<token>@github.com/XTTGO/Strata-Launcher.git v<版本>

# 6) 建 Release 并上传资产（Python + requests）
#    POST https://api.github.com/repos/XTTGO/Strata-Launcher/releases
#         {tag_name, name, body(=发布说明去掉首行标题), draft:false, prerelease:false}
#    POST https://uploads.github.com/repos/XTTGO/Strata-Launcher/releases/{id}/assets?name=<zip名>
```

## 5. 产物目录规范

```
releases/v<版本>/
  RELEASE_NOTES.md                                  # 发布说明，首行标题、末行 SHA-256
  SHA256SUMS.txt                                    # SHA256SUMS 格式，大写
  Strata-Launcher-v<版本>-for-existing-install.zip  # 包本身也入库（约 170 KB）
```

- zip 文件名固定为 `Strata-Launcher-v<版本>-for-existing-install.zip`，Release 资产必须同名。
- 发布说明里的 SHA-256 必须等于资产实际哈希（发布后用 `-VerifyOnly` 或下载回来核对）。

## 6. 本机环境约束（踩过的坑，别重复踩）

| 现象 | 原因 | 做法 |
|---|---|---|
| `git push` 报 `schannel: SEC_E_NO_CREDENTIALS` | 本机 git 的 schannel 后端不可用 | 所有 git 网络命令加 `-c http.sslBackend=openssl` |
| 不知道用哪个 token | 凭据在 Windows 凭据管理器 | target `git:https://github.com`（用户 `XTTGO`，40 位 `gho_`），用 `CredRead` 读，**只在进程内用，绝不打印** |
| `git`/`curl`/PowerShell 5.1 连不上 `api.github.com` | TLS 握手失败 | 用 Python `requests`/`urllib` |
| 匿名调 API 返回 403 `rate limit exceeded` | 共享出口 IP 已被用尽 | 校验请求也要带 Token（限额 5000/h） |
| Python 测试 12 个 `ModuleNotFoundError: psutil` | 用了系统 Python | 用 `D:\AI\Strata\.venv\Scripts\python.exe` |
| 改完 `.ps1` 后启动器报一堆语法错（如 172 个） | 编辑把 **UTF-8 BOM** 去掉了，PowerShell 5.1 按 GBK 读中文 | 改完确认文件头是 `EF BB BF`；文本工具批量改时尤其注意 |
| `git diff` 出现几百行假改动 | 编辑把 CRLF 统一成了 LF（`CHANGELOG.md` 本来就是混合行尾） | 用字节级替换，不要整体重写文件 |
| 发布说明里的哈希和资产对不上 | 先算了哈希、之后又构建了包（zip 是确定性构建，但会重新生成） | 顺序固定：**构建 → 写 SHA256SUMS → 上传 → 不要再构建** |

## 7. 发布后核对

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Release-Launcher.ps1 -Version <版本> -VerifyOnly
```

再看三件事：
1. Release 页面 `draft=false`、`prerelease=false`
2. 资产名与大小对得上，下载后的 SHA-256 等于 `SHA256SUMS.txt`
3. `git ls-remote --tags origin v<版本>` 与本地标签指向同一提交

> 标签**不必等于** HEAD：发布之后还会补文档提交，这些不影响发布内容，发布内容以标签指向的提交为准。`-VerifyOnly` 就是按这个规则检查的（标签在 HEAD 历史里 + 标签树里 `VERSION.txt` 正确），标签落后于 HEAD 时会打一行提醒。

## 8. 回滚与重发

| 情况 | 做法 |
|---|---|
| 包有问题，同版本重发 | 修好 → 重跑发布脚本。本地标签会被重建；**远端同名标签已存在时推送会被拒绝**，需要 `git push -c http.sslBackend=openssl --force <url> refs/tags/v<版本>`（仅确认要覆盖时） |
| Release 建错了 | 在 GitHub 删除该 Release 与资产，再重跑步骤 6；标签不用动 |
| 已发布但想撤回 | 删 Release（可留标签），把 `VERSION.txt` 回到上一版并提交，README 指向旧版本说明 |

## 9. 一页速查

```
改版本号(VERSION/CHANGELOG/README/matrix) → 写 releases/v<版本>/RELEASE_NOTES.md
→ 跑 Python(venv) + PowerShell(Strata 根) 测试 → Sync 到运行目录并 -CheckOnly
→ Release-Launcher.ps1 -Version <版本>
→ -VerifyOnly 复核 + 下载资产对哈希
```
