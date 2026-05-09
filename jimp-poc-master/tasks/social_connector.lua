local tracker  = require 'core.tracker'
local settings = require 'core.settings'
local world    = require 'core.world'
local stats    = require 'core.stats'

local KEY_O   = 0x4F
local KEY_ESC = 0x1B

local function step_delay()    return settings.social_step_delay    or 1 end
local function join_wait()     return settings.social_join_wait      or 6 end
local function transfer_wait() return settings.social_transfer_wait  or 2 end
local function leave_wait()    return settings.social_leave_wait     or 2 end
local function arrival_timeout() return settings.social_arrival_timeout or 30 end

local DUNGEON_START = vec3:new(108.5811, 47.0459, 0.0977)
local START_RADIUS  = 10.0

local STEP = {
    IDLE                  = 0,
    OPEN_SOCIAL           = 1,
    OPEN_SOCIAL_WAIT      = 2,
    CLICK_FRIEND          = 3,
    CLICK_FRIEND_WAIT     = 4,
    CLICK_JOIN_PARTY      = 5,
    CLICK_JOIN_WAIT       = 6,
    CLICK_TRANSFER        = 7,
    CLICK_TRANSFER_WAIT   = 8,
    WAIT_FOR_ARRIVAL      = 9,
    TEMERITY_CLICK_TELEPORT = 17,
    TEMERITY_WAIT_DUNGEON   = 18,
    POST_TELEPORT_WAIT    = 21,
    OPEN_SOCIAL_2         = 10,
    OPEN_SOCIAL_2_WAIT    = 11,
    CLICK_LEAVE_PARTY     = 12,
    CLICK_LEAVE_WAIT      = 13,
    CLICK_LEAVE_CONFIRM   = 14,
    CLICK_LEAVE_CONF_WAIT = 15,
    WAIT_ALFRED           = 20,
    DONE                  = 16,
}

local MAX_RETRIES    = 5
local STEP_WATCHDOG  = 60.0

local WATCHDOG_EXEMPT = {
    [0]  = true,
    [20] = true,
}

local task = {
    name           = 'social_connector',
    status         = 'idle',
    step           = STEP.IDLE,
    step_time      = -1,
    from_temerity  = false,
    retry_count    = 0,
}

local recent_clicks = {}
local CLICK_FADE    = 5.0

