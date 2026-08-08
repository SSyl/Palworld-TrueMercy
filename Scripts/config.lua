return {
    -- Stops burn taking a pal's last HP while Mercy applies.
    ProtectFromBurn = true,

    -- Same for poison.
    ProtectFromPoison = true,

    -- Set to false to leave human NPCs out of this mod's Mercy fix, which is what you want
    -- if you're running a mod like No Mercy For Humans.
    ProtectHumanNPCs = true,

    -- Logs each pal the mod protects or skips, and why. Noisy in normal play.
    -- Turning it off never hides an error: those are logged either way.
    DebugLogging = false,
}
