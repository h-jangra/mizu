# Mizu Annotate & Image Editor

Mizu includes a native, lightweight Wayland application for image annotation, viewing, and editing inspired by **Tensaku** (`jondkinney/tensaku`), built natively in Zig without heavyweight dependencies like GTK, Qt, or Cairo.

The application uses native XDG Shell / Layer Shell Wayland windows via [`src/core/wayland_window.zig`](file:///home/hj/mizu/src/core/wayland_window.zig) and high-performance pixel operations via [`src/graphics/image_ops.zig`](file:///home/hj/mizu/src/graphics/image_ops.zig).

Both image viewing/editing and drawing annotation are unified into a single command:
```bash
mizu annotate [options] [image_file]
# Aliases: mizu image, mizu shot, mizu draw, mizu view, mizu img
# Standalone binary: mizu-annotate (or mizu-image)
```

---

## Tensaku-Inspired Object-Based Annotations

Unlike legacy screenshot markup tools that immediately burn shapes permanently into the image pixels, Mizu Annotate implements **first-class vector annotation objects**:

- **Select & Move (`V`)**: Click any shape, arrow, text, or badge on canvas to select it. Drag to move it smoothly.
- **Resize Handles**: 8 Tensaku-style handles (white rounded squares with accent border) allow precise resizing of rectangles, circles, blur boxes, highlights, and text. Arrows and lines feature draggable start and end point handles.
- **Multi-Selection**:
  - `Shift` + click to select multiple annotations.
  - Drag on empty canvas for **Marquee Selection** to select all overlapping elements.
  - Move, duplicate, or delete all selected items together.
- **Duplication (`Ctrl + D`)**: Instantly duplicate selected annotation(s) with an offset.
- **Deletion (`Delete` / `Backspace`)**: Remove selected annotation(s) cleanly.
- **Nudge**: Use Arrow keys (`↑`, `↓`, `←`, `→`) to nudge selected annotations by 1px (or 10px with `Shift`).
- **Layers Panel (`Ctrl + L`)**:
  - Toggleable sidebar displaying all annotations in stack order (top-to-bottom).
  - `👁` Eye icon: toggle visibility (hidden layers are neither displayed nor exported).
  - `🔒` Lock icon: lock annotations against accidental selection or movement.
  - Reorder buttons (`▲` / `▼`) to bring forward or send backward.
  - Layer deletion button (`✕`).

---

## Annotation & Editing Tools

| Tool | Shortcut | Description |
| :--- | :--- | :--- |
| **Select / Move** | `V` or `S` | Select, move, multi-select, and resize annotations on canvas |
| **Pen** | `P` | Smooth freehand brush; creates a movable path object |
| **Arrow** | `A` | Straight arrow with arrowhead; draggable start and end handles |
| **Line** | `L` | Clean straight line segment with endpoint handles |
| **Rectangle** | `R` | Outlined or filled box with 8 bounding box resize handles |
| **Circle** | `C` | Outlined or filled circle / ellipse with resize handles |
| **Text** | `T` | Click to type text; editable font size, color, and position |
| **Step Badge** | `N` or `1` | Numbered step badge (`①`, `②`, `③`...) with auto-incrementing counter |
| **Highlight** | `H` | Translucent highlighter box for emphasizing key details |
| **Blur** | `B` | Movable blur box that dynamically blurs the base image beneath it |
| **Pixelate** | `X` | Movable mosaic pixelation box for redacting faces and sensitive data |
| **Crop** | `K` / Button | Interactive crop tool with dimmed backdrop and `{w}×{h}` badge |

---

## Global Actions & Keyboard Shortcuts

| Action | Shortcut |
| :--- | :--- |
| **Select Tool** | `V` / `S` |
| **Toggle Layers Panel** | `Ctrl + L` |
| **Duplicate Selected** | `Ctrl + D` |
| **Delete Selected** | `Delete` / `Backspace` |
| **Select All** | `Ctrl + A` |
| **Deselect All** | `Escape` |
| **Undo / Redo** | `Ctrl + Z` / `Ctrl + Y` |
| **Save Image** | `Ctrl + S` (saves in-place or to `~/Pictures/Screenshots/mizu_<timestamp>.png`) |
| **Copy to Clipboard** | `Ctrl + C` (copies raw PNG via `wl-copy`) |
| **Export Image** | `Ctrl + E` (export as PNG or JPEG) |
| **Screenshot Capture** | `Capture` button or `-s` / `--screenshot` flag |
| **Rotate 90° CW / CCW** | `]` / `[` (or `R` in toolbar) |
| **Bring to Front / Send to Back** | `Ctrl + Shift + ]` / `Ctrl + Shift + [` |
| **Move Layer Up / Down** | `Ctrl + ]` / `Ctrl + [` |
| **Fit to Window** | `F` |
| **Reset Zoom (100%)** | `0` |
| **Zoom In / Out** | `+` / `-` (or mouse wheel scroll towards cursor) |
| **Pan Navigation** | Middle click drag or Space + drag |
| **Commit Text / Crop** | `Enter` |
| **Cancel Mode / Close** | `Escape` |

---

## CLI Usage

```bash
# Capture a screenshot region and annotate it immediately
mizu annotate -s
# or
mizu annotate --screenshot

# Open an existing image file (JPEG, PNG, SVG)
mizu annotate photo.jpg
# or using any alias:
mizu image photo.jpg
mizu shot screenshot.png
```
