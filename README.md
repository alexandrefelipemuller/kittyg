# kittyg

`kittyg` is a fork of `gitg`, a graphical Git client built with GTK and Vala.
The project focuses on a fast UI for history browsing, commits, diffs, and common repository operations.

## Project status

- Based on the upstream `gitg` codebase.
- Main rebranding to `kittyg` has been applied (app name, desktop/metainfo, manifest/CI, UI text, and primary docs).
- Some internal APIs still use legacy names (`Gitg`, `libgitg`) to avoid large compatibility breakage.

## Features

- History view with references (branches/tags/remotes).
- Commit workflow with staging/unstaging.
- Reference actions (checkout, merge, push, create branch/tag/patch, etc.).
- Built-in plugins (`files` and `diff`) and extension support via `libpeas`.
- Application preferences (interface, history, commit, general).

## Recent changes in this fork

- New setting in Preferences > General to choose preferred Git client:
  - `Embedded`
  - `System`
- New context menu item in the commit list:
  - `Copy SHA to clipboard`

## Repository layout

- `gitg/`: main application (UI, activities, actions).
- `libgitg/`: core library, widgets, and utilities.
- `libgitg-ext/`: public extension interfaces.
- `plugins/`: built-in plugins.
- `data/`: desktop file, schemas, metainfo, manpage, icons, and resources.
- `tests/`: tests by module.
- `win32/`, `osx/`: platform packaging.

## Build and run

### Main dependencies

- Meson, Ninja, Vala (`valac`)
- GTK3, libhandy-1, libgit2-glib, gtksourceview-4, gspell, libpeas, libsecret, gee, json-glib, gobject-introspection

### Commands

```bash
meson setup build
ninja -C build
meson test -C build --print-errorlogs
```

## Important environment note

This code requires `libgit2-glib >= 1.2.0` (as defined in `meson.build`).
On Debian 12 (bookworm), the default package may be `1.1.0`, which prevents successful configuration.

## Flatpak and CI

- Development manifest: `org.gnome.kittygDevel.json`
- GitLab CI uses this manifest and app-id `org.gnome.kittygDevel`.

## License

GPL-2.0+ (inherited from the original project).
