--!strict
-- BallPhysics.lua: port of RocketSim Ball.cpp (soccar sphere).
-- Rigid sphere, 30 kg, solid-sphere inertia, Bullet linear damping 0.03 (drag), max 6000 UU/s and 6 rad/s.
-- World contacts are "special": every manifold point only does penetration recovery, and one averaged contact
-- (average normal - NOT renormalized - and average lever arm) carries restitution 0.6 and friction 0.35.
-- Car hits add RocketSim's extra impulse (Ball::_OnHit) through a velocity cache applied after the tick.
local C = require(script.Parent.PhysicsConstants)
local Curve = require(script.Parent.LinearPieceCurve)
local RigidBody = require(script.Parent.RigidBody)
local Q = require(script.Parent.Quaternion)

local UU, BT = C.UU_TO_BT, C.BT_TO_UU

local BallPhysics = {}
BallPhysics.__index = BallPhysics

function BallPhysics.new()
	local radius = C.BALL_COLLISION_RADIUS_SOCCAR * UU
	local body = RigidBody.new(C.BALL_MASS_BT, RigidBody.SphereInertia(C.BALL_MASS_BT, radius))
	body.kind = "ball"
	body.linearDamping = C.BALL_DRAG
	local self = setmetatable({
		body = body,
		radius = radius,
		velocityImpulseCache = Vector3.zero,
		lastHitCarId = 0,
	}, BallPhysics)
	BallPhysics.SetState(self, Vector3.new(0, 0, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
	return self
end

function BallPhysics.SetState(self: any, posUU: Vector3, velUU: Vector3, angVel: Vector3, rot: Q.Quat?)
	local b = self.body
	b.pos = posUU * UU
	b.vel = velUU * UU
	b.angVel = angVel
	RigidBody.SetRotation(b, rot or Q.identity())
	self.velocityImpulseCache = Vector3.zero
end

function BallPhysics.GetPosUU(self: any): Vector3 return self.body.pos * BT end
function BallPhysics.GetVelUU(self: any): Vector3 return self.body.vel * BT end

-- Ball::_OnHit extra impulse. Called once per tick while a car touches the ball.
function BallPhysics.OnHit(self: any, car: any, tickCount: number)
	local info = car.ballHitInfo
	info.isValid = true
	info.tickCountWhenHit = tickCount
	info.ballPos = self.body.pos * BT
	info.extraHitVel = Vector3.zero
	self.lastHitCarId = car.id

	-- Once an extra impulse is applied, wait at least 1 tick before applying another
	if tickCount > info.tickCountWhenExtraImpulseApplied + 1 or info.tickCountWhenExtraImpulseApplied > tickCount then
		info.tickCountWhenExtraImpulseApplied = tickCount
		local carForward = car.body.fwd
		local relPos = (self.body.pos - car.body.pos) * BT
		local relVel = (self.body.vel - car.body.vel) * BT
		local relSpeed = math.min(relVel.Magnitude, C.BALL_CAR_EXTRA_IMPULSE_MAXDELTAVEL_UU)
		if relSpeed > 0 then
			local hitDir = (relPos * Vector3.new(1, 1, C.BALL_CAR_EXTRA_IMPULSE_Z_SCALE)).Unit
			local forwardDirAdjustment = carForward * (hitDir:Dot(carForward) * (1 - C.BALL_CAR_EXTRA_IMPULSE_FORWARD_SCALE))
			hitDir = (hitDir - forwardDirAdjustment).Unit
			local addedVel = hitDir * relSpeed * Curve.BALL_CAR_EXTRA_IMPULSE_FACTOR:GetOutput(relSpeed)
			info.extraHitVel = addedVel
			self.velocityImpulseCache += addedVel * UU
		end
	end
end

-- Ball::_FinishPhysicsTick
function BallPhysics.FinishPhysicsTick(self: any)
	local b = self.body
	if self.velocityImpulseCache ~= Vector3.zero then
		b.vel += self.velocityImpulseCache
		self.velocityImpulseCache = Vector3.zero
	end
	local maxV = C.BALL_MAX_SPEED * UU
	if b.vel:Dot(b.vel) > maxV * maxV then
		b.vel = b.vel.Unit * maxV
	end
	if b.angVel:Dot(b.angVel) > C.BALL_MAX_ANG_SPEED * C.BALL_MAX_ANG_SPEED then
		b.angVel = b.angVel.Unit * C.BALL_MAX_ANG_SPEED
	end
end

-- Build the ball-world contacts exactly like RocketSim's special resolution.
function BallPhysics.WorldContacts(self: any, list: { any }, out: { any })
	if #list == 0 then
		return
	end
	local b = self.body
	local totalNormal = Vector3.zero
	local totalDist = 0
	for _, s in list do
		table.insert(out, {
			a = b, b = nil,
			pointA = b.pos - s.normal * self.radius, pointB = s.pointB,
			normal = s.normal, dist = s.dist,
			friction = C.BALL_FRICTION, restitution = self.restitution or C.BALL_RESTITUTION,
			special = true,
		})
		totalNormal += s.normal
		totalDist += self.radius
	end
	local num = #list
	local normal = totalNormal / num
	local distance = totalDist / num
	table.insert(out, {
		a = b, b = nil,
		pointA = b.pos + normal * -distance, pointB = Vector3.zero,
		normal = normal, dist = distance,
		friction = C.BALL_FRICTION, restitution = self.restitution or C.BALL_RESTITUTION,
		special = false,
	})
end

return BallPhysics
