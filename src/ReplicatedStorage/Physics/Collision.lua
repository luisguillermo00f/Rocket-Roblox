--!strict
-- Collision.lua: narrow phase. Everything here is in Bullet units (BT) unless noted.
-- Contact convention (Bullet): normal = normalWorldOnB, pointing from body B toward body A.
-- dist < 0 means penetration. pointA / pointB are the witness points on A and B.
local C = require(script.Parent.PhysicsConstants)
local ArenaCollision = require(script.Parent.ArenaCollision)

local UU, BT = C.UU_TO_BT, C.BT_TO_UU
local Collision = {}

export type Contact = {
	a: any, b: any?,
	pointA: Vector3, pointB: Vector3,
	normal: Vector3, dist: number,
	friction: number, restitution: number,
	[string]: any,
}

-- Sphere (A) vs oriented box (B). Mirrors btSphereBoxCollisionAlgorithm.
-- Returns (pointOnBox, normalBoxToSphere, dist) or nil.
function Collision.SphereOBB(center: Vector3, radius: number, boxC: Vector3, f: Vector3, r: Vector3, u: Vector3, h: Vector3, threshold: number)
	local d = center - boxC
	local lx, ly, lz = d:Dot(f), d:Dot(r), d:Dot(u)
	local cx, cy, cz = math.clamp(lx, -h.X, h.X), math.clamp(ly, -h.Y, h.Y), math.clamp(lz, -h.Z, h.Z)
	local ex, ey, ez = lx - cx, ly - cy, lz - cz
	local dist2 = ex * ex + ey * ey + ez * ez
	if dist2 > (radius + threshold) * (radius + threshold) then
		return nil
	end
	if dist2 > 1e-12 then
		local dl = math.sqrt(dist2)
		local nLocal = Vector3.new(ex, ey, ez) / dl
		local n = f * nLocal.X + r * nLocal.Y + u * nLocal.Z
		local pOnBox = boxC + f * cx + r * cy + u * cz
		return pOnBox, n, dl - radius
	end
	-- Center inside the box: push out through the face of least penetration
	local px, py, pz = h.X - math.abs(lx), h.Y - math.abs(ly), h.Z - math.abs(lz)
	local n: Vector3, pOnBox: Vector3, depth: number
	if px <= py and px <= pz then
		local s = if lx >= 0 then 1 else -1
		n = f * s; depth = px
		pOnBox = boxC + f * (s * h.X) + r * ly + u * lz
	elseif py <= pz then
		local s = if ly >= 0 then 1 else -1
		n = r * s; depth = py
		pOnBox = boxC + f * lx + r * (s * h.Y) + u * lz
	else
		local s = if lz >= 0 then 1 else -1
		n = u * s; depth = pz
		pOnBox = boxC + f * lx + r * ly + u * (s * h.Z)
	end
	return pOnBox, n, -(depth + radius)
end

-- Sphere vs arena (UU distance field). Returns the list of per-solid contacts (like a mesh manifold).
local scratch = {}
-- Minigame extras: sphere vs per-world axis-aligned box solids flagged ball = true. Appends to list.
function Collision.SphereExtraSolids(centerBT: Vector3, contactRadiusUU: number, thresholdUU: number, solids: { any }, list: { any })
	local pUU = centerBT * BT
	for _, sol in solids do
		if sol.ball then
			local d, n = ArenaCollision.PrimDist(sol, pUU)
			if d < contactRadiusUU + thresholdUU then
				local distUU = d - contactRadiusUU
				local pointB = (pUU - n * d) * UU
				local pointA = pointB + n * (distUU * UU)
				table.insert(list, { normal = n, dist = distUU * UU, pointA = pointA, pointB = pointB })
			end
		end
	end
end

function Collision.SphereArena(centerBT: Vector3, contactRadiusUU: number, thresholdUU: number, arena: any?)
	local pUU = centerBT * BT
	local n = (arena or ArenaCollision).QueryAll(pUU, contactRadiusUU + thresholdUU, scratch)
	local list = {}
	for i = 1, n do
		local s = scratch[i]
		local distUU = s.d - contactRadiusUU
		local pointB = (pUU - s.n * s.d) * UU -- on the arena surface
		local pointA = pointB + s.n * (distUU * UU) -- on the (margin-inflated) ball surface
		list[i] = { normal = s.n, dist = distUU * UU, pointA = pointA, pointB = pointB }
	end
	return list
