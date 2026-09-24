--!strict
-- InfectionShared.lua: Infection tag rules shared by the server (authoritative) and the client (prediction + visuals).
-- One car starts infected; touching a healthy car infects it. Healthy cars score for every second they survive,
-- infected cars score for every infection.
--
-- Map "CIUDAD NEÓN": a downtown block grid at night. Glass towers with crowns and antennas, brick mid-rises with water
-- tanks and fire escapes, low shops with awnings and neon signs, lit windows on every façade; streets with lane
-- markings and crosswalks, street lamps / planters / benches that you can hit, two plazas with fountains, ramps onto
-- two rooftops, tunnels through two buildings, billboards, and a skyline all around. Curved edges and an invisible
-- ceiling keep everyone in.
-- Units: UU, sim axes (x across, y along, z up).
local RS = game:GetService("ReplicatedStorage")
local MapKit = require(RS:WaitForChild("Party"):WaitForChild("MapKit"))

local IS = {}

IS.Id = "infection"
IS.MAX_TIME = 70
IS.HALF = 7000 -- the city is a 14000 x 14000 square
IS.WALL_H = 1600
IS.CEIL = 3300 -- invisible ceiling
IS.PIPE_R = 500
IS.TOUCH_DIST = 215 -- centre-to-centre distance that counts as a touch (Octane box 118 x 84, plus a little slack)
IS.GRACE = 1.2 -- s a newly infected car can't pass it on (no ping-pong)
IS.INCUBATION = 3 -- s at the start before patient zero can infect anyone (everyone gets away)
IS.HEALTHY_PER_S = 1 -- points per second survived
IS.PER_INFECTION = 4 -- points per car infected
IS.LAST_BONUS = 6 -- the last survivor(s) at the end
IS.ROOF_GRACE = 4 -- s on a rooftop before a healthy car stops earning (no hiding up there)
IS.REGEN_HEALTHY, IS.REGEN_INFECTED = 12, 70 -- the infected have to be able to catch (boost refills on the ground only)
-- building grid: centres on these coordinates (x and y), BLD half size
IS.GRID = { -4500, -1500, 1500, 4500 }
IS.BLD = 800
-- street centre lines (between / around the buildings): the bots' road network
IS.STREETS = { -6150, -3000, 0, 3000, 6150 }

-- building layout: height per grid cell (row-major over GRID x GRID); 0 = open plaza
local HEIGHTS = {
	{ 2200, 900, 1800, 2600 },
	{ 1200, 0, 500, 1500 },
	{ 1700, 500, 0, 1100 },
	{ 2600, 1400, 800, 2000 },
}
IS.HEIGHTS = HEIGHTS
-- low buildings (500) get a ramp to their roof from this side; tunnel buildings let traffic through along x or y
local RAMPS = { ["2,3"] = "y-", ["3,2"] = "y+" }
local TUNNELS = { ["1,2"] = "y", ["4,3"] = "x" }
local TUNNEL_W, TUNNEL_H = 380, 520

-- a car's position is on a rooftop (over a building footprint, above street level, not inside a tunnel)
function IS.OnRoof(p: Vector3): boolean
	if p.Z < 300 then return false end
	for iy, gy in IS.GRID do
		for ix, gx in IS.GRID do
			if HEIGHTS[iy][ix] > 0 and math.abs(p.X - gx) < IS.BLD + 40 and math.abs(p.Y - gy) < IS.BLD + 40 then
				return true
			end
		end
	end
	return false
end

-- colours
local NEONS = {
	Color3.fromRGB(255, 40, 160), Color3.fromRGB(0, 220, 255), Color3.fromRGB(160, 80, 255),
	Color3.fromRGB(255, 180, 30), Color3.fromRGB(40, 255, 140), Color3.fromRGB(255, 70, 70),
}
local SIGNS = { "BOOST COLA", "TACOS 24H", "ARCADE", "RAMEN", "TALLER RR", "HOTEL NEÓN", "FARMACIA", "KARAOKE", "PIZZA", "GIMNASIO", "CAFÉ", "DISCOTECA" }
local BILLBOARDS = { "PILLA-PILLA", "¡QUE NO TE TOQUEN!", "SUPERSÓNICO", "ROCKET ROBLOX", "TURBO+", "NEÓN 24/7" }

