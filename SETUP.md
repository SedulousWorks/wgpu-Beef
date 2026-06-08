# Setup & Build

This repo contains the **wgpu-Beef** bindings (`src/webgpu.bf`, `src/wgpu.bf`) plus two samples that draw a triangle through the same bindings:

| Project | Platform | Windowing / Surface |
|---|---|---|
| `wgpu-Beef-Test` | Native (Win64) | SDL2 + `WGPUSurfaceSourceWindowsHWND` |
| `wgpu-Beef-Test-Web` | Browser (wasm32) | Emscripten canvas (`WGPUEmscriptenSurfaceSourceCanvasHTMLSelector`) |

The GPU code (shader, pipeline, render pass) is identical between them; only window/surface creation, init flow, and the frame loop differ.

## Prerequisites

- [Beef](https://www.beeflang.org/) installed (IDE + `BeefBuild`).
- This repo cloned. Open `BeefSpace.toml` as the workspace.

---

## Native build (Windows / Win64)

Everything is preconfigured — just build and run.

- **IDE:** set `wgpu-Beef-Test` as the startup project and press **F5**. A window with an orange triangle appears.
- **CLI:**
  ```powershell
  & "C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace="<repo>" -config=Debug -platform=Win64
  ```

Notes:
- The `wgpu-Beef` binding links the **import library** `dist/Release-Win64/lib/wgpu_native.dll.lib` (not the static `wgpu_native.lib`, which would need a pile of Windows system libs), and its `PostBuildCmds` copy `wgpu_native.dll` next to the executable automatically.

---

## Web build (Browser / wasm32)

The browser path uses Emscripten + Dawn's **emdawnwebgpu** port (which implements the same modern `webgpu.h` the bindings mirror). Beef ships its own Emscripten (3.1.69), but that is **too old** for emdawnwebgpu — you need **Emscripten ≥ 4.0.10**.

### 1. Install Emscripten (emsdk)

```powershell
git clone --depth=1 https://github.com/emscripten-core/emsdk C:\DEV\emsdk
cd C:\DEV\emsdk
.\emsdk install latest
.\emsdk activate latest --permanent
# verify (resolves emcc -> emcc.exe):
C:\DEV\emsdk\upstream\emscripten\emcc --version
```

### 2. Point Beef at it

In the Beef IDE: **File ▸ Preferences ▸ Settings ▸ Wasm ▸ Emscripten Path** →

```
C:\DEV\emsdk
```

> ⚠️ Use the **emsdk root** (`C:\DEV\emsdk`), **not** `…\upstream\emscripten`. If you point at the subfolder, Beef ignores it and silently downloads its own (old) emsdk.

### 3. Add the `emcc.bat` shims (required for Emscripten 6.x)

Beef invokes the linker as `emcc.bat`, but recent Emscripten ships only `emcc.exe`/`em++.exe` (no `.bat`). Without these, the IDE reports a successful Beef compile, fails the link with `ERROR: Failed to execute "...emcc.bat"`, launches the browser anyway, and you get a **404** (no `.html` was produced).

Create two forwarding shims in `C:\DEV\emsdk\upstream\emscripten`:

`emcc.bat`
```bat
@"%~dp0emcc.exe" %*
```

`em++.bat`
```bat
@"%~dp0em++.exe" %*
```

> These are removed if you update/reinstall Emscripten — re-add them.

### 4. Build & run

- Set `wgpu-Beef-Test-Web` as the startup project, platform **wasm32**, and run. Beef builds `dist/wgpu-Beef-Test-Web.{html,js,wasm}`, serves it with miniserve, and opens your browser to the triangle.
- The **first** wasm build downloads the emdawnwebgpu port from Dawn's GitHub releases (needs network; takes a little longer).
- Requires a **WebGPU-capable browser** (recent Chrome/Edge; Firefox may need WebGPU enabled).

---

## Troubleshooting (web)

- **`ERROR: Failed to execute "...emcc.bat"`** → missing shim; see step 3.
- **miniserve 404 on `…html`** → the link didn't produce output (usually the `emcc.bat` issue). Inspect the recorded link command in `wgpu-Beef-Test-Web/dist/wgpu-Beef-Test-Web.html.build.txt`; you can re-run line 2 directly to see the real error:
  ```powershell
  $args = (Get-Content "<repo>\wgpu-Beef-Test-Web\dist\wgpu-Beef-Test-Web.html.build.txt")[1]
  Set-Content link.rsp $args -NoNewline -Encoding ASCII
  & "C:\DEV\emsdk\upstream\emscripten\emcc.exe" "@link.rsp"
  ```
- **Beef re-downloaded its own emsdk** → Emscripten Path was wrong (must be the emsdk root, step 2).
- **Blank page** → open devtools console: check for "WebGPU not supported" or an adapter/device failure (our `Console.WriteLine` messages surface there).
