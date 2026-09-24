--!strict
-- ArenaCollision.lua
-- Standard Soccar arena as an exact distance field built from convex solids.
--
-- RocketSim loads the arena triangle meshes dumped from the game (collision_meshes/*.cmf). Those files
-- are Psyonix assets and are not part of the RocketSim source, so this arena is rebuilt analytically
-- from the published dimensions (RLBot "Useful Game Values"):
--   floor z=0, ceiling z=2044, side walls x=+-4096, back walls y=+-5120,
--   45 deg corner planes |x|+|y|=8064, goals 892.755 half-width x 642.775 high x 880 deep.
-- The goal chamber is RL's, not a box: a quarter-pipe back and a sloped roof (see "Goal chambers" below).
-- The curved transitions use a single radius (ARENA_RAMP_RADIUS). Real RL uses a mesh, so ramp shape is the
-- one approximation in the whole physics stack.
--
-- Every primitive is a solid; the ball/cars live outside all of them. The distance to the arena is the min over
-- solids, which is exact for points in free space. Distances/normals are in UU; normals point into free space.

local C = require(script.Parent.PhysicsConstants)

local ArenaCollision = {}

type Prim = { kind: string, [string]: any }
local prims: { Prim } = {}

local EX, EY, H = C.ARENA_EXTENT_X, C.ARENA_EXTENT_Y, C.ARENA_HEIGHT
local CS = C.ARENA_CORNER_SUM
local R = C.ARENA_RAMP_RADIUS
local GW, GH, GD = C.GOAL_HALF_WIDTH, C.GOAL_HEIGHT, C.GOAL_DEPTH
local SQ2 = math.sqrt(2)
local HUGE = 1e9

-- Half-space solid: points with p.n < off are solid; n points into free space.
local function plane(n: Vector3, off: number)
	table.insert(prims, { kind = "plane", n = n.Unit, off = off })
end

-- Axis-aligned box solid
local function box(minP: Vector3, maxP: Vector3)
	table.insert(prims, { kind = "box", c = (minP + maxP) / 2, h = (maxP - minP) / 2 })
end

-- Convex solid = intersection of half-spaces { n (free-space normal), off }: solid where p.n < off for all.
-- Distance = the largest plane distance (exact across faces, a slight underestimate near its edges).
local function hull(planes: { any })
	for _, pl in planes do pl.n = pl.n.Unit end
	table.insert(prims, { kind = "hull", planes = planes })
end

-- Concave fillet between two solids whose free-space normals are n1, n2 (both perpendicular to axis).
-- c0 = a point on the fillet cylinder axis, axis = unit direction, [t0, t1] = extent along the axis.
local function fillet(c0: Vector3, axis: Vector3, t0: number, t1: number, n1: Vector3, n2: Vector3, r: number)
	local u1, u2 = -n1.Unit, -n2.Unit
	table.insert(prims, { kind = "fillet", c = c0, a = axis.Unit, t0 = t0, t1 = t1, u1 = u1, u2 = u2, g = u1:Dot(u2), r = r })
end

-- ===== Planes =====
plane(Vector3.new(0, 0, 1), 0) -- floor
plane(Vector3.new(0, 0, -1), -H) -- ceiling
plane(Vector3.new(-1, 0, 0), -EX) -- +x side wall
plane(Vector3.new(1, 0, 0), -EX) -- -x side wall
for _, sx in { 1, -1 } do
	for _, sy in { 1, -1 } do
		plane(Vector3.new(-sx, -sy, 0), -CS / SQ2) -- corner planes
	end
end
plane(Vector3.new(0, -1, 0), -(EY + GD)) -- goal back (+y)
plane(Vector3.new(0, 1, 0), -(EY + GD)) -- goal back (-y)

-- ===== Back walls with the goal cut-out =====
for _, sy in { 1, -1 } do
	local y0, y1 = if sy > 0 then EY else -EY - 4000, if sy > 0 then EY + 4000 else -EY
	box(Vector3.new(GW, y0, -4000), Vector3.new(EX + 4000, y1, H + 4000)) -- beside goal (+x)
	box(Vector3.new(-EX - 4000, y0, -4000), Vector3.new(-GW, y1, H + 4000)) -- beside goal (-x)
	box(Vector3.new(-GW, y0, GH), Vector3.new(GW, y1, H + 4000)) -- above crossbar
end

-- ===== Goal chambers =====
-- Profile fitted to RL's own collision mesh (depth d behind the goal line, height z): flat floor to d = 624, then a
-- quarter-pipe back (r = 256, centre d = 624, z = 256) that runs up the back of the net and curls forward past
-- vertical to 63.7 deg, then a roof sloping up to crossbar height 224 uu behind the goal line, then the flat lintel
-- to the mouth. A ball or car going in fast rides up the back and along the roof, like in RL.
local GB_R, GB_D, GB_Z = 256, 624, 256
local GB_END = math.atan2(477 - 256, 733 - 624) -- where the back curve hands over to the roof
local ROOF_FRONT_D = 224
local GB_END_D, GB_END_Z = GB_D + GB_R * math.cos(GB_END), GB_Z + GB_R * math.sin(GB_END)
local ROOF_SLOPE = (GH - GB_END_Z) / (GB_END_D - ROOF_FRONT_D) -- rise per uu toward the mouth
ArenaCollision.GoalProfile = {
	backR = GB_R, backD = GB_D, backZ = GB_Z, backEnd = GB_END, roofFrontD = ROOF_FRONT_D,
	endD = GB_END_D, endZ = GB_END_Z, slope = ROOF_SLOPE,
}
for _, sy in { 1, -1 } do
	-- quarter-pipe back: concave arc from the floor, round the back of the net, up to where the roof starts
	local toEnd = Vector3.new(0, sy * math.cos(GB_END), math.sin(GB_END))
	fillet(Vector3.new(0, sy * (EY + GB_D), GB_Z), Vector3.xAxis, -GW, GW, Vector3.zAxis, -toEnd, GB_R)
	prims[#prims].goal = sy
	-- sloped roof: solid above the line from the arc's end up to the crossbar height, between the goal line and it
	local L = math.sqrt(1 + ROOF_SLOPE * ROOF_SLOPE)
	local K = GH + ROOF_SLOPE * ROOF_FRONT_D
	hull({
		{ n = Vector3.new(0, -sy * ROOF_SLOPE, -1), off = -(K + ROOF_SLOPE * EY) / L },
		{ n = Vector3.new(0, -sy, 0), off = -EY },
		{ n = Vector3.new(0, sy, 0), off = EY + GB_END_D },
	})
	prims[#prims].goal = sy
	-- behind the roof, above the end of the curve
	if sy > 0 then
		box(Vector3.new(-GW, EY + GB_END_D, GB_END_Z), Vector3.new(GW, EY + 4000, H + 4000))
	else
		box(Vector3.new(-GW, -EY - 4000, GB_END_Z), Vector3.new(GW, -EY - GB_END_D, H + 4000))
	end
end

-- ===== Fillets (curved ramps) =====
local up, down = Vector3.zAxis, -Vector3.zAxis
local sideLen = CS - EX -- side wall spans |y| <= 3968
local backLen = CS - EY -- back wall spans |x| <= 2944
local cornerHalf = (EX - backLen) * SQ2 / 2 -- half length of a corner plane

for _, sx in { 1, -1 } do
	local nWall = Vector3.new(-sx, 0, 0)
	-- floor / ceiling <-> side wall
	fillet(Vector3.new(sx * (EX - R), 0, R), Vector3.yAxis, -sideLen, sideLen, up, nWall, R)
	fillet(Vector3.new(sx * (EX - R), 0, H - R), Vector3.yAxis, -sideLen, sideLen, down, nWall, R)
end

for _, sy in { 1, -1 } do
	local nBack = Vector3.new(0, -sy, 0)
	-- floor <-> back wall (only beside the goal mouth)
	for _, sx in { 1, -1 } do
		local mid = sx * (GW + backLen) / 2
		local half = (backLen - GW) / 2
		fillet(Vector3.new(mid, sy * (EY - R), R), Vector3.xAxis, -half, half, up, nBack, R)
	end
	-- ceiling <-> back wall (full width)
	fillet(Vector3.new(0, sy * (EY - R), H - R), Vector3.xAxis, -backLen, backLen, down, nBack, R)
end

for _, sx in { 1, -1 } do
	for _, sy in { 1, -1 } do
		local nCorner = Vector3.new(-sx, -sy, 0).Unit
		local mid = Vector3.new(sx * (EX + backLen) / 2, sy * (sideLen + EY) / 2, 0)
		local along = Vector3.new(sx, -sy, 0).Unit
		local inward = nCorner * R
		-- floor / ceiling <-> corner plane
		fillet(mid + inward + Vector3.new(0, 0, R), along, -cornerHalf, cornerHalf, up, nCorner, R)
		fillet(mid + inward + Vector3.new(0, 0, H - R), along, -cornerHalf, cornerHalf, down, nCorner, R)
		-- vertical: side wall <-> corner plane (135 deg)
		local k = R * (SQ2 - 1)
		fillet(Vector3.new(sx * (EX - R), sy * (sideLen - k), 0), Vector3.zAxis, 0, H, Vector3.new(-sx, 0, 0), nCorner, R)
		-- vertical: back wall <-> corner plane (135 deg)
		fillet(Vector3.new(sx * (backLen - k), sy * (EY - R), 0), Vector3.zAxis, 0, H, Vector3.new(0, -sy, 0), nCorner, R)
	end
end

ArenaCollision.Primitives = prims
ArenaCollision.Boxes = {}
for _, pr in prims do
	if pr.kind == "box" then
		table.insert(ArenaCollision.Boxes, pr)
	end
end

-- Distance (UU) from p to one primitive, and the free-space normal there. Returns HUGE if not applicable.
local function primDist(pr: Prim, p: Vector3): (number, Vector3)
	local kind = pr.kind
	if kind == "plane" then
		return p:Dot(pr.n) - pr.off, pr.n
	elseif kind == "box" then
		local d = p - pr.c
		local h = pr.h
		local ax, ay, az = math.abs(d.X), math.abs(d.Y), math.abs(d.Z)
		local qx, qy, qz = ax - h.X, ay - h.Y, az - h.Z
		if qx <= 0 and qy <= 0 and qz <= 0 then
			-- inside the solid: push out through the nearest face
			if qx >= qy and qx >= qz then
				return qx, Vector3.new(math.sign(d.X), 0, 0)
			elseif qy >= qz then
				return qy, Vector3.new(0, math.sign(d.Y), 0)
			end
			return qz, Vector3.new(0, 0, math.sign(d.Z))
		end
		local ox = math.max(qx, 0) * math.sign(d.X)
		local oy = math.max(qy, 0) * math.sign(d.Y)
		local oz = math.max(qz, 0) * math.sign(d.Z)
		local o = Vector3.new(ox, oy, oz)
		local m = o.Magnitude
		return m, o / m
	elseif kind == "hull" then
		local best, bestN = -HUGE, Vector3.zAxis
		for _, pl in pr.planes do
			local d = p:Dot(pl.n) - pl.off
			if d > best then
				best, bestN = d, pl.n
			end
		end
		return best, bestN
	else -- fillet
		local rel = p - pr.c
		local t = rel:Dot(pr.a)
		if t < pr.t0 or t > pr.t1 then
			return HUGE, Vector3.zAxis
		end
		local q = rel - pr.a * t
		local q1, q2 = q:Dot(pr.u1), q:Dot(pr.u2)
		local g = pr.g
		local den = 1 - g * g
		local alpha = (q1 - g * q2) / den
		local beta = (q2 - g * q1) / den
		if alpha < 0 or beta < 0 then
			return HUGE, Vector3.zAxis
		end
		local m = q.Magnitude
		if m < 1e-6 then
			return pr.r, -(pr.u1 + pr.u2).Unit
		end
		return pr.r - m, -q / m
	end
end
ArenaCollision.PrimDist = primDist

-- Nearest solid: distance (UU, negative = penetrating) and free-space normal.
function ArenaCollision.Query(p: Vector3, skipBoxes: boolean?): (number, Vector3)
	local best, bestN = HUGE, Vector3.zAxis
	for i = 1, #prims do
		if skipBoxes and prims[i].kind == "box" then
			continue
		end
		local d, n = primDist(prims[i], p)
		if d < best then
			best, bestN = d, n
		end
	end
	return best, bestN
end

-- All solids closer than maxDist (used for multi-contact manifolds, e.g. the ball in a corner).
function ArenaCollision.QueryAll(p: Vector3, maxDist: number, out: { any }): number
	local count = 0
	for i = 1, #prims do
		local d, n = primDist(prims[i], p)
		if d < maxDist then
			count += 1
			out[count] = { d = d, n = n }
		end
	end
	return count
end

-- Ray cast (UU). Returns hit distance, hit point, normal, or nil. Sphere tracing on the exact distance field.
function ArenaCollision.RayCast(origin: Vector3, dir: Vector3, maxLen: number): (number?, Vector3?, Vector3?)
	local t = 0
	for _ = 1, 48 do
		local p = origin + dir * t
		local d, n = ArenaCollision.Query(p)
		if d <= 0.01 then
			if t == 0 and d < 0 then
				-- started inside a solid: report the surface right here
				return 0, p, n
			end
			return t, p, n
		end
		t += d
		if t > maxLen then
			return nil
		end
	end
	return nil
end

return ArenaCollision
