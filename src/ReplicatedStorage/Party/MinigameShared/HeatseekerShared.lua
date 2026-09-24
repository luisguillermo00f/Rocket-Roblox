--!strict
-- HeatseekerShared.lua: Heatseeker rules shared by the server (authoritative) and the client (prediction + visuals).
-- Like Rocket League's Heatseeker: once a car touches the ball it LOCKS ON to the goal of the team that did NOT touch it
-- and homes in on it, faster after every touch. Defend by getting in its way; hit it back and it turns around.
--
-- Map "CÚPULA NEÓN": an indoor arena, smaller than a Soccar pitch. Rounded corners (vertical curves) and curved
-- floor / ceiling joints like Rocket League, recessed goals with posts, crossbar and net, a lower wall of panels with
-- an LED ribbon, a glass upper wall with the crowd behind, a truss ceiling with light rigs and a hanging jumbotron.
-- Units: UU, sim axes (x across, y along, z up). Team 0 (blue) defends -y and attacks the +y goal.
local RS = game:GetService("ReplicatedStorage")
local MapKit = require(RS:WaitForChild("Party"):WaitForChild("MapKit"))

local HS = {}

HS.Id = "heatseeker"
HS.MAX_TIME = 75
HS.WIN_GOALS = 3
HS.HALF_X, HS.HALF_Y, HS.CEIL = 3400, 4600, 2000
HS.GOAL_W, HS.GOAL_H, HS.GOAL_D = 1600, 700, 880 -- mouth width / height, chamber depth
HS.FLOOR_R, HS.CEIL_R, HS.CORNER_R = 440, 520, 1000
HS.START_SPEED, HS.SPEED_STEP, HS.MAX_SPEED = 1500, 260, 4300 -- uu/s
HS.TURN_RATE = 3.2 -- rad/s the ball can turn toward its goal
HS.BOOST_REGEN = 30
HS.LONE_BOOST_REGEN = 75 -- fairness: the single player of a 2v1 refills much faster (still only on the ground)
HS.CAMP_TIME = 2.5 -- s a car may sit (or hover) inside its OWN goal before it's pushed back onto the pitch
HS.CELEBRATE = 2.6 -- s after a goal before the next kickoff
HS.STALL_TIME = 7 -- s with the ball crawling (or parked on something) before it's re-dropped at the centre
HS.JUMBO_HALF, HS.JUMBO_Z = 700, 1560 -- the jumbotron hangs from the ceiling over the centre (solid)

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local ICE = Color3.fromRGB(170, 225, 255)

