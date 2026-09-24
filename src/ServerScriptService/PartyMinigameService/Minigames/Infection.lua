--!strict
-- Infection.lua (server): infection tag.
--   * one random player starts infected, in the middle of the city; everyone else starts at the edges
--   * an infected car touching a healthy one (centres within TOUCH_DIST) infects it; a newly infected car can't pass
--     it on for GRACE seconds
--   * healthy players earn HEALTHY_PER_S every second; infected players earn PER_INFECTION per car they infect;
--     whoever is still healthy at the whistle gets LAST_BONUS
--   * the round ends when everyone is infected, or on time
--   * fairness: patient zero can't infect during the first INCUBATION seconds (everyone gets away); a healthy car that
--     stays on a rooftop longer than ROOF_GRACE stops earning (no hiding where hunters can't reach); the last healthy car
--     is revealed to everyone; boost refills only on the ground (no hovering out of reach)
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("InfectionShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local Infection = {}
Infection.__index = Infection

Infection.Id = Shared.Id
Infection.DisplayName = "PILLA-PILLA INFECCIÓN"
Infection.Description = "Uno empieza infectado y contagia al tocar. Sano sumas cada segundo; infectado, por cada contagio."
Infection.MinPlayers = 2
Infection.MaxPlayers = 4
Infection.MaxDuration = Shared.MAX_TIME
Infection.SharedModule = "InfectionShared"
Infection.BotController = require(script.Parent.InfectionBotController)

function Infection.new(session: any)
	local self = setmetatable({}, Infection)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.rng = Random.new()
	self.elapsed = 0
	self.infected = {} -- member id -> time infected (elapsed)
	self.points = {} -- member id -> points (float for the survival part)
	self.survived = {} -- member id -> seconds healthy
	self.infections = {}
	self.order = {} -- ids in the order they were infected
	self.zero = nil :: string?
	self.roofT = {} -- member id -> seconds on a rooftop
	self.roofWarned = {}
	self.finished = false
	self.resultSummary = nil
	self.lastScores = 0
	return self
end

function Infection.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = i - 1 end
	return out
end

function Infection.Setup(self: any)
	local members = self.session.members
	local zero = members[self.rng:NextInteger(1, #members)]
	self.zero = zero.id
	local spawns = Shared.Map().spawns
	-- the healthy ones spread over the edge spawns, as far apart as the list allows
	local order = {}
	for i = 1, #spawns do order[i] = i end
	for i = #order, 2, -1 do
		local j = self.rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	local k = 0
	for i, m in members do
		self.points[m.id], self.survived[m.id], self.infections[m.id] = 0, 0, 0
		local car
		if m.id == zero.id then
			car = self.session.spawns:Spawn(m, (i - 1) % 2, Shared.Map().data.center, self.rng:NextNumber(-math.pi, math.pi))
		else
			k += 1
			local s = spawns[order[k]]
			car = self.session.spawns:Spawn(m, (i - 1) % 2, s.pos, s.yaw)
		end
		car.boost = 100
	end
	self.world.ballEnabled = false
	self:Infect(zero.id, nil)
	-- incubation: patient zero's "infected at" is set so their grace ends at INCUBATION
	self.infected[zero.id] = Shared.INCUBATION - Shared.GRACE
end

function Infection.Start(self: any) end

function Infection.Infect(self: any, id: string, by: string?)
	if self.infected[id] then return end
	self.infected[id] = self.elapsed
	table.insert(self.order, id)
	local car = self.session:CarOf(id)
	if car then car.infected = true end
	if by then
		self.infections[by] += 1
		self.points[by] += Shared.PER_INFECTION
		self.score:Stat(by, "infections", 1)
	end
	local healthy = self:HealthyIds()
	self.session:Broadcast("infect", {
		id = id, by = by, zero = by == nil, infected = self:InfectedList(), healthy = #healthy,
		pos = car and car.body.pos * BT, points = self:RoundedPoints(),
	})
	if #healthy == 1 and #self.session.members > 2 then
		self.session:Broadcast("last", { id = healthy[1] })
	end
end

function Infection.HealthyIds(self: any): { string }
	local out = {}
	for _, m in self.session.members do
		if not self.infected[m.id] then table.insert(out, m.id) end
	end
	return out
end

function Infection.InfectedList(self: any): { string }
	local out = {}
	for id in self.infected do table.insert(out, id) end
	return out
end

function Infection.RoundedPoints(self: any): { [string]: number }
	local out = {}
	for id, v in self.points do out[id] = math.floor(v) end
	return out
end

function Infection.PublicState(self: any): any
	return { infected = self:InfectedList(), zero = self.zero, points = self:RoundedPoints() }
end

function Infection.PreTick(self: any, dt: number)
	for _, car in self.world.cars do Shared.PreTick(car, dt) end
end

function Infection.ControlsLocked(self: any): boolean
	return self.finished
end

function Infection.BallVisible(self: any): boolean
	return false
end

function Infection.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	-- survival points (not while camping on a rooftop)
	for _, m in self.session.members do
		if not self.infected[m.id] then
			self.survived[m.id] += dt
			local car = self.session:CarOf(m.id)
			local onRoof = car ~= nil and Shared.OnRoof(car.body.pos * BT)
			self.roofT[m.id] = if onRoof then (self.roofT[m.id] or 0) + dt else 0
			local camping = self.roofT[m.id] > Shared.ROOF_GRACE
			if camping ~= (self.roofWarned[m.id] == true) then
				self.roofWarned[m.id] = camping
				self.session:Broadcast("roof", { id = m.id, camping = camping })
			end
			if not camping then
				self.points[m.id] += Shared.HEALTHY_PER_S * dt
			end
		end
	end
	-- touches: an infected car past its grace time against every healthy car
	local members = self.session.members
	for _, a in members do
		local t = self.infected[a.id]
		if t and self.elapsed - t >= Shared.GRACE then
			local ca = self.session:CarOf(a.id)
			if ca and not ca.netHidden then
				local pa = ca.body.pos * BT
				for _, b in members do
					if not self.infected[b.id] then
						local cb = self.session:CarOf(b.id)
						if cb and not cb.netHidden and ((cb.body.pos * BT) - pa).Magnitude < Shared.TOUCH_DIST then
							self:Infect(b.id, a.id)
						end
					end
				end
			end
		end
	end
	if #self:HealthyIds() == 0 then
		self:Finish("todos infectados")
		return
	end
	if self.elapsed - self.lastScores >= 1 then
		self.lastScores = self.elapsed
		self.session:Broadcast("scores", { points = self:RoundedPoints() })
	end
end

function Infection.Standings(self: any): { any }
	local entries = {}
	for _, m in self.session.members do
		table.insert(entries, { id = m.id, keys = { math.floor(self.points[m.id] or 0), math.floor((self.survived[m.id] or 0) * 10) } })
	end
	return Score.Rank(entries)
end

function Infection.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local survivors = self:HealthyIds()
	for _, id in survivors do
		self.points[id] += Shared.LAST_BONUS
		self.score:Stat(id, "survivor", 1)
	end
	-- if everyone got infected, the last one to fall held out longest: the bonus goes to them
	if #survivors == 0 and #self.order > 1 then
		self.points[self.order[#self.order]] += Shared.LAST_BONUS
	end
	for id, v in self.points do self.score:Add(id, math.floor(v)) end
	local st = self:Standings()
	local w = st[1] and self.session.byId[st[1].id]
	self.resultSummary = {
		title = if w then ("%s GANA"):format(w.name) else "SIN GANADOR",
		detail = if #survivors > 0 then ("%d sobreviviente%s  ·  %s"):format(#survivors, if #survivors == 1 then "" else "s", why) else why,
	}
	self.session:Broadcast("scores", { points = self:RoundedPoints() })
end

function Infection.IsFinished(self: any): boolean
	return self.finished
end

function Infection.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function Infection.HandlePlayerJoin(self: any, member: any) end
function Infection.HandlePlayerLeave(self: any, member: any) end
function Infection.HandlePlayerEliminated(self: any, member: any) end

function Infection.GetScore(self: any, member: any): number
	return math.floor(self.points[member.id] or 0)
end

function Infection.GetPlacements(self: any): { any }
	local out = {}
	for _, p in self:Standings() do
		local st = self.score:Member(p.id).stats
		st.survived = math.floor((self.survived[p.id] or 0) * 10) / 10
		table.insert(out, { id = p.id, placement = p.placement, score = math.floor(self.points[p.id] or 0), stats = st })
	end
	return out
end

function Infection.Cleanup(self: any)
	self.cleanup:Clean()
end

return Infection
