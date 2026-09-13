--[[
===============================================================================
LockOnFovChanger v1.2.03
===============================================================================

Adjusts the Lock-On camera in The Blood of Dawnwalker.
Edit LockOnFovChanger.ini, then restart the game.

INI (LockOnFovChanger.ini)
--------------------------
FOVEnabled=true|false       Lock-On FOV on/off
LockOnFOV=100               FOV while locked (normal gameplay is 90, value range 1-179)
EnemyOffset=0               Horizontal aim offset (-180=center, 120=game default)
LockOnOffsetZ=30            Camera pitch / height while locked (0=game default)
EnableLog=false             Write a debug log file (false recommended)

Console commands (type in game console)
---------------------------------------
clo ?                       List commands
clo ver                     Show version

clo fov disable             Turn Lock-On FOV off
clo fov enable              Turn Lock-On FOV on
clo fov value <1-179>       Set Lock-On FOV

clo offset <number>         Set EnemyOffset (horizontal aim)
clo pitch <number>          Set LockOnOffsetZ (0=game default)

clo fovstatus               Show current settings and lock state
clo diagstatus              Show debug info

Author: LukaZou
]]
local MOD_NAME = "LockOnFovChanger_v1.2.03"
local SCRIPT_VERSION = "1.2.03"

local HARD_LOCK_FUNCTION = "/Script/DogwoodCombat.PlayerCombatComponent:SetHardLock"
local CAMERA_MODE_CLASS = "RebelCameraMode"
local COMBAT_CAMERA_MODE_CLASS = "/Script/DogwoodCombat.CombatCameraMode"

local CAMERA_TYPE_NONE = 0
local CAMERA_TYPE_DEFAULT = 1

local POLL_MS = 100
local CACHE_WARMUP_MS = 1000

local ENABLE_LOG_DEFAULT = false
local ENABLE_INPUT_DIAGNOSTIC = false

-- UE4SS UEHelpers provides the local PlayerController without a full object scan.
local UEHelpers = require("UEHelpers")
local GetPlayerController = UEHelpers.GetPlayerController

local COMBAT_OFFSET_DEFAULT_Y = 120.0
local COMBAT_OFFSET_FIX_Y = 0.0

local CONFIG_DEFAULTS = {
    FOVEnabled = true,
    LockOnFOV = 110.0,
    LockOnOffsetZ = 0.0,
    EnemyOffset = COMBAT_OFFSET_DEFAULT_Y,
    EnableLog = ENABLE_LOG_DEFAULT,
}

local config = {
    FOVEnabled = CONFIG_DEFAULTS.FOVEnabled,
    LockOnFOV = CONFIG_DEFAULTS.LockOnFOV,
    LockOnOffsetZ = CONFIG_DEFAULTS.LockOnOffsetZ,
    EnemyOffset = CONFIG_DEFAULTS.EnemyOffset,
    EnableLog = CONFIG_DEFAULTS.EnableLog,
}

local function parse_bool(value, fallback)
    if value == nil then
        return fallback
    end

    value = string.lower(tostring(value):gsub("%s+", ""))

    if value == "true" or value == "1" or value == "yes" or value == "on" then
        return true
    end

    if value == "false" or value == "0" or value == "no" or value == "off" then
        return false
    end

    return fallback
end

local function get_script_directory()
    local source = debug.getinfo(1, "S").source

    if type(source) ~= "string" then
        return nil
    end

    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end

    return source:match("^(.*)[\\/]([^\\/]+)$")
end

local script_directory = get_script_directory()

local function load_external_config()
    local candidates = {}

    if script_directory ~= nil and script_directory ~= "" then
        table.insert(candidates, script_directory .. "\\LockOnFovChanger.ini")
        table.insert(candidates, script_directory .. "/LockOnFovChanger.ini")
    end

    table.insert(candidates, "LockOnFovChanger.ini")

    local file = nil

    for _, path in ipairs(candidates) do
        local ok, handle = pcall(io.open, path, "r")

        if ok and handle ~= nil then
            file = handle
            break
        end
    end

    if file == nil then
        return false
    end

    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")

        if line ~= "" and not line:match("^[;#]") then
            local key, value = line:match("^([^=]+)=(.*)$")

            if key ~= nil then
                key = key:gsub("^%s+", ""):gsub("%s+$", "")
                value = value:gsub("^%s+", ""):gsub("%s+$", "")

                if key == "FOVEnabled" then
                    config.FOVEnabled = parse_bool(value, config.FOVEnabled)
                elseif key == "LockOnFOV" then
                    local number = tonumber(value)
                    if number ~= nil and number >= 1 and number <= 179 then
                        config.LockOnFOV = number
                    end
                elseif key == "LockOnOffsetZ" then
                    local number = tonumber(value)
                    if number ~= nil then
                        config.LockOnOffsetZ = number
                    end
                elseif key == "EnemyOffset" then
                    local number = tonumber(value)
                    if number ~= nil then
                        config.EnemyOffset = number
                    end
                elseif key == "CameraOffsetFix" then
                    if parse_bool(value, false) then
                        config.EnemyOffset = COMBAT_OFFSET_FIX_Y
                    end
                elseif key == "EnableLog" then
                    config.EnableLog = parse_bool(value, config.EnableLog)
                end
            end
        end
    end

    file:close()
    return true
end

load_external_config()

local log_path = nil

local function build_log_path()
    if script_directory == nil or script_directory == "" then
        return "LockOnFovChanger_v" .. SCRIPT_VERSION .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
    end

    return script_directory .. "\\LockOnFovChanger_v" .. SCRIPT_VERSION .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
end

if config.EnableLog then
    log_path = build_log_path()
end

local function append_log(message)
    if not config.EnableLog or log_path == nil then
        return
    end

    local ok, file = pcall(io.open, log_path, "a")

    if ok and file ~= nil then
        pcall(function()
            file:write(
                "[" ..
                os.date("%Y-%m-%d %H:%M:%S") ..
                "] " ..
                tostring(message) ..
                "\n"
            )
            file:flush()
            file:close()
        end)
    end
end

if config.EnableLog then
    local ok, file = pcall(io.open, log_path, "w")
    if ok and file ~= nil then
        file:write(
            "===== LockOnFovChanger " ..
            SCRIPT_VERSION ..
            " =====\n"
        )
        file:write(
            "Loaded: " ..
            os.date("%Y-%m-%d %H:%M:%S") ..
            "\n"
        )
        file:write(
            "FOVEnabled=" ..
            tostring(config.FOVEnabled) ..
            " | LockOnFOV=" ..
            tostring(config.LockOnFOV) ..
            " | EnemyOffset=" ..
            tostring(config.EnemyOffset) ..
            " | LockOnOffsetZ=" ..
            tostring(config.LockOnOffsetZ) ..
            " | EnableLog=" ..
            tostring(config.EnableLog) ..
            "\n"
        )
        file:write(
            "LogFile=" ..
            tostring(log_path) ..
            "\n\n"
        )
        file:close()
    end
end

local function valid_object(object)
    if object == nil then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)

    return ok and result == true
end

local function hook_object(value)
    if value == nil then
        return nil
    end

    local ok, object = pcall(function()
        return value:get()
    end)

    if ok then
        return object
    end

    return value
end

local function get_field(owner, field_name)
    if owner == nil then
        return nil
    end

    local value = nil

    local ok = pcall(function()
        value = owner[field_name]
    end)

    if ok then
        return value
    end

    return nil
end

local function get_unwrapped_field(owner, field_name)
    return hook_object(get_field(hook_object(owner), field_name))
end

local function set_field(owner, field_name, value)
    if owner == nil then
        return false
    end

    return pcall(function()
        owner[field_name] = value
    end)
end

local function safe_full_name(object)
    if object == nil then
        return "<nil>"
    end

    local ok, value = pcall(function()
        return object:GetFullName()
    end)

    if ok and value ~= nil then
        return tostring(value)
    end

    return "<unavailable>"
end

local function safe_class_name(object)
    if object == nil then
        return "<nil>"
    end

    local ok, value = pcall(function()
        local class = object:GetClass()
        if class == nil then
            return "<no-class>"
        end
        return class:GetFullName()
    end)

    if ok and value ~= nil then
        return tostring(value)
    end

    return "<unavailable>"
