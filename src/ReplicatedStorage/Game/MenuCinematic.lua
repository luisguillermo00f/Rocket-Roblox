--!strict
-- MenuCinematic.lua: the main menu is a live, never-repeating cinematic around the player's real car.
--
-- The car is simulated by the RocketSim port the whole time. A "beat" only chooses an initial state (a cut hides the
-- teleport) and a scripted set of controls - throttle, boost, jumps, flips, air roll, and a PD air-orientation
-- controller for recoveries. Everything the car does (ramp launch off the wall curve, aerial rotation, flips, ball
-- touches, landings with suspension compression) comes out of the physics.
--
-- Because the simulation is deterministic, every beat is pre-simulated once in a private copy of the world before it
-- plays: that finds the exact tick of the jump / apex / ball touch / landing (the camera is built around them) and
-- rejects variants where the physics doesn't deliver (e.g. a flip that misses the ball). The live run then replays the
-- same inputs from the same state and gets the same result.
--
-- Loop (35-40 s): HERO -> [AERIAL, DETAIL, BALL, WIDE, FREESTYLE+GROUND shuffled] -> HERO REVEAL -> ...
-- Every beat randomises location, heading, speed, manoeuvre and camera side, and every visit to the menu reshuffles.
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Phys = script.Parent.Parent.Physics
local C = require(Phys.PhysicsConstants)
local World = require(Phys.World)
local CarPhysics = require(Phys.CarPhysics)
local BallPhysics = require(Phys.BallPhysics)
local CarConfig = require(Phys.CarConfig)
local Q = require(Phys.Quaternion)
local RenderMap = require(script.Parent.RenderMap)
local CarVisual = require(script.Parent.CarVisual)
local BallVisual = require(script.Parent.BallVisual)
local BoostPadVisuals = require(script.Parent.BoostPadVisuals)
local Effects = require(script.Parent.Effects)
local ArenaCollision = require(Phys.ArenaCollision)
local GS = require(script.Parent.GraphicsSettings)

local MenuCinematic = {}

local BT = C.BT_TO_UU
local TICK = C.TICK_TIME
local UPR = Vector3.yAxis -- Roblox up
local GRAV = 650

-- ------------------------------------------------------------------ helpers
local function clamp(x: number, a: number, b: number): number
	return math.max(a, math.min(b, x))
end
local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end
local function smooth(x: number): number
	x = clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
local function easeOut(x: number): number
	x = clamp(x, 0, 1)
	return 1 - (1 - x) ^ 3
end
local function blank(c: any)
	for k in c do
		if type(c[k]) == "number" then c[k] = 0 else c[k] = false end
	end
end
local function hdir(yaw: number): Vector3
	return Vector3.new(math.cos(yaw), math.sin(yaw), 0)
end
local function flat(v: Vector3): Vector3
	local h = Vector3.new(v.X, v.Y, 0)
	return if h.Magnitude > 1e-3 then h.Unit else Vector3.new(0, 1, 0)
end
-- sim UU -> Roblox studs
local function P(v: Vector3): Vector3
	return RenderMap.Pos(v)
end
local function D(v: Vector3): Vector3
	return RenderMap.Dir(v)
end

-- PD air orientation (signs measured on the physics: pitch+ = nose up, yaw+ = nose toward body.right,
-- roll+ = up toward body.right). dir / up in sim axes; up optional.
local function aim(car: any, dir: Vector3, up: Vector3?, c: any, kp: number?, kd: number?)
	local b = car.body
	local f, r, u, w = b.fwd, b.right, b.up, b.angVel
	local p, d = kp or 3.2, kd or 0.55
	c.pitch = clamp(p * math.atan2(dir:Dot(u), dir:Dot(f)) - d * (-w:Dot(r)), -1, 1)
	c.yaw = clamp(p * math.atan2(dir:Dot(r), dir:Dot(f)) - d * w:Dot(u), -1, 1)
	if up then
		c.roll = clamp(p * math.atan2(up:Dot(r), up:Dot(u)) - d * (-w:Dot(f)), -1, 1)
	end
end

