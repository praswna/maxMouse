# maxMouse

**Maya-style mouse gestures for 3ds Max.**

- **Right button → marking menu.** Press & hold the right button; after a short
  delay a radial menu of 8 items appears at the cursor. Flick toward a slice
  and release to run it. Flick *fast* (release before the menu shows) to run it
  without ever seeing the menu — just like a Maya marking menu. A plain
  right-click (no movement) still opens the normal quad menu.
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
4. **Middle button:** MAXScript keeps the hook's `VertexMoveArmed` flag in sync
   with the current sub-object selection (polled every 200 ms). When armed, the
   hook swallows the middle events and streams the drag
   (`VertexDragStart/Move/End`) to MAXScript, which projects the cursor onto the
   screen plane through the selection and moves the verts.

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

## Default marking menu (right button)

Slices are clockwise from the top:

| Direction | Action               |
|-----------|----------------------|
| N (up)    | Zoom Extents Selected|
| NE        | Toggle Wireframe     |
| E (right) | Redo                 |
| SE        | Hide selection       |
| S (down)  | Delete selection     |
| SW        | Unhide all           |
| W (left)  | Undo                 |
| NW        | Toggle Edged Faces   |

---

## Customizing

Open `src/maxMouse.ms`:

- **Marking menu:** edit `mm_buildMenu` — the array is the 8 slices in order
  `N, NE, E, SE, S, SW, W, NW`, each `#("Label", actionFn)`. Add a
  `fn mm_myAction = ( ... )` near the top and reference it. Re-run the script.
- **Timing / feel:** in `maxMouse_start()` change `PopupDelayMs` (hold time
  before the menu appears) and `DeadZone` (px a flick must travel to count).

Re-run `maxMouse.ms` after editing.

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
