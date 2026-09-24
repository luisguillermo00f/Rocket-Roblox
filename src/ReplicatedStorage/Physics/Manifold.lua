--!strict
-- Manifold.lua: btPersistentManifold as RocketSim uses it.
--   * the narrow phase adds ONE new point per pair per tick (plane/sphere algorithms) or a few (box-box)
--   * RocketSim change: getCacheEntry() always returns -1, so new points never overwrite old ones; once 4 points
--     exist, sortCachedPoints() picks which one to replace (keeps the deepest, maximizes the contact area)
--   * refreshContactPoints(): every point is re-evaluated from its local anchors; it is dropped when it separates
--     beyond the breaking threshold or slides sideways more than the threshold
--   * surviving points keep their accumulated impulse, which the solver uses for warm starting
local RigidBody = require(script.Parent.RigidBody)

local Manifold = {}
Manifold.__index = Manifold

local MAX_POINTS = 4

export type Point = {
	localA: Vector3, localB: Vector3,
	normal: Vector3, dist: number,
	pointA: Vector3, pointB: Vector3,
	friction: number, restitution: number,
	applied: number,
	lifeTime: number,
}

function Manifold.new(threshold: number)
	return setmetatable({ points = {} :: { Point }, threshold = threshold }, Manifold)
end

local function toLocal(body: any?, p: Vector3): Vector3
	if body then
		return RigidBody.ToLocal(body, p - body.pos)
	end
	return p
end

local function toWorld(body: any?, l: Vector3): Vector3
	if body then
		return body.pos + RigidBody.ToWorld(body, l)
	end
	return l
end

local function calcArea4Points(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): number
	local a0, a1, a2 = p0 - p1, p0 - p2, p0 - p3
	local b0, b1, b2 = p2 - p3, p1 - p3, p1 - p2
	local t0, t1, t2 = a0:Cross(b0), a1:Cross(b1), a2:Cross(b2)
	return math.max(t0:Dot(t0), t1:Dot(t1), t2:Dot(t2))
end

-- btPersistentManifold::sortCachedPoints (gContactCalcArea3Points = true by default)
local function sortCachedPoints(pts: { Point }, np: Point): number
	local maxPenetrationIndex = -1
	local maxPenetration = np.dist
	for i = 1, 4 do
		if pts[i].dist < maxPenetration then
			maxPenetrationIndex = i
			maxPenetration = pts[i].dist
		end
	end
	local res = { 0, 0, 0, 0 }
	local l = np.localA
	if maxPenetrationIndex ~= 1 then
		local c = (l - pts[2].localA):Cross(pts[4].localA - pts[3].localA)
		res[1] = c:Dot(c)
	end
	if maxPenetrationIndex ~= 2 then
		local c = (l - pts[1].localA):Cross(pts[4].localA - pts[3].localA)
		res[2] = c:Dot(c)
	end
	if maxPenetrationIndex ~= 3 then
		local c = (l - pts[1].localA):Cross(pts[4].localA - pts[2].localA)
		res[3] = c:Dot(c)
	end
	if maxPenetrationIndex ~= 4 then
		local c = (l - pts[1].localA):Cross(pts[3].localA - pts[2].localA)
		res[4] = c:Dot(c)
	end
	-- btVector4::closestAxis4 (largest absolute component, first on ties)
	local best, bestV = 1, res[1]
	for i = 2, 4 do
		if res[i] > bestV then
			best, bestV = i, res[i]
		end
	end
	return best
end
Manifold.CalcArea4Points = calcArea4Points

-- btManifoldResult::addContactPoint. pointB = witness on B (world), normal = normalWorldOnB, dist = signed depth.
function Manifold.Add(self: any, A: any, B: any?, pointB: Vector3, normal: Vector3, dist: number, friction: number, restitution: number): Point?
	if dist > self.threshold then
		return nil
	end
	local pointA = pointB + normal * dist
	local np: Point = {
		localA = toLocal(A, pointA), localB = toLocal(B, pointB),
		normal = normal, dist = dist,
		pointA = pointA, pointB = pointB,
		friction = friction, restitution = restitution,
		applied = 0, lifeTime = 0,
	}
	local pts = self.points
	if #pts == MAX_POINTS then
		pts[sortCachedPoints(pts, np)] = np
	else
		table.insert(pts, np)
	end
	return np
end

-- btPersistentManifold::refreshContactPoints
function Manifold.Refresh(self: any, A: any, B: any?)
	local pts = self.points
	local thr = self.threshold
	for i = #pts, 1, -1 do
		local p = pts[i]
		p.pointA = toWorld(A, p.localA)
		p.pointB = toWorld(B, p.localB)
		p.dist = (p.pointA - p.pointB):Dot(p.normal)
		p.lifeTime += 1
	end
	for i = #pts, 1, -1 do
		local p = pts[i]
		local remove = p.dist > thr
		if not remove then
			local projected = p.pointA - p.normal * p.dist
			local d = p.pointB - projected
			remove = d:Dot(d) > thr * thr
		end
		if remove then
			-- removeContactPoint: swap with the last point
			pts[i] = pts[#pts]
			pts[#pts] = nil
		end
	end
end

-- Emit solver contacts for every point (warm-started with the stored impulse)
function Manifold.Emit(self: any, A: any, B: any?, out: { any })
	for _, p in self.points do
		table.insert(out, {
			a = A, b = B,
			pointA = p.pointA, pointB = p.pointB,
			normal = p.normal, dist = p.dist,
			friction = p.friction, restitution = p.restitution,
			warm = p.applied, mp = p,
		})
	end
end

return Manifold
