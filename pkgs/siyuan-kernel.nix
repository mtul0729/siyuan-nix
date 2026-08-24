# SiYuan 内核（Go）：SQLite 启用 fts5 与 sqlcipher，对应官方 Dockerfile 的 go-build 阶段。
# 客户端打包时通过 patches 注入 pandoc 路径补丁。
{
  lib,
  buildGoModule,
  go_1_26,
  version,
  src,
  patches ? [ ],
}:

buildGoModule {
  pname = "siyuan-kernel";
  inherit version patches;

  src = src + "/kernel";

  # 锁定与 go.mod 一致的工具链，避免沙箱内触发 GOTOOLCHAIN 自动下载
  go = go_1_26;

  vendorHash = "sha256-PNRVGo9yoVyyFPLp3sKNjIMVvON/+LxeBal78WguDlM=";

  tags = [
    "fts5"
    "sqlcipher"
  ];
  ldflags = [
    "-s"
    "-w"
  ];
  env.CGO_ENABLED = "1";
  doCheck = false;

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
