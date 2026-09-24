--!strict
-- LootboxConfig.lua: every lootbox number that isn't part of a box's loot table (docs/lootboxes.md). Shared; the
-- server's copy decides. Loot tables, odds and pity live in LootboxData.
local LootboxConfig = {}

-- ---------------------------------------------------------------- money
-- Robux is prepared but OFF. Before turning it on, see docs/lootboxes.md §7.3: developer products per box,
-- idempotent ProcessReceipt (receipt ledger saved BEFORE PurchaseGranted), PolicyService checked on the server for
-- every purchase, the "Paid Random Items" answer in the experience questionnaire, and the current Roblox rules.
LootboxConfig.ROBUX_ENABLED = false
LootboxConfig.ROBUX_PRODUCTS = {} :: { [number]: string } -- developer product id -> box id (empty while disabled)
LootboxConfig.CREDIT_PACKS_ENABLED = false -- selling Créditos for Robux would make credit purchases "paid" too

LootboxConfig.DAILY_BUY_CAP = 10 -- boxes bought with credits per UTC day (brake on compulsive buying)

-- ---------------------------------------------------------------- PolicyService (ArePaidRandomItemsRestricted)
-- Restricted players never get a way to pay for boxes (not even with credits). What they can do with the boxes they
-- earn by playing:
--   "fragments": no randomness at all - each box converts to a fixed amount of that box's fragments and the item is
--                picked directly from the box's list (default: the safest option)
--   "free_only": earned boxes open at random like everyone else's; only buying is blocked
LootboxConfig.RESTRICTED_MODE = "fragments"
LootboxConfig.POLICY_RETRY = 60 -- s before asking PolicyService again after a failure (meanwhile: restricted)
-- Studio only (ignored in live servers): force the policy to test both flows - nil (ask PolicyService),
-- "restricted" or "unrestricted"
LootboxConfig.STUDIO_POLICY = nil :: string?

-- ---------------------------------------------------------------- duplicates and fragments (per rarity)
LootboxConfig.DUP_FRAGMENTS = { common = 5, rare = 15, epic = 40, legendary = 100, exotic = 200 }
LootboxConfig.DUP_CREDITS = { common = 30, rare = 80, epic = 200, legendary = 500, exotic = 1000 }
LootboxConfig.REDEEM_COST = { common = 50, rare = 150, epic = 400, legendary = 1000, exotic = 2000 }

-- ---------------------------------------------------------------- how boxes are earned
LootboxConfig.LEVEL_BOX_EVERY = 5 -- a standard box every 5 levels
LootboxConfig.LEVEL_SEASON_EVERY = 10 -- plus a season box every 10 (standard when no season is on)
LootboxConfig.RETRO_LEVEL_BOXES_MAX = 5 -- migration: standard boxes for levels already reached, at most this many
-- drop at the end of an online result that paid a reward (never local / training / abandoned)
LootboxConfig.DROP_CHANCE = { online_pvp = 0.12, ranked = 0.12, online_bots = 0.05, minigame = 0.05 }
LootboxConfig.DROP_SEASON_SHARE = 0.2 -- online match drops: 20 % season box (while a season is on)
LootboxConfig.DAILY_DROP_CAP = 2

-- ---------------------------------------------------------------- season
LootboxConfig.SEASON = {
	id = "season1", name = "TEMPORADA 1: NITRO",
	startsAt = 1789948800, -- 2026-09-21 00:00 UTC
	endsAt = 1798761600, -- 2027-01-01 00:00 UTC
}

-- ---------------------------------------------------------------- safety
LootboxConfig.HISTORY_SIZE = 50
LootboxConfig.REQUEST_MEMORY = 20 -- last request ids answered again without a new roll
LootboxConfig.OPEN_GAP = 1 -- s between two openings of the same player
LootboxConfig.BUY_GAP = 1

return LootboxConfig
