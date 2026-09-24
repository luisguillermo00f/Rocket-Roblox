--!strict
-- DerbyShared.lua: Demolition Derby rules shared by the server (authoritative) and the client (prediction + visuals).
-- No ball: demolish the others by hitting them at supersonic speed (Rocket League's demo rule, every car against
-- every car).
--
-- Map "EL COLISEO": a Roman amphitheatre at sunset. An octagonal sand bowl with curved walls, the podium wall dressed
-- with arches, pilasters and torches, stone stands full of people under a striped velarium, the emperor's box, a raised
-- stone platform with braziers and ramps, four square piers to hide behind and iron kickers. An invisible dome keeps
-- every car inside.
-- Units: UU, sim axes (x across, y along, z up).
local RS = game:GetService("ReplicatedStorage")
local MapKit = require(RS:WaitForChild("Party"):WaitForChild("MapKit"))

local DS = {}

DS.Id = "derby"
DS.MAX_TIME = 75
DS.FRENZY_AT = 55 -- seconds in: the last stretch demolishes on ANY contact
DS.APOTHEM = 5200 -- centre to the inside face of a wall
DS.WALL_H = 2400
DS.DOME_Z = 3000 -- invisible ceiling
DS.PIPE_R = 520
DS.PLAT_HALF, DS.PLAT_H = 1200, 420 -- the centre platform
DS.BOOST_REGEN = 34
DS.RESPAWN_BOOST = 60
DS.SPAWN_SHIELD = 2.5 -- s after (re)spawning: can't be demolished and can't demolish
DS.FARM_WINDOW = 8 -- s: demolishing the same car again this soon scores nothing
DS.BOUNTY = 2 -- points for demolishing the leader (when they lead by 2+)

local SAND = Color3.fromRGB(206, 176, 128)
local STONE = Color3.fromRGB(196, 178, 146)
local STONE_DK = Color3.fromRGB(150, 132, 104)
local SHADOW = Color3.fromRGB(34, 26, 20)
local RED = Color3.fromRGB(176, 34, 30)
local GOLD = Color3.fromRGB(226, 176, 60)
local IRON = Color3.fromRGB(96, 90, 84)

