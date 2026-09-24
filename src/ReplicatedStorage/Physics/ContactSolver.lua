--!strict
-- ContactSolver.lua
-- Port of the parts of Bullet's btSequentialImpulseConstraintSolver that RocketSim uses, including the
-- RocketSim changes:
--   * split impulse for penetration recovery with m_erp2 = 0.8 (position only, never adds velocity)
--   * no "velocityError -= penetration / dt" for separated contacts (keeps low-speed ball bounces clean)
--   * one velocity-dependent friction direction per contact, friction limited by the normal impulse
--   * 10 iterations, restitution velocity threshold 0.2 BT/s
-- Bodies are RigidBody tables. A contact's `b` may be nil for the static arena.
local C = require(script.Parent.PhysicsConstants)
local RigidBody = require(script.Parent.RigidBody)
local Q = require(script.Parent.Quaternion)

local Solver = {}

local invIW = RigidBody.InvInertiaWorld

local function planeSpace(n: Vector3): Vector3
	-- btPlaneSpace1 (first tangent)
	if math.abs(n.Z) > 0.70710678 then
		local a = n.Y * n.Y + n.Z * n.Z
		local k = 1 / math.sqrt(a)
		return Vector3.new(0, -n.Z * k, n.Y * k)
	end
	local a = n.X * n.X + n.Y * n.Y
	local k = 1 / math.sqrt(a)
	return Vector3.new(-n.Y * k, n.X * k, 0)
end

type Row = {
	A: any, B: any?,
	n1: Vector3, rc1: Vector3, ac1: Vector3, -- body A: contactNormal1, relpos1CrossNormal, angularComponentA
	n2: Vector3, rc2: Vector3, ac2: Vector3, -- body B
	jacInv: number, rhs: number, rhsPen: number,
	applied: number, appliedPush: number,
	lower: number, upper: number,
	friction: number,
	[string]: any,
}

local function sd(body: any, bodies: { [any]: any })
	return bodies[body]
end

