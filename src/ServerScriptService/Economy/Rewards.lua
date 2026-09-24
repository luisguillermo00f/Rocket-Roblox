--!strict
-- Rewards.lua (server, pure): turns a finished match / minigame round into career stats, XP, Créditos and challenge
-- progress (docs/progression.md §1-§3). Only ProfileService calls it; the client never sends XP or credits.
--   ApplyMatch(profile, raw, trusted, now)  raw = what SubmitMatch (client, trusted = false) or ServerSubmit
--                                           (server, trusted = true) delivered
--   ApplyMinigame(profile, raw, now)        server only
-- Both return a breakdown for the client (nil when the result was rejected outright).
-- Later phases plug in through the hook lists (level rewards, weekly prizes, lootbox drops) instead of editing this.
local RS = game:GetService("ReplicatedStorage")
local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Economy = RS:WaitForChild("Economy")
local Config = require(Economy:WaitForChild("EconomyConfig"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))
local Challenges = require(script.Parent:WaitForChild("Challenges"))

local Rewards = {}

-- per-match ceilings (a 5-minute match can't legitimately exceed these)
local LIMITS: { [string]: number } = { goals = 40, assists = 40, saves = 60, epicSaves = 40, shots = 100, clears = 100, demos = 60, aerials = 100, pinches = 60, points = 20000 }
Rewards.LIMITS = LIMITS

-- hooks: fn(profile, level, breakdown) when a level is reached ; fn(profile, completions, allWeekly, breakdown)
-- after challenges complete ; fn(profile, source, breakdown, now) after an eligible result (drops)
Rewards.LevelHooks = {} :: { (any, number, any) -> () }
Rewards.ChallengeHooks = {} :: { (any, { any }, boolean, any) -> () }
Rewards.ResultHooks = {} :: { (any, string, any, number) -> () }
-- per-day counters added by later phases (reset with the rest of econ)
Rewards.DailyCounters = {} :: { string }

local function num(v: any, lo: number, hi: number): number
	if type(v) ~= "number" or v ~= v then
		return 0
	end
	return math.clamp(math.floor(v), lo, hi)
end

export type Breakdown = {
	source: string, eligible: boolean, reason: string?,
	xp: number, credits: number, capped: boolean, firstWin: boolean,
	levelFrom: number, levelTo: number, levels: { number }, levelCredits: number,
	challenges: { any }, items: { any }, boxes: { any },
}

local function newBreakdown(profile: any, source: string): Breakdown
	local level = Progression.FromXp(profile.xp)
	return {
		source = source, eligible = true, reason = nil,
		xp = 0, credits = 0, capped = false, firstWin = false,
		levelFrom = level, levelTo = level, levels = {}, levelCredits = 0,
		challenges = {}, items = {}, boxes = {},
	}
end

-- new UTC day -> the daily counters start over
function Rewards.EnsureDay(profile: any, now: number)
	local e = profile.econ
	local day = DateUtil.DayIndex(now)
	if e.day ~= day then
		e.day = day
		e.earned = 0
		e.localCredits = 0
		e.localXp = 0
		for _, k in Rewards.DailyCounters do e[k] = 0 end
	end
end

-- adds XP and credits; every level crossed pays its level credits once (rewardedLevel remembers the last one paid)
function Rewards.Grant(profile: any, xp: number, credits: number, b: Breakdown)
	xp, credits = math.max(0, math.floor(xp)), math.max(0, math.floor(credits))
	profile.xp += xp
	profile.credits += credits
	profile.creditsEarned += credits
	b.xp += xp
	b.credits += credits
	local level = Progression.FromXp(profile.xp)
	while profile.rewardedLevel < level do
		local L = profile.rewardedLevel + 1
		profile.rewardedLevel = L
		local c = Progression.LevelCredits(L)
		profile.credits += c
		profile.creditsEarned += c
		b.credits += c
		b.levelCredits += c
		table.insert(b.levels, L)
		for _, h in Rewards.LevelHooks do h(profile, L, b) end
	end
	b.levelTo = Progression.FromXp(profile.xp)
end

-- the server decides the source; a client report is always "local" (or rejected training)
function Rewards.Classify(raw: any, trusted: boolean): string
	if raw.mode == "training" then return "training" end
	if not trusted or raw.online ~= true then return "local" end
	if num(raw.humanOpponents, 0, 64) >= 1 then
		return if raw.ranked == true then "ranked" else "online_pvp"
	end
	return "online_bots"
end

-- daily cap + the local sub-caps. Returns the xp / credits actually allowed.
local function applyCaps(profile: any, source: string, xp: number, credits: number, b: Breakdown): (number, number)
	local e = profile.econ
	if source == "local" then
		xp = math.min(xp, math.max(0, Config.LOCAL_DAILY_XP - e.localXp))
		e.localXp += xp
		local room = math.max(0, Config.LOCAL_DAILY_CREDITS - e.localCredits)
		if credits > room then
			credits = room
			b.capped = true
		end
	end
	local room = math.max(0, Config.DAILY_CREDIT_CAP - e.earned)
	if credits > room then
		credits = room
		b.capped = true
	end
	e.earned += credits
	if source == "local" then e.localCredits += credits end
	return xp, credits
end

local function firstWin(profile: any, source: string, won: boolean, b: Breakdown): (number, number)
	local e = profile.econ
	if won and Config.FIRST_WIN.sources[source] and e.firstWinDay ~= e.day then
		e.firstWinDay = e.day
		b.firstWin = true
		return Config.FIRST_WIN.xp, Config.FIRST_WIN.credits
	end
	return 0, 0
end

local function finish(profile: any, rec: any, xp: number, credits: number, won: boolean, b: Breakdown, now: number)
	xp, credits = applyCaps(profile, rec.source, xp, credits, b)
	local fx, fc = firstWin(profile, rec.source, won, b)
	Rewards.Grant(profile, xp + fx, credits + fc, b)
	local done, allWeekly = Challenges.Apply(profile, rec, now)
	for _, c in done do
		Rewards.Grant(profile, c.xp, c.credits, b)
		table.insert(b.challenges, c)
	end
	if #done > 0 then
		for _, h in Rewards.ChallengeHooks do h(profile, done, allWeekly, b) end
	end
	for _, h in Rewards.ResultHooks do h(profile, rec.source, b, now) end
end

function Rewards.ApplyMatch(profile: any, raw: any, trusted: boolean, now: number): Breakdown?
	if type(raw) ~= "table" then return nil end
	local result = raw.result
	if result ~= "win" and result ~= "loss" and result ~= "draw" then return nil end
	local source = Rewards.Classify(raw, trusted)
	if source == "training" then return nil end

	-- career stats (same rules as before the economy)
	local d = profile
	d.matches += 1
	if result == "win" then
		d.wins += 1
		d.streak += 1
		d.bestStreak = math.max(d.bestStreak, d.streak)
	elseif result == "loss" then
		d.losses += 1
		d.streak = 0
	else
		d.draws += 1
		d.streak = 0
	end
	local rec: { [string]: any } = {
		kind = "match", source = source, result = result, streak = d.streak,
		online = source ~= "local", ranked = source == "ranked", mode = if raw.mode == "2v2" then "2v2" else "1v1",
		scoreFor = if type(raw.scoreFor) == "number" then num(raw.scoreFor, 0, 99) else nil,
		scoreAgainst = if type(raw.scoreAgainst) == "number" then num(raw.scoreAgainst, 0, 99) else nil,
	}
	for k, lim in LIMITS do
		rec[k] = num(raw[k], 0, lim)
		d[k] += rec[k]
	end
	rec.bestKmh = num(raw.bestKmh, 0, 400)
	d.bestKmh = math.max(d.bestKmh, rec.bestKmh)
	d.bestPinchKmh = math.max(d.bestPinchKmh, num(raw.bestPinchKmh, 0, 400))

	Rewards.EnsureDay(profile, now)
	local b = newBreakdown(profile, source)
	local e = profile.econ
	if source == "local" then
		if now - e.lastLocal < Config.LOCAL_MIN_INTERVAL then
			b.eligible, b.reason = false, "interval"
		else
			e.lastLocal = now
		end
	elseif type(raw.activeSeconds) == "number" and raw.activeSeconds < Config.MIN_ONLINE_SECONDS then
		b.eligible, b.reason = false, "short"
	end
	if not b.eligible then return b end

	local xp = Progression.MatchXp(rec.points, result, source)
	local credits = Progression.MatchCredits(rec.points, result, source)
	finish(profile, rec, xp, credits, result == "win", b, now)
	return b
end

function Rewards.ApplyMinigame(profile: any, raw: any, now: number): Breakdown?
	if type(raw) ~= "table" then return nil end
	local placement = num(raw.placement, 0, 64)
	if placement < 1 then return nil end
	local humans = num(raw.humans, 0, 64)
	local source = if humans >= 2 then "minigame" else "minigame_bots"
	profile.minigames += 1
	if placement == 1 then profile.minigameWins += 1 end

	Rewards.EnsureDay(profile, now)
	local b = newBreakdown(profile, source)
	if type(raw.activeSeconds) == "number" and raw.activeSeconds < Config.MIN_MINIGAME_SECONDS then
		b.eligible, b.reason = false, "short"
		return b
	end
	local rec = { kind = "minigame", source = source, placement = placement, result = if placement == 1 then "win" else "loss",
		minigameId = if type(raw.minigameId) == "string" then raw.minigameId else nil }
	finish(profile, rec, Progression.MinigameXp(placement, source), Progression.MinigameCredits(placement, source), placement == 1, b, now)
	return b
end

return Rewards