end

local function is_ability_mode(mode)
    if mode == nil then
        return false
    end

    local class_name = safe_class_name(mode)

    local lower = string.lower(class_name)

    -- Cover both naming patterns used by the game:
    --   AA_CameraMode_*
    --   CameraMode_AA_* (e.g. BP_CameraMode_AA_Charge_Sword_C)
    return string.find(lower, "aa_cameramode", 1, true) ~= nil
        or string.find(lower, "cameramode_aa_", 1, true) ~= nil
end

local function value_to_string(object, field_name)
    local value = get_field(object, field_name)

    if value == nil then
        return "<unavailable>"
    end

    return tostring(value)
end

-- Combat-state observer. CurrentCombatMode is sampled at low frequency and only
-- value changes are logged. It is used only for the existing Combat Exit cleanup.
local COMBAT_COMPONENT_CLASS = "PlayerCombatComponent"
local COMBAT_STATE_POLL_MS = 500
local COMBAT_EXIT_CLEANUP_DELAY_MS = 150
local combat_component = nil
local combat_state_last = nil
local combat_mode_last = nil
local last_combat_state_number = nil
local combat_component_name_logged = false
local combat_state_poll_generation = 0
local combat_state_poll_active = false

-- World/load lifecycle generation. Any delayed callback created before a map
-- transition becomes invalid after the generation changes.
local runtime_generation = 0

-- Forward declaration: Combat exit handling can invoke the normal Lock-Off
-- restore path after the function is defined below.
local apply_lock_fov

local saved_modes = {}
local saved_camera_detached = {}
local tracked_combat = nil
local tracked_camera = nil
local previous_camera_type = nil
local fov_applied = false
local lock_active = false

-- CameraModeStack is used only to protect the camera during temporary
-- combat/attack camera modes. It never controls Lock-On session lifecycle.
local baseline_stack_depth = nil
local last_stack_depth = nil
local stack_poll_generation = 0
local stack_poll_active = false
local get_camera_stack_depth
local set_stack_camera_type
local start_stack_poll
local stop_stack_poll

-- Lock-On trigger diagnostics. These counters/logs are enabled only when
-- EnableLog=true and are intended to reveal duplicate/missing SetHardLock events.
local lock_trigger_count = 0
local lock_on_trigger_count = 0
local lock_off_trigger_count = 0
local last_lock_trigger = nil

local function baseline_fov(mode)
    local current = get_field(mode, "DefaultFieldOfView")

    if type(current) == "number" and current ~= config.LockOnFOV then
        return current
    end

    local class = nil
    pcall(function()
        class = mode:GetClass()
    end)

    if class ~= nil then
        local cdo = nil
        pcall(function()
            cdo = class:GetCDO()
        end)

        if valid_object(cdo) then
            local inherited = get_field(cdo, "DefaultFieldOfView")
            if type(inherited) == "number" then
                return inherited
            end
        end
    end

    return current
end

local function cache_mode(mode)
    if not valid_object(mode) or is_ability_mode(mode) then
        return
    end

    local address = nil
    pcall(function()
        address = mode:GetAddress()
    end)

    if address == nil then
        return
    end

    if saved_modes[address] == nil or
        not valid_object(saved_modes[address].mode) then
        saved_modes[address] = {
            mode = mode,
            fov = baseline_fov(mode),
        }
    else
        saved_modes[address].mode = mode
    end

end

local function rebuild_mode_cache()
    if type(FindAllOf) ~= "function" then
        return false, 0
    end

    local ok, modes = pcall(function()
        return FindAllOf(CAMERA_MODE_CLASS)
    end)

    if not ok or modes == nil then
        return false, 0
    end

    local count = 0

    for _, mode in ipairs(modes) do
        if valid_object(mode) and not is_ability_mode(mode) then
            cache_mode(mode)
            count = count + 1
        end
    end

    return count > 0, count
end

local function write_locked_fov()
    local live = 0
    local dead = {}

    for address, saved in pairs(saved_modes) do
        local mode = saved.mode

        if valid_object(mode) and not is_ability_mode(mode) then
            if set_field(mode, "DefaultFieldOfView", config.LockOnFOV) then
                live = live + 1
            end
        else
            table.insert(dead, address)
        end
    end

    for _, address in ipairs(dead) do
        saved_modes[address] = nil
    end

    return live > 0
end

local function restore_mode_defaults()
    for address, saved in pairs(saved_modes) do
        if valid_object(saved.mode) and saved.fov ~= nil then
            pcall(function()
                saved.mode.DefaultFieldOfView = saved.fov
            end)
        else
            saved_modes[address] = nil
        end
    end
end

local function readable_runtime_value(value)
    if value == nil then
        return "<nil>"
    end

    if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
        return tostring(value)
    end

    local ok, full_name = pcall(function()
        return value:GetFullName()
    end)

    if ok and full_name ~= nil then
        return tostring(full_name)
    end

    local ok_name, name = pcall(function()
        return value:GetName()
    end)

    if ok_name and name ~= nil then
        return tostring(name)
    end

    return tostring(value)
end

local function object_address(object)
    if object == nil then
        return nil
    end

    local ok, address = pcall(function()
        return object:GetAddress()
    end)

    if ok and address ~= nil then
        return tostring(address)
    end

    return nil
end

local function find_combat_component()
    if valid_object(combat_component) then
        return combat_component
    end

    if tracked_combat ~= nil and valid_object(tracked_combat) then
        combat_component = tracked_combat
        return combat_component
    end

    if type(FindAllOf) ~= "function" then
        return nil
    end

    local ok, objects = pcall(function()
        return FindAllOf(COMBAT_COMPONENT_CLASS)
    end)

    if not ok or objects == nil then
        return nil
    end

    for _, object in ipairs(objects) do
        if valid_object(object) then
            combat_component = object
            return object
        end
    end

    return nil
end

local function set_combat_component(component, reason)
    if not valid_object(component) then
        return false
    end

    local new_address = object_address(component)
    local old_address = object_address(combat_component)

    if combat_component ~= nil and new_address ~= nil and old_address == new_address then
        return false
    end

    local old_name = combat_component and safe_full_name(combat_component) or "<nil>"
    combat_component = component

    append_log(
        "COMBAT COMPONENT CHANGED | Reason=" .. tostring(reason) ..
        " | Old=" .. old_name ..
        " | New=" .. safe_full_name(component) ..
        " | Address=" .. tostring(new_address)
    )

    combat_component_name_logged = true
    return true
end

local function sample_combat_state()
    local component = find_combat_component()
    if component == nil then
        return
    end

    if not combat_component_name_logged then
        append_log(
            "COMBAT COMPONENT | " .. safe_full_name(component) ..
            " | Address=" .. tostring(object_address(component))
        )
        combat_component_name_logged = true
    end

    local state_text = readable_runtime_value(get_field(component, "CurrentState"))
    last_combat_state_number = tonumber(state_text)
    local mode_value = get_field(component, "CurrentCombatMode")
    local mode_text = readable_runtime_value(mode_value)
    local mode_number = tonumber(mode_value)

    local previous_mode_number = combat_mode_last

    if previous_mode_number ~= nil and
        previous_mode_number ~= 0 and
        mode_number == 0 then

        append_log(
            "COMBAT EXIT DETECTED | PreviousCombatMode=" ..
            tostring(previous_mode_number) ..
            " | CurrentCombatMode=0" ..
            " | LockActive=" .. tostring(lock_active) ..
            " | FOVApplied=" .. tostring(fov_applied) ..
            " | SavedCameraType=" .. tostring(previous_camera_type)
        )

        if lock_active then
            local cleanup_generation = runtime_generation
            local combat_ref = component

            append_log(
                "COMBAT EXIT CLEANUP | Scheduled=true" ..
                " | DelayMs=" .. tostring(COMBAT_EXIT_CLEANUP_DELAY_MS)
            )

            local function run_combat_exit_cleanup()
                if cleanup_generation ~= runtime_generation then
                    append_log("COMBAT EXIT CLEANUP | Skipped=StaleGeneration")
                    return
                end
                if not lock_active then
                    append_log("COMBAT EXIT CLEANUP | Skipped=LockAlreadyOff")
                    return
                end

                local ok, err = pcall(function()
                    apply_lock_fov(combat_ref, false)
                end)

                append_log(
                    "COMBAT EXIT CLEANUP | PCallOK=" .. tostring(ok) ..
                    " | Error=" .. tostring(err) ..
                    " | LockActiveAfter=" .. tostring(lock_active) ..
                    " | FOVAppliedAfter=" .. tostring(fov_applied)
                )
            end

            if type(ExecuteWithDelay) == "function" then
                ExecuteWithDelay(COMBAT_EXIT_CLEANUP_DELAY_MS, function()
                    if type(ExecuteInGameThread) == "function" then
                        ExecuteInGameThread(run_combat_exit_cleanup)
                    else
                        run_combat_exit_cleanup()
                    end
                end)
            elseif type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(run_combat_exit_cleanup)
            else
                run_combat_exit_cleanup()
            end
        else
            append_log(
                "COMBAT EXIT CLEANUP | No active Lock-On session"
            )
        end
    end

    if combat_state_last == nil or state_text ~= combat_state_last then
        append_log(
            "COMBAT STATE CHANGED | CurrentState=" .. state_text ..
            " | CurrentCombatMode=" .. mode_text
        )
        combat_state_last = state_text
    elseif mode_number ~= nil and
        (combat_mode_last == nil or mode_number ~= combat_mode_last) then
        append_log(
            "COMBAT MODE CHANGED | CurrentState=" .. state_text ..
            " | CurrentCombatMode=" .. mode_text
        )
    end

    if mode_number ~= nil then
        combat_mode_last = mode_number
    end
