# SiYuan 服务器 Nix Flake：以 siyuan-note/siyuan 官方仓库为源，构建「内核 + 前端静态资源」服务器包，
# 并提供 NixOS systemd 服务模块。
#
# 常用命令：
#   nix build .#siyuan-server            构建服务器包（含 SiYuan-Kernel 内核与 appearance/stage 等静态资源）
#   nix build .#siyuan-server.passthru.kernel.goModules   单独预取 Go 依赖（vendorHash 变更后用于校验）
#   nix build .#siyuan-server.passthru.ui.pnpmDeps        单独预取 pnpm 依赖（pnpmDeps hash 变更后用于校验）
#   nix flake update siyuan-src          升级 SiYuan 源码到新 tag
#
# 升级 SiYuan 版本步骤：
#   1. 修改下方 tag（version 自动去除 v 前缀派生）
#   2. 若构建报哈希不匹配，按错误信息中的 got: sha256-... 更新 srcHash / vendorHash / pnpmDeps.hash
#
# 在 NixOS 配置中启用：
#   imports = [ siyuan-nix.nixosModules.default ];
#   services.siyuan = {
#     enable = true;
#     accessAuthCode = "改成你的鉴权码";
#     openFirewall = true;
#   };
{
  description = "SiYuan note server with a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # SiYuan 发布 tag；version 自动去除 v 前缀，升级时只需修改这一处
      tag = "v3.8.1";
      version = nixpkgs.lib.removePrefix "v" tag;

      # 以 GitHub 上的官方发布源码为构建输入
      mkSrc = pkgs: pkgs.fetchFromGitHub {
        owner = "siyuan-note";
        repo = "siyuan";
        rev = tag;
        hash = "sha256-Rcx4+wwEfPZv0WjsxpHCk3qYV52jPdQCJcwUFeDkbos=";
      };

      # 构建前端静态资源（appearance/ stage/ guide/ changelogs/），产物布局与官方 Dockerfile 一致，
      # 内核通过 --wd 指向该目录伺服 UI。Electron 相关依赖仅参与打包桌面版，此处跳过其二进制下载。
      mkUi = pkgs: src:
        let
          pnpmDeps = pkgs.fetchPnpmDeps {
            pname = "siyuan-ui";
            inherit version;
            pnpm = pkgs.pnpm_11;
            src = src + "/app";
            # pnpm 11 的依赖存储格式对应 fetcherVersion = 4（含 SQLite 状态库的可复现转储）
            fetcherVersion = 4;
            hash = ""; # TODO: 首次构建失败后按提示填入真实哈希
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "siyuan-ui";
          inherit version;

          src = src + "/app";

          inherit pnpmDeps;
          # pnpmConfigHook 从 PATH 中查找 pnpm，需与 fetchPnpmDeps 使用的版本一致（pnpm_11）
          nativeBuildInputs = [ pkgs.nodejs_22 pkgs.pnpm_11 pkgs.pnpmConfigHook ];

          env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

          buildPhase = ''
            runHook preBuild
            pnpm run build
            node scripts/trimChangelogs.js
            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/lib/siyuan
            mv stage appearance guide changelogs $out/lib/siyuan/
          '';

          passthru = { inherit pnpmDeps; };
          meta = with pkgs.lib; {
            description = "SiYuan web UI static assets";
            license = licenses.agpl3Only;
            platforms = platforms.linux;
          };
        };

      # 编译 Go 内核（SQLite 启用 fts5 与 sqlcipher），对应 Dockerfile 的 go-build 阶段
      mkKernel = pkgs: src: pkgs.buildGoModule {
        pname = "siyuan-kernel";
        inherit version;

        src = src + "/kernel";

        # 锁定与 go.mod 一致的工具链，避免沙箱内触发 GOTOOLCHAIN 自动下载
        go = pkgs.go_1_26;

        vendorHash = "sha256-PNRVGo9yoVyyFPLp3sKNjIMVvON/+LxeBal78WguDlM=";

        tags = [ "fts5" "sqlcipher" ];
        ldflags = [ "-s" "-w" ];
        env.CGO_ENABLED = "1";
        doCheck = false;

        meta = with pkgs.lib; {
          description = "SiYuan kernel (reflection-focused note server)";
          license = licenses.agpl3Only;
          platforms = platforms.linux;
          mainProgram = "siyuan-kernel";
        };
      };

      siyuanPackages = pkgs:
        let
          src = mkSrc pkgs;
          ui = mkUi pkgs src;
          kernel = mkKernel pkgs src;
        in
        # 最终包：内核二进制 + 静态资源合并到同一输出；$out/lib/siyuan 即内核的 --wd 工作目录。
        # 子推导挂到 passthru 上，便于单独构建预取类固定输出推导以计算哈希。
        pkgs.symlinkJoin {
          name = "siyuan-server-${version}";
          paths = [ ui kernel ];
          passthru = { inherit ui kernel; };
          meta = kernel.meta // { mainProgram = "siyuan-kernel"; };
        };

    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          siyuan-server = siyuanPackages pkgs;
          default = self.packages.${system}.siyuan-server;
        });

      overlays.default = final: _prev: {
        siyuan-server = siyuanPackages final;
      };

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.siyuan;
          workspaceDir = "/var/lib/siyuan";
          system = pkgs.stdenv.hostPlatform.system;
          execArgs = lib.escapeShellArgs ([
            (lib.getExe' cfg.package "siyuan-kernel")
            "serve"
            "--workspace" workspaceDir
            "--wd" "${cfg.package}/lib/siyuan"
            "--port" (toString cfg.port)
            "--accessAuthCode" cfg.accessAuthCode
            "--mode" "prod"
          ]
          ++ lib.optionals cfg.readOnly [ "--readonly" "true" ]
          ++ lib.optionals cfg.ssl [ "--ssl" ]
          ++ lib.optionals (cfg.lang != null) [ "--lang" cfg.lang ]
          ++ cfg.extraArgs);
        in
        {
          options.services.siyuan = {
            enable = lib.mkEnableOption "SiYuan 笔记服务器";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.default;
              defaultText = lib.literalExpression "siyuan-nix.packages.\${system}.default";
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
              description = "提供 pandoc 以支持导出 docx/odt 等格式；null 表示不安装";
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

            warnings = lib.optional (cfg.networkServe && cfg.accessAuthCode == "")
              "services.siyuan：已开启 networkServe 但未设置 accessAuthCode，实例将无鉴权暴露给网络";

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
                RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
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
