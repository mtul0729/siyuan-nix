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

## 3. v3.8.1 新增测试在 Linux 上自身失败

CI（Nix 沙箱，x86_64/aarch64 一致复现；部分项纯逻辑断言失败，与沙箱无关）。本仓库暂以 `checkFlags -skip` 跳过（见 `pkgs/siyuan-kernel.nix` 注释分类）：

| 测试 | 包 | 症状 |
|---|---|---|
| TestPublishReaderCannotBrowseEncryptedNotebook | api | SaveConf 重载后 `model.Conf.FileTree` 为 nil，filetree.go:1304 空指针 panic |
| TestAddAttributeViewBlockAcceptsValidBoundItemWithoutDatabaseBlock | model | 未创建 Box 即经 box.go/conf.go 链路解引用 panic |
| TestIsForbiddenDataRelPath / TestIsForbiddenAbsPath / TestIsForbiddenAbsPathSymlinkBypass | util | path_guard 断言与 Linux 实现不匹配（publish 特性新增，纯函数表测即失败） |
| TestCustomFontLifecycle / TestParseBundledFontLocalizedName | model | 依赖系统字体环境 |
| TestDocumentTemplatesWaitForDatabaseIndex | model | 依赖 workspace/数据库索引初始化 |
| TestAuthPageActionLayout / TestHistoryRouteBlocksSensitiveSnapshots / TestRepoDiffRouteBlocksSensitivePaths | server | 依赖完整 appearance 初始化的路由渲染 |

标题草案：`Unit tests fail on Linux in v3.8.1 (nil dereference, path guard assertions, font environment)`——上报时可附各测试失败签名。
