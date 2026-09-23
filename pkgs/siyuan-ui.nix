# SiYuan web UI 静态资源（appearance/ stage/ guide/ changelogs/）。
# 产物布局与官方 Dockerfile 一致：服务端通过 --wd 指向该目录伺服 UI；
# 客户端打包时 electron-builder 会把 stage/appearance 等作为 extraResources 打进应用。
# Electron 相关依赖仅参与打包桌面版，此处跳过其二进制下载。
{
  lib,
  stdenv,
  nodejs_22,
  pnpm_12,
  pnpmConfigHook,
  fetchPnpmDeps,
  version,
  src,
}:

let
  pnpmDepsBase = fetchPnpmDeps {
    pname = "siyuan-ui";
    inherit version;
    pnpm = pnpm_12;
    src = src + "/app";
    # 依赖存储格式对应 fetcherVersion = 4（含 SQLite 状态库的可复现转储）；
    # nixpkgs 目前只支持 3/4，且 3 已对 pnpm >= 11 禁用，故 pnpm 12 仍用 4。
    # 版本跟随上游 app/package.json 的 packageManager（v3.8.5 起为 pnpm@12.3.4）。
    fetcherVersion = 4;
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  # TEMP DEBUG: 定位 darwin 上让 fetcher 的 jq 崩掉的 JSON 文件
  pnpmDeps = pnpmDepsBase.overrideAttrs (old: {
    postInstall =
      (old.postInstall or "")
      + ''
        find "$storePath" -name "*.json" -print0 | while IFS= read -r -d "" f; do
          jq -e . "$f" > /dev/null 2>&1 || echo "BADJSON: $f"
        done | head -20
      '';
  });
in
stdenv.mkDerivation {
  pname = "siyuan-ui";
  inherit version;

  src = src + "/app";

  inherit pnpmDeps;
  # pnpmConfigHook 从 PATH 中查找 pnpm，需与 fetchPnpmDeps 使用的版本一致（pnpm_12）
  nativeBuildInputs = [
    nodejs_22
    pnpm_12
    pnpmConfigHook
  ];

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
  meta = with lib; {
    description = "SiYuan web UI static assets";
    license = licenses.agpl3Only;
    # 本包同时是客户端 pnpmDeps 的来源（见 flake.nix），而客户端支持 darwin，故一并声明
    platforms = platforms.linux ++ platforms.darwin;
  };
}
