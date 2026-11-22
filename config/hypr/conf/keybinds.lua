-- -----------------------------------------------------
-- Variables
-- -----------------------------------------------------

local mainMod = "SUPER"

-- Default applications
local terminal    = "alacritty"
local browser     = "google-chrome-stable"
local filemanager = "nautilus"
local calculator  = "gnome-calculator"

-- Shelly: shell actions are IPC commands on the running instance
-- (`shelly msg ...`, see Shelly's README, "Key bindings").
local function shell(args)
    return hl.dsp.exec_cmd("shelly msg " .. args)
end
-- Volume and brightness go through wpctl and brightnessctl (5% steps, 100%
-- ceiling); Shelly's OSD shows every change whoever made it.
local volume_up       = hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+")
local volume_down     = hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
local brightness_up   = hl.dsp.exec_cmd("brightnessctl set 5%+")
local brightness_down = hl.dsp.exec_cmd("brightnessctl set 5%-")

-- -----------------------------------------------------
-- Key bindings
-- -----------------------------------------------------

-- Applications
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd(browser))
hl.bind(mainMod .. " + G", hl.dsp.exec_cmd("lutris"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(filemanager .. " --new-window"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd(filemanager .. " admin://"))
hl.bind(mainMod .. " + C", hl.dsp.exec_cmd(calculator))
hl.bind(mainMod .. " + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"))

-- Windows
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind("ALT + F4", hl.dsp.window.close())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mainMod .. " + M", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(mainMod .. " + Z", hl.dsp.window.float({ action = "toggle" }))
hl.bind("ALT + tab", hl.dsp.window.cycle_next())
hl.bind(mainMod .. " + tab", hl.dsp.window.cycle_next())

hl.bind(mainMod .. " + left",  hl.dsp.focus({ workspace = "r-1" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ workspace = "r+1" }))
hl.bind(mainMod .. " + up",    hl.dsp.window.fullscreen({ mode = "maximized", action = "set" }))
hl.bind(mainMod .. " + down",  hl.dsp.window.fullscreen({ mode = "maximized", action = "unset" }))
hl.bind(mainMod .. " + ALT + left",  hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + ALT + right", hl.dsp.window.move({ direction = "right" }))

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind(mainMod .. " + SHIFT + up",   hl.dsp.window.resize({ x = 100,  y = 0, relative = true }))
hl.bind(mainMod .. " + SHIFT + down", hl.dsp.window.resize({ x = -100, y = 0, relative = true }))

-- Groups (tabs): stack windows in one tile with a tab bar
hl.bind(mainMod .. " + T",      hl.dsp.group.toggle())
hl.bind(mainMod .. " + period", hl.dsp.group.next())
hl.bind(mainMod .. " + comma",  hl.dsp.group.prev())
hl.bind(mainMod .. " + CTRL + ALT + left",  hl.dsp.window.move({ into_group = "left" }))
hl.bind(mainMod .. " + CTRL + ALT + right", hl.dsp.window.move({ into_group = "right" }))
hl.bind(mainMod .. " + CTRL + ALT + down",  hl.dsp.window.move({ out_of_group = true }))

-- -----------------------------------------------------
-- Workspaces
-- -----------------------------------------------------

for i = 1, 6 do
    hl.bind(mainMod .. " + " .. i,             hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. i,     hl.dsp.window.move({ workspace = i, follow = false }))
    hl.bind("ALT + " .. i,                     hl.dsp.window.move({ workspace = i, follow = true }))
end

hl.bind(mainMod .. " + CTRL + left",  hl.dsp.focus({ workspace = "r-1" }))
hl.bind(mainMod .. " + CTRL + right", hl.dsp.focus({ workspace = "r+1" }))

hl.bind(mainMod .. " + CTRL + h", hl.dsp.focus({ workspace = "r-1" }))
hl.bind(mainMod .. " + CTRL + l", hl.dsp.focus({ workspace = "r+1" }))

hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ workspace = "r-1", follow = false }))
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ workspace = "r+1", follow = false }))

hl.bind(mainMod .. " + SHIFT + h", hl.dsp.window.move({ workspace = "r-1", follow = false }))
hl.bind(mainMod .. " + SHIFT + l", hl.dsp.window.move({ workspace = "r+1", follow = false }))

-- Alt+Left/Right also move the window; note this overrides back/forward in apps
hl.bind("ALT + left",  hl.dsp.window.move({ workspace = "r-1", follow = true }))
hl.bind("ALT + right", hl.dsp.window.move({ workspace = "r+1", follow = true }))

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "r-1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "r+1" }))
hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.window.move({ workspace = "r-1", follow = false }))
hl.bind(mainMod .. " + SHIFT + mouse_up",   hl.dsp.window.move({ workspace = "r+1", follow = false }))

-- -----------------------------------------------------
-- Actions
-- -----------------------------------------------------

hl.bind("ALT + space", shell("launcher toggle"))
hl.bind(mainMod .. " + V", shell("clipboard toggle"))
hl.bind(mainMod .. " + X", shell("session toggle"))
hl.bind(mainMod .. " + L", shell("lock"))

hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + SHIFT + W", shell("wallpaper toggle"))
hl.bind(mainMod .. " + S", shell("settings"))

-- Shelly locks before the machine sleeps (lockscreen.lock_before_suspend).
hl.bind("switch:Lid Switch", hl.dsp.exec_cmd("systemctl suspend"), { locked = true })

hl.bind(mainMod .. " + I", brightness_down)
hl.bind(mainMod .. " + O", brightness_up)

hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd('grim && notify-send -u normal -a "Snipping Tool" "Screenshot Captured" "Screenshot saved to /home/Pictures folder."'))

-- -----------------------------------------------------
-- Fn / Media keys
-- -----------------------------------------------------

hl.bind("XF86MonBrightnessUp",   brightness_up)
hl.bind("XF86MonBrightnessDown", brightness_down)
hl.bind("XF86AudioRaiseVolume",  volume_up)
hl.bind("XF86AudioLowerVolume",  volume_down)
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"))
hl.bind("XF86ScreenSaver",       shell("lock"))
hl.bind("Print",                 hl.dsp.exec_cmd("grim - | wl-copy"))
