--!strict
-- ArenaVisual.lua: builds the visible Soccar arena from the same numbers/primitives the collision uses,
-- so what you see is what you hit. Run once in edit mode: require(...).Build(workspace)
local C = require(script.Parent.Parent.Physics.PhysicsConstants)
local ArenaCollision = require(script.Parent.Parent.Physics.ArenaCollision)
local RenderMap = require(script.Parent.RenderMap)

local S = RenderMap.S
local ArenaVisual = {}

local EX, EY, H = C.ARENA_EXTENT_X, C.ARENA_EXTENT_Y, C.ARENA_HEIGHT
local CS, R = C.ARENA_CORNER_SUM, C.ARENA_RAMP_RADIUS
local GW, GH, GD = C.GOAL_HALF_WIDTH, C.GOAL_HEIGHT, C.GOAL_DEPTH
local THICK = 40 -- visual wall thickness (UU), always placed outside the playable surface

local FLOOR = Color3.fromRGB(64, 148, 62)
local FLOOR_ALT = Color3.fromRGB(74, 162, 72)
local LINE = Color3.fromRGB(245, 248, 245)
local WALL_BLUE = Color3.fromRGB(28, 96, 215)
local WALL_ORANGE = Color3.fromRGB(235, 96, 24)
local WALL_NEUTRAL = Color3.fromRGB(40, 44, 54)
local NEON_BLUE = Color3.fromRGB(42, 168, 255)
local NEON_ORANGE = Color3.fromRGB(255, 128, 24)
local STRUCT = Color3.fromRGB(26, 28, 34)
local TRIM_WHITE = Color3.fromRGB(248, 250, 255)
local RAMP_BASE = Color3.fromRGB(26, 30, 38)
local TURF_VARIANT = "" -- optional MaterialVariant for the pitch; empty = built-in Grass

local folder: Model

-- Box part from simulation-space center (UU), size along (x, y, z) sim axes, rotated by `rot` (Roblox CFrame rotation)
local function slab(name: string, centerUU: Vector3, sizeRoblox: Vector3, rot: CFrame, color: Color3, transparency: number?, material: Enum.Material?)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = sizeRoblox
	p.CFrame = CFrame.new(RenderMap.Pos(centerUU)) * rot
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = false
	p.Parent = folder
	return p
end

local function halfColor(y: number): Color3
	return if y < -1 then WALL_BLUE elseif y > 1 then WALL_ORANGE else WALL_NEUTRAL
end

-- A flat panel whose playable face lies on the plane through `onSurfaceUU` with free-space normal `nSim`.
local function panel(name: string, onSurfaceUU: Vector3, nSim: Vector3, uSim: Vector3, a: number, b: number, color: Color3, transparency: number, thick: number?, mat: Enum.Material?)
	local th = thick or THICK
	local center = onSurfaceUU - nSim * (th / 2)
	local n, u = RenderMap.Dir(nSim), RenderMap.Dir(uSim)
	local v = u:Cross(n)
	local rot = CFrame.fromMatrix(Vector3.zero, u, n, v)
	return slab(name, center, Vector3.new(a * S, th * S, b * S), rot, color, transparency, mat or Enum.Material.SmoothPlastic)
end

