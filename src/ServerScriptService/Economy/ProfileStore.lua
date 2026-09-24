--!strict
-- ProfileStore.lua (server): loads, keeps and saves every player's profile (docs/progression.md §5.3).
--   * DataStore "SupersonicProfile_v2". A player with nothing there yet is brought over from "SupersonicProfile_v1",
--     which is never written again (it stays as a backup, and a server still running the old code can only write v1).
--   * UpdateAsync with a session lock { job, t }: another server holding a fresh lock (a teleport in progress) is
--     waited for; a lock older than LOCK_STALE is taken over. Autosave refreshes it; leaving releases it.
--   * Saves: throttled after rewards (SaveSoon), immediate for spending (SaveNow), every AUTOSAVE s, on leave and
--     on shutdown. A profile that failed to load is session-only (persistent = false) and never saved, so a
--     DataStore hiccup can't overwrite a good profile with an empty one.
-- Other server code (ProfileService, the shop, lootboxes, PartyMinigameService) reads profiles through Get / WaitFor.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Economy = RS:WaitForChild("Economy")
local Config = require(Economy:WaitForChild("EconomyConfig"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))
local ProfileSchema = require(script.Parent:WaitForChild("ProfileSchema"))
local Challenges = require(script.Parent:WaitForChild("Challenges"))

local ProfileStore = {}

local STORE_NAME = "SupersonicProfile_v2"
local LEGACY_NAME = "SupersonicProfile_v1"
local LOCK_STALE = 90 -- s without a refresh before another server may take the profile
local LOCK_RETRIES = 5
local LOCK_WAIT = 2
local AUTOSAVE = 60
local SAVE_GAP = 6 -- s between throttled saves

type Meta = {
	persistent: boolean, -- loaded from the DataStore: saves go back to it
	readOnly: boolean, -- written by a newer schema (or another server took it): never saved
	dirty: boolean,
	saving: boolean,
	lastSave: number,
	saveQueued: boolean,
	notice: { [string]: any }?, -- one-time info for the client (welcome bonus)
}

local profiles: { [Player]: { [string]: any } } = {}
local meta: { [Player]: Meta } = {}
local loading: { [Player]: boolean } = {}

local store: DataStore?, legacy: DataStore? = nil, nil
do
	local ok, a, b = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME), DataStoreService:GetDataStore(LEGACY_NAME)
	end)
	if ok then store, legacy = a, b end
end

-- summary hooks: fn(player, profile, out) adds fields to what the client receives (later phases)
ProfileStore.SummaryHooks = {} :: { (Player, any, any) -> () }
-- load hooks: fn(player, profile, info) right after a profile is ready (later phases, e.g. granting level items)
ProfileStore.LoadHooks = {} :: { (Player, any, any) -> () }

local function key(p: Player): string
	return "u_" .. p.UserId
end

local function lockedByOther(old: any): boolean
	local lock = type(old) == "table" and old._lock
	return type(lock) == "table" and lock.job ~= game.JobId and type(lock.t) == "number" and os.time() - lock.t < LOCK_STALE
end

local function newerSchema(old: any): boolean
	return type(old) == "table" and (tonumber(old.schema) or 1) > ProfileSchema.VERSION
end

-- remotes live in ReplicatedStorage.Remotes and are created here by code (no Studio instances needed)
function ProfileStore.Remote(class: string, name: string): Instance
	local remotes = RS:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = RS
	end
	local r = (remotes :: Instance):FindFirstChild(name)
	if not r then
		local made: Instance = Instance.new(class :: any)
		made.Name = name
		made.Parent = remotes
		r = made
	end
	return r :: Instance
end

-- returns ok, raw (nil = new player), fromLegacy
local function readRaw(p: Player): (boolean, any, boolean)
	local k = key(p)
	for attempt = 1, LOCK_RETRIES + 1 do
		local steal = attempt > LOCK_RETRIES
		local state, raw = "ok", nil
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(k, function(old)
				raw = old
				if old == nil then
					state = "empty"
					return nil
				end
				if type(old) ~= "table" or newerSchema(old) then
					state = "ok" -- corrupt (ProfileSchema repairs it) or newer (read-only): don't touch the record
					return nil
				end
				if not steal and lockedByOther(old) then
					state = "locked"
					return nil
				end
				state = "ok"
				local out = table.clone(old)
				out._lock = { job = game.JobId, t = os.time() }
				return out
			end)
		end)
		if not ok then
			return false, err, false
		end
		if state == "empty" then
			local okL, v1 = pcall(function()
				return (legacy :: DataStore):GetAsync(k)
			end)
			if not okL then return false, v1, false end
			return true, v1, true
		elseif state == "locked" then
			if steal then break end
			task.wait(LOCK_WAIT)
		else
			return true, raw, false
		end
	end
	return false, "locked", false
end

function ProfileStore.Load(p: Player)
	if profiles[p] or loading[p] then return end
	loading[p] = true
	local raw, ok, fromLegacy = nil, false, false
	if store and legacy then
		local success, res, legacyFlag = readRaw(p)
		if success then
			ok, raw, fromLegacy = true, res, legacyFlag
		else
			warn("[ProfileStore] DataStore unavailable, session-only profile:", res)
		end
	end
	local data, info = ProfileSchema.Migrate(raw)
	loading[p] = nil
	if not p:IsDescendantOf(Players) then
		-- left while loading: give the lock back (if we took it) without writing anything else
		if ok and not fromLegacy and not info.readOnly then
			pcall(function()
				(store :: DataStore):UpdateAsync(key(p), function(old)
					if type(old) ~= "table" or lockedByOther(old) then return nil end
					local out = table.clone(old)
					out._lock = nil
					return out
				end)
			end)
		end
		return
	end
	Challenges.Ensure(data, os.time())
	profiles[p] = data
	meta[p] = {
		persistent = ok, readOnly = info.readOnly, dirty = fromLegacy or info.from ~= ProfileSchema.VERSION,
		saving = false, lastSave = os.clock(), saveQueued = false,
		notice = if (info.welcomeBonus or 0) > 0 then { welcomeBonus = info.welcomeBonus } else nil,
	}
	for _, h in ProfileStore.LoadHooks do
		local okH, e = pcall(function(): any
			h(p, data, info)
			return nil
		end)
		if not okH then warn("[ProfileStore] load hook failed:", e) end
	end
	if meta[p].dirty then
		task.spawn(ProfileStore.Save, p) -- write the migrated profile (and the lock) straight away
	end
