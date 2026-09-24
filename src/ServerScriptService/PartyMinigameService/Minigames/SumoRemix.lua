--!strict
-- SumoRemix.lua (server): everyone for themselves on a shrinking safe zone. Authoritative rules:
--   * the zone plan (centres + radii of every phase) is rolled here at Start and announced; each new zone lies inside
--     the previous one, so the announced circle is always reachable
--   * at the end of every phase each car whose centre is more than TOLERANCE past the edge is eliminated: its car
--     leaves the World (no collisions), is hidden in snapshots and kept (not destroyed) for the rest of the round
--   * the last car standing wins; cars knocked out at the same check are ranked by how close to the centre they were
--   * if the clock runs out with several cars in, they are ranked by distance to the centre
--   * whoever bumped the victim last (within CREDIT_WINDOW) is credited with the knock-out
-- Clients only send controls; zone, eliminations and placements are decided here.
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SumoRemixShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local SumoRemix = {}
SumoRemix.__index = SumoRemix

SumoRemix.Id = Shared.Id
SumoRemix.DisplayName = "SUMO REMIX"
SumoRemix.Description = "La zona segura se encoge por fases. Quien esté fuera cuando se cierra queda eliminado. Gana el último en pie."
SumoRemix.MinPlayers = 2
SumoRemix.MaxPlayers = 4
SumoRemix.MaxDuration = Shared.MAX_TIME
SumoRemix.SharedModule = "SumoRemixShared"
SumoRemix.BotController = require(script.Parent.SumoRemixBotController)

function SumoRemix.new(session: any)
	local self = setmetatable({}, SumoRemix)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.rng = Random.new()
	self.zones = {} -- { { c = Vector2, r = number } }, zones[1] = start
	self.phase = 0
	self.phaseStart = 0
	self.elapsed = 0
	self.alive = {} -- member id -> true
	self.out = {} -- eliminated, in order: { id, t, dist }
	self.lastBump = {} -- victim member id -> { by = member id, t }
	self.finished = false
	self.resultSummary = nil
	return self
end

-- free for all: each member is its own side (seat index); the car's physics team alternates (only matters for demos,
-- which are disabled)
function SumoRemix.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do
		out[m.id] = i - 1
	end
	return out
end