end

local function combat_state_poll()
    local generation = combat_state_poll_generation

    if type(ExecuteInGameThread) ~= "function" or type(ExecuteWithDelay) ~= "function" then
        append_log("Combat diagnostics ERROR: timer API unavailable.")
        return
    end

    ExecuteInGameThread(function()
        if generation ~= combat_state_poll_generation or not combat_state_poll_active then
            return
        end
        sample_combat_state()
    end)

    ExecuteWithDelay(COMBAT_STATE_POLL_MS, function()
        if generation == combat_state_poll_generation and combat_state_poll_active then
            combat_state_poll()
        end
    end)
end

local function start_combat_state_poll()
    if combat_state_poll_active then
        return
    end
    combat_state_poll_generation = combat_state_poll_generation + 1
    combat_state_poll_active = true
    combat_state_last = nil
    combat_mode_last = nil
    last_combat_state_number = nil
    combat_component_name_logged = false
    combat_state_poll()
end

local function stop_combat_state_poll()
    combat_state_poll_generation = combat_state_poll_generation + 1
    combat_state_poll_active = false
    combat_state_last = nil
    combat_mode_last = nil
    last_combat_state_number = nil
    combat_component_name_logged = false
end

-- Lightweight controller-input diagnostic observer.
-- It is intentionally diagnostic-only: it never changes input, camera, FOV, or Lock-On state.
-- Polling is cached and edge-triggered so normal gameplay produces no log spam.
local INPUT_POLL_MS = 100
local INPUT_START_DELAY_MS = 1500

local input_observer_generation = 0
local input_observer_active = false
local input_controller = nil
local input_keys = nil
local input_key_state = {}
local input_combo_state = false
local input_controller_retry_logged = false
local input_init_failed = false
local input_controller_retry_cooldown = 0

local INPUT_KEY_DEFINITIONS = {
    { id = "LB",      key_name = "Gamepad_LeftShoulder" },
    { id = "RB",      key_name = "Gamepad_RightShoulder" },
    { id = "Y",       key_name = "Gamepad_FaceButton_Top" },
    { id = "R3",      key_name = "Gamepad_RightThumbstick" },
    { id = "DPadLeft",key_name = "Gamepad_DPad_Left" },
    { id = "DPadUp",  key_name = "Gamepad_DPad_Up" },
}

local function create_fkey(key_name)
    local ok, key = pcall(function()
        local value = FKey()
        value.KeyName = key_name
        return value
    end)

    if ok and key ~= nil then
        return key
    end

    return nil
end

local function initialize_input_keys()
    if input_keys ~= nil then
        return true
    end

    if input_init_failed then
        return false
    end

    input_keys = {}

    for _, definition in ipairs(INPUT_KEY_DEFINITIONS) do
        local key = create_fkey(definition.key_name)
        if key == nil then
            input_keys = nil
            input_init_failed = true
            append_log(
                "INPUT OBSERVER ERROR | Failed to construct FKey | " ..
                definition.id .. "=" .. definition.key_name
            )
            return false
        end

        input_keys[definition.id] = {
            key = key,
            key_name = definition.key_name,
        }
        input_key_state[definition.id] = false
    end

    append_log(
        "INPUT OBSERVER READY | Keys=LB,RB,Y,R3,DPadLeft,DPadUp | PollMs=" ..
        tostring(INPUT_POLL_MS)
    )

    return true
end

local function get_input_controller()
    if valid_object(input_controller) then
        return input_controller
    end

    if input_controller_retry_cooldown > 0 then
        input_controller_retry_cooldown = input_controller_retry_cooldown - 1
        return nil
    end

    local ok, controller = pcall(function()
        return GetPlayerController()
    end)

    if ok and valid_object(controller) then
        input_controller = controller
        input_controller_retry_cooldown = 0

        if input_controller_retry_logged then
            append_log(
                "INPUT CONTROLLER ACQUIRED | " ..
                safe_full_name(input_controller)
            )
            input_controller_retry_logged = false
        end

        return input_controller
    end

    input_controller_retry_cooldown = math.max(1, math.floor(1000 / INPUT_POLL_MS))

    if not input_controller_retry_logged then
        append_log("INPUT CONTROLLER UNAVAILABLE | observer will retry")
        input_controller_retry_logged = true
    end

    return nil
end

local function unwrap_runtime_value(value)
    if value == nil then
        return nil
    end

    local ok, unwrapped = pcall(function()
        return value:get()
    end)

    if ok then
        return unwrapped
    end

    return value
end

local function read_input_key(controller, key)
    if controller == nil or key == nil then
        return false
    end

    local ok, result = pcall(function()
        return controller:IsInputKeyDown(key)
    end)

    if not ok then
        return false
    end

    local down = unwrap_runtime_value(result)
    return down == true
end

local function sample_controller_input()
    if not initialize_input_keys() then
        return
    end

    local controller = get_input_controller()
    if controller == nil then
        return
    end

    for id, entry in pairs(input_keys) do
        local down = read_input_key(controller, entry.key)
        local previous = input_key_state[id] == true

        if down ~= previous then
            append_log(
                "INPUT " .. id .. " " .. (down and "PRESSED" or "RELEASED")
            )
            input_key_state[id] = down
        end
    end

    local lb_down = input_key_state.LB == true
    local rb_down = input_key_state.RB == true
    local combo_down = lb_down and rb_down

    if combo_down ~= input_combo_state then
        append_log(
            "INPUT SPECIAL COMBO LB+RB " ..
            (combo_down and "PRESSED" or "RELEASED")
        )
        input_combo_state = combo_down
    end
end

local function input_observer_poll()
    local generation = input_observer_generation

    if type(ExecuteInGameThread) ~= "function" or
        type(ExecuteWithDelay) ~= "function" then
        append_log("Input observer ERROR: timer API unavailable.")
        return
    end

    ExecuteInGameThread(function()
        if generation ~= input_observer_generation or not input_observer_active then
            return
        end

        sample_controller_input()
    end)

    ExecuteWithDelay(INPUT_POLL_MS, function()
        if generation == input_observer_generation and input_observer_active then
            input_observer_poll()
        end
    end)
end

local function start_input_observer()
    if input_observer_active then
        return
    end

    if type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        append_log("Input observer ERROR: timer API unavailable.")
        return
    end

    input_observer_generation = input_observer_generation + 1
    input_observer_active = true
    input_controller = nil
    input_keys = nil
    input_key_state = {}
    input_combo_state = false
    input_initialized = false
    input_controller_retry_logged = false

    local input_start_generation = runtime_generation

    ExecuteWithDelay(INPUT_START_DELAY_MS, function()
        if input_start_generation ~= runtime_generation or
            not input_observer_active then
            return
        end

        append_log(
            "INPUT OBSERVER START | DelayMs=" ..
            tostring(INPUT_START_DELAY_MS) ..
            " | PollMs=" .. tostring(INPUT_POLL_MS)
        )
        input_observer_poll()
    end)
