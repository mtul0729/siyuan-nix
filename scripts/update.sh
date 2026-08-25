#!/usr/bin/env bash
# 升级 SiYuan 版本并安全轮换固定输出哈希。
#
# 用法: ./scripts/update.sh vX.Y.Z
#
# 为什么哈希要重置为占位符：
#   固定输出推导（goModules / pnpmDeps）的 store 路径只由「name + 声明的哈希」决定，
#   与构建脚本无关。若只升 tag 而保留旧哈希，新推导会与旧产物路径碰撞，
#   Nix 发现路径已存在就静默跳过构建——依赖不更新、补丁不生效、且无任何报错
#   （2026-08 gulu 权限替换静默失效的教训）。占位哈希强制改变输出路径，逼出真实构建。
set -euo pipefail

newtag="${1:?usage: $0 vX.Y.Z}"
if [[ ! "$newtag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: tag must look like v3.8.2, got: $newtag" >&2
  exit 1
fi
cd "$(dirname "$0")/.."

fake='sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

sed -i "s|^      tag = .*|      tag = \"$newtag\";|" flake.nix
sed -i "s|^  vendorHash = .*|  vendorHash = \"$fake\";|" pkgs/siyuan-kernel.nix
sed -i "s|^    hash = .*|    hash = \"$fake\";|" pkgs/siyuan-ui.nix

git add flake.nix pkgs/siyuan-kernel.nix pkgs/siyuan-ui.nix

echo "done: tag -> $newtag, both FOD hashes reset to placeholder"
cat <<'EOF'

next steps (hashes cannot be precomputed offline):
  1. commit & push (dev branch recommended), CI round 1 will fail printing got: sha256-...
     non-push branches: gh workflow run build.yml --ref <branch>
  2. fill both got: values back in (arch-independent):
       vendorHash   -> pkgs/siyuan-kernel.nix
       pnpmDeps.hash -> pkgs/siyuan-ui.nix
  3. push again, CI must go green, then merge to main.

invariant: the declared hash must always equal the hash of what the CURRENT build
script produces. If you change anything that affects a FOD's content (e.g.
modPostBuild), re-run this rotation even without a version bump.
EOF
