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
> **上游已修复（2026-08-31），本仓库的本地规避补丁已随之删除**（见本节末尾「修复与本仓库处置」）。

- 位置：88250/gulu `file.go::copyFile`（v1.2.3-0.20260609 中约 :327-333）：`os.Create(dest)` 后执行 `os.Chmod(dest, sourceinfo.Mode())`。
- 触发链：
  1. 安装目录资源在 Nix store 中一律只读（444）；
  2. 内核 `InitAppearance()`（kernel/model/appearance.go）每次启动将 WorkingDir 的 appearance 复制到 `<工作空间>/conf/appearance`，目标被 chmod 成 444；
  3. 下次启动覆盖复制时 `os.Create` 对只读目标报 EACCES；`siyuan-note/filelock@v0.0.0-20260411141728/filelock.go:91` 将其视为致命错误，退出码 26 → 第 1 条的误导弹窗。
- 已用标题：`CopyFile preserves source mode, making destinations from read-only sources fail on subsequent overwrites`
- 备用草案（siyuan 侧）：`Workspace appearance copies become read-only and break the next kernel start`

### 修复与本仓库处置

- gulu 侧：本仓库 pin 的 `github.com/88250/gulu v1.2.3-0.20260831011033-1a37069fad34` 中已有 `CopyWritable` 与 `copyFileWithOptions(..., writable)`——`destMode` 改为 `sourceinfo.Mode().Perm() | 0200`（`file.go:359-363`），并新增 `createCopyDestFile()`（`file.go:380-390`）：目标非常规文件或缺属主写位时先 `os.Chmod(dest, destinfo.Mode()|0200)` 再重试 `os.Create`。上面第 3 步的 EACCES 正好被这条 retry 覆盖。
- SiYuan 侧：`kernel/model/appearance.go:48` 从 `filelock.Copy(from, util.AppearancePath)` 改为 `filelock.CopyWritable(...)`（v3.8.3 起即是）；`CopyWritable` 存在于 `siyuan-note/filelock@393425122aaa/filelock.go:97`。
- 本仓库：原先的 `modPostBuild`（把 `os.Chmod(dest, sourceinfo.Mode())` 替换为 `os.Chmod(dest, 0644)`，同 nixpkgs 做法）已在 v3.8.3 升级提交 `e27a512`（2026-09-07）中删除——不是「可以删」而是「必须删」：新 gulu 里那条替换目标已变成 `os.Chmod(dest, destMode)`，`--replace-fail` 会直接硬失败。
- 残留风险（收窄）：删除后 v3.8.5 仍有从 store 往工作空间拷而用的是普通 `Copy` 的调用——`model/mount.go:504`（guide 笔记本）、`model/mount.go:516`（av storage）、`model/appearance_paths_migration.go:127`——拷出来的文件仍是 444。旧 hack 是全局 0644，所以这是一处收窄，而非等价替代。若日后这些路径也报 EACCES，按同一思路上报（改用 `CopyWritable`）即可。

## 3. fetchPnpmDeps 对 store 内每个 `*.json` 跑 jq，pnpm 12 在 darwin 上必红

> 未上报（nixpkgs 侧）。本仓库因此暂时继续使用 `pnpm_11`。

- 位置：nixpkgs `pkgs/build-support/node/fetch-pnpm-deps/default.nix` 的 `fixupPhase`：
  `for f in $(find $storePath -name "*.json"); do jq --sort-keys "del(.. | .checkedAt?)" $f | sponge $f; done`。
- 行为：jq 无法解析 JSONC。pnpm 12 在 `aarch64-darwin` 上把包内文件（含 `tsconfig.json`、`.vscode/launch.json`，均带 `//` 注释）放进 store 路径后，该循环立刻失败，退出码 5，`siyuan-ui-pnpm-deps` 无法构建 → 客户端打包连带失败。
- 证据（2026-09-23，`pnpm_12 = 12.3.4`，分支 `pnpm-12`，run 35862337069）：BADJSON 探针打印出的坏文件形如
  `$storePath/v11/links/@/define-data-property/1.1.4/<hash>/node_modules/define-data-property/tsconfig.json`、
  `.../hasown/2.0.4/<hash>/node_modules/hasown/tsconfig.json`、
  `.../xmlbuilder/15.1.1/<hash>/node_modules/xmlbuilder/.vscode/launch.json`（十余个）。
  同一提交的 linux 两个架构没有这些文件，`jq` 未报错，FOD 正常产出（哈希架构无关：`sha256-aZqEWUae1seSapIwjOa+mdj4yyMFrHc31XHx2tHKfVU=`）。
- 变量隔离：仅 bump nixpkgs、仍用 `pnpm_11` 的分支（run 35861418983）三个平台全绿，故与 nixpkgs 升级无关，锅在 pnpm 12（它是 Rust 重写版，store/links 布局与 11 不同）。
- 本仓库处置：上游 `app/package.json` 自 v3.8.5 起 `packageManager: pnpm@12.3.4`，但 darwin 客户端构建过不去，故留在 `pnpm_11`（`fetcherVersion = 4` 对 11/12 都适用，换版本只需改 3 处引用并重算 `pnpmDeps` 哈希）。待 nixpkgs 修好后再切。
- 候选标题：`fetchPnpmDeps fails on aarch64-darwin with pnpm 12: fixupPhase runs jq over JSONC files in the store`

## 4. 第三方声明里的 Pandoc 版本长期未随内置二进制更新

- 位置：`scripts/generate-third-party-notices.py:346-352`（表项硬编码 `("Pandoc", "3.5", ...)`），产物落在 `THIRD_PARTY_NOTICES.md:68`。
- 行为：`app/pandoc/*.zip` 里实际内置的是 **pandoc 3.10.1**，但声明表一直写 `3.5`。
- 证据（v3.8.3 tag，逐个解包 `app/pandoc/`）：五个平台包（linux/darwin 的 amd64+arm64、windows amd64）的 `bin/pandoc`（或 `bin/pandoc.exe`）均含字面量 `3.10.1`；把 linux-amd64 的那份直接执行，`--version` 输出 `pandoc 3.10.1` / `Features: +server +lua` / `Scripting engine: Lua 5.4`，解压后 163,339,152 B。zip 条目 mtime 全为 `2026-07-22 16:22:44`，是重打包产物。
- 影响：面向合规的第三方声明给出错误的依赖版本；且脚本里是单值硬编码，未来各平台 zip 分批更新时也无法表达。
- 顺带一提：该脚本只在 `collect_pandoc_notices()` 里读 `pandoc-windows-amd64.zip` 的 `COPYING.rtf`/`COPYRIGHT.txt`（缺了会 `RuntimeError`），这两份文件是版本无关的，无法借此拿到版本号——要修正只能另取来源（如 `bin/pandoc --version`，或读 zip 内其他随版本变化的文件）。
- 候选标题：`Third-party notices report Pandoc 3.5 while the bundled binaries are 3.10.1`
