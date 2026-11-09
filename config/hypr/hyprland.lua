--  _   _                  _                 _
-- | | | |_   _ _ __  _ __| | __ _ _ __   __| |
-- | |_| | | | | '_ \| '__| |/ _` | '_ \ / _` |
-- |  _  | |_| | |_) | |  | | (_| | | | | (_| |
-- |_| |_|\__, | .__/|_|  |_|\__,_|_| |_|\__,_|
--        |___/|_|
--

require("conf/animations")
require("conf/autostart")
require("conf/environment")
require("conf/keybinds")
require("conf/layout")
require("conf/windowrules")

-- Optional pieces that a scripts/*.sh helper drops into conf/ while what they
-- drive is installed (virtualbox.sh `install` copies assets/hypr/virtualbox.lua
-- in, `remove` deletes it) — pcall so a missing file is not a config error.
pcall(require, "conf/virtualbox")

-- VM guest overrides (software cursor, no blur). hyprland.sh writes
-- conf/vm.lua only when it runs inside a VM (VirtualBox, QEMU, ...); loaded
-- after the files above so its settings win. Not to be confused with
-- conf/virtualbox above, which is for running VirtualBox on this machine.
local in_vm = pcall(require, "conf/vm")

-- -----------------------------------------------------
-- Monitor
-- -----------------------------------------------------

hl.monitor({
    output   = "",
    -- In a VM the virtual display offers no 144 Hz mode, and its preferred
    -- mode follows the VM window size.
    mode     = in_vm and "preferred" or "1920x1080@144",
    position = "auto",
    scale    = 1,
})