-- ------------------------------------------------------------------ world + state
-- init: { pos (UU), fwd, up?, vel (UU/s), angVel?, ground, ball = { pos, vel } }
local function applyInit(world: any, car: any, init: any)
	local f = init.fwd.Unit
	CarPhysics.ResetState(car, init.pos, math.atan2(f.Y, f.X), 100, init.ground)
	if init.up or not init.ground then
		local u = (init.up or Vector3.zAxis).Unit
		local ff = (f - u * f:Dot(u)).Unit
		if not init.ground and init.fwd.Z ~= 0 then
			-- airborne with a pitched nose: keep the requested forward, rebuild up around it
			ff = f
			local r0 = Vector3.zAxis:Cross(Vector3.new(f.X, f.Y, 0).Unit)
			u = ff:Cross(r0).Unit * -1
			if u.Z < 0 then u = -u end
		end
		local r = u:Cross(ff)
		local q = Q.fromBasis(ff, r, u)
		car.body.rot = q
		car.body.fwd, car.body.right, car.body.up = ff, r, u
	end
	car.body.vel = (init.vel or Vector3.zero) / BT
	car.body.angVel = init.angVel or Vector3.zero
	car.boost = 100
	local b = init.ball
	BallPhysics.SetState(world.ball, b.pos, b.vel or Vector3.zero, Vector3.zero)
end

local function newWorld(config: any): (any, any)
	local w = World.new({ seed = 1, boostPads = false })
	local car = w:AddCar(0, config)
	return w, car
end

-- pre-simulate a beat; returns per-tick records (UU)
local inPlanner: thread? = nil -- set while the background planner coroutine runs

local function presim(config: any, init: any, control: (number, any, any, any, any) -> (), ticks: number): { any }
	local w, car = newWorld(config)
	applyInit(w, car, init)
	local rec = table.create(ticks)
	local mem = {}
	for i = 1, ticks do
		if i % 24 == 0 and inPlanner and coroutine.running() == inPlanner then
			coroutine.yield() -- planning runs in slices across frames
		end
		blank(car.controls)
		control(i * TICK, car.controls, car, w, mem)
		car.boost = 100
		w:Step()
		local hit = false
		for _, e in w.events do
			if e.type == "hit" then hit = true end
		end
		rec[i] = {
			cp = car.body.pos * BT, cv = car.body.vel * BT,
			ground = (car.numWheelsInContact or 0) > 0, bp = w.ball.body.pos * BT, bv = w.ball.body.vel * BT, hit = hit,
			jumped = mem.jumpTick ~= nil,
		}
	end
	return rec
end

local function firstHit(rec: { any }): number?
	for i, r in rec do
		if r.hit then return i end
	end
	return nil
end

-- a resting ball somewhere far from the action (keeps the stadium alive in the background)
local function parkBall(rng: Random, avoid: { Vector3 }): any
	local best, bestD = Vector3.new(0, 0, 93.15), -1
	for _ = 1, 12 do
		local p = Vector3.new(rng:NextNumber(-3200, 3200), rng:NextNumber(-4200, 4200), 93.15)
		local d = math.huge
		for _, a in avoid do d = math.min(d, (Vector3.new(a.X, a.Y, 93.15) - p).Magnitude) end
		if d > bestD then best, bestD = p, d end
	end
	return { pos = best, vel = Vector3.zero }
end

local function inField(p: Vector3, margin: number): boolean
	return math.abs(p.X) < 4096 - margin and math.abs(p.Y) < 5120 - margin
end

-- ------------------------------------------------------------------ beats
-- A beat: plan(rng, config) -> plan table with init, control, dur, camera(u, v, plan) -> (pos, look, fov, roll?),
-- scale(simT, plan) -> time scale, optional prepare(plan, records) validation. v = interpolated render state (studs).
local Beats: { [string]: any } = {}

-- SHOT 1 - HERO: extreme low + close + wide, the car rolls slowly toward the lens
Beats.hero = function(rng: Random)
	local pos = Vector3.new(rng:NextNumber(-1800, 1800), rng:NextNumber(-2600, 2600), 17)
	local yaw = math.atan2(-pos.Y, -pos.X) + rng:NextNumber(-0.7, 0.7)
	local f = hdir(yaw)
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local phase = rng:NextNumber(0, 6)
	return {
		dur = 5.2,
		init = { pos = pos, fwd = f, vel = f * 260, ground = true, ball = parkBall(rng, { pos, pos + f * 1500 }) },
		control = function(t, c)
			c.throttle = 0.26 + 0.05 * math.sin(t * 1.3 + phase)
			c.steer = 0.18 * math.sin(t * 0.8 + phase)
		end,
		camera = function(u, v, p)
			local k = smooth(u / p.dur)
			local fw = D(f)
			local sd = fw:Cross(UPR) * side
			local pos2 = v.car + fw * lerp(9.5, 5.2, k) + sd * lerp(2.6, 1.6, k) + UPR * 0.42
			return pos2, v.car + UPR * 0.75 + fw * 0.6, lerp(74, 60, k), math.rad(side * lerp(3, 6, k))
		end,
		dof = 6,
	}
end

