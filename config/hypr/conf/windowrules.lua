-- -----------------------------------------------------
-- Window Rules
-- -----------------------------------------------------

hl.window_rule({
    name  = "calculator",
    match = { class = "org.gnome.Calculator" },
    float = true,
    size  = { 300, 400 },
})

-- -----------------------------------------------------
-- Layer Rules (Shelly surfaces)
-- -----------------------------------------------------

-- Shelly animates its own surfaces; Hyprland's layersIn/layersOut on top
-- of that tear a panel that is reopened while still closing. Its docs ask
-- for this rule even without blur.
hl.layer_rule({
    name  = "shelly-no-anim",
    match = { namespace = "^shelly-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$" },
    no_anim = true,
})

-- Compositor blur behind the bar, panels, notifications and OSDs
-- (decoration.blur is on in layout.lua).
hl.layer_rule({
    name  = "shelly-blur",
    match = { namespace = "^shelly-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$" },
    ignore_alpha = 0.5,
    blur         = true,
    blur_popups  = true,
})
