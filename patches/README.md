# Mizu Patches

This directory contains community-contributed patches for Mizu, following a
suckless-inspired patch-based development model.

## How Patches Work

Patches are unified diffs (`.diff` or `.patch` files) that modify the Mizu
source code. They are applied using the standard `patch` command available on
Void Linux and most Unix-like systems.

## Patch Workflow

### 1. View Available Patches

```bash
cat patches/series
```

### 2. Apply a Patch

```bash
patch -p1 < patches/my-feature.diff
```

### 3. Remove a Patch

```bash
patch -R -p1 < patches/my-feature.diff
```

### 4. Create a New Patch

After making changes to the source:

```bash
git diff > patches/my-feature.diff
echo "my-feature.diff" >> patches/series
```

## Patch Prerequisites

Each patch should document:
- Which Mizu version it applies to
- Any other patches it depends on (prerequisites)
- Which files it modifies
- How to configure or use the new feature

## Maintaining a Personal Fork

1. Fork the Mizu repository
2. Apply patches from `patches/series` in order
3. Add your own patches to the series file
4. When upstream updates, rebase your fork and re-apply patches

## Extension Points (Easy to Patch)

These areas are designed for straightforward patching:

- **Add a bar module**: Create `src/bar/my_module.zig`, register it in
  `src/bar/bar.zig`'s `renderLeftModule`/`renderRightModule`, and add a
  `ModuleKind` variant in `src/core/config.zig`.
- **Add a panel**: Create `src/panels/my_panel.zig`, add a command in
  `src/main.zig`'s `parseCommand`, and add a `run*` function.
- **Add a drawing primitive**: Add a method to `DrawCtx` in
  `src/core/draw.zig`.
- **Add a system service**: Create `src/services/my_service.zig` with a small
  API, then consume it from panels and bar modules.
- **Change the default theme**: Modify a theme function in
  `src/core/theme.zig`.

## Keeping Patches Minimal

Prefer patches that touch 1–3 files. Avoid spreading one feature across many
files. Keep module registration and configuration mapping obvious so patches
are easy to review and maintain.
