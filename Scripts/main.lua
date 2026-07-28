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

-- Past this, the recorded hit is no longer trustworthy attribution.
local ATTRIBUTION_STALE_SECONDS = 30
local TRACKED_VICTIM_LIMIT = 256

-- A lone string can contain a "%", a pal name for instance, that string.format would eat.
local function log(fmt, ...)
    print("[TrueMercy] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt) .. "\n")
end

local CONFIG_DEFAULTS = {
    ProtectFromBurn = true,
    ProtectFromPoison = true,
    DebugLogging = false,
}

local function loadConfig()
    local config = {}
    for key, default in pairs(CONFIG_DEFAULTS) do config[key] = default end

    local okConfig, loaded = pcall(require, "config")
    if not okConfig then
        log("no readable config.lua, using defaults - %s", tostring(loaded))
        return config
    end
    if type(loaded) ~= "table" then
        log("config.lua returned a %s rather than a table - using defaults", type(loaded))
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
                log("config.lua: %s is a %s, expected a %s - using %s",
                    key, type(value), type(default), tostring(default))
            end
        end
        -- A typo like `DebugLogging_ = true` would otherwise do nothing, silently.
        for key in pairs(loaded) do
            if CONFIG_DEFAULTS[key] == nil then
                log("config.lua: ignoring unrecognized key '%s'", tostring(key))
            end
        end
    end)
    if not okRead then
        log("config.lua could not be read (%s), using defaults", tostring(readError))
        for key, default in pairs(CONFIG_DEFAULTS) do config[key] = default end
    end
    return config
end

local config = loadConfig()

-- Per-decision lines only. Failures stay on log(): a mod that has silently stopped working
-- is what a disabled debug flag would hide.
local debugLog = config.DebugLogging and log or function() end

local protectedDeadTypes = {}
if config.ProtectFromBurn then protectedDeadTypes[DEAD_TYPE_BURN] = "burn" end
if config.ProtectFromPoison then protectedDeadTypes[DEAD_TYPE_POISON] = "poison" end

-- Which DoT types actually occur is worth knowing rather than assuming: BP_Status_ToxicGas
-- also calls SlipDamage and EPalDeadType has no ToxicGas value. Once per type, debug only.
local seenUnprotectedDeadTypes = {}

local function noteUnprotectedDoT(deadType)
    if seenUnprotectedDeadTypes[deadType] then return end
    seenUnprotectedDeadTypes[deadType] = true
    debugLog("saw a %s tick (EPalDeadType %s), which is not being protected",
        DEAD_TYPE_NAMES[deadType] or "unrecognized", tostring(deadType))
end

local function unwrap(param)
    if param == nil then return nil end
    if type(param) ~= "userdata" then return param end
    local okGet, value = pcall(function() return param:get() end)
    if okGet then return value end
    return param
end

local function nameOf(object)
    if object == nil then return "<nil>" end
    local okValid, isValid = pcall(function() return object:IsValid() end)
    if not okValid or not isValid then return "<invalid>" end
    local okName, fullName = pcall(function() return object:GetFullName() end)
    if not okName then return "<noname>" end
    return tostring(fullName)
end

local function shortName(object)
    local full = nameOf(object)
    return full:match("([^%.%/]+)$") or full
end

-- Identity for table keys. GetFullName walks the outer chain and builds an FString;
-- GetAddress is a pointer read. Both hooks run per damage event server-wide.
local function addressOf(object)
    if object == nil then return nil end
    local okAddress, address = pcall(function() return object:GetAddress() end)
    if not okAddress then return nil end
    return address
end

local wallClock = (type(os) == "table") and os.time or nil

local function now()
    if wallClock == nil then return 0 end
    local okClock, seconds = pcall(wallClock)
    if okClock then return seconds end
    return 0
end

-- Cached including failure: Palworld ships bUseUObjectArrayCache=false, so a miss walks the
-- entire GUObjectArray and UE4SS never caches a failed lookup.
local function makeObjectResolver(objectPath, label)
    local resolved, lookupDone = nil, false
    return function()
        if lookupDone then return resolved end
        lookupDone = true

        local okFind, found = pcall(StaticFindObject, objectPath)
        if okFind and found ~= nil then
            local okValid, isValid = pcall(function() return found:IsValid() end)
            if okValid and isValid then
                resolved = found
                return resolved
            end
        end

        log("WARNING could not resolve %s - Mercy protection disabled", label)
        return nil
    end
end

local getFixedPointLibrary = makeObjectResolver("/Script/Pal.Default__FixedPoint64MathLibrary",
    "FixedPoint64MathLibrary")
local getPalUtility = makeObjectResolver("/Script/Pal.Default__PalUtility", "PalUtility")
local getRideMarkerClass = makeObjectResolver("/Script/Pal.PalRideMarkerComponent",
    "PalRideMarkerComponent")

