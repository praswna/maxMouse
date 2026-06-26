# pivotZDrag

A **standalone** 3ds Max tool: **Ctrl+Shift + middle-drag moves the selected
vertices along the Working Pivot's Z axis.**

Self-contained and independent of `maxMouse` and `shiftVertexDrag` — its own
runtime-compiled C# hook (namespace `PivotZMove`), globals (`pzd_*`), callback
id and macro.

## What it does

When an **Editable Poly** (Editable Mesh is **not** supported) is in a
**sub-object level** (Vertex / Edge / Border / Polygon / Element), holding
**Ctrl+Shift** and dragging with the **middle mouse button** moves each selected vertex along
**its own surface normal** by the same distance (a normal offset / inflate).
With a multi-selection every vertex goes its own way; selecting a face or edge
moves the vertices it uses, each along its own normal — the selection looks
like faces/edges but the motion happens per vertex.

The drag amount (a scalar) is the screen-plane movement projected onto the
**average** normal (drag out = inflate, drag in = deflate). The Working Pivot
is briefly aligned to that average normal and the coordinate system switched to
**Working Pivot** for visual feedback, then both are **restored** on release
(non-destructive). If a vertex normal can't be found, that vertex falls back to
+Z.

Align the Working Pivot Z to a surface normal first (e.g. with a pivot-snap
tool) and this becomes "push/pull along the normal".

- The drag is the **screen-plane movement projected onto that axis** — drag in
  the direction the axis points on screen to slide along it (like Max's
  axis-constrained gizmo drag).
- Modifier match is **exact** (Ctrl+Shift only), so it never collides with a
  Shift-only tool. Middle alone pans; the left button is never touched.
- The whole drag is one undo (`Move Verts (vertex normals)`, via `theHold`).

## How it works

1. `pivotZDrag.ms` compiles `PivotZHook.cs` in memory (CSharpCodeProvider) and
   installs a low-level mouse hook that acts only while **3ds Max is foreground**.
2. MAXScript keeps the hook's `Armed` flag in sync with the sub-object **level**
   (event-driven via `#selectionSetChanged` / `#modPanelSubObjectLevelChanged`
   — no polling timer).
3. On Ctrl+Shift + middle-down (armed, exact match), the hook swallows the
   middle down/up (no pan) and streams the drag through a **message-only window**
   (PostMessage, normal priority, self-coalescing) — smooth, never re-entrant,
   moves never swallowed (no cursor freeze).
4. MAXScript computes each vertex's **own local normal** (sum of the normals of
   the faces using it) once at drag start, plus the **average** normal. It
   projects the cursor onto a screen-plane through the selection, takes the
   component along that average normal to get a scalar amount, and moves **each
   vertex along its own normal** by that amount with one batched
   `polyOp.setVert` — live, inside a single `theHold` undo. The Working Pivot is
   aligned to the average normal for visual feedback and restored on release.

## Install / run

1. Keep `PivotZHook.cs` and `pivotZDrag.ms` **together** in the same folder.
2. **Scripting > Run Script…** → `pivotZDrag.ms`. Starts immediately.
3. Run again to toggle, or use the **PivotZDrag** macro (Customize > Toolbars,
   category *pivotZDrag*).

## Configuration

- **Modifier set:** in `pivotZDrag_start()` set `pzd_hook.Modifiers` — an exact
  bitmask of `1=Ctrl, 2=Alt, 4=Shift` (default `Ctrl+Shift` = `5`).

## Notes & caveats

- **Editable Poly only.** Editable Mesh is not supported (convert to Editable
  Poly). Edit Poly modifier is not handled either — it operates on the base
  Editable Poly object.
- Vertex writes use one batched `polyOp.setVert <poly> <bitArray> <pos_array>`
  call per move (fast on large selections).
- Uses the **active viewport** for screen↔world mapping; drag in the active
  viewport.
- Per-vertex normal = sum of the normals of the faces using that vertex
  (computed once at drag start, in local space).
- Coexists with `shiftVertexDrag` (Shift only) because the modifier match is
  exact — but make sure that tool also uses exact matching (it does as of the
  matching update) so Ctrl+Shift doesn't trigger both.
- Windows only.
