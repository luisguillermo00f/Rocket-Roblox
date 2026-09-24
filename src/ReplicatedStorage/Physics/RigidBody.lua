--!strict
-- RigidBody.lua: the subset of btRigidBody that RocketSim relies on. All values in Bullet units (BT).
-- Gyroscopic forces are disabled (RocketSim sets m_rigidbodyFlags = 0), damping is linear only.
local Q = require(script.Parent.Quaternion)

local RigidBody = {}
RigidBody.__index = RigidBody

export type RigidBody = {
	pos: Vector3,
	rot: Q.Quat,
	fwd: Vector3, right: Vector3, up: Vector3, -- world basis columns (rotation matrix)
	vel: Vector3,
	angVel: Vector3,
	mass: number,
	invMass: number,
	inertiaLocal: Vector3,
	invInertiaLocal: Vector3,
	linearDamping: number,
	totalForce: Vector3,
	totalTorque: Vector3,
	sleeping: boolean,
	[string]: any,
}

function RigidBody.new(mass: number, inertiaLocal: Vector3): RigidBody
	local self = setmetatable({
		pos = Vector3.zero,
		rot = Q.identity(),
		fwd = Vector3.xAxis, right = Vector3.yAxis, up = Vector3.zAxis,
		vel = Vector3.zero,
		angVel = Vector3.zero,
		mass = mass,
		invMass = if mass > 0 then 1 / mass else 0,
		inertiaLocal = inertiaLocal,
		invInertiaLocal = Vector3.new(
			if inertiaLocal.X ~= 0 then 1 / inertiaLocal.X else 0,
			if inertiaLocal.Y ~= 0 then 1 / inertiaLocal.Y else 0,
			if inertiaLocal.Z ~= 0 then 1 / inertiaLocal.Z else 0
		),
		linearDamping = 0,
		totalForce = Vector3.zero,
		totalTorque = Vector3.zero,
		sleeping = false,
	}, RigidBody)
	return (self :: any) :: RigidBody
end

-- btBoxShape::calculateLocalInertia
function RigidBody.BoxInertia(mass: number, halfExtents: Vector3): Vector3
	local lx, ly, lz = 2 * halfExtents.X, 2 * halfExtents.Y, 2 * halfExtents.Z
	return Vector3.new(mass / 12 * (ly * ly + lz * lz), mass / 12 * (lx * lx + lz * lz), mass / 12 * (lx * lx + ly * ly))
end

-- btSphereShape::calculateLocalInertia
function RigidBody.SphereInertia(mass: number, radius: number): Vector3
	local e = 0.4 * mass * radius * radius
	return Vector3.new(e, e, e)
end

function RigidBody.SetRotation(self: RigidBody, q: Q.Quat)
	self.rot = q
	self.fwd, self.right, self.up = Q.toBasis(q)
end

function RigidBody.ToLocal(self: RigidBody, v: Vector3): Vector3
	return Vector3.new(v:Dot(self.fwd), v:Dot(self.right), v:Dot(self.up))
end

function RigidBody.ToWorld(self: RigidBody, v: Vector3): Vector3
	return self.fwd * v.X + self.right * v.Y + self.up * v.Z
end

-- m_invInertiaTensorWorld * v
function RigidBody.InvInertiaWorld(self: RigidBody, v: Vector3): Vector3
	local l = RigidBody.ToLocal(self, v) * self.invInertiaLocal
	return RigidBody.ToWorld(self, l)
end

-- m_invInertiaTensorWorld.inverse() * v
function RigidBody.InertiaWorld(self: RigidBody, v: Vector3): Vector3
	local l = RigidBody.ToLocal(self, v) * self.inertiaLocal
	return RigidBody.ToWorld(self, l)
end

function RigidBody.VelAt(self: RigidBody, relPos: Vector3): Vector3
	return self.vel + self.angVel:Cross(relPos)
end

function RigidBody.ApplyCentralImpulse(self: RigidBody, j: Vector3)
	self.vel += j * self.invMass
end

function RigidBody.ApplyImpulse(self: RigidBody, j: Vector3, relPos: Vector3)
	self.vel += j * self.invMass
	self.angVel += RigidBody.InvInertiaWorld(self, relPos:Cross(j))
end

function RigidBody.ApplyCentralForce(self: RigidBody, f: Vector3)
	self.totalForce += f
end

function RigidBody.ApplyTorque(self: RigidBody, t: Vector3)
	self.totalTorque += t
end

-- btRigidBody::computeImpulseDenominator
function RigidBody.ImpulseDenominator(self: RigidBody, worldPos: Vector3, normal: Vector3): number
	local r = worldPos - self.pos
	local c0 = r:Cross(normal)
	local vec = RigidBody.InvInertiaWorld(self, c0):Cross(r)
	return self.invMass + normal:Dot(vec)
end

return RigidBody