function ArenaVisual.Build(parent: Instance)
	local old = parent:FindFirstChild("Arena")
	if old then old:Destroy() end
	folder = Instance.new("Model")
	folder.Name = "Arena"
	folder.LevelOfDetail = Enum.ModelLevelOfDetail.Disabled
	folder.Parent = parent

	-- Floor (striped turf with crisp contrast)
	local stripes = 12
	local stripeLen = EY * 2 / stripes
	for i = 0, stripes - 1 do
		local y = -EY + stripeLen * (i + 0.5)
		local fl = slab("Floor", Vector3.new(0, y, -THICK / 2), Vector3.new(EX * 2 * S, THICK * S, stripeLen * S), CFrame.identity,
			if i % 2 == 0 then FLOOR else FLOOR_ALT, 0, Enum.Material.Grass)
		fl.MaterialVariant = TURF_VARIANT
	end
	for _, sy in { 1, -1 } do
		slab("GoalFloor", Vector3.new(0, sy * (EY + GD / 2), -THICK / 2), Vector3.new(GW * 2 * S, THICK * S, GD * S), CFrame.identity, FLOOR, 0, Enum.Material.Grass)
	end

	-- Pitch Line Markings
	local lw = 22
	slab("CenterLine", Vector3.new(0, 0, 0.6), Vector3.new((EX * 2 - 2 * R) * S, 0.06, lw * S), CFrame.identity, LINE, 0.1)
	local circleR, segs = 1000, 64
	for i = 0, segs - 1 do
		local a0, a1 = i / segs * math.pi * 2, (i + 1) / segs * math.pi * 2
		local p0 = Vector3.new(math.cos(a0), math.sin(a0), 0) * circleR
		local p1 = Vector3.new(math.cos(a1), math.sin(a1), 0) * circleR
		local mid = (p0 + p1) / 2 + Vector3.new(0, 0, 0.6)
		local len = (p1 - p0).Magnitude
		local dir = RenderMap.Dir((p1 - p0).Unit)
		slab("CenterCircle", mid, Vector3.new(lw * S, 0.06, (len + 1.2) * S), CFrame.lookAt(Vector3.zero, dir), LINE, 0.1)
	end
	for _, sy in { 1, -1 } do
		-- goal line and penalty box
		slab("GoalLine", Vector3.new(0, sy * (EY - lw / 2), 0.6), Vector3.new(GW * 2 * S, 0.06, lw * S), CFrame.identity, LINE, 0.1)
		local boxDepth, boxHalfW = 1100, 1400
		slab("BoxFront", Vector3.new(0, sy * (EY - boxDepth), 0.6), Vector3.new(boxHalfW * 2 * S, 0.06, lw * S), CFrame.identity, LINE, 0.1)
		for _, sx in { 1, -1 } do
			slab("BoxSide", Vector3.new(sx * boxHalfW, sy * (EY - boxDepth / 2 - R / 2), 0.6), Vector3.new(lw * S, 0.06, (boxDepth - R) * S), CFrame.identity, LINE, 0.1)
		end
	end

	-- Tempered Stadium Glass Side Walls
	for _, sx in { 1, -1 } do
		local sideLen = CS - EX
		for _, sy in { 1, -1 } do
			panel("SideWall", Vector3.new(sx * EX, sy * sideLen / 2, H / 2), Vector3.new(-sx, 0, 0), Vector3.new(0, 1, 0), sideLen, H - 2 * R, halfColor(sy), 0.5, nil, Enum.Material.Glass)
		end
	end
	-- Back Walls and Goals
	local backLen = CS - EY
	for _, sy in { 1, -1 } do
		local n = Vector3.new(0, -sy, 0)
		for _, sx in { 1, -1 } do
			local w = backLen - GW
			panel("BackWall", Vector3.new(sx * (GW + w / 2), sy * EY, H / 2), n, Vector3.new(1, 0, 0), w, H - 2 * R, halfColor(sy), 0.48, nil, Enum.Material.Glass)
		end
		panel("BackWallTop", Vector3.new(0, sy * EY, (GH + H - R) / 2), n, Vector3.new(1, 0, 0), GW * 2, H - R - GH, halfColor(sy), 0.48, nil, Enum.Material.Glass)
		-- Goal chamber (RL profile, ArenaCollision.GoalProfile): the curved back is drawn with the other curved
		-- surfaces below; here the flat lintel, the sloped roof and the side netting cut to the profile
		local GP = ArenaCollision.GoalProfile
		local goalColor = halfColor(sy):Lerp(Color3.fromRGB(18, 20, 26), 0.55)
		panel("GoalLintel", Vector3.new(0, sy * (EY + GP.roofFrontD / 2), GH), Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), GW * 2, GP.roofFrontD, goalColor, 0.25)
		local roofLen = math.sqrt((GP.endD - GP.roofFrontD) ^ 2 + (GH - GP.endZ) ^ 2)
		local roofMid = Vector3.new(0, sy * (EY + (GP.roofFrontD + GP.endD) / 2), (GH + GP.endZ) / 2)
		panel("GoalRoof", roofMid, Vector3.new(0, -sy * GP.slope, -1).Unit, Vector3.new(1, 0, 0), GW * 2, roofLen, goalColor, 0.25)
		-- side netting as vertical strips between the floor / back curve and the roof / back curve
		local function profileTop(d: number): number
			if d <= GP.roofFrontD then return GH end
			if d <= GP.endD then return GH - GP.slope * (d - GP.roofFrontD) end
			return GP.backZ + math.sqrt(math.max(0, GP.backR ^ 2 - (d - GP.backD) ^ 2))
		end
		local function profileBottom(d: number): number
			if d <= GP.backD then return 0 end
			return GP.backZ - math.sqrt(math.max(0, GP.backR ^ 2 - (d - GP.backD) ^ 2))
		end
		local strips = 22
		local stripW = (GP.backD + GP.backR) / strips
		for _, sx in { 1, -1 } do
			for k = 0, strips - 1 do
				local d = (k + 0.5) * stripW
				local top, bot = profileTop(d), profileBottom(d)
				if top - bot > 4 then
					panel("GoalSide", Vector3.new(sx * GW, sy * (EY + d), (top + bot) / 2), Vector3.new(-sx, 0, 0), Vector3.new(0, 1, 0), stripW, top - bot, goalColor, 0.25)
				end
			end
		end

		-- Cylindrical Goal Posts with Smooth Spherical Elbow Joint Caps
		local postR = 12 * S
		local postDiam = postR * 2
		for _, sx in { 1, -1 } do
			local postPos = Vector3.new(sx * (GW + 8), sy * (EY + 8), (GH + 8) / 2)
			local post = Instance.new("Part")
			post.Name = "Post"
			post.Shape = Enum.PartType.Cylinder
			post.Anchored = true; post.CanCollide = false; post.CanQuery = false; post.CanTouch = false
			post.Size = Vector3.new((GH + 8) * S, postDiam, postDiam)
			post.CFrame = CFrame.new(RenderMap.Pos(postPos)) * CFrame.Angles(0, 0, math.rad(90))
			post.Color = TRIM_WHITE
			post.Material = Enum.Material.Metal
			post.CastShadow = false
			post.Parent = folder

			local elbowPos = Vector3.new(sx * (GW + 8), sy * (EY + 8), GH + 8)
			local elbow = Instance.new("Part")
			elbow.Name = "PostElbow"
			elbow.Shape = Enum.PartType.Ball
			elbow.Anchored = true; elbow.CanCollide = false; elbow.CanQuery = false; elbow.CanTouch = false
			elbow.Size = Vector3.new(postDiam, postDiam, postDiam)
			elbow.CFrame = CFrame.new(RenderMap.Pos(elbowPos))
			elbow.Color = TRIM_WHITE
			elbow.Material = Enum.Material.Metal
			elbow.CastShadow = false
			elbow.Parent = folder
		end
		local crossbarPos = Vector3.new(0, sy * (EY + 8), GH + 8)
		local crossbar = Instance.new("Part")
		crossbar.Name = "Crossbar"
		crossbar.Shape = Enum.PartType.Cylinder
		crossbar.Anchored = true; crossbar.CanCollide = false; crossbar.CanQuery = false; crossbar.CanTouch = false
		crossbar.Size = Vector3.new((GW * 2 + 16) * S, postDiam, postDiam)
		crossbar.CFrame = CFrame.new(RenderMap.Pos(crossbarPos))
		crossbar.Color = TRIM_WHITE
		crossbar.Material = Enum.Material.Metal
		crossbar.CastShadow = false
		crossbar.Parent = folder
	end
	-- Tempered Stadium Glass Corner Walls
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local mid = Vector3.new(sx * (EX + backLen) / 2, sy * ((CS - EX) + EY) / 2, H / 2)
			local n = Vector3.new(-sx, -sy, 0).Unit
			local along = Vector3.new(sx, -sy, 0).Unit
			panel("CornerWall", mid, n, along, (EX - backLen) * math.sqrt(2), H - 2 * R, halfColor(sy), 0.5, nil, Enum.Material.Glass)
		end
	end
	-- Ceiling
	panel("Ceiling", Vector3.new(0, 0, H), Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), EX * 2 - 2 * R, EY * 2 - 2 * R, WALL_NEUTRAL, 0.9)

	-- High-Poly Curved Ramps: 28 segments for silky smooth curvature without polygonal faceting
	local segments = 28
	for _, pr in ArenaCollision.Primitives do
		if pr.kind == "fillet" then
			local u1, u2 = pr.u1, pr.u2
			local total = math.acos(math.clamp(pr.g, -1, 1))
			local isVerticalFillet = math.abs(pr.a.Z) > 0.8
			local t0 = if isVerticalFillet then math.max(pr.t0, R) else pr.t0
			local t1 = if isVerticalFillet then math.min(pr.t1, H - R) else pr.t1
			local len = t1 - t0
			local mid = pr.c + pr.a * ((t0 + t1) / 2)
			local y = mid.Y
			local rampColor = if isVerticalFillet then halfColor(y):Lerp(Color3.fromRGB(40, 46, 58), 0.45) else RAMP_BASE:Lerp(halfColor(y), 0.22)
			if pr.goal then rampColor = halfColor(y):Lerp(Color3.fromRGB(18, 20, 26), 0.55) end
			for k = 0, segments - 1 do
				local th = (k + 0.5) / segments * total
				local perp = (u2 - u1 * pr.g).Unit
				local dir = u1 * math.cos(th) + perp * math.sin(th)
				local surf = mid + dir * pr.r
				local chord = 2 * pr.r * math.sin(total / segments / 2) + 1.2
				local rp = panel("Ramp", surf, -dir, pr.a, len, chord, rampColor, 0, 4)
				rp.Material = Enum.Material.SmoothPlastic
				if pr.goal then rp.Transparency = 0.25 end -- same net shell as the rest of the goal
			end
		end
	end
	ArenaVisual.Decorate(folder)
	ArenaVisual.SetupLighting()
	return folder
