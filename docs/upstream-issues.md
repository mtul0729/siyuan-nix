# 暂缓上报的上游问题

> 状态：**暂缓**（2026-08-25 决定）。本文档保留证据与思路，待决定上报时直接取用。
> 生成 issue 标题遵循主仓库 AGENTS.md 第 7 条：英文、不以 Fix 开头、客观描述症状。

## 1. Electron 弹窗把一切文件系统错误渲染成「第三方软件占用」

- 位置：`app/electron/main.js` case 26。
- 行为：内核退出码 26（`ExitCodeFileSysErr`，来自 siyuan-note/logging，涵盖所有文件系统错误）固定显示「工作空间下的文件正在被第三方软件（比如同步网盘、杀毒软件等）打开占用……」。
- 实际案例：Nix store 只读权限被复制进工作空间导致覆盖失败（见第 2 条），与同步盘无关，文案严重误导排障方向。真实错误只在 `temp/siyuan.log` 可见。
- 标题草案：`Electron dialog attributes all exit-code-26 file system errors to third-party software lock`

## 2. gulu copyFile 把源文件权限带到目标，只读源导致后续覆盖必败

- 位置：88250/gulu `file.go::copyFile`（v1.2.3-0.20260609 中约 :327-333）：`os.Create(dest)` 后执行 `os.Chmod(dest, sourceinfo.Mode())`。
- 触发链（本仓库已用打包层替换为固定 0644 规避，见 `pkgs/siyuan-kernel.nix` 的 `modPostBuild`，同 nixpkgs 做法）：
  1. 安装目录资源在 Nix store 中一律只读（444）；
  2. 内核 `InitAppearance()`（kernel/model/appearance.go）每次启动将 WorkingDir 的 appearance 复制到 `<工作空间>/conf/appearance`，目标被 chmod 成 444；
  3. 下次启动覆盖复制时 `os.Create` 对只读目标报 EACCES；`siyuan-note/filelock@v0.0.0-20260411141728/filelock.go:91` 将其视为致命错误，退出码 26 → 第 1 条的误导弹窗。
- 候选修复方向（二选一或都提）：
  - gulu 层：copyFile 不应让目标继承源的只读位（至少属主写位），或提供不保留权限的复制变体；
  - SiYuan 层：InitAppearance 覆盖复制前先解除既有文件只读。
    主仓库 `/home/myul/Shared/projects/siyuan` 有未提交草稿：`kernel/model/appearance.go` 新增 `makeAppearanceWritable()`（+26 行，filelock.Copy 前递归加属主写位、跳过符号链接）。若推进需先按主仓库 AGENTS.md 跑 gofmt。
- 标题草案（gulu）：`Copy preserves source read-only mode, making subsequent overwrites of the destination fail`
- 标题草案（siyuan）：`Workspace appearance copies become read-only and break the next kernel start`

## 3. 内核测试假定完整仓库布局（`../../app/*`），脱离全量 checkout 即失败

`checks.siyuan-kernel-test`（见 `flake.nix` checks）按设计全量跑 `go test ./...`、不加任何跳过；失败即证据。当前 v3.8.2 下共 7 个失败测试，x86_64/aarch64 的 Nix 沙箱一致复现。共因：`siyuan-kernel.nix` 的 `src` 只有 `kernel/` 子树（`src + "/kernel"`），而这些测试按 `../../app/…` 相对路径读取语言目录、字体、stage、pandoc 资源——测试工作目录（kernel 模块根）之上没有 `app/` 兄弟目录。

| 测试 | 包 | 失败签名 |
|---|---|---|
| TestAuthPageActionLayout | server | `serve_auth_test.go:31: open ../../app/stage/auth.html: no such file or directory` |
| TestSecureAssetContentHeadersForcesAttachmentOnUnknownExtension | server | `serve_assets_test.go:354: test precondition failed: .xyz unexpectedly has a MIME type` |
| TestSystemPromptUsesAppearanceLanguage | agent | `prompt_test.go:134: appearance language is missing from system prompt`（读不到 `app/appearance/langs`） |
| TestDocumentTemplatesWaitForDatabaseIndex | model | `file_index_test.go:171: document template SQL subprocess failed: exit status 26`（链路内 `open ../../app/appearance/langs` 失败） |
| TestCustomFontLifecycle | util | `custom_font_test.go:41: open ../../app/appearance/fonts/LxgwWenKai-Lite-1.501/LXGWWenKaiLite-Regular.ttf: no such file or directory` |
| TestParseBundledFontLocalizedName | util | `font_test.go:110: open ../../app/appearance/fonts/LxgwWenKai-Lite-1.501/LXGWWenKaiLite-Regular.ttf: no such file or directory` |
| TestInitPandocDoesNotUseWorkspaceTemp | util | `pandoc_test.go:54: workspace temporary Pandoc was selected: "/nix/store/…/pandoc"`（本仓库注入 nix pandoc 路径后与断言相撞） |

标题草案：`Kernel unit tests hardcode ../../app paths assuming a full checkout and fail in a kernel-only build tree`——上报时可附各失败签名。
