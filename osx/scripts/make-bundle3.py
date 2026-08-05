#!/usr/bin/env python3
"""
Bundle the kittyg build into Kittyg.app.

Rewritten for the current meson-based build and a Homebrew-under-$HOME
prefix (no /opt/homebrew admin access). Replaces the old Python 2 /
Autotools-era osx/scripts/make-bundle.
"""

import os
import shutil
import subprocess
import glob
import sys
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
BUILD = os.path.join(ROOT, "build")
BREW_PREFIX = os.environ["HOMEBREW_PREFIX"]

APP_NAME = "Kittyg"
APP_PATH = os.path.join(ROOT, APP_NAME + ".app")
CONTENTS = os.path.join(APP_PATH, "Contents")
MACOS = os.path.join(CONTENTS, "MacOS")
RESOURCES = os.path.join(CONTENTS, "Resources")
LIB = os.path.join(RESOURCES, "lib")

_resolved = {}


def pkgvar(pkg, var):
    return subprocess.check_output(
        ["pkg-config", "--variable", var, pkg], text=True
    ).strip()


_internal_libs = {
    os.path.basename(p): p
    for p in glob.glob(os.path.join(BUILD, "*", "*.dylib"))
}


def otool_deps(path, search_dir=None):
    """Returns (original_dep_string, resolved_absolute_path_or_None) pairs.

    @rpath/ entries resolve against our own internal libs (libgitg*);
    @loader_path/ entries resolve against the dylib's own original
    directory (used e.g. by icu4c for sibling libicudata/libicui18n).
    """
    out = subprocess.check_output(["otool", "-L", path], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dep = line.split(" ")[0]
        if dep.startswith("@rpath/"):
            name = dep[len("@rpath/"):]
            resolved = _internal_libs.get(name)
            deps.append((dep, resolved))
        elif dep.startswith("@loader_path/"):
            name = dep[len("@loader_path/"):]
            resolved = os.path.join(search_dir, name) if search_dir else None
            if resolved and not os.path.exists(resolved):
                resolved = None
            deps.append((dep, resolved))
        else:
            deps.append((dep, dep))
    return deps


def needs_copy(p):
    if p is None:
        return False
    return (
        p.startswith(BREW_PREFIX)
        or p.startswith("/private/tmp")
        or p.startswith(BUILD)
        or "homebrew-local" in p
    )


def future_path(target):
    return "@executable_path/../Resources/lib/" + os.path.basename(target)


def fixup_deps(target, src_for_self_check=None, search_dir=None):
    for orig, resolved in otool_deps(target, search_dir=search_dir):
        rresolved = os.path.realpath(resolved) if resolved else None
        if not needs_copy(rresolved) or rresolved == src_for_self_check:
            continue
        dep_dst = copy_binary(rresolved, LIB)
        subprocess.run(
            ["install_name_tool", "-change", orig, future_path(dep_dst), target],
            check=False,
        )


def copy_binary(src, dst_dir, executable=False):
    src = os.path.realpath(src)
    name = os.path.basename(src)
    dst = os.path.join(dst_dir, name)

    if src in _resolved:
        return _resolved[src]

    os.makedirs(dst_dir, exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, 0o755)
    _resolved[src] = dst

    if not executable:
        subprocess.run(["install_name_tool", "-id", future_path(dst), dst], check=False)

    fixup_deps(dst, src_for_self_check=src, search_dir=os.path.dirname(src))

    subprocess.run(["codesign", "--remove-signature", dst], check=False, stderr=subprocess.DEVNULL)
    return dst


def main():
    shutil.rmtree(APP_PATH, ignore_errors=True)
    for d in (CONTENTS, MACOS, RESOURCES, LIB):
        os.makedirs(d, exist_ok=True)

    # --- main binary ---
    main_bin_src = os.path.join(BUILD, "gitg", "kittyg")
    main_bin_dst = os.path.join(MACOS, "kittyg-bin")
    shutil.copyfile(main_bin_src, main_bin_dst)
    os.chmod(main_bin_dst, 0o755)
    fixup_deps(main_bin_dst, search_dir=os.path.dirname(main_bin_src))
    subprocess.run(["codesign", "--remove-signature", main_bin_dst], check=False, stderr=subprocess.DEVNULL)

    # --- plugins ---
    plugin_dir = os.path.join(RESOURCES, "lib", "kittyg", "plugins")
    os.makedirs(plugin_dir, exist_ok=True)
    for so in glob.glob(os.path.join(BUILD, "plugins", "*", "*.so")):
        name = os.path.basename(so)
        dst = os.path.join(plugin_dir, name)
        shutil.copyfile(so, dst)
        os.chmod(dst, 0o755)
        fixup_deps(dst, search_dir=os.path.dirname(so))
        subprocess.run(["codesign", "--remove-signature", dst], check=False, stderr=subprocess.DEVNULL)
    for plugin_file in glob.glob(os.path.join(ROOT, "plugins", "*", "*.plugin")):
        shutil.copyfile(plugin_file, os.path.join(plugin_dir, os.path.basename(plugin_file)))

    # --- gsettings schemas ---
    schema_dir = os.path.join(RESOURCES, "share", "glib-2.0", "schemas")
    os.makedirs(schema_dir, exist_ok=True)
    schema_srcs = [
        os.path.join(BUILD, "data", "org.gnome.kittyg.gschema.xml"),
        os.path.join(BREW_PREFIX, "share", "glib-2.0", "schemas", "org.gtk.gtk4.Settings.FileChooser.gschema.xml"),
    ]
    for f in glob.glob(os.path.join(BREW_PREFIX, "share", "glib-2.0", "schemas", "*.gschema.xml")):
        shutil.copyfile(f, os.path.join(schema_dir, os.path.basename(f)))
    if os.path.exists(schema_srcs[0]):
        shutil.copyfile(schema_srcs[0], os.path.join(schema_dir, os.path.basename(schema_srcs[0])))
    subprocess.run(["glib-compile-schemas", schema_dir], check=True)

    # --- typelibs (needed for libpeas/PeasGtk python plugin loader) ---
    gir_dst = os.path.join(RESOURCES, "lib", "girepository-1.0")
    os.makedirs(gir_dst, exist_ok=True)
    for f in glob.glob(os.path.join(BUILD, "**", "*.typelib"), recursive=True):
        shutil.copyfile(f, os.path.join(gir_dst, os.path.basename(f)))
    gi_typelib_dir = pkgvar("gobject-introspection-1.0", "typelibdir")
    for name in ("Gio-2.0", "GObject-2.0", "GLib-2.0", "GModule-2.0", "Gtk-3.0", "Gdk-3.0",
                 "GdkPixbuf-2.0", "Pango-1.0", "cairo-1.0", "Peas-1.0", "PeasGtk-1.0"):
        f = os.path.join(gi_typelib_dir, name + ".typelib")
        if os.path.exists(f):
            shutil.copyfile(f, os.path.join(gir_dst, name + ".typelib"))

    # --- gtksourceview language specs / styles ---
    gsv_prefix = pkgvar("gtksourceview-4", "prefix")
    for sub in ("language-specs", "styles"):
        src = os.path.join(gsv_prefix, "share", "gtksourceview-4", sub)
        if os.path.isdir(src):
            dst = os.path.join(RESOURCES, "share", "gtksourceview-4", sub)
            shutil.copytree(src, dst, dirs_exist_ok=True)

    # --- icon themes ---
    for theme, srcdir in (
        ("Adwaita", os.path.join(BREW_PREFIX, "share", "icons", "Adwaita")),
        ("hicolor", os.path.join(BREW_PREFIX, "share", "icons", "hicolor")),
    ):
        if os.path.isdir(srcdir):
            shutil.copytree(srcdir, os.path.join(RESOURCES, "share", "icons", theme), dirs_exist_ok=True)
    kittyg_icons = os.path.join(BUILD, "data", "icons", "hicolor")
    if os.path.isdir(kittyg_icons):
        shutil.copytree(kittyg_icons, os.path.join(RESOURCES, "share", "icons", "hicolor"), dirs_exist_ok=True)

    # --- fontconfig ---
    fc_src = os.path.join(BREW_PREFIX, "etc", "fonts")
    if os.path.isdir(fc_src):
        shutil.copytree(fc_src, os.path.join(RESOURCES, "etc", "fonts"), dirs_exist_ok=True)

    # --- icon + Info.plist ---
    shutil.copyfile(os.path.join(ROOT, "osx", "data", "Gitg.icns"), os.path.join(RESOURCES, "Kittyg.icns"))
    with open(os.path.join(ROOT, "meson.build")) as f:
        m = re.search(r"version:\s*'([^']+)'", f.read())
        version = m.group(1) if m else "45.alpha"
    plist = open(os.path.join(ROOT, "osx", "data", "Info.plist")).read()
    plist = (plist.replace("${version}", version)
                   .replace("${name}", APP_NAME)
                   .replace("<string>Gitg</string>", "<string>kittyg</string>", 1)
                   .replace("Gitg.icns", "Kittyg.icns")
                   .replace("org.gnome.Gitg", "org.gnome.kittyg"))
    with open(os.path.join(CONTENTS, "Info.plist"), "w") as f:
        f.write(plist)

    # --- launcher script ---
    launcher = f"""#!/bin/bash
DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
RES="$DIR/../Resources"
export GSETTINGS_SCHEMA_DIR="$RES/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$RES/share"
export GI_TYPELIB_PATH="$RES/lib/girepository-1.0"
export FONTCONFIG_PATH="$RES/etc/fonts"
export FONTCONFIG_FILE="$RES/etc/fonts/fonts.conf"
export DYLD_LIBRARY_PATH="$RES/lib"
exec "$DIR/kittyg-bin" "$@"
"""
    launcher_path = os.path.join(MACOS, "kittyg")
    with open(launcher_path, "w") as f:
        f.write(launcher)
    os.chmod(launcher_path, 0o755)

    print(f"Bundle created at {APP_PATH}")


if __name__ == "__main__":
    main()
