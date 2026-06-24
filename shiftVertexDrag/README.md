# shiftVertexDrag

A **standalone** 3ds Max tool: **Shift + middle-drag moves the selected
vertices in screen space.**

Self-contained and independent of `maxMouse` — its own runtime-compiled C#
hook (namespace `ShiftVertexMove`), its own globals (`svm_*`), its own callback
id and macro. You can run it on its own, or alongside maxMouse.

## What it does

When an **Editable Poly / Editable Mesh** is in **Vertex** sub-object level,
holding **Shift** and dragging with the **middle mouse button** slides the
selected verts along a plane parallel to the screen (through the selection
centroid). The viewport does **not** pan while Shift is held.

- Middle button **alone** pans as usual.
- The **left** button is never touched.
- The whole drag is committed as a **single undo** (`Move Verts (screen)`).

## How it works

1. `shiftVertexDrag.ms` reads the companion `ShiftVertexHook.cs`, compiles it
   in memory with the .NET `CSharpCodeProvider`, and installs a low-level mouse
   hook that only acts while **3ds Max is the foreground process**.
2. MAXScript keeps the hook's `Armed` flag in sync with the current sub-object
   **level** (event-driven via `#selectionSetChanged` /
   `#modPanelSubObjectLevelChanged` — no polling timer).
3. On Shift + middle-down (armed), the hook swallows the middle down/up (no
   pan) and streams the drag to MAXScript through a **message-only window**
   (PostMessage, normal priority, self-coalescing) — so it stays smooth and
   never runs MAXScript re-entrantly inside the hook. Mouse moves are never
   swallowed (the cursor can't freeze).
4. MAXScript projects the cursor onto the screen plane (`mapScreenToWorldRay`)
   and moves each selected vert by the resulting world delta, live.

## Install / run

1. Keep `ShiftVertexHook.cs` and `shiftVertexDrag.ms` **together** in the same
   folder.
2. In 3ds Max: **Scripting > Run Script…** → pick `shiftVertexDrag.ms`.
   It starts immediately and prints `shiftVertexDrag: started …`.
3. Run again to toggle off/on, or use the **ShiftVertDrag** macro
   (Customize > Toolbars, category *shiftVertexDrag*).

To auto-load, `fileIn` the script from a file in your user
`…/scripts/startup/` folder.

## Configuration

- **Modifier:** in `shiftVertexDrag_start()` set `svm_hook.Modifier`
  (`0` none, `1` Ctrl, `2` Alt, `3` Shift — default Shift).

## Notes & caveats

- **Editable Poly** is solid (`polyOp.getVert/setVert`, world space).
  **Editable Mesh** reassigns `node.mesh` each move and is best-effort /
  slower — convert to Editable Poly if it lags. Modifiers (Edit Poly/Mesh) are
  not handled.
- Mapping uses the **active viewport**; since the middle-down is swallowed,
  drag in the viewport that is already active.
- Movement is within the screen plane only (no depth move, no axis/snap).
- Windows only (Win32 mouse hook). The hook is removed on Max shutdown and when
  you toggle the tool off.
