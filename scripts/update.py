#!/usr/bin/env python3
"""升级 SiYuan 版本并轮换固定输出推导（FOD）的哈希。

本仓库在 main 一个分支上维护两套 pin（见 flake.nix）：
    stable → 最新正式版（vX.Y.Z）                 : siyuan-server / siyuan-client
    alpha  → 正式/beta/alpha 中版本最高者          : siyuan-server-alpha / siyuan-client-alpha
每套各 4 个值（tag + src/vendorHash/pnpmDeps），共 8 个 pin，全部写在 flake.nix 里。
另有两份 OCR 资源清单 pkgs/ocr-assets{,-alpha}.json（见下），同样由本脚本维护。

用法:
    scripts/update.py                    # 两套 pin 各按自己的目标升级并轮换哈希
    scripts/update.py --stable v3.9.0    # 指定稳定版目标（alpha 仍自动解析）
    scripts/update.py --alpha v3.8.8-alpha.1   # 指定抢先版目标
    scripts/update.py --force            # tag 未变也重算哈希（改了影响 FOD 内容的东西后要用）
    scripts/update.py --build            # 升级后再冒烟构建两套包
    scripts/update.py --print-pins       # 以 JSON 打印 8 个 pin 后退出
    scripts/update.py --print-targets    # 以 JSON 打印两个目标 tag 后退出（只查 remote）

两个目标 tag 相同时（最新 release 恰好是正式版）只轮换一次，两套 pin 一起写——
同一个 tag 的两个 FOD 推导内容相同，哈希必然相同，没必要构建两遍。

为什么先写占位哈希：FOD 的 store 路径只由「name + 声明的哈希」决定，与构建脚本无关。
内容变了却沿用旧哈希时，新推导会与旧产物算出同一路径，Nix 直接跳过构建——依赖不更新、
补丁不生效、零报错。占位哈希同时改掉声明哈希与输出路径，强制真实构建，也就顺便从
`hash mismatch ... got: sha256-...` 里读到真值。不变量与背景见 docs/updating.md。

OCR 资源清单：上游 v3.8.7-alpha 起客户端内置 OCR，打包前要按 scripts/ocr-assets.json
联网下载模型与 onnxruntime。清单随源码 tarball 一起被本脚本取回，规范化后写入
pkgs/ocr-assets{,-alpha}.json（版本没有该文件时写 null）。客户端求值期按清单逐条
fetchurl 预取资源，每个条目的哈希取自清单自身——所以它不是 FOD 哈希 pin，
tag 变更时跟着源码一起换新即可，无需占位哈希轮换。
"""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

UPSTREAM_REPO = "https://github.com/siyuan-note/siyuan.git"
UPSTREAM_TARBALL = "https://github.com/siyuan-note/siyuan/archive/{tag}.tar.gz"
# 源码树内 OCR 资源清单的位置（上游 v3.8.7-alpha 起存在，见 pkgs/siyuan-ocr-assets.nix）
OCR_MANIFEST_IN_TREE = "scripts/ocr-assets.json"

# 只认 vX.Y.Z：上游会先发 -alpha/-beta，且存在 v202205311650-dev 这类非版本 tag。
STABLE_TAG_RE = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
# 抢先版的目标：正式版与 -alpha.N / -beta.N 一起比（后缀可选）。
FULL_TAG_RE = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)\.(\d+))?")

# 同一版本号内 alpha < beta < 正式，保证 v3.8.7-alpha.1 > v3.8.6 且 v3.8.6-beta.2 < v3.8.6。
STAGE_RANK = {"alpha": 0, "beta": 1}
STABLE_RANK = 2

SRI = r"sha256-[A-Za-z0-9+/=]+"
HASH_MISMATCH_RE = re.compile(r"got:\s+(?P<hash>" + SRI + r")")

# 占位符：FOD 路径由 name + 声明哈希决定，故它必须与任何真实哈希不同，
# 才能既改掉输出路径、又逼出一次真实构建。
PLACEHOLDER = "sha256-" + "A" * 43 + "="


class UpdateError(RuntimeError):
    """可预期的失败：打印一行错误，而不是抛 traceback。"""


@dataclass(frozen=True)
class Pin:
    """一个需要改写的值：文件、语义锚点正则（须含名为 value 的捕获组）。"""

    label: str
    relpath: str
    pattern: re.Pattern[str]


