-- True Mercy - makes Burn and Poison respect the Mercy ring and the Mercy Hit passive.
--
-- Burn never enters the path Mercy lives in. It calls SlipDamage (Pal.hpp:20184), whose
-- signature carries no attacker and no bCannotKill. So this records who applied it when the
-- hit lands, and clamps the tick to leave 1 HP.
--
-- Authority only. HP is server-owned, so a client can change a damage popup and nothing else.

local EFFECT_NON_KILLING = 70 -- EPalPassiveSkillEffectType::NonKilling, Pal_enums.hpp:4112

-- EPalDeadType, Pal_enums.hpp:1460. The only two a pal can inflict; the rest are environmental.
local DEAD_TYPE_POISON, DEAD_TYPE_BURN = 5, 6

local DEAD_TYPE_NAMES = {
    [0] = "Undefined", [1] = "Attack", [2] = "SelfDestruction", [3] = "BodyTemperature",
    [4] = "Falling", [5] = "Poison", [6] = "Burn", [7] = "Drown", [8] = "TowerBossBattle",
    [9] = "Ground", [10] = "Sucide",
}

local TRACKED_VICTIM_LIMIT = 256

-- BP_Status_Burn_C's Duration default is 15s, and re-applying it needs a hit, which also
-- refreshes the record, so anything still burning from a Mercy source is inside this.
-- Without it a pal hit once with the ring on sits at 1 HP in a campfire forever - measured.
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

    -- A metatable makes these reads arbitrary code, and a throw here would stop the mod
    -- loading, so the walk is contained.
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

-- Per-decision lines only. Failures stay on Log(): a mod that has silently stopped working
-- is what a disabled debug flag would hide.
local DebugLog = config.DebugLogging and Log or function() end

local protectedDeadTypes = {}
if config.ProtectFromBurn then protectedDeadTypes[DEAD_TYPE_BURN] = "burn" end
if config.ProtectFromPoison then protectedDeadTypes[DEAD_TYPE_POISON] = "poison" end

-- The hook bodies throw per damage event, not once, so an unlimited log would be a write per
-- hit server-wide. The count is there because reporting once hides how long it has been going.
local HANDLER_ERROR_REPEAT = 500
local handlerFailures = {}

local function ReportHandlerError(tag, err)
    local count = (handlerFailures[tag] or 0) + 1
    handlerFailures[tag] = count
    if count == 1 or count % HANDLER_ERROR_REPEAT == 0 then
        Log("%s handler error (%d so far): %s", tag, count, tostring(err))
    end
end

-- Which DoT types actually occur is worth knowing rather than assuming: BP_Status_ToxicGas
-- also calls SlipDamage and EPalDeadType has no ToxicGas value. Once per type, debug only.
local seenUnprotectedDeadTypes = {}

local function NoteUnprotectedDoT(deadType)
    if seenUnprotectedDeadTypes[deadType] then return end
    seenUnprotectedDeadTypes[deadType] = true
    DebugLog("saw a %s tick (EPalDeadType %s), which is not being protected",
        DEAD_TYPE_NAMES[deadType] or "unrecognized", tostring(deadType))
end

-- Reading an unresolvable name off a struct returns a real nil (LuaUScriptStruct.cpp:216),
-- while the same read off a UObject returns an invalid object (LuaUObject.cpp:2172). This
-- flattens both to an invalid object so callers only ever test IsValid.
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

-- Identity for table keys. GetFullName walks the outer chain and builds an FString;
-- GetAddress is a pointer read. Both hooks run per damage event server-wide.
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

-- Palworld ships bUseUObjectArrayCache=false, so a lookup walks the entire GUObjectArray.
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
    -- containEquip=true is required. The ring is equipment and the bare query misses it.
    return passiveComponent:HasSkill(EFFECT_NON_KILLING, true)
end

-- Only resolves while the pal is ridden, which is the point: an unmounted otomo does not
-- inherit its owner's ring in vanilla. GetTrainerPlayer was tried first and reverted, since it
-- resolves for any player-owned pal and so protects otomo the game leaves unprotected.
local function ResolveRider(attacker)
    local markerClass = ResolveObject(RIDE_MARKER_CLASS)
    if not markerClass:IsValid() or not attacker:IsValid() then return CreateInvalidObject() end

    local rideMarker = attacker:GetComponentByClass(markerClass)
    if not rideMarker:IsValid() or not rideMarker:IsRiding() then return CreateInvalidObject() end

    return rideMarker:GetRiderCharacter()
end

-- The reason is returned alongside the verdict because a bare "no Mercy" reads the same whether
-- the attacker was correctly unridden or the rider walk failed on a mount, and those are
-- opposite conclusions.
local REASON_TEXT = {
    noAttacker   = "no attacker",
    ownMercy     = "own Mercy",
    noMercy      = "not ridden, no Mercy of its own",
    riderMercy   = "ridden by %s",
    riderNoMercy = "ridden by %s, who has no Mercy",
}

