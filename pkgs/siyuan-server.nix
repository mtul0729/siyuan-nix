# SiYuan 服务器包：内核二进制 + 静态资源合并到同一输出。
# $out/lib/siyuan 即内核的 --wd 工作目录。
{
  lib,
  symlinkJoin,
  version,
  ui,
  kernel,
}:

symlinkJoin {
  name = "siyuan-server-${version}";
  paths = [
    ui
    kernel
  ];
  passthru = {
    inherit ui kernel;
  };
  meta = kernel.meta // { mainProgram = "siyuan-kernel"; };
}