end

-- Oriented box vs arena: sample corners + edge midpoints (Bullet builds a 4-point manifold from the deepest ones).
local SIGNS = {}
for _, sx in { -1, 1 } do
	for _, sy in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(SIGNS, Vector3.new(sx, sy, sz))
		end
	end
end
for _, a in { { 0, 1, 1 }, { 1, 0, 1 }, { 1, 1, 0 } } do
	for _, s1 in { -1, 1 } do
		for _, s2 in { -1, 1 } do
			local v = { 0, 0, 0 }
			local k = 0
			for i = 1, 3 do
				if a[i] == 1 then
					k += 1
					v[i] = if k == 1 then s1 else s2
				end
			end
			table.insert(SIGNS, Vector3.new(v[1], v[2], v[3]))
		end
	end
end

-- Keep at most 4 manifold points: the deepest, then the ones that maximize the contact area
-- (same goal as Bullet's btPersistentManifold::sortCachedPoints). Deterministic, no ties to flicker on.
local function reduceManifold(pts: { any }): { any }
	if #pts <= 4 then
		return pts
	end
	local best = 1
	for i = 2, #pts do
		if pts[i].dist < pts[best].dist - 1e-6 then
			best = i
		end
	end
	local p1 = pts[best].pointA
	local i2, d2 = 0, -1
	for i, c in pts do
		local d = (c.pointA - p1).Magnitude
		if d > d2 + 1e-6 then i2, d2 = i, d end
	end
	local p2 = pts[i2].pointA
	local i3, a3, n3 = 0, -1, Vector3.zero
	for i, c in pts do
		local cr = (c.pointA - p1):Cross(p2 - p1)
		local a = cr.Magnitude
		if a > a3 + 1e-9 then i3, a3, n3 = i, a, cr end
	end
	local i4, a4 = 0, -1
	for i, c in pts do
		if i ~= best and i ~= i2 and i ~= i3 then
			local cr = (c.pointA - p1):Cross(p2 - p1)
			if cr:Dot(n3) < 0 then
				local a = cr.Magnitude
				if a > a4 + 1e-9 then i4, a4 = i, a end
			end
		end
	end
	local out = { pts[best], pts[i2] }
	if i3 ~= 0 and i3 ~= best and i3 ~= i2 then table.insert(out, pts[i3]) end
	if i4 ~= 0 then table.insert(out, pts[i4]) end
	return out
end
Collision.ReduceManifold = reduceManifold

function Collision.OBBArena(boxC: Vector3, f: Vector3, r: Vector3, u: Vector3, h: Vector3, thresholdUU: number)
	local found = {}
	for i = 1, #SIGNS do
		local s = SIGNS[i]
		local pBT = boxC + f * (h.X * s.X) + r * (h.Y * s.Y) + u * (h.Z * s.Z)
		local pUU = pBT * BT
		local d, n = ArenaCollision.Query(pUU, true)
		if d < thresholdUU then
			table.insert(found, { pointA = pBT, pointB = (pUU - n * d) * UU, normal = n, dist = d * UU, key = i })
		end
	end
	found = reduceManifold(found)
	-- exact box vs box against the solid blocks around the goals
	local boundR = h.Magnitude + thresholdUU * UU
	for bi, bx in ArenaCollision.Boxes do
		local bc = bx.c * UU
		local bh = bx.h * UU
		local dd = boxC - bc
		if math.abs(dd.X) <= bh.X + boundR and math.abs(dd.Y) <= bh.Y + boundR and math.abs(dd.Z) <= bh.Z + boundR then
			local cc = Collision.OBBOBB(boxC, f, r, u, h, bc, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, bh, thresholdUU * UU)
			if cc then
				for ci, c in cc do
					c.key = 100 + bi * 10 + ci
					table.insert(found, c)
				end
			end
		end
	end
	return found
end

-- OBB (A) vs OBB (B) with SAT + reference-face clipping (same scheme as Bullet's btBoxBoxDetector).
-- Returns up to 4 contacts with normal pointing from B to A.
local function project(h: Vector3, f: Vector3, r: Vector3, u: Vector3, axis: Vector3): number
	return h.X * math.abs(f:Dot(axis)) + h.Y * math.abs(r:Dot(axis)) + h.Z * math.abs(u:Dot(axis))
end

local function closestSegSeg(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3): (Vector3, Vector3)
	local d1, d2 = q1 - p1, q2 - p2
	local rr = p1 - p2
	local a, e = d1:Dot(d1), d2:Dot(d2)
	local fv = d2:Dot(rr)
	local c = d1:Dot(rr)
	local b = d1:Dot(d2)
	local den = a * e - b * b
	local s = if den > 1e-9 then math.clamp((b * fv - c * e) / den, 0, 1) else 0
	local t = (b * s + fv) / e
	if t < 0 then
		t = 0; s = math.clamp(-c / a, 0, 1)
	elseif t > 1 then
		t = 1; s = math.clamp((b - c) / a, 0, 1)
	end
	return p1 + d1 * s, p2 + d2 * t
end

-- Clip a convex polygon against the half-space dot(p - origin, axis) <= limit
local function clip(poly: { Vector3 }, origin: Vector3, axis: Vector3, limit: number): { Vector3 }
	local out = {}
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local da, db = (a - origin):Dot(axis) - limit, (b - origin):Dot(axis) - limit
		if da <= 0 then
			table.insert(out, a)
		end
		if (da <= 0) ~= (db <= 0) then
			table.insert(out, a + (b - a) * (da / (da - db)))
		end
	end
	return out
end

function Collision.OBBOBB(ca: Vector3, fa: Vector3, ra: Vector3, ua: Vector3, ha: Vector3, cb: Vector3, fb: Vector3, rb: Vector3, ub: Vector3, hb: Vector3, threshold: number)
	local axesA = { fa, ra, ua }
	local axesB = { fb, rb, ub }
	local hsA = { ha.X, ha.Y, ha.Z }
	local hsB = { hb.X, hb.Y, hb.Z }
	local d = ca - cb
	local bestSep, bestAxis, bestKind, bestI, bestJ = -math.huge, Vector3.zero, 0, 0, 0
	local function test(axis: Vector3, kind: number, i: number, j: number): boolean
		local len = axis.Magnitude
		if len < 1e-6 then
			return true
		end
		axis /= len
		local sep = math.abs(d:Dot(axis)) - (project(ha, fa, ra, ua, axis) + project(hb, fb, rb, ub, axis))
		if sep > threshold then
			return false
		end
		-- prefer face axes unless an edge axis is clearly better (Bullet uses a similar fudge)
		local biased = if kind == 3 then sep * 1.05 - 1e-4 else sep
		if biased > bestSep then
			bestSep, bestAxis, bestKind, bestI, bestJ = biased, axis, kind, i, j
		end
		return true
	end
	for i = 1, 3 do
		if not test(axesA[i], 1, i, 0) then return nil end
	end
	for i = 1, 3 do
		if not test(axesB[i], 2, i, 0) then return nil end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			if not test(axesA[i]:Cross(axesB[j]), 3, i, j) then return nil end
		end
	end
	local n = bestAxis
	if d:Dot(n) < 0 then
		n = -n -- from B toward A
	end

	local contacts = {}
	if bestKind == 1 or bestKind == 2 then
		local refIsA = bestKind == 1
		local refC = if refIsA then ca else cb
		local refAxes = if refIsA then axesA else axesB
		local refH = if refIsA then hsA else hsB
		local incC = if refIsA then cb else ca
		local incAxes = if refIsA then axesB else axesA
		local incH = if refIsA then hsB else hsA
		local k = bestI
		local nRef = if refIsA then -n else n -- reference face normal, pointing toward the incident box
		local kAxis = refAxes[k]
		local sign = if kAxis:Dot(nRef) >= 0 then 1 else -1
		nRef = kAxis * sign
		-- incident face: most anti-parallel to nRef
		local bestJ2, bestDot, incSign = 1, math.huge, 1
		for j = 1, 3 do
			local dp = incAxes[j]:Dot(nRef)
			if dp < bestDot then bestDot, bestJ2, incSign = dp, j, 1 end
			if -dp < bestDot then bestDot, bestJ2, incSign = -dp, j, -1 end
		end
		local j1 = bestJ2 % 3 + 1
		local j2 = j1 % 3 + 1
		local fc = incC + incAxes[bestJ2] * (incSign * incH[bestJ2])
		local e1 = incAxes[j1] * incH[j1]
		local e2 = incAxes[j2] * incH[j2]
		local poly = { fc + e1 + e2, fc - e1 + e2, fc - e1 - e2, fc + e1 - e2 }
		for m = 1, 3 do
			if m ~= k then
				poly = clip(poly, refC, refAxes[m], refH[m])
				poly = clip(poly, refC, -refAxes[m], refH[m])
			end
		end
		for _, p in poly do
			local depth = (p - refC):Dot(nRef) - refH[k]
			if depth < threshold then
				local onRef = p - nRef * depth
				if refIsA then
					table.insert(contacts, { pointA = onRef, pointB = p, normal = n, dist = depth })
				else
					table.insert(contacts, { pointA = p, pointB = onRef, normal = n, dist = depth })
				end
			end
		end
		contacts = Collision.ReduceManifold(contacts)
	else
		-- Edge-edge: closest points of the two supporting edges
		local ea, eb = axesA[bestI], axesB[bestJ]
		local function supportEdge(c: Vector3, axes, hs, edgeIdx: number, dir: Vector3)
			local p = c
			for k2 = 1, 3 do
				if k2 ~= edgeIdx then
					p += axes[k2] * (hs[k2] * (if axes[k2]:Dot(dir) >= 0 then 1 else -1))
				end
			end
			return p - axes[edgeIdx] * hs[edgeIdx], p + axes[edgeIdx] * hs[edgeIdx]
		end
		local a0, a1 = supportEdge(ca, axesA, hsA, bestI, -n)
		local b0, b1 = supportEdge(cb, axesB, hsB, bestJ, n)
		local pa, pb = closestSegSeg(a0, a1, b0, b1)
		table.insert(contacts, { pointA = pa, pointB = pb, normal = n, dist = (pa - pb):Dot(n) })
		local _ = ea; local _ = eb
	end
	if #contacts == 0 then
		return nil
	end
	return contacts
end

-- Ray vs sphere. Returns t (along unit dir) and normal, or nil.
function Collision.RaySphere(o: Vector3, dir: Vector3, maxLen: number, c: Vector3, radius: number): (number?, Vector3?)
	local m = o - c
	local b = m:Dot(dir)
	local cc = m:Dot(m) - radius * radius
	if cc > 0 and b > 0 then
		return nil
	end
	local disc = b * b - cc
	if disc < 0 then
		return nil
	end
	local t = math.max(-b - math.sqrt(disc), 0)
	if t > maxLen then
		return nil
	end
	return t, ((o + dir * t) - c).Unit
end

-- Ray vs oriented box (slab test).
function Collision.RayOBB(o: Vector3, dir: Vector3, maxLen: number, c: Vector3, f: Vector3, r: Vector3, u: Vector3, h: Vector3): (number?, Vector3?)
	local rel = o - c
	local tmin, tmax = 0, maxLen
	local nrm = Vector3.zero
	local axes = { f, r, u }
	local hs = { h.X, h.Y, h.Z }
	for k = 1, 3 do
		local ax = axes[k]
		local e = rel:Dot(ax)
		local fd = dir:Dot(ax)
		if math.abs(fd) < 1e-9 then
			if math.abs(e) > hs[k] then
				return nil
			end
		else
			local t1 = (-hs[k] - e) / fd
			local t2 = (hs[k] - e) / fd
			local sgn = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				sgn = 1
			end
			if t1 > tmin then
				tmin = t1
				nrm = ax * sgn
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if nrm == Vector3.zero then
		return nil -- started inside
	end
	return tmin, nrm
end

return Collision
