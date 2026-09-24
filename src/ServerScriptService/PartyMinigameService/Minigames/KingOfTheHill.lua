--!strict
-- KingOfTheHill.lua (server): hold the hill alone to earn control time. Authoritative rules:
--   * the hill sequence (HILLS spots, each MIN_HOP from the last) is rolled here and announced; each hill lasts
--     HILL_TIME and the next one is announced NEXT_WARN seconds before it moves
--   * every tick the server counts the cars on the hill (OnHill: flat distance + height). Exactly one -> that player
--     earns dt of control; two or more -> contested, nobody earns
--   * control changes are sent as discrete events; scores go out once a second (no per-frame traffic)
--   * ranking: control time, then total time spent on the hill (contested included)
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("KingOfTheHillShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local KingOfTheHill = {}
KingOfTheHill.__index = KingOfTheHill

KingOfTheHill.Id = Shared.Id
KingOfTheHill.DisplayName = "REY DE LA COLINA"
KingOfTheHill.Description = "Suma segundos estando SOLO en la colina. Si hay dos dentro, nadie suma. La colina cambia de sitio."
KingOfTheHill.MinPlayers = 2
KingOfTheHill.MaxPlayers = 4
KingOfTheHill.MaxDuration = Shared.MAX_TIME
KingOfTheHill.SharedModule = "KingOfTheHillShared"
KingOfTheHill.BotController = require(script.Parent.KingOfTheHillBotController)

function KingOfTheHill.new(session: any)
	local self = setmetatable({}, KingOfTheHill)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.rng = Random.new()
	self.hills = {} -- Vector2 centres
	self.index = 0
	self.hillStart = 0
	self.elapsed = 0
	self.control = {} -- member id -> seconds alone on the hill
	self.onTime = {} -- member id -> seconds on the hill (contested too)
	self.holder = nil :: string? -- member id | "contested" | nil
	self.lastScores = 0
	self.finished = false
	self.resultSummary = nil
	return self
end

function KingOfTheHill.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = i - 1 end
	return out
end

function KingOfTheHill.Setup(self: any)
	local slots = Shared.SpawnSlots(#self.session.members)
	for i, m in self.session.members do
		local car = self.session.spawns:Spawn(m, (i - 1) % 2, slots[i].pos, slots[i].yaw)
		car.boost = 100
		self.control[m.id] = 0
		self.onTime[m.id] = 0
	end
	self.world.ballEnabled = false
	-- the first hill is the centre; then random spots, each far enough from the previous one
	self.hills = { Shared.SPOTS[1] }
	for k = 2, Shared.HILLS do
		local prev = self.hills[k - 1]
		local pick = prev
		for _ = 1, 30 do
			local s = Shared.SPOTS[self.rng:NextInteger(1, #Shared.SPOTS)]
			if (s - prev).Magnitude >= Shared.MIN_HOP then pick = s break end
		end
		table.insert(self.hills, pick)
	end
end

function KingOfTheHill.Start(self: any)
	self:BeginHill(1)
end

function KingOfTheHill.BeginHill(self: any, k: number)
	self.index = k
	self.hillStart = self.elapsed
	self.session:Broadcast("hill", self:HillPayload())
end

function KingOfTheHill.HillPayload(self: any): any
	local t0 = self.session.timer.startTime + self.hillStart
	return {
		index = self.index, hills = self.hills, count = Shared.HILLS,
		startTime = t0, endTime = t0 + Shared.HILL_TIME,
	}
end

function KingOfTheHill.PublicState(self: any): any
	return {
		index = self.index, hills = self.hills, count = Shared.HILLS, control = self.control, holder = self.holder,
		startTime = if self.index > 0 then self.session.timer.startTime + self.hillStart else nil,
	}
end

function KingOfTheHill.PreTick(self: any, dt: number)
	for _, car in self.world.cars do
		Shared.PreTick(car, dt)
	end
end

function KingOfTheHill.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	local t = self.elapsed - self.hillStart
	if t >= Shared.HILL_TIME then
		if self.index >= Shared.HILLS then
			self:Finish("tiempo")
			return
		end
		self:BeginHill(self.index + 1)
	end

	local c = self.hills[self.index]
	local on = {}
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		if car and not car.netHidden then
			local p = car.body.pos * BT
			if p == p and Shared.OnHill(p, c) then
				table.insert(on, m.id)
				self.onTime[m.id] += dt
			end
		end
	end
	local holder = if #on == 1 then on[1] elseif #on > 1 then "contested" else nil
	if #on == 1 then
		self.control[on[1]] += dt
	elseif #on > 1 then
		for _, id in on do self.score:Stat(id, "contested", dt) end
	end
	if holder ~= self.holder then
		self.holder = holder
		self.session:Broadcast("control", { holder = holder, on = on })
	end
	-- scores once a second (display only; the ranking uses the server's numbers)
	if self.elapsed - self.lastScores >= 1 then
		self.lastScores = self.elapsed
		self.session:Broadcast("scores", { control = self.control })
	end
end

function KingOfTheHill.Standings(self: any): { any }
	local entries = {}
	for _, m in self.session.members do
		-- tenths of a second, so tiny float differences don't split a real tie
		table.insert(entries, { id = m.id, keys = { math.floor((self.control[m.id] or 0) * 10), math.floor((self.onTime[m.id] or 0) * 10) } })
	end
	return Score.Rank(entries)
end

function KingOfTheHill.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local st = self:Standings()
	local w = st[1] and self.session.byId[st[1].id]
	self.resultSummary = {
		title = if w then ("%s GANA"):format(w.name) else "SIN GANADOR",
		detail = if w then ("%.1f s en la colina  ·  %s"):format(self.control[w.id] or 0, why) else why,
	}
	self.session:Broadcast("scores", { control = self.control })
end

function KingOfTheHill.ControlsLocked(self: any): boolean
	return self.finished
end

function KingOfTheHill.BallVisible(self: any): boolean
	return false
end

function KingOfTheHill.HandlePlayerJoin(self: any, member: any) end
function KingOfTheHill.HandlePlayerLeave(self: any, member: any) end
function KingOfTheHill.HandlePlayerEliminated(self: any, member: any) end

function KingOfTheHill.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function KingOfTheHill.GetScore(self: any, member: any): number
	return self.control[member.id] or 0
end

function KingOfTheHill.IsFinished(self: any): boolean
	return self.finished
end

function KingOfTheHill.GetPlacements(self: any): { any }
	local out = {}
	for _, p in self:Standings() do
		local st = self.score:Member(p.id).stats
		st.control = math.floor((self.control[p.id] or 0) * 10) / 10
		table.insert(out, { id = p.id, placement = p.placement, score = st.control, stats = st })
	end
	return out
end

function KingOfTheHill.Cleanup(self: any)
	self.cleanup:Clean()
end

return KingOfTheHill
