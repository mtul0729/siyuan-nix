# siyuan-nix

以 [siyuan-note/siyuan](https://github.com/siyuan-note/siyuan) 官方 tag 为源构建的 Nix flake：思源笔记服务端（内核 + 静态资源）、Electron 桌面客户端，以及一个 NixOS 服务模块。服务端与 NixOS 模块支持 `x86_64-linux` / `aarch64-linux`；桌面客户端额外支持 `aarch64-darwin`。产物推送至 cachix `mtul`。

## 安装

### NixOS 服务端模块

```nix
# flake.nix
{
  inputs.siyuan-nix.url = "github:mtul0729/siyuan-nix";

  outputs = { self, siyuan-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        siyuan-nix.nixosModules.default
      ];
    };
  };
}
```

```nix
# configuration.nix
services.siyuan = {
  enable = true;
  accessAuthCode = "改成你的鉴权码"; # 开启 networkServe 时必填
  openFirewall = true;
};
```

完整选项见 `flake.nix` 的 `services.siyuan` 定义（端口、只读模式、SSL、语言、额外参数等）。服务端闭包有意包含 pandoc，docx 导出开箱即用。

### 桌面客户端 / 直接使用包

```bash
nix build github:mtul0729/siyuan-nix#siyuan-client   # Electron 客户端（linux / aarch64-darwin）
nix build github:mtul0729/siyuan-nix                 # 默认输出：Linux 上是服务端包，darwin 上是客户端
nix profile install github:mtul0729/siyuan-nix#siyuan-client
```

## 常用命令

```bash
nix build -L .#siyuan-server                        # 服务端包（仅 Linux）
nix build -L .#siyuan-client                        # 桌面客户端（linux / aarch64-darwin）
nix build -L .#checks.x86_64-linux.siyuan-kernel-test    # 内核 go 测试（独立于主构建）
nix flake check --no-build --all-systems            # 三系统纯求值校验
./scripts/update.py [vX.Y.Z]                         # 升级 tag + 轮换三个 FOD 哈希（详见脚本头注释）
./scripts/update.py --channel=any                    # 同上，但追正式/beta/alpha 中版本最高者
./scripts/update.py --print-pins                     # 打印当前 pin 的 tag/哈希（JSON）
```

## 分支

| 分支 | 跟踪 | 说明 |
| --- | --- | --- |
| `main` | 最新**正式版** | 稳定，由自动 PR 升级（人工合并） |
| `alpha-release` | 正式 / beta / alpha 中版本最高者 | 预发布滚动分支，自动 force-push，供提前试用 |
| `dev` | — | 开发分支 |

想用预发布就把 flake 输入的 ref 指过去：

```nix
inputs.siyuan-nix.url = "github:mtul0729/siyuan-nix/alpha-release";
```

```bash
nix build github:mtul0729/siyuan-nix/alpha-release#siyuan-client
```

## 自动升级

`.github/workflows/update.yml` 每天北京时间 03:17（= 前一天 19:17 UTC）跑一次，**一条流水线解析两个互相独立的目标，都由 bot 直推到对应分支（不开 PR）**：

- `main` → 最新**稳定版**（只认 `vX.Y.Z`），跑 `scripts/update.py` 轮换三个 FOD 哈希后直推 `main`。
- `alpha-release` → 正式/beta/alpha 中版本最高者（`v3.8.7-alpha.1` > `v3.8.6` > `v3.8.6-beta.2`），force-push 直推（上游 alpha 一天能发好几个）。该分支不会合回 `main`。

验收信号就是两个分支各自 push 触发的 `build.yml`（三平台构建 + 内核测试）；红了 `git revert` 即可，没有人工闸门。

**为什么不能只解析一个「最高版本」**：上游习惯正式版一发就紧接着开下一个版本的 alpha（`v3.8.6` 之后立刻有 `v3.8.7-alpha.1`），于是 `v3.8.7` 正式发布时窗口里很可能已有 `v3.8.8-alpha.1`——最高版本是那个 alpha，main 就永远拿不到 `v3.8.7` 的 PR，停在旧稳定版上。stable 的解析必须独立于预发布。

去重只在两者重合时（最新 release 恰好是稳定版）：那一轮哈希轮换只做一次，`alpha-release` 要么取 main 刚算出的 pin，要么（main 已在该 tag）直接置为 main 的 commit。最新是预发布时两者本就不同，alpha 单独轮换一次，那是必需的而非重复。

## nixpkgs（flake.lock）

`.github/workflows/flake-update.yml` 每周一北京时间 03:03 跑一次 `nix flake update`，先在本机做 `nix flake check --no-build` + 两个包的 x86_64-linux 构建当闸门，通过后由 bot 直推 `main`，并只把 `flake.lock` 同步到 `alpha-release`（不动后者的 tag/哈希——它可能停在预发布上）。推送后再盯两个分支各自触发的 `build.yml` 全矩阵，红了自动开/更新 issue。

三个 workflow 共用 `.github/actions/setup` 这一个 composite action（装 Nix + cachix daemon，`CACHIX_AUTH_TOKEN` 为空时跳过推送）。

手动触发：

```bash
gh workflow run update.yml                             # 自动解析
gh workflow run update.yml -f tag=v3.9.0               # main 指定稳定版
gh workflow run update.yml -f alpha_tag=v3.8.7-alpha.1 # alpha-release 指定预发布
gh workflow run update.yml -f force=true               # tag 未变也重算哈希
gh workflow run flake-update.yml                       # 追 nixpkgs
```

### flake.lock 自动更新

`.github/workflows/flake-update.yml` 每周北京时间 03:03（= 周日 19:03 UTC）跑一次 `nix flake update`（与版本升级正交：只动 `flake.lock`，不碰 tag 与 FOD 哈希）。它不走 PR：

- lock 没变 → 结束；
- lock 有变 → 先在 x86_64-linux 上 `nix flake check` + `nix build` 两个包，**通过就直接推上 main**（App 令牌的 push 会自动触发 `build.yml` 做全矩阵复核），**失败则开 issue 通知**，lock 不合入；
- 合入后的全矩阵（含 aarch64-linux / aarch64-darwin，本机 runner 编不了 darwin，只能在这里验证）红了同样自动开 issue。

aarch64-darwin 不在合入前拦截是刻意的：ubuntu runner 编不了它，只能靠合入后的全矩阵 + issue 兜底。另外 `alpha-release` 的 `flake.lock` 不由本 workflow 碰：`update.yml` 每次运行都会把 main 的 lock 同步到该分支（每天一次，最多滞后一天），alpha 上不做 nixpkgs 升级的决策。

手动触发：

```bash
gh workflow run flake-update.yml
```

### 一次性设置：GitHub App

workflow 需要以 GitHub App 身份开 PR，而不是默认的 `GITHUB_TOKEN`——GitHub 规定 `GITHUB_TOKEN` 产生的事件不会触发其它 workflow，那样 PR 上的 `build.yml` 会停在 `action_required` 等待人工批准，自动化就断了一环。用 App 则 PR 作者是 `<app>[bot]`，其 `pull_request` 事件能正常触发 CI。

1. 打开 <https://github.com/settings/apps/new>，填：
   - **Name**：`siyuan-nix-updater`（任意唯一名）
   - **Homepage URL**：`https://github.com/<owner>/<repo>`
   - **Webhook**：取消勾选 `Active`（本 App 不需要 webhook）
   - **Repository permissions**：`Contents` → *Read and write*，`Pull requests` → *Read and write*（其余保持 No access）
   - **Where can this app be installed?** → *Only on this account*，然后 `Create GitHub App`
2. 装到本仓库：App 页面 → `Install App` → 选账号 → `Only select repositories` → 勾选本仓库 → `Install`
3. 写入 App 的 **Client ID**（App 页面上，紧邻 App ID）作为 repo variable：
   ```bash
   gh variable set APP_CLIENT_ID --body <Client ID>
   ```
4. 生成私钥并写入 repo secret：App 页面 → `Private keys` → `Generate a private key`（下载 `.pem`），然后
   ```bash
   gh secret set APP_PRIVATE_KEY < /path/to/private-key.pem
   ```

私钥丢失或轮换时，重复第 3–4 步（同一 App 可生成多把密钥）即可。CI 另需 repo secret `CACHIX_AUTH_TOKEN`（推送构建缓存到 cachix `mtul`）。

维护者文档：[AGENTS.md](AGENTS.md)（仓库结构与工作流）、[docs/updating.md](docs/updating.md)（升级 SOP 与哈希不变量）、[docs/upstream-issues.md](docs/upstream-issues.md)（暂缓上报的上游问题）。
