# 第三方二进制清点（nixpkgs 替代规范）

规范：构建过程中凡是上游或第三方提供的预编译二进制，都尽量用 nixpkgs 里的包替代；只有「只加载、从不执行」的数据文件才 `fetchurl`。先例是 pandoc 与 OCR 的 onnxruntime。本文记录每次清点的方法与结论，换不掉的项连同原因一并写下——避免以后重复排查。

面向上游的条目（如 PlantUML 默认伺服地址外发）不在这里，见 `docs/upstream-issues.md`。

## 清点方法

1. 取当前版本的源码树（`just src` / `just src-alpha`）：按扩展名 + 魔数（ELF `7f 45 4c 46` / MZ / Mach-O / wasm `00 61 73 6d`）扫 `app/` 与 `kernel/`。
2. 与两份 `app/electron-builder-*.yml` 的 `files` / `extraResources` 清单对照：只有被显式引用的才进产物，躺在源码树里的不算。
3. 对进产物的每一项问一句「nixpkgs 有没有同 ABI 的对应物」。

## 2026-10，v3.8.7 全量扫描

**已替换（本仓库做法）**

| 上游提供 | 处置 |
| --- | --- |
| `app/pandoc/*.zip`（含 pandoc 3.10.1） | postConfigure 删除并换占位 zip，installPhase 换成 nixpkgs `pandoc` 的 store 符号链接 |
| OCR 的 onnxruntime 预编译库 | 不 fetch，installPhase 用 nixpkgs `onnxruntime` 符号链接到 dlopen 的固定路径 |
| Electron 二进制 | nixpkgs `electron_44` + `ELECTRON_SKIP_BINARY_DOWNLOAD=1` |
| ocr-worker / 内核 | 我们从源码编译（worker 复用内核 `goModules` FOD，vendor 模式） |

**不适用**：`app/elevator/elevator-{amd64,arm64}.exe` 与 `app/nsis-resources/x86-unicode/nsProcess.dll` 是 Windows 安装器的提权/安装插件，两份 yml 的 `extraResources` 都不引用它们，linux / darwin 产物里不存在。

**无法替换，记录在案（渲染进程内的第三方编译产物，随源码 tarball 分发）**

| 文件 | 大小 | 为什么换不成 nixpkgs |
| --- | --- | --- |
| `app/stage/protyle/js/graphviz/viz.js` | 1.3M | Graphviz 经 Emscripten 编成 asm.js，由前端在渲染进程里调用（`protyle/render/graphvizRender`）。nixpkgs 的 `graphviz` 是原生 `dot`，而内核侧没有任何 dot 渲染路径（`kernel/` 里 graphviz 只出现在 `av/value.go` 的语言白名单），要换就得改上游的渲染方式 |
| `app/stage/protyle/js/lute/lute.min.js` | 4.2M | Lute（Go）经 GopherJS 编成 JS，供浏览器/移动端路径使用；内核已把 Lute 作为 Go 依赖链接进去了，这份是给非内核路径的 |
| `app/stage/protyle/js/pdf/wasm/{jbig2,openjpeg,qcms_bg}.wasm` | 448K | Mozilla pdf.js 的预编译解码器，与 `pdf.min.mjs` 的胶水代码 ABI 绑定；nixpkgs 没有对应形态的包 |

**构建期例外（接受）**：electron-builder 及其工具链（app-builder、esbuild 等）随 npm 包下发预编译二进制，只在构建期使用、不进产物——nixpkgs 打包 node 生态也是同一惯例。

**数据文件（只加载、不执行，故可 fetchurl / 直接用上游的）**：`app/pandoc/pandoc-resources`（lua filter + docx 模板）、OCR 的 onnx 权重与 yml（哈希取自上游 manifest 自身，见 `pkgs/siyuan-ocr-assets.nix`）。