end

local function camera_from_combat(combat)
    if combat == nil then
        return nil
    end

    local owner = nil
    pcall(function()
        owner = combat:GetOwner()
    end)

    if owner == nil then
        return nil
    end

    local camera = get_field(owner, "FollowCamera")

    if valid_object(camera) then
        return camera
    end

    return nil
end

local function restore_camera_type(camera, restore_type)
    if not valid_object(camera) then
        return false
    end

    if restore_type == nil then
        return false
    end

    local ok = pcall(function()
        camera:SetCameraType(restore_type)
    end)

    local readback = "<unavailable>"
    pcall(function()
        readback = tostring(camera:GetCameraType())
    end)

    append_log(
        "Unlock CameraType restore | target=" .. tostring(restore_type) ..
        " | success=" .. tostring(ok) ..
        " | readback=" .. tostring(readback)
    )

    return ok
end

-- Offset Y/Z require struct write-back on CameraLocationOffsetDuringTargeting.
local combat_offset_y = {
    active = false,
    modes = {},
}

local function write_active_targeting_offset_y(mode, offset, target_y)
    if not valid_object(mode) or offset == nil or target_y == nil then
        return false, false, nil
    end

    local nested_ok = pcall(function()
        offset.Y = target_y
    end)
    local struct_ok = pcall(function()
        mode.CameraLocationOffsetDuringTargeting = offset
    end)
    local fresh_y = tonumber(get_unwrapped_field(
        get_field(mode, "CameraLocationOffsetDuringTargeting"),
        "Y"
    ))
    return nested_ok, struct_ok, fresh_y
end

local function apply_offset_y_to_mode(mode, reason, index)
    local target_y = tonumber(config.EnemyOffset) or COMBAT_OFFSET_DEFAULT_Y
    if not valid_object(mode) or is_ability_mode(mode) then
        return false
    end

    local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
    if offset == nil then
        return false
    end

    local before_y = tonumber(get_unwrapped_field(offset, "Y"))
    if before_y == nil then
        return false
    end

    local address = object_address(mode)
    if address == nil then
        return false
    end

    if combat_offset_y.modes[address] == nil then
        combat_offset_y.modes[address] = { mode = mode, baseline_y = before_y }
    else
        combat_offset_y.modes[address].mode = mode
    end

    if math.abs(before_y - target_y) < 0.001 then
        return true
    end

    local nested_ok, struct_ok, fresh_y = write_active_targeting_offset_y(mode, offset, target_y)
    local readback_ok = fresh_y ~= nil and math.abs(fresh_y - target_y) < 0.001

    append_log(
        "OFFSET Y WRITE" ..
        " | Reason=" .. tostring(reason) ..
        " | Index=" .. tostring(index) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | BeforeY=" .. tostring(before_y) ..
        " | TargetY=" .. tostring(target_y) ..
        " | FreshAfterY=" .. tostring(fresh_y) ..
        " | Nested=" .. tostring(nested_ok) ..
        " | Struct=" .. tostring(struct_ok) ..
        " | Readback=" .. tostring(readback_ok)
    )

    return nested_ok and struct_ok and readback_ok
end

