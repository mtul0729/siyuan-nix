# SiYuan 桌面客户端（Electron），打包方式参照 nixpkgs siyuan 包：
# - 用 nixpkgs 的 electron（electron.dist，复制成一份可写副本后交给 electron-builder）替代官方下载的二进制；
# - 用仓库自带的 electron-builder-<platform>.yml 以 --dir 模式打包（免自解压），再包一层 wrapper；
# - 不用上游自带的预编译 pandoc：自行放一个占位 zip 供 afterPack 解压，该副本运行时用不到
#   （内核经补丁直接用 nix pandoc），installPhase 会把解压结果换成 store 符号链接；
# - 内核以 SiYuan-Kernel 名义链接进打包目录，并注入 pandoc 路径补丁使其直接使用 nix pandoc；
# - linux 与 darwin 都支持：darwin 下产物是 .app bundle，用 /usr/bin/open 拉起。
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
  darwin,
  python3,
  go_1_26,
  fetchurl,
  version,
  src,
  # 与 UI 共用的 pnpm 依赖（同一 lockfile，fixed-output 推导可复用）
  pnpmDeps,
  # 已注入 set-pandoc-path 补丁的内核（worker 编译还要用它的 goModules）
  kernel,
  # 上游内置 OCR 的资源清单（pkgs/ocr-assets*.json，由 scripts/update.py 从源码 tarball
  # 离线拷出；版本无内置 OCR 时文件内容为 null）。null 时构建不涉及 OCR。
  ocrManifest ? null,
}:

let
  inherit (stdenv.hostPlatform) isDarwin isLinux system;

  # 上游 v3.8.7-alpha 起内置 OCR（beforePack 钩子按 scripts/ocr-assets.json 联网下载资源）。
  # 有清单就走离线化路径：资源经 fetchurl 预取（哈希取自 manifest，见 siyuan-ocr-assets.nix）。
  # 不能用 pathExists 探测上游源码树——src 是 FOD 的输出路径，那样做会把源码构建拉进求值（IFD），
  # nix flake check --no-build 直接挂。
  ocrParsedManifest =
    if ocrManifest != null then builtins.fromJSON (builtins.readFile ocrManifest) else null;
  hasOCR = ocrParsedManifest != null;

  ocrAssets =
    if hasOCR then
      import ./siyuan-ocr-assets.nix {
        inherit lib fetchurl platformId;
        manifest = ocrParsedManifest;
      }
    else null;

  # 模型文件逐个放到 prepare-ocr.py download() 的哈希校验位上（字节相符即跳过联网下载）
  ocrModelCopies = lib.concatMapStringsSep "\n" (
    m: ''
      mkdir -p "$(dirname "stage/ocr/models/${m.path}")"
      cp -f ${m.file} "stage/ocr/models/${m.path}"
    ''
  ) ocrAssets.models;

  # 使用 nixpkgs 默认的 electron_43 疑似存在不兼容性问题，例如粘贴功能失效
  # 改用electron_44，与 siyuan 上游的 electron major 版本一致
  electron = electron_44;

  # electron-builder-<platformId>.yml 的后缀，同时也是上游 extraResources 里打包内核用的目录名
  # （各 electron-builder-*.yml 中 from: "kernel-<platformId>"）。
  platformId =
    {
      "x86_64-linux" = "linux";
      "aarch64-linux" = "linux-arm64";
      "aarch64-darwin" = "darwin-arm64";
    }
    .${system} or (throw "Unsupported platform: ${system}");

  # electron-builder 配置期望的当前平台 pandoc 压缩包名，必须与 app/electron-builder-<platform>.yml
  # 的 from: 一致。上游还有 x86_64-darwin 的包，本 flake 不构建该平台。
  # 键由 platformId 限定，缺键会直接抛错，不会静默串名。
  pandocArchive =
    {
      "linux" = "pandoc-linux-amd64.zip";
      "linux-arm64" = "pandoc-linux-arm64.zip";
      "darwin-arm64" = "pandoc-darwin-arm64.zip";
    }
    .${platformId};

  # afterPack 解压出来的“内置 pandoc”是上面那个占位文件，运行时不会被用到（内核经
  # set-pandoc-path 补丁固定使用 nix pandoc）。把整个目录换成只含一个 store 符号链接的版本：
  # 客户端自身 store 路径 347 MiB -> ~138 MiB（闭包不变）。保留该路径而不是删掉，是为了让内核的
  # built-in pandoc 回退分支仍然有效。
  # 落点随平台不同：linux 在 build/*-unpacked/resources，darwin 在 <产品名>.app/Contents/Resources
  # （见上游 app/scripts/afterPack.js 的 getPackagedResourcePath()）。
  dedupePandoc = resourcesDir: ''
    rm -rf ${resourcesDir}/pandoc
    mkdir -p ${resourcesDir}/pandoc/bin
    ln -s ${lib.getExe pandoc} ${resourcesDir}/pandoc/bin/pandoc
  '';
