--!strict
-- Derby.lua (server): Demolition Derby. Everyone against everyone, no ball.
--   * a demolition (supersonic hit, Rocket League's rule) = +1 point for the demolisher
--   * a demolished car comes back after the usual respawn time at the spawn farthest from everyone else
--   * FRENZY: the last seconds demolish on ANY contact (world.demoMode = "on_contact")
--   * fairness: a (re)spawned car has a SPAWN_SHIELD (can't be demolished nor demolish), demolishing the same car
--     again within FARM_WINDOW scores nothing (no spawn camping), and demolishing a leader who is 2+ ahead pays BOUNTY
--   * ranking: points, then demolitions, then fewest times demolished, then bumps
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local CarPhysics = require(Phys.CarPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("DerbyShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local Derby = {}
Derby.__index = Derby

Derby.Id = Shared.Id
Derby.DisplayName = "DERBI DE DEMOLICIONES"
Derby.Description = "Sin balón: demuele a los demás chocándolos a velocidad supersónica. Cada demolición es un punto."
Derby.MinPlayers = 2
Derby.MaxPlayers = 4
Derby.MaxDuration = Shared.MAX_TIME
Derby.SharedModule = "DerbyShared"
Derby.BotController = require(script.Parent.DerbyBotController)

function Derby.new(session: any)
	local self = setmetatable({}, Derby)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.elapsed = 0
	self.demos = {} -- member id -> demolitions
	self.deaths = {} -- member id -> times demolished
	self.bumps = {}
	self.points = {} -- member id -> points (a demo is 1, a bounty 2, a farmed repeat 0)
	self.lastDemo = {} -- "attacker>victim" -> elapsed of the last scoring demo
	self.frenzy = false
	self.finished = false
	self.resultSummary = nil
	self.lastScores = 0
	return self
end

function Derby.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = i - 1 end
	return out
end

-- the spawn farthest from every other live car
function Derby.SafeSpawn(self: any, exclude: any?): any
	local spawns = Shared.Map().spawns
	local best, bestD = spawns[1], -1
	for _, s in spawns do
		local d = math.huge
		for _, car in self.world.cars do
			if car ~= exclude and not car.isDemoed then
				d = math.min(d, ((car.body.pos * BT) - s.pos).Magnitude)
			end
		end
		d += Random.new():NextNumber(0, 600) -- a little variety
		if d > bestD then best, bestD = s, d end
	end
	return best
end

function Derby.Setup(self: any)
	local spawns = Shared.Map().spawns
	local n = #self.session.members
	for i, m in self.session.members do
		-- spread the players evenly round the bowl
		local s = spawns[((i - 1) * math.floor(#spawns / math.max(n, 1))) % #spawns + 1]
		local car = self.session.spawns:Spawn(m, (i - 1) % 2, s.pos, s.yaw)
		car.boost = 100
		self.demos[m.id], self.deaths[m.id], self.bumps[m.id], self.points[m.id] = 0, 0, 0, 0
		self:Shield(car, m)
	end
	self.world.ballEnabled = false
	-- demolished cars come back at a safe spawn (the world calls this when their respawn timer runs out)
	self.world.onRespawn = function(car: any)
		local s = self:SafeSpawn(car)
		CarPhysics.ResetState(car, s.pos, s.yaw, Shared.RESPAWN_BOOST, true)
		local m = self.session:MemberOfCar(car)
		self:Shield(car, m)
	end
end

-- spawn shield (the world's demoFilter reads car.shieldUntil, in world ticks)
function Derby.Shield(self: any, car: any, m: any?)
	car.shieldUntil = self.world.tickCount + math.floor(Shared.SPAWN_SHIELD * 120)
	if m then self.session:Broadcast("shield", { id = m.id, time = Shared.SPAWN_SHIELD }) end
end

function Derby.Leader(self: any): (string?, number)
	local best, bestV, second = nil, -1, -1
	for id, v in self.points do
		if v > bestV then best, second, bestV = id, bestV, v elseif v > second then second = v end
	end
	return best, bestV - math.max(second, 0)
end

function Derby.Start(self: any)
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		if car then self:Shield(car, m) end
	end
end

function Derby.PublicState(self: any): any
	return { demos = self.demos, deaths = self.deaths, points = self.points, frenzy = self.frenzy }
end

function Derby.PreTick(self: any, dt: number)
	for _, car in self.world.cars do Shared.PreTick(car, dt) end
end

function Derby.ControlsLocked(self: any): boolean
	return self.finished
end

function Derby.BallVisible(self: any): boolean
	return false
end

function Derby.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	local w = self.world
	for _, e in w.events do
		if e.type == "demo" then
			local a, v = self.session:MemberOfCar(e.bumper), self.session:MemberOfCar(e.victim)
			if a and v then
				-- what this demolition is worth: a farmed repeat 0, the runaway leader a bounty
				local key = a.id .. ">" .. v.id
				local farmed = self.lastDemo[key] ~= nil and self.elapsed - self.lastDemo[key] < Shared.FARM_WINDOW
				local leader, lead = self:Leader()
				local worth = if farmed then 0 elseif leader == v.id and lead >= 2 then Shared.BOUNTY else 1
				if not farmed then self.lastDemo[key] = self.elapsed end
				self.points[a.id] += worth
				self.demos[a.id] += 1
				self.deaths[v.id] += 1
				self.score:Add(a.id, worth)
				self.score:Stat(a.id, "demos", 1)
				self.score:Stat(v.id, "demolished", 1)
				local streak = (self.streak and self.streak[a.id] or 0) + 1
				self.streak = self.streak or {}
				self.streak[a.id], self.streak[v.id] = streak, 0
				self.session:Broadcast("demo", {
					by = a.id, victim = v.id, pos = e.victim.body.pos * BT, streak = streak, worth = worth,
					farmed = farmed, bounty = worth == Shared.BOUNTY, demos = self.demos, deaths = self.deaths, points = self.points,
				})
			end
		elseif e.type == "bump" then
			local a = self.session:MemberOfCar(e.bumper)
			if a then
				self.bumps[a.id] += 1
				self.score:Stat(a.id, "bumps", 1)
			end
		end
	end
	if not self.frenzy and self.elapsed >= Shared.FRENZY_AT then
		self.frenzy = true
		w.demoMode = "on_contact"
		self.session:Broadcast("frenzy", {})
	end
	if self.elapsed - self.lastScores >= 1 then
		self.lastScores = self.elapsed
		self.session:Broadcast("scores", { demos = self.demos, deaths = self.deaths, points = self.points })
	end
end

function Derby.Standings(self: any): { any }
	local entries = {}
	for _, m in self.session.members do
		table.insert(entries, { id = m.id, keys = { self.points[m.id] or 0, self.demos[m.id] or 0, -(self.deaths[m.id] or 0), self.bumps[m.id] or 0 } })
	end
	return Score.Rank(entries)
end

function Derby.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local st = self:Standings()
	local w = st[1] and self.session.byId[st[1].id]
	self.resultSummary = {
		title = if w then ("%s GANA"):format(w.name) else "SIN GANADOR",
		detail = if w then ("%d puntos · %d demoliciones  ·  %s"):format(self.points[w.id] or 0, self.demos[w.id] or 0, why) else why,
	}
	self.session:Broadcast("scores", { demos = self.demos, deaths = self.deaths, points = self.points })
end

function Derby.IsFinished(self: any): boolean
	return self.finished
end

function Derby.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function Derby.HandlePlayerJoin(self: any, member: any) end
function Derby.HandlePlayerLeave(self: any, member: any) end
function Derby.HandlePlayerEliminated(self: any, member: any) end

function Derby.GetScore(self: any, member: any): number
	return self.points[member.id] or 0
end

function Derby.GetPlacements(self: any): { any }
	local out = {}
	for _, p in self:Standings() do
		local st = self.score:Member(p.id).stats
		table.insert(out, { id = p.id, placement = p.placement, score = self.points[p.id] or 0, stats = st })
	end
	return out
end

function Derby.Cleanup(self: any)
	self.world.onRespawn = nil
	self.cleanup:Clean()
end

return Derby
