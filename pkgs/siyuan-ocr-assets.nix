# 上游内置 OCR（v3.8.7-alpha 起）的模型资源预取。
# 上游由 app/scripts/beforePack.js 调 scripts/prepare-ocr.py 在打包前联网下载这些资源；
# nix 沙箱无网络，故按 manifest 清单用 fetchurl 逐条预取。
#
# 注意范围：这里只预取**模型数据文件**（onnx 权重与 yml 配置，只被加载、从不执行）。
# onnxruntime 原生库属于预编译二进制，按本仓库的 nixpkgs 规范不进闭包——
# 客户端在 installPhase 用 nixpkgs onnxruntime 以 store 符号链接替换（pandoc 同款），
# 见 pkgs/siyuan-client.nix 的 dedupeOnnxruntime。ocr-worker 则由我们自己从源码编译。
#
# 关键点：manifest 每个条目自带 sha256（十六进制），fetchurl 的声明哈希直接取自它——
# 因此不像 src/vendorHash/pnpmDeps 那样需要在 flake.nix 里轮换固定输出哈希，
# 也不需要 CI round trip：manifest 本身由 scripts/update.py 在 tag 变更时从源码
# tarball 离线拷出（pkgs/ocr-assets{,-alpha}.json，无内置 OCR 的版本内容为 null）。
#
# 消费方式见 pkgs/siyuan-client.nix：把文件放到 prepare-ocr.py 的 download()
# 哈希校验位上，该校验通过即跳过联网（fails closed：字节不符会当场报错而非静默放过）。
{
  lib,
  fetchurl,
  # 上游 scripts/ocr-assets.json 的解析结果（来自 pkgs/ocr-assets*.json）
  manifest,
  # 与客户端相同的 platformId，映射到 manifest 的 runtime 键（仅取目标目录名）
  platformId,
}:
let
  target =
    {
      "linux" = "linux-amd64";
      "linux-arm64" = "linux-arm64";
      "darwin-arm64" = "darwin-arm64";
    }
    .${platformId} or (throw "siyuan-ocr-assets: no OCR runtime target for platformId ${platformId}");
in
{
  # manifest 里 runtime 的键名 = 上游的运行库目录名（stage/ocr/runtime/<target>）
  inherit target;

  # 模型文件：e.path 是相对 app/stage/ocr/models/ 的落点（如 tiny/det/inference.onnx）
  models = map (entry: {
    path = entry.path;
    file = fetchurl {
      url = entry.url;
      sha256 = entry.sha256;
    };
  }) manifest.models;
}
