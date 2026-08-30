# 升级 SOP 与哈希不变量

## 标准流程

```bash
./scripts/update.sh v3.8.2        # 改 flake.nix 的 tag + src，三个 FOD 哈希（src/vendor/pnpm）重置为占位符
git commit -m "Bump siyuan to 3.8.2"
git push origin dev               # 建议 dev 分支验证；main 的 push 会自动触发 CI
gh workflow run build.yml --ref dev   # 非 push 触发分支需手动 dispatch
# CI 首轮必失败：从日志取三个 got: sha256-...（架构无关，两个 matrix 一致）
#   srcHash       -> flake.nix（mkSrc，fetchFromGitHub 的 hash）
#   vendorHash    -> pkgs/siyuan-kernel.nix
#   pnpmDeps.hash -> pkgs/siyuan-ui.nix
# 回填后再推，CI 绿后合并 main
```

哈希无法离线预计算；本地无代理访问 proxy.golang.org 会 EOF，因此按仓库惯例走 CI 日志迭代。

> 关于 `siyuan-kernel-test`：CI 里的内核测试步骤跑红是**设计内常态**，不是升级失败的信号。
> 它的唯一作用是把上游测试全量跑出来、收集沙箱中失败的证据（见 `flake.nix` 的 checks 注释与 AGENTS.md）。
> 升级的验收只看两个包：`siyuan-server` 与 `siyuan-client` 构建成功即视为绿，无需理会该 check。

## 为什么占位哈希是必须的（FOD 路径碰撞陷阱）

固定输出推导的 store 路径**只由 `name + 声明的哈希` 决定，与构建脚本内容无关**：

- 升级/改动时若保留旧哈希，新推导与旧产物算出同一输出路径；
- Nix 发现该路径已在 store/cachix 中 → **静默跳过构建**；
- 结果：依赖不更新、vendor 补丁不生效、无任何报错。2026-08 的 gulu 权限替换（modPostBuild）就因旧 vendorHash 未轮换而静默失效近一天。

占位符 `sha256-AAAA…` 同时改变声明哈希与输出路径，强制真实构建，首轮 CI 必以 `hash mismatch ... got:` 失败——这正是我们要的回填来源。

### 不变量

> **声明的 FOD 哈希必须永远等于「当前构建脚本实际产出」的树哈希。**
> 任何影响 FOD 内容的改动（`modPostBuild`、go.mod 依赖、pnpm lockfile、fetcher 版本……）之后，
> 即使没有版本升级，也必须重走占位→got:→回填流程。

## nix-update 为何不适用于本仓库

`nix-update` 要求包上存在可定位的字面量 `version` 属性（内部用 `builtins.unsafeGetAttrPos "version"`），而本仓库 version 由 flake.nix 的 `tag` 派生、经 callPackage 以函数参数注入，位置为 null，nix-update 1.16.0 直接求值崩溃。若为迁就它把字面量版本散进各 `pkgs/*.nix`，会破坏「tag 单一来源」设计并引入 tag/version 漂移风险——不值得。若未来上游结构允许再评估。