-- the goal the ball flies to after `team` touched it (the other team's), as a point in the chamber
function HS.TargetFor(team: number): Vector3
	local sign = if team == 0 then 1 else -1
	return Vector3.new(0, sign * (HS.HALF_Y + 420), 330)
end

-- ball fully over a goal line: returns the team that SCORED (0 blue into +y, 1 orange into -y), or nil
function HS.GoalScored(p: Vector3): number?
	if math.abs(p.X) > HS.GOAL_W / 2 + 40 or p.Z > HS.GOAL_H + 40 then return nil end
	if p.Y > HS.HALF_Y + 95 then return 0 end
	if p.Y < -(HS.HALF_Y + 95) then return 1 end
	return nil
end

local map: any = nil
function HS.Map(): any
	if map then return map end
	local m = MapKit.new("CupulaNeon")
	local X, Y, Z = HS.HALF_X, HS.HALF_Y, HS.CEIL
	local GW, GH, GD = HS.GOAL_W / 2, HS.GOAL_H, HS.GOAL_D
	local R, RC, RK = HS.FLOOR_R, HS.CEIL_R, HS.CORNER_R
	local rnd = Random.new(20260923)

	-- ------------------------------------------------------------ looks
	local FLOOR = { color = Color3.fromRGB(44, 50, 68), material = Enum.Material.SmoothPlastic, reflectance = 0.03, name = "Floor" }
	local HIDDEN = { visible = false }
	local CURVE = { color = Color3.fromRGB(96, 106, 132), material = Enum.Material.Metal, name = "Curve" }
	local CURVE_HI = { color = Color3.fromRGB(70, 78, 100), material = Enum.Material.Metal, name = "CeilingCurve" }
	local CEILING = { color = Color3.fromRGB(30, 34, 46), material = Enum.Material.Metal, name = "Ceiling" }
	local METAL = { color = Color3.fromRGB(58, 62, 74), material = Enum.Material.Metal }
	local TRUSS = { color = Color3.fromRGB(80, 86, 100), material = Enum.Material.DiamondPlate, shadow = false }
	local GLASS = { color = Color3.fromRGB(120, 175, 230), material = Enum.Material.Glass, transparency = 0.72, shadow = false, reflectance = 0.1 }
	local LINE = { color = Color3.fromRGB(215, 235, 255), material = Enum.Material.Neon, shadow = false, transparency = 0.15 }
	local SEAM = { color = Color3.fromRGB(70, 80, 104), material = Enum.Material.SmoothPlastic, shadow = false }
	local function neon(c: Color3, t: number?): any
		return { color = c, material = Enum.Material.Neon, shadow = false, transparency = t or 0 }
	end
	local function teamOf(sy: number): Color3
		return if sy > 0 then ORANGE else BLUE
	end
	-- neon reads brighter than its colour: a deeper orange stays orange
	local function glowOf(sy: number): Color3
		return if sy > 0 then Color3.fromRGB(255, 88, 12) else Color3.fromRGB(20, 110, 255)
	end
	local PW = 320 -- goal-side pillars (solid): the end-wall curves stop against them

	-- ------------------------------------------------------------ physics shell
	m:Floor(-X - 700, -Y - GD - 700, X + 700, Y + GD + 700, 0, FLOOR, 300)
	for _, sx in { 1, -1 } do
		-- side walls (drawn as panels below) and their floor / ceiling curves, stopping where the corner curves start
		m:Box(Vector3.new(if sx > 0 then X else -X - 600, -Y - 600, -200), Vector3.new(if sx > 0 then X + 600 else -X, Y + 600, Z + 400), HIDDEN)
		m:QuarterPipe(Vector3.new(sx * X, -Y + RK, 0), Vector3.new(sx * X, Y - RK, 0), Vector3.new(-sx, 0, 0), R, CURVE)
		m:CeilingPipe(Vector3.new(sx * X, -Y + RK, Z), Vector3.new(sx * X, Y - RK, Z), Vector3.new(-sx, 0, 0), RC, CURVE_HI)
	end
	for _, sy in { 1, -1 } do
		local y0, y1 = if sy > 0 then Y else -Y - 600, if sy > 0 then Y + 600 else -Y
		-- end wall around the goal mouth
		m:Box(Vector3.new(-X - 600, y0, -200), Vector3.new(-GW, y1, Z + 400), HIDDEN)
		m:Box(Vector3.new(GW, y0, -200), Vector3.new(X + 600, y1, Z + 400), HIDDEN)
		m:Box(Vector3.new(-GW, y0, GH), Vector3.new(GW, y1, Z + 400), HIDDEN)
		for _, sx in { 1, -1 } do
			-- a pillar each side of the goal mouth, as deep as the floor curve
			m:Box(Vector3.new(if sx > 0 then GW else -GW - PW, math.min(sy * Y, sy * (Y - R)), -200), Vector3.new(if sx > 0 then GW + PW else -GW, math.max(sy * Y, sy * (Y - R)), GH + 380), {
				color = Color3.fromRGB(70, 78, 100), material = Enum.Material.Metal, name = "GoalPillar",
				gui = { kind = "panel", face = { "Front", "Back", "Left", "Right" }, border = Color3.fromRGB(50, 56, 74), fill = Color3.fromRGB(84, 94, 120), accent = glowOf(sy), accentY = 0.1, accentH = 0.05, pps = 2 },
			})
			local a, b = sx * (GW + PW), sx * (X - RK)
			m:QuarterPipe(Vector3.new(math.min(a, b), sy * Y, 0), Vector3.new(math.max(a, b), sy * Y, 0), Vector3.new(0, -sy, 0), R, CURVE)
			-- the rounded corner, floor to ceiling
			m:CornerPipe(Vector3.new(sx * X, sy * Y, 0), Vector3.new(-sx, 0, 0), Vector3.new(0, -sy, 0), 0, Z, RK, CURVE)
		end
		m:CeilingPipe(Vector3.new(-X + RK, sy * Y, Z), Vector3.new(X - RK, sy * Y, Z), Vector3.new(0, -sy, 0), RC, CURVE_HI)
		-- goal chamber: back, sides, roof, and a curved back like RL's goals
		local yb = sy * (Y + GD)
		m:Box(Vector3.new(-GW - 400, math.min(yb, yb + sy * 400), -200), Vector3.new(GW + 400, math.max(yb, yb + sy * 400), GH + 300), HIDDEN)
		for _, sx in { 1, -1 } do
			m:Box(Vector3.new(if sx > 0 then GW else -GW - 400, math.min(sy * Y, yb), -200), Vector3.new(if sx > 0 then GW + 400 else -GW, math.max(sy * Y, yb), GH + 300), HIDDEN)
		end
		m:Box(Vector3.new(-GW, math.min(sy * Y, yb), GH), Vector3.new(GW, math.max(sy * Y, yb), GH + 300), HIDDEN)
		m:QuarterPipe(Vector3.new(-GW, yb, 0), Vector3.new(GW, yb, 0), Vector3.new(0, -sy, 0), 260, { color = Color3.fromRGB(20, 22, 30), material = Enum.Material.Metal })
	end
	m:Box(Vector3.new(-X - 600, -Y - 600, Z), Vector3.new(X + 600, Y + 600, Z + 400), CEILING)
	-- the jumbotron over the centre is solid (a ball launched up the middle bounces off it)
	local J, JZ = HS.JUMBO_HALF, HS.JUMBO_Z
	m:Box(Vector3.new(-J, -J, JZ), Vector3.new(J, J, Z), { color = Color3.fromRGB(14, 15, 20), material = Enum.Material.Metal, name = "Jumbotron" })

	-- ------------------------------------------------------------ floor art
	-- polished tiles: seams every 800 uu
	for x = -X + 800, X - 800, 800 do
		m:Prop(Vector3.new(x, 0, 1.5), Vector3.new(14, 2 * Y, 3), 0, SEAM)
	end
	for y = -Y + 800, Y - 800, 800 do
		m:Prop(Vector3.new(0, y, 1.5), Vector3.new(2 * X, 14, 3), 0, SEAM)
	end
	-- each half glows in its team's colour, strongest at the goal
	for _, sy in { 1, -1 } do
		m:Prop(Vector3.new(0, sy * Y / 2, 2), Vector3.new(2 * X - 400, Y, 2), 0, {
			color = Color3.new(1, 1, 1), transparency = 1, shadow = false,
			gui = { kind = "gradient", face = "Top", a = teamOf(sy), b = teamOf(sy), ta = if sy > 0 then 1 else 0.72, tb = if sy > 0 then 0.72 else 1, rot = 90, pps = 1, lightInfluence = 0.1, brightness = 0.9 },
		})
	end
	-- centre: halfway line, two circles, the logo
	m:Prop(Vector3.new(0, 0, 3), Vector3.new(2 * X - 200, 36, 4), 0, LINE)
	m:Ring(Vector3.new(0, 0, 3), 1000, 36, 56, LINE)
	m:Ring(Vector3.new(0, 0, 3), 340, 24, 28, neon(ICE, 0.3))
	m:Prop(Vector3.new(0, 0, 2.5), Vector3.new(1300, 520, 2), 0, {
		color = Color3.new(0, 0, 0), transparency = 1, shadow = false,
		gui = { kind = "text", face = "Top", text = "HEATSEEKER", color = Color3.fromRGB(230, 240, 255), pps = 3 },
	})
	-- goal areas, penalty arcs, kickoff marks and chevrons pointing at the goal each half attacks
	for _, sy in { 1, -1 } do
		local c = teamOf(sy)
		local g = glowOf(sy)
		local yl = sy * (Y - 1300)
		m:Prop(Vector3.new(0, yl, 3), Vector3.new(3200, 30, 4), 0, neon(g, 0.2))
		for _, sx in { 1, -1 } do
			m:Prop(Vector3.new(sx * 1600, sy * (Y - 650), 3), Vector3.new(30, 1300, 4), 0, neon(g, 0.2))
		end
		m:Ring(Vector3.new(0, yl, 3), 620, 26, 24, neon(g, 0.25), if sy > 0 then math.pi else 0, if sy > 0 then 2 * math.pi else math.pi)
		m:Prop(Vector3.new(0, sy * Y, 3), Vector3.new(2 * GW, 50, 4), 0, neon(g))
		-- kickoff marks
		for _, p in { Vector3.new(0, sy * 2700, 3), Vector3.new(-1400, sy * 2900, 3), Vector3.new(1400, sy * 2900, 3) } do
			m:Ring(p, 110, 18, 16, neon(g, 0.3))
		end
		-- chevrons in this half point at the goal it attacks (the other end)
		for k = 1, 3 do
			local yc = sy * (600 + k * 450)
			for _, sx in { 1, -1 } do
				m:Beam(Vector3.new(sx * 260, yc - sy * 120, 3), Vector3.new(0, yc - sy * 360, 3), 40, neon(g, 0.35 + k * 0.1), false, 4)
			end
		end
	end

	-- ------------------------------------------------------------ walls: panels, LED ribbon, glass, mullions
	local LOW, LED0, LED1, GLASS1 = 780, 780, 960, Z - RC
	local ads = { "ROCKET ROBLOX", "HEATSEEKER", "CÚPULA NEÓN", "SUPERSÓNICO", "¡DEFIENDE!", "BOOST COLA", "TURBO+", "RR LEAGUE" }
	local adI = 0
	local function wallRun(p0: Vector3, p1: Vector3, inward: Vector3, sideColor: (number) -> Color3)
		-- a straight run of wall from p0 to p1 (floor level), dressed from the curve up to the ceiling curve
		local d = p1 - p0
		local len = d.Magnitude
		local dir = d / len
		local yaw = math.atan2(inward.Y, inward.X)
		local n = math.max(1, math.floor(len / 800 + 0.5))
		local seg = len / n
		for i = 0, n - 1 do
			local mid = p0 + dir * (seg * (i + 0.5))
			local col = sideColor(i / math.max(1, n - 1))
			local face = mid + inward * 6
			-- lower panels (above the quarter pipe)
			m:Prop(face + Vector3.new(0, 0, (R + LOW) / 2), Vector3.new(12, seg - 24, LOW - R), yaw, {
				color = Color3.fromRGB(80, 88, 110), material = Enum.Material.Metal, shadow = false,
				gui = { kind = "panel", face = "Front", border = Color3.fromRGB(64, 70, 90), fill = Color3.fromRGB(104, 114, 140), accent = col, accentY = 0.72, accentH = 0.06, pps = 2 },
			})
			-- LED ribbon: alternating ads
			adI += 1
			m:Sign(face + inward * 4 + Vector3.new(0, 0, (LED0 + LED1) / 2), Vector3.new(10, seg - 20, LED1 - LED0), yaw, ads[(adI % #ads) + 1], Color3.new(1, 1, 1), {
				color = Color3.fromRGB(10, 12, 18), material = Enum.Material.SmoothPlastic, shadow = false,
				gui = { kind = "gradient", face = "Front", a = col, b = Color3.fromRGB(12, 14, 22), rot = 0, pps = 2, lightInfluence = 0, brightness = 1.4 },
			})
			-- glass above
			m:Prop(face + Vector3.new(0, 0, (LED1 + GLASS1) / 2), Vector3.new(8, seg - 30, GLASS1 - LED1), yaw, GLASS)
			-- mullion
			local edge = p0 + dir * (seg * i) + inward * 12
			m:Prop(edge + Vector3.new(0, 0, (R + GLASS1) / 2), Vector3.new(30, 50, GLASS1 - R), yaw, METAL)
		end
		-- a ledge under the glass and a light strip under the LED ribbon
		m:Beam(p0 + inward * 20 + Vector3.new(0, 0, LED1 + 10), p1 + inward * 20 + Vector3.new(0, 0, LED1 + 10), 40, METAL, false, 24)
		m:Beam(p0 + inward * 26 + Vector3.new(0, 0, LED0 - 6), p1 + inward * 26 + Vector3.new(0, 0, LED0 - 6), 10, neon(ICE, 0.2), false, 8)
	end
	for _, sx in { 1, -1 } do
		wallRun(Vector3.new(sx * X, -Y + RK, 0), Vector3.new(sx * X, Y - RK, 0), Vector3.new(-sx, 0, 0), function(t: number): Color3
			return BLUE:Lerp(ORANGE, t)
		end)
	end
	for _, sy in { 1, -1 } do
		for _, sx in { 1, -1 } do
			wallRun(Vector3.new(sx * (GW + 400), sy * Y, 0), Vector3.new(sx * (X - RK), sy * Y, 0), Vector3.new(0, -sy, 0), function(): Color3
				return teamOf(sy)
			end)
		end
		-- above the goal: the end wall face, a team banner and the team name
		local c = teamOf(sy)
		local g = glowOf(sy)
		m:Prop(Vector3.new(0, sy * (Y - 6), (GH + GLASS1) / 2), Vector3.new(12, 2 * GW + 800, GLASS1 - GH), if sy > 0 then -math.pi / 2 else math.pi / 2, {
			color = Color3.fromRGB(30, 33, 44), material = Enum.Material.Metal, shadow = false,
			gui = { kind = "gradient", face = "Front", a = c, b = Color3.fromRGB(18, 20, 28), ta = 0.35, tb = 0, rot = 90, pps = 1, lightInfluence = 0.2 },
		})
		m:Sign(Vector3.new(0, sy * (Y - 14), GH + 520), Vector3.new(10, 1500, 380), if sy > 0 then -math.pi / 2 else math.pi / 2, if sy > 0 then "NARANJA" else "AZUL", Color3.new(1, 1, 1), {
			color = Color3.fromRGB(10, 10, 14), transparency = 1, shadow = false,
		})
	end
	-- corner curves carry a vertical light strip
	for _, sx in { 1, -1 } do
		for _, sy in { 1, -1 } do
			local cc = Vector3.new(sx * (X - RK), sy * (Y - RK), 0)
			local out = Vector3.new(sx, sy, 0).Unit
			m:Beam(cc + out * (RK - 12) + Vector3.new(0, 0, R + 60), cc + out * (RK - 12) + Vector3.new(0, 0, GLASS1), 30, neon(glowOf(sy), 0.2), false, 30)
		end
	end

	-- ------------------------------------------------------------ goals: posts, crossbar, net, glow
	for _, sy in { 1, -1 } do
		local c = teamOf(sy)
		local g = glowOf(sy)
		local yf = sy * (Y + 18)
		local post = { color = c:Lerp(Color3.new(1, 1, 1), 0.55), material = Enum.Material.Metal, reflectance = 0.2 }
		for _, sx in { 1, -1 } do
			m:Cyl(Vector3.new(sx * (GW + 20), yf, 0), 42, GH + 40, post)
			m:Cyl(Vector3.new(sx * (GW + 20), yf, 0), 46, 60, neon(g)) -- base collar
		end
		m:Beam(Vector3.new(-GW - 60, yf, GH + 20), Vector3.new(GW + 60, yf, GH + 20), 84, post, true)
		-- chamber lining (dark) and the net: a lattice on the back, the sides and the roof
		local yb = sy * (Y + GD)
		local lining = { color = Color3.fromRGB(14, 16, 24), material = Enum.Material.Fabric }
		m:Prop(Vector3.new(0, yb - sy * 4, GH / 2), Vector3.new(8, 2 * GW, GH), if sy > 0 then -math.pi / 2 else math.pi / 2, lining)
		local net = { color = Color3.fromRGB(235, 240, 250), material = Enum.Material.SmoothPlastic, transparency = 0.35, shadow = false }
		for x = -GW + 100, GW - 100, 130 do
			m:Beam(Vector3.new(x, yb - sy * 20, 0), Vector3.new(x, yb - sy * 20, GH), 10, net)
			m:Beam(Vector3.new(x, yb - sy * 20, GH - 20), Vector3.new(x, yf, GH - 20), 10, net)
		end
		for z = 110, GH - 60, 120 do
			m:Beam(Vector3.new(-GW, yb - sy * 20, z), Vector3.new(GW, yb - sy * 20, z), 10, net)
			for _, sx in { 1, -1 } do
				m:Beam(Vector3.new(sx * (GW - 16), yf, z), Vector3.new(sx * (GW - 16), yb, z), 10, net)
			end
		end
		for t = 0.2, 0.8, 0.2 do
			local y = sy * (Y + GD * t)
			m:Beam(Vector3.new(-GW, y, GH - 20), Vector3.new(GW, y, GH - 20), 10, net)
			for _, sx in { 1, -1 } do
				m:Beam(Vector3.new(sx * (GW - 16), y, 0), Vector3.new(sx * (GW - 16), y, GH - 20), 10, net)
			end
		end
		-- glowing strip along the back of the chamber floor + an inside light
		m:Prop(Vector3.new(0, yb - sy * 40, 4), Vector3.new(30, 2 * GW - 80, 6), math.pi / 2, neon(g))
		m:Light(Vector3.new(0, sy * (Y + GD / 2), GH / 2), c, 40, 2.5)
		-- the goal surround: light strips up the pillars' faces and a bar over the mouth
		for _, sx in { 1, -1 } do
			for _, xo in { 26, PW - 26 } do
				m:Beam(Vector3.new(sx * (GW + xo), sy * (Y - R - 8), 0), Vector3.new(sx * (GW + xo), sy * (Y - R - 8), GH + 380), 28, neon(g, 0.1), false, 14)
			end
			m:Beam(Vector3.new(sx * (GW + 8), sy * (Y - R), GH + 60), Vector3.new(sx * (GW + 8), sy * Y, GH + 60), 24, neon(g, 0.2), false, 24)
		end
		m:Beam(Vector3.new(-GW - PW, sy * (Y - 8), GH + 150), Vector3.new(GW + PW, sy * (Y - 8), GH + 150), 60, neon(g, 0.1), false, 16)
	end

	-- ------------------------------------------------------------ ceiling: trusses, light rigs, jumbotron
	for x = -X + 700, X - 700, 1350 do
		m:Beam(Vector3.new(x, -Y + 200, Z - 60), Vector3.new(x, Y - 200, Z - 60), 70, TRUSS, false, 110)
	end
	for y = -Y + 900, Y - 900, 1200 do
		m:Beam(Vector3.new(-X + 200, y, Z - 50), Vector3.new(X - 200, y, Z - 50), 50, TRUSS, false, 90)
		m:Beam(Vector3.new(-X + 400, y, Z - 110), Vector3.new(X - 400, y, Z - 110), 18, neon(ICE, 0.1), false, 18)
	end
	-- light over the pitch (Roblox lights reach 60 studs: hang them low enough) and wash lights along the walls
	for _, x in { -1800, 0, 1800 } do
		for _, y in { -3000, -1000, 1000, 3000 } do
			m:Light(Vector3.new(x, y, 1150), Color3.fromRGB(215, 230, 255), 60, 1.4)
		end
	end
	for _, sx in { 1, -1 } do
		for y = -Y + 1200, Y - 1200, 1600 do
			m:Light(Vector3.new(sx * (X - 500), y, 700), BLUE:Lerp(ORANGE, (y + Y) / (2 * Y)), 40, 1.2)
		end
	end
	-- the jumbotron: four screens and neon rims
	for k = 0, 3 do
		local a = k * math.pi / 2
		local o = Vector3.new(math.cos(a), math.sin(a), 0)
		m:Sign(o * (J + 6) + Vector3.new(0, 0, (JZ + Z) / 2 - 20), Vector3.new(8, 2 * J - 80, Z - JZ - 120), a, if k % 2 == 0 then "HEATSEEKER" else "¡EL BALÓN TE BUSCA!", Color3.new(1, 1, 1), {
			color = Color3.fromRGB(8, 10, 16), shadow = false,
			gui = { kind = "gradient", face = "Front", a = Color3.fromRGB(30, 60, 140), b = Color3.fromRGB(140, 50, 20), rot = 0, pps = 1, lightInfluence = 0, brightness = 1.1 },
		})
		local side = Vector3.new(-o.Y, o.X, 0)
		for _, z in { JZ + 10, Z - 40 } do
			m:Beam(o * (J + 10) - side * (J + 10) + Vector3.new(0, 0, z), o * (J + 10) + side * (J + 10) + Vector3.new(0, 0, z), 26, neon(ICE), false, 26)
		end
	end

	-- ------------------------------------------------------------ the crowd behind the glass
	local crowdCols = { BLUE, ORANGE, Color3.fromRGB(235, 235, 240), Color3.fromRGB(60, 64, 80), Color3.fromRGB(255, 210, 60) }
	local function stands(p0: Vector3, p1: Vector3, outward: Vector3)
		local d = p1 - p0
		local len = d.Magnitude
		local dir = d / len
		local yaw = math.atan2(-outward.Y, -outward.X) -- seats face the pitch
		for t = 0, 5 do
			local base = outward * (700 + t * 420) + Vector3.new(0, 0, 600 + t * 260)
			-- the tier (concrete step)
			m:Prop((p0 + p1) / 2 + base - Vector3.new(0, 0, 130), Vector3.new(420, len, 260), yaw, { color = Color3.fromRGB(34, 36, 46), material = Enum.Material.Concrete, shadow = false })
			-- the fans: blocks of colour along the row
			local n = math.floor(len / 320)
			for i = 0, n - 1 do
				if rnd:NextNumber() < 0.86 then
					local pos = p0 + dir * ((i + 0.5) * len / n) + base + Vector3.new(0, 0, 55)
					local col = crowdCols[rnd:NextInteger(1, #crowdCols)]
					if rnd:NextNumber() < 0.5 then col = (if pos.Y > 0 then ORANGE else BLUE) end
					m:Prop(pos, Vector3.new(160, len / n - 40, 110 + rnd:NextNumber() * 40), yaw, { color = col, material = Enum.Material.Fabric, shadow = false })
				end
			end
		end
		-- the stand's back wall, its roof (no sky inside a dome) and a light strip under the roof edge
		m:Prop((p0 + p1) / 2 + outward * 3300 + Vector3.new(0, 0, 1600), Vector3.new(200, len + 3400, 2600), yaw, { color = Color3.fromRGB(22, 24, 32), material = Enum.Material.Concrete, shadow = false })
		m:Prop((p0 + p1) / 2 + outward * 1700 + Vector3.new(0, 0, 2450), Vector3.new(3400, len + 3400, 120), yaw, { color = Color3.fromRGB(26, 28, 38), material = Enum.Material.Metal, shadow = false })
		m:Beam(p0 + outward * 60 + Vector3.new(0, 0, 2380), p1 + outward * 60 + Vector3.new(0, 0, 2380), 30, neon(ICE, 0.2), false, 30)
	end
	for _, sx in { 1, -1 } do
		stands(Vector3.new(sx * X, -Y + 400, 0), Vector3.new(sx * X, Y - 400, 0), Vector3.new(sx, 0, 0))
	end
	for _, sy in { 1, -1 } do
		stands(Vector3.new(-X + 400, sy * Y, 0), Vector3.new(X - 400, sy * Y, 0), Vector3.new(0, sy, 0))
	end

	m.data.kickoff = {
		{ Vector3.new(0, -2700, 17), Vector3.new(-1400, -2900, 17), Vector3.new(1400, -2900, 17) },
	}
	m.lighting = {
		ClockTime = 13, Brightness = 2, ExposureCompensation = 0.35,
		Ambient = Color3.fromRGB(150, 150, 158), OutdoorAmbient = Color3.fromRGB(138, 138, 148),
		atmosphere = { Density = 0.12, Offset = 0, Color = Color3.fromRGB(170, 176, 196), Decay = Color3.fromRGB(90, 94, 110), Glare = 0, Haze = 0.3 },
		bloom = { Intensity = 1.1, Size = 28, Threshold = 1.3 },
		grade = { Brightness = 0.02, Contrast = 0.14, Saturation = 0.04, TintColor = Color3.fromRGB(250, 250, 255) },
	}
	map = m
	return m
end

function HS.WorldOptions(): any
	return { boostPads = false, seed = 1, arena = HS.Map():Arena() }
end

HS.DemoMode = "disabled"

function HS.SetupWorld(world: any)
	world.ball.heat = nil
end

-- boost refills only with the wheels on the ground: nobody hovers forever on regenerated boost (a full tank is ~3 s
-- of flight)
local function grounded(car: any): boolean
	return (car.numWheelsInContact or 0) >= 3
end

-- car.loneWolf: the single player of a 2v1 (set by the server; the view mirrors it on our predicted car)
function HS.PreTick(car: any, dt: number)
	if not grounded(car) then return end
	car.boost = math.min(100, (car.boost or 0) + (if car.loneWolf then HS.LONE_BOOST_REGEN else HS.BOOST_REGEN) * dt)
end

-- inside the goal chamber that `team` defends (team 0 defends -y)
function HS.InOwnGoal(team: number, p: Vector3): boolean
	local sign = if team == 0 then -1 else 1
	return p.Y * sign > HS.HALF_Y + 60 and math.abs(p.X) < HS.GOAL_W / 2 + 60
end

-- per tick after the physics step (server and client prediction): touches lock the ball on, then it homes in
function HS.PostStep(world: any, live: boolean)
	local ball = world.ball
	if not world.ballEnabled then return end
	for _, e in world.events do
		if e.type == "hit" and e.car and not e.ball then
			local h = ball.heat
			local speed = if h then math.min(HS.MAX_SPEED, h.speed + HS.SPEED_STEP) else HS.START_SPEED
			ball.heat = { team = e.car.team, speed = speed }
		end
	end
	local h = ball.heat
	if not h or not live then return end
	local b = ball.body
	local BT = 50
	local pos = b.pos * BT
	local vel = b.vel * BT
	local desired = HS.TargetFor(h.team) - pos
	if desired.Magnitude < 1 then return end
	desired = desired.Unit
	local cur = if vel.Magnitude > 1 then vel.Unit else desired
	-- turn toward the goal at a limited rate, then hold the heat speed
	local ang = math.acos(math.clamp(cur:Dot(desired), -1, 1))
	local maxTurn = HS.TURN_RATE * world.tickTime
	local dir = desired
	if ang > maxTurn then
		local axis = cur:Cross(desired)
		if axis.Magnitude > 1e-4 then
			dir = (CFrame.fromAxisAngle(axis.Unit, maxTurn) * cur).Unit
		end
	end
	b.vel = dir * h.speed / BT
end

return HS
