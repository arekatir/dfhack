local _ENV = mkmodule('plugins.overlay')

local gui = require('gui')
local json = require('json')
local scriptmanager = require('script-manager')
local utils = require('utils')
local widgets = require('gui.widgets')

local OVERLAY_CONFIG_FILE = 'dfhack-config/overlay.json'
local OVERLAY_WIDGETS_VAR = 'OVERLAY_WIDGETS'

local DEFAULT_X_POS, DEFAULT_Y_POS = -2, -2

-- ---------------- --
-- state and config --
-- ---------------- --

local trigger_lock_holder_description = nil
local trigger_lock_holder_screen = nil -- if non-nil, no triggering allowed
local widget_db = {} -- map of widget name to ephermeral state
local widget_index = {} -- ordered list of widget names
local overlay_config = {} -- map of widget name to persisted state
local active_hotspot_widgets = {} -- map of widget names to the db entry
local active_viewscreen_widgets = {} -- map of vs_name to map of w.names -> db

function get_state()
    return {index=widget_index, config=overlay_config, db=widget_db}
end

function register_trigger_lock_screen(scr, desc)
    if trigger_lock_holder_screen then
        if not trigger_lock_holder_screen:isActive() then
            trigger_lock_holder_screen:dismiss()
        end
        trigger_lock_holder_description = nil
    end
    trigger_lock_holder_screen = scr
    if trigger_lock_holder_screen then
        trigger_lock_holder_description = desc
        return true
    end
end

local function triggered_screen_has_lock()
    if not trigger_lock_holder_screen then return false end
    if trigger_lock_holder_screen:isActive() then return true end
    return register_trigger_lock_screen(nil, nil)
end

local function reset()
    register_trigger_lock_screen(nil, nil)

    widget_db = {}
    widget_index = {}

    local ok, config = pcall(json.decode_file, OVERLAY_CONFIG_FILE)
    overlay_config = ok and config or {}

    active_hotspot_widgets = {}
    active_viewscreen_widgets = {}
end

local function save_config()
    if not safecall(json.encode_file, overlay_config, OVERLAY_CONFIG_FILE) then
        dfhack.printerr(('failed to save overlay config file: "%s"')
                :format(path))
    end
end

-- ----------- --
-- utility fns --
-- ----------- --

function normalize_list(element_or_list)
    if type(element_or_list) == 'table' then return element_or_list end
    return {element_or_list}
end

-- normalize "short form" viewscreen names to "long form"
local function normalize_viewscreen_name(vs_name)
    if vs_name == 'all' or vs_name:match('viewscreen_.*st') then
        return vs_name
    end
    return 'viewscreen_' .. vs_name .. 'st'
end

-- reduce "long form" viewscreen names to "short form"
function simplify_viewscreen_name(vs_name)
    _,_,short_name = vs_name:find('^viewscreen_(.*)st$')
    if short_name then return short_name end
    return vs_name
end

local function is_empty(tbl)
    for _ in pairs(tbl) do
        return false
    end
    return true
end

local function sanitize_pos(pos)
    local x = math.floor(tonumber(pos.x) or DEFAULT_X_POS)
    local y = math.floor(tonumber(pos.y) or DEFAULT_Y_POS)
    -- if someone accidentally uses 0-based instead of 1-based indexing, fix it
    if x == 0 then x = 1 end
    if y == 0 then y = 1 end
    return {x=x, y=y}
end

local function make_frame(pos, old_frame)
    old_frame = old_frame or {}
    local frame = {w=old_frame.w, h=old_frame.h}
    if pos.x < 0 then frame.r = math.abs(pos.x) - 1 else frame.l = pos.x - 1 end
    if pos.y < 0 then frame.b = math.abs(pos.y) - 1 else frame.t = pos.y - 1 end
    return frame
end

local function get_screen_rect()
    local w, h = dfhack.screen.getWindowSize()
    return gui.ViewRect{rect=gui.mkdims_wh(0, 0, w, h)}
end

-- ------------- --
-- CLI functions --
-- ------------- --

