# SiYuan 服务器包：内核二进制 + 静态资源合并到同一输出。
# $out/lib/siyuan 即内核的 --wd 工作目录；pandoc-resources 提供 docx 导出模板与 lua filter，
# 内核按 <wd>/pandoc-resources 约定查找。
{
  lib,
  symlinkJoin,
  version,
  src,
  ui,
  kernel,
}:

symlinkJoin {
  name = "siyuan-server-${version}";
  paths = [
    ui
    kernel
  ];

  postBuild = ''
    ln -s ${src}/app/pandoc/pandoc-resources $out/lib/siyuan/pandoc-resources
  '';

  passthru = {
    inherit ui kernel;
  };
  meta = kernel.meta // { mainProgram = "siyuan-kernel"; };
}
