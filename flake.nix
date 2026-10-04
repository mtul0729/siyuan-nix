# SiYuan 服务器 Nix Flake：以 siyuan-note/siyuan 官方仓库为源，构建「内核 + 前端静态资源」服务器包
# 与 Electron 桌面客户端，并提供 NixOS systemd 服务模块。
#
# 常用命令：
#   nix build .#siyuan-server            服务器包（含 SiYuan-Kernel 内核与 appearance/stage 等静态资源；稳定版）
#   nix build .#siyuan-server-alpha      同上，但追「正式/beta/alpha 中版本最高者」（可能是预发布）
#   nix build .#siyuan-client            桌面客户端（Electron；x86_64-linux / aarch64-linux / aarch64-darwin）
#   nix build .#siyuan-client-alpha      桌面客户端的抢先版
#
# 平台范围：服务端与 NixOS 模块只提供 Linux 版，darwin 上只提供 siyuan-client
# （客户端依赖的 kernel / ui 两个包也相应声明支持 darwin）。
#   nix build .#siyuan-server.passthru.kernel.goModules   单独预取 Go 依赖（vendorHash 变更后用于校验）
#   nix build .#siyuan-server.passthru.ui.pnpmDeps        单独预取 pnpm 依赖（pnpmDeps hash 变更后用于校验）
#   nix flake update siyuan-src          升级 SiYuan 源码到新 tag
#
# 升级 SiYuan 版本步骤（详见 AGENTS.md 与 docs/updating.md）：
#   ./scripts/update.py            两套 pin 各按自己的目标升 tag 并轮换 FOD 哈希
#   ./scripts/update.py --print-targets   打印两个目标（stable / alpha）
#   8 个 pin 全在本文件的 stable* / alpha* 里，是唯一需要改的地方。
#
# 在 NixOS 配置中启用：
#   imports = [ siyuan-nix.nixosModules.default ];
#   services.siyuan = {
#     enable = true;
#     accessAuthCode = "改成你的鉴权码";
#     openFirewall = true;
#   };
{
  description = "SiYuan note server & desktop client with a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # 两套 pin，彼此独立，都由 scripts/update.py 维护（8 个值集中在这一个文件里）：
      #   stable → 最新正式版（vX.Y.Z）        ：siyuan-server / siyuan-client
      #   alpha  → 正式/beta/alpha 中最高者    ：siyuan-server-alpha / siyuan-client-alpha
      #        （“最高者”可能是预发布，也可能是刚发布的正式版，此时两套 pin 相同）
      stableTag = "v3.8.6";
      stableSrc = "sha256-rHNhrEXf9OW+t4RVz6HZFTXpEDqpIiD25JYUdV8PEM0=";
      stableVendorHash = "sha256-wJInCkkyVIDR3DHsvyQMWVKramQzWTdpwAIXTzZOKrg=";
      stablePnpmDeps = "sha256-E46qhUps5zstSP9xfEWOsg6qWWckbxzWvKZivgSFKik=";

      alphaTag = "v3.8.7-alpha.3";
      alphaSrc = "sha256-O5/Sbop94+YeUvk+I0snVq6JGItwZfoAbJLhMOTdH7U=";
      alphaVendorHash = "sha256-zc4K2X2twqJdYniS0wZTjcXStfdsPKoZia3Y5AxI6Es=";
      alphaPnpmDeps = "sha256-Inb7jIgMYDrm92LuL2ua7y/i2zz02QARZpJ4ukh/uAg=";

      # 按一套 pin 构建一整套包。suffix 决定包名后缀（稳定版无后缀，抢先版 -alpha）。
      mkVariant =
        {
          pkgs,
          system,
          tag,
          srcHash,
          vendorHash,
          pnpmDepsHash,
          suffix ? "",
        }:
        let
          # 平台判断用纯函数从 system 推导，绝不触碰 pkgs.stdenv / final：
          # overlay 求值脊上读取 final 派生值会触发 nixpkgs fixpoint 求值循环。
          isLinux = (nixpkgs.lib.systems.elaborate { inherit system; }).isLinux;
          version = nixpkgs.lib.removePrefix "v" tag;
          src = pkgs.fetchFromGitHub {
            owner = "siyuan-note";
            repo = "siyuan";
            rev = tag;
            hash = srcHash;
          };
          # 单一内核，注入 pandoc 路径补丁使 docx 导出开箱即用；
          # 服务端闭包因此引入 pandoc（有意为之）
          kernel = pkgs.callPackage ./pkgs/siyuan-kernel.nix {
            inherit version src vendorHash;
            patches = [
              (pkgs.replaceVars ./pkgs/set-pandoc-path.patch {
                pandoc_path = pkgs.lib.getExe pkgs.pandoc;
              })
            ];
          };
          ui = pkgs.callPackage ./pkgs/siyuan-ui.nix {
            inherit version src;
            pnpmDepsHash = pnpmDepsHash;
          };
        in
        {
          "siyuan-client${suffix}" = pkgs.callPackage ./pkgs/siyuan-client.nix {
            inherit version src kernel;
            pnpmDeps = ui.pnpmDeps;
          };
        }
        # 服务端（连同它承载的 NixOS 模块）只提供 Linux 版：darwin 上只提供客户端。
        // nixpkgs.lib.optionalAttrs isLinux {
          "siyuan-server${suffix}" = pkgs.callPackage ./pkgs/siyuan-server.nix {
            inherit
              version
              src
              ui
              kernel
              ;
          };
        };

      mkPackages =
        {
          pkgs,
          system,
        }:
        mkVariant {
          inherit pkgs system;
          tag = stableTag;
          srcHash = stableSrc;
          vendorHash = stableVendorHash;
          pnpmDepsHash = stablePnpmDeps;
        }
        // mkVariant {
          inherit pkgs system;
          tag = alphaTag;
          srcHash = alphaSrc;
          vendorHash = alphaVendorHash;
          pnpmDepsHash = alphaPnpmDeps;
          suffix = "-alpha";
        };

    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          packages = mkPackages { inherit pkgs system; };
        in
        packages
        // {
          # Linux 上是服务端，darwin 上只有客户端
          default = packages.siyuan-server or packages.siyuan-client;
        }
      );

      # siyuan-kernel-test：内核真实测试推导（与主构建解耦），nix build .#checks.<system>.siyuan-kernel-test。
      # 作用：单次 go test ./... 原样全量跑上游内核测试（不加任何 -skip），一次收集全部失败包。
      #       开发者都是在完整 checkout 下跑测试，本推导只剪出 kernel/ 子树，故若干读 ../../app/*
      #       资源的测试在沙箱里必红——这是打包环境差异，不是上游问题，无需上报。
      # 注意：该 check 构建失败是设计内常态，不是本仓库回归——它专门用来暴露沙箱中跑不过的测试。
      #       严禁为让 CI 变绿而加 checkFlags 跳过；版本升级验收只看 siyuan-server / siyuan-client。
      # 只在提供 siyuan-server 的平台给出（该推导由服务端包的 passthru.kernel 派生，而服务端只有 Linux 版）。
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          packages = mkPackages { inherit pkgs system; };
        in
        nixpkgs.lib.optionalAttrs (packages ? siyuan-server) {
          siyuan-kernel-test = packages.siyuan-server.passthru.kernel.overrideAttrs {
            pname = "siyuan-kernel-test";
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              go test -vet=off -tags=fts5,sqlcipher ./...
              runHook postCheck
            '';
            installPhase = "touch $out";
          };
        }
      );

      overlays.default =
        final: prev:
        mkPackages {
          pkgs = final;
          system = prev.stdenv.hostPlatform.system;
        };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.siyuan;
          workspaceDir = "/var/lib/siyuan";
          system = pkgs.stdenv.hostPlatform.system;
          execArgs = lib.escapeShellArgs (
            [
              (lib.getExe' cfg.package "siyuan-kernel")
              "serve"
              "--workspace"
              workspaceDir
              "--wd"
              "${cfg.package}/lib/siyuan"
              "--port"
              (toString cfg.port)
              "--accessAuthCode"
              cfg.accessAuthCode
              "--mode"
              "prod"
            ]
            ++ lib.optionals cfg.readOnly [
              "--readonly"
              "true"
            ]
            ++ lib.optionals cfg.ssl [ "--ssl" ]
            ++ lib.optionals (cfg.lang != null) [
              "--lang"
              cfg.lang
            ]
            ++ cfg.extraArgs
          );
        in
        {
          options.services.siyuan = {
            enable = lib.mkEnableOption "SiYuan 笔记服务器";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.siyuan-server;
              defaultText = lib.literalExpression "siyuan-nix.packages.\${system}.siyuan-server";
              description = "SiYuan 服务器包，需包含 bin/siyuan-kernel 与 lib/siyuan 静态资源目录";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 6806;
              description = "HTTP 服务监听端口";
            };

            # 内核只支持监听 127.0.0.1 或 0.0.0.0 二选一，由 conf.json 的 system.networkServe 决定；
            # 该项会在每次启动前写入配置，保证声明式生效（在界面里改掉也会被拉回）
            networkServe = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "是否监听 0.0.0.0 对局域网提供服务（false 时仅监听 127.0.0.1）";
            };

            accessAuthCode = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                访问鉴权码。开启 networkServe 后务必设置；
                也可以保持为空并通过 environmentFile 提供 SIYUAN_ACCESS_AUTH_CODE 环境变量以免密钥进入世界可读文件
              '';
            };

            lang = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "zh-CN";
              description = "界面语言，例如 zh-CN、en_US；留空则跟随首次访问的浏览器设置";
            };

            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "只读模式启动";
            };

            ssl = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "以 https/wss 方式伺服（通常应由外部反向代理终结 TLS，无需开启）";
            };

            pandocPackage = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              example = lib.literalExpression "pkgs.pandoc";
              description = ''
                一般无需设置：内核已通过补丁内置 nix pandoc，docx/odt 导出开箱即用。
                此项仅向服务进程 PATH 追加额外的 pandoc
              '';
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "是否在防火墙放行 services.siyuan.port";
            };

            environmentFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                额外环境变量文件（systemd EnvironmentFile 语法），
                可用于注入 SIYUAN_ACCESS_AUTH_CODE 等敏感配置
              '';
            };

            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "追加给 siyuan-kernel serve 的额外命令行参数";
            };
          };

          config = lib.mkIf cfg.enable {
            users.users.siyuan = {
              isSystemUser = true;
              group = "siyuan";
              home = workspaceDir;
            };
            users.groups.siyuan = { };

            networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

            warnings = lib.optional (
              cfg.networkServe && cfg.accessAuthCode == ""
            ) "services.siyuan：已开启 networkServe 但未设置 accessAuthCode，实例将无鉴权暴露给网络";

            systemd.services.siyuan = {
              description = "SiYuan Note Server";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              environment.HOME = workspaceDir; # 内核会向 ~/.config/siyuan 写 workspace.json 与 kernel.log

              path = lib.optionals (cfg.pandocPackage != null) [ cfg.pandocPackage ];

              preStart = "${pkgs.writers.writeBash "siyuan-prestart" ''
                set -euo pipefail
                conf="${workspaceDir}/conf/conf.json"
                mkdir -p "$(dirname "$conf")"
                if [[ ! -s "$conf" ]]; then
                  printf '{"system":{"networkServe":%s}}\n' "${lib.boolToString cfg.networkServe}" > "$conf"
                else
                  tmp="$(mktemp "$conf.XXXXXX")"
                  trap 'rm -f "$tmp"' EXIT
                  ${lib.getExe pkgs.jq} --argjson ns "${lib.boolToString cfg.networkServe}" \
                    '.system.networkServe = $ns' "$conf" > "$tmp"
                  mv "$tmp" "$conf"
                fi
              ''}";

              serviceConfig = {
                Type = "simple";
                ExecStart = execArgs;
                User = "siyuan";
                Group = "siyuan";
                StateDirectory = "siyuan";
                Restart = "on-failure";
                RestartSec = 5;
                EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

                # 加固选项：数据仅落在 StateDirectory 与私有 /tmp，其余文件系统只读
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
                RestrictNamespaces = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                LockPersonality = true;
                CapabilityBoundingSet = "";
              };
            };
          };
        };
    };
}
