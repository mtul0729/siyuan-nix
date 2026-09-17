# SiYuan 桌面客户端（Electron），打包方式参照 nixpkgs siyuan 包：
# - 用 nixpkgs 的 electron（electron.dist）替代官方下载的二进制；
# - 用仓库自带的 electron-builder-<platform>.yml 以 --dir 模式打包（免自解压），再包一层 wrapper；
# - 不用上游自带的预编译 pandoc：自行放一个占位 zip 供 afterPack 解压，该副本运行时用不到
#   （内核经补丁直接用 nix pandoc），installPhase 会把解压结果换成 store 符号链接；
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
  electron_44,
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

  electron = electron_44;
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
    # 不消费上游自带的预编译 pandoc：删掉它们，按当前平台名自造一个占位包。
    # electron-builder 的 extraResources 按名引用这个 zip、afterPack.js 缺了它会报错，
    # 但它只校验解压出的 bin/pandoc 是个非空普通文件——所以占位包就够。
    # 这样构建期既不会解压未审计归档（不把它喂进 JS 解压器），也不会 chmod +x 出
    # 任何未审计的可执行文件；解压结果随即被 installPhase 整体替换（见下）。
    rm -f pandoc/pandoc-*.zip
    mkdir -p pandoc/bin
    printf 'placeholder: replaced by a store symlink in installPhase\n' > pandoc/bin/pandoc
    (
      cd pandoc
      zip -qr ${pandocArchive} bin/pandoc
    )
    rm -rf pandoc/bin

    # 把内核链接到 electron-builder 期望的位置
    mkdir kernel-${platformId}
    ln -s ${kernel}/bin/siyuan-kernel kernel-${platformId}/SiYuan-Kernel
  '';

  postBuild = ''
    # electronDist 直接指向只读的 store：electron-builder 只读取它，所有写入都发生在
    # appOutDir（build/linux-unpacked）里，因此不需要 nixpkgs 那套 cp -r + chmod -R u+w 的可写副本。
    electronBuilderArgs=(
      --dir
      --config electron-builder-${platformId}.yml
      -c.electronDist=${electron.dist}
      -c.electronVersion=${electron.version}
    )

    npm exec electron-builder -- "''${electronBuilderArgs[@]}"
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/siyuan $out/share/icons/hicolor/scalable/apps

    cp -r build/*-unpacked/{locales,resources{,.pak}} $out/share/siyuan

    # afterPack 解压出的 resources/pandoc/bin/pandoc 是上面的占位文件，运行时不会被用到
    # （内核经 set-pandoc-path 补丁固定使用 nix pandoc）。把整个目录换成只含一个 store
    # 符号链接的版本：客户端自身 store 路径再从 347 MiB 降到 ~138 MiB（闭包不变）。
    # 保留该路径而不是删掉，是为了让内核的 built-in pandoc 回退分支仍然有效。
    rm -rf $out/share/siyuan/resources/pandoc
    mkdir -p $out/share/siyuan/resources/pandoc/bin
    ln -s ${lib.getExe pandoc} $out/share/siyuan/resources/pandoc/bin/pandoc

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