local function hasNonKilling(character)
    if character == nil then return false end

    local okComponent, passiveComponent = pcall(function() return character.PassiveSkillComponent end)
    if not okComponent or passiveComponent == nil then return false end

    local okValid, isValid = pcall(function() return passiveComponent:IsValid() end)
    if not okValid or not isValid then return false end

    -- containEquip=true is required. The ring is equipment and the bare query misses it.
    local okQuery, hasSkill = pcall(function()
        return passiveComponent:HasSkill(EFFECT_NON_KILLING, true)
    end)
    return okQuery and hasSkill or false
end

-- Only resolves while the pal is ridden, which is the point: an unmounted otomo does not
-- inherit its owner's ring in vanilla. GetTrainerPlayer was tried first and reverted, since it
-- resolves for any player-owned pal and so protects otomo the game leaves unprotected.
local function resolveRider(attacker)
    local markerClass = getRideMarkerClass()
    if markerClass == nil then return nil end

    local okComponent, rideMarker = pcall(function()
        return attacker:GetComponentByClass(markerClass)
    end)
    if not okComponent or rideMarker == nil then return nil end

    local okValid, isValid = pcall(function() return rideMarker:IsValid() end)
    if not okValid or not isValid then return nil end

    local okRiding, isRiding = pcall(function() return rideMarker:IsRiding() end)
    if not okRiding or not isRiding then return nil end

    local okRider, rider = pcall(function() return rideMarker:GetRiderCharacter() end)
    if not okRider then return nil end
    return rider
end

-- Mercy Hit on the attacker, or a player attacking directly, then the ring worn by its rider.
-- Returns the reason too: "no Mercy" reads the same whether the attacker was correctly
-- unridden or the rider walk failed on a mount, and those are opposite conclusions.
local REASON_TEXT = {
    noAttacker   = "no attacker",
    ownMercy     = "own Mercy",
    notRidden    = "not ridden",
    riderMercy   = "ridden by %s",
    riderNoMercy = "ridden by %s, who has no Mercy",
}

-- Rider is returned rather than named: naming costs an outer-chain walk, and this runs per
-- damage event to serve a line printed at most once.
local function evaluateMercy(attacker)
    if attacker == nil then return false, "noAttacker" end
    if hasNonKilling(attacker) then return true, "ownMercy" end

    local rider = resolveRider(attacker)
    if rider == nil then return false, "notRidden" end
    if hasNonKilling(rider) then return true, "riderMercy", rider end
    return false, "riderNoMercy", rider
end

local function describeReason(record)
    local text = REASON_TEXT[record.reasonKind] or tostring(record.reasonKind)
    if record.rider == nil then return text end
    return string.format(text, shortName(record.rider))
end

-- APalPlayerCharacter derives from APalCharacter (Pal.hpp:12586), so the pal test alone also
-- catches players. A burning player is ordinary gameplay.
local function isProtectableVictim(victim)
    if victim == nil then return false end

    local utility = getPalUtility()
    if utility == nil then return false end

    local okPal, isPal = pcall(function() return utility:IsPalCharacter(victim) end)
    if not okPal or not isPal then return false end

    local okPlayer, isPlayerControlled = pcall(function() return utility:IsPlayerControlActor(victim) end)
    if okPlayer and isPlayerControlled then return false end

    return true
end

local function currentDisplayHP(victim)
    local okParam, paramComponent = pcall(function() return victim.CharacterParameterComponent end)
    if not okParam or paramComponent == nil then return nil end

    local okValid, isValid = pcall(function() return paramComponent:IsValid() end)
    if not okValid or not isValid then return nil end

    local okHP, hp = pcall(function() return paramComponent:GetHP() end)
    if not okHP or hp == nil then return nil end

    local library = getFixedPointLibrary()
    if library == nil then return nil end

    local okConvert, displayHP = pcall(function()
        return library:Convert_FixedPoint64ToInt(hp)
    end)
    if not okConvert then return nil end
    return tonumber(displayHP)
end

-- Keyed by object address. A pooled actor reusing one inside the window inherits a stale
-- verdict, costing one wild pal a burn it should have died to.
local mercyByVictim = {}
local trackedVictimCount = 0

local function pruneTracked()
    if trackedVictimCount <= TRACKED_VICTIM_LIMIT then return end
    local cutoff = now() - ATTRIBUTION_STALE_SECONDS
    for victimAddress, record in pairs(mercyByVictim) do
        if record.time < cutoff then
            mercyByVictim[victimAddress] = nil
            trackedVictimCount = trackedVictimCount - 1
        end
    end
end

-- Not cached: one process can leave a dedicated server and start a singleplayer game, where it
-- becomes the authority, and a cached "no" would stay wrong all session. HasAuthority is on
-- Actor, not ActorComponent, so this takes the actor the caller already has.
local warnedNotAuthority = false

