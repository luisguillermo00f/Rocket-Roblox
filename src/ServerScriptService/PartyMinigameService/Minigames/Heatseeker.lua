--!strict
-- Heatseeker.lua (server): teams, kickoffs, goals and the score. The homing itself is a per-world rule in the shared
-- module (HeatseekerShared.PostStep), run by the session every tick on the server and by the clients' prediction.
--   * 2 players 1v1, 3 players 2v1, 4 players 2v2 (blue = team 0 defends -y)
--   * first to WIN_GOALS or most goals at the end; a tie at the whistle goes to golden goal (the round's time cap
--     still applies: a draw then shares first place)
--   * after a goal: CELEBRATE seconds with the ball gone and the cars frozen, then everyone back to kickoff
--   * fairness: in a 2v1 the lone player regenerates boost 3x faster ("LOBO SOLITARIO"); a ball that crawls or sits
--     on something for STALL_TIME is re-dropped at the centre (nobody can freeze the game by parking on it); a car that
--     sits or hovers inside its OWN goal for CAMP_TIME is pushed back onto the pitch (no goalkeeping from inside the net);
--     boost refills only on the ground, so nobody hovers in front of a goal forever
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local BallPhysics = require(Phys.BallPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("HeatseekerShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local Heatseeker = {}
Heatseeker.__index = Heatseeker

Heatseeker.Id = Shared.Id
Heatseeker.DisplayName = "HEATSEEKER"
Heatseeker.Description = "Al tocar el balón sale disparado solo hacia la portería rival y acelera en cada toque. ¡Defiende y devuélvelo!"
Heatseeker.MinPlayers = 2
Heatseeker.MaxPlayers = 4
Heatseeker.MaxDuration = Shared.MAX_TIME
Heatseeker.SharedModule = "HeatseekerShared"
Heatseeker.BotController = require(script.Parent.HeatseekerBotController)

function Heatseeker.new(session: any)
	local self = setmetatable({}, Heatseeker)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.goals = { [0] = 0, [1] = 0 }
	self.celebrateUntil = nil :: number?
	self.elapsed = 0
	self.lastTouch = nil :: string?
	self.finished = false
	self.overtime = false
	self.resultSummary = nil
	self.lastHeatSent = nil
	self.stallT = 0
	self.lone = nil :: string?
	self.campT = {} -- member id -> seconds inside their own goal
	return self
end

function Heatseeker.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = (i - 1) % 2 end
	return out
end

function Heatseeker.Kickoff(self: any)
	local w = self.world
	local spots = Shared.Map().data.kickoff[1]
	local counts = { [0] = 0, [1] = 0 }
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		if car then
			local team = m.team or 0
			counts[team] += 1
			local s = spots[math.min(counts[team], #spots)]
			local pos = if team == 0 then s else Vector3.new(-s.X, -s.Y, s.Z)
			local yaw = if team == 0 then math.pi / 2 else -math.pi / 2
			self.session.spawns:Place(car, pos, yaw, 100)
		end
	end
	-- dropped from above (a ball set with zero velocity sleeps in the air until touched, like a Soccar kickoff)
	BallPhysics.SetState(w.ball, Vector3.new(0, 0, 400), Vector3.new(0, 0, -1), Vector3.zero)
	w.ball.heat = nil
	w.ballEnabled = true
	self.stallT = 0
	self.lastTouch = nil
	self.session:Broadcast("heat", { team = nil })
	self.lastHeatSent = nil
end

function Heatseeker.Setup(self: any)
	local counts = { [0] = 0, [1] = 0 }
	for _, m in self.session.members do
		self.session.spawns:Spawn(m, m.team or 0, Vector3.new(0, 0, 17), 0)
		counts[m.team or 0] += 1
	end
	-- 2v1: the single player is the lone wolf
	if counts[0] + counts[1] == 3 then
		local loneTeam = if counts[0] == 1 then 0 else 1
		for _, m in self.session.members do
			if (m.team or 0) == loneTeam then
				self.lone = m.id
				local car = self.session:CarOf(m.id)
				if car then car.loneWolf = true end
			end
		end
	end
	self:Kickoff()
end

-- the ball back at the centre without a goal (stalled)
function Heatseeker.Redrop(self: any)
	local w = self.world
	BallPhysics.SetState(w.ball, Vector3.new(0, 0, 500), Vector3.new(0, 0, -1), Vector3.zero)
	w.ball.heat = nil
	self.stallT = 0
	self.session:Broadcast("redrop", { pos = Vector3.new(0, 0, 500) })
end

function Heatseeker.Start(self: any) end

function Heatseeker.PublicState(self: any): any
	return { goals = { blue = self.goals[0], orange = self.goals[1] }, overtime = self.overtime, lone = self.lone }
end

function Heatseeker.PreTick(self: any, dt: number)
	for _, car in self.world.cars do Shared.PreTick(car, dt) end
end

function Heatseeker.ControlsLocked(self: any): boolean
	return self.finished or self.celebrateUntil ~= nil
end

function Heatseeker.BallVisible(self: any): boolean
	return self.celebrateUntil == nil
end

function Heatseeker.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	local w = self.world
	-- the homing rule (the same function the clients' prediction runs after each of its steps)
	if not self.celebrateUntil then
		Shared.PostStep(w, true)
	end
	-- who touched it last
	for _, e in w.events do
		if e.type == "hit" and e.car then
			local m = self.session:MemberOfCar(e.car)
			if m then
				self.lastTouch = m.id
				self.score:Stat(m.id, "touches", 1)
			end
		end
	end
	local h = w.ball.heat
	local key = if h then (h.team .. ":" .. math.floor(h.speed)) else nil
	if key ~= self.lastHeatSent then
		self.lastHeatSent = key
		self.session:Broadcast("heat", { team = h and h.team, speed = h and h.speed })
	end

	if self.celebrateUntil then
		if self.elapsed >= self.celebrateUntil then
			self.celebrateUntil = nil
			if self.pendingFinish then
				self:Finish(self.pendingFinish)
			else
				self:Kickoff()
			end
		end
		return
	end

	-- no camping inside your own goal
	for _, m in self.session.members do
		local car = self.session:CarOf(m.id)
		if car then
			local p = car.body.pos * BT
			if Shared.InOwnGoal(m.team or 0, p) then
				self.campT[m.id] = (self.campT[m.id] or 0) + dt
				if self.campT[m.id] >= Shared.CAMP_TIME then
					self.campT[m.id] = 0
					local sign = if (m.team or 0) == 0 then 1 else -1
					car.body.vel = Vector3.new(-p.X * 0.4, sign * 1700, 350) / BT
					self.session:Broadcast("camp", { id = m.id })
				end
			else
				self.campT[m.id] = 0
			end
		end
	end

	-- stall watchdog: a ball crawling (or parked on a car / the goal roof) for too long goes back to the centre
	local bv = (w.ball.body.vel * BT).Magnitude
	if bv < 260 then
		self.stallT += dt
		if self.stallT >= Shared.STALL_TIME then
			self:Redrop()
			return
		end
	else
		self.stallT = 0
	end

	local scored = Shared.GoalScored(w.ball.body.pos * BT)
	if scored ~= nil then
		self.goals[scored] += 1
		local scorer = self.lastTouch
		local sm = scorer and self.session.byId[scorer]
		local ownGoal = sm ~= nil and sm.team ~= scored
		if scorer and not ownGoal then
			self.score:Add(scorer, 1)
			self.score:Stat(scorer, "goals", 1)
		end
		local kmh = math.floor((w.ball.body.vel * BT).Magnitude * 0.036 + 0.5)
		self.session:Broadcast("goal", {
			team = scored, scorer = scorer, ownGoal = ownGoal, kmh = kmh, goals = { blue = self.goals[0], orange = self.goals[1] },
			pos = w.ball.body.pos * BT,
		})
		w.ballEnabled = false
		w.ball.heat = nil
		self.celebrateUntil = self.elapsed + Shared.CELEBRATE
		if self.goals[scored] >= Shared.WIN_GOALS or self.overtime then
			self.pendingFinish = if self.overtime then "gol de oro" else ("primero a " .. Shared.WIN_GOALS)
		end
		return
	end

	-- time's up: a tie becomes golden goal (the session's hard cap still ends it)
	if self.elapsed >= Shared.MAX_TIME - 12 and not self.overtime and self.goals[0] == self.goals[1] then
		self.overtime = true
		self.session:Broadcast("overtime", {})
	end
end

function Heatseeker.Standings(self: any): { any }
	local entries = {}
	for _, m in self.session.members do
		local t = m.team or 0
		table.insert(entries, { id = m.id, keys = { self.goals[t] - self.goals[1 - t], self.score:Get(m.id) } })
	end
	return Score.Rank(entries)
end

function Heatseeker.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local a, b = self.goals[0], self.goals[1]
	self.resultSummary = {
		title = if a > b then "GANA AZUL" elseif b > a then "GANA NARANJA" else "EMPATE",
		detail = string.format("AZUL %d — %d NARANJA  ·  %s", a, b, why),
	}
end

function Heatseeker.IsFinished(self: any): boolean
	return self.finished
end

function Heatseeker.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function Heatseeker.HandlePlayerJoin(self: any, member: any) end
function Heatseeker.HandlePlayerLeave(self: any, member: any) end
function Heatseeker.HandlePlayerEliminated(self: any, member: any) end

function Heatseeker.GetScore(self: any, member: any): number
	return self.score:Get(member.id)
end

function Heatseeker.GetPlacements(self: any): { any }
	local out = {}
	for _, p in self:Standings() do
		local st = self.score:Member(p.id).stats
		table.insert(out, { id = p.id, placement = p.placement, score = self.score:Get(p.id), stats = st })
	end
	return out
end

function Heatseeker.Cleanup(self: any)
	self.cleanup:Clean()
end

return Heatseeker
