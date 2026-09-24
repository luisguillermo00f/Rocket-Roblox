--!strict
-- SkyRingRush.lua (server): a race through rings, in order. Authoritative rules:
--   * the route is generated here from a fresh random seed (never the same twice) and sent to everyone
--   * every tick, each car's travelled segment (last tick -> this tick) is tested against the rings of ITS next
--     checkpoint (swept OBB): passing any ring of that checkpoint (main or shortcut) advances it by one
--   * the first to pass the last checkpoint finishes 1st; once someone finishes, the rest get GRACE seconds
--   * ranking: finished cars by finish time, then by checkpoints passed, then by distance to their next checkpoint;
--     cars that didn't finish are DNF (still ranked by progress)
-- Clients never report checkpoints; they only send controls.
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SkyRingRushShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local SkyRingRush = {}
SkyRingRush.__index = SkyRingRush

SkyRingRush.Id = Shared.Id
SkyRingRush.DisplayName = "SKY RING RUSH"
SkyRingRush.Description = "Carrera por anillos en orden, con turbo infinito. Los anillos altos son atajos. Gana quien llegue primero."
SkyRingRush.MinPlayers = 2
SkyRingRush.MaxPlayers = 4
SkyRingRush.MaxDuration = Shared.MAX_TIME
SkyRingRush.SharedModule = "SkyRingRushShared"
SkyRingRush.BotController = require(script.Parent.SkyRingRushBotController)

function SkyRingRush.new(session: any)
	local self = setmetatable({}, SkyRingRush)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.rng = Random.new()
	self.route = Shared.Generate(self.rng:NextInteger(1, 2 ^ 30))
	self.progress = {} -- member id -> next checkpoint index (1-based); > #checkpoints = finished
	self.finishTime = {} -- member id -> elapsed at finish
	self.prevPos = {} -- member id -> car position last tick (uu)
	self.elapsed = 0
	self.deadline = nil :: number?
	self.finished = false
	self.resultSummary = nil
	return self
end

function SkyRingRush.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = i - 1 end
	return out
end

function SkyRingRush.Setup(self: any)
	local slots = Shared.StartSlots(self.route, #self.session.members)
	for i, m in self.session.members do
		local car = self.session.spawns:Spawn(m, (i - 1) % 2, slots[i].pos, slots[i].yaw)
		car.boost = 100
		self.progress[m.id] = 1
		self.prevPos[m.id] = car.body.pos * BT
	end
	self.world.ballEnabled = false
end

function SkyRingRush.Start(self: any)
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		if car then self.prevPos[m.id] = car.body.pos * BT end
	end
	self:PushState()
end

function SkyRingRush.PublicState(self: any): any
	return { route = self.route, progress = self.progress, total = #self.route.checkpoints, deadline = self.deadline }
end

function SkyRingRush.PushState(self: any)
	self.session:Broadcast("state", self:PublicState())
end

function SkyRingRush.PreTick(self: any, dt: number)
	for _, car in self.world.cars do
		Shared.PreTick(car, dt)
	end
end

-- distance to the nearest ring of the member's next checkpoint (for ranking and the HUD)
function SkyRingRush.DistToNext(self: any, id: string): number
	local k = self.progress[id]
	local cp = self.route.checkpoints[k]
	local car = self.session:CarOf(id)
	if not cp or not car then return 0 end
	local p = car.body.pos * BT
	local best = math.huge
	for _, r in cp do best = math.min(best, (p - r.c).Magnitude) end
	return best
end

function SkyRingRush.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	local total = #self.route.checkpoints
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		local k = self.progress[m.id]
		if car and k and k <= total then
			local p = car.body.pos * BT
			local p0 = self.prevPos[m.id] or p
			if p == p then
				for ri, r in self.route.checkpoints[k] do
					if Shared.SweptPass(r, p0, p) then
						self.progress[m.id] = k + 1
						self.score:Stat(m.id, "rings", 1)
						if ri > 1 then self.score:Stat(m.id, "shortcuts", 1) end
						local done = k + 1 > total
						if done then
							self.finishTime[m.id] = self.elapsed
							if not self.deadline then
								self.deadline = self.elapsed + Shared.GRACE
							end
						end
						self.session:Broadcast("checkpoint", { id = m.id, index = k, ring = ri, done = done, t = self.elapsed, deadline = self.deadline and (self.session.timer.startTime + self.deadline) })
						break
					end
				end
				self.prevPos[m.id] = p
			end
		end
	end
	-- everyone done, or the grace period after the first finisher is over
	local allDone = true
	for _, m in self.session.members do
		if (self.progress[m.id] or 1) <= total then allDone = false end
	end
	if allDone then
		self:Finish("todos en meta")
	elseif self.deadline and self.elapsed >= self.deadline then
		self:Finish("tiempo de gracia")
	end
end

function SkyRingRush.Standings(self: any): { any }
	local rows = {}
	local total = #self.route.checkpoints
	for _, m in self.session.members do
		local k = self.progress[m.id] or 1
		table.insert(rows, {
			id = m.id, finished = k > total, t = self.finishTime[m.id] or math.huge,
			passed = k - 1, dist = if k > total then 0 else self:DistToNext(m.id),
		})
	end
	table.sort(rows, function(a, b)
		if a.finished ~= b.finished then return a.finished end
		if a.finished then return a.t < b.t end
		if a.passed ~= b.passed then return a.passed > b.passed end
		return a.dist < b.dist
	end)
	return rows
end

function SkyRingRush.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local rows = self:Standings()
	local w = rows[1] and self.session.byId[rows[1].id]
	self.resultSummary = {
		title = if w then ("%s GANA"):format(w.name) else "SIN GANADOR",
		detail = ("%s  ·  ruta #%s"):format(why, self.route.name),
	}
end

function SkyRingRush.ControlsLocked(self: any): boolean
	return self.finished
end

function SkyRingRush.BallVisible(self: any): boolean
	return false
end

function SkyRingRush.HandlePlayerJoin(self: any, member: any) end

function SkyRingRush.HandlePlayerLeave(self: any, member: any)
	-- a leaver stays in the standings with the progress they had (the session drops the car)
end

function SkyRingRush.HandlePlayerEliminated(self: any, member: any) end

function SkyRingRush.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function SkyRingRush.GetScore(self: any, member: any): number
	return (self.progress[member.id] or 1) - 1
end

function SkyRingRush.IsFinished(self: any): boolean
	return self.finished
end

function SkyRingRush.GetPlacements(self: any): { any }
	local out = {}
	for i, r in self:Standings() do
		local st = self.score:Member(r.id).stats
		st.dnf = if r.finished then 0 else 1
		table.insert(out, { id = r.id, placement = i, score = r.passed, stats = st })
	end
	return out
end

function SkyRingRush.Cleanup(self: any)
	self.cleanup:Clean()
end

return SkyRingRush
