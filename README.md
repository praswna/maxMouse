# maxMouse

**Maya-style mouse gestures for 3ds Max.**

- **Right button → marking menu (context-sensitive).** Press & hold the right
  button; after a short delay a radial menu of 8 items (with icons) appears at
  the cursor. Flick toward a slice and release to run it. Flick *fast* (release
  before the menu shows) to run it without ever seeing the menu — just like a
  Maya marking menu. A plain right-click (no movement) still opens the normal
  quad menu. **The menu changes with the current sub-object level** —
  Object / Vertex / Edge / Polygon each get their own set.
- **Middle button → screen-space vertex move.** When an Editable Poly / Mesh is
  in **Vertex** sub-object level with a vertex selection, a middle-button drag
  slides the selected verts along the screen plane (the viewport does **not**
  pan). When that condition isn't met, the middle button pans as usual.

Built in MAXScript + a small inline C# global mouse hook (`WH_MOUSE_LL`) plus a
GDI+ radial-menu overlay, compiled at runtime. **No plugin install or DLL build
required** — just run the script. Windows only.

---

## How it works

1. `maxMouse.ms` reads the companion `MaxMouse_GestureHook.cs`, compiles it in
   memory with the .NET `CSharpCodeProvider`, and installs a low-level mouse
   hook on the 3ds Max UI thread.
2. The hook callback only updates state and decides **synchronously** whether to
   swallow an event (so the quad menu / pan are suppressed only when a gesture
   actually happens). A `Forms.Timer` drives the radial-menu UI and raises the
   .NET events, so MAXScript never runs re-entrantly inside the hook.
3. **Right button:** the hook tracks the flick direction, shows/highlights the
   radial menu, and on release raises `MarkingMenuSelected(index)`. MAXScript
   maps the slice index to an action.
4. **Middle button:** MAXScript keeps the hook's `VertexMoveArmed` flag (and the
   active menu) in sync with the current state. This is **event-driven** —
   `#selectionSetChanged` and `#modPanelSubObjectLevelChanged` callbacks update
   it instantly — with a slow 500 ms safety poll only for sub-object *component*
   selection (which has no callback). When armed, the hook swallows the middle
   events and streams the drag (`VertexDragStart/Move/End`) to MAXScript, which
   projects the cursor onto the screen plane through the selection and moves the
   verts.

---

## Middle drag in detail (screen-space vertex move)

Step by step, this is what a middle-button drag does:

1. **Arm check (event-driven).** `mm_poll` runs on the `#selectionSetChanged` /
   `#modPanelSubObjectLevelChanged` callbacks (plus a 500 ms safety poll for
   component selection) and sets `VertexMoveArmed = true` only when a single
   Editable Poly/Mesh is in **Vertex** sub-object level with **at least one
   vertex selected**. Otherwise it stays `false`.
2. **Middle button down.** In the low-level hook:
   - armed → mark the drag, **swallow the event (return 1) so the viewport does
     not pan**, and flag a `VertexDragStart`.
   - not armed → let it through, so the middle button **pans as normal**.
3. **Mouse move / button up.** While dragging, moves and the final up are
   swallowed too; the hook just records the latest cursor position.
4. **Event streaming (10 ms timer, UI thread).** A `Forms.Timer` raises
   `VertexDragStart / VertexDragMove / VertexDragEnd` to MAXScript (moves are
   coalesced to the latest position), so MAXScript never runs re-entrantly
   inside the hook.
5. **Projection onto the screen plane** (`mmv_*` handlers):
   - *Start:* record each selected vert's **world position**, the selection
     **centroid**, and build a plane through the centroid **perpendicular to the
     view direction**. Also store `offset = desktopPos − mouse.pos` to convert
     the hook's desktop coordinates into viewport coordinates.
   - *Move:* turn the cursor into a world ray with `mapScreenToWorldRay` and
     intersect it with that plane. The world distance from the start
     intersection is the **translation**; every selected vert is set to
     `original + translation` with a live redraw. Because the plane is parallel
     to the screen, the verts **follow the cursor 1:1** (works for both
     perspective and orthographic views).
   - *End:* the live edits are reverted, then re-applied inside a single
     `with undo on` block, so the whole drag collapses into **one undo entry**
     (`maxMouse Move Verts (screen)`).

```
middle down (verts selected) ──▶ pan suppressed
        │  drag
        ▼
cursor projected onto a screen-parallel plane through the selection
        │  selected verts move by that world delta (live)
        ▼
middle up ──▶ committed as a single Undo
```

**Caveats.** Movement is always **within the screen plane** (no depth move; no
axis constraint or snapping yet). Mapping uses the **active viewport** — since
the middle-down is swallowed, drag in the viewport that's already active (the
one where you selected the verts). Editable Poly is solid; Editable Mesh is
best-effort.

