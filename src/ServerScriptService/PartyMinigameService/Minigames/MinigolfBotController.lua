--!strict
-- MinigolfBotController.lua: a Minigolf bot. Each hole has a line of waypoints (the shape of the fairway) ending at
-- the cup. The bot plays its own ball toward the next waypoint it hasn't passed:
--   * wait for the ball to settle, keeping clear of it
--   * go round to the far side (never through the ball: via a point beside it), line up behind it
--   * drive through it with a speed that grows with the distance still to go
-- Imperfections: aim error of a few degrees, sometimes over- or under-hits.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local CarPhysics = require(RS.Physics.CarPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("MinigolfShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.hole = 0
	self.wp = 1
	self.aimErr = 0
	self.power = 1
	self.lined = false
	return self
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, v.Y, 0)
end

function Bot.Target(self: any, ball: Vector3): Vector3
	local mg = self.mg
	local h = Shared.HOLES[mg.hole]
	local o = Shared.Origin(mg.hole)
	local path = h.path or {}
	while self.wp <= #path and flat(o + path[self.wp] - ball).Magnitude < 800 do
		self.wp += 1
	end
	if self.wp <= #path then return o + path[self.wp], false end
	return Shared.Cup(mg.hole), true
end

function Bot.Think(self: any, dt: number): any
	local mg = self.mg
	local st = mg.p and mg.p[self.member.id]
	if mg.phase ~= "play" or not st or st.holed then
		return CarPhysics.EmptyControls()
	end
	if self.hole ~= mg.hole then
		self.hole = mg.hole
		self.wp = 1
	end
	local car = self.car
	local me = car.body.pos * BT
	local b = mg.balls[self.member.id].ball.body
	local ball = b.pos * BT
	local bv = b.vel * BT
	local target, isCup = self:Target(ball)
	local dir = flat(target - ball)
	local dist = dir.Magnitude
	dir = if dist > 1 then dir / dist else Vector3.new(0, 1, 0)
	-- the ball is still rolling: hang back beside its line
	if bv.Magnitude > 350 then
		self.lined = false
		local side = Vector3.new(-dir.Y, dir.X, 0)
		local wait = ball - dir * 700 + side * (if flat(me - ball):Dot(side) >= 0 then 450 else -450)
		local c = self:DriveTo(Vector3.new(wait.X, wait.Y, me.Z), 500)
		c.throttle = math.clamp(c.throttle, -1, 0.6)
		return c
	end
	-- a fresh shot: a little aim error and power error
	if not self.lined then
		self.aimErr = self.rng:NextNumber(-0.07, 0.07)
		self.power = self.rng:NextNumber(0.85, 1.2)
	end
	local ca, sa = math.cos(self.aimErr), math.sin(self.aimErr)
	local aim = Vector3.new(dir.X * ca - dir.Y * sa, dir.X * sa + dir.Y * ca, 0)
	local behind = ball - aim * 450
	local fromBall = flat(me - ball)
	local c
	if fromBall.Magnitude > 1 and fromBall.Unit:Dot(-aim) < 0.3 then
		-- on the wrong side: go round via the side we're on
		self.lined = false
		local side = Vector3.new(-aim.Y, aim.X, 0)
		local s = if fromBall:Dot(side) >= 0 then 1 else -1
		local around = ball + side * s * 520 - aim * 150
		c = self:DriveTo(Vector3.new(around.X, around.Y, me.Z), 900)
	elseif not self.lined and (flat(me - behind).Magnitude > 160) then
		c = self:DriveTo(Vector3.new(behind.X, behind.Y, me.Z), 450)
		local fwd = flat(car.body.fwd)
		if flat(me - behind).Magnitude < 260 and fwd.Magnitude > 0.1 and fwd.Unit:Dot(aim) > 0.93 then
			self.lined = true
		end
	else
		-- strike: speed for the distance (a putt near the cup, a drive from far away)
		self.lined = true
		local want = math.clamp(dist * (if isCup then 0.42 else 0.6), 550, 2100) * self.power
		c = self:DriveTo(Vector3.new(ball.X, ball.Y, me.Z), want)
		if (car.body.vel * BT).Magnitude > want * 1.05 then c.throttle = -0.3 end
		c.boost = want > 1800 and math.abs(c.steer) < 0.15
	end
	return c
end

return Bot
