# Mizu Configuration Reference

Mizu reads its configuration from `~/.config/mizu/config.ini` (or `$XDG_CONFIG_HOME/mizu/config.ini`). If no configuration file exists, built-in defaults are used automatically.

---

## Complete Annotated Configuration Example

```ini
# 1. Bar Dimensions & Squircle Geometry

height = 42                 # Total height of the top bar in pixels
margin_top = 4              # Distance from the top screen edge
margin_bottom = 0           # Space below the bar
margin_left = 8             # Margin from the left screen edge
margin_right = 8            # Margin from the right screen edge
border_width = 1            # Width of the bar squircle border

bar_radius = 12             # Corner radius of the main top bar
pill_radius = 10            # Corner radius of chips and pills
panel_radius = 16           # Corner radius of floating panels (QuickSettings, Launcher, etc.)

# 2. Typography & Time Formatting

font_family = Maple Mono NF, monospace

# Typography sizes (logical pixels, clamped to 8-96)
# ui: standard interface text; secondary: descriptions, timestamps, muted labels
[typography]
ui = 15                     # General interface text
secondary = 13              # Descriptions, timestamps, muted labels
heading = 18                # Section headings
title = 20                  # Panel titles
bar_text = 15               # Bar chip labels
bar_icon = 20               # Bar and header icons
quicksettings_text = 15     # QuickSettings labels
quicksettings_icon = 23     # QuickSettings icons
submenu_text = 15           # QuickSettings submenu rows
calendar_text = 16          # Calendar day numbers
calendar_heading = 19       # Calendar month/navigation
button_text = 15            # Buttons and confirmation labels
keymap_text = 16            # Keymap overlay keycap labels

# Legacy aliases (still accepted): font_size -> ui, bar_font_size -> bar_text,
# panel_font_size -> ui

# Clock strftime format:
#   %a = Short weekday, %b = Short month, %d = Day of month, %H:%M = 24-hour time
#   %I:%M %P = 12-hour time with am/pm
clock_format = %a %b %d  %H:%M


# 3. Active Theme Preset

# Presets: frosted_neumorphic, nord, catppuccin, tokyo_night, gruvbox, rose_pine
# Aliases: mizu, pastel, frost -> frosted_neumorphic; noctalia -> tokyo_night; material_you -> catppuccin
theme = nord

# 3b. Calendar Holidays

# Optional local iCalendar (.ics) file. When set, Mizu reads this file instead
# of downloading the built-in India holiday calendar. Relative paths resolve
# from ~/.config/mizu (or $XDG_CONFIG_HOME/mizu); absolute paths and ~/ are
# also accepted.
# calendar_file = holiday.ics

# 3c. Keymap Overlay

# Position of the mizu keyoverlay surface:
#   top-left, top-center, top-right, bottom-left, bottom-center, bottom-right
keymap_position = bottom-center
# Optional alias for keymap_text in [typography] (logical pixels, 8-96)
# keymap_font_size = 16

# 4. Modular Layout Configuration

# Available modules:
#   launcher      - Application launcher pill
#   workspaces    - Roman numeral workspace indicators
#   buttons       - Custom quick-launch buttons from [buttons]
#   keymaps       - Keyboard layout indicator
#   clock         - Date and clock module
#   mpris         - Media player title & controls
#   recorder      - Screen recorder indicator & button
#   tray          - System tray (StatusNotifierItem / SNI) for running apps
#   battery       - Battery level chip
#   memory        - RAM usage chip
#   network       - Wi-Fi / Ethernet status chip
#   bluetooth     - Bluetooth status chip
#   volume        - Audio volume & mute indicator with scroll adjustment
#   theme_switch  - Dynamic live theme switcher
#   separator     - Vertical divider
modules_left = launcher, buttons, workspaces, keymaps
modules_center = clock, mpris
modules_right = theme_switch, volume, recorder, tray, bluetooth, network, memory, battery

# 5. Screen Recorder Settings
recorder_cmd = gpu-screen-recorder -w screen -f 60 -fm cfr -fallback-cpu-encoding yes -o "$HOME/Videos/recording_$(date +%Y%m%d_%H%M%S).mp4"
recorder_hide_when_idle = false

# 6. Quick-Launch Custom Buttons
# Format: Label = Shell Command or 'mizu <panel>'
# Active when 'buttons' is present in modules_left, modules_center, or modules_right
[buttons]
󰌌 Term = foot
󰈹 Web = firefox
󰉋 Files = thunar
󰅍 Clip = mizu clipboard
󰸗 Cal = mizu calendar
󰒓 QS = mizu quicksettings
󰚝 Audio = mizu mixer
󰐥 Power = wlogout

# 7. Custom Panels & Drawers
# Registered panel names can be toggled directly via 'mizu <name>'
# Mizu handles instance PID locking and toggles automatically.
[panels]
mixer = pavucontrol
dashboard = foot -e btop
files = thunar
notes = foot -e nvim ~/.notes.md
power = wlogout
calc = gnome-calculator

# 8. Custom Theme Color Overrides (Optional)
# Formats: #RRGGBB or #AARRGGBB
# bar_bg = #161817
# bar_border = #525E5A
# pill_bg = #525E5A
# ws_active_bg = #DF6124
# ws_active_fg = #161817
# panel_bg = #161817
# panel_border = #525E5A
# network_bg = #282C34
# network_fg = #98C379
```