def _pin(label: str) -> Pin:
    """flake.nix 里的 `stableXxx = "...";` / `alphaXxx = "...";`。

    名字唯一，故正则天然只会匹配一处；仍由 _match_one 强制断言「恰好 1 处」，
    绝不静默跳过（写死缩进的 sed 曾导致哈希未被重置，2026-09）。
    """
    return Pin(label, "flake.nix", re.compile(rf'^[ \t]*{label} = "(?P<value>[^"]+)";', re.M))


@dataclass(frozen=True)
class Variant:
    """一套 pin：它自己的 tag、三个 FOD 哈希、OCR 资源清单，以及对应的预取推导。"""

    name: str
    tag: Pin
    src: Pin
    vendor: Pin
    pnpm: Pin
    # 上游内置 OCR 的资源清单落点（规范化 JSON；版本无内置 OCR 时内容为 null）
    ocr_relpath: str

    @property
    def suffix(self) -> str:
        return "" if self.name == "stable" else "-alpha"

    @property
    def hashes(self) -> tuple[Pin, Pin, Pin]:
        return self.src, self.vendor, self.pnpm

    @property
    def fod_installables(self) -> tuple[str, str]:
        return (
            f".#siyuan-server{self.suffix}.passthru.kernel.goModules",
            f".#siyuan-server{self.suffix}.passthru.ui.pnpmDeps",
        )


STABLE = Variant(
    "stable",
    tag=_pin("stableTag"),
    src=_pin("stableSrc"),
    vendor=_pin("stableVendorHash"),
    pnpm=_pin("stablePnpmDeps"),
    ocr_relpath="pkgs/ocr-assets-stable.json",
)
ALPHA = Variant(
    "alpha",
    tag=_pin("alphaTag"),
    src=_pin("alphaSrc"),
    vendor=_pin("alphaVendorHash"),
    pnpm=_pin("alphaPnpmDeps"),
    ocr_relpath="pkgs/ocr-assets-alpha.json",
)
VARIANTS = (STABLE, ALPHA)
# 任一步失败都要字节还原的文件（8 个 pin 全在 flake.nix，OCR 清单各占一个文件）
ROLLBACK_FILES = tuple({Path("flake.nix"), *(Path(v.ocr_relpath) for v in VARIANTS)})