---

## Install / run

1. Keep `src/maxMouse.ms` and `src/MaxMouse_GestureHook.cs` **together** in the
   same folder.
2. In 3ds Max: **Scripting > Run Script…** → pick `src/maxMouse.ms`
   (or drag the file into a viewport).
3. It starts immediately and prints `maxMouse: started …` in the Listener.

Run it again to toggle off/on, or use the registered macro:
**Customize > Customize User Interface > Toolbars**, category **maxMouse**,
action **maxMouse** — drag it onto a toolbar for an on/off button.

### Auto-start with Max

Edit the path inside `startup/maxMouse_startup.ms`, then copy that file to your
user startup scripts folder, e.g.:

```
C:\Users\<you>\AppData\Local\Autodesk\3dsMax\<version>\ENU\scripts\startup\
```

---

## Default marking menus (right button)

The menu shown depends on the current sub-object level (kept in sync by the
selection / sub-object-level callbacks). Slices are clockwise from the top;
**Undo/Redo stay on W/E** in every menu for muscle memory.

| Dir | Object | Vertex | Edge | Polygon |
|-----|--------|--------|------|---------|
| N   | Zoom Sel  | Weld     | Connect  | Extrude  |
| NE  | Wireframe | Connect  | Chamfer  | Bevel    |
| E   | Redo      | Redo     | Redo     | Redo     |
| SE  | Hide      | Chamfer  | Collapse | Inset    |
| S   | Delete    | Remove   | Remove   | Delete   |
| SW  | Unhide All| Collapse | Cut      | Collapse |
| W   | Undo      | Undo     | Undo     | Undo     |
| NW  | Edged     | Break    | Split    | Detach   |

Sub-object operations use the **Editable Poly `buttonOp`** interface (the same
as clicking the command-panel button: they act on the current selection with
the object's current settings). They require an **Editable Poly** base object;
on an Editable Mesh they print a message (convert to Editable Poly).

### Icons

Each slice can show a 24×24 icon. Icons are PNG files in `icons/`, referenced
by name in the menu tables (e.g. `"weld"` → `icons/weld.png`). A simple
placeholder set is included — drop in your own PNGs of the same names to
replace them. Regenerate the placeholders with `python tools/make_icons.py`.
If an icon file is missing, the slice shows just its label.

---

## Customizing the menus (GUI editor)

Run `maxMouse_editor()` in the Listener, or use the **maxMouse Editor** macro
(Customize > Toolbars, category *maxMouse*). The dialog lets you:

- Pick the **sub-object level** (Object / Vertex / Edge / Polygon).
- For each of the 8 directions, set the **label**, choose an **action** from a
  dropdown, and pick an **icon**.
- **Apply (live)** to try it immediately, **Save** to write it to
  `…/plugcfg/maxMouse/menus.ini` so it persists between sessions, or
  **Reset defaults**.

Saved menus are loaded automatically on the next start.

### Adding your own actions

Actions shown in the editor come from the **action registry** in
`src/maxMouse.ms` (`mm_buildActions`), a list of `#("id", "Display Name", fn)`.
Add a `fn mm_myAction = ( ... )` (or a `mm_bop #SomeEnum` wrapper for an
Editable Poly command), register it in `mm_buildActions`, and re-run the
script — it then appears in the editor's action dropdown.

Other knobs: **icons** are `icons/<name>.png`; **level → menu mapping** is in
`mm_currentLevel` / `mm_menuFor`; **timing/feel** (`PopupDelayMs`, `DeadZone`)
is in `maxMouse_start()`. Re-run `maxMouse.ms` after editing code.

---

## Notes & caveats

- **Vertex move uses the *active* viewport** for screen↔world mapping. Because
  the middle-down is swallowed to suppress panning, drag in the viewport that is
  already active (selecting the verts there makes it active).
- **Editable Poly** uses `polyOp.getVert/setVert` (world space, solid).
  **Editable Mesh** support edits `node.mesh` and is best-effort across
  versions — if a mesh misbehaves, convert it to Editable Poly. Modifiers
  (Edit Poly / Edit Mesh) are **not** handled by the vertex-move feature.
- Vertex moves are wrapped into a **single undo** entry per drag
  ("maxMouse Move Verts (screen)").
- The global hook is removed on Max shutdown (`#preSystemShutdown`) and whenever
  you toggle maxMouse off.
- Requires MAXScript .NET support. Script-path auto-detection uses
  `getThisScriptFilename()` (3ds Max 2016+) with a `getSourceFileName()`
  fallback. Tested target: Windows, modern 3ds Max — **verify in your Max
  version**, especially the Editable Mesh path.
