# maxMouse

A small collection of standalone **3ds Max** modeling tools (MAXScript, with
runtime-compiled C# only where a global mouse hook is needed). Each tool lives
in its own folder and is fully independent — run whichever you want.

> The original marking-menu gesture system has been removed; this repo now holds
> the vertex tools below.

## Tools

| Folder | Trigger | What it does |
|--------|---------|--------------|
| [`shiftVertexDrag/`](shiftVertexDrag/) | **Shift + middle-drag** | Move the selected verts (or the verts of selected edges/faces) along the **screen plane** while the viewport doesn't pan. |
| [`pivotZDrag/`](pivotZDrag/) | **Ctrl+Shift + middle-drag** | Move each selected vertex along **its own surface normal** (per-vertex normal offset / inflate). Editable Poly only. |
| [`averageVertices/`](averageVertices/) | **hotkey** (you assign) | **Average / Relax Vertices** (relax / Laplacian smoothing) — instant macro or a cursor-side caddy popup with live preview. |

Each folder has its own `README.md` with install, usage, and caveats.

## Common notes

- **Editable Poly** is the primary target. `shiftVertexDrag` also has a
  best-effort Editable Mesh path; `pivotZDrag` and `averageVertices` are
  Editable Poly only.
- The two drag tools (`shiftVertexDrag`, `pivotZDrag`) install a global
  low-level mouse hook that only acts while **3ds Max is the foreground app**;
  the left button is never touched, and they coexist (exact modifier matching).
- `averageVertices` is pure MAXScript (no hook) and registers macros you bind to
  a shortcut.
- Windows only for the mouse-hook tools (Win32 `WH_MOUSE_LL`).

## Install (per tool)

1. Keep each tool's files together in its folder.
2. **Scripting > Run Script…** → the tool's `.ms`.
3. Drag tools start immediately; `averageVertices` registers macros you assign
   in **Customize > Hotkeys** (category `#MyKUI`).

## Compatibility

- **Windows only** (the drag tools use a Win32 `WH_MOUSE_LL` hook).
- **Editable Poly** primarily (see per-tool notes); **Edit Poly / Edit Mesh
  modifiers are not handled** — they operate on the base object.
- The drag tools **runtime-compile their C# hook** with the .NET
  `CSharpCodeProvider`. Test on your target 3ds Max version before relying on it.
