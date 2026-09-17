# 上游问题与上报记录

> 状态：第 1~2 条已于 2026-08-31 **上报**（issue 号见各条）；其余保留证据与思路，待决定时直接取用。
> 生成 issue 标题遵循主仓库 AGENTS.md 第 7 条：英文、不以 Fix 开头、客观描述症状。

## 1. Electron 弹窗把一切文件系统错误渲染成「第三方软件占用」

> 已上报：[siyuan-note/siyuan#19050](https://github.com/siyuan-note/siyuan/issues/19050)

- 位置：`app/electron/main.js` case 26。
- 行为：内核退出码 26（`ExitCodeFileSysErr`，来自 siyuan-note/logging，涵盖所有文件系统错误）固定显示「工作空间下的文件正在被第三方软件（比如同步网盘、杀毒软件等）打开占用……」。
- 实际案例：Nix store 只读权限被复制进工作空间导致覆盖失败（见第 2 条），与同步盘无关，文案严重误导排障方向。真实错误只在 `temp/siyuan.log` 可见。
- 已用标题：`Electron dialog misattributes every exit-code-26 file system error to a third-party lock`

## 2. gulu copyFile 把源文件权限带到目标，只读源导致后续覆盖必败

> 已上报：[siyuan-note/siyuan#19051](https://github.com/siyuan-note/siyuan/issues/19051)

- 位置：88250/gulu `file.go::copyFile`（v1.2.3-0.20260609 中约 :327-333）：`os.Create(dest)` 后执行 `os.Chmod(dest, sourceinfo.Mode())`。
- 触发链（本仓库已用打包层替换为固定 0644 规避，见 `pkgs/siyuan-kernel.nix` 的 `modPostBuild`，同 nixpkgs 做法）：
  1. 安装目录资源在 Nix store 中一律只读（444）；
  2. 内核 `InitAppearance()`（kernel/model/appearance.go）每次启动将 WorkingDir 的 appearance 复制到 `<工作空间>/conf/appearance`，目标被 chmod 成 444；
  3. 下次启动覆盖复制时 `os.Create` 对只读目标报 EACCES；`siyuan-note/filelock@v0.0.0-20260411141728/filelock.go:91` 将其视为致命错误，退出码 26 → 第 1 条的误导弹窗。
- 候选修复方向（二选一或都提）：
  - gulu 层：copyFile 不应让目标继承源的只读位（至少属主写位），或提供不保留权限的复制变体；
  - SiYuan 层：InitAppearance 覆盖复制前先解除既有文件只读。
- 已用标题：`CopyFile preserves source mode, making destinations from read-only sources fail on subsequent overwrites`
- 备用草案（siyuan 侧）：`Workspace appearance copies become read-only and break the next kernel start`

## 3. 第三方声明里的 Pandoc 版本长期未随内置二进制更新

- 位置：`scripts/generate-third-party-notices.py:346-352`（表项硬编码 `("Pandoc", "3.5", ...)`），产物落在 `THIRD_PARTY_NOTICES.md:68`。
- 行为：`app/pandoc/*.zip` 里实际内置的是 **pandoc 3.10.1**，但声明表一直写 `3.5`。
- 证据（v3.8.3 tag，逐个解包 `app/pandoc/`）：五个平台包（linux/darwin 的 amd64+arm64、windows amd64）的 `bin/pandoc`（或 `bin/pandoc.exe`）均含字面量 `3.10.1`；把 linux-amd64 的那份直接执行，`--version` 输出 `pandoc 3.10.1` / `Features: +server +lua` / `Scripting engine: Lua 5.4`，解压后 163,339,152 B。zip 条目 mtime 全为 `2026-07-22 16:22:44`，是重打包产物。
- 影响：面向合规的第三方声明给出错误的依赖版本；且脚本里是单值硬编码，未来各平台 zip 分批更新时也无法表达。
- 顺带一提：该脚本只在 `collect_pandoc_notices()` 里读 `pandoc-windows-amd64.zip` 的 `COPYING.rtf`/`COPYRIGHT.txt`（缺了会 `RuntimeError`），这两份文件是版本无关的，无法借此拿到版本号——要修正只能另取来源（如 `bin/pandoc --version`，或读 zip 内其他随版本变化的文件）。
- 候选标题：`Third-party notices report Pandoc 3.5 while the bundled binaries are 3.10.1`