local function apply_combat_offset_y(reason)
    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    if not valid_object(camera) then
        append_log("OFFSET Y APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        append_log("OFFSET Y APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraModeStackUnavailable=true")
        return 0
    end

    local depth = 0
    local depth_ok = pcall(function()
        depth = stack:GetArrayNum()
    end)
    if not depth_ok or type(depth) ~= "number" or depth <= 0 then
        return 0
    end

    local changed = 0
    for index = 1, depth do
        local entry = nil
        local entry_ok = pcall(function()
            entry = stack[index]
        end)

        if entry_ok and entry ~= nil then
            local mode = nil
            pcall(function()
                mode = entry.CameraMode
            end)

            if apply_offset_y_to_mode(mode, reason, index) then
                changed = changed + 1
            end
        end
    end

    combat_offset_y.active = changed > 0 or next(combat_offset_y.modes) ~= nil
    append_log(
        "OFFSET Y APPLY | Reason=" .. tostring(reason) ..
        " | Changed=" .. tostring(changed) ..
        " | Active=" .. tostring(combat_offset_y.active)
    )
    return changed
end

local function restore_combat_offset_y(reason)
    if not combat_offset_y.active and next(combat_offset_y.modes) == nil then
        return 0
    end

    local restored = 0
    local skipped = 0
    for address, saved in pairs(combat_offset_y.modes) do
        local mode = saved.mode
        local baseline = saved.baseline_y
        if not valid_object(mode) or baseline == nil then
            skipped = skipped + 1
            append_log(
                "OFFSET Y RESTORE SKIP | Reason=" .. tostring(reason) ..
                " | StaleMode=true" ..
                " | Address=" .. tostring(address)
            )
        else
            local restore_ok, fresh_y = pcall(function()
                local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
                if offset == nil then
                    return nil
                end
                local _, _, value = write_active_targeting_offset_y(mode, offset, baseline)
                return value
            end)
            if restore_ok and fresh_y ~= nil and math.abs(fresh_y - baseline) < 0.001 then
                restored = restored + 1
            end
            append_log(
                (restore_ok and "OFFSET Y RESTORE" or "OFFSET Y RESTORE FAILED") ..
                " | Reason=" .. tostring(reason) ..
                " | Mode=" .. safe_full_name(mode) ..
                " | BaselineY=" .. tostring(baseline) ..
                " | FreshAfterY=" .. tostring(fresh_y) ..
                " | PCallOK=" .. tostring(restore_ok)
            )
        end
        combat_offset_y.modes[address] = nil
    end
    if skipped > 0 then
        append_log(
            "OFFSET Y RESTORE SUMMARY | Reason=" .. tostring(reason) ..
            " | Restored=" .. tostring(restored) ..
            " | SkippedStale=" .. tostring(skipped)
        )
    end

    combat_offset_y.active = false
    return restored
end

local combat_offset_z = {
    active = false,
    modes = {},
}

local function write_active_targeting_offset_z(mode, offset, target_z)
    if not valid_object(mode) or offset == nil or target_z == nil then
        return false, false, nil
    end

    local nested_ok = pcall(function()
        offset.Z = target_z
    end)
    local struct_ok = pcall(function()
        mode.CameraLocationOffsetDuringTargeting = offset
    end)
    local fresh_z = tonumber(get_unwrapped_field(
        get_field(mode, "CameraLocationOffsetDuringTargeting"),
        "Z"
    ))
    return nested_ok, struct_ok, fresh_z
end

local function apply_offset_z_to_mode(mode, reason, index)
    local target_z = tonumber(config.LockOnOffsetZ) or 0
    if target_z <= 0.001 or not valid_object(mode) or is_ability_mode(mode) then
        return false
    end

    local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
    if offset == nil then
        return false
    end

    local before_z = tonumber(get_unwrapped_field(offset, "Z"))
    if before_z == nil then
        return false
    end

    local address = object_address(mode)
    if address == nil then
        return false
    end

    if combat_offset_z.modes[address] == nil then
        combat_offset_z.modes[address] = { mode = mode, baseline_z = before_z }
    else
        combat_offset_z.modes[address].mode = mode
    end

    if math.abs(before_z - target_z) < 0.001 then
        return true
    end

    local nested_ok, struct_ok, fresh_z = write_active_targeting_offset_z(mode, offset, target_z)
    local readback_ok = fresh_z ~= nil and math.abs(fresh_z - target_z) < 0.001

    append_log(
        "OFFSET Z WRITE" ..
        " | Reason=" .. tostring(reason) ..
        " | Index=" .. tostring(index) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | BeforeZ=" .. tostring(before_z) ..
        " | TargetZ=" .. tostring(target_z) ..
        " | FreshAfterZ=" .. tostring(fresh_z) ..
        " | Nested=" .. tostring(nested_ok) ..
        " | Struct=" .. tostring(struct_ok) ..
        " | Readback=" .. tostring(readback_ok)
    )

    return nested_ok and struct_ok and readback_ok
end

local function apply_combat_offset_z(reason)
    local target_z = tonumber(config.LockOnOffsetZ) or 0
    if target_z <= 0.001 then
        return 0
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    if not valid_object(camera) then
        append_log("OFFSET Z APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        append_log("OFFSET Z APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraModeStackUnavailable=true")
        return 0
    end

    local depth = 0
    local depth_ok = pcall(function()
        depth = stack:GetArrayNum()
    end)
    if not depth_ok or type(depth) ~= "number" or depth <= 0 then
        return 0
    end

    local changed = 0
    for index = 1, depth do
        local entry = nil
        local entry_ok = pcall(function()
            entry = stack[index]
        end)

        if entry_ok and entry ~= nil then
            local mode = nil
            pcall(function()
                mode = entry.CameraMode
            end)

            if apply_offset_z_to_mode(mode, reason, index) then
                changed = changed + 1
            end
        end
    end

    combat_offset_z.active = changed > 0 or next(combat_offset_z.modes) ~= nil
    append_log(
        "OFFSET Z APPLY | Reason=" .. tostring(reason) ..
        " | Changed=" .. tostring(changed) ..
        " | Active=" .. tostring(combat_offset_z.active)
    )
    return changed
end

local function restore_combat_offset_z(reason)
    if not combat_offset_z.active and next(combat_offset_z.modes) == nil then
        return 0
    end

    local restored = 0
    local skipped = 0
    for address, saved in pairs(combat_offset_z.modes) do
        local mode = saved.mode
        local baseline = saved.baseline_z
        if not valid_object(mode) or baseline == nil then
            skipped = skipped + 1
            append_log(
                "OFFSET Z RESTORE SKIP | Reason=" .. tostring(reason) ..
                " | StaleMode=true" ..
                " | Address=" .. tostring(address)
            )
        else
            local restore_ok, fresh_z = pcall(function()
                local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
                if offset == nil then
                    return nil
                end
                local _, _, value = write_active_targeting_offset_z(mode, offset, baseline)
                return value
            end)
            if restore_ok and fresh_z ~= nil and math.abs(fresh_z - baseline) < 0.001 then
                restored = restored + 1
            end
            append_log(
                (restore_ok and "OFFSET Z RESTORE" or "OFFSET Z RESTORE FAILED") ..
                " | Reason=" .. tostring(reason) ..
                " | Mode=" .. safe_full_name(mode) ..
                " | BaselineZ=" .. tostring(baseline) ..
                " | FreshAfterZ=" .. tostring(fresh_z) ..
                " | PCallOK=" .. tostring(restore_ok)
            )
        end
        combat_offset_z.modes[address] = nil
    end
    if skipped > 0 then
        append_log(
            "OFFSET Z RESTORE SUMMARY | Reason=" .. tostring(reason) ..
            " | Restored=" .. tostring(restored) ..
            " | SkippedStale=" .. tostring(skipped)
        )
    end

    combat_offset_z.active = false
    return restored
end

local function restore_fov_defaults()
    local restored = 0
    local failed = 0
    local skipped = 0

    for address, saved in pairs(saved_modes) do
        if not valid_object(saved.mode) or saved.fov == nil then
            skipped = skipped + 1
            saved_modes[address] = nil
        else
            local call_ok, field_ok = pcall(function()
                return set_field(saved.mode, "DefaultFieldOfView", saved.fov)
            end)
            if call_ok and field_ok then
                restored = restored + 1
            else
                failed = failed + 1
            end
        end
    end

    append_log(
        "Unlock FOV restore | restored=" .. tostring(restored) ..
        " | failed=" .. tostring(failed) ..
        " | skippedStale=" .. tostring(skipped)
    )

    return restored, failed
end

local function set_camera_detached_state(combat, turn_on)
    if not valid_object(combat) then
        return false
    end

    local address = object_address(combat)
    if address == nil then
        return false
    end

    if turn_on then
        if saved_camera_detached[address] == nil then
            local original = get_field(combat, "bCameraDetachedFromTarget")
            if type(original) == "boolean" then
                saved_camera_detached[address] = {
                    component = combat,
                    value = original,
                }
            end
        end

        return set_field(combat, "bCameraDetachedFromTarget", false)
    end

    local saved = saved_camera_detached[address]
    if saved ~= nil and valid_object(saved.component) and
        type(saved.value) == "boolean" then
        local ok = set_field(saved.component, "bCameraDetachedFromTarget", saved.value)
        saved_camera_detached[address] = nil
        return ok
    end

    saved_camera_detached[address] = nil
    return false
end

local function refresh_active_lock()
    if not lock_active then
        return
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end

    if not valid_object(combat) then
        append_log("LOCK REFRESH | Combat component unavailable")
        return
    end

    local camera = camera_from_combat(combat)
    if valid_object(camera) then
        tracked_camera = camera
        set_camera_detached_state(combat, true)

        if baseline_stack_depth ~= nil then
            local ok, depth = get_camera_stack_depth(camera)
            if ok then
                if depth > baseline_stack_depth then
                    set_stack_camera_type(CAMERA_TYPE_DEFAULT, depth)
                elseif depth == baseline_stack_depth then
                    set_stack_camera_type(CAMERA_TYPE_NONE, depth)
                end
            end
        else
            start_stack_poll()
        end

        if config.FOVEnabled then
            if not write_locked_fov() then
                rebuild_mode_cache()
                write_locked_fov()
            end
        end

        apply_combat_offset_y("LockRefresh")
        apply_combat_offset_z("LockRefresh")
        if config.FOVEnabled then
            write_locked_fov()
        end
    end
end

apply_lock_fov = function(combat, locked)
    if locked then
        local camera = camera_from_combat(combat)
        if camera == nil then
            append_log("LOCK ON ERROR: Player camera unavailable.")
            return false
        end

        tracked_combat = combat
        tracked_camera = camera

        -- Capture the original CameraType only on the first real ON event.
        -- Duplicate HardLock ON events are filtered before this function is called.
        if previous_camera_type == nil then
            local camera_type = CAMERA_TYPE_DEFAULT
            pcall(function()
                camera_type = camera:GetCameraType()
            end)
            previous_camera_type = camera_type
        end

        local fov_ok = true
        if config.FOVEnabled then
            fov_ok = write_locked_fov()
            if not fov_ok then
                local scan_ok, count = pcall(rebuild_mode_cache)
                append_log(
                    "FOV cache recovery scan | ok=" ..
                    tostring(scan_ok) ..
                    " | count=" ..
                    tostring(count)
                )
                fov_ok = write_locked_fov()
            end
        end

        apply_combat_offset_y("LockOn")
        apply_combat_offset_z("LockOn")
        if config.FOVEnabled and fov_ok then
            write_locked_fov()
        end

        local camera_ok = pcall(function()
            camera:SetCameraType(CAMERA_TYPE_NONE)
        end)

        local detached_ok = set_camera_detached_state(combat, true)

        -- Lock lifecycle is independent of FOV availability. Even when no live
        -- RebelCameraMode is available, CameraType/target-follow state must still
        -- be tracked and restored correctly.
        lock_active = true
        fov_applied = config.FOVEnabled and fov_ok
        start_stack_poll()

        append_log(
            "LOCK ON" ..
            " | LockOnFOV=" .. tostring(config.LockOnFOV) ..
            " | FOVEnabled=" .. tostring(config.FOVEnabled) ..
            " | PreviousCameraType=" .. tostring(previous_camera_type) ..
            " | SetCameraType0=" .. tostring(camera_ok) ..
            " | DetachedFromTarget=false=" .. tostring(detached_ok) ..
            " | FOVApplied=" .. tostring(fov_applied)
        )

        return camera_ok
    end

    local camera = camera_from_combat(combat)
    if camera == nil and tracked_camera ~= nil and valid_object(tracked_camera) then
        camera = tracked_camera
    end

    local restore_type = previous_camera_type
    if restore_type == nil then
        restore_type = CAMERA_TYPE_DEFAULT
    end

    local current_camera_type = "<unavailable>"
    if valid_object(camera) then
        pcall(function()
            current_camera_type = tostring(camera:GetCameraType())
        end)
    end

    append_log(
        "===== LOCK OFF BEGIN =====" ..
        " | CurrentCameraType=" .. tostring(current_camera_type) ..
        " | RestoreCameraType=" .. tostring(restore_type)
    )

    restore_camera_type(camera, restore_type)
    set_camera_detached_state(combat, false)
    if tracked_combat ~= nil and tracked_combat ~= combat then
        set_camera_detached_state(tracked_combat, false)
    end

    if fov_applied then
        restore_fov_defaults()
    end

    restore_combat_offset_y("LockOff")
    restore_combat_offset_z("LockOff")

    stop_stack_poll()

    -- Do not reuse the previous lock session's object/baseline cache.
    -- Each new Lock-On session must capture fresh FOV baselines.
    saved_modes = {}

    append_log("===== LOCK OFF END =====")

    previous_camera_type = nil
    tracked_combat = nil
    tracked_camera = nil
    fov_applied = false
    lock_active = false

    return true
end

get_camera_stack_depth = function(camera)
    if not valid_object(camera) then
        return false, 0
    end

    local depth = 0
    local ok = pcall(function()
        local stack = get_field(camera, "CameraModeStack")
        if stack == nil then
            error("CameraModeStack unavailable")
        end
        depth = stack:GetArrayNum()
    end)

    if not ok then
        return false, 0
    end

    return true, depth
end

local function describe_camera_mode(mode)
    if not valid_object(mode) then
        return "<unavailable>"
    end

    local full_name = "<unknown>"
    local class_name = "<unknown>"
    local fov = "<unread>"

    pcall(function()
        full_name = tostring(mode:GetFullName())
    end)

    pcall(function()
        local cls = mode:GetClass()
        if cls ~= nil then
            class_name = tostring(cls:GetFullName())
        end
    end)

    pcall(function()
        local value = get_field(mode, "DefaultFieldOfView")
        if value ~= nil then
            fov = tostring(value)
        end
    end)

    return "FullName=" .. full_name ..
        " | Class=" .. class_name ..
        " | DefaultFOV=" .. fov
end

local function get_camera_stack_mode(camera, index)
    if not valid_object(camera) or type(index) ~= "number" or index < 1 then
        return nil
    end

    local ok, mode = pcall(function()
        local stack = get_field(camera, "CameraModeStack")
        if stack == nil then
            return nil
        end

        local entry = stack[index]
        if entry == nil then
            return nil
        end

        return entry.CameraMode
    end)

    if not ok or not valid_object(mode) then
        return nil
    end

    return mode
end

local function log_camera_mode_stack_probe(camera, depth)
    if type(depth) ~= "number" or depth <= 0 then
        return
    end

    local bottom = get_camera_stack_mode(camera, 1)
    local top = get_camera_stack_mode(camera, depth)

    append_log(
        "CameraModeStack probe" ..
        " | Depth=" .. tostring(depth) ..
        " | Bottom[1]=" .. describe_camera_mode(bottom) ..
        " | Top[" .. tostring(depth) .. "]=" .. describe_camera_mode(top)
    )
end

set_stack_camera_type = function(desired_type, depth)
    local camera = tracked_camera

    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    if not valid_object(camera) then
        append_log("Stack camera fix ERROR: camera unavailable.")
        return false
    end

    local before = "<unavailable>"
    pcall(function()
        before = tostring(camera:GetCameraType())
    end)

    if before == tostring(desired_type) then
        return true
    end

    local ok = pcall(function()
        camera:SetCameraType(desired_type)
    end)

    local after = "<unavailable>"
    pcall(function()
        after = tostring(camera:GetCameraType())
    end)

    append_log(
        "CameraType " .. tostring(before) ..
        " -> " .. tostring(desired_type) ..
        " | success=" .. tostring(ok) ..
        " | readback=" .. tostring(after) ..
        " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
        " | StackDepth=" .. tostring(depth)
    )

    return ok
end

stop_stack_poll = function()
    stack_poll_generation = stack_poll_generation + 1
    stack_poll_active = false
    last_stack_depth = nil
    baseline_stack_depth = nil
end

local function is_defensive_combat_state()
    return last_combat_state_number == 6
end

local function stack_poll()
    local generation = stack_poll_generation

    if type(ExecuteInGameThread) ~= "function" or
        type(ExecuteWithDelay) ~= "function" then
        append_log("Stack camera fix ERROR: timer API unavailable.")
        return
    end

    ExecuteInGameThread(function()
        if generation ~= stack_poll_generation or
            not stack_poll_active or
            not lock_active then
            return
        end

        local camera = tracked_camera
        if not valid_object(camera) then
            camera = camera_from_combat(tracked_combat)
            tracked_camera = camera
        end

        local ok, depth = get_camera_stack_depth(camera)
        if ok then
            if last_stack_depth == nil or depth ~= last_stack_depth then
                append_log(
                    "CameraModeStack depth changed" ..
                    " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
                    " | PreviousDepth=" .. tostring(last_stack_depth) ..
                    " | CurrentDepth=" .. tostring(depth)
                )
                last_stack_depth = depth
                -- Diagnostic probe only when the stack depth changes. This keeps
                -- per-poll overhead low while revealing the actual bottom/top
                -- CameraMode objects and their DefaultFieldOfView.
                log_camera_mode_stack_probe(camera, depth)
            end

            if baseline_stack_depth ~= nil then
                if is_defensive_combat_state() then
                    -- State=6 (block/parry): skip CameraType writes until combat state changes.
                elseif depth > baseline_stack_depth then
                    set_stack_camera_type(CAMERA_TYPE_DEFAULT, depth)
                elseif depth == baseline_stack_depth then
                    set_stack_camera_type(CAMERA_TYPE_NONE, depth)
                else
                    -- Below baseline is intentionally NOT a Lock-Off signal.
                    append_log(
                        "CameraModeStack below baseline | no recovery" ..
                        " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
                        " | CurrentDepth=" .. tostring(depth)
                    )
                end
            end
        end
    end)

    ExecuteWithDelay(POLL_MS, function()
        if generation == stack_poll_generation and
            stack_poll_active and
            lock_active then
            stack_poll()
        end
    end)
end

start_stack_poll = function()
    if not lock_active then
        return
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    local ok, depth = get_camera_stack_depth(camera)
    if ok then
        baseline_stack_depth = depth
        last_stack_depth = depth
        append_log(
            "Lock-On StackDepth baseline captured" ..
            " | BaseStackDepth=" .. tostring(baseline_stack_depth)
        )
    else
        baseline_stack_depth = nil
        last_stack_depth = nil
        append_log("Lock-On StackDepth baseline capture failed")
    end

    stack_poll_generation = stack_poll_generation + 1
    stack_poll_active = true
    stack_poll()
end

-- Do not subscribe to every new PlayerCombatComponent. This was too noisy and
-- could select unrelated/stale objects. The active SetHardLock hook updates the
-- authoritative component reference when Lock-On is actually used.

local function handle_new_camera_mode(mode, source)
    if not valid_object(mode) then
        return
    end

    local address = object_address(mode)
    if address == nil then
        return
    end

    if is_ability_mode(mode) then
        append_log(
            "CAMERA MODE DISCOVERED | Source=" .. tostring(source) ..
            " | AbilityMode=true | " .. describe_camera_mode(mode)
        )
        return
    end

    cache_mode(mode)

    if lock_active and config.FOVEnabled then
        local ok = set_field(mode, "DefaultFieldOfView", config.LockOnFOV)
        if ok then
            fov_applied = true
        end
    end

    if lock_active then
        apply_offset_y_to_mode(mode, "NewCameraMode", nil)
        apply_offset_z_to_mode(mode, "NewCameraMode", nil)
        if config.FOVEnabled then
            set_field(mode, "DefaultFieldOfView", config.LockOnFOV)
        end
    end

    append_log(
        "CAMERA MODE DISCOVERED | Source=" .. tostring(source) ..
        " | AbilityMode=false | " .. describe_camera_mode(mode)
    )
end

pcall(function()
    NotifyOnNewObject(
        CAMERA_MODE_CLASS,
        function(mode)
            handle_new_camera_mode(mode, "RebelCameraMode")
        end
    )
end)

pcall(function()
    NotifyOnNewObject(
        COMBAT_CAMERA_MODE_CLASS,
        function(mode)
            handle_new_camera_mode(mode, "CombatCameraMode")
        end
    )
end)

if type(ExecuteWithDelay) == "function" and
    type(ExecuteInGameThread) == "function" then

    local warmup_generation = runtime_generation

    ExecuteWithDelay(
        CACHE_WARMUP_MS,
        function()
            if warmup_generation ~= runtime_generation then
                return
            end

            ExecuteInGameThread(
                function()
                    if warmup_generation ~= runtime_generation then
                        return
                    end

                    local ok, count = pcall(
                        rebuild_mode_cache
                    )

                    if ok then
                        append_log(
                            "FOV cache warmup complete | CachedModes=" ..
                            tostring(count)
                        )
                    else
                        append_log(
                            "FOV cache warmup failed: " ..
                            tostring(count)
                        )
                    end
                end
            )
        end
    )
end

if ENABLE_INPUT_DIAGNOSTIC then
    start_input_observer()
else
    append_log("INPUT OBSERVER DISABLED | Known FKey construction issue; diagnostics only")
end

-- Start the CombatMode observer as a lightweight diagnostic/cleanup watcher.
-- This was defined in earlier builds but was not actually started; without this
-- call the nonzero -> 0 CombatMode cleanup path could never execute.
if type(ExecuteWithDelay) == "function" then
    local combat_start_generation = runtime_generation

    ExecuteWithDelay(
        1500,
        function()
            if combat_start_generation ~= runtime_generation then
                return
            end

            start_combat_state_poll()
            append_log(
                "COMBAT OBSERVER START | PollMs=" ..
                tostring(COMBAT_STATE_POLL_MS)
            )
        end
    )
else
    start_combat_state_poll()
    append_log(
        "COMBAT OBSERVER START | PollMs=" ..
        tostring(COMBAT_STATE_POLL_MS)
    )
end

local SET_LOCK_TARGET_FUNCTION = "/Script/DogwoodCombat.PlayerCombatComponent:SetLockTarget"

pcall(function()
    RegisterHook(
        SET_LOCK_TARGET_FUNCTION,
        function() end,
        function()
            if not lock_active then
                return
            end

            local refresh_generation = runtime_generation

            ExecuteWithDelay(100, function()
                if refresh_generation ~= runtime_generation then
                    return
                end

                ExecuteInGameThread(function()
                    if refresh_generation ~= runtime_generation then
                        return
                    end

                    if lock_active then
                        refresh_active_lock()
                        append_log("TARGET CHANGE | Active Lock-On refreshed")
                    end
                end)
            end)
        end
    )
end)

-- Map/load transition safety.
-- Do not attempt to restore state on the old world here: its UObject references
-- may already be in teardown. Invalidate all delayed work and runtime object caches
-- so callbacks created before the transition cannot touch stale objects.
local function invalidate_world_runtime(reason)
    runtime_generation = runtime_generation + 1

    stop_stack_poll()
    stop_combat_state_poll()

    input_observer_generation = input_observer_generation + 1
    input_observer_active = false
    input_controller = nil
    input_keys = nil
    input_key_state = {}
    input_combo_state = false
    input_controller_retry_logged = false

    combat_component = nil
    tracked_combat = nil
    tracked_camera = nil
    saved_modes = {}
    saved_camera_detached = {}
    previous_camera_type = nil
    fov_applied = false
    lock_active = false

    append_log(
        "WORLD RUNTIME INVALIDATED" ..
        " | Reason=" .. tostring(reason) ..
        " | Generation=" .. tostring(runtime_generation)
    )
end

local function restart_world_runtime(generation, reason)
    if generation ~= runtime_generation then
        return
    end

    if type(ExecuteInGameThread) ~= "function" then
        return
    end

    ExecuteInGameThread(function()
        if generation ~= runtime_generation then
            return
        end

        combat_component = nil
        tracked_combat = nil
        tracked_camera = nil
    combat_state_last = nil
    combat_mode_last = nil
    last_combat_state_number = nil
    combat_component_name_logged = false

        if type(FindAllOf) == "function" then
            local ok, count = pcall(rebuild_mode_cache)
            if ok then
                append_log(
                    "WORLD RUNTIME REINIT CACHE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | CachedModes=" .. tostring(count)
                )
            end
        end

        if not combat_state_poll_active then
            start_combat_state_poll()
            append_log(
                "WORLD RUNTIME REINIT COMBAT" ..
                " | Reason=" .. tostring(reason)
            )
        end

        if ENABLE_INPUT_DIAGNOSTIC then
            input_observer_generation = input_observer_generation + 1
            input_observer_active = true
            input_controller = nil
            input_keys = nil
            input_key_state = {}
            input_combo_state = false
            input_controller_retry_logged = false
            input_init_failed = false

            if type(ExecuteWithDelay) == "function" then
                local input_generation = runtime_generation

                ExecuteWithDelay(INPUT_START_DELAY_MS, function()
                    if input_generation ~= runtime_generation or
                        not input_observer_active then
                        return
                    end
                    input_observer_poll()
                end)
            else
                input_observer_poll()
            end
        end
    end)
end

if type(RegisterLoadMapPreHook) == "function" then
    pcall(function()
        RegisterLoadMapPreHook(function()
            invalidate_world_runtime("LoadMapPre")
        end)
    end)
end

if type(RegisterLoadMapPostHook) == "function" then
    pcall(function()
        RegisterLoadMapPostHook(function()
            local generation = runtime_generation

            append_log(
                "LOAD MAP POST" ..
                " | Generation=" .. tostring(generation)
            )

            if type(ExecuteWithDelay) == "function" then
                ExecuteWithDelay(1000, function()
                    restart_world_runtime(generation, "LoadMapPost")
                end)
            else
                restart_world_runtime(generation, "LoadMapPost")
            end
        end)
    end)
end

RegisterHook(
    HARD_LOCK_FUNCTION,
    function() end,
    function(combat_param, wrapped_locked)
        if wrapped_locked == nil then
            return
        end

        local combat = hook_object(combat_param)
        local locked = wrapped_locked:get() == true

        if combat ~= nil then
            set_combat_component(combat, "HardLock")
        end

        lock_trigger_count = lock_trigger_count + 1
        if locked then
            lock_on_trigger_count = lock_on_trigger_count + 1
        else
            lock_off_trigger_count = lock_off_trigger_count + 1
        end

        local state_before = lock_active
        local fov_before = fov_applied
        local prev_camera_before = previous_camera_type

        append_log(
            "HARDLOCK TRIGGER" ..
            " | Event=" .. (locked and "ON" or "OFF") ..
            " | TriggerCount=" .. tostring(lock_trigger_count) ..
            " | OnCount=" .. tostring(lock_on_trigger_count) ..
            " | OffCount=" .. tostring(lock_off_trigger_count) ..
            " | PreviousLockActive=" .. tostring(state_before) ..
            " | FOVApplied=" .. tostring(fov_before) ..
            " | PreviousCameraType=" .. tostring(prev_camera_before)
        )

        -- A duplicate HardLock event must not start/reset another session.
        -- In particular, a duplicate ON must never overwrite the original
        -- CameraType captured at the first ON.
        if locked and state_before then
            append_log(
                "HARDLOCK DUPLICATE EVENT | Event=ON" ..
                " | LockActiveBefore=true | Ignored duplicate ON"
            )

            append_log(
                "HARDLOCK HANDLER COMPLETE" ..
                " | Event=ON" ..
                " | Duplicate=true" ..
                " | LockActive=" .. tostring(lock_active) ..
                " | FOVApplied=" .. tostring(fov_applied)
            )
            return
        end

        if (not locked) and (not state_before) then
            append_log(
                "HARDLOCK DUPLICATE EVENT | Event=OFF" ..
                " | LockActiveBefore=false | Ignored duplicate OFF"
            )

            append_log(
                "HARDLOCK HANDLER COMPLETE" ..
                " | Event=OFF" ..
                " | Duplicate=true" ..
                " | LockActive=" .. tostring(lock_active) ..
                " | FOVApplied=" .. tostring(fov_applied)
            )
            return
        end

        local ok, err = pcall(function()
            apply_lock_fov(combat, locked)
        end)

        if not ok then
            append_log(
                "LOCK HardLock ERROR: " ..
                tostring(err)
            )
        end

        append_log(
            "HARDLOCK RESULT" ..
            " | Event=" .. (locked and "ON" or "OFF") ..
            " | PCallOK=" .. tostring(ok) ..
            " | LockActiveAfter=" .. tostring(lock_active) ..
            " | FOVAppliedAfter=" .. tostring(fov_applied) ..
            " | CameraTypeSaved=" .. tostring(previous_camera_type)
        )

        if locked then
            append_log(
                "HARDLOCK HANDLER COMPLETE" ..
                " | Event=ON" ..
                " | Duplicate=false" ..
                " | LockActive=" .. tostring(lock_active) ..
                " | Lifecycle=HardLock"
            )
        else
            append_log(
                "HARDLOCK HANDLER COMPLETE" ..
                " | Event=OFF" ..
                " | Duplicate=false" ..
                " | LockActive=" .. tostring(lock_active) ..
                " | Lifecycle=HardLock"
            )
        end
    end
)

RegisterConsoleCommandHandler(
    "clo",
    function(FullCommand, Parameters, Ar)
        local command = Parameters[1]
        command = command ~= nil and tostring(command) or ""
        command = command:gsub("^%s+", ""):gsub("%s+$", "")

        local arg = Parameters[2]
        arg = arg ~= nil and tostring(arg) or ""
        arg = arg:gsub("^%s+", ""):gsub("%s+$", "")

        local value_arg = Parameters[3]
        value_arg = value_arg ~= nil and tostring(value_arg) or ""
        value_arg = value_arg:gsub("^%s+", ""):gsub("%s+$", "")

        if command == "?" or command == "" then
            Ar:Log("clo fov disable")
            Ar:Log("clo fov enable")
            Ar:Log("clo offset <value>")
            Ar:Log("clo pitch <value>")
            Ar:Log("clo fov value <value>")
            Ar:Log("clo fovstatus")
            Ar:Log("clo diagstatus")
            Ar:Log("clo ver")
            return true
        end

        if command == "ver" then
            Ar:Log("LockOnFovChanger version: " .. SCRIPT_VERSION)
            return true
        end

        if command == "fov" then
            if arg == "disable" then
                ExecuteInGameThread(function()
                    if lock_active and fov_applied then
                        restore_fov_defaults()
                    end
                    config.FOVEnabled = false
                    fov_applied = false
                    append_log("CONSOLE | FOVEnabled=false")
                end)
                Ar:Log("FOVEnabled=false")
                return true
            end

            if arg == "enable" then
                ExecuteInGameThread(function()
                    config.FOVEnabled = true
                    if lock_active then
                        local ok = write_locked_fov()
                        if not ok then
                            pcall(rebuild_mode_cache)
                            ok = write_locked_fov()
                        end
                        fov_applied = ok
                    end
                    append_log("CONSOLE | FOVEnabled=true | LockOnFOV=" .. tostring(config.LockOnFOV))
                end)
                Ar:Log("FOVEnabled=true | LockOnFOV=" .. tostring(config.LockOnFOV))
                return true
            end

            if arg == "value" then
                local value = tonumber(value_arg)
                if value ~= nil and value >= 1 and value <= 179 then
                    config.LockOnFOV = value
                    ExecuteInGameThread(function()
                        if lock_active and config.FOVEnabled then
                            local ok = write_locked_fov()
                            if not ok then
                                pcall(rebuild_mode_cache)
                                ok = write_locked_fov()
                            end
                            fov_applied = ok
                        end
                        append_log("CONSOLE | LockOnFOV=" .. tostring(config.LockOnFOV))
                    end)
                    Ar:Log("LockOnFOV=" .. tostring(config.LockOnFOV))
                    return true
                end
                Ar:Log("Usage: clo fov value <1-179>")
                return true
            end

            Ar:Log("Usage: clo fov disable | clo fov enable | clo fov value <1-179>")
            return true
        end

        if command == "offset" then
            local direct_value = tonumber(arg)
            if direct_value ~= nil then
                config.EnemyOffset = direct_value
                ExecuteInGameThread(function()
                    if lock_active then
                        apply_combat_offset_y("Console")
                        if config.FOVEnabled and fov_applied then
                            write_locked_fov()
                        end
                    end
                    append_log("CONSOLE | EnemyOffset=" .. tostring(config.EnemyOffset))
                end)
                Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
                return true
            end

            Ar:Log("Usage: clo offset <number>")
            return true
        end

        if command == "pitch" then
            local value = tonumber(arg)
            if value == nil then
                Ar:Log("Usage: clo pitch <number> (0 = game default)")
                return true
            end

            config.LockOnOffsetZ = value
            ExecuteInGameThread(function()
                if lock_active then
                    if value > 0.001 then
                        apply_combat_offset_z("Console")
                        if config.FOVEnabled and fov_applied then
                            write_locked_fov()
                        end
                    else
                        restore_combat_offset_z("Console")
                    end
                end
                append_log("CONSOLE | LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ))
            end)
            Ar:Log("LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ))
            return true
        end

        if command == "fovstatus" then
            Ar:Log("FOVEnabled=" .. tostring(config.FOVEnabled))
            Ar:Log("LockOnFOV=" .. tostring(config.LockOnFOV))
            Ar:Log("LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ))
            Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
            Ar:Log("EnableLog=" .. tostring(config.EnableLog))
            Ar:Log("FOVApplied=" .. tostring(fov_applied))
            Ar:Log("LockActive=" .. tostring(lock_active))
            return true
        end

        if command == "diagstatus" then
            Ar:Log("Lifecycle=HardLock ON/OFF + CombatMode nonzero->0 exit cleanup")
            Ar:Log("CombatExitCleanup=CurrentCombatMode 0 triggers restore when LockActive=true")
            Ar:Log("CombatModePollMs=" .. tostring(COMBAT_STATE_POLL_MS) .. " (state changes only)")
            Ar:Log("CombatComponent=" .. tostring(valid_object(combat_component)))
            Ar:Log("CurrentState=" .. readable_runtime_value(get_field(combat_component, "CurrentState")))
            Ar:Log("CurrentCombatMode=" .. readable_runtime_value(get_field(combat_component, "CurrentCombatMode")))
            Ar:Log("CameraModeStackDepth=" .. tostring(last_stack_depth))
            Ar:Log("LockActive=" .. tostring(lock_active))
            Ar:Log("FOVApplied=" .. tostring(fov_applied))
            Ar:Log("SavedCameraType=" .. tostring(previous_camera_type))
            Ar:Log("LogFile=" .. tostring(log_path))
            return true
        end

        return false
    end
)

append_log(
    "Loaded " ..
    MOD_NAME ..
    " | FOVEnabled=" ..
    tostring(config.FOVEnabled) ..
    " | LockOnFOV=" ..
    tostring(config.LockOnFOV) ..
    " | LockOnOffsetZ=" ..
    tostring(config.LockOnOffsetZ) ..
    " | EnemyOffset=" ..
    tostring(config.EnemyOffset)
)

append_log(
    "HardLock lifecycle: ON/OFF controls Lock-On state. CurrentCombatMode nonzero->0 performs exit cleanup if LockActive remains true. CombatMode observer polls every 500ms, logs only value changes, and ignores non-numeric/unavailable mode samples for lifecycle detection. CameraModeStack only controls temporary CameraType behavior; below-baseline depth never triggers recovery. CameraMode discovery is event-driven for both RebelCameraMode and /Script/DogwoodCombat.CombatCameraMode. SetLockTarget triggers a delayed active-lock refresh. During Lock-On, bCameraDetachedFromTarget is saved and forced false, then restored on Lock-Off. FOV application is independent from Lock lifecycle, so temporary FOV availability cannot break CameraType or cleanup handling. On stack-depth changes, a diagnostic probe reads the bottom entry [1] and top entry [Depth], logging each CameraMode FullName, Class, and DefaultFieldOfView; it performs no direct FOV/offset modification."
)

append_log(
    "LogFile=" ..
    tostring(log_path)
)
