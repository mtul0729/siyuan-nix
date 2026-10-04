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

验收信号是 `accept` job 里那三个平台的构建：**稳定版两套包把关，抢先版只记录不把关**（上游预发布自带问题很常见，例如 `v3.8.7-alpha.3` 的 darwin 客户端 `spawn python3 ENOENT`）；红了 `git revert` 即可。

**为什么不能只解析一个「最高版本」**：上游习惯正式版一发就紧接着开下一个版本的 alpha（`v3.8.6` 之后立刻有 `v3.8.7-alpha.1`），于是 `v3.8.7` 正式发布时窗口里很可能已有 `v3.8.8-alpha.1`——最高版本是那个 alpha，stable 那套 pin 就永远拿不到 `v3.8.7`。stable 的解析必须独立于预发布。

去重发生在两者重合时（最新 release 恰好是正式版）：那一轮哈希轮换只做一次，两套 pin 一起写。最新是预发布时两者本就不同，各轮换一次，那是必需的而非重复。

## nixpkgs（flake.lock）

`.github/workflows/flake-update.yml` 每周一北京时间 03:03 跑一次 `nix flake update`，同样走「候选分支 → 三平台验收 → 快进 main」，任一环节失败就开/更新 issue。只涉及 main 一个分支（两套 pin 同在一个 flake.nix 里，不存在 lock 落后的问题）。

## 验收与凭据

三个 workflow 共用两块抽象：

- `.github/actions/setup`（composite action）：装 Nix + cachix daemon，`CACHIX_AUTH_TOKEN` 为空时跳过推送。
- `.github/workflows/accept.yml`：给定 ref，在 `x86_64-linux` / `aarch64-linux` / `aarch64-darwin` 上构建——稳定版两套包把关，抢先版与内核测试只记录。它同时是三种触发的入口：`workflow_call`（`update.yml` / `flake-update.yml` 在直推 main 前调用）、`push` / `pull_request` / `workflow_dispatch`（直接对当前 commit 验收）。一份定义，不会出现「调用方说绿、单独跑说红」。

自动化**不需要 GitHub App**：验收在各 workflow 内部完成，推送用仓库自带的 `GITHUB_TOKEN` 即可。代价要清楚——GitHub 规定 `GITHUB_TOKEN` 产生的 push 不会触发其它 workflow，所以 bot 推上去的 commit 不会再触发 `accept.yml` 的 push 入口；那次验收的结果要看 `update.yml` / `flake-update.yml` 里的 accept job，而 `accept.yml` 的 push 入口只反映人工推送与 PR。唯一需要的 repo secret 是 `CACHIX_AUTH_TOKEN`（推送构建缓存到 cachix `mtul`）。

手动触发：

```bash
gh workflow run update.yml                                    # 两套 pin 自动解析
gh workflow run update.yml -f stable_tag=v3.9.0               # 指定 stable 目标
gh workflow run update.yml -f alpha_tag=v3.8.8-alpha.1        # 指定 alpha 目标
gh workflow run update.yml -f force=true                      # tag 未变也重算哈希
gh workflow run flake-update.yml                              # 追 nixpkgs
```

维护者文档：[AGENTS.md](AGENTS.md)（仓库结构与工作流）、[docs/updating.md](docs/updating.md)（升级 SOP 与哈希不变量）、[docs/upstream-issues.md](docs/upstream-issues.md)（暂缓上报的上游问题）。
