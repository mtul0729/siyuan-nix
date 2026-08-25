# siyuan-nix

以 [siyuan-note/siyuan](https://github.com/siyuan-note/siyuan) 官方 tag 为源构建的 Nix flake：思源笔记服务端（内核 + 静态资源）、Electron 桌面客户端，以及一个 NixOS 服务模块。支持 `x86_64-linux` 与 `aarch64-linux`，产物推送至 cachix `mtul`。

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
nix build github:mtul0729/siyuan-nix#siyuan-client   # Electron 客户端
nix build github:mtul0729/siyuan-nix                 # 默认输出 = 服务端包
nix profile install github:mtul0729/siyuan-nix#siyuan-client
```

## 常用命令

```bash
nix build -L .#siyuan-server                        # 服务端包
nix build -L .#siyuan-client                        # 桌面客户端
nix build -L .#checks.x86_64-linux.siyuan-kernel    # 内核 go 测试（独立于主构建）
nix flake check --no-build --all-systems            # 双架构纯求值校验
./scripts/update.sh v3.8.2                          # 升级版本（详见脚本头注释）
```

维护者文档：[AGENTS.md](AGENTS.md)（仓库结构与工作流）、[docs/updating.md](docs/updating.md)（升级 SOP 与哈希不变量）、[docs/upstream-issues.md](docs/upstream-issues.md)（暂缓上报的上游问题）。

## FAQ：启动弹「工作空间下的文件正在被第三方软件占用」？

这是退出码 26 的**固定文案**，而退出码 26 涵盖一切文件系统错误——不一定是同步盘/杀毒软件。

真实原因看工作空间日志 `temp/siyuan.log`：若出现 `filelock.go:91: copy [...] failed: open .../conf/appearance/...: permission denied`，即为旧版打包的已知缺陷（store 只读权限被复制进工作空间，下次启动覆盖失败）。

- **3.8.1 及更早的旧包**：应急恢复 `chmod -R u+w <工作空间>/conf/appearance`；注意一次性有效（成功启动一次后会被再次改为只读），彻底解决请升级到包含 gulu 权限替换修复的构建。
- **新包仍复现**：按 AGENTS.md 排查 FOD 哈希是否被静默跳过（见 docs/updating.md）。

其他退出码参考（来自 github.com/siyuan-note/logging）：20=数据库不可用、21=端口不可用、22=安全风险、24=工作空间被锁定、25=初始化工作空间失败、26=文件系统错误。
