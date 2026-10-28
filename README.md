# Mizu (水)

A minimal, lightweight Wayland desktop shell written in Zig for Void Linux and MangoWC.

Mizu uses native Wayland protocols and Clay for layout, with a custom Zig renderer. It avoids heavyweight UI toolkits like GTK, Qt, and Electron.

## Features

- **Modular Bar** — Workspaces, clock, media, battery, audio, network, system tray, and themes.
- **Application Launcher** — Icon grid, keyboard navigation, and incremental search.
- **Quick Settings** — Wi-Fi, Bluetooth, volume, brightness, media controls, and system metrics.
- **Lock Screen** — Native Wayland session locking with PAM authentication.
- **Panels** — Calendar, clipboard, notifications, power menu, and system monitor.
- **Image Suite** — `mizu-annotate` (screenshots, markup, blurring, pixelation) and `mizu-image` (viewer, cropper, rotator, filters).
- **Customizable** — INI configuration, themes, buttons, and custom panels.
- **Lightweight** — Native rendering, on-demand panels, and minimal idle CPU usage.

## Documentation

- [Overview](docs/src/overview.md)
- [Getting Started](docs/src/getting-started.md)
- [User Guide](docs/src/user-guide.md)
- [Image Applications](docs/src/image-apps.md)
- [Configuration](docs/src/configuration.md)

## Dependencies

Verified on Void Linux x86_64.

- Zig 0.16.0
- MangoWC
- Wayland and Wayland protocols
- libxkbcommon
- FreeType
- Fontconfig
- pkg-config

Install system dependencies:

```bash
sudo xbps-install -S wayland-devel wayland-protocols libxkbcommon-devel freetype-devel fontconfig-devel pkg-config
```

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Install to your local PATH:

```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/zig-out/bin/mizu" ~/.local/bin/mizu
ln -sf "$(pwd)/zig-out/bin/mizu-annotate" ~/.local/bin/mizu-annotate
ln -sf "$(pwd)/zig-out/bin/mizu-image" ~/.local/bin/mizu-image
```

## Usage

```text
mizu                 Start the shell
mizu launcher        Application launcher
mizu quicksettings   Quick settings
mizu lock            Lock the session
mizu power           Power menu
mizu calendar        Calendar
mizu clipboard       Clipboard manager
mizu annotate        Image annotation & screenshot markup tool
mizu image           Image viewer, editor & transformer
mizu wallpaper       Wallpaper manager (switch thumbnails or set image)
mizu notify          Desktop notification
mizu theme list      List available themes
mizu help            Show available commands
```

## MangoWC Integration

Add to your MangoWC configuration:

```conf
exec_always = mizu
bind = SUPER, Space, spawn, mizu launcher
```

## Configuration

Mizu reads its configuration from:

```text
~/.config/mizu/config.ini
```

See [`config/config.example`](config/config.example) for the available options.