-- SHOT 2 - AERIAL: ramp launch off the wall curve (or a double jump), controlled rotation; camera rips back and up
Beats.aerial = function(rng: Random)
	local variant = if rng:NextNumber() < 0.65 then "wall" else "double"
	local move = ({ "roll", "spin", "flipback" })[rng:NextInteger(1, 3)]
	local rs = if rng:NextNumber() < 0.5 then -1 else 1
	local init, f
	if variant == "wall" then
		local s = if rng:NextNumber() < 0.5 then -1 else 1
		local pos = Vector3.new(s * rng:NextNumber(2000, 2500), rng:NextNumber(-2400, 2400), 17)
		local yaw = (if s > 0 then 0 else math.pi) + rng:NextNumber(-0.5, 0.5)
		f = hdir(yaw)
		init = { pos = pos, fwd = f, vel = f * rng:NextNumber(1250, 1500), ground = true }
	else
		local pos = Vector3.new(rng:NextNumber(-1500, 1500), rng:NextNumber(-2500, 2500), 17)
		f = hdir(math.atan2(-pos.Y, -pos.X) + rng:NextNumber(-0.5, 0.5))
		init = { pos = pos, fwd = f, vel = f * 1100, ground = true }
	end
	init.ball = parkBall(rng, { init.pos, init.pos + f * 1600 })
	local function control(t, c, car, _, mem)
		local ground = (car.numWheelsInContact or 0) > 0
		if not mem.jumpT then
			c.throttle = 1
			c.boost = true
			local launch = if variant == "wall" then ground and car.body.up.Z < 0.72 else t >= 0.35
			if launch then
				mem.jumpT = t
				mem.jumpTick = math.floor(t / TICK + 0.5)
			end
			return
		end
		local j = t - mem.jumpT
		if j < 0.2 then
			c.jump = true
			c.boost = variant == "double"
			return
		end
		if variant == "double" and j >= 0.26 and j < 0.3 then
			c.jump = true -- double jump (no stick on the jump tick)
			return
		end
		if variant == "double" and j < 0.75 then
			c.boost = true
			aim(car, (flat(car.body.fwd) + Vector3.new(0, 0, 1.1)).Unit, Vector3.zAxis, c)
			return
		end
		local m0 = if variant == "double" then 0.75 else 0.3
		if j < m0 + 0.75 then
			if move == "roll" then c.roll = rs
			elseif move == "spin" then c.yaw = rs; c.roll = -rs * 0.5
			else c.pitch = 1; c.roll = rs * 0.3 end
			return
		end
		aim(car, flat(if car.body.vel.Magnitude > 0.5 then car.body.vel else car.body.fwd), Vector3.zAxis, c)
	end
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	return {
		dur = 4.6, init = init, control = control, variant = variant,
		prepare = function(p, rec)
			local jt, apex, az = nil, 1, -1
			for i, r in rec do
				if r.jumped and not jt then jt = i end
				if jt and r.cp.Z > az then apex, az = i, r.cp.Z end
			end
			p.jumpT = (jt or 60) * TICK
			p.apexT = apex * TICK
			p.backDir = D(flat(rec[jt or 60].cv))
			p.side = side
			return jt ~= nil and az > 420
		end,
		camera = function(u, v, p)
			local k = easeOut((u - (p.jumpT - 0.25)) / 1.35)
			local dist = lerp(14, 40, k)
			local h = lerp(2.2, 18, k)
			local bd = if k <= 0 then v.carFwdFlat else p.backDir
			local pos = v.car - bd * dist + bd:Cross(UPR) * (p.side * dist * 0.35) + UPR * h
			return pos, v.car + UPR * 0.4, lerp(56, 80, k), math.rad(-p.side * 4 * k)
		end,
		scale = function(simT, p)
			local d = math.abs(simT - p.apexT)
			return lerp(0.38, 1, smooth((d - 0.15) / 0.45))
		end,
	}
end

