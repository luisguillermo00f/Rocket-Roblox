--!strict
-- InfectionBotController.lua: an Infection bot on the city's street grid.
--   * infected: chase the nearest healthy car. In plain sight (a clear ray) drive straight at where it will be;
--     otherwise follow the streets one crossing at a time toward it
--   * healthy: run. Pick, among the neighbouring crossings, the one that keeps the most distance from every infected
--     car (and isn't toward the nearest one); a hunter close behind in plain sight -> boost and jink
-- Imperfections: ~0.25 s reaction, commits to a crossing for a moment, sometimes panics toward a bad street.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("InfectionShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU
local ST = Shared.STREETS

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.goal = nil :: Vector3?
	self.goalUntil = 0
	self.jink = 0
	return self
end

local function nearestIndex(v: number): number
	local best, bd = 1, math.huge
	for i, s in ST do
		local d = math.abs(v - s)
		if d < bd then best, bd = i, d end
	end
	return best
end

-- a straight line between two points stays clear of buildings (on the street level). Sampled every 200 uu at car
-- height (a sphere-traced ray gives up after 64 steps over a long street and called everything "clear"), and
-- remembered for a moment: bots think every tick
function Bot.Clear(self: any, a: Vector3, b: Vector3): boolean
	local now = self.t
	local c = self.clearCache
	if c and now - c.t < 0.25 and (c.b - b).Magnitude < 300 then return c.v end
	local arena = Shared.Map():Arena()
	local d = Vector3.new(b.X - a.X, b.Y - a.Y, 0)
	local len = d.Magnitude
	local clear = true
	local n = math.floor(len / 200)
	for i = 1, n do
		local p = Vector3.new(a.X, a.Y, 90) + d * (i / (n + 1))
		if arena.Query(p) < 40 then
			clear = false
			break
		end
	end
	self.clearCache = { t = now, b = b, v = clear }
	return clear
end

function Bot.Cars(self: any): ({ any }, { any })
	local infected, healthy = {}, {}
	for _, m in self.session.members do
		if m.id ~= self.member.id then
			local car = self.session:CarOf(m.id)
			if car and not car.netHidden then
				table.insert(if self.mg.infected[m.id] then infected else healthy, car)
			end
		end
	end
	return infected, healthy
end

-- the crossing next to `p` (grid indices) and its 4 neighbours
function Bot.Neighbours(self: any, p: Vector3): { Vector3 }
	local ix, iy = nearestIndex(p.X), nearestIndex(p.Y)
	local out = {}
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local jx, jy = ix + d[1], iy + d[2]
		if ST[jx] and ST[jy] then table.insert(out, Vector3.new(ST[jx], ST[jy], 17)) end
	end
	return out
end

-- one step along the grid toward `target`: the neighbouring crossing that gets closest to it
function Bot.StepToward(self: any, me: Vector3, target: Vector3): Vector3
	local best, bd = nil, math.huge
	for _, n in self:Neighbours(me) do
		local d = (n - target).Magnitude + (n - me).Magnitude * 0.3
		if d < bd then best, bd = n, d end
	end
	return best or target
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local car = self.car
	local me = car.body.pos * BT
	local infectedCars, healthyCars = self:Cars()
	local amInfected = self.mg.infected[self.member.id] ~= nil
	local c
	if amInfected then
		local prey, pd = nil, math.huge
		for _, h in healthyCars do
			local d = ((h.body.pos * BT) - me).Magnitude
			if d < pd then prey, pd = h, d end
		end
		if not prey then
			return Base.Think(self, dt)
		end
		local pp, pv = prey.body.pos * BT, prey.body.vel * BT
		local aim = pp + pv * math.clamp(pd / 2200, 0, 0.8)
		if self:Clear(me, aim) or pd < 700 then
			c = self:DriveTo(Vector3.new(aim.X, aim.Y, 17), 2400)
			c.boost = math.abs(c.steer) < 0.3
		else
			if not self.goal or self.t > self.goalUntil or (self.goal - me).Magnitude < 450 then
				self.goal = self:StepToward(me, pp)
				self.goalUntil = self.t + 1.6
			end
			c = self:DriveTo(self.goal :: Vector3, 1900)
			c.boost = math.abs(c.steer) < 0.2 and ((self.goal :: Vector3) - me).Magnitude > 1500
		end
	else
		-- nearest hunter
		local hunter, hd = nil, math.huge
		for _, i in infectedCars do
			local d = ((i.body.pos * BT) - me).Magnitude
			if d < hd then hunter, hd = i, d end
		end
		if not self.goal or self.t > self.goalUntil or (self.goal - me).Magnitude < 450 then
			local best, bs = nil, -math.huge
			for _, n in self:Neighbours(me) do
				local s = 0
				local minD = math.huge
				for _, i in infectedCars do
					local ip = i.body.pos * BT
					minD = math.min(minD, (n - ip).Magnitude)
				end
				s = minD
				if hunter then
					local toH = ((hunter.body.pos * BT) - me)
					local toN = n - me
					if toH.Magnitude > 1 and toN.Magnitude > 1 and toH.Unit:Dot(toN.Unit) > 0.5 then s -= 4000 end
				end
				s += self.rng:NextNumber(0, 500)
				if s > bs then best, bs = n, s end
			end
			self.goal = best or Vector3.new(0, 0, 17)
			self.goalUntil = self.t + self.rng:NextNumber(1.0, 2.0)
		end
		c = self:DriveTo(self.goal :: Vector3, 2200)
		c.boost = math.abs(c.steer) < 0.3 and hunter ~= nil and hd < 2500
		if hunter and hd < 900 then
			-- jink away from a hunter right behind
			self.jink -= dt
			if self.jink <= 0 then self.jink = self.rng:NextNumber(0.4, 0.8) end
			c.steer = math.clamp(c.steer + (if self.jink > 0.4 then 0.6 else -0.6), -1, 1)
		end
	end
	return c
end

return Bot