end

local function neon(name: string, centerUU: Vector3, sizeRoblox: Vector3, rot: CFrame, color: Color3)
	local p = slab(name, centerUU, sizeRoblox, rot, color, 0, Enum.Material.Neon)
	p.CastShadow = false
	return p
end

-- Neon trims, team areas, goal frames and the stadium bowl. Purely visual.
function ArenaVisual.Decorate(parent: Instance)
	local trimW = 12 -- UU
	local backLen = CS - EY
	local sideLen = CS - EX
	local function teamNeon(y: number): Color3
		return if y < 0 then NEON_BLUE else NEON_ORANGE
	end

	-- Exact mitered floor boundary coordinates
	local D = R + trimW
	local cornerSum = CS - D * math.sqrt(2)
	local sideX = EX - D
	local sideY_end = cornerSum - sideX
	local backY = EY - D
	local backX_end = cornerSum - backY
	local cornerMidX = (sideX + backX_end) / 2
	local cornerMidY = (sideY_end + backY) / 2
	local cornerLen = math.sqrt((sideX - backX_end)^2 + (backY - sideY_end)^2)

	-- Perimeter Neon Trims cleanly mitered to eliminate overlapping X crosses
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local c = teamNeon(sy)
			
			-- 1. Side floor neon: spans from Y = 0 up to the corner intersection vertex
			neon("TrimFloorSide", Vector3.new(sx * sideX, sy * sideY_end / 2, 1.5), Vector3.new(trimW * S, 0.12, sideY_end * S), CFrame.identity, c)
			
			-- 2. Corner diagonal neon: spans precisely between side vertex and back vertex
			local rot = CFrame.lookAt(Vector3.zero, RenderMap.Dir(Vector3.new(sx, -sy, 0).Unit))
			neon("TrimFloorCorner", Vector3.new(sx * cornerMidX, sy * cornerMidY, 1.5), Vector3.new(trimW * S, 0.12, cornerLen * S), rot, c)

			-- 3. Seamless rounded joint caps at the corner miter vertices
			local cap1 = slab("TrimCap1", Vector3.new(sx * sideX, sy * sideY_end, 1.5), Vector3.new(0.12, trimW * S, trimW * S), CFrame.Angles(0, 0, math.rad(90)), c, 0, Enum.Material.Neon)
			cap1.Shape = Enum.PartType.Cylinder
			cap1.CastShadow = false

			local cap2 = slab("TrimCap2", Vector3.new(sx * backX_end, sy * backY, 1.5), Vector3.new(0.12, trimW * S, trimW * S), CFrame.Angles(0, 0, math.rad(90)), c, 0, Enum.Material.Neon)
			cap2.Shape = Enum.PartType.Cylinder
			cap2.CastShadow = false

			-- Top wall trims
			neon("TrimTopSide", Vector3.new(sx * (EX - 1), sy * sideLen / 2, H - R - 10), Vector3.new(0.3, trimW * S, sideLen * S), CFrame.identity, c)
			local mid = Vector3.new(sx * (EX + backLen) / 2, sy * (sideLen + EY) / 2, 0)
			local nC = Vector3.new(-sx, -sy, 0).Unit
			local len = (EX - backLen) * math.sqrt(2)
			neon("TrimTopCorner", mid - nC * 1 + Vector3.new(0, 0, H - R - 10), Vector3.new(0.3, trimW * S, len * S), rot, c)
		end
	end

	for _, sy in { 1, -1 } do
		local c = teamNeon(sy)
		for _, sx in { 1, -1 } do
			-- Back floor neon: spans from goal post to corner miter vertex
			local backStartX = GW + 8
			local backSpanX = backX_end - backStartX
			local backMidX = (backStartX + backX_end) / 2
			neon("TrimFloorBack", Vector3.new(sx * backMidX, sy * backY, 1.5), Vector3.new(backSpanX * S, 0.12, trimW * S), CFrame.identity, c)
		end
		neon("TrimTopBack", Vector3.new(0, sy * (EY - 1), H - R - 10), Vector3.new(backLen * 2 * S, trimW * S, 0.3), CFrame.identity, c)
		
		-- Seamless Goal Neon Arch: perfectly flush joints with zero overhanging tips
		local gy = sy * (EY + 4)
		local frameH = GH + 12
		neon("GoalFrameTop", Vector3.new(0, gy, frameH), Vector3.new((GW * 2 + 28) * S, 10 * S, 10 * S), CFrame.identity, c)
		for _, sx in { 1, -1 } do
			neon("GoalFrameSide", Vector3.new(sx * (GW + 9), gy, frameH / 2), Vector3.new(10 * S, frameH * S, 10 * S), CFrame.identity, c)
		end
		-- glow + netting follow the curved back (RL profile)
		local GP = ArenaCollision.GoalProfile
		local function arcPoint(phi: number, inset: number): Vector3
			return Vector3.new(0, sy * (EY + GP.backD + (GP.backR - inset) * math.cos(phi)), GP.backZ + (GP.backR - inset) * math.sin(phi))
		end
		local phi0, phi1 = -math.pi / 2, GP.backEnd
		local glow = slab("GoalGlow", arcPoint(0, 6), Vector3.new(GW * 2 * S, 0.2, 0.2), CFrame.identity, c, 1, Enum.Material.Neon)
		local light = Instance.new("PointLight")
		light.Color = c
		light.Brightness = 2.5
		light.Range = 30
		light.Parent = glow
		local NET = Color3.fromRGB(240, 242, 248)
		local arcSegs = 10
		for k = 1, 21 do
			local x = -GW + (GW * 2) * k / 22
			for j = 0, arcSegs - 1 do
				local pa, pb = phi0 + (phi1 - phi0) * j / arcSegs, phi0 + (phi1 - phi0) * (j + 1) / arcSegs
				local a, b = arcPoint(pa, 8), arcPoint(pb, 8)
				local mid = (a + b) / 2 + Vector3.new(x, 0, 0)
				local t = RenderMap.Dir(b - a)
				local rot = CFrame.fromMatrix(Vector3.zero, Vector3.xAxis, t.Unit, Vector3.xAxis:Cross(t.Unit))
				slab("NetV", mid, Vector3.new(1.6 * S, (b - a).Magnitude * S + 0.05, 1.6 * S), rot, NET, 0.35)
			end
		end
		for k = 1, 10 do
			local p = arcPoint(phi0 + (phi1 - phi0) * k / 11, 8)
			slab("NetH", p, Vector3.new(GW * 2 * S, 1.6 * S, 1.6 * S), CFrame.identity, NET, 0.35)
		end
		local area = slab("TeamArea", Vector3.new(0, sy * (EY - 550 - R / 2), 0.6), Vector3.new(2800 * S, 0.06, (1100 - R) * S), CFrame.identity, c, 0.85, Enum.Material.SmoothPlastic)
		area.CastShadow = false
	end
	local spot = slab("CenterSpot", Vector3.new(0, 0, 0.8), Vector3.new(0.06, 70 * S, 70 * S), CFrame.Angles(0, 0, math.rad(90)), LINE, 0.2, Enum.Material.Neon)
	spot.Shape = Enum.PartType.Cylinder

	-- ===== Stadium bowl (outside the playable volume) =====
	local tiers = 7
	local tierH, tierD = 150, 260
	local function stand(name: string, center: Vector3, alongSim: Vector3, outSim: Vector3, length: number, color: Color3)
		local rot = CFrame.lookAt(Vector3.zero, RenderMap.Dir(alongSim))
		for t = 0, tiers - 1 do
			local z = 300 + t * tierH
			local off = 260 + t * tierD
			local c = center + outSim * off + Vector3.new(0, 0, z)
			local step = slab(name, c, Vector3.new(tierD * S, tierH * S * 1.02, (length + off * 1.2) * S), rot, STRUCT:Lerp(color, 0.12 + t * 0.03), 0, Enum.Material.Concrete)
			step.CastShadow = true
			if t % 2 == 1 then
				local count = math.floor(length / 180)
				for i2 = 0, count do
					local along = -length / 2 + (i2 + 0.5) * (length / (count + 1))
					local jitter = ((i2 * 7919 + t * 104729) % 97) / 97
					local col = if jitter < 0.45 then color:Lerp(Color3.new(1, 1, 1), jitter * 0.4) else Color3.fromHSV(jitter, 0.35, 0.75)
					slab("Crowd", c + alongSim * along + Vector3.new(0, 0, tierH * 0.5 + 40), Vector3.new(60 * S, 80 * S, 90 * S), rot, col, 0, Enum.Material.SmoothPlastic)
				end
			end
		end
		local topZ = 300 + tiers * tierH + 200
		local lc = center + outSim * (260 + tiers * tierD) + Vector3.new(0, 0, topZ)
		local rig = slab(name .. "Lights", lc, Vector3.new(60 * S, 40 * S, length * 0.8 * S), rot, Color3.fromRGB(255, 244, 220), 0, Enum.Material.Neon)
		rig.CastShadow = false
		slab(name .. "Rig", lc + Vector3.new(0, 0, -60), Vector3.new(90 * S, 60 * S, length * 0.85 * S), rot, STRUCT, 0, Enum.Material.Metal)
	end
	for _, sx in { 1, -1 } do
		stand("SideStand", Vector3.new(sx * EX, 0, 0), Vector3.new(0, 1, 0), Vector3.new(sx, 0, 0), EY * 2, WALL_NEUTRAL)
	end
	for _, sy in { 1, -1 } do
		stand("EndStand", Vector3.new(0, sy * (EY + GD), 0), Vector3.new(1, 0, 0), Vector3.new(0, sy, 0), EX * 2, if sy < 0 then NEON_BLUE else NEON_ORANGE)
	end
	ArenaVisual.BuildExterior(parent)
