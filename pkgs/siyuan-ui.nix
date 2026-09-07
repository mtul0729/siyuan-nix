# SiYuan web UI 静态资源（appearance/ stage/ guide/ changelogs/）。
# 产物布局与官方 Dockerfile 一致：服务端通过 --wd 指向该目录伺服 UI；
# 客户端打包时 electron-builder 会把 stage/appearance 等作为 extraResources 打进应用。
# Electron 相关依赖仅参与打包桌面版，此处跳过其二进制下载。
{
  lib,
  stdenv,
  nodejs_22,
  pnpm_11,
  pnpmConfigHook,
  fetchPnpmDeps,
  version,
  src,
}:

let
  pnpmDeps = fetchPnpmDeps {
    pname = "siyuan-ui";
    inherit version;
    pnpm = pnpm_11;
    src = src + "/app";
    # pnpm 11 的依赖存储格式对应 fetcherVersion = 4（含 SQLite 状态库的可复现转储）
    fetcherVersion = 4;
    hash = "sha256-PItwjC+UnGbOu00AFKgyvWl67uxMVQv4C60v3CY6Nz0=";
  };
in
stdenv.mkDerivation {
  pname = "siyuan-ui";
  inherit version;

  src = src + "/app";

  inherit pnpmDeps;
  # pnpmConfigHook 从 PATH 中查找 pnpm，需与 fetchPnpmDeps 使用的版本一致（pnpm_11）
  nativeBuildInputs = [
    nodejs_22
    pnpm_11
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
    platforms = platforms.linux;
  };
}
