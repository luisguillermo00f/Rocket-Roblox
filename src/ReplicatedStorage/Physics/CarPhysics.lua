--!strict
-- CarPhysics.lua
-- 1:1 port of RocketSim 2.2.1 Car.cpp + btVehicleRL.cpp (Rocket League's modified btRaycastVehicle).
--
-- The car is a Bullet-style rigid body (180 kg box hitbox, box inertia) with four raycast wheels:
--   * suspension: spring/damper per wheel along the contact normal, clipped by the contact angle,
--     plus "extra pushback" (resolveSingleCollision) when a wheel is compressed hard
--   * tires: sideways friction impulse (resolveSingleBilateral) and a rolling impulse that carries the
--     engine/brake force, both scaled by friction curves (slip, powerslide, non-sticky surfaces)
--   * steering is a real wheel angle from the speed curve; the car turns because the front tires push it
--   * sticky force, auto-roll, jump / double jump / flip / flip-cancel / auto-flip, air control and boost
--     are applied exactly where and when Car::_PreTickUpdate applies them.
-- NOTE: a few RocketSim values are one tick late on purpose (wheel steer angle, engine force and friction
-- factors are written after the friction impulses of the current tick were computed) - this matches RL.
--
-- Units: body in Bullet units (BT); UU-denominated constants are converted at the point of use.

local C = require(script.Parent.PhysicsConstants)
local Curve = require(script.Parent.LinearPieceCurve)
local RigidBody = require(script.Parent.RigidBody)
local Q = require(script.Parent.Quaternion)
local Solver = require(script.Parent.ContactSolver)
local Collision = require(script.Parent.Collision)
local ArenaCollision = require(script.Parent.ArenaCollision)
local CarConfig = require(script.Parent.CarConfig)

local UU, BT = C.UU_TO_BT, C.BT_TO_UU

export type Controls = {
	throttle: number, steer: number,
	pitch: number, yaw: number, roll: number,
	jump: boolean, boost: boolean, handbrake: boolean,
}

local CarPhysics = {}
CarPhysics.__index = CarPhysics

function CarPhysics.EmptyControls(): Controls
	return { throttle = 0, steer = 0, pitch = 0, yaw = 0, roll = 0, jump = false, boost = false, handbrake = false }
end

local function copyControls(c: Controls): Controls
	return { throttle = c.throttle, steer = c.steer, pitch = c.pitch, yaw = c.yaw, roll = c.roll, jump = c.jump, boost = c.boost, handbrake = c.handbrake }
end

local function sgn(x: number): number
	-- RS_SGN
	return if x > 0 then 1 elseif x < 0 then -1 else 0
end

function CarPhysics.new(config: CarConfig.Config?, team: number?, id: number?)
	local cfg = config or CarConfig.Octane
	local half = cfg.hitboxSize * (0.5 * UU)
	local body = RigidBody.new(C.CAR_MASS_BT, RigidBody.BoxInertia(C.CAR_MASS_BT, half))
	body.kind = "car"

	local self = setmetatable({
		id = id or 1,
		team = team or 0, -- 0 blue, 1 orange
		config = cfg,
		body = body,
		hitboxHalf = half,
		hitboxOffset = cfg.hitboxPosOffset * UU,
		controls = CarPhysics.EmptyControls(),
		lastControls = CarPhysics.EmptyControls(),
		velocityImpulseCache = Vector3.zero,

		-- CarState (RocketSim Car.h)
		isOnGround = true,
		wheelsWithContact = { false, false, false, false },
		hasJumped = false,
		hasDoubleJumped = false,
		hasFlipped = false,
		flipRelTorque = Vector3.zero,
		jumpTime = 0,
		flipTime = 0,
		isFlipping = false,
		isJumping = false,
		airTime = 0,
		airTimeSinceJump = 0,
		boost = C.BOOST_SPAWN_AMOUNT,
		timeSinceBoosted = 0,
		isBoosting = false,
		boostingTime = 0,
		isSupersonic = false,
		supersonicTime = 0,
		handbrakeVal = 0,
		isAutoFlipping = false,
		autoFlipTimer = 0,
		autoFlipTorqueScale = 0,
		worldContact = { hasContact = false, contactNormal = Vector3.zAxis },
		carContact = { otherCarID = 0, cooldownTimer = 0 },
		isDemoed = false,
		demoRespawnTimer = 0,
		ballHitInfo = { isValid = false, relativePosOnBall = Vector3.zero, ballPos = Vector3.zero, extraHitVel = Vector3.zero, tickCountWhenHit = -100, tickCountWhenExtraImpulseApplied = -100 },

		wheels = {},
	}, CarPhysics)

	for i = 1, 4 do
		local front = i <= 2
		local left = (i % 2) == 0
		local wp = if front then cfg.frontWheels else cfg.backWheels
		local conn = wp.connectionPointOffset
		if left then
			conn = Vector3.new(conn.X, -conn.Y, conn.Z)
		end
		local rest = (wp.suspensionRestLength - C.MAX_SUSPENSION_TRAVEL) * UU
		self.wheels[i] = {
			front = front,
			left = left,
			conn = conn * UU,
			radius = wp.radius * UU,
			restLen = rest,
			travel = C.MAX_SUSPENSION_TRAVEL * UU,
			suspensionForceScale = if front then C.SUSPENSION_FORCE_SCALE_FRONT else C.SUSPENSION_FORCE_SCALE_BACK,
			steerAngle = 0,
			engineForce = 0,
			brake = 0,
			latFriction = 0,
			longFriction = 0,
			impulse = Vector3.zero,
			isInContact = false,
			isInContactWithWorld = false,
			groundObject = nil,
			groundBody = nil,
			contactPoint = Vector3.zero,
			contactNormal = Vector3.zAxis,
			suspensionLength = rest,
			suspensionRelVel = 0,
			clippedInv = 1,
			extraPushback = 0,
			suspensionForce = 0,
			hardPoint = Vector3.zero,
			wheelDir = -Vector3.zAxis,
			axle = -Vector3.yAxis,
			latDir = Vector3.yAxis,
			fwdDir = Vector3.xAxis,
			spin = 0,
		}
	end
	return self
end

-- ===== State helpers =====
function CarPhysics.GetForwardDir(self: any): Vector3 return self.body.fwd end
function CarPhysics.GetRightDir(self: any): Vector3 return self.body.right end
function CarPhysics.GetUpDir(self: any): Vector3 return self.body.up end

function CarPhysics.GetPosUU(self: any): Vector3 return self.body.pos * BT end
function CarPhysics.GetVelUU(self: any): Vector3 return self.body.vel * BT end

-- Hitbox (OBB) center in BT
function CarPhysics.GetHitboxCenter(self: any): Vector3
	return self.body.pos + RigidBody.ToWorld(self.body, self.hitboxOffset)
end

function CarPhysics.SetState(self: any, posUU: Vector3, rot: Q.Quat, velUU: Vector3?, angVel: Vector3?)
	local b = self.body
	b.pos = posUU * UU
	RigidBody.SetRotation(b, rot)
	b.vel = (velUU or Vector3.zero) * UU
	b.angVel = angVel or Vector3.zero
	self.velocityImpulseCache = Vector3.zero
end

-- CarState reset for a fresh spawn (RocketSim: SetState with a default CarState)
function CarPhysics.ResetState(self: any, posUU: Vector3, yaw: number, boost: number, onGround: boolean)
	local fresh = CarPhysics.new(self.config, self.team, self.id)
	for k, v in fresh do
		if k ~= "body" and k ~= "controls" then
			self[k] = v
		end
	end
	self.isOnGround = onGround
	self.boost = boost
	CarPhysics.SetState(self, posUU, Q.fromYaw(yaw))
	for _, w in self.wheels do
		w.suspensionLength = w.restLen
	end
end

function CarPhysics.HasFlipOrJump(self: any): boolean
	return self.isOnGround or (not self.hasFlipped and not self.hasDoubleJumped and self.airTimeSinceJump < C.DOUBLEJUMP_MAX_DELAY)
end

function CarPhysics.HasFlipReset(self: any): boolean
	return not self.isOnGround and CarPhysics.HasFlipOrJump(self) and not self.hasJumped
end

-- Contact breaking threshold of the car's compound shape: gContactBreakingThreshold * angular motion disc,
-- where the disc is the bounding-sphere radius of the hitbox AABB plus the distance of its center (btCompoundShape).
function CarPhysics.BreakingThreshold(self: any): number
	return (self.hitboxHalf.Magnitude + self.hitboxOffset.Magnitude) * C.CONTACT_BREAKING_THRESHOLD_BT
end

-- Car hitbox vs arena, one new point per primitive per tick (what Bullet's algorithms produce each tick):
--   planes: btConvexPlaneCollisionAlgorithm support vertex (no perturbation in RocketSim's configuration)
--   curved ramps: deepest box corner against the ramp surface
--   goal blocks: deepest box-box contact; the goal's sloped roof (convex hull): deepest box corner
-- addPoint(primIndex, pointOnArena (BT), normal, dist (BT))
local CORNER_SIGNS = {
	Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(1, 1, -1), Vector3.new(-1, 1, -1), Vector3.new(1, -1, -1), Vector3.new(-1, -1, -1),
}
function CarPhysics.ArenaNarrowPhase(self: any, hc: Vector3, thr: number, extraSolids: { any }?, addPoint: (number, Vector3, Vector3, number) -> (), arena: any?)
	local b = self.body
	local f, r, u = b.fwd, b.right, b.up
	local h = self.hitboxHalf
	local hcUU = hc * BT
	local thrUU = thr * BT
	local prims = if arena then arena.Primitives else ArenaCollision.Primitives
	local corners = nil
	-- a custom map only tests the pieces around the car (its grid); the Soccar arena tests all ~40 of its solids
	local nearList, nearN = nil, 0
	if arena then nearList, nearN = arena.Near(hcUU, 400) end
	for idx = 1, if arena then nearN else #prims do
		local i = if arena then nearList[idx] else idx
		local pr = prims[i]
		local kind = pr.kind
		if kind == "plane" then
			local n = pr.n
			-- btBoxShape::localGetSupportingVertex(-n): each component picks +h when the direction is >= 0.
			-- Components that are only float noise count as 0 (a perfectly level car must pick the same corner
			-- Bullet picks, otherwise a symmetric impact comes out mirrored).
			local dx, dy, dz = (-n):Dot(f), (-n):Dot(r), (-n):Dot(u)
			local sx = if dx >= -1e-5 then h.X else -h.X
			local sy = if dy >= -1e-5 then h.Y else -h.Y
			local sz = if dz >= -1e-5 then h.Z else -h.Z
			local vtx = (hc + f * sx + r * sy + u * sz) * BT
			local dist = vtx:Dot(n) - pr.off
			if dist < thrUU then
				addPoint(i, (vtx - n * dist) * UU, n, dist * UU)
			end
		elseif kind == "fillet" then
			local rel = hcUU - pr.c
			local t = rel:Dot(pr.a)
			local perp = rel - pr.a * t
			if t > pr.t0 - 120 and t < pr.t1 + 120 and perp.Magnitude < pr.r + 120 then
				if not corners then
					corners = table.create(8)
					for ci, sg in CORNER_SIGNS do
						corners[ci] = (hc + f * (h.X * sg.X) + r * (h.Y * sg.Y) + u * (h.Z * sg.Z)) * BT
					end
				end
				local best, bestN, bestP = math.huge, nil, nil
				for _, p in corners do
					local d, n = ArenaCollision.PrimDist(pr, p)
					if d < best then
						best, bestN, bestP = d, n, p
					end
				end
				if bestN and best < thrUU then
					addPoint(i, (bestP - bestN * best) * UU, bestN, best * UU)
				end
			end
		elseif kind == "hull" then
			if ArenaCollision.PrimDist(pr, hcUU) < 160 then
				if not corners then
					corners = table.create(8)
					for ci, sg in CORNER_SIGNS do
						corners[ci] = (hc + f * (h.X * sg.X) + r * (h.Y * sg.Y) + u * (h.Z * sg.Z)) * BT
					end
				end
				local best, bestN, bestP = math.huge, nil, nil
				for _, p in corners do
					local d, n = ArenaCollision.PrimDist(pr, p)
					if d < best then
						best, bestN, bestP = d, n, p
					end
				end
				if bestN and best < thrUU then
					addPoint(i, (bestP - bestN * best) * UU, bestN, best * UU)
				end
			end
		else -- box
			local d0 = ArenaCollision.PrimDist(pr, hcUU)
			if d0 < 120 then
				local cc = Collision.OBBOBB(hc, f, r, u, h, pr.c * UU, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, pr.h * UU, thr)
				if cc then
					local deepest = cc[1]
					for _, c in cc do
						if c.dist < deepest.dist then
							deepest = c
						end
					end
					addPoint(i, deepest.pointB, deepest.normal, deepest.dist)
				end
			end
		end
	end
	-- per-world minigame solids (boxes), indexed after the arena primitives
	if extraSolids then
		for k, sol in extraSolids do
			if sol.car then
				local d0 = ArenaCollision.PrimDist(sol, hcUU)
				if d0 < 120 + math.max(sol.h.X, sol.h.Y, sol.h.Z) then
					local cc = Collision.OBBOBB(hc, f, r, u, h, sol.c * UU, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, sol.h * UU, thr)
					if cc then
						local deepest = cc[1]
						for _, c in cc do
							if c.dist < deepest.dist then
								deepest = c
							end
						end
						addPoint(#prims + k, deepest.pointB, deepest.normal, deepest.dist)
					end
				end
			end
		end
	end
end

-- ===== btVehicleRL =====
local function updateWheelTransformsWS(self: any, w: any)
	local b = self.body
	w.isInContact = false
	w.isInContactWithWorld = false
	w.hardPoint = b.pos + RigidBody.ToWorld(b, w.conn)
	w.wheelDir = -b.up
	w.axle = -b.right
end

local function updateWheelTransform(self: any, w: any)
	updateWheelTransformsWS(self, w)
	local up = -w.wheelDir
	local right = -w.axle -- basis2 right column = -axle
	local fwd = up:Cross(w.axle).Unit
	local s, c = math.sin(w.steerAngle), math.cos(w.steerAngle)
	-- steering rotation about `up` (Rodrigues; both vectors are perpendicular to `up`)
	w.latDir = right * c + up:Cross(right) * s
	w.fwdDir = fwd * c + up:Cross(fwd) * s
end

-- Closest hit among arena, ball and other cars (Bullet's ClosestRayResultCallback, chassis excluded)
local function castWheelRay(self: any, world: any, from: Vector3, dir: Vector3, len: number)
	local bestT, bestN, bestObj, bestStatic = nil, nil, nil, false
	local A = (world and world.arena) or ArenaCollision
	local t, _, n = A.RayCast(from * BT, dir, len * BT)
	if t then
		bestT, bestN, bestObj, bestStatic = t * UU, n, "world", true
	end
	if world then
		local ball = world.ball
		if ball and ball.body and world.ballEnabled ~= false then
			local bt, bn = Collision.RaySphere(from, dir, bestT or len, ball.body.pos, ball.radius)
			if bt then
				bestT, bestN, bestObj, bestStatic = bt, bn, ball.body, false
			end
		end
		for _, other in world.cars do
			if other ~= self and not other.isDemoed then
				local ob = other.body
				local ct, cn = Collision.RayOBB(from, dir, bestT or len, CarPhysics.GetHitboxCenter(other), ob.fwd, ob.right, ob.up, other.hitboxHalf)
				if ct then
					bestT, bestN, bestObj, bestStatic = ct, cn, ob, false
				end
			end
		end
	end
	return bestT, bestN, bestObj, bestStatic
end

local function rayCast(self: any, w: any, world: any, dt: number)
	updateWheelTransformsWS(self, w)
	local b = self.body
	local travel = w.travel
	local realRayLength = w.restLen + travel + w.radius - C.SUSPENSION_SUBTRACTION
	local source = w.hardPoint
	w.contactPoint = source + w.wheelDir * realRayLength
	w.groundObject = nil
	w.groundBody = nil

	local t, n, obj, isStatic = castWheelRay(self, world, source, w.wheelDir, realRayLength)
	if t then
		w.contactPoint = source + w.wheelDir * t
		w.contactNormal = n
		w.isInContact = true
		w.isInContactWithWorld = isStatic
		w.groundObject = obj
		w.groundBody = if isStatic then nil else obj

		local carUp = b.up
		local wheelTraceLenSq = (source - w.contactPoint):Dot(carUp)
		w.suspensionLength = math.clamp(wheelTraceLenSq - w.radius, w.restLen - travel, w.restLen + travel)

		local denominator = n:Dot(carUp)
		local relpos = w.contactPoint - b.pos
		local velAtContact = b.vel + b.angVel:Cross(relpos)
		local projVel = n:Dot(velAtContact)
		if denominator > 0.1 then
			local inv = 1 / denominator
			w.suspensionRelVel = projVel * inv
			w.clippedInv = inv
		else
			w.suspensionRelVel = 0
			w.clippedInv = 10
		end

		if isStatic then
			local rayPushbackThresh = (w.restLen + w.radius) - C.SUSPENSION_SUBTRACTION
			if wheelTraceLenSq < rayPushbackThresh then
				local delta = wheelTraceLenSq - rayPushbackThresh
				local collisionResult = Solver.ResolveSingleCollision(b, w.contactPoint, n, delta, dt)
				w.extraPushback = collisionResult / 4
			end
		end
	else
		w.suspensionLength = w.restLen + travel
		w.suspensionRelVel = 0
		w.contactNormal = -w.wheelDir
		w.clippedInv = 1
		w.extraPushback = 0
	end
end

local function calcFrictionImpulses(self: any, dt: number)
	local b = self.body
	local frictionScale = b.mass / 3
	for _, w in self.wheels do
		if w.groundObject then
			local axleDir = w.latDir
			local surfN = w.contactNormal
			axleDir -= surfN * axleDir:Dot(surfN)
			axleDir = if axleDir.Magnitude > 1e-9 then axleDir.Unit else axleDir
			local forwardDir = surfN:Cross(axleDir)
			forwardDir = if forwardDir.Magnitude > 1e-9 then forwardDir.Unit else forwardDir

			local ground = w.groundBody
			local sideImpulse = Solver.ResolveSingleBilateral(b, w.contactPoint, ground, w.contactPoint, axleDir)

			local rollingFriction
			if w.engineForce == 0 then
				if w.brake ~= 0 then
					local carRel = w.contactPoint - b.pos
					local v1 = b.vel + b.angVel:Cross(carRel)
					local v2 = if ground then ground.vel + ground.angVel:Cross(carRel) else Vector3.zero
					local relVel = (v1 - v2):Dot(forwardDir)
					if dt > 1 / 80 then
						local threshold = -(1 / (dt * 150)) + 0.8
						if math.abs(relVel) < threshold then
							relVel = 0
						end
					end
					rollingFriction = math.clamp(-relVel * C.ROLLING_FRICTION_SCALE_MAGIC, -w.brake, w.brake)
				else
					rollingFriction = 0
				end
			else
				rollingFriction = -w.engineForce / frictionScale
			end

			local total = forwardDir * (rollingFriction * w.longFriction) + axleDir * (sideImpulse * w.latFriction)
			w.impulse = total * frictionScale
		else
			w.impulse = Vector3.zero
		end
	end
end

local function getUpwardsDirFromWheelContacts(self: any): Vector3
	local sum = Vector3.zero
	for _, w in self.wheels do
		if w.isInContact then
			sum += w.contactNormal
		end
	end
	if sum == Vector3.zero then
		return self.body.up
	end
	return sum.Unit
end

local function updateSuspension(self: any, dt: number)
	local b = self.body
	for _, w in self.wheels do
		if w.isInContact then
			local force = (w.restLen - w.suspensionLength) * C.SUSPENSION_STIFFNESS * w.clippedInv
			local dampingVelScale = if w.suspensionRelVel < 0 then C.WHEELS_DAMPING_COMPRESSION else C.WHEELS_DAMPING_RELAXATION
			local f = (force - dampingVelScale * w.suspensionRelVel) * w.suspensionForceScale
			w.suspensionForce = if f < 0 then 0 else f
		else
			w.suspensionForce = 0
		end
	end
	for _, w in self.wheels do
		if w.suspensionForce ~= 0 then
			local offset = w.contactPoint - b.pos
			local scale = (w.suspensionForce * dt) + w.extraPushback
			RigidBody.ApplyImpulse(b, w.contactNormal * scale, offset)
		end
	end
end

local function applyFrictionImpulses(self: any, dt: number)
	local b = self.body
	local up = b.up
	for _, w in self.wheels do
		if w.impulse ~= Vector3.zero then
			local offset = w.contactPoint - b.pos
			local rel = offset - up * up:Dot(offset)
			RigidBody.ApplyImpulse(b, w.impulse * dt, rel)
		end
	end
end

-- ===== Car.cpp =====
local function updateWheels(self: any, dt: number, numWheelsInContact: number, forwardSpeed_UU: number)
	local b = self.body
	local controls = self.controls
	local absForwardSpeed_UU = math.abs(forwardSpeed_UU)

	local wheelsHaveWorldContact = false
	for _, w in self.wheels do
		wheelsHaveWorldContact = wheelsHaveWorldContact or w.isInContactWithWorld
	end

	if controls.handbrake then
		self.handbrakeVal += C.POWERSLIDE_RISE_RATE * dt
	else
		self.handbrakeVal -= C.POWERSLIDE_FALL_RATE * dt
	end
	self.handbrakeVal = math.clamp(self.handbrakeVal, 0, 1)

	local realThrottle = controls.throttle
	local realBrake = 0
	if controls.boost and self.boost > 0 then
		realThrottle = 1
	end

	do -- throttle / brake
		local driveSpeedScale = Curve.DRIVE_SPEED_TORQUE_FACTOR:GetOutput(absForwardSpeed_UU)
		local engineThrottle = realThrottle
		if controls.handbrake then
			-- real throttle is unchanged from the input throttle when powersliding
		else
			local absThrottle = math.abs(realThrottle)
			if absThrottle >= C.THROTTLE_DEADZONE then
				if absForwardSpeed_UU > C.STOPPING_FORWARD_VEL and sgn(realThrottle) ~= sgn(forwardSpeed_UU) then
					realBrake = 1
					if absForwardSpeed_UU > C.BRAKING_NO_THROTTLE_SPEED_THRESH then
						engineThrottle = 0
					end
				end
			else
				engineThrottle = 0
				realBrake = if absForwardSpeed_UU < C.STOPPING_FORWARD_VEL then 1 else C.COASTING_BRAKE_FACTOR
			end
		end
		if numWheelsInContact < 3 then
			driveSpeedScale /= 4
		end
		local driveEngineForce = engineThrottle * (C.THROTTLE_TORQUE_AMOUNT * UU) * driveSpeedScale
		local driveBrakeForce = realBrake * (C.BRAKE_TORQUE_AMOUNT * UU)
		for _, w in self.wheels do
			w.engineForce = driveEngineForce
			w.brake = driveBrakeForce
		end
	end

	do -- steering
		local steerAngle = Curve.STEER_ANGLE_FROM_SPEED:GetOutput(absForwardSpeed_UU)
		if self.handbrakeVal ~= 0 then
			steerAngle += (Curve.POWERSLIDE_STEER_ANGLE_FROM_SPEED:GetOutput(absForwardSpeed_UU) - steerAngle) * self.handbrakeVal
		end
		steerAngle *= controls.steer
		self.wheels[1].steerAngle = steerAngle
		self.wheels[2].steerAngle = steerAngle
	end

	do -- friction
		for _, w in self.wheels do
			if w.groundObject then
				local vel, angVel = b.vel, b.angVel
				local latDir = w.latDir
				local longDir = latDir:Cross(w.contactNormal)
				local frictionCurveInput = 0
				local wheelDelta = w.hardPoint - b.pos
				local crossVec = (angVel:Cross(wheelDelta) + vel) * BT
				local baseFriction = math.abs(crossVec:Dot(latDir))
				if baseFriction > 5 then
					frictionCurveInput = baseFriction / (math.abs(crossVec:Dot(longDir)) + baseFriction)
				end
				local latFriction = Curve.LAT_FRICTION:GetOutput(frictionCurveInput)
				local longFriction = Curve.LONG_FRICTION:GetOutput(frictionCurveInput)
				if self.handbrakeVal ~= 0 then
					local hb = self.handbrakeVal
					latFriction *= (Curve.HANDBRAKE_LAT_FRICTION_FACTOR:GetOutput(frictionCurveInput) - 1) * hb + 1
					longFriction *= (Curve.HANDBRAKE_LONG_FRICTION_FACTOR:GetOutput(frictionCurveInput) - 1) * hb + 1
				else
					longFriction = 1
				end
				if realThrottle == 0 then
					local nonStickyScale = Curve.NON_STICKY_FRICTION_FACTOR:GetOutput(w.contactNormal.Z)
					latFriction *= nonStickyScale
					longFriction *= nonStickyScale
				end
				w.latFriction = latFriction
				w.longFriction = longFriction
			end
		end
	end

	if wheelsHaveWorldContact then -- sticky force
		local upwardsDir = getUpwardsDirFromWheelContacts(self)
		local fullStick = (realThrottle ~= 0) or (absForwardSpeed_UU > C.STOPPING_FORWARD_VEL)
		local stickyForceScale = 0.5
		if fullStick then
			stickyForceScale += 1 - math.abs(upwardsDir.Z)
		end
		RigidBody.ApplyCentralForce(b, upwardsDir * (stickyForceScale * (C.GRAVITY_Z * UU) * C.CAR_MASS_BT))
	end
end

local function updateBoost(self: any, dt: number)
	local b = self.body
	local controls = self.controls
	local hasBoost = self.boost > 0
	if hasBoost then
		if self.isBoosting then
			self.isBoosting = controls.boost or self.boostingTime < C.BOOST_MIN_TIME
		elseif controls.boost then
			self.isBoosting = true
		end
	else
		self.isBoosting = false
	end
	if self.isBoosting then
		self.boostingTime += dt
	else
		self.boostingTime = 0
	end
	if self.isBoosting then
		self.boost = math.max(self.boost - C.BOOST_USED_PER_SECOND * dt, 0)
		local accel = if self.isOnGround then C.BOOST_ACCEL_GROUND else C.BOOST_ACCEL_AIR
		RigidBody.ApplyCentralForce(b, b.fwd * (accel * UU * C.CAR_MASS_BT))
		self.timeSinceBoosted = 0
	else
		self.timeSinceBoosted += dt
		if self.rechargeBoost and self.timeSinceBoosted >= C.RECHARGE_BOOST_DELAY then
			self.boost += C.RECHARGE_BOOST_PER_SECOND * dt
		end
	end
	self.boost = math.min(self.boost, C.BOOST_MAX)
end

local function updateJump(self: any, dt: number, jumpPressed: boolean)
	local b = self.body
	local controls = self.controls
	if self.isOnGround and not self.isJumping then
		if self.hasJumped and self.jumpTime < C.JUMP_MIN_TIME + C.JUMP_RESET_TIME_PAD then
			-- don't reset yet, we might still be leaving the ground
		else
			self.hasJumped = false
			self.jumpTime = 0
		end
	end

	if self.isJumping then
		if self.jumpTime < C.JUMP_MIN_TIME or (controls.jump and self.jumpTime < C.JUMP_MAX_TIME) then
			self.isJumping = true
		else
			self.isJumping = false
		end
	elseif self.isOnGround and jumpPressed then
		self.isJumping = true
		self.jumpTime = 0
		RigidBody.ApplyCentralImpulse(b, b.up * (C.JUMP_IMMEDIATE_FORCE * UU * C.CAR_MASS_BT))
	end

	if self.isJumping then
		self.hasJumped = true
		local totalJumpForce = b.up * C.JUMP_ACCEL
		if self.jumpTime < C.JUMP_MIN_TIME then
			totalJumpForce *= C.JUMP_PRE_MIN_ACCEL_SCALE
		end
		RigidBody.ApplyCentralForce(b, totalJumpForce * (UU * C.CAR_MASS_BT))
	end

	if self.isJumping or self.hasJumped then
		self.jumpTime += dt
	end
end

local function updateAirTorque(self: any, dt: number, updateAirControl: boolean)
	local b = self.body
	local controls = self.controls
	local dirPitch_right = -b.right
	local dirYaw_up = b.up
	local dirRoll_forward = -b.fwd

	local doAirControl = false
	if self.isFlipping then
		self.isFlipping = self.hasFlipped and self.flipTime < C.FLIP_TORQUE_TIME
	end

	if self.isFlipping then
		local relDodgeTorque = self.flipRelTorque
		if relDodgeTorque ~= Vector3.zero then
			local pitchScale = 1
			if relDodgeTorque.Y ~= 0 and controls.pitch ~= 0 then
				if sgn(relDodgeTorque.Y) == sgn(controls.pitch) then
					pitchScale = 1 - math.min(math.abs(controls.pitch), 1)
					doAirControl = true
				end
			end
			relDodgeTorque = Vector3.new(relDodgeTorque.X, relDodgeTorque.Y * pitchScale, relDodgeTorque.Z)
			local dodgeTorque = relDodgeTorque * Vector3.new(C.FLIP_TORQUE_X, C.FLIP_TORQUE_Y, 0)
			RigidBody.ApplyTorque(b, RigidBody.InertiaWorld(b, RigidBody.ToWorld(b, dodgeTorque)))
		else
			doAirControl = true -- stall
		end
	else
		doAirControl = true
	end

	doAirControl = doAirControl and not self.isAutoFlipping
	doAirControl = doAirControl and updateAirControl
	if doAirControl then
		local pitchTorqueScale = 1
		local torque = Vector3.zero
		if controls.pitch ~= 0 or controls.yaw ~= 0 or controls.roll ~= 0 then
			if self.isFlipping then
				pitchTorqueScale = 0
			elseif self.hasFlipped then
				if self.flipTime < C.FLIP_TORQUE_TIME + C.FLIP_PITCHLOCK_EXTRA_TIME then
					pitchTorqueScale = 0
				end
			end
			torque = dirPitch_right * (controls.pitch * pitchTorqueScale * C.CAR_AIR_CONTROL_TORQUE.X)
				+ dirYaw_up * (controls.yaw * C.CAR_AIR_CONTROL_TORQUE.Y)
				+ dirRoll_forward * (controls.roll * C.CAR_AIR_CONTROL_TORQUE.Z)
		end
		local angVel = b.angVel
		local dampPitch = dirPitch_right:Dot(angVel) * C.CAR_AIR_CONTROL_DAMPING.X * (1 - math.abs(controls.pitch * pitchTorqueScale))
		local dampYaw = dirYaw_up:Dot(angVel) * C.CAR_AIR_CONTROL_DAMPING.Y * (1 - math.abs(controls.yaw))
		local dampRoll = dirRoll_forward:Dot(angVel) * C.CAR_AIR_CONTROL_DAMPING.Z
		local damping = dirYaw_up * dampYaw + dirPitch_right * dampPitch + dirRoll_forward * dampRoll
		RigidBody.ApplyTorque(b, RigidBody.InertiaWorld(b, (torque - damping) * C.CAR_TORQUE_SCALE))
	end

	if controls.throttle ~= 0 then
		RigidBody.ApplyCentralForce(b, b.fwd * (controls.throttle * C.THROTTLE_AIR_ACCEL * UU * C.CAR_MASS_BT))
	end
end

local function updateDoubleJumpOrFlip(self: any, dt: number, jumpPressed: boolean, forwardSpeed_UU: number)
	local b = self.body
	local controls = self.controls
	local tickTimeScale = dt / (1 / 120)

	if self.isOnGround then
		self.hasDoubleJumped = false
		self.hasFlipped = false
		self.airTime = 0
		self.airTimeSinceJump = 0
		self.flipTime = 0
	else
		self.airTime += dt
		if self.hasJumped and not self.isJumping then
			self.airTimeSinceJump += dt
		else
			self.airTimeSinceJump = 0
		end

		if jumpPressed and self.airTimeSinceJump < C.DOUBLEJUMP_MAX_DELAY then
			local inputMagnitude = math.abs(controls.yaw) + math.abs(controls.pitch) + math.abs(controls.roll)
			local isFlipInput = inputMagnitude >= self.config.dodgeDeadzone
			local canUse = (not self.hasDoubleJumped and not self.hasFlipped)
			if isFlipInput then
				canUse = canUse or self.unlimitedFlips == true
			else
				canUse = canUse or self.unlimitedDoubleJumps == true
			end
			if self.isAutoFlipping then
				canUse = false
			end

			if canUse then
				if isFlipInput then
					self.flipTime = 0
					self.hasFlipped = true
					self.isFlipping = true

					local forwardSpeedRatio = math.abs(forwardSpeed_UU) / C.CAR_MAX_SPEED
					local dx, dy = -controls.pitch, controls.yaw + controls.roll
					if math.abs(controls.yaw + controls.roll) < 0.1 and math.abs(controls.pitch) < 0.1 then
						dx, dy = 0, 0
					else
						local l = math.sqrt(dx * dx + dy * dy)
						if l > 0 then
							dx, dy = dx / l, dy / l
						end
					end
					self.flipRelTorque = Vector3.new(-dy / tickTimeScale, dx / tickTimeScale, 0)

					if math.abs(dx) < 0.1 then dx = 0 end
					if math.abs(dy) < 0.1 then dy = 0 end

					if math.abs(dx) > 1e-6 or math.abs(dy) > 1e-6 then
						local shouldDodgeBackwards
						if math.abs(forwardSpeed_UU) < 100 then
							shouldDodgeBackwards = dx < 0
						else
							shouldDodgeBackwards = (dx >= 0) ~= (forwardSpeed_UU >= 0)
						end
						local ix, iy = dx * C.FLIP_INITIAL_VEL_SCALE, dy * C.FLIP_INITIAL_VEL_SCALE
						local maxSpeedScaleX = if shouldDodgeBackwards then C.FLIP_BACKWARD_IMPULSE_MAX_SPEED_SCALE else C.FLIP_FORWARD_IMPULSE_MAX_SPEED_SCALE
						ix *= ((maxSpeedScaleX - 1) * forwardSpeedRatio) + 1
						iy *= ((C.FLIP_SIDE_IMPULSE_MAX_SPEED_SCALE - 1) * forwardSpeedRatio) + 1
						if shouldDodgeBackwards then
							ix *= C.FLIP_BACKWARD_IMPULSE_SCALE_X
						end
						local f2 = Vector3.new(b.fwd.X, b.fwd.Y, 0)
						f2 = if f2.Magnitude > 1e-9 then f2.Unit else Vector3.xAxis
						local r2 = Vector3.new(-f2.Y, f2.X, 0)
						local finalDeltaVel = f2 * ix + r2 * iy
						RigidBody.ApplyCentralImpulse(b, finalDeltaVel * (UU * C.CAR_MASS_BT))
					end
				else
					RigidBody.ApplyCentralImpulse(b, b.up * (C.JUMP_IMMEDIATE_FORCE * UU * C.CAR_MASS_BT))
					self.hasDoubleJumped = true
				end
			end
		end
	end

	if self.isFlipping then
		self.flipTime += dt
		if self.flipTime <= C.FLIP_TORQUE_TIME then
			if self.flipTime >= C.FLIP_Z_DAMP_START and (b.vel.Z < 0 or self.flipTime < C.FLIP_Z_DAMP_END) then
				b.vel = Vector3.new(b.vel.X, b.vel.Y, b.vel.Z * (1 - C.FLIP_Z_DAMP_120) ^ tickTimeScale)
			end
		end
	elseif self.hasFlipped then
		self.flipTime += dt
	end
end

local function updateAutoFlip(self: any, dt: number, jumpPressed: boolean)
	local b = self.body
	if jumpPressed and self.worldContact.hasContact and self.worldContact.contactNormal.Z > C.CAR_AUTOFLIP_NORMZ_THRESH then
		local roll = Q.rollFromBasis(b.fwd, b.right, b.up)
		local absRoll = math.abs(roll)
		if absRoll > C.CAR_AUTOFLIP_ROLL_THRESH then
			self.autoFlipTimer = C.CAR_AUTOFLIP_TIME * (absRoll / math.pi)
			self.autoFlipTorqueScale = if roll > 0 then 1 else -1
			self.isAutoFlipping = true
			RigidBody.ApplyCentralImpulse(b, -b.up * (C.CAR_AUTOFLIP_IMPULSE * UU * C.CAR_MASS_BT))
		end
	end
	if self.isAutoFlipping then
		if self.autoFlipTimer <= 0 then
			self.isAutoFlipping = false
			self.autoFlipTimer = 0
		else
			b.angVel += b.fwd * (C.CAR_AUTOFLIP_TORQUE * self.autoFlipTorqueScale * dt)
			self.autoFlipTimer -= dt
		end
	end
end

local function updateAutoRoll(self: any, dt: number, numWheelsInContact: number)
	local b = self.body
	local groundUpDir = if numWheelsInContact > 0 then getUpwardsDirFromWheelContacts(self) else self.worldContact.contactNormal
	local groundDownDir = -groundUpDir
	local forwardDir, rightDir = b.fwd, b.right
	local crossRightDir = groundUpDir:Cross(forwardDir)
	local crossForwardDir = groundDownDir:Cross(crossRightDir)
	local rightTorqueFactor = 1 - math.clamp(rightDir:Dot(crossRightDir), 0, 1)
	local forwardTorqueFactor = 1 - math.clamp(forwardDir:Dot(crossForwardDir), 0, 1)
	local torqueDirRight = forwardDir * (if rightDir:Dot(groundUpDir) >= 0 then -1 else 1)
	local torqueDirForward = rightDir * (if forwardDir:Dot(groundUpDir) >= 0 then 1 else -1)
	local torqueRight = torqueDirRight * rightTorqueFactor
	local torqueForward = torqueDirForward * forwardTorqueFactor
	RigidBody.ApplyCentralForce(b, groundDownDir * (C.CAR_AUTOROLL_FORCE * UU * C.CAR_MASS_BT))
	RigidBody.ApplyTorque(b, RigidBody.InertiaWorld(b, (torqueForward + torqueRight) * C.CAR_AUTOROLL_TORQUE))
end

-- Car::_PreTickUpdate
function CarPhysics.PreTickUpdate(self: any, dt: number, world: any)
	local c = self.controls
	c.throttle = math.clamp(c.throttle, -1, 1)
	c.steer = math.clamp(c.steer, -1, 1)
	c.pitch = math.clamp(c.pitch, -1, 1)
	c.yaw = math.clamp(c.yaw, -1, 1)
	c.roll = math.clamp(c.roll, -1, 1)

	if self.isDemoed then
		self.demoRespawnTimer = math.max(self.demoRespawnTimer - dt, 0)
		if self.demoRespawnTimer == 0 and world then
			world:RespawnCar(self)
		end
		return
	end

	-- updateVehicleFirst
	for _, w in self.wheels do
		updateWheelTransform(self, w)
	end
	for _, w in self.wheels do
		rayCast(self, w, world, dt)
	end
	calcFrictionImpulses(self, dt)

	local jumpPressed = c.jump and not self.lastControls.jump
	local numWheelsInContact = 0
	for i, w in self.wheels do
		self.wheelsWithContact[i] = w.isInContact
		if w.isInContact then
			numWheelsInContact += 1
		end
	end
	self.isOnGround = numWheelsInContact >= 3
	self.numWheelsInContact = numWheelsInContact

	local forwardSpeed_UU = self.body.vel:Dot(self.body.fwd) * BT
	updateWheels(self, dt, numWheelsInContact, forwardSpeed_UU)

	if numWheelsInContact < 3 then
		updateAirTorque(self, dt, numWheelsInContact == 0)
	else
		self.isFlipping = false
	end

	updateJump(self, dt, jumpPressed)
	updateAutoFlip(self, dt, jumpPressed)
	updateDoubleJumpOrFlip(self, dt, jumpPressed, forwardSpeed_UU)

	if c.throttle ~= 0 and ((numWheelsInContact > 0 and numWheelsInContact < 4) or self.worldContact.hasContact) then
		updateAutoRoll(self, dt, numWheelsInContact)
	end
	self.worldContact.hasContact = false

	-- updateVehicleSecond
	updateSuspension(self, dt)
	applyFrictionImpulses(self, dt)

	updateBoost(self, dt)
end

-- Car::_PostTickUpdate
function CarPhysics.PostTickUpdate(self: any, dt: number)
	if self.isDemoed then
		return
	end
	local speed = self.body.vel.Magnitude * BT
	if self.isSupersonic and self.supersonicTime < C.SUPERSONIC_MAINTAIN_MAX_TIME then
		self.isSupersonic = speed >= C.SUPERSONIC_MAINTAIN_MIN_SPEED
	else
		self.isSupersonic = speed >= C.SUPERSONIC_START_SPEED
	end
	if self.isSupersonic then
		self.supersonicTime += dt
	else
		self.supersonicTime = 0
	end
	if self.carContact.cooldownTimer > 0 then
		self.carContact.cooldownTimer = math.max(self.carContact.cooldownTimer - dt, 0)
	end
	self.lastControls = copyControls(self.controls)

	-- visual wheel spin (render only)
	for _, w in self.wheels do
		local rollVel = if w.isInContact then (self.body.vel + self.body.angVel:Cross(w.hardPoint - self.body.pos)):Dot(w.fwdDir) else 0
		w.spin = (w.spin + rollVel / w.radius * dt) % (2 * math.pi)
	end
end

-- Car::_FinishPhysicsTick
function CarPhysics.FinishPhysicsTick(self: any)
	if self.isDemoed then
		return
	end
	local b = self.body
	if self.velocityImpulseCache ~= Vector3.zero then
		b.vel += self.velocityImpulseCache
		self.velocityImpulseCache = Vector3.zero
	end
	local maxV = C.CAR_MAX_SPEED * UU
	if b.vel:Dot(b.vel) > maxV * maxV then
		b.vel = b.vel.Unit * maxV
	end
	if b.angVel:Dot(b.angVel) > C.CAR_MAX_ANG_SPEED * C.CAR_MAX_ANG_SPEED then
		b.angVel = b.angVel.Unit * C.CAR_MAX_ANG_SPEED
	end
end

return CarPhysics
