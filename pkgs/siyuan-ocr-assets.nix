# 上游内置 OCR（v3.8.7-alpha 起）的资源预取：OCR 模型 + onnxruntime 运行库。
# 上游由 app/scripts/beforePack.js 调 scripts/prepare-ocr.py 在打包前联网下载这些资源；
# nix 沙箱无网络，故按 manifest 清单用 fetchurl 逐条预取。
#
# 关键点：manifest 每个条目自带 sha256（十六进制），fetchurl 的声明哈希直接取自它——
# 因此不像 src/vendorHash/pnpmDeps 那样需要在 flake.nix 里轮换固定输出哈希，
# 也不需要 CI round trip：manifest 本身由 scripts/update.py 在 tag 变更时从源码
# tarball 离线拷出（pkgs/ocr-assets{,-alpha}.json，无内置 OCR 的版本内容为 null）。
# 信任链是「上游 tag → 上游 manifest → 资源内容」，与 fetchurl 任何上游制品相同。
#
# 消费方式见 pkgs/siyuan-client.nix：把文件放到 prepare-ocr.py 的 download()
# 哈希校验位上，该校验通过即跳过联网（fails closed：字节不符会当场报错而非静默放过）。
{
  lib,
  fetchurl,
  # 上游 scripts/ocr-assets.json 的解析结果（来自 pkgs/ocr-assets*.json）
  manifest,
  # 与客户端相同的 platformId，映射到 manifest 的 runtime 键
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

  fetchEntry =
    entry:
    fetchurl {
      url = entry.url;
      sha256 = entry.sha256;
    };
in
{
  # manifest 里 runtime 的键名（beforePack.js --runtime 参数的值）
  inherit target;

  # 模型文件：e.path 是相对 app/stage/ocr/models/ 的落点（如 tiny/det/inference.onnx）
  models = map (entry: {
    path = entry.path;
    file = fetchEntry entry;
  }) manifest.models;

  # 当前平台的 onnxruntime 归档：上游 prepare-ocr.py 把它下到 <tempdir>/siyuan-ocr-assets/<basename>
  runtime = fetchEntry manifest.runtime.${target};
  runtimeBasename = lib.last (lib.splitString "/" manifest.runtime.${target}.url);
}