local function record_click(label, x, y)
    recent_clicks[#recent_clicks + 1] = { label = label, x = x, y = y, t = get_time_since_inject() }
    while #recent_clicks > 8 do table.remove(recent_clicks, 1) end
end

function task.get_recent_clicks()
    local now = get_time_since_inject()
    while recent_clicks[1] and (now - recent_clicks[1].t) > CLICK_FADE do
        table.remove(recent_clicks, 1)
    end
    return recent_clicks, CLICK_FADE
end

local function log(msg) console.print('[PathOfCoin:social] ' .. msg) end

local function set_step(s)
    task.step      = s
    task.step_time = get_time_since_inject()
end

local function waited(secs)
    return (get_time_since_inject() - task.step_time) >= secs
end

local function click(label, x, y)
    utility.send_mouse_move(x, y)
    utility.send_mouse_click(x, y)
    record_click(label, x, y)
    log(string.format('clicked %s at (%d, %d)', label, x, y))
end

local function alfred_status()
    local alfred = _G.AlfredTheButlerPlugin
    if not alfred or type(alfred.get_status) ~= 'function' then return nil end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return nil end
    return s
end

-- Returns the Alfred plugin object, checking multiple possible global names.
local function get_alfred()
    return _G.AlfredTheButlerPlugin
        or _G.PLUGIN_alfred_the_butler
        or _G.alfred
        or nil
end

-- True when Alfred is idle (not processing a queue).
-- Mirrors WarPigs: uses trigger_tasks flag, not all_task_done, so a fresh
-- launch with nothing to do doesn't gate forever.
local function alfred_idle()
    local alfred = get_alfred()
    if not alfred or type(alfred.get_status) ~= 'function' then return true end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return true end
    if not s.enabled then return true end
    -- Paused + work pending = not idle (alfred_trigger will resume it).
    if s.paused then
        if s.need_trigger or s.inventory_full or s.talisman_full then return false end
        return true
    end
    return not s.trigger_tasks
end

-- True when Alfred needs to go to town (inventory full or seals need trigger).
local function alfred_needs_work()
    local alfred = get_alfred()
    if not alfred or type(alfred.get_status) ~= 'function' then return false end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return false end
    return s.enabled and (s.need_trigger or s.inventory_full or s.talisman_full)
end

local function looteer_set(state)
    if _G.LooteerPlugin and type(LooteerPlugin.setSettings) == 'function' then
        LooteerPlugin.setSettings('looting', state)
        log('Looteer looting -> ' .. tostring(state))
    end
end

-- Resume Alfred if paused, then fire trigger_tasks.
-- Returns true if a trigger was actually issued.
local function alfred_trigger()
    local alfred = get_alfred()
    if not alfred or type(alfred.trigger_tasks) ~= 'function' then
        log('!! Alfred not loaded — cannot trigger')
        return false
    end
    local ok, s = pcall(alfred.get_status)
    if ok and type(s) == 'table' and s.paused and type(alfred.resume) == 'function' then
        pcall(alfred.resume)
        log('Alfred was paused — resumed before trigger')
    end
    looteer_set(false)
    local ok2, err = pcall(alfred.trigger_tasks, 'PathOfCoin')
    if not ok2 then
        log('!! Alfred trigger_tasks errored: ' .. tostring(err))
        looteer_set(true)
        return false
    end
    log('triggered Alfred to stash/salvage')
    return true
end

-- Grace-period tracking: after triggering Alfred we wait a few seconds to
-- confirm it actually went busy before declaring it idle/done.
local ALFRED_GRACE_SECONDS = 4.0
local ALFRED_MAX_SECONDS   = 30.0
local alfred_fired_at      = nil
local alfred_was_busy      = false

local function alfred_wait_start()
    alfred_fired_at = get_time_since_inject()
    alfred_was_busy = false
end

-- Returns true when it's safe to move on past the Alfred wait.
local function alfred_wait_done()
    if alfred_fired_at == nil then return true end
    local elapsed  = get_time_since_inject() - alfred_fired_at
    local busy_now = not alfred_idle()
    if busy_now then alfred_was_busy = true end
    local function finish(reason)
        log(reason)
        alfred_fired_at = nil
        alfred_was_busy = false
        looteer_set(true)
        return true
    end

    if alfred_was_busy and not busy_now then
        return finish('Alfred finished its work')
    end
    if not alfred_was_busy and elapsed >= ALFRED_GRACE_SECONDS then
        return finish(string.format('Alfred had nothing to do (%.1fs grace) — moving on', elapsed))
    end
    if elapsed >= ALFRED_MAX_SECONDS then
        return finish(string.format('Alfred max wait (%.0fs) exceeded — moving on anyway', elapsed))
    end
    return false
end

local function near_start()
    local player = get_local_player()
    if not player then return false end
    return player:get_position():dist_to(DUNGEON_START) <= START_RADIUS
end

local function abort(reason)
    log('ABORT: ' .. reason .. ' — resetting to IDLE')
    task.step        = STEP.IDLE
    task.step_time   = -1
    task.retry_count = 0
    task.from_temerity = false
end

local _orig_reset = tracker.reset_run
tracker.reset_run = function()
    _orig_reset()
    task.step          = STEP.IDLE
    task.step_time     = -1
    task.from_temerity = false
    task.retry_count   = 0
end

task.shouldExecute = function()
    if not settings.use_social_connector then return false end
    return task.step > STEP.IDLE
end

task.start = function()
    if task.step == STEP.IDLE then
        task.from_temerity = world.is_in_temerity()
        log('starting social connector sequence' .. (task.from_temerity and ' (Temerity path)' or ' (normal path)'))
        set_step(STEP.OPEN_SOCIAL)
    end
end

task.Execute = function()
    local s = task.step

    if s == STEP.IDLE then
        return
    end

    if not WATCHDOG_EXEMPT[s] and task.step_time > 0 and
       (get_time_since_inject() - task.step_time) >= (settings.social_watchdog or STEP_WATCHDOG) then
        log(string.format('watchdog fired on step %d — restarting join sequence', s))
        stats.record_social_retry()
        task.retry_count   = task.retry_count + 1
        task.from_temerity = world.is_in_temerity()
        if task.retry_count >= MAX_RETRIES then
            abort('watchdog max retries reached')
            return
        end
        set_step(STEP.OPEN_SOCIAL)
        return

    elseif s == STEP.OPEN_SOCIAL then
        task.status = 'opening social menu (O)'
        utility.send_key_press(KEY_O)
        log('pressed O — opening social menu')
        set_step(STEP.OPEN_SOCIAL_WAIT)

    elseif s == STEP.OPEN_SOCIAL_WAIT then
        task.status = 'waiting for social menu...'
        if waited(step_delay()) then set_step(STEP.CLICK_FRIEND) end

    elseif s == STEP.CLICK_FRIEND then
        task.status = 'clicking friend name'
        click('Friend', settings.social_friend_x, settings.social_friend_y)
        set_step(STEP.CLICK_FRIEND_WAIT)

    elseif s == STEP.CLICK_FRIEND_WAIT then
        task.status = 'waiting after friend click...'
        if waited(step_delay()) then set_step(STEP.CLICK_JOIN_PARTY) end

    elseif s == STEP.CLICK_JOIN_PARTY then
        task.status = 'clicking join party'
        click('Join Party', settings.social_join_x, settings.social_join_y)
        set_step(STEP.CLICK_JOIN_WAIT)

    elseif s == STEP.CLICK_JOIN_WAIT then
        task.status = 'waiting for party join to resolve...'
        if waited(join_wait()) then
            if task.from_temerity then
                set_step(STEP.TEMERITY_CLICK_TELEPORT)
            else
                set_step(STEP.CLICK_TRANSFER)
            end
        end

    elseif s == STEP.CLICK_TRANSFER then
        task.status = 'clicking Transfer Now'
        click('Transfer Now', settings.social_transfer_x, settings.social_transfer_y)
        set_step(STEP.CLICK_TRANSFER_WAIT)

    elseif s == STEP.CLICK_TRANSFER_WAIT then
        task.status = 'waiting for transfer...'
        if waited(transfer_wait()) then set_step(STEP.WAIT_FOR_ARRIVAL) end

    elseif s == STEP.WAIT_FOR_ARRIVAL then
        task.status = 'waiting to arrive near dungeon start...'
        if near_start() then
            log('arrived at dungeon start — waiting before leaving party')
            task.retry_count = 0
            set_step(STEP.POST_TELEPORT_WAIT)
        elseif waited(arrival_timeout()) then
            log('arrival timeout — skipping to leave party and restarting')
            task.retry_count = 0
            set_step(STEP.OPEN_SOCIAL_2)
        end

    elseif s == STEP.TEMERITY_CLICK_TELEPORT then
        task.status = 'Temerity: waiting to click teleport button...'
        if waited(join_wait()) then
            click('Teleport', settings.social_teleport_x, settings.social_teleport_y)
            set_step(STEP.TEMERITY_WAIT_DUNGEON)
        end

    elseif s == STEP.TEMERITY_WAIT_DUNGEON then
        task.status = 'Temerity: waiting for world change to dungeon...'
        if world.is_in_dungeon() then
            log('world changed to dungeon — waiting before leaving party')
            task.retry_count = 0
            set_step(STEP.POST_TELEPORT_WAIT)
        elseif waited(arrival_timeout()) then
            log('Temerity teleport timeout — skipping to leave party and restarting')
            task.retry_count = 0
            set_step(STEP.OPEN_SOCIAL_2)
        end

    elseif s == STEP.POST_TELEPORT_WAIT then
        task.status = 'waiting before leaving party...'
        if waited(settings.social_post_teleport_wait or 8) then
            set_step(STEP.OPEN_SOCIAL_2)
        end

    elseif s == STEP.OPEN_SOCIAL_2 then
        task.status = 'opening social menu to leave party (O)'
        utility.send_key_press(KEY_O)
        log('pressed O — opening social menu to leave party')
        set_step(STEP.OPEN_SOCIAL_2_WAIT)

    elseif s == STEP.OPEN_SOCIAL_2_WAIT then
        task.status = 'waiting for social menu...'
        if waited(step_delay()) then
            set_step(STEP.CLICK_LEAVE_PARTY)
        elseif waited(step_delay() * 3) then
            task.retry_count = task.retry_count + 1
            if task.retry_count >= MAX_RETRIES then
                abort('social menu open max retries reached')
            else
                log(string.format('social menu open timeout — retrying O (%d/%d)', task.retry_count, MAX_RETRIES))
                set_step(STEP.OPEN_SOCIAL_2)
            end
        end

    elseif s == STEP.CLICK_LEAVE_PARTY then
        task.status = 'clicking leave party'
        click('Leave Party', settings.social_leave_x, settings.social_leave_y)
        set_step(STEP.CLICK_LEAVE_WAIT)

    elseif s == STEP.CLICK_LEAVE_WAIT then
        task.status = 'waiting for leave party confirm...'
        if waited(step_delay()) then set_step(STEP.CLICK_LEAVE_CONFIRM) end

    elseif s == STEP.CLICK_LEAVE_CONFIRM then
        task.status = 'clicking accept/confirm'
        click('Accept', settings.social_accept_x, settings.social_accept_y)
        set_step(STEP.CLICK_LEAVE_CONF_WAIT)

    elseif s == STEP.CLICK_LEAVE_CONF_WAIT then
        task.status = 'waiting after confirm...'
        if waited(leave_wait()) then
            log('left party — own dungeon instance active')
            tracker.left_party = true
            stats.record_run(tracker.enter_time, tracker.chests_opened)
            if settings.use_alfred and alfred_needs_work() then
                alfred_trigger()
                alfred_wait_start()
                log('Alfred has work — waiting for it to finish')
                set_step(STEP.WAIT_ALFRED)
            else
                if settings.use_alfred then log('Alfred has nothing to do — skipping') end
                tracker.reset_run()
                tracker.left_party = true
                set_step(STEP.DONE)
            end
        end

    elseif s == STEP.WAIT_ALFRED then
        task.status = 'waiting for Alfred to finish...'
        if alfred_wait_done() then
            tracker.reset_run()
            tracker.left_party = true
            set_step(STEP.DONE)
        end

    elseif s == STEP.DONE then
        task.status = 'idle'
        set_step(STEP.IDLE)
    end
end

return task