local function get_name(name_or_number)
    local num = tonumber(name_or_number)
    if num and widget_index[num] then
        return widget_index[num]
    end
    return tostring(name_or_number)
end

local function do_by_names_or_numbers(args, fn)
    local arglist = normalize_list(args)
    if #arglist == 0 then
        dfhack.printerr('please specify a widget name or list number')
        return
    end
    for _,name_or_number in ipairs(arglist) do
        local name = get_name(name_or_number)
        local db_entry = widget_db[name]
        if not db_entry then
            dfhack.printerr(('widget not found: "%s"'):format(name))
        else
            fn(name, db_entry)
        end
    end
end

local function do_enable(args, quiet, skip_save)
    local enable_fn = function(name, db_entry)
        overlay_config[name].enabled = true
        if db_entry.widget.hotspot then
            active_hotspot_widgets[name] = db_entry
        end
        for _,vs_name in ipairs(normalize_list(db_entry.widget.viewscreens)) do
            vs_name = normalize_viewscreen_name(vs_name)
            ensure_key(active_viewscreen_widgets, vs_name)[name] = db_entry
        end
        if not quiet then
            print(('enabled widget %s'):format(name))
        end
    end
    if args[1] == 'all' then
        for name,db_entry in pairs(widget_db) do
            if not overlay_config[name].enabled then
                enable_fn(name, db_entry)
            end
        end
    else
        do_by_names_or_numbers(args, enable_fn)
    end
    if not skip_save then
        save_config()
    end
end

local function do_disable(args, quiet)
    local disable_fn = function(name, db_entry)
        if db_entry.widget.always_enabled then return end
        overlay_config[name].enabled = false
        if db_entry.widget.hotspot then
            active_hotspot_widgets[name] = nil
        end
        for _,vs_name in ipairs(normalize_list(db_entry.widget.viewscreens)) do
            vs_name = normalize_viewscreen_name(vs_name)
            ensure_key(active_viewscreen_widgets, vs_name)[name] = nil
            if is_empty(active_viewscreen_widgets[vs_name]) then
                active_viewscreen_widgets[vs_name] = nil
            end
        end
        if not quiet then
            print(('disabled widget %s'):format(name))
        end
    end
    if args[1] == 'all' then
        for name,db_entry in pairs(widget_db) do
            if overlay_config[name].enabled then
                disable_fn(name, db_entry)
            end
        end
    else
        do_by_names_or_numbers(args, disable_fn)
    end
    save_config()
end

local function do_list(args)
    local filter = args and #args > 0
    local num_filtered = 0
    for i,name in ipairs(widget_index) do
        if filter then
            local passes = false
            for _,str in ipairs(args) do
                if name:find(str) then
                    passes = true
                    break
                end
            end
            if not passes then
                num_filtered = num_filtered + 1
                goto continue
            end
        end
        local db_entry = widget_db[name]
        local enabled = overlay_config[name].enabled
        dfhack.color(enabled and COLOR_LIGHTGREEN or COLOR_YELLOW)
        dfhack.print(enabled and '[enabled] ' or '[disabled]')
        dfhack.color()
        print((' %d) %s'):format(i, name))
        ::continue::
    end
    if num_filtered > 0 then
        print(('(%d widgets filtered out)'):format(num_filtered))
    end
end

local function load_widget(name, widget_class)
    local widget = widget_class{name=name}
    widget_db[name] = {
        widget=widget,
        next_update_ms=widget.overlay_onupdate and 0 or math.huge,
    }
    if not overlay_config[name] then overlay_config[name] = {} end
    local config = overlay_config[name]
    config.pos = sanitize_pos(config.pos or widget.default_pos)
    widget.frame = make_frame(config.pos, widget.frame)
    if config.enabled or widget.always_enabled then
        do_enable(name, true, true)
    else
        config.enabled = false
    end
end

