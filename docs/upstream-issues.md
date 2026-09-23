# 上游问题与上报记录

> 状态：第 1~2 条已于 2026-08-31 **上报**（issue 号见各条）；第 3 条是**阻塞项**（nixpkgs 侧，挡住 pnpm 12），**上游已有 PR 在修**（[#565315](https://github.com/NixOS/nixpkgs/pull/565315)，fetcherVersion 5，见该节「上游进展」）；其余保留证据与思路，待决定时直接取用。
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

## 3. fetchPnpmDeps 对 store 内每个 `*.json` 跑 jq，pnpm 12 在 aarch64-darwin 上必红

> 上游已有 PR 在修：[NixOS/nixpkgs#565315](https://github.com/NixOS/nixpkgs/pull/565315)（新增 `fetcherVersion = 5`）。**本仓库在该 PR 合并前继续使用 `pnpm_11`。**

### 结论

上游 `app/package.json` 自 **v3.8.4** 起 `packageManager` 就是 `pnpm@12.3.4`（v3.8.3 还是 `pnpm@11.25.0`，官方 Dockerfile 用 corepack 强制该版本），nixpkgs 的 `pnpm_12` 恰好也是 12.3.4——**方向是对的，但切不过去**：nixpkgs 的 `fetchPnpmDeps` 在 darwin 上会被包内 JSONC 文件（带 `//` 注释的 `tsconfig.json` 等）打崩，而 `siyuan-ui` 的 `pnpmDeps` 是 linux 与 darwin 共用的一个 FOD，darwin 红就等于 darwin 客户端发不出去。

### 症状

- 推导：`siyuan-ui-pnpm-deps`（`pkgs/siyuan-ui.nix` 的 `fetchPnpmDeps`，`fetcherVersion = 4`）。
- 表现：pnpm 安装本身是成功的（日志末行 `Done in 5.3s using pnpm v12.3.4`），随后 `fixupPhase` 第一行就报 `jq: parse error: Invalid numeric literal at line 3, column 7`，builder 退出码 5，`siyuan-client` 连带失败。
- 平台差异：linux（x86_64 / aarch64）完全正常，能算出 FOD 哈希；只有 `aarch64-darwin` 红。

### 根因

nixpkgs `pkgs/build-support/node/fetch-pnpm-deps/default.nix` 的 `fixupPhase`：

```bash
rm -rf $storePath/{v3,v10,v11}/tmp
for f in $(find $storePath -name "*.json"); do
  jq --sort-keys "del(.. | .checkedAt?)" $f | sponge $f
done
```

它对 store 里**每一个** `*.json` 都跑 jq，而 jq 不能解析 JSONC。pnpm 12 在 darwin 上把包内文件实体化到 `$storePath/v11/links/@/<pkg>/<ver>/<hash>/node_modules/<pkg>/` 下（Rust 重写版的 links 布局与 11 不同；linux 上这些路径不存在，故探针在 linux 一条 BADJSON 都没打出来）。命中即失败——nix stdenv 的 `pipefail` 让 jq 的非零状态穿透出 `| sponge` 管道。

### 对照实验（2026-09-23，三次 CI run）

| 分支 / 提交 | 内容 | x86_64-linux | aarch64-linux | aarch64-darwin | run |
| --- | --- | --- | --- | --- | --- |
| `nixpkgs-bump-only`（0738944） | 只 bump nixpkgs（b1b87598 → 6774f7bc），仍 `pnpm_11` | ✓ | ✓ | ✓ | [35861418983](https://github.com/mtul0729/siyuan-nix/actions/runs/35861418983) |
| `pnpm-12`（58ed539c） | 上面 + `pnpm_11` → `pnpm_12`（占位哈希） | 哈希失配（正常） | 哈希失配（正常） | ✗ jq parse error | [35860892800](https://github.com/mtul0729/siyuan-nix/actions/runs/35860892800) |
| `pnpm-12`（e12492d0） | 同上 + BADJSON 探针 | 哈希失配 | 哈希失配 | ✗ + 打印坏文件 | [35862337069](https://github.com/mtul0729/siyuan-nix/actions/runs/35862337069) |

第二次 run 排除了「nixpkgs bump 的锅」：只 bump lock、仍用 `pnpm_11` 时三平台全绿。

**坏文件清单**（探针 `find "$storePath" -name "*.json"` + `jq -e .`，16 个文件 / 15 个包）：

```
v11/links/@/define-data-property/1.1.4/<hash>/node_modules/define-data-property/tsconfig.json
v11/links/@/es-errors/1.3.0/<hash>/node_modules/es-errors/tsconfig.json
v11/links/@/math-intrinsics/1.1.0/<hash>/node_modules/math-intrinsics/tsconfig.json
v11/links/@/has-tostringtag/1.0.2/<hash>/node_modules/has-tostringtag/tsconfig.json
v11/links/@/call-bind-apply-helpers/1.0.2/<hash>/node_modules/call-bind-apply-helpers/tsconfig.json
v11/links/@/xmlbuilder/15.1.1/<hash>/node_modules/xmlbuilder/.vscode/launch.json
v11/links/@/es-define-property/1.0.1/<hash>/node_modules/es-define-property/tsconfig.json
v11/links/@/dunder-proto/1.0.1/<hash>/node_modules/dunder-proto/tsconfig.json
v11/links/@/hasown/2.0.4 与 2.0.3/<hash>/node_modules/hasown/tsconfig.json（各 1）
v11/links/@/has-symbols/1.1.0/<hash>/node_modules/has-symbols/tsconfig.json
v11/links/@/get-proto/1.0.1/<hash>/node_modules/get-proto/tsconfig.json
v11/links/@/gopd/1.2.0/<hash>/node_modules/gopd/tsconfig.json
v11/links/@/es-set-tostringtag/2.1.0/<hash>/node_modules/es-set-tostringtag/tsconfig.json
v11/links/@/domhandler/3.0.0/<hash>/node_modules/domhandler/tsconfig.json
v11/links/@/es-object-atoms/1.1.2/<hash>/node_modules/es-object-atoms/tsconfig.json
```

这些 `tsconfig.json` / `.vscode/launch.json` 是包作者写的 JSONC（带 `//` 注释），本身完全合法，问题只在于 fetcher 拿 jq 去扫所有 `*.json`。

### 为什么不在本仓库绕过

理论上可以给 `pnpmDeps` 加 `.overrideAttrs` 替换 `fixupPhase`，但那等于复刻 nixpkgs 的 fetcher 内部实现（store 版本目录、state db 转储、SQL dump 兼容处理都在那段里），一旦上游改 fetcherVersion 就静默失效——正是 AGENTS.md 里「FOD 哈希不变量」那类坑。不值得。**等上游修**。

### 上游进展（2026-09-23 查证）

**[NixOS/nixpkgs#565315「fetchPnpmDeps: add fetcherVersion 5」](https://github.com/NixOS/nixpkgs/pull/565315)**（2026-09-20 开，open，+225/−7，11 files，head `pnpm-v5`）正是修这个的，其摘要与本节的根因逐字对应：

> When pnpm's global virtual store is enabled, `fetchPnpmDeps` currently archives materialized packages under `v11/links`. Package payloads there may contain JSONC, which fails the fetcher's JSON metadata normalization.

做法：新增 `fetcherVersion = 5`，把虚拟 store 的实体化重定向到临时目录，只归档内容寻址 store 及其元数据，`pnpmConfigHook` 在离线安装时重建；**v4 继续受支持**。自带回归测试 `tests.pnpm.pnpm_12_v5`，用 `@pnpm/npm-conf@3.0.3`（`lib/tsconfig.make-out.json` 是 JSONC）复现；作者 Qusic 在评论里明确「it's not a reproducibility issue but build failure (similar issues found in #501300, #537020)」。pnpm maintainer Scrumplex 已参与，prepare/treefmt/commits 等检查绿。

**前情**

- [#501300](https://github.com/NixOS/nixpkgs/pull/501300)（2026-03-19，**已关闭未合并**）：最早提出把 `find` 从整个 store 收窄到 `*/index/*` 以避开 `links/`，Scrumplex 回「So perhaps we should just exclude `links/` instead?」——思路后来演变成 v5。评论里 MCSeekeri 报的坏文件是 `links/.../typedoc/tsconfig.json`，与本仓库同类。
- [#537020（xmcl）](https://github.com/NixOS/nixpkgs/pull/537020)（2026-06）：另一个包撞同一个 `jq: parse error`，坏文件来自三方依赖而非项目源码。
- [noosxe/worker-mcp#62](https://github.com/noosxe/worker-mcp/issues/62)（2026-09-23）：同症状、同 pnpm 12.3.4 + aarch64-darwin，但该 issue 主张**不挑平台**（坏文件是 typescript 7.0.2 的平台包，落在内容寻址 store 而非 `links/`）。与本仓库实测的「只在 darwin 红」机制不同，属同一 fixupPhase 缺陷的另一种触发路径。

### 复检清单（什么时候可以再切）

1. **[#565315](https://github.com/NixOS/nixpkgs/pull/565315) 合并**（不再把 `v11/links` 归档进产物，因此不再对包内 JSON 盲跑 jq）；合并前不要切；
2. 改 4 处：`pkgs/siyuan-ui.nix` 的 `pnpm_12` 入参、`fetchPnpmDeps.pnpm`、`fetchPnpmDeps.fetcherVersion`（4 → **5**）、`nativeBuildInputs`，以及 `pkgs/siyuan-client.nix` 的入参与 `nativeBuildInputs`；
3. `fetcherVersion` 提到 5 后 pnpmDeps 哈希与 v4 不同，需重走占位哈希 → CI 回填。**v4 下已测得的 pnpm 12 哈希（linux 两架构一致，darwin 因本条问题拿不到）**：`sha256-aZqEWUae1seSapIwjOa+mdj4yyMFrHc31XHx2tHKfVU=`（对应 v3.8.5 的 lockfile，换 tag 需重算）；切到 v5 后此值作废；
4. nixpkgs 的 `pkgs/by-name/si/siyuan` 同步受益：2026-09-23 的升级 PR [#566176](https://github.com/NixOS/nixpkgs/pull/566176) 就是因本条关闭的。

### 上报用

> 已有 #565315 在修，**除非该 PR 被弃，否则不必再开 issue**；真要开就在它上面补本仓库的实测（16 个坏文件清单、`nixpkgs-bump-only` 对照 run）。

- 候选标题：`fetchPnpmDeps fails on aarch64-darwin with pnpm 12: fixupPhase runs jq over JSONC files in the store`
- 备用草案：`pnpm 12 store links contain tsconfig.json (JSONC), breaking fetchPnpmDeps' jq normalization on darwin`
- 附：nixpkgs 复现最小条件（任一用了 `fetchPnpmDeps` + `pnpm_12` 且依赖树里含 `hasown` / `define-data-property` 之类带 JSONC 的包，在 aarch64-darwin 上构建）。

## 4. 第三方声明里的 Pandoc 版本长期未随内置二进制更新

- 位置：`scripts/generate-third-party-notices.py:346-352`（表项硬编码 `("Pandoc", "3.5", ...)`），产物落在 `THIRD_PARTY_NOTICES.md:68`。
- 行为：`app/pandoc/*.zip` 里实际内置的是 **pandoc 3.10.1**，但声明表一直写 `3.5`。
- 证据（v3.8.3 tag，逐个解包 `app/pandoc/`）：五个平台包（linux/darwin 的 amd64+arm64、windows amd64）的 `bin/pandoc`（或 `bin/pandoc.exe`）均含字面量 `3.10.1`；把 linux-amd64 的那份直接执行，`--version` 输出 `pandoc 3.10.1` / `Features: +server +lua` / `Scripting engine: Lua 5.4`，解压后 163,339,152 B。zip 条目 mtime 全为 `2026-07-22 16:22:44`，是重打包产物。
- 影响：面向合规的第三方声明给出错误的依赖版本；且脚本里是单值硬编码，未来各平台 zip 分批更新时也无法表达。
- 顺带一提：该脚本只在 `collect_pandoc_notices()` 里读 `pandoc-windows-amd64.zip` 的 `COPYING.rtf`/`COPYRIGHT.txt`（缺了会 `RuntimeError`），这两份文件是版本无关的，无法借此拿到版本号——要修正只能另取来源（如 `bin/pandoc --version`，或读 zip 内其他随版本变化的文件）。
- 候选标题：`Third-party notices report Pandoc 3.5 while the bundled binaries are 3.10.1`
