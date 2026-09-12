--[[
===============================================================================
LockOnFovChanger v1.3.25
UE4SS mod for The Blood of Dawnwalker — Lock-On camera control
Author: josky
===============================================================================

FEATURES
--------
- Combat FOV: Enter combat mode to enable custom FOV, exit combat mode will return game FOV
- Lock-On Offset Z + EnemyOffset Y: instant apply on Lock-On, restore on Lock-Off
- PageUp   = master ON  (re-apply INI settings)
- PageDown = master OFF (restore original camera)
- clo fovstatus / clo ui = show settings (UMG overlay disabled; crashes on this game)

INSTALL
-------
1. Install UE4SS with Lua mods enabled
2. Put files here:
   ue4ss\Mods\LockOnFovChanger\Scripts\main.lua
   ue4ss\Mods\LockOnFovChanger\Scripts\LockOnFovChanger.ini
3. Start the game (restart after editing INI)

INI  (LockOnFovChanger.ini)
----
FOVEnabled=true/false     Enable combat FOV tween (on combat enter/exit)
LockOnFOV=110             Target combat FOV (normal game FOV is ~90)
LockOnOffsetZ=30          Lock-On Offset Z (instant on Lock-On, restore on Lock-Off)
EnemyOffset=120           Lock-On CameraLocationOffsetDuringTargeting.Y (120 = game default)
EnableLog=true/false      Diagnostic log file (keep false for normal play)

CONSOLE  (prefix: clo)
-------
clo mod 0 | clo mod 1              Master OFF / ON (same as PageDown / PageUp)
clo fov 0 | clo fov 1              FOV feature OFF / ON
clo fov value <1-179>              Set LockOnFOV now
clo offset 0 | clo offset 1        EnemyOffset disable / enable
clo offset value <number>          Set EnemyOffset Y (120 = game default)
clo z <value>                      Set LockOnOffsetZ for this session
clo ui                             Show current settings / Lock-On state
clo fovstatus                      Same as clo ui
clo ver                            Show mod version
clo mark                           Log USER MARK CombatOver (same as End)

]]
local MOD_NAME = "LockOnFovChanger_v1.3.25"
local SCRIPT_VERSION = "1.3.25"

local HARD_LOCK_FUNCTION = "/Script/DogwoodCombat.PlayerCombatComponent:SetHardLock"
local CAMERA_MODE_CLASS = "RebelCameraMode"
local COMBAT_CAMERA_MODE_CLASS = "/Script/DogwoodCombat.CombatCameraMode"
local COMBAT_COMPONENT_CLASS = "PlayerCombatComponent"

local CAMERA_TYPE_NONE = 0
local CAMERA_TYPE_DEFAULT = 1

local POLL_MS = 150
local CACHE_WARMUP_MS = 1000

local ENABLE_LOG_DEFAULT = false
local ENABLE_INPUT_DIAGNOSTIC = false

-- UE4SS UEHelpers provides the local PlayerController without a full object scan.
local UEHelpers = require("UEHelpers")
local GetPlayerController = UEHelpers.GetPlayerController

local COMBAT_OFFSET_DEFAULT_Y = 120.0