local map: any = nil
function DS.Map(): any
	if map then return map end
	local m = MapKit.new("Coliseo")
	local A, H, R = DS.APOTHEM, DS.WALL_H, DS.PIPE_R
	local side = 2 * A * math.tan(math.pi / 8) -- one octagon side
	local rnd = Random.new(1717)

	local WALL = { color = STONE, material = Enum.Material.Limestone, name = "PodiumWall" }
	local CURVE = { color = Color3.fromRGB(186, 160, 118), material = Enum.Material.Sandstone, name = "Curve" }
	local STONE_L = { color = STONE, material = Enum.Material.Limestone }
	local STONE_D = { color = STONE_DK, material = Enum.Material.Limestone }
	local DARK = { color = SHADOW, material = Enum.Material.Slate, shadow = false }
	local WOOD = { color = Color3.fromRGB(120, 84, 52), material = Enum.Material.WoodPlanks }
	local IRONL = { color = IRON, material = Enum.Material.CorrodedMetal }

	-- ------------------------------------------------------------ physics
	m:Floor(-A - 900, -A - 900, A + 900, A + 900, 0, { color = SAND, material = Enum.Material.Sand, name = "Arena" }, 300)
	for k = 0, 7 do
		local a = k * math.pi / 4
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		local along = Vector3.new(-math.sin(a), math.cos(a), 0)
		m:Block(out * (A + 400) + Vector3.new(0, 0, H / 2 - 100), Vector3.new(800, side + 700, H + 200), a, WALL)
		m:Block(out * (A + 400) + Vector3.new(0, 0, (H + DS.DOME_Z) / 2 + 50), Vector3.new(800, side + 700, DS.DOME_Z - H + 300), a, { visible = false })
		local c = out * A
		m:QuarterPipe(c - along * (side / 2 + 40), c + along * (side / 2 + 40), -out, R, CURVE)
	end
	m:Barrier(Vector3.new(-A - 1500, -A - 1500, DS.DOME_Z), Vector3.new(A + 1500, A + 1500, DS.DOME_Z + 300))
	-- centre platform + a ramp up each side
	local P, PH = DS.PLAT_HALF, DS.PLAT_H
	m:Box(Vector3.new(-P, -P, -100), Vector3.new(P, P, PH), { color = STONE_DK, material = Enum.Material.Limestone, name = "Platform",
		gui = { kind = "panel", face = { "Front", "Back", "Left", "Right" }, border = Color3.fromRGB(128, 112, 88), fill = Color3.fromRGB(160, 142, 112), accent = RED, accentY = 0.12, accentH = 0.06, pps = 2 } })
	for k = 0, 3 do
		local a = k * math.pi / 2
		local dir = Vector3.new(math.cos(a), math.sin(a), 0)
		m:Ramp(dir * (P + 700), Vector3.new(1400, 1500, PH), a + math.pi, WOOD)
	end
	-- four square piers
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			m:Block(Vector3.new(sx * 2900, sy * 2900, 800), Vector3.new(560, 560, 1600), math.pi / 4, { color = STONE, material = Enum.Material.Limestone, name = "Pier",
				gui = { kind = "panel", face = { "Front", "Back", "Left", "Right" }, border = Color3.fromRGB(150, 132, 104), fill = STONE, accent = RED, accentY = 0.84, accentH = 0.04, pps = 2 } })
		end
	end
	-- iron kickers between the piers, pointing round the bowl
	for k = 0, 3 do
		local a = k * math.pi / 2
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		m:Ramp(out * 3500, Vector3.new(700, 600, 260), a + math.pi / 2, { color = Color3.fromRGB(128, 120, 108), material = Enum.Material.DiamondPlate, name = "Kicker", reflectance = 0.05 })
	end

	-- ------------------------------------------------------------ the podium wall: arches, pilasters, torches, cornice
	local ARCHES = 5
	for k = 0, 7 do
		local a = k * math.pi / 4
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		local along = Vector3.new(-math.sin(a), math.cos(a), 0)
		local inward = -out
		local yawIn = a + math.pi -- faces the arena
		local yawAlong = a + math.pi / 2
		local face = out * (A - 4)
		local span = side / ARCHES
		for i = 0, ARCHES - 1 do
			local c = face + along * (-side / 2 + span * (i + 0.5))
			-- an arch: a dark opening with a round head, framed by a lighter voussoir ring
			m:Prop(c + Vector3.new(0, 0, R + 340), Vector3.new(10, 440, 680), yawIn, DARK)
			m:Prop(c + Vector3.new(0, 0, R + 680), Vector3.new(440, 10, 440), yawAlong, DARK, Enum.PartType.Cylinder)
			m:Prop(c + inward * -2 + Vector3.new(0, 0, R + 680), Vector3.new(540, 8, 540), yawAlong, STONE_D, Enum.PartType.Cylinder)
			-- a smaller window above
			m:Prop(c + Vector3.new(0, 0, 1720), Vector3.new(10, 260, 260), yawIn, DARK)
			-- pilaster between arches (+ capital), and a torch on every other one
			if i > 0 then
				local pc = face + along * (-side / 2 + span * i)
				m:Prop(pc + inward * 30 + Vector3.new(0, 0, (R + 1500) / 2), Vector3.new(60, 150, 1500 - R), yawIn, STONE_L)
				m:Prop(pc + inward * 50 + Vector3.new(0, 0, 1520), Vector3.new(100, 220, 60), yawIn, STONE_D)
				if i % 2 == 1 then
					local tc = pc + inward * 90 + Vector3.new(0, 0, 1250)
					m:Beam(tc - inward * 60 + Vector3.new(0, 0, -80), tc, 22, IRONL)
					m:Cyl(tc, 38, 40, { color = IRON, material = Enum.Material.Metal, shadow = false, fire = { size = 4, heat = 8 } })
					m:Light(tc + Vector3.new(0, 0, 120), Color3.fromRGB(255, 150, 60), 22, 1.6)
				end
			end
		end
		-- cornice and a red band along the top of the podium
		m:Beam(face + inward * 40 - along * side / 2 + Vector3.new(0, 0, H - 60), face + inward * 40 + along * side / 2 + Vector3.new(0, 0, H - 60), 110, STONE_D, false, 80)
		m:Beam(face + inward * 12 - along * side / 2 + Vector3.new(0, 0, 1600), face + inward * 12 + along * side / 2 + Vector3.new(0, 0, 1600), 50, { color = RED, material = Enum.Material.Fabric }, false, 20)
		-- fire bowls on the corners of the octagon
		local corner = (out * A + along * (side / 2)) * 0.985
		m:Cyl(corner + Vector3.new(0, 0, H), 110, 90, { color = IRON, material = Enum.Material.Metal, fire = { size = 12, heat = 12 }, emit = "embers" })
		m:Light(corner + Vector3.new(0, 0, H + 200), Color3.fromRGB(255, 150, 60), 50, 2.2)
	end

	-- ------------------------------------------------------------ the cavea: stands, crowd, velarium, emperor's box
	local crowdCols = { Color3.fromRGB(176, 40, 36), Color3.fromRGB(226, 190, 90), Color3.fromRGB(236, 230, 214), Color3.fromRGB(120, 60, 40), Color3.fromRGB(70, 90, 140), Color3.fromRGB(90, 120, 60) }
	for k = 0, 7 do
		local a = k * math.pi / 4
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		local along = Vector3.new(-math.sin(a), math.cos(a), 0)
		local yawIn = a + math.pi
		for t = 0, 6 do
			local dist = A + 900 + t * 380
			local z = H + 60 + t * 230
			local w = side + 700 + t * 330
			m:Prop(out * dist + Vector3.new(0, 0, z - 120), Vector3.new(380, w, 240), yawIn, { color = if t % 2 == 0 then STONE else STONE_DK, material = Enum.Material.Limestone, shadow = false })
			local n = math.floor(w / 300)
			for i = 0, n - 1 do
				if rnd:NextNumber() < 0.8 and not (k == 2 and t <= 2 and math.abs(i - n / 2) < 3) then
					local pos = out * (dist - 40) + along * (-w / 2 + (i + 0.5) * w / n) + Vector3.new(0, 0, z + 50)
					m:Prop(pos, Vector3.new(150, w / n - 50, 100 + rnd:NextNumber() * 40), yawIn, { color = crowdCols[rnd:NextInteger(1, #crowdCols)], material = Enum.Material.Fabric, shadow = false })
				end
			end
		end
		-- the outer wall, with arcades
		local ow = out * (A + 3700)
		m:Prop(ow + Vector3.new(0, 0, H + 1100), Vector3.new(300, side + 3000, 2600), yawIn, { color = STONE_DK, material = Enum.Material.Limestone })
		for i = -3, 3 do
			m:Prop(ow - out * 160 + along * (i * 560) + Vector3.new(0, 0, H + 1300), Vector3.new(10, 280, 520), yawIn, DARK)
		end
		-- velarium: a mast on the outer wall and a striped canvas slanting in over the upper tiers
		m:Cyl(ow - out * 60 + Vector3.new(0, 0, H + 2400), 40, 900, WOOD)
		m:Prop(out * (A + 2600) + Vector3.new(0, 0, H + 2150), Vector3.new(2400, side + 1800, 30), yawIn, {
			color = Color3.fromRGB(236, 224, 196), material = Enum.Material.Fabric, shadow = true,
			gui = { kind = "stripes", face = { "Top", "Bottom" }, count = 10, a = RED, b = Color3.fromRGB(236, 224, 196), vertical = true, pps = 1 },
		})
		-- banners hanging from the podium
		if k % 2 == 0 then
			m:Prop(out * (A + 30) + Vector3.new(0, 0, H - 500), Vector3.new(16, 520, 800), yawIn, {
				color = if k % 4 == 0 then RED else GOLD, material = Enum.Material.Fabric, shadow = false,
				gui = { kind = "stripes", face = "Front", count = 3, a = if k % 4 == 0 then RED else GOLD, b = Color3.fromRGB(80, 20, 16), vertical = false, pps = 2 },
			})
		end
	end
	-- the emperor's box (north side)
	do
		local out = Vector3.new(0, 1, 0)
		local base = out * (A + 700) + Vector3.new(0, 0, H + 150)
		m:Prop(base, Vector3.new(1400, 2200, 300), 0, { color = Color3.fromRGB(230, 222, 204), material = Enum.Material.Marble })
		m:Prop(base + Vector3.new(0, -640, 160), Vector3.new(2200, 60, 120), 0, { color = GOLD, material = Enum.Material.Foil })
		for i = -2, 2 do
			m:Cyl(base + Vector3.new(i * 500, -560, 150), 50, 900, { color = Color3.fromRGB(240, 236, 226), material = Enum.Material.Marble })
		end
		m:Prop(base + Vector3.new(0, 0, 1100), Vector3.new(1600, 2400, 80), 0, { color = RED, material = Enum.Material.Fabric })
		m:Sign(out * (A + 40) + Vector3.new(0, 0, H - 220), Vector3.new(12, 1800, 360), -math.pi / 2, "PALCO DEL CÉSAR", GOLD, {
			color = Color3.fromRGB(90, 20, 18), material = Enum.Material.Fabric, glowText = false,
		})
	end

	-- ------------------------------------------------------------ the sand: raked rings, tyre marks, the emblem
	for _, r in { 1700, 2500, 4200 } do
		m:Ring(Vector3.new(0, 0, 1.5), r, 70, 64, { color = SAND:Lerp(Color3.new(0.3, 0.2, 0.1), 0.12), material = Enum.Material.Sand, shadow = false })
	end
	for _ = 1, 40 do
		local a, r = rnd:NextNumber(0, 2 * math.pi), rnd:NextNumber(1600, 4700)
		local p = Vector3.new(math.cos(a), math.sin(a), 0) * r
		local d = Vector3.new(math.cos(a + math.pi / 2 + rnd:NextNumber(-0.6, 0.6)), math.sin(a + math.pi / 2 + rnd:NextNumber(-0.6, 0.6)), 0)
		local len = rnd:NextNumber(400, 1200)
		for _, off in { -45, 45 } do
			local o = Vector3.new(-d.Y, d.X, 0) * off
			m:Beam(p + o + Vector3.new(0, 0, 2), p + o + d * len + Vector3.new(0, 0, 2), 24, { color = Color3.fromRGB(120, 96, 66), material = Enum.Material.Sand, transparency = 0.35, shadow = false }, false, 2)
		end
	end
	-- platform top: iron grate, a red border and the emblem; braziers on its corners
	m:Prop(Vector3.new(0, 0, PH + 3), Vector3.new(2 * P - 160, 2 * P - 160, 6), 0, { color = Color3.fromRGB(70, 66, 62), material = Enum.Material.DiamondPlate, shadow = false })
	m:Prop(Vector3.new(0, 0, PH + 7), Vector3.new(1500, 700, 2), 0, {
		color = Color3.new(0, 0, 0), transparency = 1, shadow = false,
		gui = { kind = "text", face = "Top", text = "DERBI", color = Color3.fromRGB(230, 60, 40), glow = false, pps = 2 },
	})
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local c = Vector3.new(sx * (P - 110), sy * (P - 110), PH)
			m:Cyl(c, 70, 260, { color = IRON, material = Enum.Material.Metal })
			m:Cyl(c + Vector3.new(0, 0, 260), 120, 50, { color = IRON, material = Enum.Material.Metal, fire = { size = 9, heat = 12 }, emit = "embers" })
			m:Light(c + Vector3.new(0, 0, 450), Color3.fromRGB(255, 150, 60), 40, 2)
		end
	end
	-- ramp rails and kicker hazard stripes
	for k = 0, 3 do
		local a = k * math.pi / 2
		local dir = Vector3.new(math.cos(a), math.sin(a), 0)
		local across = Vector3.new(-dir.Y, dir.X, 0)
		for _, s in { -1, 1 } do
			local o = across * s * 760
			m:Beam(dir * (P + 1400) + o + Vector3.new(0, 0, 60), dir * P + o + Vector3.new(0, 0, PH + 60), 30, IRONL)
		end
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		m:Prop(out * 3500 + Vector3.new(0, 0, 2), Vector3.new(900, 800, 3), a + math.pi / 2, {
			color = Color3.new(0, 0, 0), transparency = 1, shadow = false,
			gui = { kind = "stripes", face = "Top", count = 8, a = Color3.fromRGB(240, 190, 30), b = Color3.fromRGB(30, 28, 26), vertical = true, pps = 1 },
		})
	end
	-- pier caps with fire
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local c = Vector3.new(sx * 2900, sy * 2900, 1600)
			m:Block(c + Vector3.new(0, 0, 40), Vector3.new(680, 680, 80), math.pi / 4, { color = STONE_DK, material = Enum.Material.Limestone })
			m:Cyl(c + Vector3.new(0, 0, 80), 150, 60, { color = IRON, material = Enum.Material.Metal, fire = { size = 10, heat = 12 } })
			m:Light(c + Vector3.new(0, 0, 300), Color3.fromRGB(255, 150, 60), 45, 2)
		end
	end
	-- sunset fill light over the sand
	for _, p in { Vector3.new(0, 0, 900), Vector3.new(2600, 0, 900), Vector3.new(-2600, 0, 900), Vector3.new(0, 2600, 900), Vector3.new(0, -2600, 900) } do
		m:Light(p, Color3.fromRGB(255, 210, 160), 60, 0.8)
	end

	-- spawns round the bowl, facing the centre
	for k = 0, 7 do
		local a = (k + 0.5) * math.pi / 4
		local p = Vector3.new(math.cos(a), math.sin(a), 0) * 3900
		m:Spawn(Vector3.new(p.X, p.Y, 17), a + math.pi)
	end
	m.lighting = {
		ClockTime = 17.7, Brightness = 2.6, ExposureCompensation = 0.1, GeographicLatitude = 20,
		Ambient = Color3.fromRGB(130, 110, 96), OutdoorAmbient = Color3.fromRGB(160, 130, 110),
		atmosphere = { Density = 0.3, Offset = 0.1, Color = Color3.fromRGB(255, 190, 140), Decay = Color3.fromRGB(150, 90, 70), Glare = 0.4, Haze = 1.5 },
		bloom = { Intensity = 0.8, Size = 30, Threshold = 1.6 },
		grade = { Brightness = 0.02, Contrast = 0.1, Saturation = 0.12, TintColor = Color3.fromRGB(255, 240, 222) },
	}
	map = m
	return m
end

function DS.WorldOptions(): any
	return { boostPads = false, seed = 1, arena = DS.Map():Arena() }
end

DS.DemoMode = "normal"

function DS.SetupWorld(world: any)
	world.enableTeamDemos = true -- everyone against everyone
	-- spawn shield: a car within its shield time can't be demolished and can't demolish (car.shieldUntil = world tick)
	world.demoFilter = function(bumper: any, victim: any): boolean
		local t = world.tickCount
		return not ((bumper.shieldUntil and t < bumper.shieldUntil) or (victim.shieldUntil and t < victim.shieldUntil))
	end
end

-- boost refills only with the wheels on the ground: nobody hovers forever on regenerated boost (a full tank is ~3 s
-- of flight)
local function grounded(car: any): boolean
	return (car.numWheelsInContact or 0) >= 3
end

function DS.PreTick(car: any, dt: number)
	if not grounded(car) then return end
	car.boost = math.min(100, (car.boost or 0) + DS.BOOST_REGEN * dt)
end

return DS
