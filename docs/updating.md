# 升级 SOP 与哈希不变量

## 标准流程

```bash
./scripts/update.py              # 升到上游最新稳定版；也可传显式 tag，如 v3.9.0
./scripts/update.py --channel=any # 升到正式/beta/alpha 中版本最高者（alpha-release 分支用）
./scripts/update.py --force      # tag 未变也重算哈希（改了影响 FOD 内容的东西后要用）
./scripts/update.py --build      # 升级后再冒烟构建 siyuan-server
./scripts/update.py --print-pins # 以 JSON 打印当前 pin 的 tag 与三个哈希
```

`scripts/update.py`（Python 3，仅标准库）一步完成「升 tag + 轮换三个 FOD 哈希」：先把 tag 与三个哈希写成占位符，再解析出真值写回。任何一步失败都会把四个 pin 回滚到原状，不会留下「一半占位、一半真实」的仓库。哈希无法离线预计算，所以需要联网 + nix。

`--channel` 决定「最新」的含义（`version_key` 据此排序）：

| channel | 认哪些 tag | 用于 |
| --- | --- | --- |
| `stable`（默认） | `vX.Y.Z` | `main` |
| `any` | `vX.Y.Z` 与 `vX.Y.Z-alpha.N` / `vX.Y.Z-beta.N` | `alpha-release` |

同一版本号内 alpha < beta < 正式，故 `v3.8.7-alpha.1 > v3.8.6 > v3.8.6-beta.2`；`v202205311650-dev` 这类非版本 tag 两个 channel 都不认。

三个哈希的解析方式：

| FOD | 位置 | 解析方式 |
| --- | --- | --- |
| `src` | `flake.nix`（`fetchFromGitHub.hash`） | `nix-prefetch-url --unpack`（已核对等价于 `fetchFromGitHub`） |
| `vendorHash` | `pkgs/siyuan-kernel.nix` | 占位哈希触发构建，从 `hash mismatch ... got:` 取真值 |
| `pnpmDeps` | `pkgs/siyuan-ui.nix` | 同上 |

正则锚定到语义块（`fetchFromGitHub { ... hash = ... }`、`vendorHash`、`fetchPnpmDeps { ... }`）且强制断言恰好匹配 1 处，不匹配就报错——绝不像写死缩进的 `sed` 那样静默跳过。手动迭代时（改完 Push 再推）仍可看 CI 日志里的 `got: sha256-...`，架构无关、两个 matrix 一致。

### alpha-release 分支（预发布滚动跟踪）

`alpha-release` 追「正式 / beta / alpha 三者中版本最高的那个 release」，由同一条 `update.yml` 在 main 阶段之后滚动，**force-push 直接落盘**，不开 PR——上游 alpha 一天能发好几个（`v3.8.6-alpha.1..10`），逐个开 PR 会淹没真正要人看 CI 的 main 升级单。验收同样由该分支上的 `build.yml` 给出（含 darwin）。

三个不能动的点：

1. **checkout 必须是 `alpha-release` 本身**：该分支的 tag/哈希与 `main` 不同，从 `main` 起算会把 `main` 的 pin 当基准，可能把分支回退到旧正式版。
2. **推送必须用 App 令牌**：`GITHUB_TOKEN` 产生的 push 事件不触发其它 workflow，用默认令牌推等于没有 CI。
3. **该分支不合回 `main`**：`main` 只追稳定版，两者是独立的滚动序列。

### 自动升级（GitHub Actions）

`.github/workflows/update.yml` 把上面这套 SOP 自动化，每天北京时间 03:17（= 前一天 19:17 UTC）跑一次，**一条流水线同时喂 `main` 与 `alpha-release`**（也可 `workflow_dispatch`，可传入 `tag` / `alpha_tag` / `force`）。流程：

1. **阶段一（main）**：`python3 scripts/update.py` 检测上游最新 **稳定** tag（`git ls-remote` + `vX.Y.Z` 正则，滤掉 `-alpha`/`-beta` 与 `v202205311650-dev` 这类非版本 tag），与现行 tag 相同则直接退出；否则提交到 `auto-update/siyuan-<tag>` 分支并开 PR（同一 tag 已有开启的 PR 时只跳过开单，分支照建——阶段二要用它上面的 pin）。
2. **阶段二（alpha-release）**：按「能不能复用阶段一的成果」分三种：
   - 目标 tag == `main` 当前 pin 的 tag → `git reset --hard origin/main`，该分支直接变成 main 的那个 commit（同 SHA，零哈希轮换）。只有「分支 tip 已经是 main 的那个 commit」时才跳过（不 push、不触发 CI）——这里比的是 **commit 而非 tree**：「tree 相同但 SHA 不同」正是要消掉的重复，比 tree 会让它永远对齐不过来。
   - 目标 tag == main 本次要升到的 tag（PR 还没合）→ 直接取 `auto-update/siyuan-<tag>` 分支的 `flake.nix` + `pkgs/*.nix`，不重跑两个 FOD 构建。
   - 否则（最新是预发布）→ 在 `alpha-release` 的 checkout 上跑 `scripts/update.py --channel=any`，做一次完整轮换。

合在一条流水线里的原因：稳定版发布时两个分支的目标 tag 相同、三个哈希也必然相同，拆成两条会各跑一遍 go modules / pnpm 两个 FOD 真构建、各占一个 runner。剩下的 CI 重复不用管——tag + 哈希一致 ⇒ 推导 store path 一致 ⇒ 第二次构建是 cachix 命中，push 已存在的路径是 no-op。

真正的跨平台验收仍是 `build.yml`：main 侧在该 PR 上运行（含 `aarch64-darwin`），人工点合并；alpha 侧在该分支的 push 上运行。

**身份与秘钥**：workflow 用 GitHub App 令牌而非 `GITHUB_TOKEN`——GitHub 规定 `GITHUB_TOKEN` 产生的事件不触发其它 workflow，那样 PR 上的 `build.yml` 会停在 `action_required` 需人工批准。因此需一个 GitHub App（repo variable `APP_CLIENT_ID` + repo secret `APP_PRIVATE_KEY`；权限只给 `Contents: Read and write` 与 `Pull requests: Read and write`），这样 PR 作者是 `<app>[bot]`、其 `pull_request` 事件能自动触发 CI。一次性创建步骤见 README 的“自动升级”一节；私钥丢失/轮换时重建后更新这两个值即可。

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