local CONFIG_DEFAULTS = {
    FOVEnabled = true,
    LockOnFOV = 110.0,
    LockOnOffsetZ = 70.0,
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
                elseif key == "EnemyOffsetEnabled" or key == "CameraOffsetFix" then
                    if not parse_bool(value, true) then
                        config.EnemyOffset = COMBAT_OFFSET_DEFAULT_Y
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
    local prefix = "LockOnFovChanger_v" .. SCRIPT_VERSION .. "_"
    local stamp = os.date("%Y%m%d_%H%M%S") .. ".log"
    if script_directory == nil or script_directory == "" then
        return prefix .. stamp
    end

    return script_directory .. "\\" .. prefix .. stamp
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
            " | LockOnOffsetZ=" ..
            tostring(config.LockOnOffsetZ) ..
            " | EnemyOffset=" ..
            tostring(config.EnemyOffset) ..
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

-- Bag for helpers so the main chunk stays under Lua's 200-local limit.
local CloUtil = {}
CloUtil.lock_target = { address = nil, name = nil, component = nil }
CloUtil.vitality_log = { last_ms = 0 }
CloUtil.stack_overlay = {
    active = false,
    recovery_pending = false,
    recovery_generation = 0,
    recovery_ms = 300,
    quiet_until_ms = 0,
    quiet_ms = 250,
}

function CloUtil.is_hot_fov_write_quiet()
    local overlay = CloUtil.stack_overlay
    if overlay.recovery_pending or overlay.active then
        return true
    end
    return (os.clock() * 1000.0) < (overlay.quiet_until_ms or 0)
end

CloUtil.combat_fov = {
    generation = 0,
    direction = nil,
    paused = false,
    poll_active = false,
    pending_enter = false,
    session_active = false,
    last_state = nil,
    lock_writes_deferred = false,
    exit_pending = 0,
    exit_confirm_polls = 2,
    exit_confirm_ms = 2000,
    exit_zero_since_ms = nil,
    duration_ms = 350,
    tick_ms = 33,
    start_ms = 0,
    from_by_address = {},
    last_manager_fov = nil,
    last_stack_push_ms = nil,
    last_view_publish_ms = nil,
    last_reassert_ms = nil,
    reassert_cooldown_ms = 800,
    resolve_miss_logged = false,
    stack_push_interval_ms = 300,
    view_publish_interval_ms = 200,
    last_catchup_ms = nil,
    catchup_cooldown_ms = 2000,
    fov_type_pulse_done = false,
    fov_type_pulse_pending = false,
    restore_view_fov = nil,
    sheath_abort_rearm_pending = false,
}

function CloUtil.mark_overlay_recovery_quiet()
    local overlay = CloUtil.stack_overlay
    overlay.quiet_until_ms = (os.clock() * 1000.0) + (overlay.quiet_ms or 250)
end

function CloUtil.combat_component_path_text(component)
    if component == nil then
        return ""
    end

    local ok, name = pcall(function()
        return component:GetFullName()
    end)
    if ok and name ~= nil then
        return tostring(name)
    end

    return tostring(component)
end

function CloUtil.is_cutscene_combat_component(component)
    local path = string.lower(CloUtil.combat_component_path_text(component))
    if path == "" then
        return false
    end

    return path:find("cutscene", 1, true) ~= nil or
        path:find("moviescene", 1, true) ~= nil or
        path:find("_ls.", 1, true) ~= nil
end

function CloUtil.score_combat_component(component)
    local path = string.lower(CloUtil.combat_component_path_text(component))
    if path == "" then
        return -1
    end

    local score = 0
    if path:find("persistentlevel", 1, true) ~= nil then
        score = score + 1000
    end
    if path:find("bp_playercharacter", 1, true) ~= nil then
        score = score + 500
    end
    if CloUtil.is_cutscene_combat_component(component) then
        score = score - 10000
    end

    return score
end

function CloUtil.get_ini_path()
    if script_directory ~= nil and script_directory ~= "" then
        return script_directory .. "\\LockOnFovChanger.ini"
    end
    return "LockOnFovChanger.ini"
end

function CloUtil.save_external_config()
    local path = CloUtil.get_ini_path()
    local lines = {
        "FOVEnabled=" .. tostring(config.FOVEnabled),
        "LockOnFOV=" .. tostring(config.LockOnFOV),
        "LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ),
        "EnemyOffset=" .. tostring(config.EnemyOffset),
        "EnableLog=" .. tostring(config.EnableLog),
        "",
    }

    local ok, file = pcall(io.open, path, "w")
    if not ok or file == nil then
        append_log("INI SAVE FAILED | Path=" .. tostring(path))
        return false
    end

    file:write(table.concat(lines, "\n"))
    file:close()
    append_log("INI SAVED | Path=" .. tostring(path))
    return true
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

function CloUtil.combat_from_outer_object(object)
    local current = object
    for _ = 1, 8 do
        if not valid_object(current) then
            break
        end

        local field_names = {
            "CombatComponent",
            "PlayerCombatComponent",
            "Combat",
        }
        for _, field_name in ipairs(field_names) do
            local candidate = get_field(current, field_name)
            if candidate ~= nil then
                candidate = hook_object(candidate) or candidate
            end
            if valid_object(candidate) and
                not CloUtil.is_cutscene_combat_component(candidate) then
                return candidate
            end
        end

        local outer = nil
        pcall(function()
            outer = current:GetOuter()
        end)
        if outer == nil or outer == current then
            break
        end
        current = outer
    end

    return nil
end

function CloUtil.find_player_combat_component()
    if type(GetPlayerController) ~= "function" then
        return nil
    end

    local controller = GetPlayerController()
    if not valid_object(controller) then
        return nil
    end

    local pawn = nil
    pcall(function()
        if controller.GetPawn ~= nil then
            pawn = controller:GetPawn()
        elseif controller.Pawn ~= nil then
            pawn = controller.Pawn
        elseif controller.AcknowledgedPawn ~= nil then
            pawn = controller.AcknowledgedPawn
        end
    end)
    if not valid_object(pawn) then
        return nil
    end

    local from_pawn = CloUtil.combat_from_outer_object(pawn)
    if valid_object(from_pawn) then
        return from_pawn
    end

    local by_class = nil
    pcall(function()
        if pawn.GetComponentByClass ~= nil then
            by_class = pawn:GetComponentByClass(COMBAT_COMPONENT_CLASS)
        end
    end)
    if by_class ~= nil then
        by_class = hook_object(by_class) or by_class
    end
    if valid_object(by_class) and
        not CloUtil.is_cutscene_combat_component(by_class) then
        return by_class
    end

    return nil
end

function CloUtil.resolve_combat_component(cached)
    local player_component = CloUtil.find_player_combat_component()
    if valid_object(player_component) then
        return player_component
    end

    if valid_object(cached) and
        not CloUtil.is_cutscene_combat_component(cached) then
        return cached
    end

    return nil
end

-- UE4SS may return struct/container fields as userdata wrappers. Some wrappers
-- expose the actual value through :get(); unwrap only for diagnostics and
-- numeric reads so normal UObject handling remains unchanged.
local function unwrap_value(value)
    if value == nil or type(value) ~= "userdata" then
        return value
    end

    local ok, result = pcall(function()
        return value:get()
    end)
    if ok and result ~= nil then
        return result
    end
    return value
end

local function get_unwrapped_field(owner, field_name)
    return unwrap_value(get_field(unwrap_value(owner), field_name))
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

-- Temporary combat overlays (sprint / push layers). Safe for CameraType stack
-- handling, but must NOT receive LockOnOffsetZ / OffsetY writes.
function CloUtil.is_transient_overlay_mode(mode)
    if mode == nil or is_ability_mode(mode) then
        return true
    end

    local lower = string.lower(safe_class_name(mode))
    return string.find(lower, "sprint", 1, true) ~= nil
        or string.find(lower, "bloodboil", 1, true) ~= nil
        or string.find(lower, "block", 1, true) ~= nil
        or string.find(lower, "guard", 1, true) ~= nil
        or string.find(lower, "deflect", 1, true) ~= nil
        or string.find(lower, "parry", 1, true) ~= nil
end

local function value_to_string(object, field_name)
    local value = get_field(object, field_name)

    if value == nil then
        return "<unavailable>"
    end

    return tostring(value)
end

-- Combat-state observer. CurrentCombatMode 0<->nonzero drives combat Offset Z;
-- nonzero->0 also triggers Lock-Off cleanup when a session is still active.
local COMBAT_STATE_POLL_MS = 500
local combat_component = nil
local combat_state_last = nil
local combat_mode_last = nil
local combat_component_name_logged = false
local combat_state_poll_generation = 0
local combat_state_poll_active = false

-- World/load lifecycle generation. Any delayed callback created before a map
-- transition becomes invalid after the generation changes.
local runtime_generation = 0

-- Forward declaration: Combat exit handling can invoke the normal Lock-Off
-- restore path after the function is defined below.
local apply_lock_fov
local set_camera_detached_state
local apply_combat_offset_fix

local saved_modes = {}
local saved_camera_detached = {}
local tracked_combat = nil
local tracked_camera = nil
local previous_camera_type = nil
local fov_applied = false
local lock_active = false
local game_hard_lock_active = false
-- Master runtime switch controlled by PageDown/PageUp or `clo mod 0/1`.
-- Individual FOV/offset settings remain stored in config so disabling the
-- master switch does not destroy the user's preferences.
local mod_enabled = true
local test_camera_suspended = false
local lock_camera_test_suspended = false

function CloUtil.enemy_offset_target_y()
    return tonumber(config.EnemyOffset) or COMBAT_OFFSET_DEFAULT_Y
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
    if tracked_combat ~= nil and valid_object(tracked_combat) then
        if combat_component == nil or
            object_address(tracked_combat) ~= object_address(combat_component) then
            set_combat_component(tracked_combat, "TrackedCombat")
        end
        return combat_component
    end

    if valid_object(combat_component) and
        not CloUtil.is_cutscene_combat_component(combat_component) then
        return combat_component
    end

    local resolved = CloUtil.resolve_combat_component(combat_component)
    if resolved == nil then
        combat_component = nil
        return nil
    end

    local resolved_address = object_address(resolved)
    local cached_address = object_address(combat_component)
    if cached_address == nil or cached_address ~= resolved_address then
        set_combat_component(resolved, "Resolve")
    end

    return combat_component
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

local function get_player_camera_manager()
    local controller = nil
    local manager = nil
    pcall(function()
        controller = GetPlayerController()
    end)
    if valid_object(controller) then
        manager = get_field(controller, "PlayerCameraManager")
    end
    return controller, manager
end

-- CameraModeStack is used only to protect the camera during temporary
-- combat/attack camera modes. It never controls Lock-On session lifecycle.
local baseline_stack_depth = nil
local last_stack_depth = nil
local last_lock_test_mode_address = nil
local stack_poll_generation = 0
local stack_poll_active = false
local get_camera_stack_depth
local set_stack_camera_type
local start_stack_poll
local stop_stack_poll

-- Read-only post-Lock-On pitch timeline. Disabled by default: the previous
-- 50ms monitor plus expanded probes stuttered Lock-On and crashed on PageUp/Down.
local PITCH_MONITOR_INTERVAL_MS = 50
local PITCH_MONITOR_DURATION_MS = 3000
local ENABLE_PITCH_MONITOR = false
local pitch_monitor_generation = 0
local pitch_monitor_active = false
local start_pitch_monitor
local stop_pitch_monitor

-- Hot-path probes only touch known-safe fields. Speculative candidate scans are
-- opt-in via `clo pitchprobe` because missing UObject fields often return
-- disposable TrivialObject wrappers that spam logs and destabilize UE4SS.
local PITCH_SOURCE_CANDIDATES = {
    "RelativeRotation",
    "CameraRotationOffsetDuringTargeting",
    "RotationOffsetDuringTargeting",
    "CameraRotationOffset",
    "DesiredRotation",
    "TargetRotation",
    "ControlRotation",
}

local PITCH_SCALAR_CANDIDATES = {
    "DefaultFieldOfView",
    "PivotZOffset",
}

local LOCATION_OFFSET_CANDIDATES = {
    "CameraLocationOffsetDuringTargeting",
    "RelativeLocation",
}

local LOCK_TARGET_FIELD_CANDIDATES = {
    "LockTarget",
    "CurrentLockTarget",
    "HardLockTarget",
    "LockedActor",
    "LockedTarget",
    "CurrentTarget",
    "TargetActor",
    "FocusTarget",
}

local CAMERA_OFFSET_ENTRY_SCALAR_CANDIDATES = {
    "PivotZOffset",
    "bUseOffsetPitchCurves",
}

local CAMERA_OFFSET_ENTRY_VECTOR_CANDIDATES = {
    "TargetOffset",
}

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
        local saved_fov = baseline_fov(mode)
        if type(saved_fov) == "number" and
            math.abs(saved_fov - config.LockOnFOV) < 0.001 then
            saved_fov = CloUtil.unlock_baseline_fov(mode)
        end

        saved_modes[address] = {
            mode = mode,
            fov = saved_fov,
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

local function recover_fov_cache_and_write()
    local scan_ok, cache_ok, cache_count = pcall(rebuild_mode_cache)
    append_log(
        "FOV cache recovery scan | ok=" ..
        tostring(scan_ok) ..
        " | cacheOk=" .. tostring(cache_ok) ..
        " | count=" .. tostring(cache_count)
    )
    return write_locked_fov()
end

function CloUtil.stop_combat_fov_tween(reason)
    local cf = CloUtil.combat_fov
    cf.generation = cf.generation + 1
    cf.poll_active = false
    cf.direction = nil
    cf.paused = false
    cf.from_by_address = {}
    cf.last_manager_fov = nil
    if config.EnableLog and reason ~= nil then
        append_log("COMBAT FOV TWEEN STOP | Reason=" .. tostring(reason))
    end
end

function CloUtil.combat_fov_smooth_t(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    return t * t * (3.0 - 2.0 * t)
end

function CloUtil.iter_combat_fov_stack_modes(visitor)
    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
    end
    if not valid_object(camera) then
        local combat = find_combat_component()
        camera = camera_from_combat(combat)
    end
    if not valid_object(camera) then
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        return 0
    end

    local depth = 0
    pcall(function()
        depth = stack:GetArrayNum()
    end)
    if type(depth) ~= "number" or depth <= 0 then
        return 0
    end

    local count = 0
    for index = 1, depth do
        local mode = nil
        pcall(function()
            local entry = stack[index]
            if entry ~= nil then
                mode = entry.CameraMode
            end
        end)
        if valid_object(mode) and
            not is_ability_mode(mode) and
            not CloUtil.is_transient_overlay_mode(mode) then
            cache_mode(mode)
            local address = object_address(mode)
            if visitor(mode, address, index) then
                count = count + 1
            end
        end
    end

    return count
end

function CloUtil.read_manager_fov()
    local _, manager = get_player_camera_manager()
    if not valid_object(manager) then
        return nil
    end
    local value = nil
    pcall(function()
        value = manager:GetFOVAngle()
    end)
    return tonumber(value)
end

function CloUtil.set_manager_fov(target_fov, reason, force)
    if type(target_fov) ~= "number" then
        return false
    end
    if CloUtil.stack_overlay.active or CloUtil.combat_fov.paused then
        return false
    end

    local cf = CloUtil.combat_fov
    if not force and cf.last_manager_fov ~= nil and
        math.abs(cf.last_manager_fov - target_fov) < 0.05 then
        return true
    end

    local _, manager = get_player_camera_manager()
    if not valid_object(manager) then
        return false
    end

    local ok = false
    pcall(function()
        manager:SetFOVAngle(target_fov)
        ok = true
    end)

    if ok then
        cf.last_manager_fov = target_fov
        if config.EnableLog and reason ~= nil and
            reason ~= "CombatPoll" and
            reason ~= "StackPoll" then
            append_log(
                "COMBAT MANAGER FOV" ..
                " | Reason=" .. tostring(reason) ..
                " | Target=" .. tostring(target_fov)
            )
        end
    end

    return ok
end

function CloUtil.write_manager_cache_pov_fov(manager, cache_field, target_fov)
    if not valid_object(manager) or type(target_fov) ~= "number" then
        return false
    end

    local cache = get_unwrapped_field(manager, cache_field)
    local pov = get_unwrapped_field(cache, "POV")
    if pov == nil then
        return false
    end

    return set_field(pov, "FOV", target_fov)
end

function CloUtil.publish_combat_fov_to_view(target_fov, reason, force)
    if type(target_fov) ~= "number" then
        return ""
    end
    if not force and
        (CloUtil.stack_overlay.active or CloUtil.combat_fov.paused) then
        return ""
    end

    local channels = {}
    local _, manager = get_player_camera_manager()
    if valid_object(manager) then
        if CloUtil.write_manager_cache_pov_fov(manager, "CameraCachePrivate", target_fov) then
            channels[#channels + 1] = "CameraCachePrivate"
        end
        if CloUtil.write_manager_cache_pov_fov(manager, "LastFrameCameraCachePrivate", target_fov) then
            channels[#channels + 1] = "LastFrameCameraCachePrivate"
        end

        local view_target = get_field(manager, "ViewTarget")
        local view_pov = get_unwrapped_field(view_target, "POV")
        if view_pov ~= nil and set_field(view_pov, "FOV", target_fov) then
            channels[#channels + 1] = "ViewTarget.POV"
        end

        pcall(function()
            if manager.SetFOV ~= nil then
                manager:SetFOV(target_fov)
                channels[#channels + 1] = "SetFOV"
            end
        end)
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
    end
    if not valid_object(camera) then
        local combat = find_combat_component()
        camera = camera_from_combat(combat)
    end

    if valid_object(camera) then
        for _, field_name in ipairs({ "FieldOfView", "CurrentFOV", "DefaultFOV" }) do
            if set_field(camera, field_name, target_fov) then
                channels[#channels + 1] = "FollowCamera." .. field_name
            end
        end
    end

    if config.EnableLog and reason ~= nil and #channels > 0 and
        reason ~= "CombatPoll" and reason ~= "StackPoll" then
        append_log(
            "COMBAT FOV VIEW PUBLISH" ..
            " | Reason=" .. tostring(reason) ..
            " | Target=" .. tostring(target_fov) ..
            " | Channels=" .. table.concat(channels, ",")
        )
    end

    return table.concat(channels, ",")
end

function CloUtil.schedule_combat_fov_arm_confirm(reason)
    return
end

function CloUtil.seed_stack_modes_full_fov(target_fov, reason)
    if type(target_fov) ~= "number" then
        return 0
    end

    local wrote = CloUtil.apply_combat_fov_to_stack(target_fov, reason)

    for _, saved in pairs(saved_modes) do
        local mode = saved.mode
        if valid_object(mode) and
            not is_ability_mode(mode) and
            not CloUtil.is_transient_overlay_mode(mode) then
            cache_mode(mode)
            if set_field(mode, "DefaultFieldOfView", target_fov) then
                wrote = wrote + 1
            end
        end
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
    end
    if not valid_object(camera) then
        camera = camera_from_combat(find_combat_component())
    end

    if valid_object(camera) then
        local stack = get_field(camera, "CameraModeStack")
        if stack ~= nil then
            local depth = 0
            pcall(function()
                depth = stack:GetArrayNum()
            end)
            for index = 1, depth do
                local mode = nil
                pcall(function()
                    local entry = stack[index]
                    if entry ~= nil then
                        mode = entry.CameraMode
                    end
                end)
                if valid_object(mode) and
                    not is_ability_mode(mode) and
                    not CloUtil.is_transient_overlay_mode(mode) then
                    cache_mode(mode)
                    if set_field(mode, "DefaultFieldOfView", target_fov) then
                        wrote = wrote + 1
                    end
                end
            end
        end
    end

    return wrote
end

function CloUtil.read_live_view_fov()
    local manager_fov = CloUtil.read_manager_fov()
    local cache_fov = nil
    local _, manager = get_player_camera_manager()
    if valid_object(manager) then
        local cache = get_unwrapped_field(manager, "CameraCachePrivate")
        local pov = get_unwrapped_field(cache, "POV")
        cache_fov = tonumber(get_unwrapped_field(pov, "FOV"))
    end
    return manager_fov, cache_fov
end

function CloUtil.capture_restore_view_fov(reason)
    local cf = CloUtil.combat_fov
    if type(cf.restore_view_fov) == "number" then
        return cf.restore_view_fov
    end

    local combat_target = tonumber(config.LockOnFOV) or 110.0
    local manager_fov, cache_fov = CloUtil.read_live_view_fov()
    local candidate = nil

    if type(manager_fov) == "number" and
        math.abs(manager_fov - combat_target) > 0.05 then
        candidate = manager_fov
    elseif type(cache_fov) == "number" and
        math.abs(cache_fov - combat_target) > 0.05 then
        candidate = cache_fov
    end

    if candidate == nil then
        CloUtil.iter_combat_fov_stack_modes(function(mode, address)
            if candidate ~= nil then
                return true
            end
            local base = baseline_fov(mode)
            if type(base) == "number" and
                math.abs(base - combat_target) > 0.05 then
                candidate = base
            elseif saved_modes[address] ~= nil and
                type(saved_modes[address].fov) == "number" and
                math.abs(saved_modes[address].fov - combat_target) > 0.05 then
                candidate = saved_modes[address].fov
            end
            return true
        end)
    end

    if candidate == nil then
        local last_mode = nil
        CloUtil.iter_combat_fov_stack_modes(function(mode)
            if valid_object(mode) then
                last_mode = mode
            end
            return true
        end)
        if valid_object(last_mode) then
            candidate = CloUtil.unlock_baseline_fov(last_mode)
        end
    end

    cf.restore_view_fov = candidate or 90.0

    if config.EnableLog then
        append_log(
            "COMBAT FOV RESTORE CAPTURE" ..
            " | Reason=" .. tostring(reason) ..
            " | ManagerFOV=" .. tostring(manager_fov) ..
            " | CacheFOV=" .. tostring(cache_fov) ..
            " | RestoreFOV=" .. tostring(cf.restore_view_fov)
        )
    end

    return cf.restore_view_fov
end

function CloUtil.get_restore_view_fov()
    local cf = CloUtil.combat_fov
    if type(cf.restore_view_fov) == "number" then
        return cf.restore_view_fov
    end

    local combat_target = tonumber(config.LockOnFOV) or 110.0
    for _, saved in pairs(saved_modes) do
        if type(saved.fov) == "number" and
            math.abs(saved.fov - combat_target) > 0.05 then
            return saved.fov
        end
    end

    return 90.0
end

function CloUtil.arm_combat_fov(reason)
    if not mod_enabled or not config.FOVEnabled or not CloUtil.in_combat_context() then
        return false
    end
    if CloUtil.combat_fov.sheath_abort_rearm_pending and
        reason ~= "SheathAbortRedraw" then
        return false
    end

    CloUtil.capture_restore_view_fov(reason)

    local target = tonumber(config.LockOnFOV) or 110.0
    CloUtil.stop_combat_fov_tween(reason)

    pcall(function()
        CloUtil.warm_combat_fov_cache(reason)
    end)
    pcall(function()
        CloUtil.combat_fov_capture_from_values()
    end)

    local stack_wrote = CloUtil.seed_stack_modes_full_fov(target, reason)
    local apply_ok, apply_err = pcall(function()
        CloUtil.apply_fov_to_active_stack_top(target, reason)
    end)
    if not apply_ok and config.EnableLog then
        append_log(
            "COMBAT STACK TOP FOV ERROR" ..
            " | Reason=" .. tostring(reason) ..
            " | Error=" .. tostring(apply_err)
        )
    end
    local view_channels = CloUtil.publish_combat_fov_to_view(target, reason, true)
    local live_pov = CloUtil.read_manager_fov()
    local cache_pov = nil
    local _, manager = get_player_camera_manager()
    if valid_object(manager) then
        local cache = get_unwrapped_field(manager, "CameraCachePrivate")
        local pov = get_unwrapped_field(cache, "POV")
        cache_pov = tonumber(get_unwrapped_field(pov, "FOV"))
    end

    fov_applied = true
    CloUtil.combat_fov.direction = nil
    CloUtil.combat_fov.poll_active = false
    CloUtil.combat_fov.last_view_publish_ms = os.clock() * 1000.0

    if config.EnableLog then
        append_log(
            "COMBAT FOV ARM" ..
            " | Reason=" .. tostring(reason) ..
            " | Target=" .. tostring(target) ..
            " | StackWrote=" .. tostring(stack_wrote) ..
            " | ViewChannels=" .. tostring(view_channels) ..
            " | ManagerFOV=" .. tostring(live_pov) ..
            " | CachePOV=" .. tostring(cache_pov) ..
            " | LockActive=" .. tostring(lock_active)
        )
    end

    CloUtil.pulse_unlocked_camera_type_for_fov(reason)

    local sanity_fov = CloUtil.read_manager_fov()
    if type(sanity_fov) == "number" and sanity_fov < 50.0 then
        local restore_fov = CloUtil.get_restore_view_fov()
        if type(restore_fov) == "number" then
            CloUtil.publish_combat_fov_to_view(restore_fov, "ArmSanityFail", true)
            CloUtil.set_manager_fov(restore_fov, "ArmSanityFail", true)
        end
        if valid_object(camera_from_combat(tracked_combat)) then
            pcall(function()
                camera_from_combat(tracked_combat):SetCameraType(CAMERA_TYPE_DEFAULT)
            end)
        end
        fov_applied = false
        CloUtil.combat_fov.fov_type_pulse_done = false
        if config.EnableLog then
            append_log(
                "COMBAT FOV ARM SANITY FAIL" ..
                " | Reason=" .. tostring(reason) ..
                " | ManagerFOV=" .. tostring(sanity_fov) ..
                " | RestoreFOV=" .. tostring(restore_fov)
            )
        end
        return false
    end

    return true
end

function CloUtil.reassert_event_bypasses_cooldown(reason)
    local text = tostring(reason)
    return text == "TargetSwap" or
        text == "TargetSwapAfterDeath" or
        text == "OverlayRecovery" or
        text:find("TargetSwap", 1, true) ~= nil or
        text:find("OverlayRecovery", 1, true) ~= nil
end

function CloUtil.refresh_combat_fov_view(reason, force)
    if not mod_enabled or not config.FOVEnabled or not CloUtil.in_combat_context() then
        return false
    end

    local target = tonumber(config.LockOnFOV) or 110.0
    local cf = CloUtil.combat_fov
    local now_ms = os.clock() * 1000.0
    CloUtil.publish_combat_fov_to_view(target, reason, force == true)
    cf.last_view_publish_ms = now_ms
    fov_applied = true
    return true
end

function CloUtil.reassert_combat_fov(reason, urgent)
    if not mod_enabled or not config.FOVEnabled or not CloUtil.in_combat_context() then
        return false
    end

    local cf = CloUtil.combat_fov
    local now_ms = os.clock() * 1000.0
    local bypass = CloUtil.reassert_event_bypasses_cooldown(reason)
    local cooldown = cf.reassert_cooldown_ms or 800
    if not bypass and cf.last_reassert_ms ~= nil and
        now_ms - cf.last_reassert_ms < cooldown then
        return false
    end

    local target = tonumber(config.LockOnFOV) or 110.0
    local stack_wrote = CloUtil.seed_stack_modes_full_fov(target, reason)
    local view_channels = CloUtil.publish_combat_fov_to_view(
        target,
        reason,
        urgent == true
    )
    cf.last_stack_push_ms = now_ms
    cf.last_view_publish_ms = now_ms
    cf.last_reassert_ms = now_ms
    fov_applied = true

    if config.EnableLog then
        append_log(
            "COMBAT FOV REASSERT" ..
            " | Reason=" .. tostring(reason) ..
            " | Urgent=" .. tostring(urgent == true) ..
            " | Target=" .. tostring(target) ..
            " | StackWrote=" .. tostring(stack_wrote) ..
            " | ViewChannels=" .. tostring(view_channels) ..
            " | ManagerFOV=" .. tostring(CloUtil.read_manager_fov())
        )
    end

    return true
end

function CloUtil.schedule_combat_fov_reassert(reason)
    if not CloUtil.in_combat_context() or not config.FOVEnabled or
        type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        return
    end

    local generation = runtime_generation
    for _, delay_ms in ipairs({ 0, 300 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= runtime_generation then
                return
            end

            ExecuteInGameThread(function()
                if generation ~= runtime_generation or
                    not CloUtil.in_combat_context() or
                    not mod_enabled or
                    not config.FOVEnabled then
                    return
                end

                CloUtil.reassert_combat_fov(
                    tostring(reason) .. "@T+" .. tostring(delay_ms),
                    true
                )
            end)
        end)
    end
end

function CloUtil.apply_combat_fov_to_stack(target_fov, reason)
    if type(target_fov) ~= "number" then
        return 0
    end

    local wrote = 0
    CloUtil.iter_combat_fov_stack_modes(function(mode, address)
        if set_field(mode, "DefaultFieldOfView", target_fov) then
            wrote = wrote + 1
        end
        return true
    end)

    if wrote > 0 and reason ~= nil and config.EnableLog then
        append_log(
            "COMBAT STACK FOV" ..
            " | Reason=" .. tostring(reason) ..
            " | Target=" .. tostring(target_fov) ..
            " | Wrote=" .. tostring(wrote)
        )
    end

    return wrote
end

function CloUtil.maintain_combat_fov(reason)
    if not mod_enabled or not config.FOVEnabled then
        return 0
    end
    if not CloUtil.in_combat_context() then
        return 0
    end
    if CloUtil.is_defensive_combat_state() then
        return 0
    end
    if CloUtil.stack_overlay.active or CloUtil.combat_fov.paused then
        return 0
    end

    local cf = CloUtil.combat_fov
    if cf.sheath_abort_rearm_pending then
        return 0
    end
    local in_combat_fov = fov_applied or cf.poll_active or cf.direction == "in"
    if not in_combat_fov then
        return 0
    end

    local target = tonumber(config.LockOnFOV) or 110.0
    local now_ms = os.clock() * 1000.0
    local wrote = 0

    if fov_applied then
        local stack_interval = cf.stack_push_interval_ms or 300
        local view_interval = cf.view_publish_interval_ms or 200
        if cf.last_stack_push_ms == nil or
            now_ms - cf.last_stack_push_ms >= stack_interval then
            wrote = CloUtil.apply_combat_fov_to_stack(target, nil)
            cf.last_stack_push_ms = now_ms
        end
        if cf.last_view_publish_ms == nil or
            now_ms - cf.last_view_publish_ms >= view_interval or
            reason == "TargetSwap" or
            reason == "TargetSwapAfterDeath" or
            reason == "OverlayRecovery" then
            CloUtil.publish_combat_fov_to_view(target, reason, false)
            cf.last_view_publish_ms = now_ms
        end
    end

    return wrote
end

function CloUtil.combat_fov_capture_from_values()
    local cf = CloUtil.combat_fov
    cf.from_by_address = {}
    CloUtil.iter_combat_fov_stack_modes(function(mode, address)
        if address == nil then
            return true
        end
        local current = baseline_fov(mode)
        if current == nil and saved_modes[address] ~= nil then
            current = saved_modes[address].fov
        end
        if type(current) == "number" then
            cf.from_by_address[address] = current
        end
        return true
    end)
end

function CloUtil.combat_fov_tick()
    local cf = CloUtil.combat_fov
    local direction = cf.direction
    if direction == nil then
        return true
    end
    if cf.paused or CloUtil.stack_overlay.active then
        return false
    end

    local elapsed = (os.clock() * 1000.0) - cf.start_ms
    local raw_t = math.min(1.0, elapsed / cf.duration_ms)
    local t = CloUtil.combat_fov_smooth_t(raw_t)
    local target_lock = tonumber(config.LockOnFOV) or 110.0
    local all_done = true
    local wrote = 0
    local manager_fov = nil

    CloUtil.iter_combat_fov_stack_modes(function(mode, address)
        if address == nil then
            return true
        end

        if cf.from_by_address[address] == nil then
            local current = baseline_fov(mode)
            if current == nil and saved_modes[address] ~= nil then
                current = saved_modes[address].fov
            end
            if type(current) == "number" then
                cf.from_by_address[address] = current
            end
        end

        local from_fov = cf.from_by_address[address]
        if type(from_fov) ~= "number" then
            return true
        end

        local to_fov = from_fov
        if direction == "in" then
            to_fov = target_lock
        elseif direction == "out" then
            to_fov = CloUtil.get_restore_view_fov()
        elseif saved_modes[address] ~= nil and saved_modes[address].fov ~= nil then
            to_fov = saved_modes[address].fov
        end

        local new_fov = from_fov + (to_fov - from_fov) * t
        if set_field(mode, "DefaultFieldOfView", new_fov) then
            wrote = wrote + 1
        end
        if math.abs(new_fov - to_fov) > 0.25 then
            all_done = false
        end
        if manager_fov == nil then
            manager_fov = new_fov
        end
        return true
    end)

    if manager_fov ~= nil then
        CloUtil.set_manager_fov(manager_fov, "CombatFovTween")
    end

    if raw_t >= 1.0 then
        all_done = true
    end

    if all_done then
        fov_applied = direction == "in"
        cf.direction = nil
        cf.poll_active = false
        if direction == "in" and manager_fov ~= nil then
            CloUtil.set_manager_fov(target_lock, "CombatFovTweenDone")
        elseif direction == "out" then
            cf.last_manager_fov = nil
            local restore_fov = CloUtil.get_restore_view_fov()
            if type(restore_fov) == "number" then
                CloUtil.publish_combat_fov_to_view(
                    restore_fov,
                    "CombatExitViewRestore",
                    true
                )
                CloUtil.set_manager_fov(
                    restore_fov,
                    "CombatExitViewRestore",
                    true
                )
            end
            pcall(restore_mode_defaults)
            cf.restore_view_fov = nil
        end
        if config.EnableLog then
            append_log(
                "COMBAT FOV TWEEN DONE" ..
                " | Direction=" .. tostring(direction) ..
                " | Wrote=" .. tostring(wrote) ..
                " | FOVApplied=" .. tostring(fov_applied) ..
                " | ManagerFOV=" .. tostring(manager_fov)
            )
        end
    end

    return all_done
end

function CloUtil.combat_fov_poll(generation)
    if generation ~= CloUtil.combat_fov.generation or not CloUtil.combat_fov.poll_active then
        return
    end
    if type(ExecuteInGameThread) ~= "function" or type(ExecuteWithDelay) ~= "function" then
        return
    end

    ExecuteInGameThread(function()
        if generation ~= CloUtil.combat_fov.generation or not CloUtil.combat_fov.poll_active then
            return
        end

        local done = CloUtil.combat_fov_tick()
        if done then
            return
        end

        ExecuteWithDelay(CloUtil.combat_fov.tick_ms, function()
            CloUtil.combat_fov_poll(generation)
        end)
    end)
end

function CloUtil.warm_combat_fov_cache(reason)
    pcall(rebuild_mode_cache)

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
    end
    if not valid_object(camera) then
        local combat = find_combat_component()
        camera = camera_from_combat(combat)
    end
    if not valid_object(camera) then
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        return 0
    end

    local depth = 0
    pcall(function()
        depth = stack:GetArrayNum()
    end)
    if type(depth) ~= "number" or depth <= 0 then
        return 0
    end

    local cached = 0
    for index = 1, depth do
        local mode = nil
        pcall(function()
            local entry = stack[index]
            if entry ~= nil then
                mode = entry.CameraMode
            end
        end)
        if valid_object(mode) then
            cache_mode(mode)
            cached = cached + 1
        end
    end

    if config.EnableLog and cached > 0 then
        append_log(
            "COMBAT FOV CACHE WARM" ..
            " | Reason=" .. tostring(reason) ..
            " | StackModes=" .. tostring(cached)
        )
    end

    return cached
end

function CloUtil.start_combat_fov_tween(direction, reason)
    if not config.FOVEnabled then
        return false
    end
    if not mod_enabled then
        if direction == "in" and CloUtil.in_combat_context() then
            CloUtil.combat_fov.pending_enter = true
            if config.EnableLog then
                append_log(
                    "COMBAT FOV PENDING | Reason=" .. tostring(reason) ..
                    " | ModEnabled=false"
                )
            end
        end
        return false
    end
    if direction ~= "in" and direction ~= "out" then
        return false
    end

    local cf = CloUtil.combat_fov
    if direction == "in" then
        if CloUtil.in_combat_context() then
            return CloUtil.arm_combat_fov(reason or "TweenIn")
        end
        if fov_applied or cf.poll_active then
            if config.EnableLog then
                append_log(
                    "COMBAT FOV TWEEN SKIP" ..
                    " | Reason=" .. tostring(reason) ..
                    " | FOVApplied=" .. tostring(fov_applied) ..
                    " | PollActive=" .. tostring(cf.poll_active)
                )
            end
            return true
        end
    end

    CloUtil.combat_fov.pending_enter = false
    pcall(function()
        CloUtil.warm_combat_fov_cache(reason)
    end)

    CloUtil.stop_combat_fov_tween("restart+" .. tostring(reason))

    cf.generation = cf.generation + 1
    local generation = cf.generation
    cf.direction = direction
    cf.start_ms = os.clock() * 1000.0
    cf.paused = false
    cf.poll_active = false

    local capture_ok, capture_err = pcall(function()
        CloUtil.combat_fov_capture_from_values()
    end)
    if not capture_ok then
        cf.direction = nil
        if CloUtil.in_combat_context() then
            return CloUtil.arm_combat_fov("CaptureFallback+" .. tostring(reason))
        end
        local target = tonumber(config.LockOnFOV) or 110.0
        CloUtil.seed_stack_modes_full_fov(target, reason)
        CloUtil.publish_combat_fov_to_view(target, "CaptureFallback+" .. tostring(reason))
        fov_applied = true
        if config.EnableLog then
            append_log(
                "COMBAT FOV CAPTURE FALLBACK" ..
                " | Reason=" .. tostring(reason) ..
                " | Error=" .. tostring(capture_err) ..
                " | Target=" .. tostring(target)
            )
        end
        return true
    end

    cf.poll_active = true

    local pov_before = CloUtil.read_manager_fov()

    if config.EnableLog then
        append_log(
            "COMBAT FOV TWEEN START" ..
            " | Direction=" .. tostring(direction) ..
            " | Reason=" .. tostring(reason) ..
            " | TargetFOV=" .. tostring(config.LockOnFOV) ..
            " | DurationMs=" .. tostring(cf.duration_ms) ..
            " | ManagerFOVBefore=" .. tostring(pov_before)
        )
    end

    CloUtil.combat_fov_tick()

    if config.EnableLog then
        append_log(
            "COMBAT FOV POV PUSH" ..
            " | Reason=" .. tostring(reason) ..
            " | ManagerFOVBefore=" .. tostring(pov_before) ..
            " | ManagerFOVAfter=" .. tostring(CloUtil.read_manager_fov()) ..
            " | PollActive=" .. tostring(cf.poll_active)
        )
    end

    if cf.poll_active then
        CloUtil.combat_fov_poll(generation)
    end
    return true
end

function CloUtil.apply_combat_fov_to_mode(mode, reason)
    if not mod_enabled or not config.FOVEnabled or not valid_object(mode) then
        return false
    end
    if is_ability_mode(mode) or CloUtil.is_transient_overlay_mode(mode) then
        return false
    end
    if not fov_applied and CloUtil.combat_fov.direction ~= "in" then
        return false
    end

    cache_mode(mode)
    local target = tonumber(config.LockOnFOV)
    if target == nil then
        return false
    end

    if CloUtil.combat_fov.direction == "in" then
        local address = object_address(mode)
        local cf = CloUtil.combat_fov
        if address ~= nil and cf.from_by_address[address] == nil then
            local current = baseline_fov(mode)
            cf.from_by_address[address] = current or target
        end
        local elapsed = (os.clock() * 1000.0) - cf.start_ms
        local raw_t = math.min(1.0, elapsed / cf.duration_ms)
        local t = CloUtil.combat_fov_smooth_t(raw_t)
        local from_fov = address and cf.from_by_address[address]
        if type(from_fov) == "number" then
            target = from_fov + (target - from_fov) * t
        end
    end

    return set_field(mode, "DefaultFieldOfView", target)
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
    combat_mode_last = nil
    combat_state_last = nil

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
        local cf = CloUtil.combat_fov
        if config.EnableLog and not cf.resolve_miss_logged then
            cf.resolve_miss_logged = true
            append_log("COMBAT COMPONENT MISSING | CombatPollSkipped")
        end
        return
    end
    CloUtil.combat_fov.resolve_miss_logged = false

    if not combat_component_name_logged then
        append_log(
            "COMBAT COMPONENT | " .. safe_full_name(component) ..
            " | Address=" .. tostring(object_address(component))
        )
        combat_component_name_logged = true
    end

    local state_text = readable_runtime_value(get_field(component, "CurrentState"))
    CloUtil.combat_fov.last_state = tonumber(state_text)
    local mode_value = unwrap_value(get_field(component, "CurrentCombatMode"))
    local mode_text = readable_runtime_value(mode_value)
    local mode_number = tonumber(mode_value)

    local cf = CloUtil.combat_fov
    local previous_mode_number = combat_mode_last
    local effective_mode = mode_number
    local now_ms = os.clock() * 1000.0
    local confirm_ms = cf.exit_confirm_ms or 2000
    local held_ms = 0
    local sheath_abort_handled = false

    -- Enemy death can set CurrentCombatMode=0 while still in a fight.
    -- Require a wall-clock hold so two polls in the same second cannot burn debounce.
    if mode_number == 0 and previous_mode_number ~= nil and previous_mode_number ~= 0 then
        if cf.exit_zero_since_ms == nil then
            cf.exit_zero_since_ms = now_ms
            if config.EnableLog then
                append_log(
                    "COMBAT MODE FLICKER" ..
                    " | State=" .. tostring(state_text) ..
                    " | HeldMode=" .. tostring(previous_mode_number) ..
                    " | ConfirmMs=" .. tostring(confirm_ms)
                )
            end
        end
        held_ms = now_ms - cf.exit_zero_since_ms
        if held_ms < confirm_ms then
            effective_mode = previous_mode_number
        end
    else
        if cf.exit_zero_since_ms ~= nil and
            mode_number ~= nil and mode_number ~= 0 and
            cf.session_active and not lock_active then
            if config.EnableLog then
                append_log(
                    "COMBAT SHEATH ABORT REDRAW" ..
                    " | Mode=" .. tostring(mode_number) ..
                    " | FOVApplied=" .. tostring(fov_applied)
                )
            end
            CloUtil.handle_sheath_abort_redraw()
            sheath_abort_handled = true
        end
        cf.exit_zero_since_ms = nil
        cf.exit_pending = 0
        held_ms = 0
    end

    if effective_mode ~= nil and effective_mode ~= 0 and not cf.session_active then
        append_log(
            "COMBAT ENTER DETECTED | PreviousCombatMode=" ..
            tostring(previous_mode_number) ..
            " | CurrentCombatMode=" .. tostring(effective_mode) ..
            " | LockActive=" .. tostring(lock_active)
        )
        CloUtil.begin_combat_session(component, "CombatEnter", true)
    elseif not sheath_abort_handled and
        effective_mode ~= nil and effective_mode ~= 0 and
        cf.session_active and mod_enabled and config.FOVEnabled and
        not cf.sheath_abort_rearm_pending and
        not fov_applied and not cf.poll_active then
        local last_ms = cf.last_catchup_ms
        if last_ms == nil or (now_ms - last_ms) >= (cf.catchup_cooldown_ms or 2000) then
            cf.last_catchup_ms = now_ms
            CloUtil.bootstrap_combat_fov("CombatEnterCatchup")
        end
    elseif not sheath_abort_handled and
        cf.session_active and mod_enabled and config.FOVEnabled and
        not cf.sheath_abort_rearm_pending and
        not fov_applied and not cf.poll_active then
        CloUtil.bootstrap_combat_fov("CombatPoll")
    end

    if previous_mode_number ~= nil and
        previous_mode_number ~= 0 and
        mode_number == 0 and
        held_ms >= confirm_ms and
        cf.session_active then

        combat_mode_last = 0

        append_log(
            "COMBAT EXIT DETECTED | PreviousCombatMode=" ..
            tostring(previous_mode_number) ..
            " | CurrentCombatMode=0" ..
            " | HeldMs=" .. tostring(math.floor(held_ms)) ..
            " | LockActive=" .. tostring(lock_active) ..
            " | FOVApplied=" .. tostring(fov_applied) ..
            " | SavedCameraType=" .. tostring(previous_camera_type)
        )

        CloUtil.end_combat_session(component, "CombatExit")
    end

    if combat_state_last == nil or state_text ~= combat_state_last then
        append_log(
            "COMBAT STATE CHANGED | CurrentState=" .. state_text ..
            " | CurrentCombatMode=" .. mode_text
        )
        combat_state_last = state_text
    elseif effective_mode ~= nil and
        (combat_mode_last == nil or effective_mode ~= combat_mode_last) then
        append_log(
            "COMBAT MODE CHANGED | CurrentState=" .. state_text ..
            " | CurrentCombatMode=" .. mode_text
        )
    end

    if effective_mode ~= nil then
        combat_mode_last = effective_mode
    elseif mode_number == 0 and held_ms >= confirm_ms then
        combat_mode_last = 0
    end

    if cf.session_active and mod_enabled then
        if cf.lock_writes_deferred and lock_active and
            not CloUtil.is_defensive_combat_state() then
            CloUtil.apply_deferred_lock_writes("CombatPoll")
        end
        if not cf.sheath_abort_rearm_pending and
            cf.fov_type_pulse_pending and not lock_active then
            CloUtil.pulse_unlocked_camera_type_for_fov("CombatPoll")
        end
        if config.FOVEnabled and not cf.sheath_abort_rearm_pending then
            CloUtil.maintain_combat_fov("CombatPoll")
        end
    elseif lock_active and not cf.session_active then
        append_log(
            "COMBAT SESSION STALE LOCK" ..
            " | Action=ForceLockOff"
        )
        pcall(function()
            apply_lock_fov(component, false)
        end)
        CloUtil.restore_combat_offset_z("StaleLockOutsideSession")
        CloUtil.stop_combat_fov_tween("StaleLockOutsideSession")
        fov_applied = false
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
    combat_component_name_logged = false
    combat_state_poll()
end

local function stop_combat_state_poll()
    combat_state_poll_generation = combat_state_poll_generation + 1
    combat_state_poll_active = false
    combat_state_last = nil
    combat_mode_last = nil
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

-- Non-Lock-On camera transform test state.
-- Used only to probe direct FollowCamera transform controls.
local test_camera_enabled = false
local test_camera_base = nil
local test_camera_values = {
    X = 0.0,
    Y = 0.0,
    Z = 0.0,
    Pitch = 0.0,
    Yaw = 0.0,
    Roll = 0.0,
}

-- Lock-On camera test state.
-- v1.1.28 tests CameraLocationOffsetDuringTargeting.Z only. Rotation values
-- and CameraOffsets.TargetOffset remain stored/read-only for reference.
local lock_camera_test_enabled = false
local lock_camera_test_cache = {}
local lock_pitch_test_requested = false
local lock_follow_rotation_baseline = nil
local lock_follow_rotation_camera = nil
local follow_rotation_probe_generation = 0
local LOCK_ROTATION_CANDIDATES = {
    "CameraRotationOffsetDuringTargeting",
    "RotationOffsetDuringTargeting",
    "CameraRotation",
    "RelativeRotation",
    "Rotation",
    "RelativeCameraRotation",
    "CameraRotationOffset",
}

local function find_test_camera()
    if lock_active then
        return nil
    end

    local combat = find_combat_component()
    if not valid_object(combat) then
        return nil
    end

    local camera = camera_from_combat(combat)
    if valid_object(camera) then
        return camera
    end

    return nil
end

local function read_test_camera_base(camera)
    if not valid_object(camera) then
        return false
    end

    local location = get_field(camera, "RelativeLocation")
    local rotation = get_field(camera, "RelativeRotation")
    if location == nil and rotation == nil then
        return false
    end

    local base = {}

    if location ~= nil then
        base.X = tonumber(get_field(location, "X")) or 0.0
        base.Y = tonumber(get_field(location, "Y")) or 0.0
        base.Z = tonumber(get_field(location, "Z")) or 0.0
    end

    if rotation ~= nil then
        base.Pitch = tonumber(get_field(rotation, "Pitch")) or 0.0
        base.Yaw = tonumber(get_field(rotation, "Yaw")) or 0.0
        base.Roll = tonumber(get_field(rotation, "Roll")) or 0.0
    end

    base.camera = camera
    test_camera_base = base
    return true
end

local function apply_test_camera()
    if not mod_enabled or lock_active or not test_camera_enabled then
        return false
    end

    local camera = find_test_camera()
    if not valid_object(camera) then
        return false
    end

    if test_camera_base == nil or not valid_object(test_camera_base.camera) or
        object_address(test_camera_base.camera) ~= object_address(camera) then
        if not read_test_camera_base(camera) then
            return false
        end
    end

    local location = get_field(camera, "RelativeLocation")
    local rotation = get_field(camera, "RelativeRotation")
    local ok = true

    if location ~= nil then
        ok = pcall(function() location.X = test_camera_base.X + test_camera_values.X end) and ok
        ok = pcall(function() location.Y = test_camera_base.Y + test_camera_values.Y end) and ok
        ok = pcall(function() location.Z = test_camera_base.Z + test_camera_values.Z end) and ok
    end

    if rotation ~= nil then
        ok = pcall(function() rotation.Pitch = test_camera_base.Pitch + test_camera_values.Pitch end) and ok
        ok = pcall(function() rotation.Yaw = test_camera_base.Yaw + test_camera_values.Yaw end) and ok
        ok = pcall(function() rotation.Roll = test_camera_base.Roll + test_camera_values.Roll end) and ok
    end

    append_log(
        "CAMERA TEST APPLY" ..
        " | X=" .. tostring(test_camera_values.X) ..
        " | Y=" .. tostring(test_camera_values.Y) ..
        " | Z=" .. tostring(test_camera_values.Z) ..
        " | Pitch=" .. tostring(test_camera_values.Pitch) ..
        " | Yaw=" .. tostring(test_camera_values.Yaw) ..
        " | Roll=" .. tostring(test_camera_values.Roll) ..
        " | Success=" .. tostring(ok)
    )

    return ok
end

local function set_test_camera_enabled(enabled)
    enabled = enabled == true

    if enabled then
        if not mod_enabled then
            append_log("CAMERA TEST ENABLE BLOCKED | Master mod switch is OFF")
            return false
        end

        local camera = find_test_camera()
        if not valid_object(camera) or not read_test_camera_base(camera) then
            append_log("CAMERA TEST ENABLE FAILED | FollowCamera unavailable")
            return false
        end

        test_camera_enabled = true
        apply_test_camera()
        append_log("CAMERA TEST ENABLED")
        return true
    end

    local camera = find_test_camera()
    if valid_object(camera) and test_camera_base ~= nil then
        local location = get_field(camera, "RelativeLocation")
        local rotation = get_field(camera, "RelativeRotation")

        if location ~= nil then
            pcall(function() location.X = test_camera_base.X end)
            pcall(function() location.Y = test_camera_base.Y end)
            pcall(function() location.Z = test_camera_base.Z end)
        end

        if rotation ~= nil then
            pcall(function() rotation.Pitch = test_camera_base.Pitch end)
            pcall(function() rotation.Yaw = test_camera_base.Yaw end)
            pcall(function() rotation.Roll = test_camera_base.Roll end)
        end
    end

    test_camera_enabled = false
    test_camera_base = nil
    append_log("CAMERA TEST DISABLED")
    return true
end

local function find_lock_rotation_property(mode)
    if not valid_object(mode) then
        return nil, nil
    end

    for _, field_name in ipairs(LOCK_ROTATION_CANDIDATES) do
        local value = get_field(mode, field_name)
        if value ~= nil then
            -- A TrivialObject wrapper is not proof that this is a usable
            -- FRotator. Only accept a candidate with numeric components.
            local pitch = tonumber(get_field(value, "Pitch"))
            if pitch ~= nil then
                return value, field_name
            end
        end
    end

    return nil, nil
end

-- Return the highest non-ability CameraMode currently present in the stack.
-- The stack's top entry is the best current approximation of the mode that is
-- producing the visible Lock-On camera. Writing every stack entry can produce
-- no visible result because inactive entries are not consumed, or because a
-- later mode overwrites them.
local function find_active_lock_camera_mode(camera)
    if not valid_object(camera) then
        return nil, nil, 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        return nil, nil, 0
    end

    local depth = 0
    local depth_ok = pcall(function()
        depth = stack:GetArrayNum()
    end)

    if not depth_ok or type(depth) ~= "number" or depth <= 0 then
        return nil, nil, depth
    end

    for index = depth, 1, -1 do
        local entry = nil
        local entry_ok = pcall(function()
            entry = stack[index]
        end)

        if entry_ok and entry ~= nil then
            local mode = nil
            pcall(function()
                mode = entry.CameraMode
            end)

            if valid_object(mode) and
                not is_ability_mode(mode) and
                not CloUtil.is_transient_overlay_mode(mode) then
                return mode, index, depth
            end
        end
    end

    return nil, nil, depth
end

local function pitch_probe_component_text(label, value, component_names)
    value = unwrap_value(value)
    if value == nil then
        return label .. "=<nil>"
    end

    local parts = {
        label .. "Type=" .. tostring(type(value)),
        label .. "Value=" .. tostring(value),
    }

    for _, component_name in ipairs(component_names) do
        local raw = unwrap_value(get_field(value, component_name))
        local nested = unwrap_value(raw)
        local numeric = tonumber(nested)
        if numeric == nil then
            numeric = tonumber(raw)
        end
        table.insert(
            parts,
            label .. "." .. component_name .. "Raw=" .. tostring(raw)
        )
        table.insert(
            parts,
            label .. "." .. component_name .. "Numeric=" .. tostring(numeric)
        )
    end

    return table.concat(parts, " | ")
end

local function readable_probe_number(value)
    local current = unwrap_value(value)
    local numeric = tonumber(current)
    if numeric ~= nil then
        return numeric
    end

    if current ~= nil and type(current) == "userdata" then
        local nested = unwrap_value(current)
        numeric = tonumber(nested)
        if numeric ~= nil then
            return numeric
        end
    end

    return nil
end

local function format_probe_scalar(value)
    local numeric = readable_probe_number(value)
    if numeric ~= nil then
        return tostring(numeric)
    end
    if value == nil then
        return "<nil>"
    end
    return tostring(unwrap_value(value))
end

local function log_probe_scalar_fields(reason, owner_label, owner, field_names)
    if owner == nil then
        return
    end

    for _, field_name in ipairs(field_names) do
        local raw = get_field(owner, field_name)
        local numeric = readable_probe_number(raw)
        -- Skip missing/false-positive TrivialObject wrappers; they crash/spam UE4SS.
        if numeric ~= nil then
            append_log(
                "PITCH PROBE SCALAR" ..
                " | Reason=" .. tostring(reason) ..
                " | Owner=" .. tostring(owner_label) ..
                " | Field=" .. tostring(field_name) ..
                " | Value=" .. tostring(numeric)
            )
        end
    end
end

local function log_probe_vector_fields(reason, owner_label, owner, field_names)
    if owner == nil then
        return
    end

    for _, field_name in ipairs(field_names) do
        local raw = get_field(owner, field_name)
        if raw ~= nil then
            local unwrapped = unwrap_value(raw)
            local x = readable_probe_number(get_field(unwrapped, "X"))
            local y = readable_probe_number(get_field(unwrapped, "Y"))
            local z = readable_probe_number(get_field(unwrapped, "Z"))
            if x ~= nil or y ~= nil or z ~= nil then
                append_log(
                    "PITCH PROBE VECTOR" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Owner=" .. tostring(owner_label) ..
                    " | Field=" .. tostring(field_name) ..
                    " | X=" .. tostring(x) ..
                    " | Y=" .. tostring(y) ..
                    " | Z=" .. tostring(z)
                )
            end
        end
    end
end

local function log_mode_known_offsets(reason, owner_label, mode)
    if not valid_object(mode) then
        return
    end

    local targeting = get_field(mode, "CameraLocationOffsetDuringTargeting")
    local ox = readable_probe_number(get_field(targeting, "X"))
    local oy = readable_probe_number(get_field(targeting, "Y"))
    local oz = readable_probe_number(get_field(targeting, "Z"))
    append_log(
        "PITCH PROBE KNOWN OFFSET" ..
        " | Reason=" .. tostring(reason) ..
        " | Owner=" .. tostring(owner_label) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | FOV=" .. tostring(readable_probe_number(get_field(mode, "DefaultFieldOfView"))) ..
        " | TargetingOffset.X=" .. tostring(ox) ..
        " | TargetingOffset.Y=" .. tostring(oy) ..
        " | TargetingOffset.Z=" .. tostring(oz)
    )

    local camera_offsets = get_unwrapped_field(mode, "CameraOffsets")
    if camera_offsets == nil then
        return
    end

    pcall(function()
        camera_offsets:ForEach(function(a, b, c)
            local key = unwrap_value(a)
            local value = unwrap_value(b)
            if c ~= nil and tonumber(key) == nil then
                key = unwrap_value(b)
                value = unwrap_value(c)
            end
            if value == nil then
                return
            end

            local target = get_unwrapped_field(value, "TargetOffset")
            append_log(
                "PITCH PROBE KNOWN CAMERA OFFSET" ..
                " | Reason=" .. tostring(reason) ..
                " | Owner=" .. tostring(owner_label) ..
                " | Key=" .. tostring(tonumber(key) or key) ..
                " | PivotZOffset=" .. tostring(readable_probe_number(get_unwrapped_field(value, "PivotZOffset"))) ..
                " | UsePitchCurves=" .. tostring(get_unwrapped_field(value, "bUseOffsetPitchCurves")) ..
                " | TargetOffset.X=" .. tostring(readable_probe_number(get_unwrapped_field(target, "X"))) ..
                " | TargetOffset.Y=" .. tostring(readable_probe_number(get_unwrapped_field(target, "Y"))) ..
                " | TargetOffset.Z=" .. tostring(readable_probe_number(get_unwrapped_field(target, "Z")))
            )
        end)
    end)
end

local function log_probe_actor_location(reason, label, actor)
    if not valid_object(actor) then
        return nil, nil, nil
    end

    local location = nil
    pcall(function()
        location = actor:K2_GetActorLocation()
    end)
    if location == nil then
        pcall(function()
            location = actor:GetActorLocation()
        end)
    end

    local x = readable_probe_number(get_field(location, "X"))
    local y = readable_probe_number(get_field(location, "Y"))
    local z = readable_probe_number(get_field(location, "Z"))
    if x == nil and y == nil and z == nil then
        return nil, nil, nil
    end

    append_log(
        "PITCH PROBE ACTOR LOCATION" ..
        " | Reason=" .. tostring(reason) ..
        " | Label=" .. tostring(label) ..
        " | Actor=" .. safe_full_name(actor) ..
        " | X=" .. tostring(x) ..
        " | Y=" .. tostring(y) ..
        " | Z=" .. tostring(z)
    )

    return x, y, z
end

local function log_lock_target_height_probe(reason, camera)
    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end
    if not valid_object(combat) then
        return
    end

    local owner = nil
    pcall(function()
        owner = combat:GetOwner()
    end)
    local _, _, owner_z = log_probe_actor_location(reason, "PlayerOwner", owner)

    for _, field_name in ipairs(LOCK_TARGET_FIELD_CANDIDATES) do
        local target = unwrap_value(get_field(combat, field_name))
        if valid_object(target) then
            local _, _, target_z = log_probe_actor_location(reason, field_name, target)
            if owner_z ~= nil and target_z ~= nil then
                append_log(
                    "PITCH PROBE HEIGHT DELTA" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Source=" .. tostring(field_name) ..
                    " | OwnerZ=" .. tostring(owner_z) ..
                    " | TargetZ=" .. tostring(target_z) ..
                    " | OwnerMinusTargetZ=" .. tostring(owner_z - target_z)
                )
            end
            break
        end
    end

    if valid_object(camera) then
        local relative = get_field(camera, "RelativeLocation")
        local rx = readable_probe_number(get_field(relative, "X"))
        local ry = readable_probe_number(get_field(relative, "Y"))
        local rz = readable_probe_number(get_field(relative, "Z"))
        if rx ~= nil or ry ~= nil or rz ~= nil then
            append_log(
                "PITCH PROBE FOLLOW CAMERA LOCATION" ..
                " | Reason=" .. tostring(reason) ..
                " | RelativeLocation.X=" .. tostring(rx) ..
                " | RelativeLocation.Y=" .. tostring(ry) ..
                " | RelativeLocation.Z=" .. tostring(rz)
            )
        end
    end
end

-- Read-only diagnostics for finding the real Lock-On pitch control.
local log_pitch_source_diagnostics
local log_pitch_probe_full

-- Hot-path probe: known-safe fields only. Used by LockOn/Off and PageUp/Down.
local function log_pitch_probe(reason)
    if not lock_active then
        append_log(
            "PITCH PROBE SKIPPED | Reason=" .. tostring(reason) ..
            " | LockActive=false"
        )
        return false
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        append_log(
            "PITCH PROBE FAILED | Reason=" .. tostring(reason) ..
            " | CameraUnavailable=true"
        )
        return false
    end

    local mode, index, depth = find_active_lock_camera_mode(camera)
    local rotation = get_field(camera, "RelativeRotation")
    append_log(
        "PITCH PROBE LIGHT" ..
        " | Reason=" .. tostring(reason) ..
        " | StackDepth=" .. tostring(depth) ..
        " | ActiveIndex=" .. tostring(index) ..
        " | Pitch=" .. tostring(readable_probe_number(get_field(rotation, "Pitch"))) ..
        " | Yaw=" .. tostring(readable_probe_number(get_field(rotation, "Yaw"))) ..
        " | Roll=" .. tostring(readable_probe_number(get_field(rotation, "Roll"))) ..
        " | Mode=" .. safe_full_name(mode)
    )

    local stack = get_field(camera, "CameraModeStack")
    if stack ~= nil then
        local stack_depth = 0
        local depth_ok = pcall(function()
            stack_depth = stack:GetArrayNum()
        end)
        if depth_ok and type(stack_depth) == "number" then
            for stack_index = 1, stack_depth do
                local entry = nil
                pcall(function()
                    entry = stack[stack_index]
                end)
                local stack_mode = nil
                if entry ~= nil then
                    pcall(function()
                        stack_mode = entry.CameraMode
                    end)
                end
                if valid_object(stack_mode) then
                    log_mode_known_offsets(
                        reason,
                        "Stack[" .. tostring(stack_index) .. "]",
                        stack_mode
                    )
                end
            end
        end
    elseif valid_object(mode) then
        log_mode_known_offsets(reason, "ActiveMode", mode)
    end

    return true
end

local function log_pitch_candidate_wrappers(reason, label, owner)
    for _, field_name in ipairs(PITCH_SOURCE_CANDIDATES) do
        local raw = get_field(owner, field_name)
        local unwrapped = unwrap_value(raw)
        local pitch = readable_probe_number(get_field(unwrapped, "Pitch"))
        local yaw = readable_probe_number(get_field(unwrapped, "Yaw"))
        local roll = readable_probe_number(get_field(unwrapped, "Roll"))
        if pitch ~= nil or yaw ~= nil or roll ~= nil then
            append_log(
                "PITCH CANDIDATE DIAGNOSTIC" ..
                " | Reason=" .. tostring(reason) ..
                " | Owner=" .. tostring(label) ..
                " | Field=" .. tostring(field_name) ..
                " | Pitch=" .. tostring(pitch) ..
                " | Yaw=" .. tostring(yaw) ..
                " | Roll=" .. tostring(roll)
            )
        end
    end
end

-- Forward declaration: assigned later with the camera-chain helpers.
local schedule_camera_chain_probe

log_pitch_source_diagnostics = function(reason, camera, mode)
    if valid_object(mode) then
        log_pitch_candidate_wrappers(reason, "Mode", mode)
    end
end

log_pitch_probe_full = function(reason)
    if not lock_active then
        append_log(
            "PITCH PROBE FULL SKIPPED | Reason=" .. tostring(reason) ..
            " | LockActive=false"
        )
        return false
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        append_log("PITCH PROBE FULL FAILED | CameraUnavailable=true")
        return false
    end

    local mode, index, depth = find_active_lock_camera_mode(camera)
    append_log(
        "PITCH PROBE FULL BEGIN" ..
        " | Reason=" .. tostring(reason) ..
        " | StackDepth=" .. tostring(depth) ..
        " | ActiveIndex=" .. tostring(index) ..
        " | Mode=" .. safe_full_name(mode)
    )

    log_pitch_probe(reason)
    log_pitch_source_diagnostics(reason, camera, mode)
    log_probe_scalar_fields(reason, "Mode", mode, PITCH_SCALAR_CANDIDATES)
    log_probe_vector_fields(reason, "Mode", mode, LOCATION_OFFSET_CANDIDATES)
    log_probe_vector_fields(reason, "Camera", camera, { "RelativeLocation" })
    log_lock_target_height_probe(reason, camera)

    if type(schedule_camera_chain_probe) == "function" then
        schedule_camera_chain_probe(reason)
    end

    append_log("PITCH PROBE FULL END | ReadOnly=true | Expanded=v1.1.33")
    return true
end

local function log_master_transition_snapshot(reason)
    if not lock_active then
        append_log(
            "MASTER TRANSITION SNAPSHOT" ..
            " | Reason=" .. tostring(reason) ..
            " | LockActive=false"
        )
        return false
    end

    -- Ultra-light: active mode only, no CameraOffsets ForEach / stack walks.
    -- Those walks crashed during PageDown/PageUp in v1.1.33.
    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    local mode = select(1, find_active_lock_camera_mode(camera))
    local pitch = nil
    if valid_object(camera) then
        local rotation = get_field(camera, "RelativeRotation")
        pitch = readable_probe_number(get_field(rotation, "Pitch"))
    end

    local ox, oy, oz, fov = nil, nil, nil, nil
    if valid_object(mode) then
        fov = readable_probe_number(get_field(mode, "DefaultFieldOfView"))
        local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
        ox = readable_probe_number(get_field(offset, "X"))
        oy = readable_probe_number(get_field(offset, "Y"))
        oz = readable_probe_number(get_field(offset, "Z"))
    end

    append_log(
        "MASTER TRANSITION SNAPSHOT" ..
        " | Reason=" .. tostring(reason) ..
        " | Pitch=" .. tostring(pitch) ..
        " | FOV=" .. tostring(fov) ..
        " | TargetingOffset=" .. tostring(ox) .. "," .. tostring(oy) .. "," .. tostring(oz) ..
        " | Mode=" .. safe_full_name(mode)
    )
    return true
end

local function log_pitch_monitor_sample(generation, sample_index, elapsed_ms)
    if generation ~= pitch_monitor_generation or
        not pitch_monitor_active or
        not lock_active then
        return false
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    local pitch = nil
    local yaw = nil
    local roll = nil
    local mode, index, depth = nil, nil, nil
    if valid_object(camera) then
        mode, index, depth = find_active_lock_camera_mode(camera)
        local rotation = get_unwrapped_field(camera, "RelativeRotation")
        pitch = tonumber(get_unwrapped_field(rotation, "Pitch"))
        yaw = tonumber(get_unwrapped_field(rotation, "Yaw"))
        roll = tonumber(get_unwrapped_field(rotation, "Roll"))
    end

    append_log(
        "PITCH MONITOR SAMPLE" ..
        " | Sample=" .. tostring(sample_index) ..
        " | ElapsedMs=" .. tostring(elapsed_ms) ..
        " | StackDepth=" .. tostring(depth) ..
        " | ActiveIndex=" .. tostring(index) ..
        " | Mode=" .. (valid_object(mode) and safe_full_name(mode) or "Unavailable") ..
        " | Camera=" .. (valid_object(camera) and safe_full_name(camera) or "Unavailable") ..
        " | Pitch=" .. tostring(pitch) ..
        " | Yaw=" .. tostring(yaw) ..
        " | Roll=" .. tostring(roll) ..
        " | ReadOnly=true"
    )

    return true
end

stop_pitch_monitor = function(reason)
    pitch_monitor_generation = pitch_monitor_generation + 1
    pitch_monitor_active = false
    append_log("PITCH MONITOR STOP | Reason=" .. tostring(reason))
end

start_pitch_monitor = function()
    if type(ExecuteWithDelay) ~= "function" then
        append_log("PITCH MONITOR ERROR: timer API unavailable.")
        return false
    end

    pitch_monitor_generation = pitch_monitor_generation + 1
    local generation = pitch_monitor_generation
    pitch_monitor_active = true
    local sample_index = 0
    local max_samples = math.floor(PITCH_MONITOR_DURATION_MS / PITCH_MONITOR_INTERVAL_MS)

    append_log(
        "PITCH MONITOR BEGIN" ..
        " | IntervalMs=" .. tostring(PITCH_MONITOR_INTERVAL_MS) ..
        " | DurationMs=" .. tostring(PITCH_MONITOR_DURATION_MS) ..
        " | MaxSamples=" .. tostring(max_samples) ..
        " | ReadOnly=true"
    )

    local function schedule_next()
        if generation ~= pitch_monitor_generation or
            not pitch_monitor_active or
            not lock_active or
            sample_index >= max_samples then
            if generation == pitch_monitor_generation then
                pitch_monitor_active = false
                append_log("PITCH MONITOR END | Samples=" .. tostring(sample_index))
            end
            return
        end

        ExecuteWithDelay(PITCH_MONITOR_INTERVAL_MS, function()
            if generation ~= pitch_monitor_generation or
                not pitch_monitor_active or
                not lock_active then
                return
            end

            sample_index = sample_index + 1
            log_pitch_monitor_sample(
                generation,
                sample_index,
                sample_index * PITCH_MONITOR_INTERVAL_MS
            )
            schedule_next()
        end)
    end

    schedule_next()
    return true
end

local function capture_lock_camera_test_baseline(mode)
    if not valid_object(mode) then
        return nil
    end

    local address = object_address(mode)
    if address == nil then
        return nil
    end

    local cached = lock_camera_test_cache[address]
    if cached ~= nil and valid_object(cached.mode) then
        return cached
    end

    cached = {
        mode = mode,
        rotation = nil,
    }

    local rotation, rotation_field = find_lock_rotation_property(mode)
    if rotation ~= nil then
        cached.rotation = {
            field_name = rotation_field,
            Pitch = tonumber(get_field(rotation, "Pitch")) or 0.0,
            Yaw = tonumber(get_field(rotation, "Yaw")) or 0.0,
            Roll = tonumber(get_field(rotation, "Roll")) or 0.0,
        }
    end

    lock_camera_test_cache[address] = cached
    return cached
end

local function capture_lock_follow_rotation_baseline(camera)
    if not valid_object(camera) then
        return nil
    end

    local address = object_address(camera)
    if address == nil then
        return nil
    end

    if lock_follow_rotation_baseline ~= nil and
        valid_object(lock_follow_rotation_camera) and
        object_address(lock_follow_rotation_camera) == address then
        return lock_follow_rotation_baseline
    end

    local rotation = get_field(camera, "RelativeRotation")
    local pitch = tonumber(get_field(rotation, "Pitch"))
    if pitch == nil then
        return nil
    end

    lock_follow_rotation_camera = camera
    lock_follow_rotation_baseline = {
        camera = camera,
        field_name = "RelativeRotation",
        Pitch = pitch,
        Yaw = tonumber(get_field(rotation, "Yaw")) or 0.0,
        Roll = tonumber(get_field(rotation, "Roll")) or 0.0,
    }
    return lock_follow_rotation_baseline
end

local function read_fresh_follow_pitch(camera)
    if not valid_object(camera) then
        return nil, nil, nil
    end

    local fresh_rotation = get_field(camera, "RelativeRotation")
    return tonumber(get_unwrapped_field(fresh_rotation, "Pitch")),
        tonumber(get_unwrapped_field(fresh_rotation, "Yaw")),
        tonumber(get_unwrapped_field(fresh_rotation, "Roll"))
end

local function schedule_follow_rotation_readback(camera, reason, target_pitch)
    follow_rotation_probe_generation = follow_rotation_probe_generation + 1
    local generation = follow_rotation_probe_generation

    if type(ExecuteWithDelay) ~= "function" then
        append_log(
            "LOCK FOLLOW PITCH FRESH READBACK ERROR" ..
            " | Reason=" .. tostring(reason) ..
            " | TimerUnavailable=true"
        )
        return
    end

    for _, delay_ms in ipairs({ 10, 50, 100 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= follow_rotation_probe_generation or
                not lock_active or
                not valid_object(camera) then
                return
            end

            local pitch, yaw, roll = read_fresh_follow_pitch(camera)
            append_log(
                "LOCK FOLLOW PITCH FRESH READBACK" ..
                " | Reason=" .. tostring(reason) ..
                " | DelayMs=" .. tostring(delay_ms) ..
                " | Target=" .. tostring(target_pitch) ..
                " | FreshPitch=" .. tostring(pitch) ..
                " | FreshYaw=" .. tostring(yaw) ..
                " | FreshRoll=" .. tostring(roll) ..
                " | Delta=" .. tostring(pitch ~= nil and target_pitch ~= nil and pitch - target_pitch or nil)
            )
        end)
    end
end

local function apply_lock_camera_test(reason)
    if not mod_enabled or not lock_active or not lock_camera_test_enabled then
        return false, 0
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    if not valid_object(camera) then
        append_log("LOCK TEST APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return false, 0
    end

    local mode, index, depth = find_active_lock_camera_mode(camera)
    local mode_name = valid_object(mode) and safe_full_name(mode) or "Unavailable"
    local baseline = capture_lock_follow_rotation_baseline(camera)
    local changed = 0
    local rotation = get_field(camera, "RelativeRotation")
    local before_pitch = tonumber(get_field(rotation, "Pitch"))

    if baseline ~= nil and before_pitch ~= nil and rotation ~= nil then
        local target_pitch = baseline.Pitch + test_camera_values.Pitch
        local nested_write_ok = pcall(function()
            rotation.Pitch = target_pitch
        end)
        local struct_write_ok = pcall(function()
            camera.RelativeRotation = rotation
        end)
        local after_pitch = tonumber(get_unwrapped_field(rotation, "Pitch"))
        local fresh_pitch = read_fresh_follow_pitch(camera)
        local readback_ok = fresh_pitch ~= nil and
            math.abs(fresh_pitch - target_pitch) < 0.001

        append_log(
            "LOCK TEST FOLLOW PITCH" ..
            " | Reason=" .. tostring(reason) ..
            " | Index=" .. tostring(index) ..
            " | Mode=" .. mode_name ..
            " | Property=FollowCamera.RelativeRotation.Pitch" ..
            " | Camera=" .. safe_full_name(camera) ..
            " | Before=" .. tostring(before_pitch) ..
            " | Offset=" .. tostring(test_camera_values.Pitch) ..
            " | Target=" .. tostring(target_pitch) ..
            " | NestedAfter=" .. tostring(after_pitch) ..
            " | FreshAfter=" .. tostring(fresh_pitch) ..
            " | NestedWrite=" .. tostring(nested_write_ok) ..
            " | StructWrite=" .. tostring(struct_write_ok) ..
            " | Readback=" .. tostring(readback_ok)
        )

        if nested_write_ok and struct_write_ok and readback_ok then
            changed = 1
        end
        schedule_follow_rotation_readback(camera, reason, target_pitch)
    else
        append_log(
            "LOCK TEST FOLLOW PITCH MISSING" ..
            " | Reason=" .. tostring(reason) ..
            " | Index=" .. tostring(index) ..
            " | Mode=" .. mode_name ..
            " | Camera=" .. safe_full_name(camera) ..
            " | RelativeRotationPitchNumeric=" .. tostring(before_pitch ~= nil)
        )
    end

    append_log(
        "LOCK CAMERA FOLLOW PITCH TEST APPLY" ..
        " | Reason=" .. tostring(reason) ..
        " | StackDepth=" .. tostring(depth) ..
        " | ActiveIndex=" .. tostring(index) ..
        " | ChangedCamera=" .. tostring(changed)
    )
    return true, changed
end

local function restore_lock_camera_test(reason)
    follow_rotation_probe_generation = follow_rotation_probe_generation + 1
    local restored = 0
    local baseline = lock_follow_rotation_baseline
    local camera = lock_follow_rotation_camera
    if baseline ~= nil and valid_object(camera) then
        local rotation = get_field(camera, "RelativeRotation")
        local nested_write_ok = pcall(function()
            rotation.Pitch = baseline.Pitch
        end)
        local struct_write_ok = pcall(function()
            camera.RelativeRotation = rotation
        end)
        local after_pitch = tonumber(get_unwrapped_field(rotation, "Pitch"))
        local fresh_pitch = read_fresh_follow_pitch(camera)
        local readback_ok = fresh_pitch ~= nil and
            math.abs(fresh_pitch - baseline.Pitch) < 0.001
        if nested_write_ok and struct_write_ok and readback_ok then
            restored = 1
        end
        append_log(
            "LOCK FOLLOW PITCH RESTORE" ..
            " | Reason=" .. tostring(reason) ..
            " | Property=FollowCamera.RelativeRotation.Pitch" ..
            " | Target=" .. tostring(baseline.Pitch) ..
            " | NestedAfter=" .. tostring(after_pitch) ..
            " | FreshAfter=" .. tostring(fresh_pitch) ..
            " | NestedWrite=" .. tostring(nested_write_ok) ..
            " | StructWrite=" .. tostring(struct_write_ok) ..
            " | Readback=" .. tostring(readback_ok)
        )
    end

    append_log("LOCK CAMERA FOLLOW PITCH TEST RESTORE | Reason=" .. tostring(reason) .. " | RestoredCamera=" .. tostring(restored))
    lock_camera_test_cache = {}
    lock_follow_rotation_baseline = nil
    lock_follow_rotation_camera = nil
    lock_camera_test_enabled = false
    return restored
end

-- v1.1.27 experiment retained for reference. v1.1.28 overrides its lifecycle
-- wiring below with the live CameraLocationOffsetDuringTargeting.Z test.
local lock_target_offset_baseline = nil
local lock_target_offset_camera = nil
local lock_target_offset_key = nil
local lock_target_offset_probe_generation = 0

local function find_active_target_offset_entry(camera)
    if not valid_object(camera) then
        return nil, nil, nil, nil, nil, nil
    end

    local mode, index, depth = find_active_lock_camera_mode(camera)
    if not valid_object(mode) then
        return nil, index, depth, nil, nil, nil
    end

    local camera_offsets = get_unwrapped_field(mode, "CameraOffsets")
    if camera_offsets == nil then
        return mode, index, depth, nil, nil, nil
    end

    local selected_key = nil
    local selected_value = nil
    local selected_target = nil
    local walk_ok = pcall(function()
        camera_offsets:ForEach(function(a, b, c)
            local key = unwrap_value(a)
            local value = unwrap_value(b)
            if c ~= nil and tonumber(key) == nil then
                key = unwrap_value(b)
                value = unwrap_value(c)
            end

            local numeric_key = tonumber(key)
            if value ~= nil and (selected_value == nil or numeric_key == 1) then
                local target = get_field(value, "TargetOffset")
                local z = tonumber(get_unwrapped_field(target, "Z"))
                if target ~= nil and z ~= nil then
                    selected_key = numeric_key or key
                    selected_value = value
                    selected_target = target
                end
            end
        end)
    end)

    if not walk_ok then
        append_log(
            "TARGET OFFSET Z FIND FAILED" ..
            " | Camera=" .. safe_full_name(camera) ..
            " | Mode=" .. safe_full_name(mode) ..
            " | Index=" .. tostring(index)
        )
    end

    return mode, index, depth, selected_key, selected_value, selected_target
end

local function read_fresh_target_offset_z(camera)
    local mode, index, depth, key, value, target = find_active_target_offset_entry(camera)
    if target == nil then
        return nil, key, mode, index, depth
    end

    return tonumber(get_unwrapped_field(target, "Z")), key, mode, index, depth
end

local function write_target_offset_z(value, target, target_z)
    if value == nil or target == nil or target_z == nil then
        return false, false, nil
    end

    local nested_write_ok = pcall(function()
        target.Z = target_z
    end)
    local struct_write_ok = pcall(function()
        value.TargetOffset = target
    end)
    local fresh_z = tonumber(get_unwrapped_field(get_field(value, "TargetOffset"), "Z"))
    return nested_write_ok, struct_write_ok, fresh_z
end

local function schedule_target_offset_z_readback(camera, reason, target_z)
    lock_target_offset_probe_generation = lock_target_offset_probe_generation + 1
    local generation = lock_target_offset_probe_generation

    if type(ExecuteWithDelay) ~= "function" then
        append_log(
            "TARGET OFFSET Z FRESH READBACK ERROR" ..
            " | Reason=" .. tostring(reason) ..
            " | TimerUnavailable=true"
        )
        return
    end

    for _, delay_ms in ipairs({ 10, 50, 100 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= lock_target_offset_probe_generation or
                not lock_active or
                not valid_object(camera) then
                return
            end

            local fresh_z, key, mode, index = read_fresh_target_offset_z(camera)
            append_log(
                "TARGET OFFSET Z FRESH READBACK" ..
                " | Reason=" .. tostring(reason) ..
                " | DelayMs=" .. tostring(delay_ms) ..
                " | Index=" .. tostring(index) ..
                " | Key=" .. tostring(key) ..
                " | Target=" .. tostring(target_z) ..
                " | FreshZ=" .. tostring(fresh_z) ..
                " | Delta=" .. tostring(fresh_z ~= nil and target_z ~= nil and fresh_z - target_z or nil) ..
                " | Mode=" .. safe_full_name(mode)
            )
        end)
    end
end

local function apply_lock_target_offset_test(reason)
    if not mod_enabled or not lock_active or not lock_camera_test_enabled then
        return false, 0
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end

    if not valid_object(camera) then
        append_log("TARGET OFFSET Z APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return false, 0
    end

    local mode, index, depth, key, value, target = find_active_target_offset_entry(camera)
    local before_z = tonumber(get_unwrapped_field(target, "Z"))
    if value == nil or target == nil or before_z == nil then
        append_log(
            "TARGET OFFSET Z APPLY FAILED" ..
            " | Reason=" .. tostring(reason) ..
            " | Index=" .. tostring(index) ..
            " | Key=" .. tostring(key) ..
            " | Mode=" .. safe_full_name(mode) ..
            " | TargetOffsetZNumeric=" .. tostring(before_z ~= nil)
        )
        return false, 0
    end

    lock_target_offset_baseline = before_z
    lock_target_offset_camera = camera
    lock_target_offset_key = key

    local target_z = test_camera_values.Z
    local nested_write_ok, struct_write_ok, fresh_z = write_target_offset_z(value, target, target_z)
    local readback_ok = fresh_z ~= nil and math.abs(fresh_z - target_z) < 0.001

    append_log(
        "TARGET OFFSET Z WRITE" ..
        " | Reason=" .. tostring(reason) ..
        " | Index=" .. tostring(index) ..
        " | Key=" .. tostring(key) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | BeforeZ=" .. tostring(before_z) ..
        " | TargetZ=" .. tostring(target_z) ..
        " | FreshAfterZ=" .. tostring(fresh_z) ..
        " | NestedWrite=" .. tostring(nested_write_ok) ..
        " | StructWrite=" .. tostring(struct_write_ok) ..
        " | Readback=" .. tostring(readback_ok)
    )

    schedule_target_offset_z_readback(camera, reason, target_z)
    return true, (nested_write_ok and struct_write_ok and readback_ok) and 1 or 0
end

local function restore_lock_target_offset_test(reason)
    lock_target_offset_probe_generation = lock_target_offset_probe_generation + 1
    local restored = 0
    local camera = lock_target_offset_camera
    local baseline = lock_target_offset_baseline

    if baseline ~= nil and valid_object(camera) then
        local mode_unused, index, depth_unused, key, value, target = find_active_target_offset_entry(camera)
        local nested_write_ok, struct_write_ok, fresh_z = write_target_offset_z(value, target, baseline)
        local readback_ok = fresh_z ~= nil and math.abs(fresh_z - baseline) < 0.001
        if nested_write_ok and struct_write_ok and readback_ok then
            restored = 1
        end
        append_log(
            "TARGET OFFSET Z RESTORE" ..
            " | Reason=" .. tostring(reason) ..
            " | Index=" .. tostring(index) ..
            " | Key=" .. tostring(key) ..
            " | TargetZ=" .. tostring(baseline) ..
            " | FreshAfterZ=" .. tostring(fresh_z) ..
            " | NestedWrite=" .. tostring(nested_write_ok) ..
            " | StructWrite=" .. tostring(struct_write_ok) ..
            " | Readback=" .. tostring(readback_ok)
        )
    end

    append_log("TARGET OFFSET Z TEST RESTORE | Reason=" .. tostring(reason) .. " | Restored=" .. tostring(restored))
    lock_target_offset_baseline = nil
    lock_target_offset_camera = nil
    lock_target_offset_key = nil
    lock_camera_test_cache = {}
    lock_camera_test_enabled = false
    return restored
end

-- Keep the existing lifecycle wiring, but switch the active experiment from
-- Switch the active experiment to the live targeting offset below.
apply_lock_camera_test = apply_lock_target_offset_test
restore_lock_camera_test = restore_lock_target_offset_test

-- Combat-scoped Offset Z (v1.1.46). Applied on CurrentCombatMode 0->nonzero,
-- restored on nonzero->0. Lock On/Off no longer touches TargetingOffset.Z.
local combat_offset_z = {
    active = false,
    modes = {},
}

local function write_active_targeting_offset_z(mode, offset, target_z)
    if not valid_object(mode) or offset == nil or target_z == nil then
        return false, false, nil
    end

    local nested_write_ok = pcall(function()
        offset.Z = target_z
    end)
    local struct_write_ok = pcall(function()
        mode.CameraLocationOffsetDuringTargeting = offset
    end)
    local fresh_z = tonumber(get_unwrapped_field(
        get_field(mode, "CameraLocationOffsetDuringTargeting"),
        "Z"
    ))
    return nested_write_ok, struct_write_ok, fresh_z
end

local function write_active_targeting_offset_y(mode, offset, target_y)
    if not valid_object(mode) or offset == nil or target_y == nil then
        return false, false, nil
    end

    local nested_write_ok = pcall(function()
        offset.Y = target_y
    end)
    local struct_write_ok = pcall(function()
        mode.CameraLocationOffsetDuringTargeting = offset
    end)
    local fresh_y = tonumber(get_unwrapped_field(
        get_field(mode, "CameraLocationOffsetDuringTargeting"),
        "Y"
    ))
    return nested_write_ok, struct_write_ok, fresh_y
end

function CloUtil.combat_offset_z_wanted()
    return CloUtil.combat_mod_active() and lock_active and
        (tonumber(config.LockOnOffsetZ) or 0) > 0.001
end

function CloUtil.in_combat_context()
    return CloUtil.combat_fov.session_active
end

function CloUtil.combat_mod_active()
    return mod_enabled and CloUtil.combat_fov.session_active
end

function CloUtil.is_defensive_combat_state()
    return CloUtil.combat_fov.last_state == 6
end

function CloUtil.log_user_mark(source)
    local combat = tracked_combat
    if not valid_object(combat) then
        combat = combat_component
    end

    local cf = CloUtil.combat_fov
    local mode_text = nil
    if valid_object(combat) then
        mode_text = readable_runtime_value(
            unwrap_value(get_field(combat, "CurrentCombatMode"))
        )
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(combat)
    end

    local camera_type = "<unavailable>"
    if valid_object(camera) then
        pcall(function()
            camera_type = tostring(camera:GetCameraType())
        end)
    end

    local manager_fov = CloUtil.read_manager_fov()
    local sheath_debounce = cf.exit_zero_since_ms ~= nil

    append_log(
        "USER MARK | Event=CombatOver" ..
        " | Source=" .. tostring(source) ..
        " | SessionActive=" .. tostring(cf.session_active) ..
        " | LockActive=" .. tostring(lock_active) ..
        " | FOVApplied=" .. tostring(fov_applied) ..
        " | CombatMode=" .. tostring(mode_text) ..
        " | GameHardLock=" .. tostring(game_hard_lock_active) ..
        " | SheathDebounce=" .. tostring(sheath_debounce) ..
        " | TypePulseDone=" .. tostring(cf.fov_type_pulse_done) ..
        " | CameraType=" .. tostring(camera_type) ..
        " | ManagerFOV=" .. tostring(manager_fov) ..
        " | FovTweenDir=" .. tostring(cf.direction) ..
        " | FovTweenActive=" .. tostring(cf.poll_active) ..
        " | RestoreViewFOV=" .. tostring(cf.restore_view_fov)
    )
    return true
end

function CloUtil.pulse_unlocked_camera_type_for_fov(reason)
    local cf = CloUtil.combat_fov
    if cf.fov_type_pulse_done or lock_active or not cf.session_active then
        cf.fov_type_pulse_pending = false
        return false
    end
    if not fov_applied then
        cf.fov_type_pulse_pending = true
        return false
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end
    if valid_object(combat) then
        local state_text = readable_runtime_value(get_field(combat, "CurrentState"))
        local state = tonumber(state_text)
        if state ~= nil then
            cf.last_state = state
        end
    end
    if CloUtil.is_defensive_combat_state() then
        cf.fov_type_pulse_pending = true
        if config.EnableLog then
            append_log(
                "COMBAT FOV TYPE HOLD DEFERRED" ..
                " | Reason=" .. tostring(reason) ..
                " | CurrentState=" .. tostring(cf.last_state)
            )
        end
        return false
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        cf.fov_type_pulse_pending = true
        return false
    end

    local before = CAMERA_TYPE_DEFAULT
    pcall(function()
        before = camera:GetCameraType()
    end)
    if tonumber(before) == CAMERA_TYPE_NONE then
        cf.fov_type_pulse_done = true
        cf.fov_type_pulse_pending = false
        return true
    end

    local to_none = pcall(function()
        camera:SetCameraType(CAMERA_TYPE_NONE)
    end)

    local after = "<unavailable>"
    pcall(function()
        after = tostring(camera:GetCameraType())
    end)

    cf.fov_type_pulse_done = to_none
    cf.fov_type_pulse_pending = not to_none

    if config.EnableLog then
        append_log(
            "COMBAT FOV TYPE HOLD" ..
            " | Reason=" .. tostring(reason) ..
            " | Before=" .. tostring(before) ..
            " | Set0=" .. tostring(to_none) ..
            " | After=" .. tostring(after)
        )
    end

    return to_none
end

function CloUtil.release_combat_fov_camera_type(reason)
    if lock_active or not CloUtil.combat_fov.session_active then
        return false
    end

    local cf = CloUtil.combat_fov
    if not cf.fov_type_pulse_done then
        return false
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        return false
    end

    local before = CAMERA_TYPE_DEFAULT
    pcall(function()
        before = camera:GetCameraType()
    end)

    local released = true
    if tonumber(before) ~= CAMERA_TYPE_DEFAULT then
        released = pcall(function()
            camera:SetCameraType(CAMERA_TYPE_DEFAULT)
        end)
    end

    local after = "<unavailable>"
    pcall(function()
        after = tostring(camera:GetCameraType())
    end)

    cf.fov_type_pulse_done = false
    cf.fov_type_pulse_pending = false

    if config.EnableLog then
        append_log(
            "COMBAT SHEATH TYPE RELEASE" ..
            " | Reason=" .. tostring(reason) ..
            " | Before=" .. tostring(before) ..
            " | Set1=" .. tostring(released) ..
            " | After=" .. tostring(after)
        )
    end

    return released
end

function CloUtil.repulse_combat_fov_camera_type(reason)
    if lock_active or not CloUtil.combat_fov.session_active then
        return false
    end

    local cf = CloUtil.combat_fov
    cf.fov_type_pulse_done = false
    cf.fov_type_pulse_pending = false
    tracked_camera = nil

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end
    if valid_object(combat) then
        local camera = camera_from_combat(combat)
        if valid_object(camera) then
            tracked_camera = camera
        end
    end

    return CloUtil.pulse_unlocked_camera_type_for_fov(reason)
end

function CloUtil.handle_sheath_abort_redraw()
    if lock_active or not CloUtil.combat_fov.session_active or
        not mod_enabled or not config.FOVEnabled then
        return false
    end

    local cf = CloUtil.combat_fov
    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end

    cf.sheath_abort_rearm_pending = true

    local restore_fov = CloUtil.get_restore_view_fov()
    cf.fov_type_pulse_done = false
    cf.fov_type_pulse_pending = false
    CloUtil.stop_combat_fov_tween("SheathAbortReset")

    tracked_camera = nil
    local camera = camera_from_combat(combat)
    if valid_object(camera) then
        tracked_camera = camera
        pcall(function()
            camera:SetCameraType(CAMERA_TYPE_DEFAULT)
        end)
    end

    if type(restore_fov) == "number" then
        CloUtil.publish_combat_fov_to_view(restore_fov, "SheathAbortReset", true)
        CloUtil.set_manager_fov(restore_fov, "SheathAbortReset", true)
    end

    if config.EnableLog then
        append_log(
            "COMBAT SHEATH ABORT RESET" ..
            " | RestoreFOV=" .. tostring(restore_fov) ..
            " | ManagerFOV=" .. tostring(CloUtil.read_manager_fov()) ..
            " | CameraType=1"
        )
    end

    if type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        cf.sheath_abort_rearm_pending = false
        CloUtil.arm_combat_fov("SheathAbortRedraw")
        return true
    end

    local generation = runtime_generation
    ExecuteWithDelay(500, function()
        if generation ~= runtime_generation then
            return
        end
        ExecuteInGameThread(function()
            if generation ~= runtime_generation or
                not cf.session_active or lock_active or
                not mod_enabled or not config.FOVEnabled then
                cf.sheath_abort_rearm_pending = false
                return
            end
            cf.sheath_abort_rearm_pending = false
            tracked_camera = nil
            cf.fov_type_pulse_done = false
            CloUtil.arm_combat_fov("SheathAbortRedraw")
        end)
    end)
    return true
end

function CloUtil.bootstrap_combat_fov(reason)
    if CloUtil.combat_fov.sheath_abort_rearm_pending then
        return false
    end
    if not mod_enabled or not config.FOVEnabled or not CloUtil.in_combat_context() then
        return false
    end
    if fov_applied then
        return CloUtil.refresh_combat_fov_view(reason, false)
    end

    return CloUtil.arm_combat_fov(reason)
end

function CloUtil.begin_combat_session(combat, reason, arm_fov)
    local cf = CloUtil.combat_fov
    if not cf.session_active then
        cf.session_active = true
        cf.exit_pending = 0
        cf.exit_zero_since_ms = nil
        cf.last_catchup_ms = nil
        cf.fov_type_pulse_done = false
        cf.fov_type_pulse_pending = false
    end

    if arm_fov == true and mod_enabled and config.FOVEnabled then
        CloUtil.bootstrap_combat_fov(reason)
    elseif arm_fov == true and config.FOVEnabled then
        cf.pending_enter = true
    end

    return true
end

function CloUtil.apply_deferred_lock_writes(reason)
    local cf = CloUtil.combat_fov
    if not cf.lock_writes_deferred or not lock_active or not game_hard_lock_active then
        cf.lock_writes_deferred = false
        return false
    end
    if CloUtil.is_defensive_combat_state() then
        return false
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
        tracked_combat = combat
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(combat)
        tracked_camera = camera
    end

    if not valid_object(camera) or not valid_object(combat) then
        return false
    end

    cf.lock_writes_deferred = false

    if previous_camera_type == nil then
        local camera_type = CAMERA_TYPE_DEFAULT
        if not cf.fov_type_pulse_done then
            pcall(function()
                camera_type = camera:GetCameraType()
            end)
        end
        previous_camera_type = camera_type
    end

    local camera_ok = pcall(function()
        camera:SetCameraType(CAMERA_TYPE_NONE)
    end)

    set_camera_detached_state(combat, true)
    CloUtil.apply_lock_offsets(reason)

    if not stack_poll_active then
        start_stack_poll()
    end

    if config.EnableLog then
        append_log(
            "LOCK DEFERRED WRITES APPLIED" ..
            " | Reason=" .. tostring(reason) ..
            " | SetCameraType0=" .. tostring(camera_ok)
        )
    end

    return camera_ok
end

function CloUtil.end_combat_session(combat, reason)
    local cf = CloUtil.combat_fov
    if not cf.session_active then
        return false
    end

    local combat_type_forced = cf.fov_type_pulse_done or fov_applied
    cf.session_active = false
    cf.exit_pending = 0
    cf.exit_zero_since_ms = nil
    cf.pending_enter = false
    cf.lock_writes_deferred = false
    cf.last_catchup_ms = nil
    cf.sheath_abort_rearm_pending = false
    if not valid_object(combat) then
        combat = find_combat_component()
    end

    if lock_active then
        local ok, err = pcall(function()
            apply_lock_fov(combat, false)
        end)
        append_log(
            "COMBAT EXIT CLEANUP | PCallOK=" .. tostring(ok) ..
            " | Error=" .. tostring(err) ..
            " | LockActiveAfter=" .. tostring(lock_active) ..
            " | FOVAppliedAfter=" .. tostring(fov_applied)
        )
    else
        append_log("COMBAT EXIT CLEANUP | No active Lock-On session")
        if combat_type_forced then
            local camera = tracked_camera
            if not valid_object(camera) then
                camera = camera_from_combat(combat)
            end
            local restored = pcall(function()
                if valid_object(camera) then
                    camera:SetCameraType(CAMERA_TYPE_DEFAULT)
                end
            end)
            append_log(
                "COMBAT TYPE HOLD RESTORE" ..
                " | Target=1" ..
                " | Success=" .. tostring(restored)
            )
        end
    end

    cf.fov_type_pulse_done = false
    cf.fov_type_pulse_pending = false

    CloUtil.restore_combat_offset_z("CombatExit")

    if config.FOVEnabled and mod_enabled then
        local ok, err = pcall(function()
            CloUtil.start_combat_fov_tween("out", reason)
        end)
        if not ok and config.EnableLog then
            append_log(
                "COMBAT FOV TWEEN OUT ERROR" ..
                " | Reason=" .. tostring(reason) ..
                " | Error=" .. tostring(err)
            )
        end
    else
        CloUtil.stop_combat_fov_tween("CombatExit")
        fov_applied = false
    end

    return true
end

local function get_player_camera_for_offset()
    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        if valid_object(camera) then
            tracked_camera = camera
        end
    end
    if not valid_object(camera) then
        local combat = find_combat_component()
        camera = camera_from_combat(combat)
        if valid_object(camera) then
            tracked_camera = camera
        end
    end
    return camera
end

function CloUtil.apply_combat_offset_z_to_mode(mode, reason, index)
    if not CloUtil.combat_offset_z_wanted() or not valid_object(mode) then
        return false
    end
    if is_ability_mode(mode) or CloUtil.is_transient_overlay_mode(mode) then
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

    local target_z = config.LockOnOffsetZ
    if math.abs(before_z - target_z) < 0.001 then
        return true
    end

    local nested_ok, struct_ok, fresh_z = write_active_targeting_offset_z(mode, offset, target_z)
    local readback_ok = fresh_z ~= nil and math.abs(fresh_z - target_z) < 0.001

    append_log(
        "COMBAT OFFSET Z WRITE" ..
        " | Reason=" .. tostring(reason) ..
        " | Index=" .. tostring(index) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | BeforeZ=" .. tostring(before_z) ..
        " | TargetZ=" .. tostring(target_z) ..
        " | FreshAfterZ=" .. tostring(fresh_z) ..
        " | Readback=" .. tostring(readback_ok)
    )

    return nested_ok and readback_ok
end

function CloUtil.apply_combat_offset_z(reason)
    if not CloUtil.combat_offset_z_wanted() then
        return 0
    end

    local camera = get_player_camera_for_offset()
    if not valid_object(camera) then
        append_log("COMBAT OFFSET Z APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        append_log("COMBAT OFFSET Z APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraModeStackUnavailable=true")
        return 0
    end

    local depth = 0
    pcall(function()
        depth = stack:GetArrayNum()
    end)
    if type(depth) ~= "number" or depth <= 0 then
        return 0
    end

    local changed = 0
    for index = 1, depth do
        local entry = nil
        pcall(function()
            entry = stack[index]
        end)
        if entry ~= nil then
            local mode = nil
            pcall(function()
                mode = entry.CameraMode
            end)
            if CloUtil.apply_combat_offset_z_to_mode(mode, reason, index) then
                changed = changed + 1
            end
        end
    end

    combat_offset_z.active = changed > 0 or next(combat_offset_z.modes) ~= nil
    append_log(
        "COMBAT OFFSET Z APPLY | Reason=" .. tostring(reason) ..
        " | Changed=" .. tostring(changed) ..
        " | Active=" .. tostring(combat_offset_z.active)
    )
    return changed
end

function CloUtil.restore_combat_offset_z(reason)
    if not combat_offset_z.active and next(combat_offset_z.modes) == nil then
        return 0
    end

    local restored = 0
    for address, saved in pairs(combat_offset_z.modes) do
        local mode = saved.mode
        local baseline = saved.baseline_z
        if valid_object(mode) and baseline ~= nil then
            local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
            if offset ~= nil then
                local _, _, fresh_z = write_active_targeting_offset_z(mode, offset, baseline)
                if fresh_z ~= nil and math.abs(fresh_z - baseline) < 0.001 then
                    restored = restored + 1
                end
                append_log(
                    "COMBAT OFFSET Z RESTORE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Mode=" .. safe_full_name(mode) ..
                    " | TargetZ=" .. tostring(baseline) ..
                    " | FreshAfterZ=" .. tostring(fresh_z)
                )
            end
        end
    end

    combat_offset_z.modes = {}
    combat_offset_z.active = false
    append_log(
        "COMBAT OFFSET Z RESTORE DONE | Reason=" .. tostring(reason) ..
        " | Restored=" .. tostring(restored)
    )
    return restored
end

CloUtil.HARD_LOCK_BOOL_FIELDS = {
    "bIsLockedOn",
    "bHardLockActive",
    "bIsHardLocked",
    "bHardLocked",
    "bHardLock",
    "bIsHardLock",
    "HardLock",
}

CloUtil.LOCK_PROBE_SOFT_BOOL_FIELDS = {
    "bSoftLock",
    "bIsSoftLocked",
    "bSoftLockActive",
    "bHasSoftLock",
    "bSoftLocked",
    "bIsSoftLock",
    "SoftLock",
    "bTargeting",
    "bHasTarget",
    "bTargetValid",
    "bIsTargetValid",
    "bLockOnActive",
    "bIsLockOn",
    "bIsFocusingTarget",
    "bFocusTargetValid",
}

function CloUtil.probe_combat_lock_fields(combat)
    local parts = {}
    local seen = {}

    local function add_field(field_name)
        if seen[field_name] then
            return
        end
        seen[field_name] = true

        local value = unwrap_value(get_field(combat, field_name))
        if type(value) == "boolean" then
            parts[#parts + 1] = field_name .. "=" .. tostring(value)
        end
    end

    if not valid_object(combat) then
        return "<no-combat>"
    end

    for _, field_name in ipairs(CloUtil.HARD_LOCK_BOOL_FIELDS) do
        add_field(field_name)
    end
    for _, field_name in ipairs(CloUtil.LOCK_PROBE_SOFT_BOOL_FIELDS) do
        add_field(field_name)
    end
    for _, field_name in ipairs(CloUtil.PLAYER_LOCK_LOST_FIELDS) do
        add_field(field_name)
    end

    if #parts == 0 then
        return "<empty>"
    end

    return table.concat(parts, ",")
end

function CloUtil.probe_lock_target_fields(combat)
    local parts = {}

    if not valid_object(combat) then
        return "<no-combat>"
    end

    for _, field_name in ipairs(LOCK_TARGET_FIELD_CANDIDATES) do
        local target = unwrap_value(get_field(combat, field_name))
        if valid_object(target) then
            parts[#parts + 1] = field_name .. "=@" .. tostring(object_address(target))
        end
    end

    if #parts == 0 then
        return "<empty>"
    end

    return table.concat(parts, ",")
end

function CloUtil.summarize_lock_probe(combat)
    if not valid_object(combat) then
        return "CombatUnavailable"
    end

    if not game_hard_lock_active then
        return "UnlockHookHardLockOff"
    end

    local player_lost, player_lost_reason = CloUtil.is_player_lock_target_lost(combat)
    if player_lost then
        return "Unlock" .. tostring(player_lost_reason)
    end

    local lock_target = CloUtil.read_lock_target_actor(combat)
    if not valid_object(lock_target) then
        return "UnlockEmptyTarget"
    end

    local target_gone, gone_reason = CloUtil.is_lock_target_gone(lock_target)
    if target_gone then
        return "UnlockDeadTarget:" .. tostring(gone_reason)
    end

    local fields, any_true, any_readable = CloUtil.scan_hard_lock_fields(combat)
    if any_readable and not any_true then
        return "UnlockAllHardFieldsFalse"
    end

    local field_lock = CloUtil.read_game_hard_lock(combat)
    if field_lock == false then
        return "UnlockFieldFalse"
    end

    local soft_true = false
    for _, field_name in ipairs(CloUtil.LOCK_PROBE_SOFT_BOOL_FIELDS) do
        if unwrap_value(get_field(combat, field_name)) == true then
            soft_true = true
            break
        end
    end

    if soft_true and not any_true and not game_hard_lock_active then
        return "SoftLockOnly"
    end

    if game_hard_lock_active then
        return "LikelyHardLock"
    end

    return "Unknown"
end

function CloUtil.log_lock_state_probe(combat, reason, phase)
    if not config.EnableLog then
        return
    end

    if not valid_object(combat) then
        combat = find_combat_component()
    end

    local fields, _, _ = CloUtil.scan_hard_lock_fields(combat)
    local current_target, current_field = CloUtil.read_lock_target_actor(combat)
    local current_address = valid_object(current_target) and
        object_address(current_target) or nil

    append_log(
        "LOCK STATE PROBE" ..
        " | Reason=" .. tostring(reason) ..
        " | Phase=" .. tostring(phase) ..
        " | Verdict=" .. CloUtil.summarize_lock_probe(combat) ..
        " | ModLockActive=" .. tostring(lock_active) ..
        " | ModFOVApplied=" .. tostring(fov_applied) ..
        " | HookHardLock=" .. tostring(game_hard_lock_active) ..
        " | TrackedAddr=" .. tostring(CloUtil.lock_target.address) ..
        " | CurrentAddr=" .. tostring(current_address) ..
        " | CurrentField=" .. tostring(current_field) ..
        " | BoolFields=" .. CloUtil.probe_combat_lock_fields(combat) ..
        " | TargetFields=" .. CloUtil.probe_lock_target_fields(combat) ..
        " | HardLockScan=" .. CloUtil.format_hard_lock_fields(fields)
    )
end

function CloUtil.schedule_lock_state_probe_after_swap(combat, reason)
    if not config.EnableLog then
        return
    end

    if type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        CloUtil.log_lock_state_probe(combat, reason, "Immediate")
        return
    end

    local generation = runtime_generation
    for _, delay_ms in ipairs({ 0, 100, 300 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= runtime_generation then
                return
            end

            ExecuteInGameThread(function()
                if generation ~= runtime_generation then
                    return
                end

                local live_combat = tracked_combat
                if not valid_object(live_combat) then
                    live_combat = find_combat_component()
                end

                CloUtil.log_lock_state_probe(
                    live_combat,
                    reason,
                    "T+" .. tostring(delay_ms) .. "ms"
                )
            end)
        end)
    end
end

function CloUtil.read_lock_target_actor(combat)
    if not valid_object(combat) then
        return nil, nil
    end

    for _, field_name in ipairs(LOCK_TARGET_FIELD_CANDIDATES) do
        local target = unwrap_value(get_field(combat, field_name))
        if valid_object(target) then
            return target, field_name
        end
    end

    return nil, nil
end

function CloUtil.describe_lock_target(target)
    if not valid_object(target) then
        return nil, nil
    end

    return object_address(target), readable_runtime_value(target)
end

function CloUtil.set_active_lock_target(target)
    if valid_object(target) then
        CloUtil.lock_target.component = target
        CloUtil.lock_target.address = object_address(target)
        CloUtil.lock_target.name = readable_runtime_value(target)
    else
        CloUtil.lock_target.component = nil
        CloUtil.lock_target.address = nil
        CloUtil.lock_target.name = nil
    end
end

function CloUtil.is_tracked_lock_target_gone()
    if not valid_object(CloUtil.lock_target.component) then
        return false, nil
    end

    return CloUtil.is_lock_target_gone(CloUtil.lock_target.component)
end

function CloUtil.is_player_lock_target_lost(combat)
    if not valid_object(combat) then
        return false, nil
    end

    for _, field_name in ipairs(CloUtil.PLAYER_LOCK_LOST_FIELDS) do
        local value = unwrap_value(get_field(combat, field_name))
        if value == false then
            return true, field_name .. "=false"
        end
    end

    return false, nil
end

function CloUtil.log_tracked_vitality_if_due()
    if not config.EnableLog or not lock_active then
        return
    end

    local now_ms = os.clock() * 1000.0
    if now_ms - (CloUtil.vitality_log.last_ms or 0) < 5000.0 then
        return
    end
    CloUtil.vitality_log.last_ms = now_ms

    local tracked = CloUtil.lock_target.component
    if not valid_object(tracked) then
        append_log("LOCK VITALITY | TrackedTarget=Invalid")
        return
    end

    append_log(
        "LOCK VITALITY | Tracked=" .. tostring(CloUtil.lock_target.name) ..
        " | Address=" .. tostring(CloUtil.lock_target.address)
    )
end

function CloUtil.log_lock_target_changed(from_address, from_name, to_target, reason, target_field)
    local to_address, to_name = CloUtil.describe_lock_target(to_target)
    if from_address == nil or to_address == nil or from_address == to_address then
        return false
    end

    append_log(
        "LOCK TARGET CHANGED" ..
        " | Reason=" .. tostring(reason) ..
        " | From=" .. tostring(from_name or from_address) ..
        " | To=" .. tostring(to_name) ..
        " | FromAddress=" .. tostring(from_address) ..
        " | ToAddress=" .. tostring(to_address) ..
        " | TargetField=" .. tostring(target_field)
    )
    return true
end

CloUtil.LOCK_TARGET_OWNER_FIELDS = {
    "Owner",
    "OwnerActor",
    "Character",
    "Pawn",
    "TargetActor",
    "LockedActor",
    "Actor",
}

CloUtil.LOCK_TARGET_OWNER_HEALTH_FIELDS = {
    "HealthComponent",
    "HealthComp",
    "DamageHandler",
    "AttributeSet",
    "StatsComponent",
    "VitalityComponent",
    "CharacterHealth",
}

CloUtil.PLAYER_LOCK_LOST_FIELDS = {
    "bHasValidLockTarget",
    "bHasLockTarget",
    "bLockTargetValid",
    "bIsLockTargetValid",
    "bIsLockedOn",
    "bCanHardLock",
}

CloUtil.LOCK_TARGET_DEAD_BOOL_FIELDS = {
    "bIsDead",
    "bDead",
    "bIsDying",
    "bIsDestroyed",
    "bTargetDead",
    "bTargetIsDead",
    "bIsDefeated",
    "bIsKnockedOut",
}

CloUtil.LOCK_TARGET_HEALTH_FIELDS = {
    "Health",
    "CurrentHealth",
    "HP",
    "CurrentHP",
    "RemainingHealth",
}

function CloUtil.resolve_lock_target_subjects(target)
    local subjects = {}
    local seen = {}

    local function add(obj)
        if not valid_object(obj) then
            return
        end

        local addr = object_address(obj)
        if addr ~= nil then
            if seen[addr] then
                return
            end
            seen[addr] = true
        end

        subjects[#subjects + 1] = obj
    end

    if not valid_object(target) then
        return subjects
    end

    add(target)

    local owner = nil
    pcall(function()
        if target.GetOwner ~= nil then
            owner = target:GetOwner()
        end
    end)
    add(owner)

    for _, field_name in ipairs(CloUtil.LOCK_TARGET_OWNER_FIELDS) do
        add(unwrap_value(get_field(target, field_name)))
    end

    if not valid_object(owner) then
        owner = unwrap_value(get_field(target, "Owner"))
    end

    if valid_object(owner) then
        for _, field_name in ipairs(CloUtil.LOCK_TARGET_OWNER_HEALTH_FIELDS) do
            add(unwrap_value(get_field(owner, field_name)))
        end
    elseif owner ~= nil then
        subjects.owner_missing = true
    end

    return subjects
end

function CloUtil.check_subject_gone(subject)
    if not valid_object(subject) then
        return true, "Invalid"
    end

    if unwrap_value(get_field(subject, "bIsAlive")) == false then
        return true, "bIsAlive=false"
    end

    if unwrap_value(get_field(subject, "bHidden")) == true or
        unwrap_value(get_field(subject, "bHiddenInGame")) == true then
        return true, "Hidden"
    end

    local collision_disabled = nil
    pcall(function()
        if subject.GetActorEnableCollision ~= nil and
            subject:GetActorEnableCollision() == false then
            collision_disabled = true
        end
    end)
    if collision_disabled == true then
        return true, "CollisionDisabled"
    end

    for _, field_name in ipairs(CloUtil.LOCK_TARGET_DEAD_BOOL_FIELDS) do
        local value = unwrap_value(get_field(subject, field_name))
        if value == true then
            return true, field_name
        end
    end

    for _, field_name in ipairs(CloUtil.LOCK_TARGET_HEALTH_FIELDS) do
        local value = tonumber(unwrap_value(get_field(subject, field_name)))
        if value ~= nil and value <= 0.0 then
            return true, field_name .. "<=0"
        end
    end

    local method_dead = nil
    pcall(function()
        if subject.IsDead ~= nil and subject:IsDead() then
            method_dead = true
        elseif subject.IsAlive ~= nil and subject:IsAlive() == false then
            method_dead = true
        elseif subject.IsActorBeingDestroyed ~= nil and subject:IsActorBeingDestroyed() then
            method_dead = true
        end
    end)
    if method_dead == true then
        return true, "LifeState"
    end

    return false, nil
end

function CloUtil.is_lock_target_gone(target)
    if not valid_object(target) then
        return true, "Invalid"
    end

    local subjects = CloUtil.resolve_lock_target_subjects(target)

    for index, subject in ipairs(subjects) do
        local gone, reason = CloUtil.check_subject_gone(subject)
        if gone then
            if index == 1 then
                return true, reason
            end
            return true, reason .. "@Subject=" .. readable_runtime_value(subject)
        end
    end

    return false, nil
end

function CloUtil.read_game_hard_lock(combat)
    if not valid_object(combat) then
        return nil, nil
    end

    for _, field_name in ipairs(CloUtil.HARD_LOCK_BOOL_FIELDS) do
        local value = unwrap_value(get_field(combat, field_name))
        if type(value) == "boolean" then
            return value, field_name
        end
    end

    return nil, nil
end

function CloUtil.scan_hard_lock_fields(combat)
    local fields = {}
    local any_true = false
    local any_readable = false

    if not valid_object(combat) then
        return fields, any_true, any_readable
    end

    for _, field_name in ipairs(CloUtil.HARD_LOCK_BOOL_FIELDS) do
        local value = unwrap_value(get_field(combat, field_name))
        if type(value) == "boolean" then
            any_readable = true
            fields[field_name] = value
            if value then
                any_true = true
            end
        end
    end

    return fields, any_true, any_readable
end

function CloUtil.should_restore_fov_session(combat)
    if not lock_active then
        return false, nil
    end

    if not valid_object(combat) then
        combat = find_combat_component()
    end
    if not valid_object(combat) then
        return true, "CombatUnavailable"
    end

    local tracked_gone, tracked_reason = CloUtil.is_tracked_lock_target_gone()
    if tracked_gone then
        return true, "TrackedDead:" .. tostring(tracked_reason)
    end

    local player_lost, player_lost_reason = CloUtil.is_player_lock_target_lost(combat)
    if player_lost then
        return true, "PlayerLockLost:" .. tostring(player_lost_reason)
    end

    local lock_target, target_field = CloUtil.read_lock_target_actor(combat)
    if not valid_object(lock_target) then
        if game_hard_lock_active and CloUtil.in_combat_context() then
            return false, "EmptyTargetCombatSwap"
        end
        return true, "EmptyTarget"
    end

    local target_gone, gone_reason = CloUtil.is_lock_target_gone(lock_target)
    if target_gone then
        return true, "DeadTarget:" .. tostring(gone_reason)
    end

    if not game_hard_lock_active then
        return true, "HookHardLockOff"
    end

    local fields, any_true, any_readable = CloUtil.scan_hard_lock_fields(combat)
    if any_readable and not any_true then
        return true, "AllHardLockFieldsFalse"
    end

    local field_lock, field_name = CloUtil.read_game_hard_lock(combat)
    if field_lock == false then
        return true, tostring(field_name) .. "=false"
    end

    return false, nil
end

function CloUtil.unlock_baseline_fov(mode)
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

    local current = get_field(mode, "DefaultFieldOfView")
    if type(current) == "number" and
        math.abs(current - config.LockOnFOV) > 0.001 then
        return current
    end

    return 90.0
end

function CloUtil.format_hard_lock_fields(fields)
    if type(fields) ~= "table" then
        return tostring(fields)
    end

    local parts = {}
    for field_name, value in pairs(fields) do
        table.insert(parts, field_name .. "=" .. tostring(value))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function CloUtil.try_restore_locked_fov_on_mode(mode, lock_fov)
    if not valid_object(mode) or is_ability_mode(mode) or
        CloUtil.is_transient_overlay_mode(mode) then
        return false
    end

    local current = tonumber(get_field(mode, "DefaultFieldOfView"))
    if current == nil or math.abs(current - lock_fov) > 0.001 then
        return false
    end

    local target_fov = CloUtil.unlock_baseline_fov(mode)
    if math.abs(target_fov - lock_fov) <= 0.001 then
        return false
    end

    return set_field(mode, "DefaultFieldOfView", target_fov)
end

function CloUtil.restore_stuck_lock_fov(reason, full_scan)
    if not mod_enabled or not config.FOVEnabled then
        return 0
    end

    if CloUtil.in_combat_context() or lock_active then
        return 0
    end

    if CloUtil.is_hot_fov_write_quiet() then
        return 0
    end

    local lock_fov = tonumber(config.LockOnFOV)
    if lock_fov == nil then
        return 0
    end

    local restored = 0
    local touched = {}

    local function restore_mode(mode)
        if CloUtil.try_restore_locked_fov_on_mode(mode, lock_fov) then
            local address = object_address(mode)
            if address == nil or touched[address] == nil then
                if address ~= nil then
                    touched[address] = true
                end
                restored = restored + 1
            end
        end
    end

    local camera = get_player_camera_for_offset()
    if valid_object(camera) then
        local stack = get_field(camera, "CameraModeStack")
        if stack ~= nil then
            local depth = 0
            pcall(function()
                depth = stack:GetArrayNum()
            end)

            if type(depth) == "number" then
                for index = 1, depth do
                    local mode = nil
                    pcall(function()
                        local entry = stack[index]
                        if entry ~= nil then
                            mode = entry.CameraMode
                        end
                    end)
                    restore_mode(mode)
                end
            end
        end
    end

    if full_scan == true and type(FindAllOf) == "function" then
        for _, class_name in ipairs({ CAMERA_MODE_CLASS, COMBAT_CAMERA_MODE_CLASS }) do
            local ok, modes = pcall(function()
                return FindAllOf(class_name)
            end)

            if ok and modes ~= nil then
                for _, mode in ipairs(modes) do
                    restore_mode(mode)
                end
            end
        end
    end

    if restored > 0 then
        append_log(
            "FOV UNLOCK RECONCILE" ..
            " | Reason=" .. tostring(reason) ..
            " | FullScan=" .. tostring(full_scan == true) ..
            " | Restored=" .. tostring(restored)
        )
        fov_applied = false
    end

    return restored
end

function CloUtil.reconcile_unlocked_fov(reason)
    return CloUtil.sync_lock_with_game(reason)
end

function CloUtil.request_game_hard_lock_off(combat, reason)
    if not valid_object(combat) or not game_hard_lock_active then
        return false
    end

    local ok, err = pcall(function()
        combat:SetHardLock(false)
    end)

    append_log(
        "GAME HARDLOCK OFF REQUEST" ..
        " | Reason=" .. tostring(reason) ..
        " | Success=" .. tostring(ok) ..
        " | Error=" .. tostring(err)
    )

    return ok
end

function CloUtil.finish_mod_unlock(combat, reason)
    if not valid_object(combat) then
        combat = find_combat_component()
    end
    if valid_object(combat) and game_hard_lock_active then
        CloUtil.request_game_hard_lock_off(combat, reason)
    end
end

function CloUtil.sync_lock_with_game(reason)
    if not mod_enabled then
        return false
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
    end

    local should_unlock, unlock_detail = CloUtil.should_restore_fov_session(combat)

    if should_unlock then
        local lock_target, target_field = nil, nil
        local field_lock, hard_lock_field = nil, nil
        local fields = {}

        if valid_object(combat) then
            lock_target, target_field = CloUtil.read_lock_target_actor(combat)
            field_lock, hard_lock_field = CloUtil.read_game_hard_lock(combat)
            fields, _, _ = CloUtil.scan_hard_lock_fields(combat)
        end

        append_log(
            "FOV SYNC LOCK OFF" ..
            " | Reason=" .. tostring(reason) ..
            " | Detail=" .. tostring(unlock_detail) ..
            " | GameHardLock=" .. tostring(game_hard_lock_active) ..
            " | FieldHardLock=" .. tostring(field_lock) ..
            " | FieldName=" .. tostring(hard_lock_field) ..
            " | TargetField=" .. tostring(target_field) ..
            " | TargetValid=" .. tostring(valid_object(lock_target)) ..
            " | LockActive=" .. tostring(lock_active) ..
            " | FOVApplied=" .. tostring(fov_applied) ..
            " | HardLockFields=" .. CloUtil.format_hard_lock_fields(fields) ..
            " | Action=SameAsManualLockOff"
        )

        -- Mirror manual lock off: when the game still reports HardLock, call
        -- SetHardLock(false) and let the SetHardLock hook run apply_lock_fov(false)
        -- once. Do not call apply_lock_fov again here or unlock runs twice.
        local ok = true
        local err = nil
        local used_game_hard_lock_off = valid_object(combat) and game_hard_lock_active

        if used_game_hard_lock_off then
            CloUtil.finish_mod_unlock(
                combat,
                reason .. "+" .. tostring(unlock_detail)
            )
        elseif lock_active then
            ok, err = pcall(function()
                apply_lock_fov(combat, false)
            end)
            if not ok then
                append_log("FOV SYNC LOCK OFF ERROR | " .. tostring(err))
            end
        end

        append_log(
            "FOV SYNC LOCK OFF RESULT" ..
            " | Reason=" .. tostring(reason) ..
            " | Detail=" .. tostring(unlock_detail) ..
            " | UsedGameHardLockOff=" .. tostring(used_game_hard_lock_off) ..
            " | PCallOK=" .. tostring(ok) ..
            " | LockActiveAfter=" .. tostring(lock_active) ..
            " | FOVAppliedAfter=" .. tostring(fov_applied) ..
            " | GameHardLockAfter=" .. tostring(game_hard_lock_active)
        )
        return true
    end

    return false
end

local height_entry_test = {
    target_offset_z = nil,
    pivot_z = nil,
    baselines = {},
    camera = nil,
    active = false,
}

local function clear_height_entry_test()
    height_entry_test.target_offset_z = nil
    height_entry_test.pivot_z = nil
    height_entry_test.baselines = {}
    height_entry_test.camera = nil
    height_entry_test.active = false
end

local function log_height_probe_light(reason)
    if not lock_active then
        append_log(
            "HEIGHT PROBE SKIPPED | Reason=" .. tostring(reason) ..
            " | LockActive=false"
        )
        return false
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        append_log("HEIGHT PROBE FAILED | CameraUnavailable=true")
        return false
    end

    local mode, index, depth = find_active_lock_camera_mode(camera)
    local rotation = get_field(camera, "RelativeRotation")
    local targeting = valid_object(mode) and get_field(mode, "CameraLocationOffsetDuringTargeting") or nil

    append_log(
        "HEIGHT PROBE" ..
        " | Reason=" .. tostring(reason) ..
        " | StackDepth=" .. tostring(depth) ..
        " | ActiveIndex=" .. tostring(index) ..
        " | Pitch=" .. tostring(readable_probe_number(get_field(rotation, "Pitch"))) ..
        " | TargetingOffset.X=" .. tostring(readable_probe_number(get_field(targeting, "X"))) ..
        " | TargetingOffset.Y=" .. tostring(readable_probe_number(get_field(targeting, "Y"))) ..
        " | TargetingOffset.Z=" .. tostring(readable_probe_number(get_field(targeting, "Z"))) ..
        " | Mode=" .. safe_full_name(mode)
    )

    if not valid_object(mode) then
        return true
    end

    local camera_offsets = get_unwrapped_field(mode, "CameraOffsets")
    if camera_offsets == nil then
        append_log("HEIGHT PROBE | CameraOffsets=<nil>")
        return true
    end

    pcall(function()
        camera_offsets:ForEach(function(a, b, c)
            local key = unwrap_value(a)
            local value = unwrap_value(b)
            if c ~= nil and tonumber(key) == nil then
                key = unwrap_value(b)
                value = unwrap_value(c)
            end
            if value == nil then
                return
            end

            local target = get_unwrapped_field(value, "TargetOffset")
            append_log(
                "HEIGHT PROBE ENTRY" ..
                " | Reason=" .. tostring(reason) ..
                " | Key=" .. tostring(tonumber(key) or key) ..
                " | PivotZOffset=" .. tostring(readable_probe_number(get_unwrapped_field(value, "PivotZOffset"))) ..
                " | TargetOffset.X=" .. tostring(readable_probe_number(get_unwrapped_field(target, "X"))) ..
                " | TargetOffset.Y=" .. tostring(readable_probe_number(get_unwrapped_field(target, "Y"))) ..
                " | TargetOffset.Z=" .. tostring(readable_probe_number(get_unwrapped_field(target, "Z")))
            )
        end)
    end)

    return true
end

local function capture_height_entry_baselines(mode, camera)
    height_entry_test.baselines = {}
    height_entry_test.camera = camera
    local camera_offsets = get_unwrapped_field(mode, "CameraOffsets")
    if camera_offsets == nil then
        return 0
    end

    local count = 0
    pcall(function()
        camera_offsets:ForEach(function(a, b, c)
            local key = unwrap_value(a)
            local value = unwrap_value(b)
            if c ~= nil and tonumber(key) == nil then
                key = unwrap_value(b)
                value = unwrap_value(c)
            end
            if value == nil then
                return
            end

            local key_text = tostring(tonumber(key) or key)
            local target = get_unwrapped_field(value, "TargetOffset")
            height_entry_test.baselines[key_text] = {
                value = value,
                target_offset_z = readable_probe_number(get_unwrapped_field(target, "Z")),
                pivot_z = readable_probe_number(get_unwrapped_field(value, "PivotZOffset")),
            }
            count = count + 1
        end)
    end)
    return count
end

local function apply_height_entry_test(reason)
    if not mod_enabled or not lock_active then
        return false, 0
    end
    if height_entry_test.target_offset_z == nil and height_entry_test.pivot_z == nil then
        return false, 0
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(tracked_combat)
        tracked_camera = camera
    end
    if not valid_object(camera) then
        append_log("HEIGHT ENTRY APPLY FAILED | Reason=" .. tostring(reason) .. " | CameraUnavailable=true")
        return false, 0
    end

    local mode = select(1, find_active_lock_camera_mode(camera))
    if not valid_object(mode) then
        append_log("HEIGHT ENTRY APPLY FAILED | Reason=" .. tostring(reason) .. " | ModeUnavailable=true")
        return false, 0
    end

    if next(height_entry_test.baselines) == nil or
        not valid_object(height_entry_test.camera) or
        object_address(height_entry_test.camera) ~= object_address(camera) then
        capture_height_entry_baselines(mode, camera)
    end

    local changed = 0
    for key_text, baseline in pairs(height_entry_test.baselines) do
        local value = baseline.value
        if value ~= nil then
            if height_entry_test.target_offset_z ~= nil and baseline.target_offset_z ~= nil then
                local target = get_unwrapped_field(value, "TargetOffset")
                local write_ok = pcall(function()
                    target.Z = height_entry_test.target_offset_z
                    value.TargetOffset = target
                end)
                local after_z = readable_probe_number(get_unwrapped_field(get_unwrapped_field(value, "TargetOffset"), "Z"))
                append_log(
                    "HEIGHT ENTRY TARGETOFFSET.Z WRITE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Key=" .. key_text ..
                    " | Before=" .. tostring(baseline.target_offset_z) ..
                    " | Target=" .. tostring(height_entry_test.target_offset_z) ..
                    " | After=" .. tostring(after_z) ..
                    " | WriteOK=" .. tostring(write_ok)
                )
                if write_ok then
                    changed = changed + 1
                end
            end

            if height_entry_test.pivot_z ~= nil and baseline.pivot_z ~= nil then
                local write_ok = pcall(function()
                    value.PivotZOffset = height_entry_test.pivot_z
                end)
                local after_z = readable_probe_number(get_unwrapped_field(value, "PivotZOffset"))
                append_log(
                    "HEIGHT ENTRY PIVOTZ WRITE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Key=" .. key_text ..
                    " | Before=" .. tostring(baseline.pivot_z) ..
                    " | Target=" .. tostring(height_entry_test.pivot_z) ..
                    " | After=" .. tostring(after_z) ..
                    " | WriteOK=" .. tostring(write_ok)
                )
                if write_ok then
                    changed = changed + 1
                end
            end
        end
    end

    height_entry_test.active = changed > 0
    log_height_probe_light(reason .. "AfterWrite")
    return true, changed
end

local function restore_height_entry_test(reason)
    local restored = 0
    for key_text, baseline in pairs(height_entry_test.baselines) do
        local value = baseline.value
        if value ~= nil then
            if baseline.target_offset_z ~= nil then
                local target = get_unwrapped_field(value, "TargetOffset")
                local ok = pcall(function()
                    target.Z = baseline.target_offset_z
                    value.TargetOffset = target
                end)
                if ok then
                    restored = restored + 1
                end
                append_log(
                    "HEIGHT ENTRY TARGETOFFSET.Z RESTORE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Key=" .. key_text ..
                    " | Target=" .. tostring(baseline.target_offset_z) ..
                    " | WriteOK=" .. tostring(ok)
                )
            end
            if baseline.pivot_z ~= nil then
                local ok = pcall(function()
                    value.PivotZOffset = baseline.pivot_z
                end)
                if ok then
                    restored = restored + 1
                end
                append_log(
                    "HEIGHT ENTRY PIVOTZ RESTORE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | Key=" .. key_text ..
                    " | Target=" .. tostring(baseline.pivot_z) ..
                    " | WriteOK=" .. tostring(ok)
                )
            end
        end
    end

    append_log(
        "HEIGHT ENTRY TEST RESTORE | Reason=" .. tostring(reason) ..
        " | Restored=" .. tostring(restored)
    )
    clear_height_entry_test()
    return restored
end

restore_lock_camera_test = function(reason)
    local restored = 0
    if height_entry_test.active or
        height_entry_test.target_offset_z ~= nil or
        height_entry_test.pivot_z ~= nil then
        restored = restore_height_entry_test(reason)
    end
    return restored
end

-- Final camera-chain diagnostics. These snapshots intentionally read the
-- PlayerCameraManager output in addition to the FollowCamera/CameraMode data.
local camera_chain_probe_generation = 0

local function read_camera_pov(owner, cache_field)
    if not valid_object(owner) then
        return {
            location_x = nil,
            location_y = nil,
            location_z = nil,
            pitch = nil,
            yaw = nil,
            roll = nil,
            fov = nil,
            cache = nil,
            pov = nil,
        }
    end

    local cache = get_unwrapped_field(owner, cache_field)
    local pov = get_unwrapped_field(cache, "POV")
    local location = get_unwrapped_field(pov, "Location")
    local rotation = get_unwrapped_field(pov, "Rotation")
    return {
        location_x = tonumber(get_unwrapped_field(location, "X")),
        location_y = tonumber(get_unwrapped_field(location, "Y")),
        location_z = tonumber(get_unwrapped_field(location, "Z")),
        pitch = tonumber(get_unwrapped_field(rotation, "Pitch")),
        yaw = tonumber(get_unwrapped_field(rotation, "Yaw")),
        roll = tonumber(get_unwrapped_field(rotation, "Roll")),
        fov = tonumber(get_unwrapped_field(pov, "FOV")),
        cache = cache,
        pov = pov,
    }
end

local function camera_chain_snapshot(reason, delay_ms)
    local controller, manager = get_player_camera_manager()
    local current = read_camera_pov(manager, "CameraCachePrivate")
    local last = read_camera_pov(manager, "LastFrameCameraCachePrivate")
    local current_view_target = get_field(manager, "ViewTarget")
    local pending_view_target = get_field(manager, "PendingViewTarget")

    local method_location = nil
    local method_rotation = nil
    local method_fov = nil
    if valid_object(manager) then
        pcall(function() method_location = manager:GetCameraLocation() end)
        pcall(function() method_rotation = manager:GetCameraRotation() end)
        pcall(function() method_fov = manager:GetFOVAngle() end)
    end

    append_log(
        "CAMERA CHAIN SNAPSHOT" ..
        " | Reason=" .. tostring(reason) ..
        " | DelayMs=" .. tostring(delay_ms or 0) ..
        " | Controller=" .. safe_full_name(controller) ..
        " | PlayerCameraManager=" .. safe_full_name(manager) ..
        " | ViewTarget=" .. tostring(current_view_target) ..
        " | PendingViewTarget=" .. tostring(pending_view_target) ..
        " | CurrentPOV.Location=" .. tostring(current.location_x) .. "," .. tostring(current.location_y) .. "," .. tostring(current.location_z) ..
        " | CurrentPOV.Rotation=" .. tostring(current.pitch) .. "," .. tostring(current.yaw) .. "," .. tostring(current.roll) ..
        " | CurrentPOV.FOV=" .. tostring(current.fov) ..
        " | LastPOV.Location=" .. tostring(last.location_x) .. "," .. tostring(last.location_y) .. "," .. tostring(last.location_z) ..
        " | LastPOV.Rotation=" .. tostring(last.pitch) .. "," .. tostring(last.yaw) .. "," .. tostring(last.roll) ..
        " | LastPOV.FOV=" .. tostring(last.fov) ..
        " | MethodLocation=" .. tostring(method_location) ..
        " | MethodRotation=" .. tostring(method_rotation) ..
        " | MethodFOV=" .. tostring(method_fov)
    )
end

function CloUtil.snap_manager_fov_to_default()
    local _, manager = get_player_camera_manager()
    if not valid_object(manager) then
        return false
    end

    local before = nil
    pcall(function()
        before = manager:GetFOVAngle()
    end)

    local target_fov = 90.0
    pcall(function()
        manager:SetFOVAngle(target_fov)
    end)

    local after = nil
    pcall(function()
        after = manager:GetFOVAngle()
    end)

    append_log(
        "MANAGER FOV SNAP" ..
        " | Before=" .. tostring(before) ..
        " | Target=" .. tostring(target_fov) ..
        " | After=" .. tostring(after)
    )

    return true
end

function CloUtil.schedule_unlock_fov_fixup(reason)
    if type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        return
    end

    local generation = runtime_generation
    for _, delay_ms in ipairs({ 0, 100, 300 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= runtime_generation then
                return
            end

            ExecuteInGameThread(function()
                if generation ~= runtime_generation or lock_active then
                    return
                end

                pcall(function()
                    CloUtil.restore_stuck_lock_fov(
                        reason .. "+UnlockFix@" .. tostring(delay_ms),
                        false
                    )
                    if not CloUtil.in_combat_context() then
                        CloUtil.snap_manager_fov_to_default()
                    elseif config.FOVEnabled and
                        CloUtil.in_combat_context() then
                        CloUtil.refresh_combat_fov_view(
                            reason .. "+UnlockFix@" .. tostring(delay_ms),
                            false
                        )
                    end
                end)
            end)
        end)
    end
end

schedule_camera_chain_probe = function(reason)
    return
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

function CloUtil.enforce_unlocked_camera(reason)
    if lock_active or not mod_enabled then
        return false
    end

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
    end

    local camera = camera_from_combat(combat)
    if not valid_object(camera) and valid_object(tracked_camera) then
        camera = tracked_camera
    end
    if not valid_object(camera) then
        return false
    end

    local changed = false
    local current_type = nil
    pcall(function()
        current_type = camera:GetCameraType()
    end)

    if current_type == CAMERA_TYPE_NONE then
        local keep_combat_type = CloUtil.in_combat_context() and
            CloUtil.combat_fov.fov_type_pulse_done
        if not keep_combat_type then
            append_log(
                "UNLOCK CAMERA ENFORCE" ..
                " | Reason=" .. tostring(reason) ..
                " | StuckCameraType=0 -> 1"
            )
            restore_camera_type(camera, CAMERA_TYPE_DEFAULT)
            changed = true
        end
    end

    if valid_object(combat) then
        local detached = unwrap_value(get_field(combat, "bCameraDetachedFromTarget"))
        if detached ~= true then
            CloUtil.force_camera_detached(combat, reason)
            changed = true
        end
    end

    return changed
end

function CloUtil.force_camera_detached(combat, reason)
    if not valid_object(combat) then
        return false
    end

    local address = object_address(combat)
    if address ~= nil then
        saved_camera_detached[address] = nil
    end

    local ok = set_field(combat, "bCameraDetachedFromTarget", true)
    append_log(
        "CAMERA DETACH ENFORCE" ..
        " | Reason=" .. tostring(reason) ..
        " | DetachedFromTarget=true | Success=" .. tostring(ok)
    )
    return ok
end

function CloUtil.force_unlock_cleanup(combat, reason)
    append_log("FORCE UNLOCK CLEANUP | Reason=" .. tostring(reason))

    if lock_active then
        CloUtil.end_fov_lock_session(reason)
        return true
    end

    return false
end

function CloUtil.schedule_post_unlock_camera_cleanup()
    if type(ExecuteWithDelay) ~= "function" then
        return
    end

    local generation = runtime_generation
    for _, delay_ms in ipairs({ 0, 50, 100, 250, 500, 1000 }) do
        ExecuteWithDelay(delay_ms, function()
            if generation ~= runtime_generation then
                return
            end

            local function run_enforce()
                if generation ~= runtime_generation or lock_active then
                    return
                end
                CloUtil.enforce_unlocked_camera("PostUnlock+" .. tostring(delay_ms) .. "ms")
            end

            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(run_enforce)
            else
                run_enforce()
            end
        end)
    end
end

local function apply_enemy_offset_y_to_mode(mode, target_y, reason, index)
    if not valid_object(mode) or target_y == nil then
        return false
    end
    if is_ability_mode(mode) or CloUtil.is_transient_overlay_mode(mode) then
        return false
    end

    local offset = get_field(mode, "CameraLocationOffsetDuringTargeting")
    if offset == nil then
        return false
    end

    local before_y = readable_probe_number(get_field(offset, "Y"))
    if before_y ~= nil and math.abs(before_y - target_y) < 0.001 then
        return true
    end

    local nested_ok, struct_ok, fresh_y = write_active_targeting_offset_y(mode, offset, target_y)
    local readback_ok = fresh_y ~= nil and math.abs(fresh_y - target_y) < 0.001

    append_log(
        ((nested_ok and struct_ok and readback_ok) and "ENEMY OFFSET WRITE" or "ENEMY OFFSET WRITE FAILED") ..
        " | Reason=" .. tostring(reason) ..
        " | Index=" .. tostring(index) ..
        " | Mode=" .. safe_full_name(mode) ..
        " | BeforeY=" .. tostring(before_y) ..
        " | TargetY=" .. tostring(target_y) ..
        " | FreshAfterY=" .. tostring(fresh_y) ..
        " | Readback=" .. tostring(readback_ok)
    )

    return nested_ok and struct_ok and readback_ok
end

-- Apply EnemyOffset Y to CameraModes on the live CameraModeStack.
apply_combat_offset_fix = function(target_y_override, reason)
    local target_y = target_y_override
    if target_y == nil then
        target_y = CloUtil.enemy_offset_target_y()
    end

    tracked_camera = nil
    local camera = camera_from_combat(tracked_combat)
    if not valid_object(camera) then
        local combat = find_combat_component()
        tracked_combat = combat
        camera = camera_from_combat(combat)
    end
    tracked_camera = camera

    if not valid_object(camera) then
        append_log("ENEMY OFFSET APPLY FAILED | Reason=" .. tostring(reason) ..
            " | TargetY=" .. tostring(target_y) .. " | CameraUnavailable=true")
        return 0
    end

    local stack = get_field(camera, "CameraModeStack")
    if stack == nil then
        append_log("ENEMY OFFSET APPLY FAILED | Reason=" .. tostring(reason) ..
            " | TargetY=" .. tostring(target_y) .. " | CameraModeStackUnavailable=true")
        return 0
    end

    local depth = 0
    local depth_ok = pcall(function()
        depth = stack:GetArrayNum()
    end)
    if not depth_ok or type(depth) ~= "number" or depth <= 0 then
        append_log("ENEMY OFFSET APPLY FAILED | Reason=" .. tostring(reason) ..
            " | TargetY=" .. tostring(target_y) ..
            " | StackDepth=" .. tostring(depth) .. " | StackUnavailable=true")
        return 0
    end

    local changed = 0
    for index = 1, depth do
        local entry = nil
        pcall(function()
            entry = stack[index]
        end)
        if entry ~= nil then
            local mode = nil
            pcall(function()
                mode = entry.CameraMode
            end)
            if apply_enemy_offset_y_to_mode(mode, target_y, reason, index) then
                changed = changed + 1
            end
        end
    end

    append_log(
        "ENEMY OFFSET APPLY | Reason=" .. tostring(reason) ..
        " | TargetY=" .. tostring(target_y) ..
        " | Changed=" .. tostring(changed) ..
        " | LockActive=" .. tostring(lock_active)
    )

    return changed
end

function CloUtil.apply_enemy_offset(reason)
    if not mod_enabled then
        return 0
    end
    return apply_combat_offset_fix(CloUtil.enemy_offset_target_y(), reason)
end

function CloUtil.apply_lock_offsets(reason)
    if CloUtil.is_defensive_combat_state() then
        return
    end
    if CloUtil.combat_offset_z_wanted() then
        CloUtil.apply_combat_offset_z(reason)
    end
    if lock_active then
        apply_combat_offset_fix(CloUtil.enemy_offset_target_y(), reason)
    end
end

function CloUtil.restore_lock_offsets(reason)
    CloUtil.restore_combat_offset_z(reason)
    if mod_enabled then
        apply_combat_offset_fix(COMBAT_OFFSET_DEFAULT_Y, reason)
    end
end

local function restore_fov_defaults()
    local restored = 0
    local failed = 0

    for address, saved in pairs(saved_modes) do
        if valid_object(saved.mode) and saved.fov ~= nil then
            local target_fov = saved.fov
            if type(target_fov) == "number" and
                math.abs(target_fov - config.LockOnFOV) < 0.001 then
                target_fov = CloUtil.unlock_baseline_fov(saved.mode)
            end

            local ok = set_field(saved.mode, "DefaultFieldOfView", target_fov)
            if ok then
                restored = restored + 1
            else
                failed = failed + 1
            end
        else
            saved_modes[address] = nil
        end
    end

    append_log(
        "Unlock FOV restore | restored=" .. tostring(restored) ..
        " | failed=" .. tostring(failed)
    )

    return restored, failed
end

function CloUtil.end_fov_lock_session(reason)
    if not lock_active then
        return
    end

    stop_stack_poll()

    local combat = tracked_combat
    if not valid_object(combat) then
        combat = find_combat_component()
    end

    local camera = tracked_camera
    if not valid_object(camera) then
        camera = camera_from_combat(combat)
    end

    local restore_type = previous_camera_type
    if restore_type == nil then
        restore_type = CAMERA_TYPE_DEFAULT
    end

    local keep_combat_type = CloUtil.in_combat_context() and
        CloUtil.combat_fov.fov_type_pulse_done
    if keep_combat_type then
        append_log(
            "LOCK OFF CAMERA TYPE HOLD" ..
            " | CurrentType=0" ..
            " | SessionActive=true"
        )
    else
        local camera_ok, camera_err = pcall(function()
            if valid_object(camera) then
                restore_camera_type(camera, restore_type)
            end
        end)
        if not camera_ok then
            append_log("FOV SESSION END CAMERA ERROR | " .. tostring(camera_err))
        end
    end

    local detach_ok, detach_err = pcall(function()
        if valid_object(combat) then
            set_camera_detached_state(combat, false)
        end
    end)
    if not detach_ok then
        append_log("FOV SESSION END DETACH ERROR | " .. tostring(detach_err))
    end

    pcall(function()
        CloUtil.restore_lock_offsets(reason)
    end)

    stop_pitch_monitor("LockOff")
    saved_camera_detached = {}
    previous_camera_type = nil
    tracked_combat = nil
    tracked_camera = nil
    CloUtil.set_active_lock_target(nil)
    lock_active = false

    append_log("FOV SESSION END | Reason=" .. tostring(reason))

    CloUtil.schedule_post_unlock_camera_cleanup()
    if type(schedule_camera_chain_probe) == "function" then
        schedule_camera_chain_probe("LockOff+" .. tostring(reason))
    end
end

set_camera_detached_state = function(combat, turn_on)
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

    saved_camera_detached[address] = nil
    return set_field(combat, "bCameraDetachedFromTarget", true)
end

local function refresh_lock_target_swap(combat)
    if not lock_active or not valid_object(combat) then
        return
    end

    local lock_target, target_field = CloUtil.read_lock_target_actor(combat)
    local new_address, new_name = CloUtil.describe_lock_target(lock_target)
    if new_address == nil then
        append_log("LOCK TARGET SWAP SKIPPED | Reason=NoTarget")
        return
    end
    if new_address == CloUtil.lock_target.address then
        append_log(
            "LOCK TARGET SWAP SKIPPED | Reason=SameTarget" ..
            " | Address=" .. tostring(new_address) ..
            " | Name=" .. tostring(new_name)
        )
        return
    end

    local tracked_gone, tracked_reason = CloUtil.is_tracked_lock_target_gone()
    if tracked_gone then
        if game_hard_lock_active and CloUtil.in_combat_context() then
            append_log(
                "LOCK TARGET SWAP PENDING" ..
                " | Reason=TrackedTargetDead" ..
                " | Detail=" .. tostring(tracked_reason) ..
                " | OldTarget=" .. tostring(CloUtil.lock_target.name) ..
                " | NextTarget=" .. tostring(new_name)
            )
            CloUtil.set_active_lock_target(nil)
            CloUtil.schedule_lock_state_probe_after_swap(
                combat,
                "TargetSwapAfterDeath"
            )
            return
        end

        append_log(
            "LOCK TARGET SWAP -> LOCK OFF" ..
            " | Reason=TrackedTargetDead" ..
            " | Detail=" .. tostring(tracked_reason) ..
            " | OldTarget=" .. tostring(CloUtil.lock_target.name) ..
            " | NewTarget=" .. tostring(new_name)
        )
        CloUtil.schedule_lock_state_probe_after_swap(
            combat,
            "TargetSwapAfterDeath"
        )
        CloUtil.sync_lock_with_game("TargetSwapAfterDeath")
        return
    end

    CloUtil.log_lock_target_changed(
        CloUtil.lock_target.address,
        CloUtil.lock_target.name,
        lock_target,
        "TargetSwap",
        target_field
    )
    CloUtil.set_active_lock_target(lock_target)
    tracked_combat = combat

    local camera = camera_from_combat(combat)
    if valid_object(camera) then
        tracked_camera = camera
    end

    if lock_active then
        CloUtil.apply_lock_offsets("TargetSwap")
    end

    append_log(
        "LOCK TARGET SWAP" ..
        " | Address=" .. tostring(new_address) ..
        " | Name=" .. tostring(new_name)
    )

    CloUtil.schedule_lock_state_probe_after_swap(combat, "TargetSwap")
end

local function refresh_active_lock()
    if not lock_active then
        return
    end

    if CloUtil.is_defensive_combat_state() then
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

        CloUtil.apply_lock_offsets("LockRefresh")

        local lock_target = CloUtil.read_lock_target_actor(combat)
        CloUtil.set_active_lock_target(lock_target)

    end
end

apply_lock_fov = function(combat, locked)
    if locked then
        if not mod_enabled then
            if config.EnableLog then
                append_log("LOCK ON SKIPPED | Reason=ModDisabled")
            end
            return false
        end

        if test_camera_enabled then
            set_test_camera_enabled(false)
        end

        local camera = camera_from_combat(combat)
        if camera == nil then
            append_log("LOCK ON ERROR | CameraUnavailable=true")
            return false
        end

        tracked_combat = combat
        tracked_camera = camera

        lock_active = true

        local camera_ok = true
        local detached_ok = false

        if CloUtil.is_defensive_combat_state() then
            CloUtil.combat_fov.lock_writes_deferred = true
            start_stack_poll()
            if config.EnableLog then
                append_log(
                    "LOCK ON DEFERRED WRITES | Reason=DefensiveState" ..
                    " | CurrentState=" .. tostring(CloUtil.combat_fov.last_state)
                )
            end
            return true
        end

        if previous_camera_type == nil then
            local camera_type = CAMERA_TYPE_DEFAULT
            if not CloUtil.combat_fov.fov_type_pulse_done then
                pcall(function()
                    camera_type = camera:GetCameraType()
                end)
            end
            previous_camera_type = camera_type
        end

        camera_ok = pcall(function()
            camera:SetCameraType(CAMERA_TYPE_NONE)
        end)

        detached_ok = set_camera_detached_state(combat, true)

        CloUtil.combat_fov.lock_writes_deferred = false
        CloUtil.apply_lock_offsets("LockOn")
        start_stack_poll()

        append_log(
            "FOV LOCK ON" ..
            " | LockOnFOV=" .. tostring(config.LockOnFOV) ..
            " | FOVEnabled=" .. tostring(config.FOVEnabled) ..
            " | PreviousCameraType=" .. tostring(previous_camera_type) ..
            " | SetCameraType0=" .. tostring(camera_ok) ..
            " | DetachedFromTarget=false=" .. tostring(detached_ok) ..
            " | FOVApplied=" .. tostring(fov_applied)
        )

        return camera_ok
    end

    if lock_active then
        CloUtil.end_fov_lock_session("LockOff")
    end
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

function CloUtil.apply_fov_to_active_stack_top(target_fov, reason)
    if type(target_fov) ~= "number" then
        return false
    end

    local camera = get_player_camera_for_offset()
    if not valid_object(camera) then
        return false
    end

    local depth_ok, depth = get_camera_stack_depth(camera)
    if not depth_ok or type(depth) ~= "number" or depth <= 0 then
        return false
    end

    local mode = get_camera_stack_mode(camera, depth)
    if not valid_object(mode) or CloUtil.is_transient_overlay_mode(mode) then
        return false
    end

    cache_mode(mode)
    local wrote = set_field(mode, "DefaultFieldOfView", target_fov)
    if wrote and config.EnableLog and reason ~= nil then
        append_log(
            "COMBAT STACK TOP FOV" ..
            " | Reason=" .. tostring(reason) ..
            " | Depth=" .. tostring(depth) ..
            " | Target=" .. tostring(target_fov) ..
            " | Mode=" .. safe_full_name(mode)
        )
    end

    return wrote == true
end

local function is_transient_overlay_stack_top(camera, depth)
    if type(depth) ~= "number" or depth <= 0 then
        return false
    end

    local top_mode = get_camera_stack_mode(camera, depth)
    if not valid_object(top_mode) then
        return false
    end

    return CloUtil.is_transient_overlay_mode(top_mode)
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

    if config.EnableLog then
        append_log(
            "CameraType " .. tostring(before) ..
            " -> " .. tostring(desired_type) ..
            " | success=" .. tostring(ok) ..
            " | readback=" .. tostring(after) ..
            " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
            " | StackDepth=" .. tostring(depth)
        )
    end

    return ok
end

stop_stack_poll = function()
    stack_poll_generation = stack_poll_generation + 1
    stack_poll_active = false
    CloUtil.stack_overlay.active = false
    CloUtil.stack_overlay.recovery_pending = false
    CloUtil.stack_overlay.quiet_until_ms = 0
    CloUtil.stack_overlay.recovery_generation = CloUtil.stack_overlay.recovery_generation + 1
    last_stack_depth = nil
    last_lock_test_mode_address = nil
    baseline_stack_depth = nil
end

function CloUtil.schedule_overlay_stack_recovery(stack_generation)
    if type(ExecuteWithDelay) ~= "function" or
        type(ExecuteInGameThread) ~= "function" then
        return
    end

    local overlay = CloUtil.stack_overlay
    overlay.recovery_generation = overlay.recovery_generation + 1
    local recovery_generation = overlay.recovery_generation

    ExecuteWithDelay(overlay.recovery_ms, function()
        if recovery_generation ~= overlay.recovery_generation or
            stack_generation ~= stack_poll_generation or
            not stack_poll_active or
            not lock_active or
            not game_hard_lock_active then
            return
        end

        ExecuteInGameThread(function()
            if recovery_generation ~= overlay.recovery_generation or
                stack_generation ~= stack_poll_generation or
                not stack_poll_active or
                not lock_active or
                not game_hard_lock_active then
                return
            end

            local camera = tracked_camera
            if not valid_object(camera) then
                camera = camera_from_combat(tracked_combat)
                tracked_camera = camera
            end

            if not valid_object(camera) then
                return
            end

            if CloUtil.is_defensive_combat_state() then
                return
            end

            local depth_ok, depth = get_camera_stack_depth(camera)
            if not depth_ok or baseline_stack_depth == nil then
                return
            end

            local overlay_top = is_transient_overlay_stack_top(camera, depth)
            local overlay_depth = baseline_stack_depth ~= nil and
                depth > baseline_stack_depth
            local stack_stable = depth == baseline_stack_depth and
                not overlay_top and
                not overlay_depth

            if not stack_stable then
                if overlay_top or overlay_depth then
                    overlay.recovery_pending = true
                    CloUtil.schedule_overlay_stack_recovery(stack_generation)
                    if config.EnableLog then
                        append_log(
                            "STACK OVERLAY RECOVERY DEFERRED" ..
                            " | Depth=" .. tostring(depth) ..
                            " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
                            " | OverlayTop=" .. tostring(overlay_top) ..
                            " | OverlayDepth=" .. tostring(overlay_depth)
                        )
                    end
                else
                    overlay.recovery_pending = false
                end
                return
            end

            pcall(function()
                set_stack_camera_type(CAMERA_TYPE_NONE, depth)
            end)

            overlay.recovery_pending = false

            if config.EnableLog then
                append_log(
                    "STACK OVERLAY RECOVERY DONE" ..
                    " | Depth=" .. tostring(depth) ..
                    " | BaseStackDepth=" .. tostring(baseline_stack_depth)
                )
            end

            if mod_enabled and config.FOVEnabled and CloUtil.in_combat_context() then
                CloUtil.refresh_combat_fov_view("OverlayRecovery", false)
            end
        end)
    end)
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
            not lock_active or
            not game_hard_lock_active then
            if generation == stack_poll_generation and stack_poll_active then
                stop_stack_poll()
            end
            return
        end

        local camera = tracked_camera
        if not valid_object(camera) then
            camera = camera_from_combat(tracked_combat)
            tracked_camera = camera
        end

        local ok, depth = get_camera_stack_depth(camera)
        if ok then
            local stack_changed = last_stack_depth == nil or depth ~= last_stack_depth

            if stack_changed then
                local previous_depth = last_stack_depth
                last_stack_depth = depth
                if config.EnableLog then
                    append_log(
                        "CameraModeStack depth changed" ..
                        " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
                        " | PreviousDepth=" .. tostring(previous_depth) ..
                        " | CurrentDepth=" .. tostring(depth)
                    )
                    log_camera_mode_stack_probe(camera, depth)
                end
            end

            local overlay_top = is_transient_overlay_stack_top(camera, depth)
            local overlay_depth = baseline_stack_depth ~= nil and
                depth > baseline_stack_depth
            local overlay_active = overlay_top or overlay_depth
            local was_overlay = CloUtil.stack_overlay.active

            if overlay_active and stack_changed then
                CloUtil.stack_overlay.recovery_generation = CloUtil.stack_overlay.recovery_generation + 1
            end

            CloUtil.stack_overlay.active = overlay_active
            CloUtil.combat_fov.paused = overlay_active

            if not CloUtil.is_defensive_combat_state() then
                if CloUtil.combat_fov.lock_writes_deferred then
                    CloUtil.apply_deferred_lock_writes("StackPoll")
                end

                if baseline_stack_depth ~= nil then
                    if depth > baseline_stack_depth then
                        -- Release lock camera type while overlay modes sit above baseline.
                        CloUtil.stack_overlay.recovery_pending = false
                        set_stack_camera_type(CAMERA_TYPE_DEFAULT, depth)
                    elseif depth == baseline_stack_depth and not overlay_top then
                        if CloUtil.stack_overlay.recovery_pending then
                            -- Deferred handler will restore lock camera type.
                        elseif was_overlay and stack_changed then
                            CloUtil.stack_overlay.recovery_pending = true
                            CloUtil.schedule_overlay_stack_recovery(generation)
                            if config.EnableLog then
                                append_log(
                                    "STACK OVERLAY RECOVERY SCHEDULED" ..
                                    " | DelayMs=" .. tostring(CloUtil.stack_overlay.recovery_ms) ..
                                    " | Depth=" .. tostring(depth)
                                )
                            end
                        elseif stack_changed then
                            set_stack_camera_type(CAMERA_TYPE_NONE, depth)
                        end
                    elseif stack_changed and depth < baseline_stack_depth then
                        append_log(
                            "CameraModeStack below baseline | no recovery" ..
                            " | BaseStackDepth=" .. tostring(baseline_stack_depth) ..
                            " | CurrentDepth=" .. tostring(depth)
                        )
                    end
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
        local active_mode = select(1, find_active_lock_camera_mode(camera))
        last_lock_test_mode_address = object_address(active_mode)
        append_log(
            "Lock-On StackDepth baseline captured" ..
            " | BaseStackDepth=" .. tostring(baseline_stack_depth)
        )
    else
        baseline_stack_depth = nil
        last_stack_depth = nil
        last_lock_test_mode_address = nil
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

    local bound = CloUtil.combat_from_outer_object(mode)
    if valid_object(bound) then
        set_combat_component(bound, "CameraMode")
        local bound_mode = tonumber(
            unwrap_value(get_field(bound, "CurrentCombatMode"))
        )
        if bound_mode ~= nil and bound_mode ~= 0 then
            if not CloUtil.combat_fov.session_active then
                append_log(
                    "COMBAT ENTER DETECTED | PreviousCombatMode=" ..
                    tostring(combat_mode_last) ..
                    " | CurrentCombatMode=" .. tostring(bound_mode) ..
                    " | LockActive=" .. tostring(lock_active)
                )
                CloUtil.begin_combat_session(bound, "CombatEnter", true)
            elseif not fov_applied and
                not CloUtil.combat_fov.sheath_abort_rearm_pending then
                CloUtil.bootstrap_combat_fov("CombatEnterCatchup")
            end
        end
    end

    if CloUtil.combat_mod_active() and config.FOVEnabled and
        not CloUtil.combat_fov.sheath_abort_rearm_pending and
        not CloUtil.is_transient_overlay_mode(mode) then
        if fov_applied then
            CloUtil.refresh_combat_fov_view("NewCameraMode", false)
            if CloUtil.combat_fov.exit_zero_since_ms == nil then
                CloUtil.repulse_combat_fov_camera_type("NewCameraMode")
            end
        else
            local target = tonumber(config.LockOnFOV) or 110.0
            cache_mode(mode)
            set_field(mode, "DefaultFieldOfView", target)
            CloUtil.publish_combat_fov_to_view(target, "NewCameraMode", false)
        end
    end

    if lock_active and CloUtil.combat_mod_active() and
        not CloUtil.is_defensive_combat_state() then
        if CloUtil.combat_offset_z_wanted() then
            CloUtil.apply_combat_offset_z_to_mode(mode, "NewCameraMode", nil)
        end
        apply_combat_offset_fix(CloUtil.enemy_offset_target_y(), "NewCameraMode")
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
    CloUtil.combat_fov.session_active = false
    CloUtil.combat_fov.exit_pending = 0
    CloUtil.combat_fov.lock_writes_deferred = false
    CloUtil.combat_fov.last_state = nil
    CloUtil.combat_fov.restore_view_fov = nil
    CloUtil.combat_fov.sheath_abort_rearm_pending = false
    lock_active = false
    game_hard_lock_active = false
    CloUtil.set_active_lock_target(nil)
    lock_camera_test_enabled = false
    lock_camera_test_cache = {}
    lock_camera_test_suspended = false
    test_camera_enabled = false
    test_camera_base = nil
    test_camera_suspended = false
    clear_height_entry_test()
    combat_offset_z.modes = {}
    combat_offset_z.active = false

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
        combat_component_name_logged = false

        if type(FindAllOf) == "function" then
            local ok, cache_ok, cache_count = pcall(rebuild_mode_cache)
            if ok then
                append_log(
                    "WORLD RUNTIME REINIT CACHE" ..
                    " | Reason=" .. tostring(reason) ..
                    " | CacheOk=" .. tostring(cache_ok) ..
                    " | CachedModes=" .. tostring(cache_count)
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

        game_hard_lock_active = locked

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
            " | GameHardLock=" .. tostring(game_hard_lock_active) ..
            " | FOVApplied=" .. tostring(fov_before) ..
            " | PreviousCameraType=" .. tostring(prev_camera_before)
        )

        -- A duplicate HardLock event must not start/reset another session.
        -- In particular, a duplicate ON must never overwrite the original
        -- CameraType captured at the first ON.
        if locked and state_before then
            append_log(
                "HARDLOCK DUPLICATE EVENT | Event=ON" ..
                " | LockActiveBefore=true" ..
                " | Action=ignored"
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
                " | LockActiveBefore=false | Action=cleanup"
            )

            pcall(function()
                CloUtil.force_unlock_cleanup(combat, "HardLockDuplicateOFF")
            end)

            append_log(
                "HARDLOCK HANDLER COMPLETE" ..
                " | Event=OFF" ..
                " | Duplicate=true" ..
                " | Action=cleanup" ..
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

-- This is the single implementation used by the `clo fov 0/1` console
-- commands. The master switch below uses its own `clo mod 0/1` path so FOV,
-- offset, and camera test modifications can be controlled together.
local function set_fov_enabled(enabled, source)
    enabled = enabled == true

    if not enabled then
        CloUtil.stop_combat_fov_tween("FovCommandOff")
        if fov_applied then
            pcall(restore_fov_defaults)
        end

        config.FOVEnabled = false
        fov_applied = false

        append_log(
            "FOV COMMAND | Enabled=false" ..
            " | Source=" .. tostring(source)
        )
        return true
    end

    config.FOVEnabled = true

    local applied = false
    if mod_enabled and CloUtil.in_combat_context() then
        applied = CloUtil.start_combat_fov_tween("in", "FovCommandOn")
    end

    append_log(
        "FOV COMMAND | Enabled=true" ..
        " | LockOnFOV=" .. tostring(config.LockOnFOV) ..
        " | CombatTweenStarted=" .. tostring(applied) ..
        " | Source=" .. tostring(source)
    )

    return true
end

local function set_mod_enabled(enabled, source)
    enabled = enabled == true

    if not enabled then
        stop_pitch_monitor("MasterOff")
        CloUtil.stop_combat_fov_tween("MasterOff")
        if lock_active then
            CloUtil.restore_lock_offsets("MasterOff")
        end
        if fov_applied then
            pcall(restore_fov_defaults)
        end
        fov_applied = false

        if test_camera_enabled then
            test_camera_suspended = true
            set_test_camera_enabled(false)
        end

        mod_enabled = false
        append_log(
            "MASTER COMMAND | Enabled=false" ..
            " | Source=" .. tostring(source)
        )
        return true
    end

    mod_enabled = true

    if CloUtil.in_combat_context() and mod_enabled and config.FOVEnabled then
        local tween_reason = "MasterOn"
        if CloUtil.combat_fov.pending_enter then
            tween_reason = "PendingCombatEnter"
        end
        CloUtil.start_combat_fov_tween("in", tween_reason)
    end

    if lock_active then
        CloUtil.apply_lock_offsets("MasterOn")
    elseif test_camera_suspended then
        test_camera_suspended = false
        set_test_camera_enabled(true)
    end

    append_log(
        "MASTER COMMAND | Enabled=true" ..
        " | FOVEnabled=" .. tostring(config.FOVEnabled) ..
        " | LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ) ..
        " | EnemyOffset=" .. tostring(config.EnemyOffset) ..
        " | Source=" .. tostring(source)
    )
    return true
end

local function run_fov_command(enabled, source)
    local function apply_command()
        set_fov_enabled(enabled, source)
    end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(apply_command)
    else
        apply_command()
    end
end

local function run_mod_command(enabled, source)
    local function apply_command()
        set_mod_enabled(enabled, source)
    end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(apply_command)
    else
        apply_command()
    end
end

local function register_mod_hotkey(key_code, key_name, enabled)
    if key_code == nil then
        append_log(
            "HOTKEY UNAVAILABLE | " .. tostring(key_name) ..
            " key is not present in the UE4SS Key table"
        )
        return false
    end

    local ok, err = pcall(function()
        RegisterKeyBind(key_code, function()
            run_mod_command(
                enabled,
                key_name .. " -> clo mod " .. (enabled and "1" or "0")
            )
        end)
    end)

    if ok then
        append_log(
            "HOTKEY REGISTERED | " .. tostring(key_name) ..
            "=clo mod " .. (enabled and "1" or "0")
        )
    else
        append_log(
            "HOTKEY REGISTER FAILED | " .. tostring(key_name) ..
            " | Error=" .. tostring(err)
        )
    end

    return ok
end


function CloUtil.nudge_enemy_offset(delta, source)
    local value = (tonumber(config.EnemyOffset) or COMBAT_OFFSET_DEFAULT_Y) + (tonumber(delta) or 0)
    config.EnemyOffset = value

    if mod_enabled and lock_active then
        CloUtil.apply_enemy_offset(source or "NudgeEnemyOffset")
    end

    append_log(
        "ENEMY OFFSET NUDGE | EnemyOffset=" .. tostring(config.EnemyOffset) ..
        " | Source=" .. tostring(source)
    )
    return config.EnemyOffset
end

function CloUtil.nudge_lock_on_fov(delta, source)
    local value = (tonumber(config.LockOnFOV) or 110) + (tonumber(delta) or 0)
    if value < 1 then
        value = 1
    elseif value > 179 then
        value = 179
    end

    config.LockOnFOV = value

    if mod_enabled and config.FOVEnabled and CloUtil.in_combat_context() then
        CloUtil.start_combat_fov_tween("in", source or "NudgeFOV")
    end

    append_log(
        "FOV NUDGE | LockOnFOV=" .. tostring(config.LockOnFOV) ..
        " | Source=" .. tostring(source)
    )
    return config.LockOnFOV
end

function CloUtil.nudge_lock_on_offset_z(delta, source)
    local value = (tonumber(config.LockOnOffsetZ) or 0) + (tonumber(delta) or 0)
    config.LockOnOffsetZ = value

    if mod_enabled and lock_active and CloUtil.combat_offset_z_wanted() then
        CloUtil.apply_combat_offset_z(source or "NudgeZ")
    elseif mod_enabled and lock_active then
        CloUtil.restore_combat_offset_z(source or "NudgeZZero")
    end

    append_log(
        "OFFSET Z NUDGE | LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ) ..
        " | Source=" .. tostring(source)
    )
    return config.LockOnOffsetZ
end

-- PageDown/PageUp are the master switch for FOV, offset, and camera tests.
-- End is a log-only combat-over mark and must not disable the mod.
if type(RegisterKeyBind) == "function" and type(Key) == "table" then
    register_mod_hotkey(Key.PAGE_DOWN, "PageDown", false)
    register_mod_hotkey(Key.PAGE_UP, "PageUp", true)
    pcall(function()
        local end_key = Key.END or Key.End or Key.END_KEY
        if end_key == nil then
            append_log("HOTKEY UNAVAILABLE | End key is not present in the UE4SS Key table")
            return
        end
        local ok, err = pcall(function()
            RegisterKeyBind(end_key, function()
                CloUtil.log_user_mark("End")
            end)
        end)
        if ok then
            append_log("HOTKEY REGISTERED | End=USER MARK CombatOver")
        else
            append_log(
                "HOTKEY REGISTER FAILED | End | Error=" .. tostring(err)
            )
        end
    end)
else
    append_log("HOTKEY UNAVAILABLE | RegisterKeyBind or Key table unavailable")
end

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
            Ar:Log("clo mod 0 | clo mod 1")
            Ar:Log("clo fov 0 | clo fov 1 | clo fov value <1-179>")
            Ar:Log("clo offset value <number>  (120 = game default)")
            Ar:Log("clo z <value>   (runtime LockOnOffsetZ; also saved for this session)")
            Ar:Log("clo ui | clo fovstatus")
            Ar:Log("clo ver")
            Ar:Log("clo mark          (log CombatOver; same as End)")
            Ar:Log("PageDown = master OFF | PageUp = master ON | End = USER MARK")
            return true
        end

        if command == "ver" then
            Ar:Log("LockOnFovChanger version: " .. SCRIPT_VERSION)
            return true
        end

        if command == "mark" then
            CloUtil.log_user_mark("Console: clo mark")
            Ar:Log("USER MARK CombatOver written")
            return true
        end

        if command == "mod" then
            if arg == "0" then
                run_mod_command(false, "Console: clo mod 0")
                Ar:Log("ModEnabled=false")
                return true
            end

            if arg == "1" then
                run_mod_command(true, "Console: clo mod 1")
                Ar:Log("ModEnabled=true")
                return true
            end

            Ar:Log("Usage: clo mod 0 | clo mod 1")
            return true
        end

        if command == "fov" then
            if arg == "0" then
                run_fov_command(false, "Console: clo fov 0")
                Ar:Log("FOVEnabled=false")
                return true
            end

            if arg == "1" then
                run_fov_command(true, "Console: clo fov 1")
                Ar:Log("FOVEnabled=true | LockOnFOV=" .. tostring(config.LockOnFOV))
                return true
            end

            if arg == "value" then
                local value = tonumber(value_arg)
                if value ~= nil and value >= 1 and value <= 179 then
                    config.LockOnFOV = value
                    ExecuteInGameThread(function()
                        if mod_enabled and config.FOVEnabled and CloUtil.in_combat_context() then
                            CloUtil.start_combat_fov_tween("in", "ConsoleFovValue")
                        end
                        append_log("CONSOLE | LockOnFOV=" .. tostring(config.LockOnFOV))
                    end)
                    Ar:Log("LockOnFOV=" .. tostring(config.LockOnFOV))
                    return true
                end
                Ar:Log("Usage: clo fov value <1-179>")
                return true
            end

            Ar:Log("Usage: clo fov 0 | clo fov 1 | clo fov value <1-179>")
            return true
        end

        if command == "offset" then
            local value_arg = Parameters[3]

            if arg == "value" then
                local value = tonumber(value_arg)
                if value ~= nil then
                    config.EnemyOffset = value
                    ExecuteInGameThread(function()
                        local changed = 0
                        if mod_enabled and lock_active then
                            changed = apply_combat_offset_fix(value, "ConsoleEnemyOffset")
                        end
                        append_log(
                            "CONSOLE | EnemyOffset=" .. tostring(config.EnemyOffset) ..
                            " | Changed=" .. tostring(changed) ..
                            " | LockActive=" .. tostring(lock_active)
                        )
                    end)
                    if lock_active then
                        Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
                    else
                        Ar:Log(
                            "EnemyOffset=" .. tostring(config.EnemyOffset) ..
                            " (saved; lock on to apply)"
                        )
                    end
                    return true
                end
                Ar:Log("Usage: clo offset value <number>")
                return true
            end

            local direct_value = tonumber(arg)
            if direct_value ~= nil then
                config.EnemyOffset = direct_value
                ExecuteInGameThread(function()
                    local changed = 0
                    if mod_enabled and lock_active then
                        changed = apply_combat_offset_fix(direct_value, "ConsoleEnemyOffset")
                    end
                    append_log(
                        "CONSOLE | EnemyOffset=" .. tostring(config.EnemyOffset) ..
                        " | Changed=" .. tostring(changed) ..
                        " | LockActive=" .. tostring(lock_active)
                    )
                end)
                Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
                return true
            end

            Ar:Log("Usage: clo offset value <number>")
            return true
        end

        if command == "z" then
            local value = tonumber(arg)
            if value == nil then
                Ar:Log("Usage: clo z <value>")
                return true
            end

            config.LockOnOffsetZ = value

            local function apply_z_command()
                if mod_enabled and lock_active then
                    if CloUtil.combat_offset_z_wanted() then
                        CloUtil.apply_combat_offset_z("ConsoleLockOnOffsetZ")
                    else
                        CloUtil.restore_combat_offset_z("ConsoleLockOnOffsetZZero")
                    end
                end
                append_log(
                    "LOCK OFFSET Z COMMAND" ..
                    " | Value=" .. tostring(value) ..
                    " | LockActive=" .. tostring(lock_active) ..
                    " | ModEnabled=" .. tostring(mod_enabled)
                )
            end

            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(apply_z_command)
            else
                apply_z_command()
            end

            Ar:Log("LockOnOffsetZ=" .. tostring(value))
            return true
        end

        if command == "ui" then
            Ar:Log("Settings UI disabled (UMG crash). Use clo fovstatus or edit INI.")
            Ar:Log("ModEnabled=" .. tostring(mod_enabled))
            Ar:Log("FOVEnabled=" .. tostring(config.FOVEnabled))
            Ar:Log("LockOnFOV=" .. tostring(config.LockOnFOV))
            Ar:Log("LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ))
            Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
            Ar:Log("LockActive=" .. tostring(lock_active))
            return true
        end

        if command == "fovstatus" then
            Ar:Log("ModEnabled=" .. tostring(mod_enabled))
            Ar:Log("FOVEnabled=" .. tostring(config.FOVEnabled))
            Ar:Log("LockOnFOV=" .. tostring(config.LockOnFOV))
            Ar:Log("LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ))
            Ar:Log("EnemyOffset=" .. tostring(config.EnemyOffset))
            Ar:Log("EnableLog=" .. tostring(config.EnableLog))
            Ar:Log("FOVApplied=" .. tostring(fov_applied))
            Ar:Log("LockActive=" .. tostring(lock_active))
            Ar:Log("InCombat=" .. tostring(CloUtil.in_combat_context()))
            Ar:Log("CombatOffsetZActive=" .. tostring(combat_offset_z.active))
            return true
        end

        return false
    end
)

append_log(
    "Loaded " ..
    MOD_NAME ..
    " | FOVEnabled=" .. tostring(config.FOVEnabled) ..
    " | LockOnFOV=" .. tostring(config.LockOnFOV) ..
    " | LockOnOffsetZ=" .. tostring(config.LockOnOffsetZ) ..
    " | EnemyOffset=" .. tostring(config.EnemyOffset) ..
    " | EnableLog=" .. tostring(config.EnableLog)
)

