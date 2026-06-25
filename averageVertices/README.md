# averageVertices

A **standalone** 3ds Max tool that reimplements Maya's **Average Vertices**
(relax / Laplacian smoothing) for **Editable Poly**.

It moves each selected vertex toward the **average position of its connected
neighbour vertices**. Repeat to smooth more — exactly like Maya's
*Mesh > Average Vertices*.

Pure MAXScript — no C#, no mouse hook. It registers a **macroScript** so you can
bind your own hotkey.

## What it does

- Works at any **sub-object level**: Vertex / Edge / Border / Polygon / Element.
  Edge/face selections are converted to the vertices they use.
- For each target vertex, the new position is the average of the vertices
  connected to it by an edge (whether selected or not), blended by `avgv_weight`.
- Uses **Jacobi iteration** (all new positions computed from the previous state,
  then applied at once) so the result doesn't depend on vertex order.
- One **undo** entry per run (`Average Vertices`, via `theHold`). Applied with a
  single batched `polyOp.setVert`.

## Install / run & assign a hotkey

1. **Scripting > Run Script…** → `averageVertices.ms` (this registers the macro).
2. **Customize > Hotkeys** (or Toolbars) → category **averageVertices** →
   action **Average Vertices** → assign your shortcut.
3. Select an Editable Poly, enter a sub-object level, select verts/edges/faces,
   and press the key. Press repeatedly to smooth more.

To auto-load, `fileIn` the script from a file in your user `…/scripts/startup/`.

## Tuning

Two globals (edit in the script or set from the Listener):

- `avgv_iterations` — relax passes per key press (default `1`). Higher = more
  smoothing in one press.
- `avgv_weight` — `0..1`, how far each vertex moves toward its neighbour average
  (default `1.0` = move fully to the average; lower = gentler).

## Notes

- **Editable Poly only.** (Convert Editable Mesh to Editable Poly; Edit Poly
  modifier is not handled.)
- Neighbours include **unselected** connected vertices, so the boundary of your
  selection blends into the surrounding mesh (it isn't pinned to only the
  selected set).
- Isolated vertices (no connected edges) are left unchanged.
- Windows/any 3ds Max with MAXScript (no platform-specific code here).