-- Solve one tick. `bodies` is the list of dynamic bodies participating this tick.
function Solver.Solve(bodies: { any }, contacts: { any }, dt: number)
	-- convertBodies
	local S = {}
	for _, b in bodies do
		S[b] = {
			dLin = Vector3.zero, dAng = Vector3.zero,
			push = Vector3.zero, turn = Vector3.zero,
			extLin = b.totalForce * (b.invMass * dt),
			extAng = invIW(b, b.totalTorque) * dt,
		}
	end

	local normals: { Row } = {}
	local frictions: { Row } = {}

	for _, c in contacts do
		local A, B = c.a, c.b
		local sa = S[A]
		local sb = if B then S[B] else nil
		local n = c.normal
		local r1 = c.pointA - A.pos
		local r2 = if B then c.pointB - B.pos else Vector3.zero

		-- setupContactConstraint
		local torqueAxis0 = r1:Cross(n)
		local ac1 = invIW(A, torqueAxis0)
		local torqueAxis1 = r2:Cross(n)
		local ac2 = if B then invIW(B, -torqueAxis1) else Vector3.zero
		local denom0 = A.invMass + n:Dot(ac1:Cross(r1))
		local denom1 = if B then B.invMass + n:Dot((-ac2):Cross(r2)) else 0
		local jacInv = 1 / (denom0 + denom1)

		local penetration = c.dist
		local vel1 = A.vel + A.angVel:Cross(r1)
		local vel2 = if B then B.vel + B.angVel:Cross(r2) else Vector3.zero
		local relVel = n:Dot(vel1 - vel2)
		local restitution = 0
		if math.abs(relVel) >= C.SOLVER_RESTITUTION_VEL_THRESHOLD then
			restitution = c.restitution * -relVel
			if restitution <= 0 then
				restitution = 0
			end
		end

		local vel1Dotn = n:Dot(A.vel + sa.extLin) + torqueAxis0:Dot(A.angVel + sa.extAng)
		local vel2Dotn = 0
		if B then
			vel2Dotn = (-n):Dot(B.vel + sb.extLin) + (-torqueAxis1):Dot(B.angVel + sb.extAng)
		end
		local velocityError = restitution - (vel1Dotn + vel2Dotn)
		local positionalError = 0
		if penetration <= 0 then
			positionalError = -penetration * C.SOLVER_ERP2 / dt
		end

		local row: Row = {
			A = A, B = B,
			n1 = n, rc1 = torqueAxis0, ac1 = ac1,
			n2 = -n, rc2 = -torqueAxis1, ac2 = ac2,
			jacInv = jacInv,
			rhs = velocityError * jacInv,
			rhsPen = positionalError * jacInv,
			applied = 0, appliedPush = 0,
			lower = 0, upper = 1e10,
			friction = c.friction,
			special = c.special,
			contact = c,
		}
		table.insert(normals, row)

		-- Warm starting (SOLVER_USE_WARMSTARTING): a persistent manifold point starts from its previous impulse
		if c.warm and c.warm > 0 then
			local w = c.warm * C.SOLVER_WARMSTARTING_FACTOR
			row.applied = w
			sa.dLin += n * (A.invMass * w)
			sa.dAng += ac1 * w
			if B then
				sb.dLin += -n * (B.invMass * w)
				sb.dAng += ac2 * w
			end
		end

		-- friction direction (velocity dependent), using velocities with external impulses but no deltas
		local v1 = A.vel + sa.extLin + (A.angVel + sa.extAng):Cross(r1)
		local v2 = if B then B.vel + sb.extLin + (B.angVel + sb.extAng):Cross(r2) else Vector3.zero
		local vel = v1 - v2
		local rv = n:Dot(vel)
		local lat = vel - n * rv
		local dir: Vector3
		if lat:Dot(lat) > 1.1920929e-07 then
			dir = lat.Unit
		else
			dir = planeSpace(n)
		end
		local frc1 = r1:Cross(dir)
		local fac1 = invIW(A, frc1)
		local frc2 = -(r2:Cross(dir))
		local fac2 = if B then invIW(B, frc2) else Vector3.zero
		local fden0 = A.invMass + dir:Dot(fac1:Cross(r1))
		local fden1 = if B then B.invMass + dir:Dot((-fac2):Cross(r2)) else 0
		local fJacInv = 1 / (fden0 + fden1)
		local fv1 = dir:Dot(A.vel + sa.extLin) + frc1:Dot(A.angVel)
		local fv2 = if B then (-dir):Dot(B.vel + sb.extLin) + frc2:Dot(B.angVel) else 0
		table.insert(frictions, {
			A = A, B = B,
			n1 = dir, rc1 = frc1, ac1 = fac1,
			n2 = -dir, rc2 = frc2, ac2 = fac2,
			jacInv = fJacInv,
			rhs = (0 - (fv1 + fv2)) * fJacInv,
			rhsPen = 0,
			applied = 0, appliedPush = 0,
			lower = 0, upper = 0,
			friction = c.friction,
			normalRow = row,
		})
	end

	-- Split impulse iterations (position correction only)
	for _ = 1, C.SOLVER_ITERATIONS do
		local residual = 0
		for _, row in normals do
			if row.rhsPen ~= 0 then
				local sa = S[row.A]
				local sb = if row.B then S[row.B] else nil
				local delta = row.rhsPen
				local dv1 = row.n1:Dot(sa.push) + row.rc1:Dot(sa.turn)
				local dv2 = if sb then row.n2:Dot(sb.push) + row.rc2:Dot(sb.turn) else 0
				delta -= dv1 * row.jacInv
				delta -= dv2 * row.jacInv
				local sum = row.appliedPush + delta
				if sum < row.lower then
					delta = row.lower - row.appliedPush
					row.appliedPush = row.lower
				else
					row.appliedPush = sum
				end
				sa.push += row.n1 * (row.A.invMass * delta)
				sa.turn += row.ac1 * delta
				if sb then
					sb.push += row.n2 * (row.B.invMass * delta)
					sb.turn += row.ac2 * delta
				end
				residual = math.max(residual, delta * delta)
			end
		end
		if residual <= 0 then
			break
		end
	end

	-- Velocity iterations
	local function solveRow(row: Row)
		local sa = S[row.A]
		local sb = if row.B then S[row.B] else nil
		local delta = row.rhs
		local dv1 = row.n1:Dot(sa.dLin) + row.rc1:Dot(sa.dAng)
		local dv2 = if sb then row.n2:Dot(sb.dLin) + row.rc2:Dot(sb.dAng) else 0
		delta -= dv1 * row.jacInv
		delta -= dv2 * row.jacInv
		local sum = row.applied + delta
		if sum < row.lower then
			delta = row.lower - row.applied
			row.applied = row.lower
		elseif sum > row.upper then
			delta = row.upper - row.applied
			row.applied = row.upper
		else
			row.applied = sum
		end
		sa.dLin += row.n1 * (row.A.invMass * delta)
		sa.dAng += row.ac1 * delta
		if sb then
			sb.dLin += row.n2 * (row.B.invMass * delta)
			sb.dAng += row.ac2 * delta
		end
	end

	for _ = 1, C.SOLVER_ITERATIONS do
		for _, row in normals do
			-- RocketSim: "special" (ball-world) manifold points only take part in penetration recovery;
			-- their velocity response comes from the single averaged contact built by the caller.
			if not (row :: any).special then
				solveRow(row)
			end
		end
		for _, row in frictions do
			local total = row.normalRow.applied
			if total > 0 then
				row.lower = -row.friction * total
				row.upper = row.friction * total
				solveRow(row)
			end
		end
	end

	-- Write back velocities, then split-impulse position correction
	for b, s in S do
		b.vel = b.vel + s.dLin + s.extLin
		b.angVel = b.angVel + s.dAng + s.extAng
		if s.push ~= Vector3.zero or s.turn ~= Vector3.zero then
			b.pos += s.push * dt
			RigidBody.SetRotation(b, Q.integrate(b.rot, s.turn * C.SOLVER_SPLIT_IMPULSE_TURN_ERP, dt))
		end
	end

	return normals