-- SHOT 3 - CLOSE DETAIL: wheels / chassis / exhaust, the car accelerates past a very tight lens
Beats.detail = function(rng: Random)
	local pos = Vector3.new(rng:NextNumber(-1800, 1800), rng:NextNumber(-3000, 3000), 17)
	local f = hdir(math.atan2(-pos.Y, -pos.X) + rng:NextNumber(-0.4, 0.4))
	local mode = if rng:NextNumber() < 0.6 then "passby" else "exhaust"
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	return {
		dur = 3.4, mode = mode,
		init = { pos = pos, fwd = f, vel = f * 650, ground = true, ball = parkBall(rng, { pos, pos + f * 2500 }) },
		control = function(t, c)
			c.throttle = 1
			c.boost = t > 0.35
		end,
		prepare = function(p, rec)
			local i = math.floor(1.35 / TICK)
			p.q = P(rec[i].cp)
			p.fw = D(f)
			return inField(rec[#rec].cp, 250)
		end,
		camera = function(u, v, p)
			local sd = p.fw:Cross(UPR) * side
			if p.mode == "passby" then
				local cam = p.q + sd * 5.2 - p.fw * 1.5 + UPR * 0.9
				local k = smooth((u - 1.0) / 1.2)
				return cam, v.car + UPR * 0.15 - v.carFwd * lerp(0, 1.2, k), lerp(30, 52, k), math.rad(side * 2)
			end
			-- exhaust: low rear quarter locked to the car, slowly sliding around the tail
			local a = lerp(-0.5, 0.35, smooth(u / p.dur)) * side
			local back = CFrame.fromAxisAngle(UPR, a) * (-v.carFwdFlat)
			return v.car + back * 5.5 + UPR * 0.55, v.car + UPR * 0.35, lerp(34, 44, smooth(u / p.dur)), 0
		end,
		dof = 3,
	}
end

-- SHOT 4 - BALL CONTROL: nose-pop off a jump, then follow it up with boost
Beats.ball = function(rng: Random)
	local pos = Vector3.new(rng:NextNumber(-1400, 1400), rng:NextNumber(-2800, 1000), 17)
	local f = hdir(math.atan2(2500 - pos.Y, -pos.X) + rng:NextNumber(-0.5, 0.5))
	local dist = rng:NextNumber(950, 1200)
	local jumpAt = dist / 1050 - rng:NextNumber(0.12, 0.3)
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local function control(t, c, car, w, mem)
		local ground = (car.numWheelsInContact or 0) > 0
		if t < jumpAt then
			c.throttle = 1
			return
		end
		if t < jumpAt + 0.18 then
			c.jump = true
			mem.jumpTick = mem.jumpTick or math.floor(t / TICK)
			return
		end
		local to = w.ball.body.pos * BT - car.body.pos * BT
		if ground then
			c.throttle = 1
			return
		end
		aim(car, to.Unit, Vector3.zAxis, c, 2.6, 0.5)
		c.boost = to.Z > 60 and car.body.fwd:Dot(to.Unit) > 0.8
	end
	return {
		dur = 5.0,
		init = { pos = pos, fwd = f, vel = f * 1050, ground = true, ball = { pos = pos + f * dist + Vector3.new(0, 0, 76.15), vel = Vector3.zero } },
		control = control,
		prepare = function(p, rec)
			local h = firstHit(rec)
			if not h or h + 3 > #rec then return false end
			local maxZ = 0
			for i = h, math.min(#rec, h + 180) do maxZ = math.max(maxZ, rec[i].bp.Z) end
			p.hitT = h * TICK
			p.fw = D(f)
			p.side = side
			return maxZ > 330 and rec[h + 3].bv.Magnitude < 2200
		end,
		camera = function(u, v, p)
			local mid = v.car:Lerp(v.ball, 0.5)
			local k = smooth((u - p.hitT + 0.2) / 1.4)
			local sd = p.fw:Cross(UPR) * p.side
			local pos = mid + sd * lerp(30, 38, k) + p.fw * lerp(10, -6, k) + UPR * lerp(3, 12, k)
			return pos, mid + UPR * lerp(0.5, 3, k), lerp(46, 58, k), math.rad(p.side * 2)
		end,
		scale = function(simT, p)
			local d = simT - p.hitT
			if d > -0.18 and d < 0.5 then return 0.28 end
			if d >= 0.5 and d < 0.9 then return lerp(0.28, 1, (d - 0.5) / 0.4) end
			return 1
		end,
		hitEffect = true,
	}
end

-- SHOT 5 - WIDE: huge lens from far behind while the car flies across the stadium
Beats.wide = function(rng: Random)
	-- a big real ballistic arc across the stadium: launch boost with the nose on the trajectory, then coast
	local s = if rng:NextNumber() < 0.5 then -1 else 1
	local sx = if rng:NextNumber() < 0.5 then -1 else 1
	local pos = Vector3.new(-sx * rng:NextNumber(1200, 2200), -s * 3500, 200)
	local f = Vector3.new(sx * rng:NextNumber(0.15, 0.4), s, 0).Unit
	local barrel = rng:NextNumber() < 0.45
	local rs = if rng:NextNumber() < 0.5 then -1 else 1
	local boostT = rng:NextNumber(0.6, 0.8)
	local v0 = f * rng:NextNumber(850, 950) + Vector3.new(0, 0, rng:NextNumber(850, 950))
	return {
		dur = 4.4,
		init = { pos = pos, fwd = v0.Unit, vel = v0, ground = false, ball = parkBall(rng, { pos, pos + f * 6000 }) },
		control = function(t, c, car)
			local vel = car.body.vel
			local dir = if vel.Magnitude > 1e-3 then vel.Unit else car.body.fwd
			c.boost = t < boostT
			if barrel and t > 0.5 then
				aim(car, dir, nil, c)
				c.roll = rs * 0.8
			else
				aim(car, dir, Vector3.zAxis, c)
			end
		end,
		prepare = function(p, rec)
			p.fw = D(f)
			p.side = rs
			for _, r in rec do
				if r.cp.Z > 1850 or not inField(r.cp, 150) then return false end
			end
			return true
		end,
		camera = function(u, v, p)
			local k = smooth(u / p.dur)
			local pos = v.car - p.fw * lerp(30, 42, k) + p.fw:Cross(UPR) * (p.side * 8) + UPR * lerp(5, 11, k)
			return pos, v.car + p.fw * 5 + UPR * 0.8, lerp(80, 86, k), math.rad(p.side * -3)
		end,
		smoothCam = 6,
	}
end

-- SHOT 6 + 7 - FREESTYLE then GROUND: air roll -> flip into the ball -> recovery -> hard landing -> launch
Beats.freestyle = function(rng: Random)
	local pos = Vector3.new(rng:NextNumber(-1400, 1400), rng:NextNumber(-2600, 1200), rng:NextNumber(1050, 1200))
	local f = hdir(math.atan2(-pos.Y, -pos.X) + rng:NextNumber(-0.6, 0.6))
	local rs = if rng:NextNumber() < 0.5 then -1 else 1
	local flipYaw = ({ 0, 0.55, -0.55 })[rng:NextInteger(1, 3)]
	local rollEnd = rng:NextNumber(0.7, 0.9)
	local flipT = rollEnd + 0.42
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local function control(t, c, car, _, mem)
		local ground = (car.numWheelsInContact or 0) > 0
		if ground or mem.landT then
			mem.landT = mem.landT or t
			c.throttle = 1
			c.boost = t - mem.landT > 0.12
			return
		end
		if t < rollEnd then
			c.roll = rs
		elseif t < flipT then
			aim(car, flat(car.body.vel), Vector3.zAxis, c, 3.6, 0.6)
		elseif t < flipT + 0.05 then
			c.jump = true
			c.pitch = -1
			c.yaw = flipYaw
		elseif t < flipT + 0.75 then
			c.pitch = -1
			c.yaw = flipYaw
		else
			aim(car, flat(car.body.vel), Vector3.zAxis, c, 3.4, 0.6)
		end
	end
	local init = { pos = pos, fwd = f, vel = f * 780 + Vector3.new(0, 0, 250), ground = false, ball = { pos = Vector3.new(3500, 4500, 93.15), vel = Vector3.zero } }
	return {
		dur = 6.4, init = init, control = control,
		-- the ball is dropped so it meets the nose right after the flip starts; tried at several offsets
		solve = function(p, config)
			local ticks = math.floor(p.dur / TICK)
			local dry = presim(config, init, control, math.floor((flipT + 0.5) / TICK))
			for _, th in { 0.3, 0.24, 0.36 } do
				for _, off in { 150, 115, 185 } do
					local i = math.floor((flipT + th) / TICK)
					local r = dry[i]
					local target = r.cp + flat(r.cv) * off
					local tt = i * TICK
					-- released with a tiny push: a ball set at exact rest would sleep instead of falling
					local v0 = -20
					init.ball = { pos = target + Vector3.new(0, 0, 0.5 * GRAV * tt * tt - v0 * tt), vel = Vector3.new(0, 0, v0) }
					if init.ball.pos.Z < 1900 then
						-- cheap check up to just after the touch; the full run only for the winner
						local probe = presim(config, init, control, math.floor((tt + 0.3) / TICK))
						local h = firstHit(probe)
						if h and math.abs(h * TICK - tt) < 0.25 then
							return presim(config, init, control, ticks)
						end
					end
				end
			end
			return nil
		end,
		prepare = function(p, rec)
			local h = firstHit(rec)
			local land
			for i, r in rec do
				if r.ground then land = i break end
			end
			if not h or not land or land * TICK > p.dur - 1.3 then return false end
			p.hitT = h * TICK
			p.landT = land * TICK
			p.landP = P(rec[land].cp)
			p.landDir = D(flat(rec[land].cv))
			p.side = side
			p.fw = D(f)
			return inField(rec[#rec].cp, 200)
		end,
		camera = function(u, v, p)
			if u < p.landT - 0.42 then
				-- SHOT 6: orbiting chase, sweeping from rear quarter to the side
				local a = lerp(-0.9, 0.45, smooth(u / (p.landT - 0.42))) * p.side
				local back = CFrame.fromAxisAngle(UPR, a) * (-p.fw)
				return v.car + back * 24 + UPR * 3, v.car:Lerp(v.ball, 0.25), 58, math.rad(p.side * 3)
			end
			-- SHOT 7: lens on the grass beside the landing spot, then it widens as the car launches
			local sd = p.landDir:Cross(UPR) * p.side
			local cam = p.landP + sd * 11 - p.landDir * 3 + UPR * 0.8
			local k = smooth((u - p.landT - 0.25) / 1.1)
			return cam, v.car + UPR * 0.3, lerp(38, 72, k), 0
		end,
		scale = function(simT, p)
			local d = simT - p.hitT
			if d > -0.3 and d < 0.35 then return 0.3 end
			if d >= 0.35 and d < 0.7 then return lerp(0.3, 1, (d - 0.35) / 0.35) end
			local l = simT - p.landT
			if l > -0.15 and l < 0.25 then return 0.45 end
			return 1
		end,
		hitEffect = true,
		landShake = true,
	}
end

-- SHOT 8 - HERO REVEAL: stationary car, low orbit, the player's name appears
Beats.reveal = function(rng: Random)
	local spots = { Vector3.new(0, 0, 17), Vector3.new(0, -3800, 17), Vector3.new(0, 3800, 17), Vector3.new(-2400, -2000, 17), Vector3.new(2400, 2000, 17) }
	local pos = spots[rng:NextInteger(1, #spots)] + Vector3.new(rng:NextNumber(-300, 300), rng:NextNumber(-300, 300), 0)
	local f = hdir(rng:NextNumber(0, math.pi * 2))
	local dir = if rng:NextNumber() < 0.5 then -1 else 1
	local a0 = rng:NextNumber(0, math.pi * 2)
	local ballP = pos + f * 420 + f:Cross(Vector3.zAxis) * rng:NextNumber(-200, 200)
	ballP = Vector3.new(clamp(ballP.X, -3800, 3800), clamp(ballP.Y, -4800, 4800), 93.15)
	return {
		dur = 7.5, reveal = true,
		init = { pos = pos, fwd = f, vel = Vector3.zero, ground = true, ball = { pos = ballP, vel = Vector3.zero } },
		control = function(t, c)
			c.handbrake = true
		end,
		camera = function(u, v, p)
			local a = a0 + dir * u * 0.3
			local k = smooth(u / p.dur)
			local r = lerp(17, 14, k)
			local pos2 = v.car + Vector3.new(math.cos(a) * r, lerp(1.1, 2.2, k), math.sin(a) * r)
			return pos2, v.car + UPR * 1.0, lerp(46, 40, k), 0
		end,
		dof = 14,
	}
end

-- ------------------------------------------------------------------ director
local st: any = nil

local function orderFor(rng: Random): { string }
	if not GS.Get("menuFull") then
		return { "reveal" } -- simple menu: only the slow orbit around the car (cheapest)
	end
	local mid = { "aerial", "detail", "ball", "wide", "freestyle" }
	for i = #mid, 2, -1 do
		local j = rng:NextInteger(1, i)
		mid[i], mid[j] = mid[j], mid[i]
	end
	local out = { "hero" }
	for _, b in mid do table.insert(out, b) end
	table.insert(out, "reveal")
	return out
end

local function planBeat(s: any, name: string): any
	for _ = 1, 6 do
		local p = Beats[name](s.rng)
		p.name = name
		local ticks = math.floor(p.dur / TICK)
		local rec
		if p.solve then
			rec = p.solve(p, s.config)
		else
			rec = presim(s.config, p.init, p.control, ticks)
		end
		if rec and (not p.prepare or p.prepare(p, rec)) then
			return p
		end
	end
	return nil
end

-- background planner for the beat after the current one
local function spawnPlanner()
	local s0 = st
	if s0.index + 1 > #s0.order then
		for _, n in orderFor(s0.rng) do table.insert(s0.order, n) end
	end
	s0.nextPlan = nil
	s0.planner = coroutine.create(function()
		local i = s0.index + 1
		for _ = 1, 3 do
			local p = planBeat(s0, s0.order[i])
			if p then
				s0.nextPlan = p
				s0.nextIndex = i
				return
			end
			i += 1 -- the physics didn't deliver this beat: skip it
			if i > #s0.order then
				for _, n in orderFor(s0.rng) do table.insert(s0.order, n) end
			end
		end
	end)
end

local function runPlanner(budget: number?)
	local co = st.planner
	if not co or coroutine.status(co) == "dead" then return end
	local t0 = os.clock()
	repeat
		inPlanner = co
		local ok, err = coroutine.resume(co)
		inPlanner = nil
		if not ok then
			warn("[MenuCinematic] planner:", err)
			break
		end
	until coroutine.status(co) == "dead" or (budget and os.clock() - t0 > budget)
end

local function startBeat(p: any)
	st.beat = p
	if st.visual then st.visual:Destroy() end
	st.world, st.car = newWorld(st.config)
	applyInit(st.world, st.car, p.init)
	st.visual = CarVisual.new(st.car, st.folder, st.skin)
	st.visual:SetAudio(false)
	st.mem = {}
	st.tick = 0
	st.acc = 0
	st.u = 0
	st.prevC = { p = st.car.body.pos * BT, q = st.car.body.rot }
	st.curC = st.prevC
	st.prevB = st.world.ball.body.pos * BT
	st.curB = st.prevB
	st.camSmooth = nil
	st.landed = false
	-- cut: short blur pulse
	st.blur.Size = 12
	TweenService:Create(st.blur, TweenInfo.new(0.22), { Size = 0 }):Play()
	if st.onReveal then st.onReveal(p.reveal == true) end
	spawnPlanner()
end

local function nextBeat()
	runPlanner(nil) -- finish planning now if it isn't done (normally it finished long ago)
	local p = st.nextPlan
	if p then
		st.index = st.nextIndex
	else
		p = planBeat(st, "hero")
		st.index += 1
	end
	startBeat(p)
end

-- cfg: { hitbox, skin } ; onReveal(on) is called when the hero reveal starts/ends
function MenuCinematic.Start(cfg: { [string]: any }, onReveal: ((boolean) -> ())?)
	MenuCinematic.Stop()
	local folder = Instance.new("Folder")
	folder.Name = "MenuCinematic"
	folder.Parent = workspace
	local padWorld = World.new({ seed = 1 })
	st = {
		rng = Random.new(math.floor(os.clock() * 1e6) % 2147483647),
		config = CarConfig[cfg.hitbox] or CarConfig.Octane,
		skin = cfg.skin or "Octane",
		folder = folder,
		onReveal = onReveal,
		ball = BallVisual.new(folder),
		pads = BoostPadVisuals.new(padWorld.pads, folder),
		clock = 0,
		shake = 0,
	}
	st.blur = Instance.new("BlurEffect"); st.blur.Name = "MenuBlur"; st.blur.Size = 0; st.blur.Parent = Lighting
	st.dof = Instance.new("DepthOfFieldEffect"); st.dof.Name = "MenuDOF"; st.dof.FarIntensity = 0.35; st.dof.NearIntensity = 0; st.dof.InFocusRadius = 10; st.dof.Parent = Lighting
	st.grade = Instance.new("ColorCorrectionEffect"); st.grade.Name = "MenuGrade"; st.grade.Contrast = 0.1; st.grade.Saturation = 0.1; st.grade.Parent = Lighting
	st.order = orderFor(st.rng)
	st.index = 1
	startBeat(planBeat(st, "hero"))
end

function MenuCinematic.Stop()
	if not st then return end
	local s = st
	st = nil
	if s.visual then s.visual:Destroy() end
	s.folder:Destroy()
	s.blur:Destroy()
	s.dof:Destroy()
	s.grade:Destroy()
	if s.onReveal then s.onReveal(false) end
end

function MenuCinematic.IsRunning(): boolean
	return st ~= nil
end

-- garage / settings changed: swap the skin in place, or restart the beat for a new hitbox
function MenuCinematic.SetCar(cfg: { [string]: any })
	if not st then return end
	st.skin = cfg.skin or st.skin
	local newConfig = CarConfig[cfg.hitbox] or st.config
	if newConfig ~= st.config then
		st.config = newConfig
		st.order = orderFor(st.rng)
		st.index = 1
		startBeat(planBeat(st, "hero"))
		return
	end
	if st.visual then st.visual:Destroy() end
	st.visual = CarVisual.new(st.car, st.folder, st.skin)
	st.visual:SetAudio(false)
end

function MenuCinematic.Update(dt: number)
	if not st then return end
	local p = st.beat
	dt = math.min(dt, 0.1)
	local simT = st.tick * TICK
	local scale = if p.scale then p.scale(simT, p) else 1
	st.acc += dt * scale
	local maxTicks = math.floor(p.dur / TICK)
	while st.acc >= TICK and st.tick < maxTicks do
		st.acc -= TICK
		st.tick += 1
		st.prevC = st.curC
		st.prevB = st.curB
		blank(st.car.controls)
		p.control(st.tick * TICK, st.car.controls, st.car, st.world, st.mem)
		st.car.boost = 100
		st.world:Step()
		for _, e in st.world.events do
			if e.type == "hit" and p.hitEffect then
				local bp = st.world.ball.body.pos
				local cp = CarPhysics.GetHitboxCenter(st.car)
				Effects.Hit(P((bp + (cp - bp).Unit * st.world.ball.radius) * BT), 0.8)
				st.shake = math.max(st.shake, 0.6)
			end
		end
		local ground = (st.car.numWheelsInContact or 0) > 0
		if p.landShake and ground and not st.landed and st.tick > 20 then
			st.landed = true
			st.shake = math.max(st.shake, 1.0)
		end
		st.curC = { p = st.car.body.pos * BT, q = st.car.body.rot }
		st.curB = st.world.ball.body.pos * BT
	end
	local alpha = clamp(st.acc / TICK, 0, 1)
	st.u += dt

	-- render the real simulated state
	local cp = st.prevC.p:Lerp(st.curC.p, alpha)
	local cq = Q.slerp(st.prevC.q, st.curC.q, alpha)
	local carCF = RenderMap.CFrame(cp, cq)
	st.visual:Update(carCF, true)
	local bp = st.prevB:Lerp(st.curB, alpha)
	st.ball:Update(RenderMap.CFrame(bp, st.world.ball.body.rot), true)
	st.ball:SetSpeed(st.world.ball.body.vel.Magnitude * BT)
	st.clock += dt
	st.pads:Update(st.clock)

	local fwd = D(st.car.body.fwd)
	local ff = Vector3.new(fwd.X, 0, fwd.Z)
	local v = {
		car = carCF.Position, carFwd = fwd, carFwdFlat = if ff.Magnitude > 1e-3 then ff.Unit else Vector3.zAxis,
		ball = P(bp),
	}
	local pos, look, fov, roll = p.camera(st.u, v, p)
	if p.smoothCam then
		st.camSmooth = if st.camSmooth then st.camSmooth:Lerp(pos, 1 - math.exp(-p.smoothCam * dt)) else pos
		pos = st.camSmooth
	end
	-- keep the lens inside the arena (never behind the stands / inside a goal wall) and off the floor
	local simP = Vector3.new(pos.X, pos.Z, pos.Y) / C.STUDS_PER_UU
	for _ = 1, 3 do
		local d, nrm = ArenaCollision.Query(simP)
		if d >= 40 then break end
		simP += nrm * (40 - d)
	end
	pos = Vector3.new(simP.X, simP.Z, simP.Y) * C.STUDS_PER_UU
	if pos.Y < 0.25 then pos = Vector3.new(pos.X, 0.25, pos.Z) end
	local cf = CFrame.lookAt(pos, look)
	if roll then cf *= CFrame.Angles(0, 0, roll) end
	-- handheld drift + impact shake
	local t = st.clock
	st.shake = math.max(0, st.shake - dt * 2.2)
	local hh = 0.004 + 0.02 * st.shake
	cf *= CFrame.Angles(math.noise(t * 0.6, 1) * hh, math.noise(t * 0.6, 2) * hh, math.noise(t * 0.5, 3) * hh * 0.5)
	if st.shake > 0.01 then
		cf *= CFrame.new(math.noise(t * 25, 4) * 0.25 * st.shake, math.noise(t * 25, 5) * 0.25 * st.shake, 0)
	end
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cf
	cam.FieldOfView = fov
	-- depth of field on the close shots only
	if p.dof and GS.Get("dof") then
		st.dof.Enabled = true
		st.dof.FocusDistance = (pos - v.car).Magnitude
		st.dof.InFocusRadius = p.dof
	else
		st.dof.Enabled = false
	end

	runPlanner(0.004)
	if st.tick >= maxTicks then
		nextBeat()
	end
end

-- dev: plan every beat type n times headless and report success + planning cost
function MenuCinematic._Benchmark(n: number, only: string?, seed: number?): string
	local out = {}
	local saved = st
	st = { rng = Random.new(seed or 42), config = CarConfig.Octane }
	for name in Beats do
		if only and name ~= only then continue end
		local ok, t0 = 0, os.clock()
		for _ = 1, n do
			if planBeat(st, name) then ok += 1 end
		end
		table.insert(out, string.format("%-10s %d/%d  %.0f ms/plan", name, ok, n, (os.clock() - t0) / n * 1000))
	end
	st = saved
	return table.concat(out, "\n")
end

return MenuCinematic