local map: any = nil
function IS.Map(): any
	if map then return map end
	local m = MapKit.new("CiudadNeon")
	local HALF, H, R, B = IS.HALF, IS.WALL_H, IS.PIPE_R, IS.BLD
	local rnd = Random.new(4242)

	local ASPHALT = { color = Color3.fromRGB(64, 66, 76), material = Enum.Material.Asphalt, reflectance = 0.04, name = "Road" }
	local WALK = { color = Color3.fromRGB(110, 112, 122), material = Enum.Material.Concrete, shadow = false }
	local CURB = { color = Color3.fromRGB(150, 152, 160), material = Enum.Material.Concrete, shadow = false }
	local EDGE = { color = Color3.fromRGB(88, 90, 104), material = Enum.Material.Concrete, name = "Edge" }
	local CURVE = { color = Color3.fromRGB(96, 98, 112), material = Enum.Material.Concrete, name = "Curve" }
	local RAMP = { color = Color3.fromRGB(96, 100, 112), material = Enum.Material.DiamondPlate, name = "Ramp" }
	local METAL = { color = Color3.fromRGB(70, 72, 80), material = Enum.Material.Metal }
	local DARKMETAL = { color = Color3.fromRGB(40, 42, 48), material = Enum.Material.Metal }
	local YELLOW = { color = Color3.fromRGB(240, 200, 60), material = Enum.Material.SmoothPlastic, shadow = false }
	local WHITE = { color = Color3.fromRGB(235, 235, 235), material = Enum.Material.SmoothPlastic, shadow = false }
	local function neon(c: Color3, t: number?): any
		return { color = c, material = Enum.Material.Neon, shadow = false, transparency = t or 0 }
	end

	-- ------------------------------------------------------------ ground, edges, ceiling
	m:Floor(-HALF - 600, -HALF - 600, HALF + 600, HALF + 600, 0, ASPHALT, 300)
	for _, s in { 1, -1 } do
		m:Box(Vector3.new(if s > 0 then HALF else -HALF - 600, -HALF - 600, -100), Vector3.new(if s > 0 then HALF + 600 else -HALF, HALF + 600, H), EDGE)
		m:Box(Vector3.new(-HALF, if s > 0 then HALF else -HALF - 600, -100), Vector3.new(HALF, if s > 0 then HALF + 600 else -HALF, H), EDGE)
		m:Barrier(Vector3.new(if s > 0 then HALF else -HALF - 600, -HALF - 600, H), Vector3.new(if s > 0 then HALF + 600 else -HALF, HALF + 600, IS.CEIL))
		m:Barrier(Vector3.new(-HALF, if s > 0 then HALF else -HALF - 600, H), Vector3.new(HALF, if s > 0 then HALF + 600 else -HALF, IS.CEIL))
		m:QuarterPipe(Vector3.new(s * HALF, -HALF + R, 0), Vector3.new(s * HALF, HALF - R, 0), Vector3.new(-s, 0, 0), R, CURVE)
		m:QuarterPipe(Vector3.new(-HALF + R, s * HALF, 0), Vector3.new(HALF - R, s * HALF, 0), Vector3.new(0, -s, 0), R, CURVE)
	end
	m:Barrier(Vector3.new(-HALF - 600, -HALF - 600, IS.CEIL), Vector3.new(HALF + 600, HALF + 600, IS.CEIL + 300))
	-- the edge walls: a concrete barrier with a neon rail and graffiti panels
	for _, s in { 1, -1 } do
		for k = 0, 1 do
			local alongX = k == 0
			local c = if alongX then Vector3.new(0, s * (HALF + 8), 0) else Vector3.new(s * (HALF + 8), 0, 0)
			local yaw = if alongX then (if s > 0 then -math.pi / 2 else math.pi / 2) else (if s > 0 then math.pi else 0)
			m:Prop(c + Vector3.new(0, 0, H - 60), Vector3.new(30, 2 * HALF, 50), yaw, neon(NEONS[1 + (k * 2 + (s > 0 and 1 or 0)) % #NEONS]))
			for i = -6, 6 do
				local off = if alongX then Vector3.new(i * 1000, 0, 0) else Vector3.new(0, i * 1000, 0)
				m:Prop(c + off + Vector3.new(0, 0, (R + H - 120) / 2), Vector3.new(10, 900, H - R - 200), yaw, {
					color = Color3.fromRGB(70, 72, 84), material = Enum.Material.Concrete, shadow = false,
					gui = { kind = "gradient", face = "Front", a = NEONS[rnd:NextInteger(1, #NEONS)], b = Color3.fromRGB(40, 40, 50), ta = 0.55, tb = 0.9, rot = rnd:NextNumber(0, 180), pps = 1, lightInfluence = 0.3 },
				})
			end
		end
	end

	-- ------------------------------------------------------------ streets: lane lines, crosswalks
	for _, c in IS.STREETS do
		local edge = math.abs(c) > 6000
		for k = -7, 6 do
			local mid = k * 1000 + 500
			-- dashed centre line, skipping the crossings
			local nearCross = false
			for _, s2 in IS.STREETS do if math.abs(mid - s2) < 800 then nearCross = true end end
			if not nearCross and not edge then
				m:Prop(Vector3.new(c - 18, mid, 1.5), Vector3.new(14, 420, 3), 0, YELLOW)
				m:Prop(Vector3.new(c + 18, mid, 1.5), Vector3.new(14, 420, 3), 0, YELLOW)
				m:Prop(Vector3.new(mid, c - 18, 1.5), Vector3.new(420, 14, 3), 0, YELLOW)
				m:Prop(Vector3.new(mid, c + 18, 1.5), Vector3.new(420, 14, 3), 0, YELLOW)
			end
		end
	end
	for _, x in IS.STREETS do
		for _, y in IS.STREETS do
			if math.abs(x) < 6000 and math.abs(y) < 6000 then
				-- four crosswalks round the crossing
				for _, d in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, -1, 0) } do
					local p = Vector3.new(x, y, 1.6) + d * 830
					m:Prop(p, Vector3.new(if d.X ~= 0 then 260 else 1300, if d.X ~= 0 then 1300 else 260, 3), 0, {
						color = Color3.new(1, 1, 1), transparency = 1, shadow = false,
						gui = { kind = "stripes", face = "Top", count = 11, a = Color3.fromRGB(235, 235, 235), b = Color3.fromRGB(48, 50, 58), tb = 1, vertical = d.X == 0, pps = 1, lightInfluence = 0.9 },
					})
				end
			end
		end
	end

	-- ------------------------------------------------------------ the blocks
	local n = 0
	local signI, boardI = 0, 0
	for iy, gy in IS.GRID do
		for ix, gx in IS.GRID do
			n += 1
			local h = HEIGHTS[iy][ix]
			local key = ix .. "," .. iy
			local c = Vector3.new(gx, gy, 0)
			local neonC = NEONS[(n % #NEONS) + 1]
			-- sidewalk slab + curb line (visual; street level), street lamps and planters (solid, on the sidewalk)
			m:Prop(c + Vector3.new(0, 0, 4), Vector3.new(2 * B + 320, 2 * B + 320, 8), 0, WALK)
			for _, sx in { 1, -1 } do
				m:Prop(c + Vector3.new(sx * (B + 160), 0, 6), Vector3.new(20, 2 * B + 340, 12), 0, CURB)
				m:Prop(c + Vector3.new(0, sx * (B + 160), 6), Vector3.new(2 * B + 340, 20, 12), 0, CURB)
			end
			for _, sx in { 1, -1 } do
				for _, sy in { 1, -1 } do
					-- a lamp on each corner: solid post, arm over the street, glowing head
					local lp = c + Vector3.new(sx * (B + 110), sy * (B + 110), 0)
					m:Box(lp + Vector3.new(-22, -22, 0), lp + Vector3.new(22, 22, 720), DARKMETAL)
					local arm = lp + Vector3.new(sx * 180, sy * 180, 700)
					m:Beam(lp + Vector3.new(0, 0, 700), arm, 20, DARKMETAL)
					m:Prop(arm + Vector3.new(0, 0, -10), Vector3.new(70, 34, 14), math.pi / 4, neon(Color3.fromRGB(255, 222, 170)))
					m:Light(arm + Vector3.new(0, 0, -60), Color3.fromRGB(255, 205, 150), 45, 2.2)
				end
			end
			if h == 0 then
				-- ---------------- a plaza: marble fountain with water, trees, benches, a neon ring
				m:Prop(c + Vector3.new(0, 0, 6), Vector3.new(2 * B, 2 * B, 10), 0, { color = Color3.fromRGB(150, 146, 140), material = Enum.Material.Pavement })
				m:Block(c + Vector3.new(0, 0, 90), Vector3.new(700, 700, 180), math.pi / 4, { color = Color3.fromRGB(210, 206, 198), material = Enum.Material.Marble, name = "Fountain" })
				m:Block(c + Vector3.new(0, 0, 185), Vector3.new(600, 600, 20), math.pi / 4, { color = Color3.fromRGB(60, 140, 200), material = Enum.Material.Glass, transparency = 0.35, reflectance = 0.2, shadow = false })
				m:Cyl(c + Vector3.new(0, 0, 180), 70, 260, { color = Color3.fromRGB(210, 206, 198), material = Enum.Material.Marble })
				m:Cyl(c + Vector3.new(0, 0, 440), 140, 30, { color = Color3.fromRGB(210, 206, 198), material = Enum.Material.Marble, emit = "water" })
				m:Ring(c + Vector3.new(0, 0, 12), 600, 30, 36, neon(NEONS[2], 0.2))
				m:Light(c + Vector3.new(0, 0, 500), NEONS[2], 40, 2)
				for _, a in { 0.25, 1.25, 2.25, 3.25 } do
					local tp = c + Vector3.new(math.cos(a * math.pi / 2), math.sin(a * math.pi / 2), 0) * 620
					-- a tree in a planter (solid planter)
					m:Box(tp + Vector3.new(-80, -80, 0), tp + Vector3.new(80, 80, 70), { color = Color3.fromRGB(96, 92, 88), material = Enum.Material.Concrete })
					m:Cyl(tp + Vector3.new(0, 0, 70), 18, 260, { color = Color3.fromRGB(80, 56, 36), material = Enum.Material.Wood })
					m:Prop(tp + Vector3.new(0, 0, 400), Vector3.new(300, 300, 300), 0, { color = Color3.fromRGB(46, 110, 60), material = Enum.Material.Grass }, Enum.PartType.Ball)
				end
				for _, a in { 0, 1, 2, 3 } do
					local bp = c + Vector3.new(math.cos(a * math.pi / 2), math.sin(a * math.pi / 2), 0) * 520
					m:Block(bp + Vector3.new(0, 0, 30), Vector3.new(60, 240, 60), a * math.pi / 2, { color = Color3.fromRGB(120, 84, 52), material = Enum.Material.WoodPlanks })
				end
			else
				local tall = h >= 1700
				local brick = not tall and h >= 800
				local look: any
				if tall then
					look = { color = Color3.fromRGB(58, 70, 92), material = Enum.Material.SmoothPlastic, reflectance = 0.15, name = "Tower",
						gui = { kind = "windows", face = { "Front", "Back", "Left", "Right" }, cols = 11, rows = math.min(18, math.floor(h / 140)), seed = n * 17, density = 0.55,
							lit = { Color3.fromRGB(190, 225, 255), Color3.fromRGB(150, 200, 255), Color3.fromRGB(255, 240, 210) }, dark = Color3.fromRGB(24, 32, 50) } }
				elseif brick then
					look = { color = Color3.fromRGB(128, 70, 56), material = Enum.Material.Brick, name = "Brick",
						gui = { kind = "windows", face = { "Front", "Back", "Left", "Right" }, cols = 9, rows = math.min(11, math.floor(h / 140)), seed = n * 31, density = 0.5, dark = Color3.fromRGB(34, 26, 26) } }
				else
					look = { color = Color3.fromRGB(150, 140, 126), material = Enum.Material.Concrete, name = "Shop",
						gui = { kind = "windows", face = { "Front", "Back", "Left", "Right" }, cols = 8, rows = 3, seed = n * 7, density = 0.7, shop = neonC } }
				end
				if TUNNELS[key] then
					local along = TUNNELS[key]
					local TW, TH = TUNNEL_W, TUNNEL_H
					if along == "y" then
						m:Box(c + Vector3.new(-B, -B, 0), c + Vector3.new(-TW, B, h), look)
						m:Box(c + Vector3.new(TW, -B, 0), c + Vector3.new(B, B, h), look)
						m:Box(c + Vector3.new(-TW, -B, TH), c + Vector3.new(TW, B, h), look)
						for _, sx in { 1, -1 } do
							m:Prop(c + Vector3.new(sx * (TW - 10), 0, TH - 40), Vector3.new(20, 2 * B, 30), 0, neon(neonC))
							m:Prop(c + Vector3.new(sx * (TW - 10), 0, 40), Vector3.new(20, 2 * B, 20), 0, neon(Color3.fromRGB(255, 200, 60)))
						end
						for _, sy in { 1, -1 } do
							m:Sign(c + Vector3.new(0, sy * (B + 12), TH + 120), Vector3.new(10, 2 * TW + 200, 180), if sy > 0 then math.pi / 2 else -math.pi / 2, "TÚNEL", Color3.fromRGB(255, 220, 90), { color = Color3.fromRGB(20, 20, 26) })
						end
					else
						m:Box(c + Vector3.new(-B, -B, 0), c + Vector3.new(B, -TW, h), look)
						m:Box(c + Vector3.new(-B, TW, 0), c + Vector3.new(B, B, h), look)
						m:Box(c + Vector3.new(-B, -TW, TH), c + Vector3.new(B, TW, h), look)
						for _, sy in { 1, -1 } do
							m:Prop(c + Vector3.new(0, sy * (TW - 10), TH - 40), Vector3.new(2 * B, 20, 30), 0, neon(neonC))
							m:Prop(c + Vector3.new(0, sy * (TW - 10), 40), Vector3.new(2 * B, 20, 20), 0, neon(Color3.fromRGB(255, 200, 60)))
						end
						for _, sx in { 1, -1 } do
							m:Sign(c + Vector3.new(sx * (B + 12), 0, TH + 120), Vector3.new(10, 2 * TW + 200, 180), if sx > 0 then 0 else math.pi, "TÚNEL", Color3.fromRGB(255, 220, 90), { color = Color3.fromRGB(20, 20, 26) })
						end
					end
					m:Light(c + Vector3.new(0, 0, TH - 100), neonC, 30, 2)
				else
					m:Box(c + Vector3.new(-B, -B, 0), c + Vector3.new(B, B, h), look)
				end
				-- ground-floor band, roof parapet, a stair house and AC units
				for _, sx in { 1, -1 } do
					m:Prop(c + Vector3.new(sx * (B + 6), 0, h - 20), Vector3.new(24, 2 * B + 24, 60), 0, { color = Color3.fromRGB(70, 72, 80), material = Enum.Material.Concrete })
					m:Prop(c + Vector3.new(0, sx * (B + 6), h - 20), Vector3.new(2 * B + 24, 24, 60), 0, { color = Color3.fromRGB(70, 72, 80), material = Enum.Material.Concrete })
				end
				if not RAMPS[key] then
					m:Prop(c + Vector3.new(-B * 0.4, B * 0.35, h + 110), Vector3.new(320, 260, 220), 0, { color = Color3.fromRGB(96, 98, 106), material = Enum.Material.Concrete })
					for i = 0, 2 do
						m:Prop(c + Vector3.new(B * 0.3 + i * 150, -B * 0.4, h + 45), Vector3.new(120, 120, 90), 0, METAL)
					end
				end
				if tall then
					-- a glowing crown and an antenna with a red beacon
					for _, sx in { 1, -1 } do
						m:Prop(c + Vector3.new(sx * (B + 14), 0, h - 90), Vector3.new(16, 2 * B, 30), 0, neon(neonC))
						m:Prop(c + Vector3.new(0, sx * (B + 14), h - 90), Vector3.new(2 * B, 16, 30), 0, neon(neonC))
					end
					m:Cyl(c + Vector3.new(B * 0.5, B * 0.5, h), 14, 520, METAL)
					m:Prop(c + Vector3.new(B * 0.5, B * 0.5, h + 540), Vector3.new(50, 50, 50), 0, neon(Color3.fromRGB(255, 40, 40)), Enum.PartType.Ball)
					-- vertical light fins on the corners
					for _, sx in { 1, -1 } do
						for _, sy in { 1, -1 } do
							m:Beam(c + Vector3.new(sx * (B + 8), sy * (B + 8), 200), c + Vector3.new(sx * (B + 8), sy * (B + 8), h - 120), 18, neon(neonC, 0.3))
						end
					end
					-- a billboard on the face toward the city centre
					boardI += 1
					local toC = if math.abs(gx) > math.abs(gy) then Vector3.new(-math.sign(gx), 0, 0) else Vector3.new(0, -math.sign(gy), 0)
					m:Sign(c + toC * (B + 30) + Vector3.new(0, 0, h * 0.62), Vector3.new(20, 1200, 520), math.atan2(toC.Y, toC.X), BILLBOARDS[(boardI % #BILLBOARDS) + 1], Color3.new(1, 1, 1), {
						color = Color3.fromRGB(14, 14, 20), shadow = false,
						gui = { kind = "gradient", face = "Front", a = NEONS[(boardI % #NEONS) + 1], b = NEONS[((boardI + 2) % #NEONS) + 1], rot = 20, pps = 1, lightInfluence = 0, brightness = 1.2 },
					})
				elseif brick then
					-- water tank on legs + a fire escape zig-zag on one face
					local wt = c + Vector3.new(B * 0.35, B * 0.35, h)
					for _, lx in { -1, 1 } do
						for _, ly in { -1, 1 } do
							m:Beam(wt + Vector3.new(lx * 110, ly * 110, 0), wt + Vector3.new(lx * 110, ly * 110, 220), 18, DARKMETAL)
						end
					end
					m:Cyl(wt + Vector3.new(0, 0, 220), 170, 260, { color = Color3.fromRGB(110, 78, 50), material = Enum.Material.WoodPlanks })
					m:Prop(wt + Vector3.new(0, 0, 510), Vector3.new(360, 360, 60), math.pi / 4, { color = Color3.fromRGB(60, 50, 44), material = Enum.Material.Slate, shape = "wedge" })
					local fx = c + Vector3.new(B + 60, 0, 0)
					for z = 260, h - 200, 240 do
						m:Prop(fx + Vector3.new(0, 0, z), Vector3.new(120, 600, 10), 0, DARKMETAL)
						m:Beam(fx + Vector3.new(40, -260, z), fx + Vector3.new(40, 260, z + 240), 14, DARKMETAL)
					end
				else
					-- a shop: awning + neon sign
					signI += 1
					for _, d in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) } do
						m:Prop(c + d * (B + 90) + Vector3.new(0, 0, 330), Vector3.new(180, 2 * B - 200, 60), math.atan2(d.Y, d.X), { color = neonC:Lerp(Color3.new(0.2, 0.2, 0.2), 0.3), material = Enum.Material.Fabric, shape = "wedge" })
						m:Sign(c + d * (B + 16) + Vector3.new(0, 0, h - 150), Vector3.new(14, 1100, 220), math.atan2(d.Y, d.X), SIGNS[(signI % #SIGNS) + 1], neonC, { color = Color3.fromRGB(14, 14, 18), shadow = false })
					end
				end
				if RAMPS[key] then
					local sgn = if RAMPS[key] == "y+" then 1 else -1
					-- rises toward the building; striped edges, a glowing roof deck up top
					m:Ramp(c + Vector3.new(0, sgn * (B + 800), 0), Vector3.new(1600, 900, h), if sgn > 0 then -math.pi / 2 else math.pi / 2, RAMP)
					for _, sx in { 1, -1 } do
						m:Beam(c + Vector3.new(sx * 430, sgn * (B + 1600), 20), c + Vector3.new(sx * 430, sgn * B, h + 20), 40, { color = Color3.fromRGB(240, 190, 30), material = Enum.Material.SmoothPlastic })
					end
					m:Prop(c + Vector3.new(0, 0, h + 3), Vector3.new(2 * B - 100, 2 * B - 100, 6), 0, { color = Color3.fromRGB(70, 74, 86), material = Enum.Material.DiamondPlate })
					m:Ring(c + Vector3.new(0, 0, h + 8), 500, 30, 32, neon(neonC, 0.2))
					m:Prop(c + Vector3.new(0, 0, h + 8), Vector3.new(600, 600, 2), 0, {
						color = Color3.new(0, 0, 0), transparency = 1, shadow = false,
						gui = { kind = "text", face = "Top", text = "H", color = Color3.fromRGB(240, 240, 240), pps = 2 },
					})
				end
			end
		end
	end

	-- ------------------------------------------------------------ the skyline all around
	for i = 0, 27 do
		local a = i / 28 * math.pi * 2
		local r = 11500 + rnd:NextNumber(0, 2500)
		local p = Vector3.new(math.cos(a), math.sin(a), 0) * r
		local h = rnd:NextNumber(2500, 7000)
		local w = rnd:NextNumber(1500, 2800)
		m:Prop(p + Vector3.new(0, 0, h / 2 - 200), Vector3.new(w, w, h), a + math.pi, {
			color = Color3.fromRGB(34, 38, 52), material = Enum.Material.SmoothPlastic, shadow = false,
			gui = { kind = "windows", face = "Front", cols = 6, rows = 12, seed = i * 13, density = 0.4, dark = Color3.fromRGB(22, 26, 38) },
		})
		if i % 3 == 0 then
			m:Prop(p + Vector3.new(0, 0, h + 10), Vector3.new(60, 60, 60), 0, neon(Color3.fromRGB(255, 40, 40)), Enum.PartType.Ball)
		end
	end

	-- spawns on the street crossings, facing the centre
	for _, x in { -6150, 0, 6150 } do
		for _, y in { -6150, 0, 6150 } do
			if not (x == 0 and y == 0) then
				m:Spawn(Vector3.new(x, y, 17), math.atan2(-y, -x))
			end
		end
	end
	m.data.center = Vector3.new(0, 0, 17)
	m.lighting = {
		ClockTime = 20.2, Brightness = 1.6, ExposureCompensation = 0.4,
		Ambient = Color3.fromRGB(132, 122, 166), OutdoorAmbient = Color3.fromRGB(146, 134, 184),
		atmosphere = { Density = 0.3, Offset = 0.05, Color = Color3.fromRGB(120, 90, 170), Decay = Color3.fromRGB(60, 40, 110), Glare = 0, Haze = 1.2 },
		bloom = { Intensity = 1.3, Size = 30, Threshold = 1.15 },
		grade = { Brightness = 0.03, Contrast = 0.14, Saturation = 0.2, TintColor = Color3.fromRGB(242, 236, 255) },
	}
	map = m
	return m
end

function IS.WorldOptions(): any
	return { boostPads = false, seed = 1, arena = IS.Map():Arena() }
end

-- bumps still push (it's a chase, not a demo game)
IS.DemoMode = "disabled"

function IS.SetupWorld(world: any) end

-- boost refills only with the wheels on the ground: nobody hovers forever on regenerated boost (a full tank is ~3 s
-- of flight)
local function grounded(car: any): boolean
	return (car.numWheelsInContact or 0) >= 3
end

-- car.infected is set by the server on its cars and by the view on our predicted car
function IS.PreTick(car: any, dt: number)
	if not grounded(car) then return end
	local regen = if car.infected then IS.REGEN_INFECTED else IS.REGEN_HEALTHY
	car.boost = math.min(100, (car.boost or 0) + regen * dt)
end

return IS
