local plugin_label   = 'debug_info'
local plugin_version = '1.0.0'
console.print('Lua Plugin - Debug Info - v' .. plugin_version)

local SCAN_INTERVAL  = 0.5
local MAX_ACTOR_DIST = 30.0

local actors_cache = {}
local last_scan    = -1

local pending_print_pos        = false
local pending_print_world      = false
local pending_print_actors     = false

local main_tree    = tree_node:new(0)
local enabled      = checkbox:new(true,  get_hash(plugin_label .. '_enabled'))
local show_all     = checkbox:new(false, get_hash(plugin_label .. '_show_all'))
local print_pos    = checkbox:new(false, get_hash(plugin_label .. '_print_pos'))
local print_world  = checkbox:new(false, get_hash(plugin_label .. '_print_world'))
local print_actors = checkbox:new(false, get_hash(plugin_label .. '_print_actors'))

local function scan_actors()
    actors_cache = {}
    local player = get_local_player()
    if not player then return end
    local ppos = player:get_position()

    for _, actor in ipairs(actors_manager.get_all_actors()) do
        local ok, name = pcall(function() return actor:get_skin_name() end)
        if not ok or not name then name = '<unknown>' end

        local pos  = actor:get_position()
        local dist = ppos:dist_to(pos)

        if dist <= MAX_ACTOR_DIST then
            local interactable = false
            pcall(function() interactable = actor:is_interactable() end)
            actors_cache[#actors_cache + 1] = {
                name = name, pos = pos, dist = dist, interactable = interactable,
            }
        end
    end

    table.sort(actors_cache, function(a, b) return a.dist < b.dist end)
end

on_update(function()
    if not enabled:get() then actors_cache = {} return end
    local now = get_time_since_inject()
    if (now - last_scan) >= SCAN_INTERVAL then
        last_scan = now
        scan_actors()
    end
end)

on_render(function()
    if not enabled:get() then return end

    local player = get_local_player()
    if not player then return end
    local ppos = player:get_position()

    local world_id  = '?'
    local zone_name = '?'
    local w = get_current_world()
    if w then
        pcall(function() world_id  = tostring(w:get_world_id()) end)
        pcall(function() zone_name = tostring(w:get_current_zone_name()) end)
    end

    local sx = 10
    local sy = 200
    local lh = 16

    graphics.text_2d('── DEBUG INFO ──', vec2:new(sx, sy), 14, color_white(255))
    sy = sy + lh

    graphics.text_2d(
        string.format('Pos:  (%.1f, %.1f, %.1f)', ppos:x(), ppos:y(), ppos:z()),
        vec2:new(sx, sy), 13, color_yellow(255))
    sy = sy + lh

    graphics.text_2d('Zone: ' .. zone_name,    vec2:new(sx, sy), 13, color_yellow(255))
    sy = sy + lh
    graphics.text_2d('World ID: ' .. world_id, vec2:new(sx, sy), 13, color_yellow(255))
    sy = sy + lh + 4

    graphics.text_2d(
        string.format('── ACTORS WITHIN %.0fm (%d) ──', MAX_ACTOR_DIST, #actors_cache),
        vec2:new(sx, sy), 13, color_white(255))
    sy = sy + lh

    for _, a in ipairs(actors_cache) do
        if show_all:get() or a.interactable then
            local col = a.interactable and color_green(255) or color_white(200)
            local tag = a.interactable and ' [I]' or ''
            graphics.text_2d(
                string.format('  %.1fm  %s%s', a.dist, a.name, tag),
                vec2:new(sx, sy), 12, col)
            sy = sy + lh
        end
    end

    for _, a in ipairs(actors_cache) do
        if a.interactable then
            graphics.circle_3d(a.pos, 1.2, color_green(200))
            graphics.text_3d(
                string.format('%s (%.0fm)', a.name, a.dist),
                a.pos, 13, color_green(255))
        end
    end
end)

on_render_menu(function()
    if not main_tree:push('Z | Debug Info | v' .. plugin_version) then return end

    enabled:render('Enable', 'Show on-screen overlay.')
    show_all:render('Show all actors', 'Show every actor, not just interactable ones.')

    print_pos:render('Print position to console', 'Prints current X/Y/Z. Auto-unchecks.')
    if print_pos:get() then
        print_pos:set(false)
        pending_print_pos = true
    end

    print_world:render('Print world info to console', 'Prints zone name and world ID. Auto-unchecks.')
    if print_world:get() then
        print_world:set(false)
        pending_print_world = true
    end

    print_actors:render('Print nearby actors to console', 'Prints all actors within 30m. Auto-unchecks.')
    if print_actors:get() then
        print_actors:set(false)
        pending_print_actors = true
    end

    -- flush pending console prints
    if pending_print_pos then
        pending_print_pos = false
        local p = get_local_player()
        if p then
            local pos = p:get_position()
            console.print(string.format('[Debug] Pos: vec3:new(%.4f, %.4f, %.4f)', pos:x(), pos:y(), pos:z()))
        end
    end

    if pending_print_world then
        pending_print_world = false
        local w = get_current_world()
        if w then
            console.print('[Debug] Zone:     ' .. tostring(w:get_current_zone_name()))
            console.print('[Debug] World:    ' .. tostring(w:get_name()))
            console.print('[Debug] World ID: ' .. tostring(w:get_world_id()))
        else
            console.print('[Debug] get_current_world() returned nil')
        end
    end

    if pending_print_actors then
        pending_print_actors = false
        local p = get_local_player()
        if p then
            local ppos = p:get_position()
            local count = 0
            console.print('[Debug] ── Actors within ' .. MAX_ACTOR_DIST .. 'm ──')
            for _, actor in ipairs(actors_manager.get_all_actors()) do
                local ok, name = pcall(function() return actor:get_skin_name() end)
                if not ok or not name then name = '<unknown>' end
                local dist = actor:get_position():dist_to(ppos)
                if dist <= MAX_ACTOR_DIST then
                    local interactable = false
                    pcall(function() interactable = actor:is_interactable() end)
                    local tag = interactable and ' [INTERACTABLE]' or ''
                    console.print(string.format('[Debug]   %.1fm  %s%s', dist, name, tag))
                    count = count + 1
                end
            end
            console.print('[Debug] Total: ' .. count .. ' actors')
        end
    end

    main_tree:pop()
end)
