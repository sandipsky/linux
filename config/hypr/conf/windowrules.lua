-- -----------------------------------------------------
-- Window Rules
-- -----------------------------------------------------

hl.window_rule({
    name  = "calculator",
    match = { class = "org.gnome.Calculator" },
    float = true,
    size  = { 300, 400 },
})

-- Shelly Settings (Super+S), floating.
hl.window_rule({
    name  = "shelly-settings",
    match = { class = "io.shelly.Settings" },
    float = true,
    size  = { 1080, 920 },
})

-- -----------------------------------------------------
-- Layer Rules (Shelly surfaces)
-- -----------------------------------------------------

-- Shelly animates its own surfaces; Hyprland's layer animations on top of
-- that would tear a panel reopened while it is still closing. Whole names
-- only: shelly-panel-shield covers the screen while a panel is open.
hl.layer_rule({
    name  = "shelly-no-anim",
    match = { namespace = "^shelly-(bar|panel|launcher|toast|osd)$" },
    no_anim = true,
})

-- Compositor blur behind the bar, panels, launcher, toasts and OSD
-- (decoration.blur is on in layout.lua).
hl.layer_rule({
    name  = "shelly-blur",
    match = { namespace = "^shelly-(bar|panel|launcher|toast|osd)$" },
    ignore_alpha = 0.5,
    blur         = true,
    blur_popups  = true,
})
