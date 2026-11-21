-- -----------------------------------------------------
-- Autostart
-- -----------------------------------------------------

hl.on("hyprland.start", function()
    -- Shelly: bar, launcher, notifications, clipboard, lock/idle, night
    -- light, wallpaper and OSDs. It is not a polkit agent.
    hl.exec_cmd("shelly")
    -- Polkit agent: the password prompts of Nautilus admin://, GUI package
    -- tools and the like.
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
end)