def run(cmd: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    except FileNotFoundError as exc:
        raise UpdateError(f"命令不存在: {cmd[0]}") from exc


def _match_one(repo: Path, pin: Pin) -> tuple[str, re.Match[str]]:
    text = (repo / pin.relpath).read_text(encoding="utf-8")
    matches = list(pin.pattern.finditer(text))
    if len(matches) != 1:
        raise UpdateError(
            f"{pin.relpath}: 期望 {pin.label} 恰好匹配 1 处，实际 {len(matches)} 处"
            "（锚点失效或文件被改过，拒绝盲改）"
        )
    return text, matches[0]


def read_pin(repo: Path, pin: Pin) -> str:
    return _match_one(repo, pin)[1].group("value")


def write_pin(repo: Path, pin: Pin, value: str) -> None:
    text, match = _match_one(repo, pin)
    start, end = match.span("value")
    (repo / pin.relpath).write_text(text[:start] + value + text[end:], encoding="utf-8")


def version_key(tag: str) -> tuple[int, int, int, int, int]:
    """排序键：主版本.次版本.补丁 + 预发布等级（alpha < beta < 正式）+ 预发布序号。"""
    match = FULL_TAG_RE.fullmatch(tag)
    if match is None:
        raise UpdateError(f"非法 tag: {tag!r}")
    major, minor, patch, stage, num = match.groups()
    rank = STABLE_RANK if stage is None else STAGE_RANK[stage]
    return int(major), int(minor), int(patch), rank, int(num or 0)


def resolve_targets(repo: Path) -> tuple[str, str]:
    """一次 ls-remote 解析两个目标：最新正式版、正式/beta/alpha 中最高者。"""
    proc = run(["git", "ls-remote", "--tags", "--refs", UPSTREAM_REPO], cwd=repo)
    if proc.returncode != 0:
        raise UpdateError(f"git ls-remote 失败:\n{proc.stderr.strip()}")
    tags = [line.partition("refs/tags/")[2] for line in proc.stdout.splitlines()]
    stable = [t for t in tags if STABLE_TAG_RE.fullmatch(t)]
    newest = [t for t in tags if FULL_TAG_RE.fullmatch(t)]
    if not stable:
        raise UpdateError("上游未找到任何 vX.Y.Z 稳定 tag")
    if not newest:
        raise UpdateError("上游未找到任何 vX.Y.Z[-(alpha|beta).N] tag")
    return max(stable, key=version_key), max(newest, key=version_key)


def resolve_src(repo: Path, tag: str) -> str:
    """src 哈希 == 解包后去掉单一顶层目录的 tarball 树哈希，即 fetchFromGitHub 的 hash。"""
    proc = run(["nix-prefetch-url", "--unpack", UPSTREAM_TARBALL.format(tag=tag)], cwd=repo)
    if proc.returncode != 0:
        raise UpdateError(f"nix-prefetch-url 失败:\n{proc.stderr.strip()}")
    nix32 = proc.stdout.strip().splitlines()[-1]
    proc = run(
        ["nix", "hash", "convert", "--to", "sri", "--hash-algo", "sha256", nix32],
        cwd=repo,
    )
    if proc.returncode != 0:
        raise UpdateError(f"nix hash convert 失败:\n{proc.stderr.strip()}")
    return proc.stdout.strip()


def resolve_fod(repo: Path, installable: str) -> str:
    """用占位哈希构建 FOD，从 Nix 的 hash mismatch 错误里取出真实哈希。"""
    proc = run(["nix", "build", "--no-link", installable], cwd=repo)
    if proc.returncode == 0:
        raise UpdateError(
            f"{installable}: 用占位哈希竟构建成功——不应发生，占位符必须与真实哈希不同"
        )
    for stream in (proc.stderr, proc.stdout):
        match = HASH_MISMATCH_RE.search(stream)
        if match:
            return match.group("hash")
    tail = "\n".join(proc.stderr.strip().splitlines()[-20:])
    raise UpdateError(f"无法从 `nix build {installable}` 的输出中提取哈希，日志尾部:\n{tail}")


def resolve_ocr_manifest(repo: Path, tag: str) -> str:
    """取该 tag 的 OCR 资源清单并规范化；没有内置 OCR 的版本写 null。

    流式读 tarball，只为取回一个小 JSON——不值得为它落盘整包。
    规范化（sort_keys + 固定缩进）保证内容不变时字节不变，git diff 保持安静。
    """
    url = UPSTREAM_TARBALL.format(tag=tag)
    found: str | None = None
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            with tarfile.open(fileobj=io.BytesIO(response.read()), mode="r:gz") as archive:
                for member in archive.getmembers():
                    if not member.isfile() or not member.name.endswith("/" + OCR_MANIFEST_IN_TREE):
                        continue
                    text = archive.extractfile(member).read().decode("utf-8")
                    found = json.dumps(json.loads(text), ensure_ascii=False, sort_keys=True, indent=2) + "\n"
                    break
    except Exception as exc:
        raise UpdateError(f"取回 OCR 资源清单失败（{url}）:\n{exc}") from exc
    if found is None:
        print(f"{tag}: 源码树无 {OCR_MANIFEST_IN_TREE}，OCR 清单写 null（该版本未内置 OCR）")
        return "null\n"
    return found


def write_ocr_manifest(repo: Path, variant: Variant, content: str) -> None:
    (repo / variant.ocr_relpath).write_text(content, encoding="utf-8")


def rotate(repo: Path, variant: Variant, tag: str) -> dict[str, str]:
    """把一套 pin 轮换到 tag：先落 tag + 占位哈希，再依次解析 src 与两个 FOD。"""
    print(f"{variant.name}: -> {tag}")
    write_pin(repo, variant.tag, tag)
    for pin in variant.hashes:
        write_pin(repo, pin, PLACEHOLDER)

    values = {"src": resolve_src(repo, tag)}
    write_pin(repo, variant.src, values["src"])
    # OCR 清单随源码走：tag 变了清单就可能变，与哈希轮换同时落盘
    values["ocr"] = resolve_ocr_manifest(repo, tag)
    write_ocr_manifest(repo, variant, values["ocr"])
    # 解析顺序：src 必须先落实，另两个 FOD 都依赖它。
    for pin, installable in zip(variant.hashes[1:], variant.fod_installables, strict=True):
        values[pin.label] = resolve_fod(repo, installable)
        write_pin(repo, pin, values[pin.label])
    return values


def apply_values(repo: Path, variant: Variant, tag: str, values: dict[str, str]) -> None:
    """把另一套 pin 直接写成同一份结果（目标 tag 相同时省掉一次 FOD 构建）。"""
    print(f"{variant.name}: -> {tag}（复用上一套的哈希）")
    write_pin(repo, variant.tag, tag)
    for pin in variant.hashes:
        write_pin(repo, pin, values[pin.label])
    write_ocr_manifest(repo, variant, values["ocr"])


def current_pins(repo: Path) -> dict[str, str]:
    return {pin.label: read_pin(repo, pin) for variant in VARIANTS for pin in (variant.tag, *variant.hashes)}


def update(
    repo: Path,
    stable: str | None,
    alpha: str | None,
    *,
    force: bool,
    build: bool,
) -> int:
    current = {v.name: read_pin(repo, v.tag) for v in VARIANTS}
    if stable is None or alpha is None:
        resolved_stable, resolved_alpha = resolve_targets(repo)
        stable = stable or resolved_stable
        alpha = alpha or resolved_alpha
    version_key(stable)  # 校验格式
    version_key(alpha)

    print(f"目标: stable={stable} alpha={alpha}（当前: stable={current['stable']} alpha={current['alpha']}）")

    # 任一步失败都回滚：8 个 pin 在 flake.nix，OCR 清单各占一个文件，回滚即字节还原。
    saved = {path: path.read_bytes() for path in (repo / p for p in ROLLBACK_FILES)}
    try:
        if stable == alpha:
            # 最新 release 恰好是正式版：一套轮换，两套共用（tag 同 ⇒ 哈希同）
            if stable == current["stable"] and alpha == current["alpha"] and not force:
                print(f"两套 pin 都已是最新: {stable}")
                return 0
            values = rotate(repo, STABLE, stable)
            apply_values(repo, ALPHA, alpha, values)
        else:
            for variant, tag in ((STABLE, stable), (ALPHA, alpha)):
                if tag == current[variant.name] and not force:
                    print(f"{variant.name}: 已是最新 {tag}")
                    continue
                rotate(repo, variant, tag)

        if build:
            for installable in (".#siyuan-server", ".#siyuan-server-alpha"):
                proc = run(["nix", "build", "-L", installable], cwd=repo)
                if proc.returncode != 0:
                    raise UpdateError(f"{installable} 冒烟构建失败")
    except BaseException:
        for path, content in saved.items():
            path.write_bytes(content)
        raise

    for pin_label, value in current_pins(repo).items():
        print(f"{pin_label:17} {value}")
    for variant in VARIANTS:
        has_ocr = (repo / variant.ocr_relpath).read_text(encoding="utf-8").strip() != "null"
        print(f"{variant.ocr_relpath:22} {'内置 OCR' if has_ocr else '无 OCR'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="scripts/update.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--stable", metavar="TAG", help="稳定版的目标 tag（默认自动解析）")
    parser.add_argument("--alpha", metavar="TAG", help="抢先版的目标 tag（默认自动解析）")
    parser.add_argument("--force", action="store_true", help="tag 未变也重算哈希")
    parser.add_argument("--build", action="store_true", help="升级后冒烟构建两套服务端包")
    parser.add_argument(
        "--print-pins",
        action="store_true",
        help="以 JSON 打印 8 个 pin 后退出",
    )
    parser.add_argument(
        "--print-targets",
        action="store_true",
        help="以 JSON 打印两个目标 tag（stable / alpha）后退出（只查 remote，不改文件）",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args(argv)
    repo = args.repo.resolve()

    try:
        if args.print_pins:
            print(json.dumps(current_pins(repo), ensure_ascii=False))
            return 0
        if args.print_targets:
            stable, alpha = resolve_targets(repo)
            print(json.dumps({"stable": stable, "alpha": alpha}, ensure_ascii=False))
            return 0
        return update(repo, args.stable, args.alpha, force=args.force, build=args.build)
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
