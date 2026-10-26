# Keeps folder icons previewing the images inside them: hands the folders
# Nautilus shows to ~/.local/bin/folder-preview, which does the drawing.
# That runs as its own process because Python threads started in here never
# get to run while Nautilus is idle. Installed by hyprland.sh.
import os

from gi.repository import GLib, GObject, Nautilus

HELPER = os.path.join(GLib.get_home_dir(), ".local", "bin", "folder-preview")


class FolderPreviewExtension(GObject.GObject, Nautilus.InfoProvider):
    def __init__(self):
        super().__init__()
        self.pending = set()
        self.timer = 0

    def update_file_info(self, file):
        path = file.get_location().get_path()
        if not path:
            return
        # A folder's own icon, or the folder a file is shown in: images
        # added there or removed change its preview.
        self.pending.add(path if file.is_directory() else os.path.dirname(path))
        # Restarted on every call, so a folder full of files loading ends
        # in a single run of the helper.
        if self.timer:
            GLib.source_remove(self.timer)
        self.timer = GLib.timeout_add(500, self.flush)

    def flush(self):
        self.timer = 0
        paths, self.pending = sorted(self.pending), set()
        try:
            GLib.spawn_async([HELPER, *paths])
        except GLib.Error:
            pass  # helper not installed
        return GLib.SOURCE_REMOVE
