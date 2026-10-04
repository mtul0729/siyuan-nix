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

### 抢先版（正式 / beta / alpha 中版本最高者）

同一套 flake 里另有 `-alpha` 后缀的包，追「正式/beta/alpha 中版本最高的那个 release」（`v3.8.7-alpha.1` > `v3.8.6` > `v3.8.6-beta.2`），可能是预发布：

```bash
nix build github:mtul0729/siyuan-nix#siyuan-client-alpha
nix build github:mtul0729/siyuan-nix#siyuan-server-alpha      # 仅 Linux
```

NixOS 模块默认用稳定版；要试用抢先版就换 package：

```nix
services.siyuan.package = siyuan-nix.packages.${pkgs.system}.siyuan-server-alpha;
```

## 常用命令

```bash
nix build -L .#siyuan-server                        # 服务端包（仅 Linux）
nix build -L .#siyuan-server-alpha                  # 抢先版服务端包（仅 Linux）
nix build -L .#siyuan-client                        # 桌面客户端（linux / aarch64-darwin）
nix build -L .#siyuan-client-alpha                  # 抢先版桌面客户端
nix build -L .#checks.x86_64-linux.siyuan-kernel-test    # 内核 go 测试（独立于主构建）
nix flake check --no-build --all-systems            # 三系统纯求值校验
./scripts/update.py                                 # 两套 pin 各按目标升级 + 轮换 FOD 哈希
./scripts/update.py --print-targets                 # 打印两个目标 tag（JSON）
./scripts/update.py --print-pins                    # 打印 8 个 pin（JSON）
```

## 分支

| 分支 | 说明 |
| --- | --- |
| `main` | 唯一发布分支：稳定版与抢先版两套 pin 都在这里 |
| `dev` | 开发分支 |

## 自动升级

`.github/workflows/update.yml` 每天北京时间 03:17（= 前一天 19:17 UTC）跑一次，**在 main 上解析两个互相独立的目标，轮换 pin 后由 bot 直推（不开 PR）**：

- `stable` → 最新**稳定版**（只认 `vX.Y.Z`），喂 `siyuan-server` / `siyuan-client`。
- `alpha` → 正式/beta/alpha 中版本最高者，喂 `siyuan-server-alpha` / `siyuan-client-alpha`。

两者必须是独立的目标：上游习惯正式版一发就紧接着开下一个版本的 alpha（`v3.8.6` 之后立刻有 `v3.8.7-alpha.1`），若只解析一个「最高版本」，`v3.8.7` 发布时窗口里可能已有 `v3.8.8-alpha.1`，stable 那套 pin 就永远拿不到 `v3.8.7`。

验收信号是这次 push 触发的 `build.yml`：**稳定版两套包把关，抢先版只记录不把关**（上游预发布自带问题很常见，例如 `v3.8.7-alpha.3` 的 darwin 客户端 `spawn python3 ENOENT`）；红了 `git revert` 即可。

**为什么不能只解析一个「最高版本」**：上游习惯正式版一发就紧接着开下一个版本的 alpha（`v3.8.6` 之后立刻有 `v3.8.7-alpha.1`），于是 `v3.8.7` 正式发布时窗口里很可能已有 `v3.8.8-alpha.1`——最高版本是那个 alpha，stable 那套 pin 就永远拿不到 `v3.8.7`。stable 的解析必须独立于预发布。

去重发生在两者重合时（最新 release 恰好是正式版）：那一轮哈希轮换只做一次，两套 pin 一起写。最新是预发布时两者本就不同，各轮换一次，那是必需的而非重复。

## nixpkgs（flake.lock）

`.github/workflows/flake-update.yml` 每周一北京时间 03:03 跑一次 `nix flake update`，先在本机做 `nix flake check --no-build` + 两套包的 x86_64-linux 构建当闸门，通过后由 bot 直推 `main`，再盯这次 push 触发的 `build.yml` 全矩阵，红了自动开/更新 issue。只涉及 main 一个分支（两套 pin 同在一个 flake.nix 里，不存在 lock 落后的问题）。

三个 workflow 共用 `.github/actions/setup` 这一个 composite action（装 Nix + cachix daemon，`CACHIX_AUTH_TOKEN` 为空时跳过推送）。

手动触发：

```bash
gh workflow run update.yml                                    # 两套 pin 自动解析
gh workflow run update.yml -f stable_tag=v3.9.0               # 指定 stable 目标
gh workflow run update.yml -f alpha_tag=v3.8.8-alpha.1        # 指定 alpha 目标
gh workflow run update.yml -f force=true                      # tag 未变也重算哈希
gh workflow run flake-update.yml                              # 追 nixpkgs
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
