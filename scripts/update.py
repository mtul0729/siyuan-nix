#!/usr/bin/env python3
"""升级 SiYuan 版本并轮换三个固定输出推导（FOD）的哈希。

用法:
    scripts/update.py                # 升到上游最新稳定版（忽略 -alpha/-beta 等预发布）
    scripts/update.py v3.9.0         # 升到指定 tag
    scripts/update.py --force        # tag 未变也重算哈希（改了影响 FOD 内容的东西后要用）
    scripts/update.py --build        # 升级后再冒烟构建 siyuan-server
    scripts/update.py --print-pins   # 以 JSON 打印当前 pin 的 tag 与三个哈希后退出

三个 FOD 及其哈希位置:
    src            flake.nix              fetchFromGitHub.hash
    vendorHash     pkgs/siyuan-kernel.nix buildGoModule.vendorHash
    pnpmDeps       pkgs/siyuan-ui.nix     fetchPnpmDeps.hash

为什么先写占位哈希：FOD 的 store 路径只由「name + 声明的哈希」决定，与构建脚本无关。
内容变了却沿用旧哈希时，新推导会与旧产物算出同一路径，Nix 直接跳过构建——依赖不更新、
补丁不生效、零报错。占位哈希同时改掉声明哈希与输出路径，强制真实构建，也就顺便从
`hash mismatch ... got: sha256-...` 里读到真值。不变量与背景见 docs/updating.md。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

UPSTREAM_REPO = "https://github.com/siyuan-note/siyuan.git"
UPSTREAM_TARBALL = "https://github.com/siyuan-note/siyuan/archive/{tag}.tar.gz"

# 只认 vX.Y.Z：上游会先发 -alpha/-beta，且存在 v202205311650-dev 这类非版本 tag。
STABLE_TAG_RE = re.compile(r"v(\d+)\.(\d+)\.(\d+)")

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


# 正则锚定到语义块而非缩进：写死缩进曾导致 sed 静默不匹配、哈希未被重置（2026-09）。
TAG = Pin("tag", "flake.nix", re.compile(r'^[ \t]*tag = "(?P<value>[^"]+)";', re.M))
SRC = Pin(
    "src",
    "flake.nix",
    re.compile(r'(fetchFromGitHub\s*\{[^{}]*?hash = ")(?P<value>[^"]+)(")', re.S),
)
VENDOR = Pin(
    "vendorHash",
    "pkgs/siyuan-kernel.nix",
    re.compile(r'^[ \t]*vendorHash = "(?P<value>[^"]+)";', re.M),
)
PNPM = Pin(
    "pnpmDeps",
    "pkgs/siyuan-ui.nix",
    re.compile(r'(fetchPnpmDeps\s*\{[^{}]*?hash = ")(?P<value>[^"]+)(")', re.S),
)

# 解析顺序：src 必须先落实，另两个 FOD 都依赖它。
FOD_PINS = (
    (VENDOR, ".#siyuan-server.passthru.kernel.goModules"),
    (PNPM, ".#siyuan-server.passthru.ui.pnpmDeps"),
)


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


def version_key(tag: str) -> tuple[int, int, int]:
    match = STABLE_TAG_RE.fullmatch(tag)
    if match is None:
        raise UpdateError(f"非法 tag: {tag!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def latest_stable_tag(repo: Path) -> str:
    proc = run(["git", "ls-remote", "--tags", "--refs", UPSTREAM_REPO], cwd=repo)
    if proc.returncode != 0:
        raise UpdateError(f"git ls-remote 失败:\n{proc.stderr.strip()}")
    tags = [
        ref
        for line in proc.stdout.splitlines()
        if (ref := line.partition("refs/tags/")[2]) and STABLE_TAG_RE.fullmatch(ref)
    ]
    if not tags:
        raise UpdateError("上游未找到任何 vX.Y.Z 稳定 tag")
    return max(tags, key=version_key)


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


def current_pins(repo: Path) -> dict[str, str]:
    return {
        "tag": read_pin(repo, TAG),
        "src": read_pin(repo, SRC),
        "vendorHash": read_pin(repo, VENDOR),
        "pnpmDeps": read_pin(repo, PNPM),
    }


def update(repo: Path, tag: str | None, *, force: bool, build: bool) -> int:
    current = read_pin(repo, TAG)
    tag = tag or latest_stable_tag(repo)
    version_key(tag)  # 校验格式；本脚本只跟稳定版
    if tag == current and not force:
        print(f"已是最新: {tag}")
        return 0

    print(f"升级 {current} -> {tag}")

    # 任一步失败都回滚四个 pin，避免仓库停在「一半占位、一半真实」的状态。
    pins = (TAG, SRC, VENDOR, PNPM)
    originals = {pin.relpath: (repo / pin.relpath).read_bytes() for pin in pins}
    try:
        write_pin(repo, TAG, tag)
        for pin in (SRC, VENDOR, PNPM):
            write_pin(repo, pin, PLACEHOLDER)

        write_pin(repo, SRC, resolve_src(repo, tag))
        for pin, installable in FOD_PINS:
            write_pin(repo, pin, resolve_fod(repo, installable))

        if build:
            proc = run(["nix", "build", "-L", ".#siyuan-server"], cwd=repo)
            if proc.returncode != 0:
                raise UpdateError("siyuan-server 冒烟构建失败")
    except BaseException:
        for relpath, data in originals.items():
            (repo / relpath).write_bytes(data)
        raise

    for pin in pins:
        print(f"{pin.label:11} {read_pin(repo, pin)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="scripts/update.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("tag", nargs="?", help="目标 tag（默认取上游最新稳定版）")
    parser.add_argument("--force", action="store_true", help="tag 未变也重算哈希")
    parser.add_argument("--build", action="store_true", help="升级后冒烟构建 siyuan-server")
    parser.add_argument(
        "--print-pins",
        action="store_true",
        help="以 JSON 打印当前 pin 的 tag 与三个哈希后退出",
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
        return update(repo, args.tag, force=args.force, build=args.build)
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