end

-- ===== Finishing the stadium: what you see from the stands, the cinematics and from outside =====
-- Corner stands (the bowl closes all the way round), an octagonal outer facade with columns and a team-colour band,
-- a cantilever roof over the stands (never over the pitch), a solid housing behind each goal chamber, a plaza and
-- grass out to the horizon, and caps closing the ends of the back-wall floor ramps at the goal posts.
function ArenaVisual.BuildExterior(parent: Instance)
	local FACADE = Color3.fromRGB(34, 37, 45)
	local tiers, tierH, tierD = 7, 150, 260
	-- a slab from P to Q (sim xy), centred at height z
	local function seg(name: string, P: Vector3, Q: Vector3, z: number, height: number, thick: number, color: Color3, mat: Enum.Material, transparency: number?)
		local d = Vector3.new(Q.X - P.X, Q.Y - P.Y, 0)
		local len = d.Magnitude
		local rot = CFrame.lookAt(Vector3.zero, RenderMap.Dir(d.Unit))
		local c = (P + Q) / 2
		return slab(name, Vector3.new(c.X, c.Y, z), Vector3.new(thick * S, height * S, len * S), rot, color, transparency or 0, mat)
	end

	-- corner stands: each tier joins the end of the side tier to the end of the end tier
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local team = if sy < 0 then NEON_BLUE else NEON_ORANGE
			for t = 0, tiers - 1 do
				local off = 260 + t * tierD
				local z = 300 + t * tierH
				local A = Vector3.new(sx * (EX + off), sy * (EY + off * 0.6), 0)
				local B = Vector3.new(sx * (EX + off * 0.6), sy * (EY + GD + off), 0)
				local step = seg("CornerStand", A, B, z, tierH * 1.02, tierD, STRUCT:Lerp(team:Lerp(WALL_NEUTRAL, 0.5), 0.12 + t * 0.03), Enum.Material.Concrete)
				step.CastShadow = true
				if t % 2 == 1 then
					local len = (B - A).Magnitude
					local n = math.floor(len / 180)
					local rot = CFrame.lookAt(Vector3.zero, RenderMap.Dir((B - A).Unit))
					for i = 0, n do
						local p = A + (B - A) * ((i + 0.5) / (n + 1))
						local jitter = ((i * 7919 + t * 104729 + (sx + 2) * 31 + (sy + 2) * 17) % 97) / 97
						local col = if jitter < 0.45 then team:Lerp(Color3.new(1, 1, 1), jitter * 0.4) else Color3.fromHSV(jitter, 0.35, 0.75)
						slab("Crowd", Vector3.new(p.X, p.Y, z + tierH * 0.5 + 40), Vector3.new(60 * S, 80 * S, 90 * S), rot, col, 0, Enum.Material.SmoothPlastic)
					end
				end
			end
		end
	end

	-- outer facade: octagon just outside the light rigs
	local XS, YS = EX + 2180, EY + GD + 2180
	local AY, BX = EY + 0.6 * 2180, EX + 0.6 * 2180
	local ZB, ZT = -60, 1760
	local H2 = ZT - ZB
	local ring = {}
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			table.insert(ring, { Vector3.new(sx * XS, sy * AY, 0), Vector3.new(sx * BX, sy * YS, 0), sy }) -- corner
		end
		table.insert(ring, { Vector3.new(sx * XS, -AY, 0), Vector3.new(sx * XS, AY, 0), 0 }) -- side
	end
	for _, sy in { 1, -1 } do
		table.insert(ring, { Vector3.new(-BX, sy * YS, 0), Vector3.new(BX, sy * YS, 0), sy }) -- end
	end
	for _, r in ring do
		local P, Q, sy = r[1], r[2], r[3]
		local wall = seg("Facade", P, Q, ZB + H2 / 2, H2, 60, FACADE, Enum.Material.Concrete)
		wall.CastShadow = true
		-- columns every ~700 uu, standing proud of the wall
		local d = Q - P
		local len = d.Magnitude
		local outward = Vector3.new(d.Y, -d.X, 0).Unit
		if outward:Dot(P) < 0 then outward = -outward end
		local n = math.max(1, math.floor(len / 700))
		for i = 0, n do
			local p = P + d * (i / n) + outward * 40
			local col = slab("FacadeColumn", Vector3.new(p.X, p.Y, ZB + (H2 + 120) / 2), Vector3.new(70 * S, (H2 + 120) * S, 70 * S), CFrame.identity, Color3.fromRGB(58, 62, 72), 0, Enum.Material.Metal)
			col.CastShadow = true
		end
		-- a light band near the top: team colour behind the goals, white along the sides
		local band = if sy > 0 then NEON_ORANGE elseif sy < 0 then NEON_BLUE else TRIM_WHITE
		local P2, Q2 = P + outward * 32, Q + outward * 32
		seg("FacadeNeon", P2, Q2, ZT - 180, 36, 6, band, Enum.Material.Neon).CastShadow = false
		seg("FacadeNeon", P2, Q2, 260, 14, 6, band, Enum.Material.Neon).CastShadow = false
	end

	-- cantilever roof over the stands: 1500 uu deep from the facade, thin, with a lit inner lip
	local ROOF_D = 1500
	for _, r in ring do
		local P, Q = r[1], r[2]
		local d = Q - P
		local inward = Vector3.new(d.Y, -d.X, 0).Unit
		if inward:Dot(P) > 0 then inward = -inward end
		local shift = inward * (ROOF_D / 2)
		local roof = seg("Roof", P + shift, Q + shift, ZT + 30, 60, ROOF_D, Color3.fromRGB(46, 50, 60), Enum.Material.Metal)
		roof.CastShadow = true
		local lipShift = inward * ROOF_D
		seg("RoofLip", P + lipShift, Q + lipShift, ZT - 10, 30, 24, Color3.fromRGB(255, 244, 220), Enum.Material.Neon).CastShadow = false
	end

	-- solid housing behind each goal chamber (the net shell is see-through)
	for _, sy in { 1, -1 } do
		local hw = GW + 70
		slab("GoalHousing", Vector3.new(0, sy * (EY + GD + 50), (GH + 90) / 2), Vector3.new(hw * 2 * S, (GH + 90) * S, 40 * S), CFrame.identity, STRUCT, 0, Enum.Material.Concrete).CastShadow = true
		slab("GoalHousing", Vector3.new(0, sy * (EY + (GD + 70) / 2), GH + 70), Vector3.new(hw * 2 * S, 40 * S, (GD + 70) * S), CFrame.identity, STRUCT, 0, Enum.Material.Concrete).CastShadow = true
		for _, sx in { 1, -1 } do
			slab("GoalHousing", Vector3.new(sx * (GW + 50), sy * (EY + (GD + 70) / 2), (GH + 90) / 2), Vector3.new(40 * S, (GH + 90) * S, (GD + 70) * S), CFrame.identity, STRUCT, 0, Enum.Material.Concrete).CastShadow = true
		end
	end

	-- caps closing the ends of the back-wall floor ramps at the goal posts (they used to end open)
	local N = 40
	for _, sy in { 1, -1 } do
		local capColor = RAMP_BASE:Lerp(halfColor(sy), 0.22)
		for _, sx in { 1, -1 } do
			for k = 0, N - 1 do
				local w = (k + 0.5) * R / N -- distance in from the start of the ramp (y = EY - R)
				local top = R - math.sqrt(math.max(0, R * R - w * w))
				if top > 1 then
					slab("RampCap", Vector3.new(sx * (GW + 6), sy * (EY - R + w), top / 2), Vector3.new(12 * S, top * S, (R / N + 0.6) * S), CFrame.identity, capColor, 0, Enum.Material.Metal)
				end
			end
			-- and the strip of wall above the cap up to where the post stands
			slab("RampCap", Vector3.new(sx * (GW + 6), sy * (EY - 4), (R + 8) / 2), Vector3.new(12 * S, (R + 8) * S, 8 * S), CFrame.identity, capColor, 0, Enum.Material.Metal)
		end
	end

	-- ground: a plaza round the stadium, grass out to the horizon (parts max out at 2048 studs)
	slab("Ground", Vector3.new(0, 0, -60), Vector3.new((XS + 900) * 2 * S, 2, (YS + 900) * 2 * S), CFrame.identity, Color3.fromRGB(58, 60, 66), 0, Enum.Material.Pavement)
	local T = 38000 -- uu per grass tile (1900 studs)
	for i = -1, 1 do
		for j = -1, 1 do
			slab("OuterGround", Vector3.new(i * T, j * T, -90), Vector3.new(T * S, 2, T * S), CFrame.identity, Color3.fromRGB(62, 104, 52), 0, Enum.Material.Grass).CastShadow = false
		end
	end
