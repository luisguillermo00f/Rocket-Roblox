--!strict
-- World.lua: port of RocketSim Arena::Step for Soccar.
-- Tick order (identical to RocketSim):
--   1. every car: Car::_PreTickUpdate (wheel rays, tire impulses, suspension, jump/flip/air/boost forces)
--   2. boost pads: pre-tick cooldowns
--   3. Bullet step: gravity -> damping -> collision detection (+ contact callbacks: ball hit extra impulse,
--      bumps/demos, car-world contact) -> sequential impulse solve -> integrate transforms
--   4. every car: _PostTickUpdate (supersonic, cooldowns), _FinishPhysicsTick (velocity cache, speed caps),
--      boost pad pickup test
--   5. boost pads post-tick, ball _FinishPhysicsTick (extra hit impulse, caps), goal test
local C = require(script.Parent.PhysicsConstants)
local Curve = require(script.Parent.LinearPieceCurve)
local RigidBody = require(script.Parent.RigidBody)
local Q = require(script.Parent.Quaternion)
local Solver = require(script.Parent.ContactSolver)
local Collision = require(script.Parent.Collision)
local CarPhysics = require(script.Parent.CarPhysics)
local BallPhysics = require(script.Parent.BallPhysics)
local Manifold = require(script.Parent.Manifold)
local CarConfig = require(script.Parent.CarConfig)

local UU, BT = C.UU_TO_BT, C.BT_TO_UU

local World = {}
World.__index = World

export type Options = {
	ballOnly: boolean?,
	boostPads: boolean?,
	seed: number?,
	-- Per-world extras for minigames (never global). Each solid: { c = centre UU, h = half extents UU,
	-- ball = collides with the ball, car = collides with cars }. Absent = standard Soccar arena only.
	extraSolids: { any }?,
	-- A whole custom map (CustomArena) instead of the Soccar arena: minigames on their own maps. No goal events.
	arena: any?,
	-- false: cars go through each other (no bumps, no demos) - e.g. minigolf, where everyone plays the same hole
	carCarCollision: boolean?,
}

