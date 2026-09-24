--!strict
-- SkyRingRushShared.lua: Sky Ring Rush rules shared by the server (authoritative) and the client (prediction +
-- visuals). Units: UU, sim axes (x across, y along, z up). Standard arena, no ball, no pads, unlimited boost.
--
-- A race through rings in order, on a route generated fresh for every match (Generate(seed)). Each checkpoint is one or
-- two rings (the second one is a shortcut: a higher, more direct line that asks for an aerial); passing either counts.
-- A ring is an oriented box (OBB): the ring's plane, RING_THICK thick, RING_R wide. The server tests the segment a car
-- travelled during the tick against the box (swept, so a fast car can't skip through it between two ticks).
local SK = {}

SK.Id = "sky_ring_rush"
SK.MAX_TIME = 75
SK.GRACE = 15 -- s left for everyone once the first car finishes
SK.RING_R = 270 -- inner radius (uu)
SK.RING_THICK = 70 -- half thickness of the checkpoint box along its normal
SK.CAR_TOL = 35 -- the car's hitbox counts: a pass within this of the rim still counts

-- A new route every match. From a random start (either end of the field, facing the other), walk forward in legs of
-- 1500-2600 uu with gentle turns (steering back toward the middle near the walls), dropping a ring at the end of each
-- leg facing the direction of travel. Required rings stay jump-height (170-400); about a third of the checkpoints
-- also get a shortcut ring high above the line (an aerial) that counts the same. Rings never crowd each other.
SK.GEN = {
	COUNT_MIN = 12, COUNT_MAX = 14,
	LEG_MIN = 1500, LEG_MAX = 2600,
	TURN_MAX = 1.05, -- rad per leg (up to 1.7 when a wall is ahead)
	BOUND = Vector2.new(3000, 4100), -- ring centres stay inside this (walls and corner ramps beyond)
	SPACING = 1300, -- min distance between any two rings (except the leg just flown)
	HEIGHTS = { 170, 170, 220, 280, 330, 380 },
	SHORTCUT_CHANCE = 0.33,
}

function SK.Generate(seed: number): any
	local g = SK.GEN
	local rng = Random.new(seed)
	local fromBlue = rng:NextNumber() < 0.5
	local sy = if fromBlue then -1 else 1
	local startPos = Vector3.new(rng:NextNumber(-600, 600), sy * 4300, 17)
	local heading = if fromBlue then math.pi / 2 else -math.pi / 2
	local checkpoints = {}
	local placed = {}
	local p = Vector2.new(startPos.X, startPos.Y)
	local count = rng:NextInteger(g.COUNT_MIN, g.COUNT_MAX)
	for k = 1, count do
		local best, bestH, bestScore = nil, heading, -math.huge
		for attempt = 1, 60 do
			-- gentle turns first; if nothing fits (a wall ahead), allow sharper turns and shorter legs; last resort
			-- (boxed into a corner): head back toward the middle
			local wide = attempt > 24
			local spread = if wide then 1.7 else g.TURN_MAX
			local turn = rng:NextNumber(-spread, spread)
			if k == 1 then turn *= 0.3 end
			local h = heading + turn
			if attempt > 48 then
				h = math.atan2(-p.Y, -p.X) + rng:NextNumber(-0.5, 0.5)
				turn = math.atan2(math.sin(h - heading), math.cos(h - heading))
			end
			local len = if k == 1 then rng:NextNumber(1300, 1700) elseif wide then rng:NextNumber(1200, 1900) else rng:NextNumber(g.LEG_MIN, g.LEG_MAX)
			local c = p + Vector2.new(math.cos(h), math.sin(h)) * len
			local inside = math.abs(c.X) <= g.BOUND.X and math.abs(c.Y) <= g.BOUND.Y
			local near = math.huge
			for i = 1, #placed - 1 do near = math.min(near, (placed[i] - c).Magnitude) end
			-- must be inside and spaced out; then prefer room ahead (not facing a wall) and gentle turns
			local ahead = c + Vector2.new(math.cos(h), math.sin(h)) * 1500
			local room = if math.abs(ahead.X) <= g.BOUND.X + 600 and math.abs(ahead.Y) <= g.BOUND.Y + 600 then 1 else 0
			local score = (if inside then 100 else 0) + (if near >= g.SPACING then 50 else near / g.SPACING * 20)
				+ room * 30 - math.abs(turn) * 3 + rng:NextNumber(0, 2)
			if score > bestScore then best, bestH, bestScore = c, h, score end
			if attempt >= 24 and bestScore >= 170 then break end -- found a good one (inside, spaced, room ahead)
		end
		local c = best :: Vector2
		c = Vector2.new(math.clamp(c.X, -g.BOUND.X, g.BOUND.X), math.clamp(c.Y, -g.BOUND.Y, g.BOUND.Y))
		local travel = c - p
		local dir = if travel.Magnitude > 1 then travel.Unit else Vector2.new(math.cos(bestH), math.sin(bestH))
		local z = g.HEIGHTS[rng:NextInteger(1, #g.HEIGHTS)]
		local n = Vector3.new(dir.X, dir.Y, 0).Unit
		local cp = { { c = Vector3.new(c.X, c.Y, z), n = n } }
		-- shortcut: high above the leg's second half, a bit off the line; flying there cuts the corner
		if k > 1 and k < count and rng:NextNumber() < g.SHORTCUT_CHANCE then
			local side = Vector2.new(-dir.Y, dir.X) * rng:NextNumber(-450, 450)
			local sc = p:Lerp(c, rng:NextNumber(0.55, 0.8)) + side
			sc = Vector2.new(math.clamp(sc.X, -g.BOUND.X, g.BOUND.X), math.clamp(sc.Y, -g.BOUND.Y, g.BOUND.Y))
			table.insert(cp, { c = Vector3.new(sc.X, sc.Y, rng:NextNumber(850, 1150)), n = (n + Vector3.new(0, 0, rng:NextNumber(-0.1, 0.15))).Unit })
		end
		table.insert(checkpoints, cp)
		table.insert(placed, c)
		p = c
		heading = math.atan2(dir.Y, dir.X)
	end
	return {
		name = string.format("%04d", seed % 10000),
		seed = seed,
		start = { pos = startPos, yaw = if fromBlue then math.pi / 2 else -math.pi / 2 },
		checkpoints = checkpoints,
	}
end

function SK.WorldOptions(): any
	return { boostPads = false, seed = 1 }
end

-- start grid for n cars behind the start line
function SK.StartSlots(route: any, n: number): { { pos: Vector3, yaw: number } }
	local out = {}
	local xs = if n <= 1 then { 0 } elseif n == 2 then { -300, 300 } elseif n == 3 then { -500, 0, 500 } else { -750, -250, 250, 750 }
	for i = 1, n do
		table.insert(out, { pos = route.start.pos + Vector3.new(xs[i], 0, 0), yaw = route.start.yaw })
	end
	return out
end

-- orthonormal frame of a ring: n (normal) and two in-plane axes
function SK.RingAxes(r: any): (Vector3, Vector3, Vector3)
	local n = r.n
	local ref = if math.abs(n.Z) < 0.9 then Vector3.zAxis else Vector3.xAxis
	local u = ref:Cross(n).Unit
	local v = n:Cross(u)
	return n, u, v
end

-- swept segment p0 -> p1 against the ring's box (slab test in the ring frame). Returns true on a pass.
function SK.SweptPass(r: any, p0: Vector3, p1: Vector3): boolean
	local n, u, v = SK.RingAxes(r)
	local ext = { SK.RING_THICK, SK.RING_R + SK.CAR_TOL, SK.RING_R + SK.CAR_TOL }
	local axes = { n, u, v }
	local d0 = p0 - r.c
	local d = p1 - p0
	local tmin, tmax = 0, 1
	for i = 1, 3 do
		local a = axes[i]
		local o, dd = d0:Dot(a), d:Dot(a)
		if math.abs(dd) < 1e-6 then
			if math.abs(o) > ext[i] then return false end
		else
			local t1, t2 = (-ext[i] - o) / dd, (ext[i] - o) / dd
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return false end
		end
	end
	-- inside the square box; the ring is round: check the in-plane distance where the segment is inside
	local tm = (tmin + tmax) / 2
	local hit = d0 + d * tm
	local inPlane = Vector3.new(hit:Dot(u), hit:Dot(v), 0).Magnitude
	return inPlane <= SK.RING_R + SK.CAR_TOL
end

function SK.PreTick(car: any, dt: number)
	car.boost = 100 -- unlimited boost: it's a flying race
end

return SK
