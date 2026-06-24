# maxMouse

Mouse gestures for **3ds Max**. Hold the **right** (or **middle**) mouse
button, draw a quick shape, and release — the drag is recognized as a gesture
and runs a mapped command. A plain right-click with no drag still opens the
normal quad menu.

Built in MAXScript + a tiny inline C# global mouse hook (`WH_MOUSE_LL`),
compiled at runtime. **No plugin install or DLL build required** — just run
the script.

---

## How it works

1. `maxMouse.ms` reads the companion `MaxMouse_GestureHook.cs`, compiles it in
   memory with the .NET `CSharpCodeProvider`, and installs a low-level mouse
   hook on the 3ds Max UI thread.
2. While the right/middle button is held, mouse travel is reduced to a
   **direction string** made of `U` `D` `L` `R`
   (e.g. dragging down then right → `"DR"`).
3. On release:
   - If you actually dragged (past the threshold), the button-up is swallowed
     (so the quad menu doesn't pop) and the gesture is dispatched.
   - If you just clicked, nothing is intercepted — normal behavior.
4. MAXScript looks the gesture up in the map and runs the action.

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

## Default gestures

### Right button

| Gesture | Drag             | Action                 |
|---------|------------------|------------------------|
| `L`     | left             | Undo                   |
| `R`     | right            | Redo                   |
| `D`     | down             | Delete selection       |
| `U`     | up               | Zoom Extents Selected  |
| `UD`    | up, down         | Zoom Ext. All Selected |
| `DR`    | down, right      | Hide selection         |
| `DL`    | down, left       | Unhide all             |
| `UR`    | up, right        | Toggle Wireframe       |
| `UL`    | up, left         | Toggle Edged Faces     |
| `LU`    | left, up         | View: Top              |
| `LD`    | left, down       | View: Front            |
| `RU`    | right, up        | View: Perspective      |
| `RD`    | right, down      | Isolate toggle         |

### Middle button

| Gesture | Action                |
|---------|-----------------------|
| `L`     | Undo                  |
| `R`     | Redo                  |
| `U`     | Zoom Extents Selected |
| `D`     | Hide selection        |

> **Middle-button caveat:** the middle button also **pans the viewport** in
> 3ds Max, so a middle-drag both pans *and* fires the gesture. The right button
> is the clean primary. To turn the middle button off, set
> `EnableMiddle = false` in `maxMouse_start()` (in `maxMouse.ms`).

---

## Customizing

Open `src/maxMouse.ms`:

- **Add an action:** write a `fn mm_myAction = ( ... )` near the top.
- **Map it:** add a row to `mm_buildMap`, e.g.
  `#("R", "URD", "My Thing", mm_myAction)` — button `"R"`/`"M"`, the gesture
  string, a label, and the function.
- **Sensitivity:** change `MinDistance` in `maxMouse_start()` (smaller = more
  sensitive, more tokens per drag).

Re-run `maxMouse.ms` after editing.

---

## Requirements & notes

- 3ds Max with MAXScript .NET support (any reasonably modern version).
  Path auto-detection uses `getThisScriptFilename()` (3ds Max 2016+); older
  builds fall back to `getSourceFileName()`.
- The hook is global to your session but only acts on right/middle **drags**;
  it is removed on Max shutdown (`#preSystemShutdown` callback) and whenever
  you toggle maxMouse off.
- Windows only (uses the Win32 mouse hook API).
