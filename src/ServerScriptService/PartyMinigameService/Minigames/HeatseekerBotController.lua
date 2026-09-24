--!strict
-- HeatseekerBotController.lua: a Heatseeker bot. The ball homes in on a goal after every touch, so the game is about
-- getting in its way and hitting it back:
--   * ball heading for MY goal: get onto its path between it and the goal and meet it (a touch sends it back);
--   * otherwise attack: come round behind the ball (relative to the rival goal) and drive through it;
--   * with a team-mate, the one closer to the ball attacks and the other covers the goal.
-- Imperfections: ~0.2 s reaction, jumps late, sometimes overcommits.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("HeatseekerShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.reaction = self.rng:NextNumber(0.12, 0.28)
	self.hist = {}
	self.jumpHold = 0
	return self
end

-- the ball as seen `reaction` seconds ago, extrapolated to now
function Bot.SeeBall(self: any): (Vector3, Vector3)
	local b = self.session.world.ball.body
	table.insert(self.hist, { t = self.t, p = b.pos * BT, v = b.vel * BT })
	while #self.hist > 2 and self.hist[2].t <= self.t - self.reaction do table.remove(self.hist, 1) end
	local o = self.hist[1]
	return o.p + o.v * self.reaction, o.v
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local w = self.session.world
	local car = self.car
	local me = car.body.pos * BT
	if not w.ballEnabled then
		return self:DriveTo(Vector3.new(0, if self.member.team == 0 then -2600 else 2600, 17), 600)
	end
	local ball, bv = self:SeeBall()
	local team = self.member.team or 0
	local myGoal = Shared.TargetFor(1 - team) -- the goal the OTHER team shoots at = mine
	local theirGoal = Shared.TargetFor(team)
	local heat = w.ball.heat
	local threatened = heat ~= nil and heat.team ~= team

	-- team role: the mate nearer the ball attacks
	local attacker = true
	for _, m in self.session.members do
		if m.id ~= self.member.id and (m.team or 0) == team then
			local other = self.session:CarOf(m.id)
			if other and ((other.body.pos * BT) - ball).Magnitude < (me - ball).Magnitude - 150 then
				attacker = false
			end
		end
	end

	local c
	local toBall = ball - me
	local flatDist = Vector2.new(toBall.X, toBall.Y).Magnitude
	if threatened or not attacker then
		-- defend: stand on the ball's path to my goal, closer to the ball when it's far from goal
		local path = myGoal - ball
		local along = math.clamp(path.Magnitude * 0.35, 300, 1600)
		local guard = ball + path.Unit * along
		if threatened and flatDist < 900 then
			-- it's coming: meet it head on
			c = self:DriveTo(Vector3.new(ball.X, ball.Y, 17), 2300)
			c.boost = true
		else
			c = self:DriveTo(Vector3.new(guard.X, guard.Y, 17), if threatened then 2200 else 900)
			c.boost = threatened and math.abs(c.steer) < 0.3
		end
	else
		-- attack: approach from behind the ball, then drive through it
		local shotDir = Vector3.new(theirGoal.X - ball.X, theirGoal.Y - ball.Y, 0)
		shotDir = if shotDir.Magnitude > 1 then shotDir.Unit else Vector3.new(0, if team == 0 then 1 else -1, 0)
		local behind = ball - shotDir * 450
		local fromBehind = Vector3.new(me.X - ball.X, me.Y - ball.Y, 0)
		local aligned = fromBehind.Magnitude > 1 and fromBehind.Unit:Dot(-shotDir) > 0.6
		if aligned or flatDist < 350 then
			c = self:DriveTo(Vector3.new(ball.X, ball.Y, 17), 2300)
			c.boost = math.abs(c.steer) < 0.25
		else
			c = self:DriveTo(Vector3.new(behind.X, behind.Y, 17), 1700)
			c.boost = flatDist > 1500 and math.abs(c.steer) < 0.3
		end
	end
	-- jump for a ball in the air nearby
	if self.jumpHold > 0 then
		self.jumpHold -= dt
		c.jump = true
	elseif flatDist < 420 and ball.Z > 230 and ball.Z < 600 and (car.numWheelsInContact or 0) > 0 then
		self.jumpHold = 0.18
		c.jump = true
	end
	return c
end

return Bot
