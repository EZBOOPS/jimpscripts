local gui      = require 'gui'
local settings = {}

settings.update_settings = function()
    settings.enabled   = gui.elements.main_toggle:get()
    settings.show_boss = gui.elements.show_boss:get()
end

settings.get_keybind_state = function()
    return gui.elements.keybind_toggle:get()
end

return settings