local function load_widgets(env_name, env)
    local overlay_widgets = env[OVERLAY_WIDGETS_VAR]
    if not overlay_widgets then return end
    if type(overlay_widgets) ~= 'table' then
        dfhack.printerr(
                ('error loading overlay widgets from "%s": %s map is malformed')
                :format(env_name, OVERLAY_WIDGETS_VAR))
        return
    end
    for widget_name,widget_class in pairs(overlay_widgets) do
        local name = env_name .. '.' .. widget_name
        if not safecall(load_widget, name, widget_class) then
            dfhack.printerr(('error loading overlay widget "%s"'):format(name))
        end
    end
end

-- called directly from cpp on plugin enable
function reload()
    reset()

    for _,plugin in ipairs(dfhack.internal.listPlugins()) do
        local env_name = 'plugins.' .. plugin
        local ok, plugin_env = pcall(require, env_name)
        if ok then
            load_widgets(plugin, plugin_env)
        end
    end
    scriptmanager.foreach_module_script(load_widgets)

    for name in pairs(widget_db) do
        table.insert(widget_index, name)
    end
    table.sort(widget_index)

    reposition_widgets()
end

local function dump_widget_config(name, widget)
    local pos = overlay_config[name].pos
    print(('widget %s is positioned at x=%d, y=%d'):format(name, pos.x, pos.y))
    local viewscreens = normalize_list(widget.viewscreens)
    if #viewscreens > 0 then
        print('  it will be attached to the following viewscreens:')
        for _,vs in ipairs(viewscreens) do
            print(('    %s'):format(simplify_viewscreen_name(vs)))
        end
    end
    if widget.hotspot then
        print('  it will act as a hotspot on all screens')
    end
end

local function do_position(args, quiet)
    local name_or_number, x, y = table.unpack(args)
    local name = get_name(name_or_number)
    if not widget_db[name] then
        if not name_or_number then
            dfhack.printerr('please specify a widget name or list number')
        else
            dfhack.printerr(('widget not found: "%s"'):format(name))
        end
        return
    end
    local widget = widget_db[name].widget
    local pos
    if x == 'default' then
        pos = sanitize_pos(widget.default_pos)
    else
        x, y = tonumber(x), tonumber(y)
        if not x or not y then
            dump_widget_config(name, widget)
            return
        end
        pos = sanitize_pos{x=x, y=y}
    end
    overlay_config[name].pos = pos
    widget.frame = make_frame(pos, widget.frame)
    widget:updateLayout(get_screen_rect())
    save_config()
    if not quiet then
        print(('repositioned widget %s to x=%d, y=%d'):format(name, pos.x, pos.y))
    end
end

-- note that the widget does not have to be enabled to be triggered
local function do_trigger(args, quiet)
    if triggered_screen_has_lock() then
        dfhack.printerr(('cannot trigger widget; widget "%s" is already active')
                        :format(active_triggered_widget))
        return
    end
    do_by_names_or_numbers(args[1], function(name, db_entry)
        local widget = db_entry.widget
        if widget.overlay_trigger then
            register_trigger_lock_screen(widget:overlay_trigger(), name)
            if not quiet then
                print(('triggered widget %s'):format(name))
            end
        end
    end)
end

local command_fns = {
    enable=do_enable,
    disable=do_disable,
    list=do_list,
    position=do_position,
    trigger=do_trigger,
}

local HELP_ARGS = utils.invert{'help', '--help', '-h'}

function overlay_command(args, quiet)
    local command = table.remove(args, 1) or 'help'
    if HELP_ARGS[command] or not command_fns[command] then return false end
    command_fns[command](args, quiet)
    return true
end

-- ---------------- --
-- event management --
-- ---------------- --

local function detect_frame_change(widget, fn)
    local frame = widget.frame
    local w, h = frame.w, frame.h
    local ret = fn()
    if w ~= frame.w or h ~= frame.h then
        widget:updateLayout()
    end
    return ret
end