function World.new(opts: Options?)
	local o = opts or {}
	local self = setmetatable({
		tickTime = C.TICK_TIME,
		tickCount = 0,
		ball = BallPhysics.new(),
		cars = {},
		lastCarId = 0,
		pads = {},
		rng = Random.new(o.seed or 0),
		demoMode = "normal", -- "normal" | "on_contact" | "disabled"
		enableTeamDemos = false,
		ballEnabled = true,
		manifolds = {}, -- persistent contact manifolds by pair key -- false while the ball is removed after a goal
		events = {}, -- per-tick event list: { type = "goal"|"bump"|"demo"|"hit", ... }
		onEvent = nil :: ((any) -> ())?,
		-- per-world overrides (minigames). nil / 1 = RocketSim defaults.
		extraSolids = o.extraSolids,
		ballGravityScale = 1,
		arena = o.arena, -- nil = the Soccar arena (ArenaCollision)
		carCarCollision = o.carCarCollision ~= false,
		ballOwner = nil :: any?, -- a car: only that car touches world.ball (nil = everyone)
		extraBalls = {} :: { any }, -- more balls, each { ball, owner (car or nil), enabled }
		onRespawn = nil :: ((any) -> ())?, -- custom maps place respawning cars themselves
		demoFilter = nil :: ((any, any) -> boolean)?, -- (bumper, victim) -> may this be a demolition
	}, World)
	if o.boostPads ~= false then
		for i, p in C.BOOSTPAD_LOCS_BIG do
			table.insert(self.pads, { pos = p, isBig = true, cooldown = 0, isActive = true, prevLockedCarId = 0, curLockedCar = nil, index = i })
		end
		for i, p in C.BOOSTPAD_LOCS_SMALL do
			table.insert(self.pads, { pos = p, isBig = false, cooldown = 0, isActive = true, prevLockedCarId = 0, curLockedCar = nil, index = #C.BOOSTPAD_LOCS_BIG + i })
		end
	end
	return self
end

function World.AddCar(self: any, team: number, config: any?)
	self.lastCarId += 1
	local car = CarPhysics.new(config or CarConfig.Octane, team, self.lastCarId)
	table.insert(self.cars, car)
	World.RespawnCar(self, car)
	return car
end

function World.RemoveCar(self: any, car: any)
	local i = table.find(self.cars, car)
	if i then
		table.remove(self.cars, i)
	end
end

-- more balls (own-ball minigames): only `owner` touches it (nil = every car). Returns the BallPhysics.
function World.AddBall(self: any, owner: any?): any
	local b = BallPhysics.new()
	table.insert(self.extraBalls, { ball = b, owner = owner, enabled = true })
	return b
end

-- Car::Respawn
function World.RespawnCar(self: any, car: any)
	for key in self.manifolds do
		if string.find(key, "^[bw]" .. car.id .. "[:]?") or string.find(key, "^x%d+:" .. car.id .. "$") then
			self.manifolds[key] = nil
		end
	end
	if self.onRespawn then
		self.onRespawn(car)
		return
	end
	local loc = C.CAR_RESPAWN_LOCATIONS[self.rng:NextInteger(1, #C.CAR_RESPAWN_LOCATIONS)]
	local sy = if car.team == 0 then 1 else -1
	local yaw = loc.yaw + (if car.team == 0 then 0 else math.pi)
	CarPhysics.ResetState(car, Vector3.new(loc.x, loc.y * sy, C.CAR_RESPAWN_Z), yaw, C.BOOST_SPAWN_AMOUNT, true)
end

-- Arena::ResetToRandomKickoff
function World.ResetToKickoff(self: any, seed: number?)
	local rng = if seed then Random.new(seed) else self.rng
	local order = { 1, 2, 3, 4, 5 }
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	local blue, orange = {}, {}
	for _, car in self.cars do
		table.insert(if car.team == 0 then blue else orange, car)
	end
	local numAtRespawn = { 0, 0, 0, 0 }
	for i = 1, math.max(#blue, #orange) do
		local spawn
		if i <= 5 then
			local s = C.CAR_SPAWN_LOCATIONS[order[i]]
			spawn = { x = s.x, y = s.y, yaw = s.yaw }
		else
			local idx = ((i - 6) % 4) + 1
			local s = C.CAR_RESPAWN_LOCATIONS[idx]
			spawn = { x = s.x, y = s.y + 250 * numAtRespawn[idx], yaw = s.yaw }
			numAtRespawn[idx] += 1
		end
		for team = 0, 1 do
			local list = if team == 0 then blue else orange
			local car = list[i]
			if car then
				local pos = Vector3.new(spawn.x, spawn.y, C.CAR_SPAWN_REST_Z)
				local yaw = spawn.yaw
				if team == 1 then
					pos = Vector3.new(-pos.X, -pos.Y, pos.Z)
					yaw += math.pi
				end
				CarPhysics.ResetState(car, pos, yaw, C.BOOST_SPAWN_AMOUNT, true)
			end
		end
	end
	BallPhysics.SetState(self.ball, Vector3.new(0, 0, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
	self.manifolds = {}
	for _, pad in self.pads do
		pad.cooldown = 0
		pad.isActive = true
		pad.prevLockedCarId = 0
	end
end

local function emit(self: any, ev: any)
	table.insert(self.events, ev)
	if self.onEvent then
		self.onEvent(ev)
	end
end

-- Arena::_BtCallback_OnCarCarCollision
local function carCarCallback(self: any, car1: any, car2: any, contact: any)
	for i = 1, 2 do
		local swapped = i == 2
		local c1, c2 = car1, car2
		if swapped then
			c1, c2 = car2, car1
		end
		if c1.isDemoed or c2.isDemoed then
			return
		end
		if c1.carContact.otherCarID == c2.id and c1.carContact.cooldownTimer > 0 then
			continue
		end
		local vel = c1.body.vel * BT
		local otherVel = c2.body.vel * BT
		local deltaPos = (c2.body.pos - c1.body.pos) * BT
		if vel:Dot(deltaPos) > 0 then
			local velDir = vel.Unit
			local dirToOtherCar = deltaPos.Unit
			local speedTowardsOtherCar = vel:Dot(dirToOtherCar)
			local otherCarAwaySpeed = otherVel:Dot(velDir)
			if speedTowardsOtherCar > otherCarAwaySpeed then
				-- local contact point on car1 (m_localPointA)
				local worldPoint = if swapped then contact.pointB else contact.pointA
				local localX = (worldPoint - c1.body.pos):Dot(c1.body.fwd) * BT
				if localX > C.BUMP_MIN_FORWARD_DIST then
					local isDemo
					if self.demoMode == "on_contact" then
						isDemo = true
					elseif self.demoMode == "disabled" then
						isDemo = false
					else
						isDemo = c1.isSupersonic
					end
					if isDemo and not self.enableTeamDemos then
						isDemo = c1.team ~= c2.team
					end
					-- per-world rule (minigames, e.g. a spawn shield); nil = RocketSim
					if isDemo and self.demoFilter and not self.demoFilter(c1, c2) then
						isDemo = false
					end
					if isDemo then
						c2.isDemoed = true
						c2.demoRespawnTimer = C.DEMO_RESPAWN_TIME
					else
						local groundHit = c2.isOnGround
						local baseScale = (if groundHit then Curve.BUMP_VEL_AMOUNT_GROUND else Curve.BUMP_VEL_AMOUNT_AIR):GetOutput(speedTowardsOtherCar)
						local hitUpDir = if c2.isOnGround then c2.body.up else Vector3.zAxis
						local bumpImpulse = velDir * baseScale + hitUpDir * Curve.BUMP_UPWARD_VEL_AMOUNT:GetOutput(speedTowardsOtherCar)
						c2.velocityImpulseCache += bumpImpulse * UU
					end
					c1.carContact.otherCarID = c2.id
					c1.carContact.cooldownTimer = C.BUMP_COOLDOWN_TIME
					emit(self, { type = if isDemo then "demo" else "bump", bumper = c1, victim = c2 })
				end
			end
		end
	end
end

local function aabbOfCar(car: any): (Vector3, Vector3)
	local b = car.body
	local c = CarPhysics.GetHitboxCenter(car)
	local h = car.hitboxHalf
	local ext = Vector3.new(
		math.abs(b.fwd.X) * h.X + math.abs(b.right.X) * h.Y + math.abs(b.up.X) * h.Z,
		math.abs(b.fwd.Y) * h.X + math.abs(b.right.Y) * h.Y + math.abs(b.up.Y) * h.Z,
		math.abs(b.fwd.Z) * h.X + math.abs(b.right.Z) * h.Y + math.abs(b.up.Z) * h.Z
	)
	return c - ext, c + ext
end

-- BoostPad::_CheckCollide
local function padCheckCollide(pad: any, car: any)
	local padPos = pad.pos * UU
	local colliding = false
	if pad.prevLockedCarId == car.id then
		local boxRad = (if pad.isBig then C.BOOSTPAD_BOX_RAD_BIG else C.BOOSTPAD_BOX_RAD_SMALL) * UU
		local bmin = padPos - Vector3.new(boxRad, boxRad, 0)
		local bmax = padPos + Vector3.new(boxRad, boxRad, C.BOOSTPAD_BOX_HEIGHT * UU)
		local cmin, cmax = aabbOfCar(car)
		colliding = bmax.X > cmin.X and bmax.Y > cmin.Y and bmax.Z > cmin.Z and bmin.X < cmax.X and bmin.Y < cmax.Y and bmin.Z < cmax.Z
	else
		local rad = (if pad.isBig then C.BOOSTPAD_CYL_RAD_BIG else C.BOOSTPAD_CYL_RAD_SMALL) * UU
		local p = car.body.pos
		local dx, dy = p.X - padPos.X, p.Y - padPos.Y
		if dx * dx + dy * dy < rad * rad then
			colliding = math.abs(p.Z - padPos.Z) < C.BOOSTPAD_CYL_HEIGHT * UU
		end
	end
	if colliding then
		pad.curLockedCar = car
	end
end

function World.IsBallScored(self: any): boolean
	if self.arena then return false end -- custom maps score however their minigame says
	return math.abs(self.ball.body.pos.Y * BT) > C.SOCCAR_GOAL_SCORE_BASE_THRESHOLD_Y + C.BALL_COLLISION_RADIUS_SOCCAR
end

-- One 120 Hz tick
function World.Step(self: any, ticks: number?)
	for _ = 1, ticks or 1 do
		World._StepOnce(self)
	end
end

function World._StepOnce(self: any)
	local dt = self.tickTime
	local ball = self.ball
	local bb = ball.body
	table.clear(self.events)
	-- ball slots: the main ball, then any extra (owned) balls
	local slots = { { ball = ball, owner = self.ballOwner, enabled = self.ballEnabled, pre = "b" } }
	for i, e in self.extraBalls do
		table.insert(slots, { ball = e.ball, owner = e.owner, enabled = e.enabled ~= false, pre = "x" .. i .. ":" })
	end

	-- Ball zero-velocity sleeping
	for _, s in slots do
		local sb = s.ball.body
		sb.sleeping = (sb.vel == Vector3.zero and sb.angVel == Vector3.zero)
	end

	for _, car in self.cars do
		CarPhysics.PreTickUpdate(car, dt, self)
	end

	local hasCars = #self.cars > 0
	if hasCars then
		for _, pad in self.pads do
			if pad.cooldown > 0 then
				pad.cooldown = math.max(pad.cooldown - dt, 0)
			end
			pad.isActive = pad.cooldown == 0
			pad.curLockedCar = nil
		end
	end

	-- ===== Bullet world step =====
	local activeCars = {}
	for _, car in self.cars do
		if not car.isDemoed then
			table.insert(activeCars, car)
		end
	end

	-- applyGravity + damping (active bodies only)
	local g = Vector3.new(0, 0, C.GRAVITY_Z * UU)
	for _, car in activeCars do
		car.body.totalForce += g * car.body.mass
	end
	for _, s in slots do
		local sb = s.ball.body
		if not sb.sleeping and s.enabled then
			sb.totalForce += g * (sb.mass * self.ballGravityScale)
			sb.vel *= (1 - sb.linearDamping) ^ dt
		end
	end

	-- Collision detection (persistent manifolds, one per colliding pair, exactly like Bullet + RocketSim)
	local contacts = {}
	local manifolds = self.manifolds
	local ballThrBT = C.CONTACT_BREAKING_THRESHOLD_UU * UU

	for _, car in activeCars do
		local cb = car.body
		local hc = CarPhysics.GetHitboxCenter(car)
		local carThrBT = CarPhysics.BreakingThreshold(car)
		-- car-ball: btSphereBoxCollisionAlgorithm adds one point per tick (an owned ball only meets its owner)
		for _, s in slots do
			local sball = s.ball
			local sb = sball.body
			local mkey = s.pre .. car.id
			local m = manifolds[mkey]
			if not m then
				m = Manifold.new(math.min(carThrBT, ballThrBT))
				manifolds[mkey] = m
			end
			if s.enabled and (s.owner == nil or s.owner == car) then
				local pOnBox, n, dist = Collision.SphereOBB(sb.pos, sball.radius, hc, cb.fwd, cb.right, cb.up, car.hitboxHalf, m.threshold)
				if pOnBox then
					local np = m:Add(sb, cb, pOnBox, n, dist, C.CARBALL_COLLISION_FRICTION, C.CARBALL_COLLISION_RESTITUTION)
					if np then
						BallPhysics.OnHit(sball, car, self.tickCount)
						emit(self, { type = "hit", car = car, ball = if sball == ball then nil else sball })
					end
				end
				m:Refresh(sb, cb)
			else
				table.clear(m.points)
			end
		end

		-- car-world: one manifold per arena primitive
		CarPhysics.ArenaNarrowPhase(car, hc, carThrBT, self.extraSolids, function(primIndex: number, pointB: Vector3, normal: Vector3, dist: number)
			local key = "w" .. car.id .. ":" .. primIndex
			local wm = manifolds[key]
			if not wm then
				wm = Manifold.new(carThrBT)
				manifolds[key] = wm
			end
			local np = wm:Add(cb, nil, pointB, normal, dist, C.CARWORLD_COLLISION_FRICTION, C.CARWORLD_COLLISION_RESTITUTION)
			if np then
				-- Arena::_BtCallback_OnCarWorldCollision
				car.worldContact.hasContact = true
				car.worldContact.contactNormal = normal
			end
		end, self.arena)
		local prefix = "w" .. car.id .. ":"
		for key, wm in manifolds do
			if string.sub(key, 1, #prefix) == prefix then
				wm:Refresh(cb, nil)
			end
		end
	end

	-- car-car: box-box adds up to 4 points per tick into the pair's manifold
	for i = 1, if self.carCarCollision then #activeCars else 0 do
		for j = i + 1, #activeCars do
			local c1, c2 = activeCars[i], activeCars[j]
			local b1, b2 = c1.body, c2.body
			local key = "c" .. c1.id .. ":" .. c2.id
			local m = manifolds[key]
			if not m then
				m = Manifold.new(math.min(CarPhysics.BreakingThreshold(c1), CarPhysics.BreakingThreshold(c2)))
				manifolds[key] = m
			end
			local cc = Collision.OBBOBB(CarPhysics.GetHitboxCenter(c1), b1.fwd, b1.right, b1.up, c1.hitboxHalf,
				CarPhysics.GetHitboxCenter(c2), b2.fwd, b2.right, b2.up, c2.hitboxHalf, m.threshold)
			if cc then
				for _, c in cc do
					local np = m:Add(b1, b2, c.pointB, c.normal, c.dist, C.CARCAR_COLLISION_FRICTION, C.CARCAR_COLLISION_RESTITUTION)
					if np then
						carCarCallback(self, c1, c2, np)
					end
				end
			end
			m:Refresh(b1, b2)
		end
	end

	-- A sleeping ball is woken by car contact (same island), but received no gravity this tick
	for _, s in slots do
		local ballTouched = false
		for _, car in activeCars do
			local m = manifolds[s.pre .. car.id]
			if m and #m.points > 0 then
				ballTouched = true
			end
		end
		local sb = s.ball.body
		s.active = s.enabled and ((not sb.sleeping) or ballTouched)
		if s.active then
			local list = Collision.SphereArena(sb.pos, C.BALL_WORLD_CONTACT_RADIUS, C.BALL_WORLD_CONTACT_THRESHOLD_UU, self.arena)
			if self.extraSolids then
				Collision.SphereExtraSolids(sb.pos, C.BALL_WORLD_CONTACT_RADIUS, C.BALL_WORLD_CONTACT_THRESHOLD_UU, self.extraSolids, list)
			end
			BallPhysics.WorldContacts(s.ball, list, contacts)
		end
	end
	local ballActive = slots[1].active

	-- Bodies in this solve (a car may have been demolished by a callback this tick)
	local bodies = {}
	local bodySet = {}
	for _, car in activeCars do
		if not car.isDemoed then
			table.insert(bodies, car.body)
			bodySet[car.body] = true
		end
	end
	for _, s in slots do
		if s.active then
			table.insert(bodies, s.ball.body)
			bodySet[s.ball.body] = true
		end
	end

	-- Emit every manifold point (warm-started) whose bodies take part
	for _, car in activeCars do
		local cb = car.body
		if bodySet[cb] then
			for _, s in slots do
				local m = manifolds[s.pre .. car.id]
				if m and s.active then
					m:Emit(s.ball.body, cb, contacts)
				end
			end
			local prefix = "w" .. car.id .. ":"
			for key, wm in manifolds do
				if string.sub(key, 1, #prefix) == prefix then
					wm:Emit(cb, nil, contacts)
				end
			end
		end
	end
	for i = 1, #activeCars do
		for j = i + 1, #activeCars do
			local c1, c2 = activeCars[i], activeCars[j]
			if bodySet[c1.body] and bodySet[c2.body] then
				local m = manifolds["c" .. c1.id .. ":" .. c2.id]
				if m then
					m:Emit(c1.body, c2.body, contacts)
				end
			end
		end
	end

	local rows = Solver.Solve(bodies, contacts, dt)
	for _, row in rows do
		local c = row.contact
		if c and c.mp then
			c.mp.applied = row.applied
		end
	end
	for _, bdy in bodies do
		Solver.Integrate(bdy, dt)
		bdy.totalForce = Vector3.zero
		bdy.totalTorque = Vector3.zero
	end
	for _, s in slots do
		s.ball.body.totalForce = Vector3.zero
		s.ball.body.totalTorque = Vector3.zero
	end

	-- ===== Post =====
	for _, car in self.cars do
		CarPhysics.PostTickUpdate(car, dt)
		CarPhysics.FinishPhysicsTick(car)
		if not car.isDemoed then
			for _, pad in self.pads do
				padCheckCollide(pad, car)
			end
		end
	end

	if hasCars then
		for _, pad in self.pads do
			local lockedId = 0
			if pad.curLockedCar then
				lockedId = pad.curLockedCar.id
				if pad.isActive then
					local car = pad.curLockedCar
					car.boost = math.min(car.boost + (if pad.isBig then C.BOOSTPAD_AMOUNT_BIG else C.BOOSTPAD_AMOUNT_SMALL), C.BOOST_MAX)
					pad.isActive = false
					pad.cooldown = if pad.isBig then C.BOOSTPAD_COOLDOWN_BIG else C.BOOSTPAD_COOLDOWN_SMALL
					emit(self, { type = "pad", pad = pad, car = car })
				end
			end
			pad.prevLockedCarId = lockedId
		end
	end

	for _, s in slots do
		BallPhysics.FinishPhysicsTick(s.ball)
	end

	if self.ballEnabled and World.IsBallScored(self) then
		emit(self, { type = "goal", team = if bb.pos.Y > 0 then 0 else 1 }) -- team that scored
	end

	self.tickCount += 1
end

-- Copy of just the ball into a ball-only world (used by BallPrediction)
function World.CloneBallOnly(self: any)
	local w = World.new({ boostPads = false, arena = self.arena, extraSolids = self.extraSolids })
	w.ballGravityScale = self.ballGravityScale
	local b = self.ball.body
	BallPhysics.SetState(w.ball, b.pos * BT, b.vel * BT, b.angVel, b.rot)
	return w
end

return World
