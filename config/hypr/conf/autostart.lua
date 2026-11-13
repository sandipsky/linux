-- -----------------------------------------------------
-- Autostart
-- -----------------------------------------------------

hl.on("hyprland.start", function()
    -- Shelly: bar, launcher, notifications, clipboard, lock/idle, night
    -- light, wallpaper, OSDs and (polkit_agent = true in its config.toml)
    -- the polkit authentication agent. Started the way its Hyprland docs
    -- show; `shelly --daemon` is only for compositors that wait for the
    -- startup command to return.
    hl.exec_cmd("shelly")
end)
