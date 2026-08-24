# AGENTS.md

Nix flake packaging SiYuan (note server + Electron client + NixOS module) from the upstream `siyuan-note/siyuan` tag. Layout: `flake.nix` (wiring, tag/version, NixOS module) + `pkgs/siyuan-{kernel,ui,server,client}.nix`.

## Commands

```bash
nix build -L .#siyuan-server         # server package
nix build -L .#siyuan-client         # Electron desktop client
nix build -L .#checks.<system>.siyuan-kernel   # kernel go test (independent of main build)
nix flake check --no-build --all-systems   # eval-only validation of both arches
```

There are no tests/linters; CI (`.github/workflows/build.yml`) builds both packages on `x86_64-linux` and `aarch64-linux` (ubuntu-latest / ubuntu-24.04-arm matrix) and pushes to cachix `mtul` (needs `CACHIX_AUTH_TOKEN` secret).

## Hash-fixing workflow (expected on version bumps)

`vendorHash` (pkgs/siyuan-kernel.nix) and `pnpmDeps.hash` (pkgs/siyuan-ui.nix) have no offline way to precompute — bump the SiYuan `tag` in `flake.nix`, push, then read `got: sha256-...` from the CI failure log and fill it in. The user prefers iterating via GitHub Actions logs over local builds.

- The pnpm hash is arch-independent; both matrix jobs print the same value.
- Prefetch derivations exist for this: `.#siyuan-server.passthru.kernel.goModules` and `.#siyuan-server.passthru.ui.pnpmDeps`.

## Gotchas

- Flakes only see git-tracked files: `git add` new files before any `nix` command or evaluation fails confusingly.
- Kernel binary is renamed in `postInstall` (`bin/kernel` → `bin/siyuan-kernel`, Go's default product name is `bin/kernel`). Both the client packaging and the NixOS module reference `siyuan-kernel`; don't reference `bin/kernel`.
- There is a single kernel variant shared by server and client, patched via `pkgs/set-pandoc-path.patch` (`replaceVars @pandoc_path@`) to use nixpkgs pandoc directly — the server closure intentionally contains pandoc (docx export works out of the box). Don't "optimize" it away.
- Client reuses `ui.pnpmDeps` (same app lockfile); don't add a second `fetchPnpmDeps`.
- Client packaging mirrors nixpkgs' siyuan recipe: electron-builder runs with `--dir`, needs a platform pandoc zip rebuilt from nixpkgs pandoc (its `afterPack` hook extracts it), kernel symlinked as `SiYuan-Kernel`. When upstream changes `app/` layout or `InitPandoc`, diff against the nixpkgs `pkgs/by-name/si/siyuan` package.
- Version upgrades touch exactly one place: `tag` in `flake.nix` (+ hashes per above).
