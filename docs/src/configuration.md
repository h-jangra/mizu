# Configuration Reference

Mizu reads its configuration from `~/.config/mizu/config.ini` (or `$XDG_CONFIG_HOME/mizu/config.ini`). If absent, built-in defaults are used automatically.

---

## Configuration Options

### 1. Bar Dimensions & Geometry
* `height`: Status bar height in pixels (default: `42`).
* `margin_top`, `margin_bottom`, `margin_left`, `margin_right`: Outer screen margins.
* `border_width`: Stroke width of bar and pill borders (default: `1`).
* `bar_radius`: Corner radius of the status bar (default: `12`).
* `pill_radius`: Corner radius of chips and pills (default: `10`).
* `panel_radius`: Corner radius of floating overlay panels (default: `16`).

### 2. Typography (`[typography]`)
Logical pixel font sizes (clamped to 8–96):
* `ui`: Standard interface text (default: `15`).
* `secondary`: Descriptions and timestamps (default: `13`).
* `heading`, `title`: Section and window headers (default: `18`, `20`).
* `bar_text`, `bar_icon`: Bar chip labels and vector icons (default: `15`, `20`).
* `quicksettings_text`, `quicksettings_icon`: Quick Settings text and icons.
* `calendar_text`, `calendar_heading`: Calendar day numbers and navigation.

### 3. Themes & Theme System
* `theme`: Active theme name (default: `nord`).
  * Built-in themes: `nord`, `dracula`, `catppuccin`, `tokyo-night`, `rose-pine`, `frosted-neumorphic`.
  * **Built-in Location**: Shipped in `/usr/share/mizu/themes/`.
  * **User Overrides**: When a theme is selected, its files are copied to `~/.config/mizu/themes/<theme_name>/` and loaded from the user copy. User modifications are preserved and never overwritten on theme changes.
  * **CSS-based Colors & Styling**: Each theme directory includes a `theme.css` file defining CSS variables (`--mizu-base`, `--mizu-accent`, `--mizu-radius-bar`, etc.) and GTK `@define-color` rules.
  * **Automatic SVG Recoloring**: SVG icons in theme directories and asset paths are automatically recolored using the active theme's palette where appropriate, with full anti-aliased rendering via Mizu's NanoSVG renderer.
  * **Fallback Handling**: If a user theme is missing or invalid, Mizu safely falls back to built-in themes without overwriting user customizations.
* `font_family`: Primary font family (e.g. `Maple Mono NF, monospace`).
* `clock_format`: Standard strftime format string (e.g. `%a %b %d %H:%M`).
* `calendar_file`: Optional custom `.ics` calendar file for holiday dates.

### 4. Modular Layout
* `modules_left`: Comma-separated list of left-aligned modules.
* `modules_center`: Comma-separated list of center-aligned modules.
* `modules_right`: Comma-separated list of right-aligned modules.

Available module names: `launcher`, `workspaces`, `buttons`, `keymaps`, `clock`, `mpris`, `recorder`, `tray`, `battery`, `memory`, `network`, `bluetooth`, `volume`, `quicksettings`, `theme_switch`, `separator`.

### 5. Custom Buttons (`[buttons]`)
Add custom quick-launch buttons to the bar (`Label = Command`):
```ini
[buttons]
󰌌 Term = foot
󰈹 Web = firefox
󰅍 Clip = mizu clipboard
```

### 6. Custom Panels (`[panels]`)
Register custom overlay panels toggleable via `mizu <name>`:
```ini
[panels]
mixer = pavucontrol
dashboard = foot -e btop
```
