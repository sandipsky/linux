# "Open in Code" and "Open in Terminal" in Nautilus' right-click menu.
# Installed by hyprland.sh.
import shutil

from gi.repository import GLib, GObject, Nautilus


def launch(argv):
    # Without DO_NOT_REAP_CHILD, GLib double-forks: the app is detached from
    # Nautilus and leaves no zombie behind.
    GLib.spawn_async(argv, flags=GLib.SpawnFlags.SEARCH_PATH)


class OpenInExtension(GObject.GObject, Nautilus.MenuProvider):
    def _items(self, paths, folder):
        items = []
        if shutil.which("code"):
            item = Nautilus.MenuItem(name="OpenIn::Code", label="Open in Code")
            item.connect("activate", lambda *_: launch(["code", *paths]))
            items.append(item)
        if folder and shutil.which("alacritty"):
            item = Nautilus.MenuItem(name="OpenIn::Terminal", label="Open in Terminal")
            item.connect("activate", lambda *_: launch(["alacritty", "--working-directory", folder]))
            items.append(item)
        return items

    def get_file_items(self, files):
        # get_path() is None for places with no local path (trash://, recent://).
        paths = [f.get_location().get_path() for f in files]
        if not paths or None in paths:
            return []
        folder = paths[0] if len(files) == 1 and files[0].is_directory() else None
        return self._items(paths, folder)

    def get_background_items(self, current_folder):
        path = current_folder.get_location().get_path()
        return self._items([path], path) if path else []
