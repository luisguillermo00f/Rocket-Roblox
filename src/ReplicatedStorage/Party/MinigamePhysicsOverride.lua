--!strict
-- MinigamePhysicsOverride.lua: temporary, reversible physics overrides on ONE World instance.
-- Nothing global is touched: PhysicsConstants, BallPhysics and CarPhysics stay as they are. The override writes
-- per-instance fields that the World reads with RocketSim defaults when they are absent:
--   world.ballGravityScale, ball.body.mass / invMass / inertia, ball.body.linearDamping, ball.restitution
-- Apply() remembers the previous values; Restore() puts them back exactly.
local RS = game:GetService("ReplicatedStorage")
local RigidBody = require(RS.Physics.RigidBody)

local MinigamePhysicsOverride = {}

export type BallOverride = {
	gravityScale: number?,
	linearDamping: number?,
	restitution: number?,
	massScale: number?,
}

function MinigamePhysicsOverride.ApplyBall(world: any, o: BallOverride)
	assert(world._ballOverrideSaved == nil, "ball override already applied to this world")
	local ball = world.ball
	local b = ball.body
	world._ballOverrideSaved = {
		gravityScale = world.ballGravityScale,
		linearDamping = b.linearDamping,
		restitution = ball.restitution,
		mass = b.mass, invMass = b.invMass, inertiaLocal = b.inertiaLocal, invInertiaLocal = b.invInertiaLocal,
	}
	if o.gravityScale then world.ballGravityScale = o.gravityScale end
	if o.linearDamping then b.linearDamping = o.linearDamping end
	if o.restitution then ball.restitution = o.restitution end
	if o.massScale then
		local m = b.mass * o.massScale
		local inertia = RigidBody.SphereInertia(m, ball.radius)
		b.mass = m
		b.invMass = 1 / m
		b.inertiaLocal = inertia
		b.invInertiaLocal = Vector3.new(1 / inertia.X, 1 / inertia.Y, 1 / inertia.Z)
	end
end

function MinigamePhysicsOverride.RestoreBall(world: any)
	local s = world._ballOverrideSaved
	if not s then return end
	local ball = world.ball
	local b = ball.body
	world.ballGravityScale = s.gravityScale
	b.linearDamping = s.linearDamping
	ball.restitution = s.restitution
	b.mass, b.invMass, b.inertiaLocal, b.invInertiaLocal = s.mass, s.invMass, s.inertiaLocal, s.invInertiaLocal
	world._ballOverrideSaved = nil
end

return MinigamePhysicsOverride
