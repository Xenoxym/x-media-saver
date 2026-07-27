# Codex 项目操作注意事项

本文件长期保留。以后遇到同类问题，只追加简短的“现象 / 原因 / 处理”，不要写过程废话。

## 权威位置

- 项目根目录：`D:\Projects\x-media-saver\outputs\XMediaSaver`
- 只修改这个 D 盘仓库；不要操作自动生成的 C 盘副本。
- 每次修改前先确认当前目录、仓库根目录和分支：

```powershell
$PWD.Path
git -C "D:\Projects\x-media-saver\outputs\XMediaSaver" rev-parse --show-toplevel
git -C "D:\Projects\x-media-saver\outputs\XMediaSaver" status -sb
```

如果当前目录不是 D 盘，或可写根目录没有 `D:\Projects`，立即停止文件操作，先从电脑端恢复项目上下文。

## 固定发布流程

1. 直接在 `main` 修改并做本地验证。
2. 只暂存本次相关文件，commit 后直接 push `main`。
3. 不创建 PR 或功能分支，除非用户明确要求。
4. Push `main` 会自动触发 **Build unsigned IPA**；不要再手动运行一次 workflow。
5. Actions 成功应包含：Xcode 构建、IPA 上传、构建日志上传。

项目验证：

```powershell
cd D:\Projects\x-media-saver
& "C:\Users\Luo Chengqian\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" work\validate_project.py
```

## 手机端与批准

- 手机端跟进任务可能错误恢复到 C 盘工作区，或丢失此前记住的批准规则；电脑端消息可能恢复 D 盘，但每次仍须实际检查。
- D 盘文件可写不等于 `.git` 和网络自动获准；`git add/commit` 写 `.git`，`git push` 和 `gh` 访问网络。
- “允许类似命令”按精确命令前缀生效，可能不会覆盖其他 `gh run` 子命令。
- Xcode/IPA 构建本身不需要本机批准；弹窗通常来自触发或查询 GitHub 的网络命令。
- 为减少弹窗：直接 push `main` 让 Actions 自动运行，不主动轮询 `gh run list/view/watch`。

## 已记录问题

- 2026-07-27：手机端跟进后任务一度从 D 盘恢复到 C 盘，并重新请求多项批准。处理：停止操作，从电脑端继续，确认 `$PWD` 和仓库根目录均为 D 盘后再执行。
