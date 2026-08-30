# AGENTS.md

Nix flake packaging SiYuan (note server + Electron client + NixOS module) from the upstream `siyuan-note/siyuan` tag. Layout: `flake.nix` (wiring, tag/version, NixOS module) + `pkgs/siyuan-{kernel,ui,server,client}.nix` + `scripts/update.sh` (version bump entrypoint). Human-facing docs live in `README.md`; deeper background in `docs/updating.md` (update SOP, FOD hash invariant) and `docs/upstream-issues.md` (deferred upstream reports).

## Commands

```bash
nix build -L .#siyuan-server         # server package
nix build -L .#siyuan-client         # Electron desktop client
nix build -L .#checks.<system>.siyuan-kernel-test   # kernel go test (via passthru.kernel + overrideAttrs)
nix build -L .#siyuan-server.passthru.kernel   # kernel derivation (no tests)
nix flake check --no-build --all-systems   # eval-only validation of both arches
./scripts/update.sh vX.Y.Z           # version bump: rewrites tag + resets all three FOD hashes
```

There are no tests/linters beyond the kernel check derivation; CI (`.github/workflows/build.yml`) builds both packages on `x86_64-linux` and `aarch64-linux` (ubuntu-latest / ubuntu-24.04-arm matrix) and pushes to cachix `mtul` (needs `CACHIX_AUTH_TOKEN` secret). Pushing to `main` triggers CI; for other branches use `gh workflow run build.yml --ref <branch>`.

## Update / hash workflow

Run `./scripts/update.sh vX.Y.Z`: it rewrites `tag` and resets the `src` hash in `flake.nix`, plus `vendorHash` (pkgs/siyuan-kernel.nix) and `pnpmDeps.hash` (pkgs/siyuan-ui.nix) to a placeholder. These hashes have no offline way to be precomputed — push, then read `got: sha256-...` from the CI failure log and fill all three in; push again until green. Don't forget the `src` hash on a tag bump: `fetchFromGitHub`'s `hash` in `flake.nix` is a FOD too and the old value silently fails for the new tag. The user prefers iterating via GitHub Actions logs over local builds.

- The pnpm hash is arch-independent; both matrix jobs print the same value.
- Prefetch derivations exist for this: `.#siyuan-server.passthru.kernel.goModules` and `.#siyuan-server.passthru.ui.pnpmDeps`.
- Full rationale and step-by-step: `docs/updating.md`.

## Gotchas

- Flakes only see git-tracked files: `git add` new files before any `nix` command or evaluation fails confusingly.
- FOD hash invariant (see `docs/updating.md`): a fixed-output derivation's store path is derived from name + declared hash only, NOT its build script. If you change anything that affects a FOD's content (`modPostBuild`, go.mod deps, lockfiles) without rotating the declared hash, the new build collides with the old artifact path and is silently skipped — patches stop applying with zero errors. Always re-run the placeholder → CI `got:` → fill-in rotation after such changes, even without a version bump.
- The kernel check derivation runs all test packages in one `go test ./...` invocation (default checkPhase aborts at the first failing package). Deferred upstream reports: `docs/upstream-issues.md`.
- Kernel test derivation lives in `flake.nix` `checks` as `kernel.overrideAttrs`; the kernel derivation stays pure build logic.
- Kernel binary is renamed in `postInstall` (`bin/kernel` → `bin/siyuan-kernel`, Go's default product name is `bin/kernel`). Both the client packaging and the NixOS module reference `siyuan-kernel`; don't reference `bin/kernel`.
- There is a single kernel variant shared by server and client, patched via `pkgs/set-pandoc-path.patch` (`replaceVars @pandoc_path@`) to use nixpkgs pandoc directly — the server closure intentionally contains pandoc (docx export works out of the box). Don't "optimize" it away.
- Client reuses `ui.pnpmDeps` (same app lockfile); don't add a second `fetchPnpmDeps`.
- Client packaging mirrors nixpkgs' siyuan recipe: electron-builder runs with `--dir`, needs a platform pandoc zip rebuilt from nixpkgs pandoc (its `afterPack` hook extracts it), kernel symlinked as `SiYuan-Kernel`. When upstream changes `app/` layout or `InitPandoc`, diff against the nixpkgs `pkgs/by-name/si/siyuan` package.
- Version upgrades touch exactly one place: `tag` in `flake.nix` (+ hashes per above).
