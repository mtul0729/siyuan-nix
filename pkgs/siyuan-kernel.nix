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

  # 这些上游测试对环境有隐含假设（状态码预期、系统 MIME 表、非确定性顺序、
  # 沙箱内无预编译 pandoc / 无 workspace 配置），或自身存在缺陷
  # （TestPublishReaderCannotBrowseEncryptedNotebook 在 SaveConf 重载后访问空的
  # model.Conf.FileTree 而 panic），在 Nix 沙箱中必挂，跳过方式同 nixpkgs
  checkFlags = [
    "-skip=^(TestSpinBlockDOMInputSizeLimit|TestSecureAssetContentHeadersForcesAttachmentOnUnknownExtension|TestInitPandocDoesNotUseWorkspaceTemp|TestFilterPathsByPublishAccess|TestSystemPromptUsesAppearanceLanguage|TestPublishReaderCannotBrowseEncryptedNotebook|TestAddAttributeViewBlockAcceptsValidBoundItemWithoutDatabaseBlock)$"
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