function SumoRemix.Setup(self: any)
	local slots = Shared.SpawnSlots(#self.session.members)
	for i, m in self.session.members do
		local car = self.session.spawns:Spawn(m, (i - 1) % 2, slots[i].pos, slots[i].yaw)
		car.boost = 100
		self.alive[m.id] = true
	end
	self.world.ballEnabled = false
	-- roll the zone plan now so the loading screen / countdown can already show the first circle
	self.zones = { { c = Vector2.zero, r = Shared.R0 } }
	for k, r in Shared.RADII do
		local prev = self.zones[k]
		local room = prev.r - r
		local c
		for _ = 1, 20 do
			local a = self.rng:NextNumber(0, math.pi * 2)
			local d = self.rng:NextNumber(0.25, 0.9) * room
			c = prev.c + Vector2.new(math.cos(a), math.sin(a)) * d
			if math.abs(c.X) + r < Shared.FLOOR_LIMIT.X and math.abs(c.Y) + r < Shared.FLOOR_LIMIT.Y then break end
			c = prev.c
		end
		table.insert(self.zones, { c = c, r = r })
	end
end

function SumoRemix.Start(self: any)
	self:BeginPhase(1)
end

function SumoRemix.BeginPhase(self: any, k: number)
	self.phase = k
	self.phaseStart = self.elapsed
	self.session:Broadcast("zone", self:ZonePayload())
	self:PushState()
end

function SumoRemix.ZonePayload(self: any): any
	return { phase = self.phase, phases = #Shared.RADII, zones = self.zones, phaseStart = self.session.timer.startTime + self.phaseStart }
end

function SumoRemix.AliveCount(self: any): number
	local n = 0
	for _ in self.alive do n += 1 end
	return n
end

function SumoRemix.PublicState(self: any): any
	return {
		phase = self.phase, phases = #Shared.RADII, zones = self.zones, alive = self:AliveCount(), total = #self.session.members,
		phaseStart = if self.phase > 0 then self.session.timer.startTime + self.phaseStart else nil,
	}
end

function SumoRemix.PushState(self: any)
	local alive = {}
	for id in self.alive do table.insert(alive, id) end
	self.session:Broadcast("state", { alive = alive, phase = self.phase })
end

function SumoRemix.PreTick(self: any, dt: number)
	for _, car in self.world.cars do
		Shared.PreTick(car, dt)
	end
end

local function flatDist(car: any, c: Vector2): number
	local p = car.body.pos * BT
	return (Vector2.new(p.X, p.Y) - c).Magnitude
end

function SumoRemix.Eliminate(self: any, list: { any }, why: string)
	-- list: { { m, dist } } knocked out at the same moment; the farther from the centre goes out first
	table.sort(list, function(a, b) return a.dist > b.dist end)
	for _, e in list do
		local m = e.m
		if not self.alive[m.id] then continue end
		self.alive[m.id] = nil
		local car = self.session:CarOf(m.id)
		if car then
			car.netHidden = true
			self.world:RemoveCar(car) -- out of the physics, kept for the round (not destroyed)
		end
		local credit = self.lastBump[m.id]
		local by = if credit and self.elapsed - credit.t <= Shared.CREDIT_WINDOW and self.alive[credit.by] then credit.by else nil
		if by then self.score:Stat(by, "knockouts", 1) end
		table.insert(self.out, { id = m.id, t = self.elapsed, dist = e.dist })
		self.session:Broadcast("eliminated", { id = m.id, by = by, why = why, left = self:AliveCount(), pos = car and car.body.pos * BT })
	end
	self:PushState()
end

function SumoRemix.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt

	-- bumps: remember who pushed whom (for the knock-out credit)
	for _, e in self.world.events do
		if e.type == "bump" or e.type == "demo" then
			local a, v = self.session:MemberOfCar(e.bumper), self.session:MemberOfCar(e.victim)
			if a and v then
				self.lastBump[v.id] = { by = a.id, t = self.elapsed }
				self.score:Stat(a.id, "bumps", 1)
			end
		end
	end

	-- failsafe: a car that somehow left the arena is out
	local lost = {}
	for id in self.alive do
		local car = self.session:CarOf(id)
		if car then
			local p = car.body.pos * BT
			if p ~= p or math.abs(p.X) > 4300 or math.abs(p.Y) > 6300 or p.Z < -200 or p.Z > 2300 then
				table.insert(lost, { m = self.session.byId[id], dist = math.huge })
			end
		end
	end
	if #lost > 0 then self:Eliminate(lost, "fuera del estadio") end

	-- phase clock: check at the end of the closing
	local t = self.elapsed - self.phaseStart
	if t >= Shared.PHASE then
		local c, r = Shared.ZoneAt(self.zones, self.phase, Shared.PHASE)
		local outList = {}
		for id in self.alive do
			local car = self.session:CarOf(id)
			if car and Shared.Outside(car.body.pos * BT, c, r) then
				table.insert(outList, { m = self.session.byId[id], dist = flatDist(car, c) })
			end
		end
		-- everyone out at once: the closest one survives (a round always has a winner)
		if #outList > 0 and #outList >= self:AliveCount() then
			table.sort(outList, function(a, b) return a.dist < b.dist end)
			table.remove(outList, 1)
		end
		if #outList > 0 then self:Eliminate(outList, "fuera de la zona") end
		if self:AliveCount() <= 1 then
			self:Finish("último en pie")
			return
		end
		if self.phase >= #Shared.RADII then
			self:Finish("zona final")
			return
		end
		self:BeginPhase(self.phase + 1)
	end
	if self:AliveCount() <= 1 then
		self:Finish("último en pie")
	end
end

function SumoRemix.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local places = self:Placements()
	local winner = places[1] and self.session.byId[places[1].id]
	self.resultSummary = {
		title = if winner then ("%s GANA"):format(winner.name) else "SIN GANADOR",
		detail = why,
	}
end

-- alive cars first (closest to the zone centre first), then the knocked-out in reverse order of elimination
function SumoRemix.Placements(self: any): { any }
	local c = if self.zones[self.phase] then (Shared.ZoneAt(self.zones, math.max(1, self.phase), self.elapsed - self.phaseStart)) else Vector2.zero
	local alive = {}
	for id in self.alive do
		local car = self.session:CarOf(id)
		table.insert(alive, { id = id, dist = if car then flatDist(car, c) else math.huge })
	end
	table.sort(alive, function(a, b) return a.dist < b.dist end)
	local out = {}
	for _, a in alive do table.insert(out, { id = a.id }) end
	for i = #self.out, 1, -1 do table.insert(out, { id = self.out[i].id }) end
	return out
end

function SumoRemix.ControlsLocked(self: any): boolean
	return self.finished
end

function SumoRemix.BallVisible(self: any): boolean
	return false
end

function SumoRemix.HandlePlayerJoin(self: any, member: any)
	-- spectates; plays the next round
end

function SumoRemix.HandlePlayerLeave(self: any, member: any)
	if self.alive[member.id] then
		self.alive[member.id] = nil
		table.insert(self.out, { id = member.id, t = self.elapsed, dist = math.huge })
		self.session:Broadcast("eliminated", { id = member.id, why = "abandonó", left = self:AliveCount() })
		self:PushState()
	end
	if self:AliveCount() <= 1 and self.phase > 0 then
		self:Finish("último en pie")
	end
end

function SumoRemix.HandlePlayerEliminated(self: any, member: any)
	local car = self.session:CarOf(member.id)
	self:Eliminate({ { m = member, dist = if car then flatDist(car, Vector2.zero) else math.huge } }, "eliminado")
end

function SumoRemix.End(self: any)
	if not self.finished then
		self:Finish("tiempo")
	end
end

function SumoRemix.GetScore(self: any, member: any): number
	return self.score:Member(member.id).stats.knockouts or 0
end

function SumoRemix.IsFinished(self: any): boolean
	return self.finished
end

function SumoRemix.GetPlacements(self: any): { any }
	local out = {}
	for i, p in self:Placements() do
		table.insert(out, { id = p.id, placement = i, score = self.score:Member(p.id).stats.knockouts or 0, stats = self.score:Member(p.id).stats })
	end
	-- members that never got a car (shouldn't happen) go last
	local seen = {}
	for _, p in out do seen[p.id] = true end
	for _, m in self.session.members do
		if not seen[m.id] then table.insert(out, { id = m.id, placement = #out + 1, score = 0, stats = {} }) end
	end
	return out
end

function SumoRemix.Cleanup(self: any)
	self.cleanup:Clean()
end

return SumoRemix
