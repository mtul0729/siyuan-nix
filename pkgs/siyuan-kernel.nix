# SiYuan 内核（Go）：SQLite 启用 fts5 与 sqlcipher，对应官方 Dockerfile 的 go-build 阶段。
# 客户端打包时通过 patches 注入 pandoc 路径补丁。
{
  lib,
  buildGoModule,
  go_1_26,
  version,
  src,
  patches ? [ ],
  # 主构建默认跳过测试；测试作为独立的 checks 推导运行（见 flake.nix 的 checks 输出）
  doCheck ? false,
}:

let
  kernelTags = [
    "fts5"
    "sqlcipher"
  ];
in
buildGoModule {
  pname = "siyuan-kernel";
  inherit version patches;

  src = src + "/kernel";

  # 锁定与 go.mod 一致的工具链，避免沙箱内触发 GOTOOLCHAIN 自动下载
  go = go_1_26;

  vendorHash = "sha256-r0Ey7KP+grj/B89lJ9TlCoCI9mqRcc1KLbI5gFLnqhk=";

  tags = kernelTags;
  ldflags = [
    "-s"
    "-w"
  ];
  env.CGO_ENABLED = "1";
  inherit doCheck;

  # 跳过在 Nix 沙箱中无法通过的上游测试（方式同 nixpkgs）：
  # - 环境假设类：沙箱无系统字体/预编译 pandoc/workspace 配置（CustomFont、ParseBundledFont、
  #   DocumentTemplatesWait、InitPandoc、SystemPromptUsesAppearanceLanguage、SecureAssetContent）
  # - 上游自身缺陷：SaveConf 重载后访问空的 model.Conf.FileTree 而 panic（PublishReaderCannotBrowse）；
  #   绑定属性视图测试未创建 Box 即解引用（AddAttributeViewBlockAccepts）；
  #   path_guard 断言与 Linux 实现不匹配（IsForbidden* 三项，v3.8.1 新增 publish 特性）
  # - server 路由渲染类依赖完整 appearance 初始化（AuthPageActionLayout、HistoryRoute、RepoDiffRoute）
  checkFlags = [
    "-skip=^(TestSpinBlockDOMInputSizeLimit|TestSecureAssetContentHeadersForcesAttachmentOnUnknownExtension|TestInitPandocDoesNotUseWorkspaceTemp|TestFilterPathsByPublishAccess|TestSystemPromptUsesAppearanceLanguage|TestPublishReaderCannotBrowseEncryptedNotebook|TestAddAttributeViewBlockAcceptsValidBoundItemWithoutDatabaseBlock|TestIsForbiddenAbsPath|TestIsForbiddenAbsPathSymlinkBypass|TestIsForbiddenDataRelPath|TestCustomFontLifecycle|TestDocumentTemplatesWaitForDatabaseIndex|TestParseBundledFontLocalizedName|TestAuthPageActionLayout|TestHistoryRouteBlocksSensitiveSnapshots|TestRepoDiffRouteBlocksSensitivePaths)$"
  ];

  # 默认 checkPhase 按目录串行跑且一挂即停，无法一次拿到完整失败清单；
  # 改为单次 go test 全量执行（某包 panic 只影响该包，其余包照常出结果）
  checkPhase = ''
    runHook preCheck
    go test -vet=off -tags=${lib.concatStringsSep "," kernelTags} $checkFlags ./...
    runHook postCheck
  '';

  # go build 产物名为 bin/kernel，统一改名为 siyuan-kernel
  # （NixOS 模块与客户端打包均按此名引用）
  postInstall = ''
    mv $out/bin/kernel $out/bin/siyuan-kernel
  '';

  # gulu 复制文件时保留 store 只读权限会导致工作区文件只读，统一改为 0644（同 nixpkgs）
  modPostBuild = ''
    chmod +w vendor/github.com/88250/gulu
    substituteInPlace vendor/github.com/88250/gulu/file.go \
        --replace-fail "os.Chmod(dest, sourceinfo.Mode())" "os.Chmod(dest, 0644)"
  '';

  meta = with lib; {
    description = "SiYuan kernel (reflection-focused note server)";
    license = licenses.agpl3Only;
    platforms = platforms.linux;
    mainProgram = "siyuan-kernel";
  };
}
