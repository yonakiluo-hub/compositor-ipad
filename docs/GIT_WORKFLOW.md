# Mac 与 Windows 的 Git 协作

两台电脑各自克隆同一个仓库。Git 记录和同步代码版本，不实时同步正在编辑的文件，也不负责运行时画稿传输。

仓库：<https://github.com/yonakiluo-hub/compositor-ipad>

## 首次使用

```sh
git clone https://github.com/yonakiluo-hub/compositor-ipad.git
cd compositor-ipad
```

Mac agent 先读 `docs/MAC_AGENT_HANDOFF.md` 和 `ipad_bridge/docs/API_V1.md`。Windows agent 主要维护 `ipad_bridge/`。原生 iPad 工程放在 `ipad_app/`，网络协议修改同步更新文档和兼容性测试。

每台电脑分别配置自己的 GitHub 登录和提交身份。公开提交建议使用 GitHub 账户设置中显示的 noreply 邮箱；不把密码、访问令牌或私人邮箱写进仓库。

## 两边同时开发

每个任务建一个分支，避免两个 agent 同时往 `main` 推送。Mac 端示例：

```sh
git switch main
git pull --ff-only
git switch -c mac/ipad-canvas
```

Windows 端可使用 `windows/bridge-improvements` 等分支。分支名对应实际任务；不要重复创建已存在的分支。

完成一段可运行的修改后，检查差异、提交并推送。例如 Mac 修改仅包含 iPad 工程和交接文档时：

```sh
git status --short
git diff
git add ipad_app docs/MAC_AGENT_HANDOFF.md
git diff --cached
git commit -m "Add initial iPad canvas"
git push -u origin mac/ipad-canvas
```

随后在 GitHub 为该分支创建 Pull Request，检查变更和测试后合并到 `main`。另一台电脑再切到干净的 `main` 并执行 `git pull --ff-only` 即可取得合并结果。已经有未提交修改时先提交或妥善暂存，不直接覆盖。

## 从另一台电脑继续同一个任务

原电脑先提交并推送当前任务分支，再在另一台电脑执行：

```sh
git fetch origin
git switch --track origin/mac/ipad-canvas
```

如果本地已存在该分支，改用 `git switch mac/ipad-canvas`，再 `git pull --ff-only`。同一任务分支交接后由一台电脑继续写，避免两端同时修改它。遇到非快进错误，先检查双方提交并正常合并；不要强制推送来覆盖另一台电脑的工作。

## 每台电脑自己保留的内容

- Python 虚拟环境、ComfyUI 安装、模型和缓存。
- 配对文件、访问令牌、证书私钥与本机地址配置。
- 画稿、任务数据库、输入输出图片、工程备份和测试运行结果。
- Xcode 的个人签名与本机用户状态。

根 `.gitignore` 已覆盖这些常见文件。忽略规则不是秘密扫描工具；每次提交前仍查看 `git diff --cached`，只提交本任务需要的文件。AI 生成运行时仍通过局域网桥接完成，不通过 commit/push 传图。

## 验证修改

桥接修改后，在 `ipad_bridge` 目录用各自虚拟环境运行 `python -m pytest -q`。接口变化同时检查模拟 HTTP 客户端；真实 GPU 修改由有 ComfyUI 的 Windows 验证。iPad 源码在 Mac 使用 Xcode 构建，模拟器与真机结果分别记录。纯文档修改不需要重跑 GPU 生成。
