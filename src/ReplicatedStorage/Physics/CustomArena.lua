--!strict
-- CustomArena.lua: a per-world arena made of solid primitives, for minigames on their own maps (World.new{arena=...}).
-- Same interface as ArenaCollision (Query / QueryAll / RayCast / PrimDist / Primitives / Boxes), so the car narrow
-- phase, the wheel rays, the ball contacts and the client prediction work unchanged on any map. A world without an
-- arena keeps using the Soccar arena (ArenaCollision), so standard physics is untouched.
--
-- Primitive kinds (UU, sim axes, same conventions as ArenaCollision: solids, free-space normals):
--   box    { c, h }                       axis-aligned box
--   hull   { planes = {{n, off}}, min, max } convex solid (oriented blocks, ramps, wedges); min/max = its bounds
--   fillet { c, a, t0, t1, u1, u2, g, r }   concave cylindrical transition (quarter pipes, bowl edges)
-- Maps can be big (hundreds of pieces over tens of thousands of uu): a uniform grid on x/y keeps every query local.
local ArenaCollision = require(script.Parent.ArenaCollision)

local CustomArena = {}

local HUGE = 1e9
local CELL = 1200 -- uu
local FAR = 900 -- uu: Query reports at most this when nothing is closer (sphere tracing steps are capped by it)

local basePrimDist = ArenaCollision.PrimDist

-- Hulls get their exact distance outside an edge or corner. The plane-max distance ArenaCollision uses is exact
-- inside a convex solid and over a face, but near an edge it measures to the face plane EXTENDED past the edge: a
-- ball rolling over the crest of a downhill ramp "touched" a slope that isn't there and was kicked into the air.
-- When the point is outside two or more planes, Dykstra's alternating projections onto the half-spaces converge to
-- the solid's closest point. (The Soccar arena keeps ArenaCollision's own function: its physics is unchanged.)
local ecc: { Vector3 } = {}
local function primDist(pr: any, p: Vector3): (number, Vector3)
	if pr.kind ~= "hull" then
		return basePrimDist(pr, p)
	end
	local planes = pr.planes
	local outside = 0
	local best, bestN = -HUGE, Vector3.zAxis
	for _, pl in planes do
		local d = p:Dot(pl.n) - pl.off
		if d > 0 then outside += 1 end
		if d > best then best, bestN = d, pl.n end
	end
	if outside < 2 then
		return best, bestN
	end
	local np = #planes
	for i = 1, np do ecc[i] = Vector3.zero end
	local x = p
	for _ = 1, 14 do
		for i = 1, np do
			local pl = planes[i]
			local y = x + ecc[i]
			local d = y:Dot(pl.n) - pl.off
			local yp = if d > 0 then y - pl.n * d else y
			ecc[i] = y - yp
			x = yp
		end
	end
	local off = p - x
	local m = off.Magnitude
	if m <= best or m < 1e-4 then
		return best, bestN
	end
	return m, off / m
end

local function boundsOf(pr: any): (Vector3, Vector3)
	if pr.kind == "box" then
		return pr.c - pr.h, pr.c + pr.h
	elseif pr.kind == "hull" then
		return pr.min, pr.max
	elseif pr.kind == "fillet" then
		local a0, a1 = pr.c + pr.a * pr.t0, pr.c + pr.a * pr.t1
		local r = Vector3.new(pr.r, pr.r, pr.r) * 1.05
		return a0:Min(a1) - r, a0:Max(a1) + r
	end
	return Vector3.new(-HUGE, -HUGE, -HUGE), Vector3.new(HUGE, HUGE, HUGE)
end

function CustomArena.new(prims: { any }): any
	local self: any = { Primitives = prims, Boxes = {}, custom = true }
	local grid: { [number]: { number } } = {}
	local function key(ix: number, iy: number): number
		return (ix + 4096) * 8192 + (iy + 4096)
	end
	for i, pr in prims do
		local mn, mx = boundsOf(pr)
		pr.bmin, pr.bmax = mn, mx
		if pr.kind == "box" then table.insert(self.Boxes, pr) end
		for ix = math.floor(mn.X / CELL), math.floor(mx.X / CELL) do
			for iy = math.floor(mn.Y / CELL), math.floor(mx.Y / CELL) do
				local k = key(ix, iy)
				local list = grid[k]
				if not list then list = {}; grid[k] = list end
				table.insert(list, i)
			end
		end
	end
	local stamp = table.create(#prims, 0)
	local gen = 0
	-- indices of the primitives whose bounds come within r of p
	local near = table.create(64)
	local function gather(p: Vector3, r: number): number
		gen += 1
		local n = 0
		for ix = math.floor((p.X - r) / CELL), math.floor((p.X + r) / CELL) do
			for iy = math.floor((p.Y - r) / CELL), math.floor((p.Y + r) / CELL) do
				local list = grid[key(ix, iy)]
				if list then
					for _, i in list do
						if stamp[i] ~= gen then
							stamp[i] = gen
							local pr = prims[i]
							local mn, mx = pr.bmin, pr.bmax
							if p.X > mn.X - r and p.X < mx.X + r and p.Y > mn.Y - r and p.Y < mx.Y + r and p.Z > mn.Z - r and p.Z < mx.Z + r then
								n += 1
								near[n] = i
							end
						end
					end
				end
			end
		end
		return n
	end
	self.Near = function(p: Vector3, r: number): ({ number }, number)
		local n = gather(p, r)
		return near, n
	end
	self.PrimDist = primDist
	self.Query = function(p: Vector3, skipBoxes: boolean?): (number, Vector3)
		local best, bestN = FAR, Vector3.zAxis
		local n = gather(p, FAR)
		for k = 1, n do
			local pr = prims[near[k]]
			if not (skipBoxes and pr.kind == "box") then
				local d, nn = primDist(pr, p)
				if d < best then best, bestN = d, nn end
			end
		end
		return best, bestN
	end
	self.QueryAll = function(p: Vector3, maxDist: number, out: { any }): number
		local count = 0
		local n = gather(p, maxDist)
		for k = 1, n do
			local d, nn = primDist(prims[near[k]], p)
			if d < maxDist then
				count += 1
				out[count] = { d = d, n = nn }
			end
		end
		return count
	end
	self.RayCast = function(origin: Vector3, dir: Vector3, maxLen: number): (number?, Vector3?, Vector3?)
		local t = 0
		for _ = 1, 64 do
			local p = origin + dir * t
			local d, n = self.Query(p)
			if d <= 0.01 then
				if t == 0 and d < 0 then return 0, p, n end
				return t, p, n
			end
			t += d
			if t > maxLen then return nil end
		end
		return nil
	end
	return self
end

return CustomArena