local function onAuthority(actor)
    local okAuthority, hasAuthority = pcall(function() return actor:HasAuthority() end)
    -- Unreadable counts as yes: wasted work beats disabling silently.
    if not okAuthority then return true end

    if hasAuthority then
        warnedNotAuthority = false
        return true
    end

    if not warnedNotAuthority then
        warnedNotAuthority = true
        log("not the authority - install this on the host or dedicated server. "
            .. "Nothing will be protected here.")
    end
    return false
end

-- Every hit overwrites, so a later attacker without Mercy makes the target killable again.
-- Gating here disables the mod on a client: no records means the clamp below finds nothing.
RegisterHook("/Script/Pal.PalDamageReactionComponent:CallOnDamageDelegateAlways",
    function(Context, DamageResult)
        local okHook, hookError = pcall(function()
            local damageResult = unwrap(DamageResult)
            if damageResult == nil then return end

            local okDefender, defender = pcall(function() return damageResult.Defender end)
            if not okDefender or defender == nil then return end

            if not onAuthority(defender) then return end

            local victimAddress = addressOf(defender)
            if victimAddress == nil then return end

            local okAttacker, attacker = pcall(function() return damageResult.Attacker end)
            local protected, reasonKind, rider = false, "attacker unreadable", nil
            if okAttacker then protected, reasonKind, rider = evaluateMercy(attacker) end

            local previous = mercyByVictim[victimAddress]
            if previous == nil then
                trackedVictimCount = trackedVictimCount + 1
            end

            mercyByVictim[victimAddress] = {
                protected = protected,
                reasonKind = reasonKind,
                -- Held as objects, not names: naming costs an outer-chain walk per hit,
                -- and only the one log line per verdict reads them.
                attacker = okAttacker and attacker or nil,
                rider = rider,
                time = now(),
                -- Carried across overwrites while the verdict holds. An attacker pinning a
                -- pal at 1 HP keeps landing hits, and resetting this would reprint
                -- the line on every tick that follows one.
                reported = (previous ~= nil and previous.protected == protected)
                    and previous.reported or false,
            }

            pruneTracked()
        end)
        if not okHook then log("record hook error: %s", tostring(hookError)) end
    end)

-- Drown, BodyTemperature, Falling and Ground share this path and the same hole, but nothing a
-- player controls inflicts them, so covering them would only stop lava and cold.
RegisterHook("/Script/Pal.PalDamageReactionComponent:SlipDamage",
    function(Context, Damage, ShieldIgnore, DeadType, ClearShield)
        local okHook, hookError = pcall(function()
            local deadType = unwrap(DeadType)
            local dotKind = protectedDeadTypes[deadType]
            if dotKind == nil then
                if config.DebugLogging then noteUnprotectedDoT(deadType) end
                return
            end

            local component = unwrap(Context)
            if component == nil then return end

            local okOwner, victim = pcall(function() return component:GetOwner() end)
            if not okOwner or victim == nil then return end

            -- No recorded hit means environmental, which has nothing to inherit and stays
            -- lethal. Every burning pal server-wide reaches this, so it stays cheap.
            local record = mercyByVictim[addressOf(victim)]
            if record == nil then return end
            if (now() - record.time) > ATTRIBUTION_STALE_SECONDS then return end

            -- Two UFunction calls, and a pal never becomes a player, so it is kept.
            if record.protectable == nil then
                record.protectable = isProtectableVictim(victim)
            end
            if not record.protectable then return end

            -- Declines are logged too, or a correct decline and a broken mod look identical.
            if not record.protected then
                if not record.reported then
                    record.reported = true
                    debugLog("not protecting %s from %s - %s: %s", shortName(victim), dotKind,
                        shortName(record.attacker), describeReason(record))
                end
                return
            end

            local displayHP = currentDisplayHP(victim)
            if displayHP == nil or displayHP <= 0 then return end

            local requested = tonumber(unwrap(Damage))
            if requested == nil then return end

            local allowed = displayHP - 1
            if allowed < 0 then allowed = 0 end
            if requested <= allowed then return end

            Damage:set(allowed)

            -- One line per burn, not per tick.
            if not record.reported then
                record.reported = true
                debugLog("held %s at 1 HP - %s from %s (%s), tick %d -> %d (hp was %d)",
                    shortName(victim), dotKind, shortName(record.attacker),
                    describeReason(record), requested, allowed, displayHP)
            end
        end)
        if not okHook then log("clamp hook error: %s", tostring(hookError)) end
    end)

local protectedNames = {}
for _, name in pairs(protectedDeadTypes) do protectedNames[#protectedNames + 1] = name end
table.sort(protectedNames)

if #protectedNames == 0 then
    log("loaded, but every ProtectFrom option is off - nothing will be protected")
else
    log("loaded - %s will respect Mercy on the authority%s", table.concat(protectedNames, " and "),
        config.DebugLogging and " (debug logging on)" or "")
end