local function get_next_onupdate_timestamp(now_ms, widget)
    local freq_s = widget.overlay_onupdate_max_freq_seconds
    if freq_s == 0 then
        return now_ms
    end
    local freq_ms = math.floor(freq_s * 1000)
    local jitter = math.random(0, freq_ms // 8) -- up to ~12% jitter
    return now_ms + freq_ms - jitter
end

-- reduces the next call by a small random amount to introduce jitter into the
-- widget processing timings
local function do_update(name, db_entry, now_ms, vs)
    if db_entry.next_update_ms > now_ms then return end
    local w = db_entry.widget
    db_entry.next_update_ms = get_next_onupdate_timestamp(now_ms, w)
    if detect_frame_change(w, function() return w:overlay_onupdate(vs) end) then
        if register_trigger_lock_screen(w:overlay_trigger(), name) then
            return true
        end
    end
end

function update_hotspot_widgets()
    if triggered_screen_has_lock() then return end
    local now_ms = dfhack.getTickCount()
    for name,db_entry in pairs(active_hotspot_widgets) do
        if do_update(name, db_entry, now_ms) then return end
    end
end

local function _update_viewscreen_widgets(vs_name, vs, now_ms)
    local vs_widgets = active_viewscreen_widgets[vs_name]
    if not vs_widgets then return end
    now_ms = now_ms or dfhack.getTickCount()
    for name,db_entry in pairs(vs_widgets) do
        if do_update(name, db_entry, now_ms, vs) then return end
    end
    return now_ms
end

-- not subject to trigger lock since these widgets are already filtered by
-- viewscreen
function update_viewscreen_widgets(vs_name, vs)
    local now_ms = _update_viewscreen_widgets(vs_name, vs, nil)
    _update_viewscreen_widgets('all', vs, now_ms)
end

local function _feed_viewscreen_widgets(vs_name, keys)
    local vs_widgets = active_viewscreen_widgets[vs_name]
    if not vs_widgets then return false end
    for _,db_entry in pairs(vs_widgets) do
        local w = db_entry.widget
        if detect_frame_change(w, function() return w:onInput(keys) end) then
            return true
        end
    end
    return false
end

function feed_viewscreen_widgets(vs_name, keys)
    return _feed_viewscreen_widgets(vs_name, keys) or
            _feed_viewscreen_widgets('all', keys)
end

local function _render_viewscreen_widgets(vs_name, dc)
    local vs_widgets = active_viewscreen_widgets[vs_name]
    if not vs_widgets then return false end
    dc = dc or gui.Painter.new()
    for _,db_entry in pairs(vs_widgets) do
        local w = db_entry.widget
        detect_frame_change(w, function() w:render(dc) end)
    end
end

function render_viewscreen_widgets(vs_name)
    local dc = _render_viewscreen_widgets(vs_name, nil)
    _render_viewscreen_widgets('all', dc)
end

-- called when the DF window is resized
function reposition_widgets()
    local sr = get_screen_rect()
    for _,db_entry in pairs(widget_db) do
        db_entry.widget:updateLayout(sr)
    end
end

-- ------------------------------------------------- --
-- OverlayWidget (base class of all overlay widgets) --
-- ------------------------------------------------- --

OverlayWidget = defclass(OverlayWidget, widgets.Panel)
OverlayWidget.ATTRS{
    name=DEFAULT_NIL, -- this is set by the framework to the widget name
    default_pos={x=DEFAULT_X_POS, y=DEFAULT_Y_POS}, -- 1-based widget screen pos
    overlay_only=false, -- true if there is no widget to reposition
    hotspot=false, -- whether to call overlay_onupdate on all screens
    viewscreens={}, -- override with associated viewscreen or list of viewscrens
    overlay_onupdate_max_freq_seconds=5, -- throttle calls to overlay_onupdate
    always_enabled=false, -- for overlays that should never be disabled
}

function OverlayWidget:init()
    if self.overlay_onupdate_max_freq_seconds < 0 then
        error(('overlay_onupdate_max_freq_seconds must be >= 0: %s')
              :format(tostring(self.overlay_onupdate_max_freq_seconds)))
    end

    -- set defaults for frame. the widget is expected to keep these up to date
    -- when display contents change so the widget position can shift if the
    -- frame is relative to the right or bottom edges.
    self.frame = self.frame or {}
    self.frame.w = self.frame.w or 5
    self.frame.h = self.frame.h or 1
end

return _ENV