end

-- Integrate positions/orientations with the solved velocities (btDiscreteDynamicsWorld::integrateTransforms)
function Solver.Integrate(b: any, dt: number)
	b.pos += b.vel * dt
	RigidBody.SetRotation(b, Q.integrate(b.rot, b.angVel, dt))
end

-- resolveSingleCollision (btContactConstraint.cpp): used by the vehicle for wheel "extra pushback"
function Solver.ResolveSingleCollision(body: any, contactPos: Vector3, normal: Vector3, distance: number, dt: number): number
	local relPos = contactPos - body.pos
	local vel = body.vel + body.angVel:Cross(relPos)
	local relVel = normal:Dot(vel)
	local positionalError = C.SOLVER_ERP * -distance / dt
	local velocityError = -relVel
	local denom = RigidBody.ImpulseDenominator(body, contactPos, normal)
	local jacInv = 1 / denom
	local impulse = (positionalError + velocityError) * jacInv
	return if impulse < 0 then 0 else impulse
end

-- resolveSingleBilateral: sideways wheel friction impulse against a (possibly dynamic) ground body
function Solver.ResolveSingleBilateral(body1: any, pos1: Vector3, body2: any?, pos2: Vector3, normal: Vector3): number
	if normal:Dot(normal) > 1.1 then
		return 0
	end
	local r1 = pos1 - body1.pos
	local vel1 = body1.vel + body1.angVel:Cross(r1)
	local vel2 = Vector3.zero
	local diag = body1.invMass
	local aJ = RigidBody.ToLocal(body1, r1:Cross(normal))
	diag += (aJ * body1.invInertiaLocal):Dot(aJ)
	if body2 then
		local r2 = pos2 - body2.pos
		vel2 = body2.vel + body2.angVel:Cross(r2)
		local bJ = RigidBody.ToLocal(body2, r2:Cross(-normal))
		diag += body2.invMass + (bJ * body2.invInertiaLocal):Dot(bJ)
	end
	local relVel = normal:Dot(vel1 - vel2)
	return -C.BILATERAL_CONTACT_DAMPING * relVel * (1 / diag)
end

return Solver
