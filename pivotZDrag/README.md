# pivotZDrag

A **standalone** 3ds Max tool: **Ctrl+Shift + middle-drag moves the selected
vertices along the Working Pivot's Z axis.**

Self-contained and independent of `maxMouse` and `shiftVertexDrag` — its own
runtime-compiled C# hook (namespace `PivotZMove`), globals (`pzd_*`), callback
id and macro.

## What it does

When an **Editable Poly / Editable Mesh** is in a **sub-object level**
(Vertex / Edge / Border / Polygon / Element), holding **Ctrl+Shift** and
dragging with the **middle mouse button** moves the selection along the
**Working Pivot's Z axis** (world `WorkingPivot.getTM()` row 3). If no working
pivot is set, it falls back to the **object's local Z**. Edges and faces are
moved by moving the vertices they use.

Align the Working Pivot Z to a surface normal first (e.g. with a pivot-snap
tool) and this becomes "push/pull along the normal".

- The drag is the **screen-plane movement projected onto that axis** — drag in
  the direction the axis points on screen to slide along it (like Max's
  axis-constrained gizmo drag).
- Modifier match is **exact** (Ctrl+Shift only), so it never collides with a
  Shift-only tool. Middle alone pans; the left button is never touched.
- The whole drag is one undo (`Move Verts (pivot Z)`).

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
4. MAXScript reads the Working Pivot Z, projects the cursor onto a screen-plane
   through the selection, takes the component along the axis, and moves each
   selected vert by that amount — live, then committed as a single undo.

## Install / run

1. Keep `PivotZHook.cs` and `pivotZDrag.ms` **together** in the same folder.
2. **Scripting > Run Script…** → `pivotZDrag.ms`. Starts immediately.
3. Run again to toggle, or use the **PivotZDrag** macro (Customize > Toolbars,
   category *pivotZDrag*).

## Configuration

- **Modifier set:** in `pivotZDrag_start()` set `pzd_hook.Modifiers` — an exact
  bitmask of `1=Ctrl, 2=Alt, 4=Shift` (default `Ctrl+Shift` = `5`).

## Notes & caveats

- Editable **Poly** is solid; Editable **Mesh** is best-effort/slower. Modifiers
  (Edit Poly/Mesh) are not handled — operates on the base object.
- Uses the **active viewport** for screen↔world mapping; drag in the active
  viewport.
- Uses `WorkingPivot.getTM()` Z. If the working pivot is identity/unset, the
  axis falls back to the object's local Z.
- Coexists with `shiftVertexDrag` (Shift only) because the modifier match is
  exact — but make sure that tool also uses exact matching (it does as of the
  matching update) so Ctrl+Shift doesn't trigger both.
- Windows only.
