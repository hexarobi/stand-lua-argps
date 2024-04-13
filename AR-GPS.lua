-- AR-GPS
-- by Murten with additions by McThickness and Hexarobi

local SCRIPT_VERSION = "0.3.4"

-- Auto Updater from https://github.com/hexarobi/stand-lua-auto-updater
local status, auto_updater = pcall(require, "auto-updater")
if not status then
    if not async_http.have_access() then
        util.toast("Failed to install auto-updater. Internet access is disabled. To enable automatic updates, please stop the script then uncheck the `Disable Internet Access` option.")
    else
        local auto_update_complete = nil util.toast("Installing auto-updater...", TOAST_ALL)
        async_http.init("raw.githubusercontent.com", "/hexarobi/stand-lua-auto-updater/main/auto-updater.lua",
                function(raw_result, raw_headers, raw_status_code)
                    local function parse_auto_update_result(result, headers, status_code)
                        local error_prefix = "Error downloading auto-updater: "
                        if status_code ~= 200 then util.toast(error_prefix..status_code, TOAST_ALL) return false end
                        if not result or result == "" then util.toast(error_prefix.."Found empty file.", TOAST_ALL) return false end
                        filesystem.mkdir(filesystem.scripts_dir() .. "lib")
                        local file = io.open(filesystem.scripts_dir() .. "lib\\auto-updater.lua", "wb")
                        if file == nil then util.toast(error_prefix.."Could not open file for writing.", TOAST_ALL) return false end
                        file:write(result) file:close() util.toast("Successfully installed auto-updater lib", TOAST_ALL) return true
                    end
                    auto_update_complete = parse_auto_update_result(raw_result, raw_headers, raw_status_code)
                end, function() util.toast("Error downloading auto-updater lib. Update failed to download.", TOAST_ALL) end)
        async_http.dispatch() local i = 1 while (auto_update_complete == nil and i < 40) do util.yield(250) i = i + 1 end
        if auto_update_complete == nil then error("Error downloading auto-updater lib. HTTP Request timeout") end
        auto_updater = require("auto-updater")
    end
end
if auto_updater == true then error("Invalid auto-updater lib. Please delete your Stand/Lua Scripts/lib/auto-updater.lua and try again") end

---
--- Auto Updater
---

local auto_update_config = {
    source_url="https://raw.githubusercontent.com/hexarobi/stand-lua-argps/main/AR-GPS.lua",
    script_relpath=SCRIPT_RELPATH,
}
if auto_updater == true then
    auto_updater.run_auto_update(auto_update_config)
end

---
--- Dependencies
---

util.require_natives("2944b", "g")

---
--- Config
---

local config = {
    is_enabled = true,
    marker = 2,
    marker_spacing = 2,
    line_smoothing = 0.5,
    line_z_offset = -1,
    lowering_strength = 6,
    max_nodes = 12,
    tick_handler_delay = 100,
    draw_waypoint_gps = true,
    draw_objective_gps = true,
    slot_colors = {
        [0]={r = 170, g = 0, b = 255, a = 100},
        [1]={r = 255, g = 234, b = 0, a = 100},
    },
}

local WAYPOINT_GPS_SLOT = 0
local OBJECTIVE_GPS_SLOT = 1

local user_ped = players.user_ped()
local state = {
    active_routes={}
}
local menus = {}

v3.one = v3(1, 1, 1)

---
--- Functions
---

local function get_num_active_routes()
    local count = 0
    for route_slot, is_active in state.active_routes do
        if is_active then
            count = count + 1
        end
    end
    return count
end

local function quadraticBezierCurve(p0, p1, p2, t)
    local a = (1 - t) ^ 2
    local b = 2 * (1 - t) * t
    local c = t ^ 2

    local term1 = v3(p0):mul(a)
    local term2 = v3(p1):mul(b)
    local term3 = v3(p2):mul(c)

    local result = term1:add(term2):add(term3)

    local u = 1 - t
    local term4 = v3(p1):sub(p0):mul(2 * u)
    local term5 = v3(p2):sub(p1):mul(2 * t)
    term4:add(term5)

    return result, term4
end

local function draw_arrows_between_points(point_a, point_b, route_slot)
    local dist = v3.distance(point_a, point_b)
    local count = math.floor(dist / config.marker_spacing)
    local dir = v3(point_b):sub(point_a):normalise()
    local player_pos = GET_ENTITY_COORDS(user_ped)
    local color = config.slot_colors[route_slot]

    for i = 0, count do
        local draw_pos = v3(dir):mul(i * config.marker_spacing):add(point_a)
        local dist = v3.distance(draw_pos, player_pos)
        draw_pos.z = draw_pos.z - (config.lowering_strength / dist) - config.line_z_offset
        DRAW_MARKER(config.marker, draw_pos, dir, v3(90, 0, 0), v3.one, color.r, color.g, color.b, color.a, false, false, 0, false, 0, 0, false)
    end
