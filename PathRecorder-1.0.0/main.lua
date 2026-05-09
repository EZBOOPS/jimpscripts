local plugin_label   = 'path_recorder'
local plugin_version = '1.0.0'
console.print('Lua Plugin - Path Recorder - v' .. plugin_version)

local MIN_DIST = 3.0   -- minimum metres between auto-recorded points

local waypoints  = {}
local last_pos   = nil

local pending_record  = false
local pending_undo    = false
local pending_clear   = false
local pending_print   = false
local pending_auto    = false

local main_tree    = tree_node:new(0)
local auto_record  = checkbox:new(false, get_hash(plugin_label .. '_auto_record'))
local do_record    = checkbox:new(false, get_hash(plugin_label .. '_do_record'))
local do_undo      = checkbox:new(false, get_hash(plugin_label .. '_do_undo'))
local do_clear     = checkbox:new(false, get_hash(plugin_label .. '_do_clear'))
local do_print     = checkbox:new(false, get_hash(plugin_label .. '_do_print'))

on_update(function()
    if not auto_record:get() then
        last_pos = nil
        return
    end

    local player = get_local_player()
    if not player then return end
    local pos = player:get_position()

    if last_pos == nil or pos:dist_to(last_pos) >= MIN_DIST then
        last_pos = pos
        waypoints[#waypoints + 1] = { x = pos:x(), y = pos:y(), z = pos:z() }
    end
end)

on_render(function()
    if #waypoints == 0 then return end

    -- Draw lines between waypoints and index labels
    for i, wp in ipairs(waypoints) do
        local p = vec3:new(wp.x, wp.y, wp.z)
        graphics.circle_3d(p, 0.6, color_cyan(200))
        graphics.text_3d(tostring(i), p, 12, color_cyan(255))
        if i > 1 then
            local prev = waypoints[i - 1]
            graphics.line(vec3:new(prev.x, prev.y, prev.z), p, color_cyan(150), 1.5)
        end
    end

    -- 2D counter
    graphics.text_2d(
        string.format('Path Recorder — %d points recorded', #waypoints),
        vec2:new(10, 170), 14, color_cyan(255))
end)

on_render_menu(function()
    if not main_tree:push('Z | Path Recorder | v' .. plugin_version) then return end

    auto_record:render('Auto-record (walk to record)',
        string.format('Automatically saves your position every %.0fm as you walk.', MIN_DIST))

    do_record:render('Record point now', 'Manually saves your current position. Auto-unchecks.')
    if do_record:get() then
        do_record:set(false)
        pending_record = true
    end

    do_undo:render('Undo last point', 'Removes the most recently recorded point. Auto-unchecks.')
    if do_undo:get() then
        do_undo:set(false)
        pending_undo = true
    end

    do_clear:render('Clear all points', 'Wipes the entire recorded path. Auto-unchecks.')
    if do_clear:get() then
        do_clear:set(false)
        pending_clear = true
    end

    do_print:render('Print path to console', 'Dumps all waypoints as Lua vec3 table — ready to paste into run_route.lua. Auto-unchecks.')
    if do_print:get() then
        do_print:set(false)
        pending_print = true
    end

    -- flush pending actions
    if pending_record then
        pending_record = false
        local player = get_local_player()
        if player then
            local pos = player:get_position()
            waypoints[#waypoints + 1] = { x = pos:x(), y = pos:y(), z = pos:z() }
            console.print(string.format('[PathRecorder] Recorded point %d: (%.4f, %.4f, %.4f)',
                #waypoints, pos:x(), pos:y(), pos:z()))
        end
    end

    if pending_undo then
        pending_undo = false
        if #waypoints > 0 then
            local removed = waypoints[#waypoints]
            table.remove(waypoints, #waypoints)
            console.print(string.format('[PathRecorder] Removed point %d: (%.4f, %.4f, %.4f)',
                #waypoints + 1, removed.x, removed.y, removed.z))
        else
            console.print('[PathRecorder] Nothing to undo.')
        end
    end

    if pending_clear then
        pending_clear = false
        waypoints = {}
        last_pos  = nil
        console.print('[PathRecorder] Path cleared.')
    end

    if pending_print then
        pending_print = false
        if #waypoints == 0 then
            console.print('[PathRecorder] No waypoints recorded yet.')
        else
            console.print('[PathRecorder] ── Paste into WAYPOINTS table in run_route.lua ──')
            console.print('local WAYPOINTS = {')
            for _, wp in ipairs(waypoints) do
                console.print(string.format('    vec3:new(%.4f, %.4f, %.4f),', wp.x, wp.y, wp.z))
            end
            console.print('}')
            console.print('[PathRecorder] ── End of waypoints ──')
        end
    end

    main_tree:pop()
end)