in
stdenv.mkDerivation {
  pname = "siyuan-client";
  inherit version pnpmDeps;

  src = src + "/app";

  nativeBuildInputs = [
    nodejs_22
    pnpm_11
    pnpmConfigHook
    # 前端 bundle 由 webpack 生成到 app/stage/build —— 该目录被 .gitignore 排除、未随仓库提交，
    # 所以两个平台都必须真跑一次构建，否则产物缺少 JS bundle。
    # 注意 nixpkgs 把这条限定在 isLinux，它的 darwin 构建因此是不完整的，这里不跟随。
    pnpmBuildHook
    zip
  ]
  ++ lib.optionals isLinux [
    makeWrapper
    copyDesktopItems
  ]
  ++ lib.optionals isDarwin [
    # 打包会把只读 store 里的 Mach-O 可执行文件复制进 .app，需要重新做 ad-hoc 签名
    darwin.autoSignDarwinBinariesHook
  ]
  ++ lib.optionals hasOCR [
    # beforePack 钩子的 OCR 资源准备脚本（纯 stdlib）
    python3
  ]
  ++ lib.optionals (hasOCR && isLinux) [
    # linux 上上游还要现场编译 CGO 的 ocr-worker（gcc 由 stdenv 提供）
    go_1_26
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

    # electron-builder 需要一份**可写**的 electron dist，不能直接指向只读 store：
    # darwin 打包会就地改写 .app 内各 Helper 的 Info.plist
    # （app-builder-lib/src/electron/electronMac.ts createMacApp → util/plist.ts savePlistFile），
    # 而从 0444 的 store 文件复制出来的副本也是只读，写入就 EACCES：
    #   EACCES ... Electron Helper (Renderer).app/Contents/Info.plist
    # （CI 实测过）。nixpkgs 里的 cp -r + chmod -R u+w 就是这个原因，别当冗余删掉。
    cp -r ${electron.dist} electron-dist
    chmod -R u+w electron-dist
  ''
  + lib.optionalString hasOCR ''
    # ---- 内置 OCR 资源离线化（v3.8.7-alpha 起，见 siyuan-ocr-assets.nix）----
    # 上游 beforePack 钩子按仓库布局调 ../scripts/prepare-ocr.py（ROOT/app 布局定位资源、
    # ROOT/kernel 编译 worker），但 nix 构建目录的上一层不可写。故在构建目录里自建一个
    # 受控的仓库布局镜像，亲手执行与 beforePack.js 完全相同的调用，然后把钩子换成 no-op。
    mkdir -p ocr-layout/scripts
    cp -r ${src}/scripts/. ocr-layout/scripts/
    ln -s "$PWD" ocr-layout/app
    ln -s ${src}/kernel ocr-layout/kernel

    # 模型放到 download() 的哈希校验位：字节相符即跳过下载，不符则当场报错（fails closed）
    ${ocrModelCopies}
    # onnxruntime 归档放到 download() 的缓存位（<tempdir>/siyuan-ocr-assets/<basename>）
    ocrCache="''${TMPDIR:-/tmp}/siyuan-ocr-assets"
    mkdir -p "$ocrCache" /tmp/siyuan-ocr-assets
    cp -f ${ocrAssets.runtime} "$ocrCache/${ocrAssets.runtimeBasename}"
    if [[ "$ocrCache" != /tmp/siyuan-ocr-assets ]]; then
      cp -f ${ocrAssets.runtime} /tmp/siyuan-ocr-assets/${ocrAssets.runtimeBasename}
    fi

    # 与 beforePack.js 相同的参数；linux 另加 --build-worker（CGO worker，gcc 来自 stdenv）。
    # go 走内核的 goModules FOD，GOPROXY=off 保证零联网，GOTOOLCHAIN=local 杜绝工具链下载。
    ocrArgs=(--runtime ${ocrAssets.target})
    ${lib.optionalString isLinux "ocrArgs+=(--build-worker)"}
    env GOMODCACHE=${kernel.goModules} GOPROXY=off GOTOOLCHAIN=local \
      GOCACHE="$PWD/.gocache" \
      python3 ocr-layout/scripts/prepare-ocr.py "''${ocrArgs[@]}"

    # 资源已就位，钩子使命完成：换成 no-op，electron-builder 打包时不再执行
    cat > scripts/beforePack.js <<'OCR_EOF'
    // OCR 资源已在构建的 postConfigure 阶段由 nix 预取并就位（无需联网），
    // 这里 no-op 以避免 electron-builder 重复执行需要联网的上游钩子。
    module.exports = async function beforePack() {};
    OCR_EOF
  '';

  postBuild = ''
    electronBuilderArgs=(
      --dir
      --config electron-builder-${platformId}.yml
      -c.electronDist=electron-dist
      -c.electronVersion=${electron.version}
      ${lib.optionalString isDarwin "-c.mac.identity=null"}
    )

    npm exec electron-builder -- "''${electronBuilderArgs[@]}"
  '';

  installPhase = ''
    runHook preInstall
  ''
  + lib.optionalString isLinux ''
    mkdir -p $out/share/siyuan $out/share/icons/hicolor/scalable/apps

    cp -r build/*-unpacked/{locales,resources{,.pak}} $out/share/siyuan

    ${dedupePandoc "$out/share/siyuan/resources"}

    makeWrapper ${lib.getExe electron} $out/bin/siyuan \
        --chdir $out/share/siyuan/resources \
        --add-flags $out/share/siyuan/resources/app \
        --set ELECTRON_FORCE_IS_PACKAGED 1 \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
        --inherit-argv0

    cp src/assets/icon.svg $out/share/icons/hicolor/scalable/apps/siyuan.svg
  ''
  + lib.optionalString isDarwin ''
    mkdir -p $out/Applications $out/bin

    # --dir 模式下 electron-builder 把 app bundle 输出到 build/mac*/*.app
    cp -R build/mac*/*.app $out/Applications/SiYuan.app

    ${dedupePandoc "$out/Applications/SiYuan.app/Contents/Resources"}

    # 与 nixpkgs 一致：darwin 不包装 electron 本身，用 open(1) 拉起 app bundle。
    # $out 在构建期展开，$@ 留给运行期（heredoc 里转义）。
    cat > $out/bin/siyuan << EOF
    #!${stdenv.shell}
    exec open -na "$out/Applications/SiYuan.app" --args "\$@"
    EOF
    chmod +x $out/bin/siyuan
  ''
  + ''
    runHook postInstall
  '';

  desktopItems = lib.optional isLinux (makeDesktopItem {
    name = "siyuan";
    desktopName = "SiYuan";
    comment = "Refactor your thinking";
    icon = "siyuan";
    exec = "siyuan %U";
    categories = [ "Utility" ];
  });

  meta = with lib; {
    description = "SiYuan 桌面客户端（Electron）";
    license = licenses.agpl3Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    mainProgram = "siyuan";
  };
}