end

function ProfileStore.Get(p: Player): { [string]: any }?
	return profiles[p]
end

function ProfileStore.WaitFor(p: Player, timeout: number): { [string]: any }?
	local t0 = os.clock()
	while not profiles[p] and os.clock() - t0 < timeout and p.Parent do
		task.wait(0.1)
	end
	return profiles[p]
end

function ProfileStore.IsPersistent(p: Player): boolean
	local m = meta[p]
	return m ~= nil and m.persistent and not m.readOnly
end

-- spending (shop, lootboxes) needs a profile that is really saved; Studio without API access is allowed so the
-- flow can be tested (nothing is kept after the session anyway)
function ProfileStore.CanSpend(p: Player): boolean
	local m = meta[p]
	if not m or m.readOnly then return false end
	return m.persistent or RunService:IsStudio()
end

function ProfileStore.MarkDirty(p: Player)
	local m = meta[p]
	if m then m.dirty = true end
end

-- returns true when the profile reached the DataStore
function ProfileStore.Save(p: Player, release: boolean?): boolean
	local d, m = profiles[p], meta[p]
	if not d or not m or not m.persistent or m.readOnly or not store then
		return false
	end
	local t0 = os.clock()
	while m.saving and os.clock() - t0 < 15 do
		task.wait(0.1)
	end
	m.saving = true
	m.dirty = false
	local snapshot = ProfileSchema.DeepCopy(d)
	local lost = false
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(key(p), function(old)
			if lockedByOther(old) or newerSchema(old) then
				lost = true
				return nil
			end
			local out = table.clone(snapshot)
			out._lock = if release then nil else { job = game.JobId, t = os.time() }
			return out
		end)
	end)
	m.saving = false
	if not ok then
		m.dirty = true
		warn("[ProfileStore] save failed:", err)
		return false
	end
	if lost then
		-- another server owns this profile now: stop writing from here so we can't clobber it
		m.readOnly = true
		warn("[ProfileStore] profile locked by another server; this session won't save it any more")
		return false
	end
	m.lastSave = os.clock()
	return true
end

function ProfileStore.SaveNow(p: Player): boolean
	return ProfileStore.Save(p)
end

-- save within SAVE_GAP seconds (several rewards in a row become one write)
function ProfileStore.SaveSoon(p: Player)
	local m = meta[p]
	if not m then return end
	m.dirty = true
	if m.saveQueued then return end
	m.saveQueued = true
	task.delay(math.max(0, m.lastSave + SAVE_GAP - os.clock()), function()
		m.saveQueued = false
		if profiles[p] and m.dirty then ProfileStore.Save(p) end
	end)
end

function ProfileStore.Release(p: Player)
	if profiles[p] then
		ProfileStore.Save(p, true)
	end
	profiles[p] = nil
	meta[p] = nil
	loading[p] = nil
end

function ProfileStore.All(): { Player }
	local out = {}
	for p in profiles do table.insert(out, p) end
	return out
end

-- what the client receives (GetProfile / ProfileUpdate)
function ProfileStore.Summary(p: Player): { [string]: any }?
	local d, m = profiles[p], meta[p]
	if not d or not m then return nil end
	local now = os.time()
	if Challenges.Ensure(d, now) then m.dirty = true end
	local out: { [string]: any } = {}
	for k in ProfileSchema.STATS do out[k] = d[k] end
	out.settings = d.settings
	out.persistent = m.persistent and not m.readOnly
	local level, into, need = Progression.FromXp(d.xp)
	out.level, out.levelXp, out.levelNeed = level, into, need
	out.challenges = Challenges.View(d, now)
	local today = d.econ.day == DateUtil.DayIndex(now)
	out.dailyCap = { earned = if today then d.econ.earned else 0, max = Config.DAILY_CREDIT_CAP }
	out.serverTime = now
	if m.notice then
		out.notice = m.notice
		m.notice = nil
	end
	for _, h in ProfileStore.SummaryHooks do
		local ok, e = pcall(function(): any
			h(p, d, out)
			return nil
		end)
		if not ok then warn("[ProfileStore] summary hook failed:", e) end
	end
	return out
end

-- server -> client: { profile = summary, reward = what was just earned? } (Remotes.ProfileUpdate)
function ProfileStore.Push(p: Player, reward: any?)
	if not p.Parent then return end
	local s = ProfileStore.Summary(p)
	if s then
		(ProfileStore.Remote("RemoteEvent", "ProfileUpdate") :: RemoteEvent):FireClient(p, { profile = s, reward = reward })
	end
end

-- autosave (also refreshes the session lock)
task.spawn(function()
	while true do
		task.wait(AUTOSAVE)
		for p, m in meta do
			if m.dirty or os.clock() - m.lastSave > AUTOSAVE - 5 then
				task.spawn(ProfileStore.Save, p)
			end
		end
	end
end)

return ProfileStore