end

local function draw_arrows_between_points_smooth(point_a, point_b, point_c, route_slot)
    local dist = v3.distance(point_a, point_b) + v3.distance(point_b, point_c)
    local count = math.floor(dist / config.marker_spacing)
    local player_pos = GET_ENTITY_COORDS(user_ped)
    local color = config.slot_colors[route_slot]

    for i = 1, count do
        local t = 1 - i / count
        local draw_pos, dir = quadraticBezierCurve(point_a, point_b, point_c, t)

        draw_pos.z = draw_pos.z - (config.lowering_strength / v3.distance(draw_pos, player_pos)) - config.line_z_offset
        DRAW_MARKER(config.marker, draw_pos, dir, v3(90, 0, 0), v3.one, color.r, color.g, color.b, color.a, false, false, 0, false, 0, 0, false)
    end
end

local function get_corner_points(point_a, point_b, point_c)
    local b_to_a = v3(point_a):sub(point_b)
    local b_to_c = v3(point_c):sub(point_b)

    b_to_a:mul(config.line_smoothing):add(point_b)
    b_to_c:mul(config.line_smoothing):add(point_b)

    return b_to_a, b_to_c
end

local function draw_points(points, color)
    local start_point = nil
    for i = 1, #points do
        if points[i + 2] then
            local subpoint_a, subpoint_b = get_corner_points(start_point or points[i], points[i + 1], points[i + 2])
            draw_arrows_between_points(start_point or points[i], subpoint_a, color)
            draw_arrows_between_points_smooth(subpoint_a, points[i + 1], subpoint_b, color)
            start_point = subpoint_b
        elseif points[i + 1] then
            draw_arrows_between_points(start_point or points[i], points[i + 1], color)
        end
    end
end

local function get_route_clean(max_nodes, route_slot)
    local route = util.get_gps_route(route_slot)
    local result = {}
    for i, node in ipairs(route) do
        if #result >= max_nodes then break end
        if node.junction then
            goto continue
        end
        table.insert(result, v3(node.x, node.y, node.z))
        ::continue::
    end
    return result
end

local function recalculate_route(route_slot)
    local points = get_route_clean(config.max_nodes / get_num_active_routes(), route_slot)
    state.active_routes[route_slot] = points -- (#points > 0)
end

local function draw_gps_route_slot(route_slot)
    if #state.active_routes[route_slot] > 0 then
        draw_points(state.active_routes[route_slot], route_slot)
    end
end

local function recalculate_gps()
    if config.draw_waypoint_gps then
        recalculate_route(WAYPOINT_GPS_SLOT)
    end
    if config.draw_objective_gps then
        recalculate_route(OBJECTIVE_GPS_SLOT)
    end
end

local function redraw_gps()
    user_ped = players.user_ped()
    if config.draw_waypoint_gps then
        draw_gps_route_slot(WAYPOINT_GPS_SLOT)
    end
    if config.draw_objective_gps then
        draw_gps_route_slot(OBJECTIVE_GPS_SLOT)
    end
end

local function update_gps_tick()
    if state.next_tick_time == nil or util.current_time_millis() > state.next_tick_time then
        state.next_tick_time = util.current_time_millis() + config.tick_handler_delay
        recalculate_gps()
    end
    redraw_gps()
end

---
--- Menus
---

menu.my_root():toggle("Enable Waypoint", {"arggpswaypoint"}, "draws arrows along the gps route", function(value)
    config.draw_waypoint_gps = value
end, config.draw_waypoint_gps)

menu.my_root():toggle("Enable Objective", {"arggpsobjective"}, "draws arrows along the gps route", function(value)
    config.draw_objective_gps = value
end, config.draw_objective_gps)


menus.settings = menu.my_root():list("Settings")
menus.settings:slider("max nodes", {"argpsmaxnodes"}, "Higher numbers may cause lag or stutters", 5, 25, config.max_nodes, 1, function(value)
    config.max_nodes = value
end)
menus.settings:slider("Marker Model", {"argpsmarkerlook"}, "Changes what asset is used for path markers", 1, 44, config.marker, 1, function(value)
    config.marker = value
end)
menus.settings:slider("Marker Spacing", {"argpsmarkerspace"}, "Spacing between each marker. Can increase the distance markers will render to.", 1, 20, config.marker_spacing, 1, function(value)
    config.marker_spacing = value
end)

menus.about = menu.my_root():list("About AR-GPS")
menus.about:divider(SCRIPT_NAME)
menus.about:readonly("Version", SCRIPT_VERSION)
menus.about:hyperlink("Github Source", "https://github.com/hexarobi/stand-lua-hexascript", "View source files on Github")

---
--- Tick Handlers
---

util.create_tick_handler(update_gps_tick)
