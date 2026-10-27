# Getting Started

## Dependencies (Void Linux)

Mizu compiles with **Zig 0.16.0** and links against standard C system libraries:

```bash
sudo xbps-install -S \
  zig \
  wayland-devel \
  wayland-protocols \
  libxkbcommon-devel \
  freetype-devel \
  fontconfig-devel \
  libpng-devel \
  libjpeg-turbo-devel \
  pam-devel \
  dbus-devel \
  pkg-config
```

---

## Building & Installation

Compile with the Zig build system:

```bash
git clone https://github.com/mizu-shell/mizu.git
cd mizu

# Release build (recommended)
zig build -Doptimize=ReleaseFast

# Symlink to user PATH
mkdir -p ~/.local/bin
ln -sf $(pwd)/zig-out/bin/mizu ~/.local/bin/mizu
```

Run tests to verify the build:

```bash
zig build test
```

---

## Autostart in MangoWC

Start the desktop shell daemon (status bar, notification server, and system tray) in your MangoWC startup script (`~/.config/mangowc/autostart`):

```bash
mizu &
```

### Recommended Keybindings

Bind compositor shortcuts to toggle Mizu's overlay surfaces:

```ini
# Application Launcher (Super + Space)
bind = SUPER, Space, exec, mizu launcher

# Quick Settings Drawer (Super + S)
bind = SUPER, S, exec, mizu quicksettings

# Interactive Calendar (Super + C)
bind = SUPER, C, exec, mizu calendar

# Clipboard Manager (Super + V)
bind = SUPER, V, exec, mizu clipboard

# Process Memory Monitor (Super + M)
bind = SUPER, M, exec, mizu system-monitor

# Screen Lock (Super + L)
bind = SUPER, L, exec, mizu lock

# Power / Session Menu (Super + Backspace)
bind = SUPER, Backspace, exec, mizu power
```

All panel commands toggle automatically: running a command while the panel is active closes it cleanly.
