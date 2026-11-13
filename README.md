# fifi

A background app (no menu bar icon) that fills windows to the screen, including Adobe apps that macOS's own
Window ▸ Fill doesn't handle well.

## What it does

- **Fill window** (⌥Space): the focused window of the front app fills its screen's usable area,
  with 8pt margins on every side (next to a shown Dock too).
- **Fill all** (⌥⌘Space): every eligible window on the current desktop fills its screen, back to front.
- **Fill new windows** (always on): a window another app opens is filled 0.3s
  after it appears, along with the windows an app opens as it launches. Only document windows
  are filled: standard windows, or non-standard ones at least 400×300, like Adobe apps' main
  windows. Dialogs, palettes and popups are left alone. A window that isn't ready yet is checked
  again after 0.7s and 1.5s. Adobe apps don't announce new windows, so fifi catches them when an
  unseen window becomes focused or main.
- **KakaoTalk:** windows aren't widened. Each one fills the height at its smallest width at the
  left edge, on top of each other.
- With an auto-hiding Dock, the Dock's side always counts as free space.

Needs the Accessibility permission. Launch at login is on after the first run. To quit,
run `pkill -x fifi`.

⌥⌘Space is macOS's default shortcut for the Finder search window: turn it off in System
Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Spotlight so fifi gets it.

## Build

    scripts/make-signing-cert.sh   # once: a "fifi local" signing certificate, so Accessibility survives rebuilds
    scripts/install.sh             # release build into /Applications and launch
    scripts/run.sh                 # debug build and launch from build/
    swift scripts/make-icon.swift  # redraw Support/AppIcon.icns