end

-- Realistic look within Roblox's renderer (no custom shaders on the platform): Future lighting in the Realistic style,
-- full PBR environment reflections (MaterialVariants and metals pick up the sky), crisper sun shadows, a clear
-- stadium atmosphere and a restrained filmic grade. GraphicsSettings switches the post effects / shadows per preset.
function ArenaVisual.SetupLighting()
	local L = game:GetService("Lighting")
	pcall(function() L.Technology = Enum.Technology.Future end)
	pcall(function() L.LightingStyle = Enum.LightingStyle.Realistic end)
	pcall(function() L.PrioritizeLightingQuality = true end)
	L.ClockTime = 14.8
	L.GeographicLatitude = 35
	L.Brightness = 3.2
	L.ExposureCompensation = 0.1
	L.Ambient = Color3.fromRGB(62, 66, 78)
	L.OutdoorAmbient = Color3.fromRGB(112, 118, 132)
	L.EnvironmentDiffuseScale = 1
	L.EnvironmentSpecularScale = 1
	L.GlobalShadows = true
	L.ShadowSoftness = 0.12
	for _, c in L:GetChildren() do
		if c:IsA("PostEffect") or c:IsA("Atmosphere") then c:Destroy() end
	end
	local atm = Instance.new("Atmosphere")
	atm.Density = 0.2
	atm.Offset = 0.1
	atm.Color = Color3.fromRGB(205, 220, 240)
	atm.Decay = Color3.fromRGB(96, 118, 150)
	atm.Glare = 0.35
	atm.Haze = 0.8
	atm.Parent = L
	-- Roblox's physically based sky (scatters with the Atmosphere) instead of a painted skybox, plus volumetric clouds
	for _, c in L:GetChildren() do
		if c:IsA("Sky") then c:Destroy() end
	end
	local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
	clouds.Cover = 0.55
	clouds.Density = 0.6
	clouds.Color = Color3.fromRGB(245, 247, 252)
	clouds.Parent = workspace.Terrain
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "Bloom"
	bloom.Intensity = 0.45
	bloom.Size = 28
	bloom.Threshold = 1.7
	bloom.Parent = L
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "ColorCorrection"
	cc.Contrast = 0.12
	cc.Saturation = 0.08
	cc.Brightness = 0
	cc.TintColor = Color3.fromRGB(255, 253, 250)
	cc.Parent = L
	local rays = Instance.new("SunRaysEffect")
	rays.Name = "SunRays"
	rays.Intensity = 0.04
	rays.Spread = 0.55
	rays.Parent = L
end

return ArenaVisual
