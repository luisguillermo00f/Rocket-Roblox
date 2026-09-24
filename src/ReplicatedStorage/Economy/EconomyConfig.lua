--!strict
-- EconomyConfig.lua: every number of the XP / Créditos economy in one place (see docs/progression.md).
-- Shared so the client can show estimates and caps, but only the server's copy decides anything.
local EconomyConfig = {}

-- reward multipliers per source; the SERVER classifies every result (the client can't pick its source)
EconomyConfig.SOURCES = {
	ranked = { xp = 1.15, credits = 1.2 }, -- online, ranked queue, at least one human opponent
	online_pvp = { xp = 1.0, credits = 1.0 }, -- online, at least one human opponent
	online_bots = { xp = 0.85, credits = 0.5 }, -- online, every opponent is a bot
	["local"] = { xp = 0.7, credits = 0.3 }, -- offline vs bots: simulated by the client, can't be verified
	minigame = { xp = 1.0, credits = 1.0 }, -- party round with 2+ humans
	minigame_bots = { xp = 0.6, credits = 0.4 }, -- party round with a single human (the rest are the host's bots)
	training = { xp = 0, credits = 0 },
}

-- XP per match = (base + result + min(points, pointsCap)) * source.xp
EconomyConfig.MATCH_XP = { base = 30, win = 100, draw = 50, loss = 0, pointsCap = 1500 }
-- credits per match = (base + result + min(floor(points / perPoints), pointsBonusCap)) * source.credits
EconomyConfig.MATCH_CREDITS = { base = 10, win = 20, draw = 12, loss = 6, perPoints = 100, pointsBonusCap = 10 }
-- minigame round (<= 80 s): XP = (base + byPlacement) * source.xp ; credits = byPlacement * source.credits
EconomyConfig.MINIGAME_XP = { base = 20, byPlacement = { 80, 50, 30, 20 } }
EconomyConfig.MINIGAME_CREDITS = { 12, 8, 5, 3 }

-- first win of the UTC day (outside the daily cap), only where the opponents are people
EconomyConfig.FIRST_WIN = { credits = 50, xp = 200, sources = { online_pvp = true, ranked = true, minigame = true } }

-- anti-farming (reset at 00:00 UTC)
EconomyConfig.DAILY_CREDIT_CAP = 400 -- credits from matches + minigames per day
EconomyConfig.LOCAL_DAILY_CREDITS = 90 -- of which at most this much from the unverifiable local source
EconomyConfig.LOCAL_DAILY_XP = 3000
EconomyConfig.LOCAL_MIN_INTERVAL = 240 -- s (server clock) between two rewarded local matches (a match is 300 s)
EconomyConfig.MIN_ONLINE_SECONDS = 60 -- an online match shorter than this gives no reward
EconomyConfig.MIN_MINIGAME_SECONDS = 15 -- same for a minigame round (time in ACTIVE)

-- level up (reaching level L): 100 + 20 * floor(L / 5)
EconomyConfig.LEVEL_CREDITS = { base = 100, per5 = 20 }

-- challenge rewards by difficulty (1..3); not counted in the daily cap (fixed amounts)
EconomyConfig.CHALLENGE_REWARDS = {
	daily = { { credits = 60, xp = 150 }, { credits = 80, xp = 150 }, { credits = 100, xp = 150 } },
	weekly = { { credits = 300, xp = 600 }, { credits = 400, xp = 600 }, { credits = 500, xp = 600 } },
}
EconomyConfig.DAILY_COUNT = 3
EconomyConfig.WEEKLY_COUNT = 3

-- one-time bonus when an existing (v1) profile is migrated: credits for the levels it had already reached
EconomyConfig.WELCOME_BONUS = { perLevel = 100, max = 3000 }

return EconomyConfig
