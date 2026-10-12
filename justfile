# SiYuan nix 打包常用入口。列出全部配方：just --list

# 打印源码树在 nix store 中的路径（nu 里跳转：cd (just src)）
# ui.src 是完整仓库根（app/ kernel/ scripts/ 都在里面）；内核源码在 src/kernel
src:
    ./scripts/src-path.nu stable

# 同上，alpha 变体
src-alpha:
    ./scripts/src-path.nu alpha
