# AGENTS.md

Nix flake packaging SiYuan (note server + Electron client + NixOS module) from the upstream `siyuan-note/siyuan` tag. Layout: `flake.nix` (wiring, tag/version, NixOS module) + `pkgs/siyuan-{kernel,ui,server,client}.nix` + `scripts/update.sh` (version bump entrypoint). Human-facing docs live in `README.md`; deeper background in `docs/updating.md` (update SOP, FOD hash invariant) and `docs/upstream-issues.md` (deferred upstream reports).

**Platform scope**: the server package (and therefore the NixOS module and its kernel-test check) is Linux-only; the desktop client also builds on `aarch64-darwin`. The two packages the client depends on (`siyuan-kernel`, `siyuan-ui`) declare darwin support for that reason, even though nothing else uses them there — see the darwin gotcha below.

## Commands

```bash
nix build -L .#siyuan-server         # server package (Linux only)
nix build -L .#siyuan-client         # Electron desktop client (linux + aarch64-darwin)
nix build -L .#checks.<system>.siyuan-kernel-test   # kernel go test (via passthru.kernel + overrideAttrs; Linux only)
nix build -L .#siyuan-server.passthru.kernel   # kernel derivation (no tests)
nix flake check --no-build --all-systems   # eval-only validation of all three systems
./scripts/update.sh vX.Y.Z           # version bump: rewrites tag + resets all three FOD hashes
```

There are no tests/linters beyond the kernel check derivation; CI (`.github/workflows/build.yml`) builds on `x86_64-linux`, `aarch64-linux` and `aarch64-darwin` (ubuntu-latest / ubuntu-24.04-arm / macos-14 matrix; the darwin job builds only the client and its inputs, and macOS minutes cost 10x) and pushes to cachix `mtul` (needs `CACHIX_AUTH_TOKEN` secret). Pushing to `main` triggers CI; for other branches use `gh workflow run build.yml --ref <branch>`.

## Update / hash workflow

Run `./scripts/update.sh vX.Y.Z`: it rewrites `tag` and resets the `src` hash in `flake.nix`, plus `vendorHash` (pkgs/siyuan-kernel.nix) and `pnpmDeps.hash` (pkgs/siyuan-ui.nix) to a placeholder. These hashes have no offline way to be precomputed — push, then read `got: sha256-...` from the CI failure log and fill all three in; push again until green. Don't forget the `src` hash on a tag bump: `fetchFromGitHub`'s `hash` in `flake.nix` is a FOD too and the old value silently fails for the new tag. The user prefers iterating via GitHub Actions logs over local builds.

- The pnpm hash is arch-independent; both matrix jobs print the same value.
- Prefetch derivations exist for this: `.#siyuan-server.passthru.kernel.goModules` and `.#siyuan-server.passthru.ui.pnpmDeps`.
- Full rationale and step-by-step: `docs/updating.md`.

## Gotchas

