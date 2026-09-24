--!strict
-- BeachVolley.lua (server): volleyball with the cars. Authoritative rules on the session's own World:
--   * the ball may touch the sand ONCE on a side; a second touch on the same side (before it goes back over the net)
--     is a point for the other team. Crossing the net resets the count.
--   * the ball rolling on the sand (continuous contact) is dead: same as a second bounce.
--   * out: ball lands fully outside the court, or touches a wall / the ceiling. If the ball already bounced in on
--     that side, it's that side's fault; otherwise the last team that touched it loses the point.
--   * the net is a real collider (ball and cars); an invisible wall above it keeps cars on their half.
--   * first to 5, or best score after 60 s; tie -> sudden death (next point wins) until the 80 s cap (draw).
-- The ball is lighter only in this World (MinigamePhysicsOverride) and restored in Cleanup.
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local BallPhysics = require(Phys.BallPhysics)
local ArenaCollision = require(Phys.ArenaCollision)
local Shared = require(RS.Party.MinigameShared:WaitForChild("BeachVolleyShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)
local Override = require(RS.Party:WaitForChild("MinigamePhysicsOverride"))
local BounceTracker = require(Base.BallBounceTracker)

local BT = C.BT_TO_UU

local BeachVolley = {}
BeachVolley.__index = BeachVolley

BeachVolley.Id = Shared.Id
BeachVolley.DisplayName = "BEACH VOLLEY"
BeachVolley.Description = "El balón puede tocar la arena una vez por lado. Segundo bote = punto del rival."
BeachVolley.MinPlayers = 2
BeachVolley.MaxPlayers = 4
BeachVolley.MaxDuration = Shared.MAX_TIME
BeachVolley.SharedModule = "BeachVolleyShared"
BeachVolley.BotController = require(script.Parent.BeachVolleyBotController)

local POINT_PAUSE = 1.8
local STALL_TIME = 3.0

function BeachVolley.new(session: any)
	local self = setmetatable({}, BeachVolley)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.tracker = BounceTracker.new(Shared.BALL_RADIUS)
	self.rng = Random.new()
	self.phase = "idle" -- idle | rally | point
	self.side = 0
	self.bounces = 0
	self.lastTouchTeam = nil :: number?
	self.lastTouchMember = nil :: string?
	self.elapsed = 0
	self.pauseLeft = 0
	self.stall = 0
	self.nextServe = 0
	self.suddenDeath = false
	self.finished = false
	self.winnerTeam = nil :: number?
	self.resultSummary = nil
	return self
end

-- 2 -> 1v1, 3 -> 1 vs 2, 4 -> 2v2. Shuffled; never adds bots.
function BeachVolley.AssignTeams(self: any, members: { any }): { [string]: number }
	local list = table.clone(members)
	for i = #list, 2, -1 do
		local j = self.rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	local out = {}
	local nA = math.floor(#list / 2) -- 3 players: 1 on team A, 2 on team B
	for i, m in list do
		out[m.id] = if i <= nA then 0 else 1
	end
	return out
end

function BeachVolley.PlaceTeams(self: any)
	for team = 0, 1 do
		local ms = self.session:MembersOnTeam(team)
		local slots = Shared.HomeSlots(team, #ms)
		for i, m in ms do
			local car = self.session:CarOf(m.id)
			if car then
				self.session.spawns:Place(car, slots[i].pos, slots[i].yaw, car.boost)
			end
		end
	end
end

function BeachVolley.Setup(self: any)
	-- (the lighter ball is applied when the session builds the world: Shared.SetupWorld, same as on clients)
	for team = 0, 1 do
		local ms = self.session:MembersOnTeam(team)
		local slots = Shared.HomeSlots(team, #ms)
		for i, m in ms do
			local car = self.session.spawns:Spawn(m, team, slots[i].pos, slots[i].yaw)
			car.boost = 100
		end
	end
	-- ball waits above the court until the first serve
	BallPhysics.SetState(self.world.ball, Shared.ServePos(0), Vector3.zero, Vector3.zero)
	self.world.ballEnabled = false
end

function BeachVolley.Serve(self: any, team: number)
	self:PlaceTeams()
	BallPhysics.SetState(self.world.ball, Shared.ServePos(team), Vector3.new(0, 0, -20), Vector3.zero)
	self.world.ballEnabled = true
	self.world.manifolds = {}
	self.side = team
	self.bounces = 0
	self.lastTouchTeam = nil
	self.lastTouchMember = nil
	self.tracker:Reset()
	self.stall = 0
	self.phase = "rally"
	self.session:Broadcast("serve", { team = team })
	self:PushState()
end

function BeachVolley.Start(self: any)
	self:Serve(self.rng:NextInteger(0, 1))
end

function BeachVolley.PublicState(self: any): any
	return {
		scoreA = self.score:TeamGet(0), scoreB = self.score:TeamGet(1), side = self.side, bounces = self.bounces,
		suddenDeath = self.suddenDeath, phase = self.phase,
	}
end

function BeachVolley.PushState(self: any)
	self.session:Broadcast("state", self:PublicState())
end

function BeachVolley.Point(self: any, team: number, reason: string, posUU: Vector3?)
	if self.phase ~= "rally" then return end
	self.score:TeamAdd(team, 1)
	for _, m in self.session:MembersOnTeam(team) do
		self.score:Stat(m.id, "pointsWon", 1)
	end
	self.phase = "point"
	self.pauseLeft = POINT_PAUSE
	self.nextServe = team
	self.world.ballEnabled = false -- ball freezes where the point ended
	self.session:Broadcast("point", {
		team = team, reason = reason, scoreA = self.score:TeamGet(0), scoreB = self.score:TeamGet(1),
		pos = posUU, side = self.side,
	})
	local s = self.score:TeamGet(team)
	if s >= Shared.WIN_POINTS or self.suddenDeath then
		self:Finish(team, if self.suddenDeath then "muerte súbita" else ("primero a %d"):format(Shared.WIN_POINTS))
	end
	self:PushState()
end

function BeachVolley.Finish(self: any, team: number?, why: string)
	if self.finished then return end
	self.finished = true
	self.winnerTeam = team
	self.resultSummary = {
		title = if team == nil then "EMPATE" else (if team == 0 then "EQUIPO A GANA" else "EQUIPO B GANA"),
		detail = ("%d — %d  ·  %s"):format(self.score:TeamGet(0), self.score:TeamGet(1), why),
	}
end

local scratch = {}
local function touchesWallOrCeiling(p: Vector3): boolean
	local n = ArenaCollision.QueryAll(p, Shared.BALL_RADIUS + 6, scratch)
	for i = 1, n do
		if scratch[i].n.Z < 0.7 then
			return true
		end
	end
	return false
end

function BeachVolley.PreTick(self: any, dt: number)
	for _, car in self.world.cars do
		Shared.PreTick(car, dt)
	end
end

function BeachVolley.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt

	-- regulation time / sudden death / hard cap
	if not self.suddenDeath and self.elapsed >= Shared.REGULATION_TIME and self.phase ~= "point" then
		local a, b = self.score:TeamGet(0), self.score:TeamGet(1)
		if a ~= b then
			self:Finish(if a > b then 0 else 1, "tiempo")
			return
		end
		self.suddenDeath = true
		self.session:Broadcast("suddenDeath", {})
		self:PushState()
	end
	if self.elapsed >= Shared.MAX_TIME - 0.05 then
		local a, b = self.score:TeamGet(0), self.score:TeamGet(1)
		self:Finish(if a == b then nil elseif a > b then 0 else 1, "tiempo máximo")
		return
	end

	if self.phase == "point" then
		self.pauseLeft -= dt
		if self.pauseLeft <= 0 then
			self:Serve(self.nextServe)
		end
		return
	end
	if self.phase ~= "rally" then return end

	-- touches (from the authoritative contact events)
	for _, e in self.world.events do
		if e.type == "hit" then
			Shared.VolleyTouch(self.world)
			self.lastTouchTeam = e.car.team
			local m = self.session:MemberOfCar(e.car)
			if m then
				local now = self.elapsed
				if self.lastTouchMember ~= m.id or now - (self.lastTouchAt or -1) > 0.3 then
					self.score:Stat(m.id, "touches", 1)
					local bb = self.world.ball.body
					self.session:Broadcast("touch", { id = m.id, team = m.team, pos = bb.pos * BT, speed = (bb.vel * BT).Magnitude })
				end
				self.lastTouchAt = now
				self.lastTouchMember = m.id
			end
		end
	end

	local bb = self.world.ball.body
	local pos, vel = bb.pos * BT, bb.vel * BT
	-- failsafe: lost / invalid ball -> replay the serve, nobody scores
	if pos ~= pos or math.abs(pos.X) > 4300 or math.abs(pos.Y) > 6200 or pos.Z < -200 or pos.Z > 2300 then
		self:Serve(self.side)
		return
	end

	-- crossing the net resets the bounce count (small hysteresis around y = 0)
	local s = Shared.SideOf(pos.Y)
	if s ~= self.side and math.abs(pos.Y) > 30 then
		self.side = s
		self.bounces = 0
		self:PushState()
	end

	-- walls / ceiling = out
	if touchesWallOrCeiling(pos) then
		local faulty = if self.bounces >= 1 then self.side else (self.lastTouchTeam or self.side)
		self:Point(1 - faulty, "fuera", pos)
		return
	end

	-- sand contacts
	local ev = self.tracker:Update(pos, vel, dt)
	if ev == "enter" then
		if not Shared.InCourt(pos) then
			local faulty = if self.bounces >= 1 then self.side else (self.lastTouchTeam or self.side)
			self:Point(1 - faulty, "fuera", pos)
			return
		end
		self.bounces += 1
		if self.bounces >= 2 then
			self:Point(1 - self.side, "doble bote", pos)
			return
		end
		self.session:Broadcast("bounce", { side = self.side, count = self.bounces, pos = pos })
		self:PushState()
	elseif ev == "dead" then
		self:Point(1 - self.side, "balón muerto", pos)
		return
	end

	-- failsafe: ball stuck (e.g. balanced on the net) -> replay, nobody scores
	if vel.Magnitude < 40 and not self.tracker.touching then
		self.stall += dt
		if self.stall > STALL_TIME then
			self:Serve(self.side)
		end
	else
		self.stall = 0
	end
end

function BeachVolley.ControlsLocked(self: any): boolean
	return self.phase == "point" or self.finished
end

function BeachVolley.BallVisible(self: any): boolean
	return self.phase ~= "idle"
end

function BeachVolley.HandlePlayerJoin(self: any, member: any)
	-- joins as a spectator; plays the next round
end

function BeachVolley.HandlePlayerLeave(self: any, member: any)
	-- a team with nobody left forfeits
	for team = 0, 1 do
		local left = 0
		for _, m in self.session:MembersOnTeam(team) do
			if m.id ~= member.id then left += 1 end
		end
		if left == 0 and member.team == team then
			self:Finish(1 - team, "abandono")
		end
	end
end

function BeachVolley.HandlePlayerEliminated(self: any, member: any)
	-- no eliminations in volley
end

function BeachVolley.End(self: any)
	if not self.finished then
		local a, b = self.score:TeamGet(0), self.score:TeamGet(1)
		self:Finish(if a == b then nil elseif a > b then 0 else 1, "tiempo máximo")
	end
	self.world.ballEnabled = false
end

function BeachVolley.GetScore(self: any, member: any): number
	return self.score:TeamGet(member.team)
end

function BeachVolley.IsFinished(self: any): boolean
	return self.finished
end

-- team result: winners 1st, losers 2nd, draw -> everyone 1st
function BeachVolley.GetPlacements(self: any): { any }
	local out = {}
	for _, m in self.session.members do
		local placement = if self.winnerTeam == nil then 1 elseif m.team == self.winnerTeam then 1 else 2
		table.insert(out, { id = m.id, placement = placement, score = self.score:TeamGet(m.team), stats = self.score:Member(m.id).stats })
	end
	return out
end

function BeachVolley.Cleanup(self: any)
	Override.RestoreBall(self.world)
	self.cleanup:Clean()
end

return BeachVolley
