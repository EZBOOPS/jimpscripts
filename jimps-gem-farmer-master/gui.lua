local plugin_label   = 'gem_farmer'
local plugin_version = '1.0.0'

local gui = {}
gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.pending_zone          = false
gui.pending_pos           = false
gui.pending_interactables = false

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end

local function kb(key)
    return keybind:new(key, get_hash(plugin_label .. '_' .. 'keybind'))
end

gui.elements = {
    main_tree      = tree_node:new(0),
    main_toggle    = cb(false, 'main_toggle'),
    keybind_toggle = kb(0x70),  -- F1
    show_boss      = cb(false, 'show_boss'),
    dbg_coords     = cb(false, 'dbg_coords'),
}

gui.render = function()
    if not gui.elements.main_tree:push('Gem Farmer | v' .. plugin_version) then return end

    gui.elements.main_toggle:render('Enable', 'Enable Gem Farmer bot.')
    gui.elements.keybind_toggle:render('Toggle Keybind', 'Keybind to toggle the bot on/off.')
    gui.elements.show_boss:render('Show Boss Marker', 'Draw a 3D marker on the last known boss position.')
    gui.elements.dbg_coords:render('Debug Coords', 'Print position and boss distance to console every second.')

    if imgui.button('Print Zone Info') then gui.pending_zone = true end
    if imgui.button('Print Position') then gui.pending_pos = true end
    if imgui.button('Print Interactables') then gui.pending_interactables = true end

    gui.elements.main_tree:pop()
end

return gui
