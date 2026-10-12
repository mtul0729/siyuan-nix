#!/usr/bin/env nu

# 打印 SiYuan 源码树在 nix store 中的路径。
#   src-path.nu [stable|alpha]
# ui.src 是完整仓库根（app/ kernel/ scripts/ 都在里面），内核源码在其 kernel 子目录。

def main [variant: string = "stable"] {
  let pkg = match $variant {
    "alpha" => "siyuan-server-alpha"
    "stable" => "siyuan-server"
    _ => {
      print -e $"unknown variant: ($variant) \(expected stable or alpha)"
      exit 1
    }
  }

  # 纯求值，不触发构建；store 路径由 src FOD 的哈希决定
  let src_path = (nix eval --raw $".#($pkg).passthru.ui.src" | str trim)

  mut realised = ($src_path | path exists)

  # 换了 src 哈希后路径还没 realize：先按 store 路径从 substituter 拉（cachix mtul 上通常有）
  if not $realised {
    print -e $"fetching ($src_path) from substituters ..."
    try { nix-store --realise $src_path | ignore }
    $realised = ($src_path | path exists)
  }

  # 缓存里也没有，只能本地构建（会顺带取回源码）
  if not $realised {
    print -e $"not in cache, building ($pkg).passthru.ui ..."
    nix build -L $".#($pkg).passthru.ui" | ignore
  }

  print $src_path
}
