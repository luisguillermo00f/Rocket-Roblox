--!strict
-- MinigolfShared.lua: Giant Minigolf rules shared by the server (authoritative) and the client (prediction + visuals).
-- Modelled on the Rocket League workshop minigolf maps: every player has THEIR OWN ball on the same hole (cars and
-- other players' balls pass through each other), every touch of your ball is a stroke, a ball that falls off the
-- course comes back to its last resting spot with a one-stroke penalty, and the fewest strokes over the round wins.
-- Played on "ISLAS DEL GOLF": six giant holes floating over a sea of clouds; each round plays three of them.
-- Units: UU, sim axes (x across, y along, z up). Hole-local coordinates: tee at the origin, playing toward +y.
local RS = game:GetService("ReplicatedStorage")
local MapKit = require(RS:WaitForChild("Party"):WaitForChild("MapKit"))

local MG = {}

MG.Id = "minigolf"
MG.HOLES_PER_ROUND = 3
MG.HOLE_TIME = 23 -- s to play a hole
MG.BETWEEN = 2.4 -- s between holes (cars frozen, moved to the next tee)
MG.MAX_TIME = 78
MG.CUP_R = 175 -- horizontal radius of the cup (ball radius 91.25)
MG.SINK_SPEED = 1700 -- faster than this and the ball lips out
MG.MAGNET_R, MG.MAGNET_SPEED = 380, 1000 -- a slow ball this close is pulled into the cup
MG.UNSUNK_PENALTY = 2 -- strokes added to a hole not finished in time
MG.MAX_OVER_PAR = 4 -- a hole closes for a player at par + this (one disaster hole can't decide the round)
MG.STROKE_GAP = 0.35 -- s without contact that makes the next touch a new stroke
MG.PUSH_STROKE = 1.0 -- s of continuous pushing that counts as another stroke
MG.OOB_DROP = 900 -- below the hole's lowest floor by this much = out of bounds
MG.BOOST_REGEN = 22
MG.LANES = { -360, -120, 120, 360 }
MG.SPACING = 9000 -- hole origins along x

-- grass with mowing stripes (a striped overlay on the top face)
local function mown(c: Color3, name: string, count: number): any
	return { color = c, material = Enum.Material.Grass, name = name,
		gui = { kind = "stripes", face = "Top", count = count, a = c:Lerp(Color3.new(1, 1, 0.8), 0.12), b = c:Lerp(Color3.new(0, 0.1, 0), 0.1), ta = 0.35, tb = 0.35, vertical = true, pps = 1, lightInfluence = 1 } }
end
local GRASS = mown(Color3.fromRGB(92, 172, 72), "Fairway", 12)
local GREEN = mown(Color3.fromRGB(112, 200, 88), "Green", 18)
local TEE = mown(Color3.fromRGB(76, 146, 62), "Tee", 8)
local WALL = { color = Color3.fromRGB(198, 182, 150), material = Enum.Material.Limestone, name = "Wall" }
local MOSS = { color = Color3.fromRGB(86, 140, 62), material = Enum.Material.Grass }
local LEAF = { Color3.fromRGB(58, 132, 58), Color3.fromRGB(72, 150, 60), Color3.fromRGB(46, 112, 52), Color3.fromRGB(150, 170, 60) }
local WOOD = { color = Color3.fromRGB(150, 105, 65), material = Enum.Material.WoodPlanks, name = "Wood" }
local RAMP = { color = Color3.fromRGB(96, 180, 78), material = Enum.Material.Grass, name = "Ramp" }
local BUMP = { color = Color3.fromRGB(240, 70, 70), material = Enum.Material.SmoothPlastic, name = "Bumper" }
local ROCK = { color = Color3.fromRGB(110, 96, 84), material = Enum.Material.Rock, name = "Rock" }
local CURVE = { color = Color3.fromRGB(225, 222, 210), material = Enum.Material.SmoothPlastic, name = "Curve" }
local FLAG_COLS = { Color3.fromRGB(255, 60, 60), Color3.fromRGB(255, 200, 40), Color3.fromRGB(60, 160, 255), Color3.fromRGB(255, 120, 220), Color3.fromRGB(80, 230, 120), Color3.fromRGB(255, 150, 40) }

-- a hole builder draws into the map in hole-local coordinates (origin o)
local function builder(m: any, o: Vector3)
	local b = { o = o, m = m }
	function b.box(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, look: any)
		m:Box(o + Vector3.new(math.min(x0, x1), math.min(y0, y1), math.min(z0, z1)), o + Vector3.new(math.max(x0, x1), math.max(y0, y1), math.max(z0, z1)), look)
	end
	function b.floor(x0: number, y0: number, x1: number, y1: number, z: number, look: any)
		b.box(x0, y0, z - 250, x1, y1, z, look)
	end
	function b.block(x: number, y: number, z: number, size: Vector3, yaw: number, look: any)
		m:Block(o + Vector3.new(x, y, z), size, yaw, look)
	end
	function b.ramp(x: number, y: number, z: number, size: Vector3, yaw: number, look: any)
		m:Ramp(o + Vector3.new(x, y, z), size, yaw, look)
	end
	function b.prop(x: number, y: number, z: number, size: Vector3, yaw: number, look: any, shape: Enum.PartType?)
		m:Prop(o + Vector3.new(x, y, z), size, yaw, look, shape)
	end
	-- a wall along a segment (outside of it by half its thickness), from z0 up to z1
	function b.wall(x0: number, y0: number, x1: number, y1: number, z0: number, z1: number)
		local T = 200
		if y0 == y1 then
			b.box(math.min(x0, x1) - T / 2, y0 - T / 2, z0, math.max(x0, x1) + T / 2, y0 + T / 2, z1, WALL)
		else
			b.box(x0 - T / 2, math.min(y0, y1) - T / 2, z0, x0 + T / 2, math.max(y0, y1) + T / 2, z1, WALL)
		end
		-- a mossy cap along the top, and stone posts every ~900 uu
		if y0 == y1 then
			b.prop((x0 + x1) / 2, y0, z1 + 14, Vector3.new(math.abs(x1 - x0) + T + 20, T + 30, 28), 0, MOSS)
			local n = math.max(1, math.floor(math.abs(x1 - x0) / 900))
			for i = 0, n do
				local x = math.min(x0, x1) + math.abs(x1 - x0) * i / n
				b.prop(x, y0, z1 + 40, Vector3.new(T + 60, T + 60, 80), 0, { color = Color3.fromRGB(128, 120, 108), material = Enum.Material.Slate })
			end
		else
			b.prop(x0, (y0 + y1) / 2, z1 + 14, Vector3.new(T + 30, math.abs(y1 - y0) + T + 20, 28), 0, MOSS)
			local n = math.max(1, math.floor(math.abs(y1 - y0) / 900))
			for i = 0, n do
				local y = math.min(y0, y1) + math.abs(y1 - y0) * i / n
				b.prop(x0, y, z1 + 40, Vector3.new(T + 60, T + 60, 80), 0, { color = Color3.fromRGB(128, 120, 108), material = Enum.Material.Slate })
			end
		end
	end
	-- a tree: trunk + a cluster of leaf balls
	function b.tree(x: number, y: number, z: number, size: number?)
		local sz = size or 1
		m:Cyl(o + Vector3.new(x, y, z), 40 * sz, 420 * sz, { color = Color3.fromRGB(96, 66, 42), material = Enum.Material.Wood })
		for i = 1, 4 do
			local a = i * 1.7 + x * 0.001
			local off = Vector3.new(math.cos(a), math.sin(a), 0) * 110 * sz
			b.prop(x + off.X, y + off.Y, z + (400 + (i % 2) * 120) * sz, Vector3.new(320 * sz, 320 * sz, 320 * sz), 0, { color = LEAF[(i + math.floor(math.abs(x))) % #LEAF + 1], material = Enum.Material.Grass }, Enum.PartType.Ball)
		end
	end
	function b.bush(x: number, y: number, z: number, r: number?)
		local rr = r or 140
		b.prop(x, y, z + rr * 0.6, Vector3.new(rr * 2, rr * 2, rr * 2), 0, { color = LEAF[(math.floor(math.abs(x + y)) % #LEAF) + 1], material = Enum.Material.Grass }, Enum.PartType.Ball)
		if (math.floor(math.abs(x * 7 + y)) % 3) == 0 then
			b.prop(x + rr * 0.4, y, z + rr * 1.3, Vector3.new(50, 50, 50), 0, { color = Color3.fromRGB(255, 120, 170), material = Enum.Material.SmoothPlastic, shadow = false }, Enum.PartType.Ball)
		end
	end
	-- the island under a piece of course (decoration): a grass rim with bushes, irregular rock tapering down into the
	-- clouds, hanging roots and a few floating stones
	local rnd = Random.new(math.floor(o.X) % 997 + 11)
	function b.island(x0: number, y0: number, x1: number, y1: number, z: number)
		local cx, cy, w, l = (x0 + x1) / 2, (y0 + y1) / 2, math.abs(x1 - x0), math.abs(y1 - y0)
		-- grass rim just outside the course (the walls stand on it) and a soil band under it
		b.prop(cx, cy, z - 60, Vector3.new(w + 700, l + 700, 120), 0, { color = Color3.fromRGB(84, 150, 64), material = Enum.Material.Grass })
		b.prop(cx, cy, z - 230, Vector3.new(w + 760, l + 760, 240), 0, { color = Color3.fromRGB(116, 84, 58), material = Enum.Material.Ground })
		-- rock: layered chunks, each layer narrower, turned a little, off-centre
		for k = 0, 4 do
			local sc = 1 - k * 0.19
			for _ = 1, 3 do
				local ox, oy = rnd:NextNumber(-0.15, 0.15) * w, rnd:NextNumber(-0.12, 0.12) * l
				b.prop(cx + ox, cy + oy, z - 450 - k * 430 - rnd:NextNumber(0, 120), Vector3.new((w + 500) * sc * rnd:NextNumber(0.55, 0.85), (l + 500) * sc * rnd:NextNumber(0.55, 0.85), 480), rnd:NextNumber(-0.25, 0.25),
					{ color = Color3.fromRGB(104 + rnd:NextInteger(-12, 12), 92 + rnd:NextInteger(-10, 10), 80 + rnd:NextInteger(-8, 8)), material = Enum.Material.Rock })
			end
		end
		b.prop(cx, cy, z - 2550, Vector3.new(w * 0.2 + 200, l * 0.12 + 200, 700), 0.3, { color = Color3.fromRGB(96, 86, 76), material = Enum.Material.Rock })
		-- hanging roots / vines along the rim
		for _ = 1, math.floor((w + l) / 700) do
			local side = rnd:NextInteger(0, 3)
			local x = if side < 2 then cx + rnd:NextNumber(-w / 2, w / 2) else cx + (if side == 2 then 1 else -1) * (w / 2 + 330)
			local y = if side >= 2 then cy + rnd:NextNumber(-l / 2, l / 2) else cy + (if side == 0 then 1 else -1) * (l / 2 + 330)
			m:Beam(o + Vector3.new(x, y, z - 120), o + Vector3.new(x + rnd:NextNumber(-60, 60), y + rnd:NextNumber(-60, 60), z - 120 - rnd:NextNumber(400, 1100)), 22, { color = Color3.fromRGB(62, 110, 48), material = Enum.Material.Grass, shadow = false })
		end
		-- bushes on the rim
		for _ = 1, math.floor((w + l) / 500) do
			local side = rnd:NextInteger(0, 3)
			local x = if side < 2 then cx + rnd:NextNumber(-w / 2 - 250, w / 2 + 250) else cx + (if side == 2 then 1 else -1) * (w / 2 + 220)
			local y = if side >= 2 then cy + rnd:NextNumber(-l / 2 - 250, l / 2 + 250) else cy + (if side == 0 then 1 else -1) * (l / 2 + 220)
			b.bush(x, y, z, rnd:NextNumber(90, 170))
		end
		-- floating stones nearby
		for _ = 1, 3 do
			local a = rnd:NextNumber(0, math.pi * 2)
			local r = (w + l) / 4 + rnd:NextNumber(600, 1400)
			local sz = rnd:NextNumber(180, 420)
			b.prop(cx + math.cos(a) * r, cy + math.sin(a) * r, z - rnd:NextNumber(300, 1500), Vector3.new(sz, sz * 0.8, sz * 0.7), rnd:NextNumber(0, 3), { color = Color3.fromRGB(110, 98, 86), material = Enum.Material.Rock })
		end
	end
	-- a waterfall pouring off an edge (x, y on the rim; dir = outward)
	function b.waterfall(x: number, y: number, z: number, dir: Vector3, width: number)
		local p = Vector3.new(x, y, z) + dir * 40
		b.prop(p.X, p.Y, z - 900, Vector3.new(30, width, 1800), math.atan2(dir.Y, dir.X), { color = Color3.fromRGB(150, 210, 250), material = Enum.Material.Glass, transparency = 0.35, reflectance = 0.1, shadow = false, emit = "fall" })
		b.prop(p.X - dir.X * 60, p.Y - dir.Y * 60, z + 4, Vector3.new(220, width, 8), math.atan2(dir.Y, dir.X), { color = Color3.fromRGB(120, 190, 240), material = Enum.Material.Glass, transparency = 0.25, shadow = false })
	end
	-- the tee: a darker mat and a sign on a post: hole number, name and par
	function b.teeSign(k: number, name: string, par: number, x: number, y: number, z: number)
		b.prop(0, 400, z + 4, Vector3.new(700, 900, 6), 0, { color = Color3.fromRGB(58, 118, 50), material = Enum.Material.Fabric, shadow = false })
		m:Cyl(o + Vector3.new(x, y, z), 26, 700, { color = Color3.fromRGB(96, 66, 42), material = Enum.Material.Wood })
		m:Sign(o + Vector3.new(x, y + 30, z + 760), Vector3.new(20, 900, 380), math.pi / 2, "HOYO " .. k .. " · " .. name .. " · PAR " .. par, Color3.fromRGB(60, 40, 24), {
			color = Color3.fromRGB(226, 200, 156), material = Enum.Material.WoodPlanks, glowText = false,
		})
	end
	-- the cup: a dark hole, a white rim and a flag
	function b.cup(x: number, y: number, z: number, flag: Color3)
		b.prop(x, y, z + 2, Vector3.new(MG.CUP_R * 2, MG.CUP_R * 2, 4), 0, { color = Color3.fromRGB(12, 12, 14), material = Enum.Material.SmoothPlastic, shadow = false, upright = true }, Enum.PartType.Cylinder)
		b.prop(x, y, z + 1, Vector3.new(MG.CUP_R * 2 + 70, MG.CUP_R * 2 + 70, 3), 0, { color = Color3.fromRGB(245, 245, 245), material = Enum.Material.SmoothPlastic, shadow = false, upright = true }, Enum.PartType.Cylinder)
		b.prop(x + MG.CUP_R + 40, y, z + 700, Vector3.new(24, 24, 1400), 0, { color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Metal, upright = true }, Enum.PartType.Cylinder)
		b.prop(x + MG.CUP_R + 40, y + 260, z + 1230, Vector3.new(500, 10, 320), math.pi / 2, { color = flag, material = Enum.Material.Fabric, shadow = false })
		b.prop(x + MG.CUP_R + 40, y, z + 1420, Vector3.new(50, 50, 50), 0, { color = Color3.fromRGB(250, 220, 90), material = Enum.Material.Metal }, Enum.PartType.Ball)
		m:Light(o + Vector3.new(x, y, z + 300), flag, 30, 2)
	end
	return b
end

-- the six holes: name, par, cup (local), lowest floor z, build(b, flag)
local HOLES = {
	{
		name = "LA RAMPA", par = 2, cup = Vector3.new(0, 6200, 500), minZ = 0, bounds = { -1100, -900, 1100, 7200 },
		path = { Vector3.new(0, 2600, 0), Vector3.new(0, 4800, 500) },
		build = function(b: any, flag: Color3)
			b.floor(-900, -700, 900, 3000, 0, TEE)
			b.ramp(0, 3700, 0, Vector3.new(1400, 1800, 500), math.pi / 2, RAMP)
			b.box(-900, 4400, -250, 900, 7000, 500, GREEN)
			b.wall(-900, -700, -900, 4400, -250, 320)
			b.wall(-900, 4400, -900, 7000, -250, 950)
			b.wall(900, -700, 900, 4400, -250, 320)
			b.wall(900, 4400, 900, 7000, -250, 950)
			b.wall(-900, -700, 900, -700, -250, 320)
			b.wall(-900, 7000, 900, 7000, -250, 950)
			b.island(-900, -700, 900, 7000, 0)
			b.cup(0, 6200, 500, flag)
			-- a lighthouse beyond the green
			b.m:Cyl(b.o + Vector3.new(0, 7750, 500), 260, 1600, { color = Color3.fromRGB(240, 240, 236), material = Enum.Material.SmoothPlastic,
				gui = { kind = "stripes", face = { "Front", "Back", "Left", "Right" }, count = 6, a = Color3.fromRGB(220, 50, 40), b = Color3.fromRGB(240, 240, 236), pps = 1 } })
			b.m:Cyl(b.o + Vector3.new(0, 7750, 2100), 200, 220, { color = Color3.fromRGB(255, 236, 170), material = Enum.Material.Neon, glow = { color = Color3.fromRGB(255, 230, 160), range = 40, brightness = 2 } })
			b.m:Cyl(b.o + Vector3.new(0, 7750, 2320), 240, 60, { color = Color3.fromRGB(60, 60, 66), material = Enum.Material.Metal })
			b.tree(-1150, 1200, 0, 1.1)
			b.tree(1150, 2600, 0, 0.9)
			b.tree(-1150, 5200, 500, 1)
			b.waterfall(1250, 800, 0, Vector3.new(1, 0, 0), 500)
		end,
	},
	{
		name = "ZIG-ZAG", par = 3, cup = Vector3.new(4500, 6400, 0), minZ = 0, bounds = { -1100, -900, 5600, 7400 },
		path = { Vector3.new(0, 2800, 0), Vector3.new(4500, 2800, 0) },
		build = function(b: any, flag: Color3)
			b.floor(-900, -700, 900, 3600, 0, TEE)
			b.floor(-900, 2000, 5400, 3600, 0, GRASS)
			b.floor(3600, 2000, 5400, 7200, 0, GREEN)
			local Z0, Z1 = -250, 330
			b.wall(-900, -700, 900, -700, Z0, Z1)
			b.wall(900, -700, 900, 2000, Z0, Z1)
			b.wall(900, 2000, 5400, 2000, Z0, Z1)
			b.wall(5400, 2000, 5400, 7200, Z0, Z1)
			b.wall(3600, 7200, 5400, 7200, Z0, Z1)
			b.wall(3600, 3600, 3600, 7200, Z0, Z1)
			b.wall(-900, 3600, 3600, 3600, Z0, Z1)
			b.wall(-900, -700, -900, 3600, Z0, Z1)
			-- 45-degree banks in the outer corners
			b.block(-656, 3356, 200, Vector3.new(990, 300, 400), math.pi / 4, WOOD)
			b.block(5156, 2244, 200, Vector3.new(990, 300, 400), math.pi / 4, WOOD)
			b.block(1900, 2800, 150, Vector3.new(300, 300, 300), math.pi / 4, BUMP)
			b.island(-900, -700, 900, 3600, 0)
			b.island(900, 2000, 3600, 3600, 0)
			b.island(3600, 2000, 5400, 7200, 0)
			b.cup(4500, 6400, 0, flag)
			-- a windmill in the inner corner (outside the course)
			local wm = Vector3.new(2250, 1300, 0)
			b.island(1850, 900, 2650, 1700, 0)
			b.m:Cyl(b.o + wm, 300, 1300, { color = Color3.fromRGB(226, 214, 190), material = Enum.Material.Plaster })
			b.prop(wm.X, wm.Y, 1450, Vector3.new(700, 700, 300), 0, { color = Color3.fromRGB(150, 60, 40), material = Enum.Material.Slate, shape = "wedge" })
			for i = 0, 3 do
				local a = i * math.pi / 2 + 0.3
				local tip = Vector3.new(wm.X + math.cos(a) * 900, wm.Y - 330, 1150 + math.sin(a) * 900)
				b.m:Beam(b.o + Vector3.new(wm.X, wm.Y - 330, 1150), b.o + tip, 150, { color = Color3.fromRGB(236, 228, 210), material = Enum.Material.Fabric }, false, 12)
			end
			b.tree(-1250, 200, 0, 1)
			b.tree(5850, 4200, 0, 1.2)
		end,
	},
	{
		name = "EL EMBUDO", par = 2, cup = Vector3.new(0, 4200, 0), minZ = 0, bounds = { -2500, -900, 2500, 6700 },
		path = { Vector3.new(0, 2000, 300) },
		build = function(b: any, flag: Color3)
			local cy = 4200
			local H = 320
			-- the plateau (tee side and the rim round the funnel), at z = H
			b.box(-2300, -700, -250, 2300, cy - 1900, H, TEE)
			b.box(-2300, cy - 1900, -250, -1900, cy + 1900, H, GRASS)
			b.box(1900, cy - 1900, -250, 2300, cy + 1900, H, GRASS)
			b.box(-2300, cy + 1900, -250, 2300, cy + 2300, H, GRASS)
			-- the funnel floor and four ramps rising outward from it
			b.floor(-1900, cy - 1900, 1900, cy + 1900, 0, GREEN)
			for k = 0, 3 do
				local a = k * math.pi / 2
				local d = Vector3.new(math.cos(a), math.sin(a), 0)
				b.ramp(d.X * 1200, cy + d.Y * 1200, 0, Vector3.new(1400, 3800, H), a, RAMP)
			end
			b.wall(-2300, -700, -2300, cy + 2300, -250, 640)
			b.wall(2300, -700, 2300, cy + 2300, -250, 640)
			b.wall(-2300, -700, 2300, -700, -250, 620)
			b.wall(-2300, cy + 2300, 2300, cy + 2300, -250, 640)
			-- two posts guarding the way in
			b.block(-800, 1400, H + 200, Vector3.new(350, 350, 400), math.pi / 4, BUMP)
			b.block(800, 1400, H + 200, Vector3.new(350, 350, 400), math.pi / 4, BUMP)
			b.island(-2300, -700, 2300, cy + 2300, 0)
			b.cup(0, cy, 0, flag)
			-- a little volcano beside the funnel, on its own islet, smoking
			b.island(2900, cy - 1400, 3700, cy - 600, 0)
			for i = 0, 3 do
				b.prop(3300, cy - 1000, 200 + i * 300, Vector3.new(1400 - i * 300, 1400 - i * 300, 300), i * 0.4, { color = Color3.fromRGB(80 - i * 6, 60 - i * 4, 52), material = Enum.Material.Basalt })
			end
			b.prop(3300, cy - 1000, 1330, Vector3.new(300, 300, 40), 0, { color = Color3.fromRGB(255, 110, 30), material = Enum.Material.Neon, emit = "embers" })
			b.prop(3300, cy - 1000, 1400, Vector3.new(60, 60, 60), 0, { color = Color3.new(0, 0, 0), transparency = 1, emit = "smoke" })
			b.tree(-2750, 400, 0, 1.1)
			b.tree(-2750, 3600, 0, 0.9)
		end,
	},
	{
		name = "ESCALERA", par = 3, cup = Vector3.new(0, 8000, 0), minZ = 0, bounds = { -1200, -900, 1200, 9000 },
		path = { Vector3.new(0, 3300, 600), Vector3.new(0, 5300, 300), Vector3.new(0, 7200, 0) },
		build = function(b: any, flag: Color3)
			local levels = { { -700, 1800, 900 }, { 2800, 3800, 600 }, { 4800, 5800, 300 }, { 6800, 8800, 0 } }
			for i, L in levels do
				b.box(-1000, L[1], -250, 1000, L[2], L[3], if i == 1 then TEE elseif i == 4 then GREEN else GRASS)
				if i < #levels then
					-- a slope down to the next level (rises back toward the tee)
					local nxt = levels[i + 1]
					b.box(-1000, L[2], -250, 1000, nxt[1], nxt[3], GRASS)
					b.ramp(0, (L[2] + nxt[1]) / 2, nxt[3], Vector3.new(nxt[1] - L[2], 2000, L[3] - nxt[3]), -math.pi / 2, RAMP)
				end
			end
			b.wall(-1000, -700, -1000, 8800, -250, 1400)
			b.wall(1000, -700, 1000, 8800, -250, 1400)
			b.wall(-1000, -700, 1000, -700, -250, 1400)
			b.wall(-1000, 8800, 1000, 8800, -250, 700)
			b.block(0, 3300, 600 + 150, Vector3.new(300, 700, 300), 0, BUMP)
			b.block(-500, 5300, 300 + 150, Vector3.new(300, 300, 300), math.pi / 4, BUMP)
			b.block(500, 5300, 300 + 150, Vector3.new(300, 300, 300), math.pi / 4, BUMP)
			b.island(-1000, -700, 1000, 8800, 0)
			b.cup(0, 8000, 0, flag)
			-- stone arches over each slope, a waterfall down the side
			for _, y in { 2300, 4300, 6300 } do
				for _, sx in { 1, -1 } do
					b.prop(sx * 1150, y, 1400, Vector3.new(220, 220, 2000), 0, { color = Color3.fromRGB(170, 160, 146), material = Enum.Material.Cobblestone })
				end
				b.prop(0, y, 2450, Vector3.new(260, 2520, 200), 0, { color = Color3.fromRGB(170, 160, 146), material = Enum.Material.Cobblestone })
			end
			b.waterfall(-1260, 1200, 900, Vector3.new(-1, 0, 0), 600)
			b.tree(1350, 400, 900, 1)
			b.tree(1350, 7600, 0, 1.2)
		end,
	},
	{
		name = "EL PUENTE", par = 3, cup = Vector3.new(0, 8300, 0), minZ = 0, bounds = { -1500, -900, 1500, 9400 },
		path = { Vector3.new(0, 2600, 0), Vector3.new(0, 4500, 0), Vector3.new(0, 6400, 0) },
		build = function(b: any, flag: Color3)
			b.floor(-1200, -700, 1200, 1400, 0, TEE)
			b.floor(-300, 1400, 300, 3900, 0, WOOD)
			b.floor(-1300, 3900, 1300, 5100, 0, GRASS)
			b.floor(-300, 5100, 300, 7000, 0, WOOD)
			b.floor(-1400, 7000, 1400, 9200, 0, GREEN)
			b.wall(-1200, -700, 1200, -700, -250, 400)
			b.wall(-1200, -700, -1200, 1400, -250, 300)
			b.wall(1200, -700, 1200, 1400, -250, 300)
			b.block(-600, 4500, 150, Vector3.new(300, 300, 300), math.pi / 4, BUMP)
			b.block(600, 4500, 150, Vector3.new(300, 300, 300), math.pi / 4, BUMP)
			b.wall(-1400, 9200, 1400, 9200, -250, 500)
			b.wall(-1400, 7000, -1400, 9200, -250, 400)
			b.wall(1400, 7000, 1400, 9200, -250, 400)
			-- rope posts along the planks (decoration only)
			for y = 1600, 6800, 600 do
				if y < 3900 or y > 5100 then
					for _, sx in { 1, -1 } do
						b.prop(sx * 320, y, 120, Vector3.new(30, 30, 240), 0, WOOD)
					end
				end
			end
			b.island(-1200, -700, 1200, 1400, 0)
			b.island(-1300, 3900, 1300, 5100, 0)
			b.island(-1400, 7000, 1400, 9200, 0)
			b.cup(0, 8300, 0, flag)
			-- stone gates with lanterns at both ends of the planks
			for _, y in { 1500, 6900 } do
				for _, sx in { 1, -1 } do
					b.prop(sx * 520, y, 500, Vector3.new(200, 200, 1000), 0, { color = Color3.fromRGB(150, 140, 128), material = Enum.Material.Cobblestone })
					b.prop(sx * 520, y, 1040, Vector3.new(90, 90, 90), 0, { color = Color3.fromRGB(255, 200, 110), material = Enum.Material.Neon, glow = { color = Color3.fromRGB(255, 190, 110), range = 24, brightness = 2 } }, Enum.PartType.Ball)
				end
			end
			b.tree(-1550, 100, 0, 1)
			b.tree(1650, 8600, 0, 1.1)
			b.waterfall(0, 5150, 0, Vector3.new(0, 1, 0), 900)
		end,
	},
	{
		name = "PINBALL", par = 3, cup = Vector3.new(0, 6700, 0), minZ = 0, bounds = { -2000, -900, 2000, 7800 },
		path = { Vector3.new(-1100, 3500, 0), Vector3.new(0, 5600, 0) },
		build = function(b: any, flag: Color3)
			b.floor(-1800, -700, 1800, 7600, 0, GRASS)
			b.prop(0, 6700, 2, Vector3.new(2400, 2400, 4), 0, { color = GREEN.color, material = Enum.Material.Grass })
			b.wall(-1800, -700, -1800, 7600, -250, 420)
			b.wall(1800, -700, 1800, 7600, -250, 420)
			b.wall(-1800, -700, 1800, -700, -250, 420)
			b.wall(-1800, 7600, 1800, 7600, -250, 420)
			for _, p in { { 0, 2000 }, { -900, 3000 }, { 900, 3000 }, { 0, 4000 }, { -1200, 4900 }, { 1200, 4900 }, { 500, 5300 } } do
				b.block(p[1], p[2], 170, Vector3.new(380, 380, 340), math.pi / 4, BUMP)
				b.prop(p[1], p[2], 350, Vector3.new(300, 300, 30), math.pi / 4, { color = Color3.fromRGB(255, 230, 120), material = Enum.Material.Neon, shadow = false })
			end
			-- a U guard round the cup, open toward the tee
			b.block(-620, 6700, 150, Vector3.new(200, 900, 300), 0, WOOD)
			b.block(620, 6700, 150, Vector3.new(200, 900, 300), 0, WOOD)
			b.block(0, 7200, 150, Vector3.new(1440, 200, 300), 0, WOOD)
			b.island(-1800, -700, 1800, 7600, 0)
			b.cup(0, 6700, 0, flag)
			-- pinball dressing: lane arrows and a lit backboard
			for i = 0, 4 do
				b.m:Beam(b.o + Vector3.new(-160, 700 + i * 260, 3), b.o + Vector3.new(0, 820 + i * 260, 3), 40, { color = Color3.fromRGB(255, 220, 90), material = Enum.Material.Neon, shadow = false }, false, 3)
				b.m:Beam(b.o + Vector3.new(160, 700 + i * 260, 3), b.o + Vector3.new(0, 820 + i * 260, 3), 40, { color = Color3.fromRGB(255, 220, 90), material = Enum.Material.Neon, shadow = false }, false, 3)
			end
			b.m:Sign(b.o + Vector3.new(0, 7760, 1500), Vector3.new(20, 3200, 900), -math.pi / 2, "PINBALL", Color3.fromRGB(255, 240, 200), {
				color = Color3.fromRGB(30, 20, 50), gui = { kind = "gradient", face = "Front", a = Color3.fromRGB(120, 40, 200), b = Color3.fromRGB(255, 60, 140), rot = 0, pps = 1, lightInfluence = 0 },
			})
		end,
	},
}
MG.HOLES = HOLES

-- hole k's origin in the world
function MG.Origin(k: number): Vector3
	return Vector3.new((k - 3.5) * MG.SPACING, 0, 0)
end

function MG.Cup(k: number): Vector3
	return MG.Origin(k) + HOLES[k].cup
end

-- the tee spot for a lane: ball and car (car behind the ball, facing +y)
function MG.Tee(k: number, lane: number): (Vector3, Vector3)
	local o = MG.Origin(k)
	-- fairness: everyone tees off from the SAME spot (balls and cars pass through each other)
	local x = 0
	local z = if k == 4 then 900 elseif k == 3 then 320 else 0
	-- far enough from the back wall that the chase camera (~400 uu behind the car) stays inside the course
	return o + Vector3.new(x, 700, z + 92), o + Vector3.new(x, 180, z + 17)
end

function MG.KillZ(k: number): number
	return HOLES[k].minZ - MG.OOB_DROP
end

-- a point (world) has left hole k: fallen off, or flown over a wall out of its footprint
function MG.OutOfBounds(k: number, p: Vector3): boolean
	if p.Z < MG.KillZ(k) then return true end
	local b = HOLES[k].bounds
	local l = p - MG.Origin(k)
	return l.X < b[1] - 300 or l.X > b[3] + 300 or l.Y < b[2] - 300 or l.Y > b[4] + 300
end

local map: any = nil
function MG.Map(): any
	if map then return map end
	local m = MapKit.new("IslasDelGolf")
	for k, h in HOLES do
		local b = builder(m, MG.Origin(k))
		h.build(b, FLAG_COLS[k])
		local tz = if k == 4 then 900 elseif k == 3 then 320 else 0
		b.teeSign(k, h.name, h.par, h.bounds[1] - 120, 300, tz)
	end
	-- a sea of clouds below and a few drifting clusters above (each cloud = a cluster of puffs)
	local rng = Random.new(7)
	local CLOUD = { color = Color3.fromRGB(252, 252, 255), material = Enum.Material.SmoothPlastic, transparency = 0.05, shadow = false }
	for i = 1, 46 do
		local low = i <= 34
		local x, y = rng:NextNumber(-34000, 34000), rng:NextNumber(-9000, 18000)
		local z = if low then -4300 + rng:NextNumber(-500, 400) else rng:NextNumber(1500, 4000)
		if not low and math.abs(y - 4000) < 6000 then y += 14000 end
		local base = if low then rng:NextNumber(1800, 3200) else rng:NextNumber(700, 1300)
		for _ = 1, 5 do
			local sz = base * rng:NextNumber(0.6, 1.1)
			m:Prop(Vector3.new(x + rng:NextNumber(-1.2, 1.2) * base, y + rng:NextNumber(-0.6, 0.6) * base, z + rng:NextNumber(0, 0.4) * base), Vector3.new(sz, sz, sz), 0, CLOUD, Enum.PartType.Ball)
		end
	end
	m.lighting = {
		ClockTime = 9.6, Brightness = 3, ExposureCompensation = 0.1, GeographicLatitude = 30,
		Ambient = Color3.fromRGB(120, 130, 140), OutdoorAmbient = Color3.fromRGB(150, 160, 170),
		atmosphere = { Density = 0.25, Offset = 0.2, Color = Color3.fromRGB(200, 225, 255), Decay = Color3.fromRGB(120, 160, 210), Glare = 0.3, Haze = 1.2 },
		bloom = { Intensity = 0.6, Size = 24, Threshold = 1.8 },
		grade = { Brightness = 0.02, Contrast = 0.08, Saturation = 0.14, TintColor = Color3.fromRGB(255, 252, 244) },
	}
	map = m
	return m
end

function MG.WorldOptions(): any
	return { boostPads = false, seed = 1, arena = MG.Map():Arena(), carCarCollision = false }
end

MG.DemoMode = "disabled"

function MG.SetupWorld(world: any)
	world.golfCup = nil -- the current hole's cup (set by the server's minigame and the client's view)
end

-- boost refills only with the wheels on the ground: nobody hovers forever on regenerated boost (a full tank is ~3 s
-- of flight)
local function grounded(car: any): boolean
	return (car.numWheelsInContact or 0) >= 3
end

function MG.PreTick(car: any, dt: number)
	if not grounded(car) then return end
	car.boost = math.min(100, (car.boost or 0) + MG.BOOST_REGEN * dt)
end

-- per tick after the physics step (server: every ball; client prediction: our own ball): a slow ball near the cup
-- is pulled in, like the lip of a real cup
local BTU = 50
local function magnet(world: any, ball: any)
	local cup = world.golfCup
	if not cup then return end
	local b = ball.body
	local p = b.pos * BTU
	local d = Vector3.new(cup.X - p.X, cup.Y - p.Y, 0)
	local dist = d.Magnitude
	if dist > MG.MAGNET_R or dist < 1 or math.abs(p.Z - (cup.Z + 92)) > 60 then return end
	local v = b.vel * BTU
	local flat = Vector3.new(v.X, v.Y, 0)
	if flat.Magnitude > MG.MAGNET_SPEED then return end
	local pull = d.Unit * (1 - dist / MG.MAGNET_R) * 900 * world.tickTime
	b.vel = (v + pull) / BTU
end

function MG.PostStep(world: any, live: boolean)
	if not live then return end
	if world.ballEnabled then magnet(world, world.ball) end
	for _, e in world.extraBalls do
		if e.enabled ~= false then magnet(world, e.ball) end
	end
end

return MG
