-- True Mercy - makes Burn and Poison respect the Mercy ring and the Mercy Hit passive.
--
-- Records who applied the DoT when the hit lands, and clamps the tick to leave 1 HP.
--
-- Authority only. HP is server-owned, so a client can change a damage popup and nothing else.

local MOD_VERSION = "1.2.1"
local EFFECT_NON_KILLING = 70 -- EPalPassiveSkillEffectType::NonKilling, Pal_enums.hpp:4112

-- EPalDeadType, Pal_enums.hpp:1460. The only two a pal can inflict. The rest are environmental.
local DEAD_TYPE_POISON, DEAD_TYPE_BURN = 5, 6

local DEAD_TYPE_NAMES = {
    [0] = "Undefined", [1] = "Attack", [2] = "SelfDestruction", [3] = "BodyTemperature",
    [4] = "Falling", [5] = "Poison", [6] = "Burn", [7] = "Drown", [8] = "TowerBossBattle",
    [9] = "Ground", [10] = "Sucide",
}

local TRACKED_VICTIM_LIMIT = 256

-- BP_Status_Burn_C's Duration default is 15s. Set to 20 because os.time is imprecise.
local RECORD_STALE_SECONDS = 20

-- A lone string can contain a "%", a pal name for instance, that string.format would eat.
local function Log(fmt, ...)
    print("[TrueMercy] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt) .. "\n")
end

local CONFIG_DEFAULTS = {
    ProtectFromBurn = true,
    ProtectFromPoison = true,
    ProtectHumanNPCs = true,
    DebugLogging = false,
}

local function LoadConfig()
    local config = {}
    for key, default in pairs(CONFIG_DEFAULTS) do config[key] = default end

    local okConfig, loaded = pcall(require, "config")
    if not okConfig then
        Log("no readable config.lua, using defaults - %s", tostring(loaded))
        return config
    end
    if type(loaded) ~= "table" then
        Log("config.lua returned a %s rather than a table - using defaults", type(loaded))
        return config
    end

    -- Walk is contained so a bad config does not stop the mod from loading.
    local okRead, readError = pcall(function()
        for key, default in pairs(CONFIG_DEFAULTS) do
            local value = loaded[key]
            if type(value) == type(default) then
                config[key] = value
            elseif value ~= nil then
                Log("config.lua: %s is a %s, expected a %s - using %s",
                    key, type(value), type(default), tostring(default))
            end
        end
        -- A typo like `DebugLogging_ = true` would otherwise do nothing, silently.
        for key in pairs(loaded) do
            if CONFIG_DEFAULTS[key] == nil then
                Log("config.lua: ignoring unrecognized key '%s'", tostring(key))
            end
        end
    end)
    if not okRead then
        Log("config.lua could not be read (%s), using defaults", tostring(readError))
        for key, default in pairs(CONFIG_DEFAULTS) do config[key] = default end
    end
    return config
end

local config = LoadConfig()

-- Failures use Log() so a silently broken mod still reports.
local DebugLog = config.DebugLogging and Log or function() end

local protectedDeadTypes = {}
if config.ProtectFromBurn then protectedDeadTypes[DEAD_TYPE_BURN] = "burn" end
if config.ProtectFromPoison then protectedDeadTypes[DEAD_TYPE_POISON] = "poison" end

-- Logs every hit server-wide, so errors only report on the first and every 500th.
local HANDLER_ERROR_REPEAT = 500
local handlerFailures = {}

local function ReportHandlerError(tag, err)
    local count = (handlerFailures[tag] or 0) + 1
    handlerFailures[tag] = count
    if count == 1 or count % HANDLER_ERROR_REPEAT == 0 then
        Log("%s handler error (%d so far): %s", tag, count, tostring(err))
    end
end

-- Logs any DoTs we have not seen. Debug only.
local seenUnprotectedDeadTypes = {}

local function NoteUnprotectedDoT(deadType)
    if seenUnprotectedDeadTypes[deadType] then return end
    seenUnprotectedDeadTypes[deadType] = true
    DebugLog("saw a %s tick (EPalDeadType %s), which is not being protected",
        DEAD_TYPE_NAMES[deadType] or "unrecognized", tostring(deadType))
end

-- Structs can return a lua nil. This makes both an invalid object for IsValid().
local function ReadObject(owner, propertyName)
    if owner == nil or not owner:IsValid() then return CreateInvalidObject() end
    local value = owner[propertyName]
    if value == nil then return CreateInvalidObject() end
    return value
end

local function FullName(object)
    if not object:IsValid() then return "<invalid>" end
    return tostring(object:GetFullName())
end

local function ShortName(object)
    local full = FullName(object)
    return full:match("([^%.%/]+)$") or full
end

local function AddressOf(object)
    if not object:IsValid() then return nil end
    return object:GetAddress()
end

local wallClock = (type(os) == "table") and os.time or nil

local function Now()
    if wallClock == nil then return 0 end
    return wallClock()
end

local FIXED_POINT_LIBRARY = "/Script/Pal.Default__FixedPoint64MathLibrary"
local RIDE_MARKER_CLASS = "/Script/Pal.PalRideMarkerComponent"
local PLAYER_CHARACTER_CLASS = "/Script/Pal.PalPlayerCharacter"

local resolvedObjects, warnedPaths = {}, {}

-- Palworld ships bUseUObjectArrayCache=false. A lookup costs a walk of the entire GUObjectArray.
local function ResolveObject(objectPath)
    local resolved = resolvedObjects[objectPath]
    if resolved ~= nil and resolved:IsValid() then return resolved end

    resolved = StaticFindObject(objectPath)
    resolvedObjects[objectPath] = resolved

    if not resolved:IsValid() and not warnedPaths[objectPath] then
        warnedPaths[objectPath] = true
        Log("WARNING could not resolve %s", objectPath)
    end
    return resolved
end

local function HasNonKilling(character)
    local passiveComponent = ReadObject(character, "PassiveSkillComponent")
    if not passiveComponent:IsValid() then return false end
    -- The true passed to HasSkill is containEquip, which is what checks for the ring.
    return passiveComponent:HasSkill(EFFECT_NON_KILLING, true)
end

-- Only resolves while the pal is ridden. GetTrainerPlayer was tried first and reverted
-- because it resolves for any player-owned pal.
local function ResolveRider(attacker)
    local markerClass = ResolveObject(RIDE_MARKER_CLASS)
    if not markerClass:IsValid() or not attacker:IsValid() then return CreateInvalidObject() end

    local rideMarker = attacker:GetComponentByClass(markerClass)
    if not rideMarker:IsValid() or not rideMarker:IsRiding() then return CreateInvalidObject() end

    return rideMarker:GetRiderCharacter()
end

-- The reason is returned to show whether the rider, pal, or no one had mercy.
local REASON_TEXT = {
    noAttacker   = "no attacker",
    ownMercy     = "own Mercy",
    noMercy      = "not ridden, no Mercy of its own",
    riderMercy   = "ridden by %s",
    riderNoMercy = "ridden by %s, who has no Mercy",
}

local function EvaluateMercy(attacker)
    if not attacker:IsValid() then return false, "noAttacker" end

    local rider = ResolveRider(attacker)
    if rider:IsValid() then
        if HasNonKilling(rider) then return true, "riderMercy", rider end
        return false, "riderNoMercy", rider
    end

    if HasNonKilling(attacker) then return true, "ownMercy" end
    return false, "noMercy"
end

local function DescribeReason(record)
    local text = REASON_TEXT[record.reasonKind] or tostring(record.reasonKind)
    if record.rider == nil or not record.rider:IsValid() then return text end
    return string.format(text, ShortName(record.rider))
end

-- Caching here because IsA(string) reruns StaticFindObject which walks the whole UObjectArray.
local function IsPlayerCharacter(victim)
    local playerClass = ResolveObject(PLAYER_CHARACTER_CLASS)
    return playerClass:IsValid() and victim:IsA(playerClass)
end

local function IsProtectableVictim(victim)
    local staticComponent = ReadObject(victim, "StaticCharacterParameterComponent")
    if not staticComponent:IsValid() then return false end

    if staticComponent.IsPal == true then return true end
    if IsPlayerCharacter(victim) then return true end
    return config.ProtectHumanNPCs
end

local function CurrentDisplayHP(victim)
    local paramComponent = ReadObject(victim, "CharacterParameterComponent")
    if not paramComponent:IsValid() then return nil end

    local library = ResolveObject(FIXED_POINT_LIBRARY)
    if not library:IsValid() then return nil end

    return tonumber(library:Convert_FixedPoint64ToInt(paramComponent:GetHP()))
end

-- Keyed by object address. Entries are dropped once the actor is gone rather than on a clock.
local mercyByVictim = {}
local victimCount, sweepThreshold = 0, TRACKED_VICTIM_LIMIT

local function SweepDeadVictims()
    for address, record in pairs(mercyByVictim) do
        if not record.victim:IsValid() then
            mercyByVictim[address] = nil
            victimCount = victimCount - 1
        end
    end
    -- Backs off when a sweep frees nothing to avoid walking the table every damage event.
    sweepThreshold = math.max(TRACKED_VICTIM_LIMIT, victimCount * 2)
end

local function RememberVictim(victimAddress, record)
    if mercyByVictim[victimAddress] == nil then victimCount = victimCount + 1 end
    mercyByVictim[victimAddress] = record
    if victimCount > sweepThreshold then SweepDeadVictims() end
end

-- Never cache Authority as a player may leave a server and start an SP game or vice versa.
local warnedNotAuthority = false

local function OnAuthority(actor)
    if actor:HasAuthority() then
        warnedNotAuthority = false
        return true
    end

    if not warnedNotAuthority then
        warnedNotAuthority = true
        Log("not the authority - install this on the host or dedicated server. "
            .. "Nothing will be protected here.")
    end
    return false
end

-- Every hit overwrites, so a later attacker without Mercy makes the target killable again.
--
-- Gating here disables the mod on a client.
RegisterHook("/Script/Pal.PalDamageReactionComponent:CallOnDamageDelegateAlways",
    function(Context, DamageResult)
        local okHook, hookError = pcall(function()
            local damageResult = DamageResult:get()

            local defender = ReadObject(damageResult, "Defender")
            if not defender:IsValid() or not OnAuthority(defender) then return end

            local victimAddress = AddressOf(defender)
            if victimAddress == nil then return end

            local attacker = ReadObject(damageResult, "Attacker")
            local protected, reasonKind, rider = EvaluateMercy(attacker)

            local previous = mercyByVictim[victimAddress]

            -- Dazzi's party attacks carry bCannotKill and were overwriting mercy, letting
            -- burn kill next tick.
            --
            -- Ordered so the Lua checks gate the struct read rather than every server-wide
            -- damage event.
            if not protected and previous ~= nil and previous.protected
                and damageResult.bCannotKill == true then
                return
            end

            RememberVictim(victimAddress, {
                protected = protected,
                reasonKind = reasonKind,
                -- Held as objects instead of names to avoid an outer-chain walk.
                victim = defender,
                attacker = attacker,
                rider = rider,
                time = Now(),
                -- Carried across overwrites while the verdict holds. Resetting this would
                -- reprint every tick.
                reported = (previous ~= nil and previous.protected == protected)
                    and previous.reported or false,
                protectable = previous and previous.protectable,
            })
        end)
        if not okHook then ReportHandlerError("record", hookError) end
    end)

-- Mercy doesn't check SlipDamage (Pal.hpp:20184) which is where burn lives.
--
-- Drown, BodyTemperature, Falling and Ground also share this path.
RegisterHook("/Script/Pal.PalDamageReactionComponent:SlipDamage",
    function(Context, Damage, ShieldIgnore, DeadType, ClearShield)
        local okHook, hookError = pcall(function()
            local deadType = DeadType:get()
            local dotKind = protectedDeadTypes[deadType]
            if dotKind == nil then
                if config.DebugLogging then NoteUnprotectedDoT(deadType) end
                return
            end

            local component = Context:get()
            if not component:IsValid() then return end

            local victim = component:GetOwner()
            if not victim:IsValid() then return end

            -- No recorded hit means environmental.
            local record = mercyByVictim[AddressOf(victim)]
            if record == nil then return end
            if (Now() - record.time) > RECORD_STALE_SECONDS then return end

            if record.protectable == nil then
                record.protectable = IsProtectableVictim(victim)
            end
            if not record.protectable then return end

            if not record.protected then
                -- Guarded before DebugLog because Lua builds the names first and each one
                -- costs a GetFullName walk.
                if config.DebugLogging and not record.reported then
                    record.reported = true
                    DebugLog("not protecting %s from %s - %s: %s", ShortName(victim), dotKind,
                        ShortName(record.attacker), DescribeReason(record))
                end
                return
            end

            local displayHP = CurrentDisplayHP(victim)
            if displayHP == nil or displayHP <= 0 then return end

            local requested = tonumber(Damage:get())
            local allowed = math.max(displayHP - 1, 0)
            if requested <= allowed then return end

            Damage:set(allowed)

            if config.DebugLogging and not record.reported then
                record.reported = true
                DebugLog("held %s at 1 HP - %s from %s (%s), tick %d -> %d (hp was %d)",
                    ShortName(victim), dotKind, ShortName(record.attacker),
                    DescribeReason(record), requested, allowed, displayHP)
            end
        end)
        if not okHook then ReportHandlerError("clamp", hookError) end
    end)

local protectedNames = {}
for _, name in pairs(protectedDeadTypes) do protectedNames[#protectedNames + 1] = name end
table.sort(protectedNames)

if #protectedNames == 0 then
    Log("loaded, but every ProtectFrom option is off - nothing will be protected")
else
    Log("v%s loaded - %s will respect Mercy on the authority%s%s",
        MOD_VERSION,
        table.concat(protectedNames, " and "),
        config.ProtectHumanNPCs and "" or ", human NPCs excluded",
        config.DebugLogging and " (debug logging on)" or "")
end