- Flakes only see git-tracked files: `git add` new files before any `nix` command or evaluation fails confusingly.
- FOD hash invariant (see `docs/updating.md`): a fixed-output derivation's store path is derived from name + declared hash only, NOT its build script. If you change anything that affects a FOD's content (`modPostBuild`, go.mod deps, lockfiles) without rotating the declared hash, the new build collides with the old artifact path and is silently skipped — patches stop applying with zero errors. Always re-run the placeholder → CI `got:` → fill-in rotation after such changes, even without a version bump.
- `siyuan-kernel-test`（flake.nix `checks`，经 `kernel.overrideAttrs` 定义）是内核的真实测试推导：单次 `go test ./...` 全量跑上游测试、不加任何 `-skip`，一次暴露全部失败包。开发者都在完整 checkout 下开发，本推导只剪出 `kernel/` 子树（`src + "/kernel"`），故读 `../../app/*` 资源的测试在沙箱里必红——**这是打包环境差异，不是上游问题**。该 check 构建红是设计内常态，不是本仓库回归，严禁为让 CI 变绿而添加 `checkFlags` 跳过。版本升级的验收只看 `siyuan-server` / `siyuan-client` 两个包是否构建成功。内核本体推导（`pkgs/siyuan-kernel.nix`）保持纯构建逻辑，不做任何测试配置。
- Kernel binary is renamed in `postInstall` (`bin/kernel` → `bin/siyuan-kernel`, Go's default product name is `bin/kernel`). Both the client packaging and the NixOS module reference `siyuan-kernel`; don't reference `bin/kernel`.
- There is a single kernel variant shared by server and client, patched via `pkgs/set-pandoc-path.patch` (`replaceVars @pandoc_path@`) to use nixpkgs pandoc directly — the server closure intentionally contains pandoc (docx export works out of the box). Don't "optimize" it away.
- Client reuses `ui.pnpmDeps` (same app lockfile); don't add a second `fetchPnpmDeps`.
- Client packaging: electron-builder runs with `--dir`, kernel symlinked as `SiYuan-Kernel`. When upstream changes `app/` layout or `InitPandoc`, diff against the nixpkgs `pkgs/by-name/si/siyuan` package as a reference for what changed. We deliberately do NOT consume upstream's vendored prebuilt pandoc zips: `postConfigure` deletes them and drops in our own placeholder archive, so no unaudited binary is ever extracted (no untrusted archive into the `unzipper` parser) or `chmod +x`'ed during the build — electron-builder's `extraResources` only names the archive and `app/scripts/afterPack.js` only checks that the extracted `bin/pandoc` is a non-empty regular file. `installPhase` then replaces the extracted `resources/pandoc/` with a store symlink, since the shared kernel uses nix pandoc via `set-pandoc-path.patch`. That's a deliberate ~209 MiB dedupe, not a bug, and it fails closed: if the `--dir` assumption ever breaks, you get no pandoc rather than a silently shipped unaudited binary.
- darwin client support (`pkgs/siyuan-client.nix`): `platformId` maps `aarch64-darwin` → `darwin-arm64`, which is both the `electron-builder-<id>.yml` suffix and the kernel dir name upstream's `extraResources` expects (`from: "kernel-<id>"`). Three darwin-specific things to keep intact: `pandocArchive`'s `darwin-arm64` entry (`pandoc-darwin-arm64.zip`; upstream also has an `x86_64-darwin` pair we don't build), `darwin.autoSignDarwinBinariesHook` in `nativeBuildInputs` (the packaging copies Mach-O binaries out of the read-only store, which invalidates their signatures), and `-c.mac.identity=null` (upstream's darwin ymls sign with their own certificate and reference `../../entitlements.mas.plist` / `../../SiYuan.provisionprofile`, neither of which exists in the repo). The `installPhase` pandoc dedupe targets a different path per platform: `afterPack.js`'s `getPackagedResourcePath()` resolves darwin to `<productFilename>.app/Contents/Resources`, so it is `<Product>.app/Contents/Resources/pandoc` instead of `$out/share/siyuan/resources/pandoc`.
- `pnpmBuildHook` intentionally runs on **both** platforms, unlike nixpkgs which gates it to `isLinux`: webpack writes `app/stage/build`, which is `.gitignore`d and therefore absent from the source tarball — skip the build and the app ships without its JS bundles. (nixpkgs' darwin package is incomplete for this reason.) The darwin path cannot be built on Linux (no remote darwin builder) — verify it on the `dev` branch via CI's `macos-14` job before letting anything near `main`.
- The Electron dist must be copied to a writable `electron-dist` (`cp -r` + `chmod -R u+w`), not pointed straight at the read-only store. Linux does not need this, but darwin packaging rewrites the `Info.plist` of every Helper app inside the freshly copied `.app` (app-builder-lib `electronMac.ts::createMacApp` → `plist.ts::savePlistFile`), and copies of 0444 store files are themselves read-only → `EACCES: ... Electron Helper (Renderer).app/Contents/Info.plist`. Paid for with a CI round trip: don't "optimize" it back to `-c.electronDist=${electron.dist}`.
- Version upgrades touch exactly one place: `tag` in `flake.nix` (+ hashes per above).
