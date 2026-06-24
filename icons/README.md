# maxMouse icons

Placeholder marking-menu icons (32×32 PNG, white glyph, transparent
background; drawn at 24×24 in the menu).

Each menu slice references an icon by name in `src/maxMouse.ms`
(`#("Label", action, "iconName")`) → `icons/<iconName>.png`. A missing file
just falls back to a text-only slice.

Replace any of these with your own PNGs of the same name, or regenerate the
placeholder set:

```
python tools/make_icons.py
```