-- Riding transfers the question to the rider: a mount carrying Mercy Hit stops sparing anything
-- while ridden by someone without the ring, measured in vanilla with no mods loaded. So a rider,
-- when there is one, is the whole answer and the mount's own passive does not get a say.
--
-- Rider is returned rather than named: naming costs an outer-chain walk, and this runs per
-- damage event to serve a line printed at most once.
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

-- The class is resolved once because IsA(string) re-runs StaticFindObject on every call
-- (is_a_implementation, LuaUObject.cpp:2132), which walks the whole array here.
local function IsPlayerCharacter(victim)
    local playerClass = ResolveObject(PLAYER_CHARACTER_CLASS)
    return playerClass:IsValid() and victim:IsA(playerClass)
end

-- IsPal (Pal.hpp:34599) is per-character class data: true for pals, false for humans and for
-- players. UPalUtility::IsPalCharacter is not a substitute, it reads true for human NPCs too.
-- The `== true` is load-bearing, since an absent property returns an invalid object rather than
-- nil and would pass a bare truthiness test.
--
-- Players stay protected in both modes. Vanilla Mercy floors them as well: the Arena disables
-- NonKilling and nothing else (BP_PalArenaWorldSubsystem, DisablePassiveTypes), which only makes
-- sense if it applies everywhere else.
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

-- Keyed by object address. A record's natural lifetime is its victim's, so entries are dropped
-- once the actor is gone rather than on a clock or a generation counter: the pal you are
-- burning to capture is the one you have stopped hitting, and anything driven by churn would
-- evict it mid-burn. IsValid answers this directly, going false once the engine deletes the
-- object (FLuaObjectDeleteListener::NotifyUObjectDeleted, LuaUObject.cpp:74).
local mercyByVictim = {}
local victimCount, sweepThreshold = 0, TRACKED_VICTIM_LIMIT

local function SweepDeadVictims()
    for address, record in pairs(mercyByVictim) do
        if not record.victim:IsValid() then
            mercyByVictim[address] = nil
            victimCount = victimCount - 1
        end
    end
    -- Backs off when a sweep frees nothing, so a server holding more than the limit in live
    -- damaged actors does not walk the table on every damage event.
    sweepThreshold = math.max(TRACKED_VICTIM_LIMIT, victimCount * 2)
end

local function RememberVictim(victimAddress, record)
    if mercyByVictim[victimAddress] == nil then victimCount = victimCount + 1 end
    mercyByVictim[victimAddress] = record
    if victimCount > sweepThreshold then SweepDeadVictims() end
end

-- Not cached: one process can leave a dedicated server and start a singleplayer game, where it
-- becomes the authority, and a cached "no" would stay wrong all session. HasAuthority is on
-- Actor, not ActorComponent, so this takes the actor the caller already has.
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
-- Gating here disables the mod on a client: no records means the clamp below finds nothing.
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

            RememberVictim(victimAddress, {
                protected = protected,
                reasonKind = reasonKind,
                -- Held as objects, not names: naming costs an outer-chain walk per hit,
                -- and only the one log line per verdict reads them. The victim is what the
                -- sweep tests to decide the record has outlived its actor.
                victim = defender,
                attacker = attacker,
                rider = rider,
                time = Now(),
                -- Carried across overwrites while the verdict holds. An attacker pinning a
                -- pal at 1 HP keeps landing hits, and resetting this would reprint
                -- the line on every tick that follows one.
                reported = (previous ~= nil and previous.protected == protected)
                    and previous.reported or false,
                -- Carried too, or it recomputes after every hit and the cache buys nothing.
                -- Not an `and/or` chain: this is tri-state, and `or nil` would turn a cached
                -- false back into nil.
                protectable = previous and previous.protectable,
            })
        end)
        if not okHook then ReportHandlerError("record", hookError) end
    end)

-- Drown, BodyTemperature, Falling and Ground share this path and the same hole, but nothing a
-- player controls inflicts them, so covering them would only stop lava and cold.
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

            -- No recorded hit means environmental, which has nothing to inherit and stays
            -- lethal. Every burning pal server-wide reaches this, so it stays cheap.
            local record = mercyByVictim[AddressOf(victim)]
            if record == nil then return end
            if (Now() - record.time) > RECORD_STALE_SECONDS then return end

            -- Two UFunction calls, and a pal never becomes a player, so it is kept.
            if record.protectable == nil then
                record.protectable = IsProtectableVictim(victim)
            end
            if not record.protectable then return end

            -- Declines are logged too, or a correct decline and a broken mod look identical.
            if not record.protected then
                -- Guarded here, not in DebugLog: Lua builds the names before the call, and
                -- each one costs a GetFullName walk.
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

            -- One line per burn, not per tick.
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
    Log("loaded - %s will respect Mercy on the authority%s%s",
        table.concat(protectedNames, " and "),
        config.ProtectHumanNPCs and "" or ", human NPCs excluded",
        config.DebugLogging and " (debug logging on)" or "")
end
