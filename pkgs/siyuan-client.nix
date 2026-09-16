# SiYuan 桌面客户端（Electron），打包方式参照 nixpkgs siyuan 包：
# - 用 nixpkgs 的 electron（electron.dist）替代官方下载的二进制；
# - 用仓库自带的 electron-builder-<platform>.yml 以 --dir 模式打包（免自解压），再包一层 wrapper；
# - afterPack 钩子会解压 pandoc.zip，因此仍需按名放一个当前平台的压缩包，但内容只是占位符；
#   解压出的副本运行时用不到（内核经补丁直接用 nix pandoc），installPhase 会换成 store 符号链接；
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
    # 清掉上游自带的各平台预编译 pandoc 压缩包（共数百 MiB；pandoc-resources 保留，内核要用）
    rm -f pandoc/pandoc-*.zip

    # 仍需按名生成一个当前平台的压缩包：electron-builder 的 extraResources 引用它，
    # 且 app/scripts/afterPack.js 在 resources/pandoc.zip 缺失时直接报错、解压后只校验
    # bin/pandoc 是非空普通文件。解压出的副本并不被使用（内核经补丁只用 nix pandoc，
    # installPhase 随后还会把该文件换成 store 符号链接），所以这里只放占位内容，
    # 省掉 ~209 MiB 二进制的搬运与压缩（实测 ~5s/次）。
    # 注意：仅当前 --dir 模式下安全（解压结果只进 build/，被 installPhase 覆盖）。若以后改成让
    # electron-builder 直接产出 deb/AppImage，剥掉的 pandoc 会真的进产物，必须把 zip 换回真实内容。
    (
      cd pandoc
      mkdir -p .tmp/bin
      printf 'placeholder: replaced by a store symlink in installPhase\n' > .tmp/bin/pandoc
      (
        cd .tmp
        zip -qr ../${pandocArchive} bin/pandoc
      )
      rm -rf .tmp
    )

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

    # afterPack 解压出的 resources/pandoc/bin/pandoc 只是个占位符，且这份“内置 pandoc”运行时
    # 不会被用到（内核经 set-pandoc-path 补丁固定使用 nix pandoc）。这里换成指向同一 store
    # 路径的符号链接：客户端自身 store 路径从 347 MiB 降到 ~138 MiB（闭包不变）。
    # 保留该路径而不是删掉 resources/pandoc，是为了让内核的 built-in pandoc 回退分支仍然有效。
    ln -sf ${lib.getExe pandoc} $out/share/siyuan/resources/pandoc/bin/pandoc

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
