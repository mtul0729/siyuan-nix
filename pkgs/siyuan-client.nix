# SiYuan 桌面客户端（Electron），打包方式参照 nixpkgs siyuan 包：
# - 用 nixpkgs 的 electron（electron.dist）替代官方下载的二进制；
# - 用仓库自带的 electron-builder-<platform>.yml 以 --dir 模式打包（免自解压），再包一层 wrapper；
# - afterPack 钩子会解压 pandoc.zip，因此用 nix 的 pandoc 现打一个平台压缩包放进源码树；
# - 内核以 SiYuan-Kernel 名义链接进打包目录，并注入 pandoc 路径补丁使其直接使用 nix pandoc。
{
  lib,
  stdenv,
  nodejs_22,
  pnpm_11,
  pnpmConfigHook,
  pnpmBuildHook,
  zip,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  electron,
  xdg-utils,
  pandoc,
  version,
  src,
  # 与 UI 共用的 pnpm 依赖（同一 lockfile，fixed-output 推导可复用）
  pnpmDeps,
  # 已注入 set-pandoc-path 补丁的内核
  kernel,
}:

let
  inherit (stdenv.hostPlatform) system;

  platformId =
    {
      "x86_64-linux" = "linux";
      "aarch64-linux" = "linux-arm64";
    }
    .${system} or (throw "Unsupported platform: ${system}");

  # electron-builder 配置期望的当前平台 pandoc 压缩包名
  pandocArchive =
    {
      "linux" = "pandoc-linux-amd64.zip";
      "linux-arm64" = "pandoc-linux-arm64.zip";
    }
    .${platformId};
in
stdenv.mkDerivation {
  pname = "siyuan-client";
  inherit version pnpmDeps;

  src = src + "/app";

  nativeBuildInputs = [
    nodejs_22
    pnpm_11
    pnpmConfigHook
    pnpmBuildHook
    zip
    makeWrapper
    copyDesktopItems
  ];

  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

  postConfigure = ''
    # 移除预编译的 pandoc 压缩包，用 nix pandoc 重打当前平台的（保留 pandoc-resources 供内核使用）
    rm -f pandoc/pandoc-*.zip

    (
      cd pandoc
      mkdir -p .tmp/bin
      cp ${lib.getExe pandoc} .tmp/bin/pandoc
      (
        cd .tmp
        zip -qr ../${pandocArchive} bin/pandoc
      )
      rm -rf .tmp
    )

    # 把内核链接到 electron-builder 期望的位置
    mkdir kernel-${platformId}
    ln -s ${kernel}/bin/siyuan-kernel kernel-${platformId}/SiYuan-Kernel

    cp -r ${electron.dist} electron-dist
    chmod -R u+w electron-dist
  '';

  postBuild = ''
    electronBuilderArgs=(
      --dir
      --config electron-builder-${platformId}.yml
      -c.electronDist=electron-dist
      -c.electronVersion=${electron.version}
    )

    npm exec electron-builder -- "''${electronBuilderArgs[@]}"
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/siyuan $out/share/icons/hicolor/scalable/apps

    cp -r build/*-unpacked/{locales,resources{,.pak}} $out/share/siyuan

    makeWrapper ${lib.getExe electron} $out/bin/siyuan \
        --chdir $out/share/siyuan/resources \
        --add-flags $out/share/siyuan/resources/app \
        --set ELECTRON_FORCE_IS_PACKAGED 1 \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
        --inherit-argv0

    cp src/assets/icon.svg $out/share/icons/hicolor/scalable/apps/siyuan.svg

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "siyuan";
      desktopName = "SiYuan";
      comment = "Refactor your thinking";
      icon = "siyuan";
      exec = "siyuan %U";
      categories = [ "Utility" ];
    })
  ];

  meta = with lib; {
    description = "SiYuan 桌面客户端（Electron）";
    license = licenses.agpl3Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "siyuan";
  };
}
