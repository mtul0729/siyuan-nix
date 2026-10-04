# 升级 SOP 与哈希不变量

## 标准流程

```bash
./scripts/update.py                    # 两套 pin 各按自己的目标升级 + 轮换 FOD 哈希
./scripts/update.py --stable v3.9.0    # 只显式指定 stable 的目标（alpha 仍自动解析）
./scripts/update.py --alpha v3.8.8-alpha.1   # 只显式指定 alpha 的目标
./scripts/update.py --force            # tag 未变也重算哈希（改了影响 FOD 内容的东西后要用）
./scripts/update.py --build            # 升级后再冒烟构建两套服务端包
./scripts/update.py --print-pins       # 以 JSON 打印 8 个 pin
./scripts/update.py --print-targets    # 以 JSON 打印两个目标 tag（只查 remote）
```

`scripts/update.py`（Python 3，仅标准库）一步完成「升 tag + 轮换 FOD 哈希」：先把该套 pin 的 tag 与三个哈希写成占位符，再解析出真值写回。任何一步失败都会把 `flake.nix` 按字节还原，不会留下「一半占位、一半真实」的仓库。哈希无法离线预计算，所以需要联网 + nix。

**两套 pin，两个目标**（都在 `flake.nix` 里，各 4 个值：tag + src/vendorHash/pnpmDeps）：

| variant | 目标 | 认哪些 tag | 喂哪些包 |
| --- | --- | --- | --- |
| `stable` | 最新稳定版 | `vX.Y.Z` | `siyuan-server` / `siyuan-client` |
| `alpha` | 正式/beta/alpha 中最高者 | `vX.Y.Z` 与 `vX.Y.Z-alpha.N` / `vX.Y.Z-beta.N` | `siyuan-server-alpha` / `siyuan-client-alpha` |

同一版本号内 alpha < beta < 正式，故 `v3.8.7-alpha.1 > v3.8.6 > v3.8.6-beta.2`；`v202205311650-dev` 这类非版本 tag 两套都不认。两个目标 tag 相同时（最新 release 恰好是正式版）**只轮换一次**，结果同时写进两套 pin——同 tag ⇒ FOD 内容相同 ⇒ 哈希必然相同。

每套三个哈希的解析方式：

| FOD | pin 名 | 解析方式 |
| --- | --- | --- |
| `src` | `stableSrc` / `alphaSrc` | `nix-prefetch-url --unpack`（已核对等价于 `fetchFromGitHub`） |
| `vendorHash` | `stableVendorHash` / `alphaVendorHash` | 占位哈希触发构建，从 `hash mismatch ... got:` 取真值 |
| `pnpmDeps` | `stablePnpmDeps` / `alphaPnpmDeps` | 同上 |

哈希不再写死在 `pkgs/*.nix` 里，而是作为参数注入（`siyuan-kernel.nix` 收 `vendorHash`、`siyuan-ui.nix` 收 `pnpmDepsHash`），因此两个版本共用同一份打包逻辑。8 个 pin 名各自唯一，正则（`^[ \t]*<名字> = "..."$;`）天然只匹配一处，`update.py` 仍强制断言「恰好 1 处」——绝不像写死缩进的 `sed` 那样静默跳过。手动迭代时仍可看 CI 日志里的 `got: sha256-...`，架构无关、两个 matrix 一致。

### 自动升级（GitHub Actions）

`.github/workflows/update.yml` 把上面这套 SOP 自动化，每天北京时间 03:17（= 前一天 19:17 UTC）跑一次（也可 `workflow_dispatch`，可传入 `stable_tag` / `alpha_tag` / `force`）。一次运行解析两个目标，改完 `flake.nix` 后**由 bot 直推 `main`，不开 PR**：

1. `stable` → `siyuan-server` / `siyuan-client`。
2. `alpha` → `siyuan-server-alpha` / `siyuan-client-alpha`。

**必须是两个目标**：若用「最高版本」顺带推出 stable 的目标，更新的 alpha 会遮蔽刚发布的正式版——上游正式版一发就紧接着开下一个版本的 alpha（`v3.8.6` 之后立刻 `v3.8.7-alpha.1`），等 `v3.8.7` 发布时窗口里很可能已有 `v3.8.8-alpha.1`，最高版本是那个 alpha，stable 那套 pin 就永远拿不到 `v3.8.7`，`siyuan-server` 停在旧稳定版上。

真正的跨平台验收是这次 push 触发的 `build.yml`（含 `aarch64-darwin`）：**稳定版两套包把关，抢先版 `continue-on-error` 只记录**（上游预发布自带问题很常见）。推送必须是 App 令牌——`GITHUB_TOKEN` 产生的 push 事件不触发其它 workflow，用它推等于没有 CI。

> 过去两个变体分别放在 `main` 与 `alpha-release` 两个分支上，已废弃：main 独有的内容（workflow、共用的 composite action、打包修复）流不到另一个分支，它自己的 `build.yml` 会因缺文件或旧代码而红（2026-10 撞过一次：它不含 `.github/actions/setup`，构建直接找不到 action）。合成一个分支、用包名区分之后，这类故障在结构上不可能再发生，也不需要 force-push 任何分支。

**身份与秘钥**：workflow 用 GitHub App 令牌而非 `GITHUB_TOKEN`——GitHub 规定 `GITHUB_TOKEN` 产生的事件不触发其它 workflow，那样直推上去的 commit 不会触发 `build.yml`，验收信号就没了。因此需一个 GitHub App（repo variable `APP_CLIENT_ID` + repo secret `APP_PRIVATE_KEY`；权限只给 `Contents: Read and write` 与 `Pull requests: Read and write`）。一次性创建步骤见 README 的“自动升级”一节；私钥丢失/轮换时重建后更新这两个值即可。

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
> 即使没有版本升级，也必须重走占位→got:→回填流程（`./scripts/update.py --force`）。

## nix-update 为何不适用于本仓库

`nix-update` 要求包上存在可定位的字面量 `version` 属性（内部用 `builtins.unsafeGetAttrPos "version"`），而本仓库 version 由 flake.nix 的 `tag` 派生、经 callPackage 以函数参数注入，位置为 null，nix-update 1.16.0 直接求值崩溃（`expected a set but found null`）。**用 `--version=skip` 也绕不过**：该步只跳过版本更新，求值阶段依旧执行 `unsafeGetAttrPos "version"`，2026-09 实测同样崩。若为迁就它把字面量版本散进各 `pkgs/*.nix`，会破坏「tag 单一来源」设计并引入 tag/version 漂移风险——不值得。若未来上游结构允许再评估。
