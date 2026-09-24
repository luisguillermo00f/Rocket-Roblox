--!strict
-- MinigameViews/BeachVolley.lua: what Beach Volley looks like on the client. Sand over the stadium floor, court
-- lines, the net (drawn exactly where the server's collider is), a shimmer wall above it where cars can't pass,
-- a few palms, warm daylight, a shadow under the ball to judge where it lands, sand puffs on bounces.
-- Everything it shows comes from server events / snapshots; everything it builds lives in the round's folder and
-- the lighting it changes is put back on Destroy.
local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local GameHud = require(Game.Hud)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("BeachVolleyShared"))
local Hud = require(script.Parent.Parent.MinigameHud)

local S = RenderMap.S
local BLUE, ORANGE = GameHud.BLUE, GameHud.ORANGE
local SAND = Color3.fromRGB(230, 205, 158)
local SAND_OUT = Color3.fromRGB(214, 186, 138)
local LINE = Color3.fromRGB(250, 250, 246)
local ARENA_HX, ARENA_HY = 4096, 5120

local View = {}
View.__index = View
View.BallCamDefault = true -- volley is played looking at the ball (C toggles)

local TEAM_NAME = { [0] = "AZUL", [1] = "NARANJA" }
local REASON = { ["doble bote"] = "DOBLE BOTE", ["fuera"] = "FUERA", ["balón muerto"] = "EL BALÓN SE QUEDÓ EN LA ARENA" }

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then p.Shape = shape end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- sim UU (x, y, z) -> studs
local function P(x: number, y: number, z: number): Vector3
	return RenderMap.Pos(Vector3.new(x, y, z))
end

local function palm(parent: Instance, base: Vector3, lean: number, seed: number)
	local rng = Random.new(seed)
	local trunkColor = Color3.fromRGB(122, 88, 58)
	local pos = base
	local dir = Vector3.new(math.cos(lean), 0, math.sin(lean))
	local top = pos
	for i = 1, 7 do
		local seg = 4.2
		local up = (Vector3.yAxis + dir * (0.08 * i)).Unit
		local a = top
		local b = a + up * seg
		part(parent, Vector3.new(seg + 0.3, 2.2 - i * 0.12, 2.2 - i * 0.12), CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0),
			if i % 2 == 0 then trunkColor else trunkColor:Lerp(Color3.new(0, 0, 0), 0.12), Enum.Material.Wood, Enum.PartType.Cylinder)
		top = b
	end
	for k = 1, 7 do
		local yaw = (k / 7) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local out = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
		local droop = rng:NextNumber(0.25, 0.5)
		local leafDir = (out - Vector3.yAxis * droop).Unit
		local len = rng:NextNumber(9, 12)
		local c = top + leafDir * (len / 2)
		local leaf = part(parent, Vector3.new(len, 0.35, 2.6), CFrame.lookAt(c, c + leafDir) * CFrame.Angles(0, math.rad(90), 0),
			Color3.fromRGB(58, 150, 70):Lerp(Color3.fromRGB(110, 170, 60), rng:NextNumber()), Enum.Material.Grass)
		leaf.CFrame *= CFrame.Angles(math.rad(rng:NextNumber(-12, 12)), 0, 0)
	end
	for k = 1, 3 do
		local a = k * 2.1
		part(parent, Vector3.new(1.3, 1.3, 1.3), CFrame.new(top + Vector3.new(math.cos(a) * 0.9, -0.9, math.sin(a) * 0.9)), Color3.fromRGB(96, 70, 40), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end
end

local function umbrella(parent: Instance, base: Vector3, color: Color3)
	part(parent, Vector3.new(9, 0.3, 0.3), CFrame.new(base + Vector3.new(0, 4.5, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(240, 240, 235), Enum.Material.Metal, Enum.PartType.Cylinder)
	for k = 0, 7 do
		local yaw = k / 8 * math.pi * 2
		local out = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
		local dir = (out - Vector3.yAxis * 0.35).Unit
		local c = base + Vector3.new(0, 9, 0) + dir * 2.6
		part(parent, Vector3.new(5.4, 0.2, 2.3), CFrame.lookAt(c, c + dir) * CFrame.Angles(0, math.rad(90), 0), if k % 2 == 0 then color else LINE)
	end
	part(parent, Vector3.new(5, 0.1, 9), CFrame.new(base + Vector3.new(3.5, 0.06, 0)), color:Lerp(LINE, 0.4)) -- towel
end

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.scoreA = pub.scoreA or 0
	self.scoreB = pub.scoreB or 0
	self.side = pub.side or 0
	self.bounces = pub.bounces or 0
	self.phase = pub.phase or "idle"
	self.suddenDeath = pub.suddenDeath == true

	local env = Instance.new("Folder")
	env.Name = "BeachVolley"
	env.Parent = round.folder
	self.env = env

	-- sand: the whole floor, the court a shade lighter
	part(env, Vector3.new(ARENA_HX * 2 * S, 0.4, ARENA_HY * 2 * S), CFrame.new(0, -0.18, 0), SAND_OUT, Enum.Material.Sand)
	part(env, Vector3.new(Shared.COURT_HX * 2 * S, 0.4, Shared.COURT_HY * 2 * S), CFrame.new(0, -0.16, 0), SAND, Enum.Material.Sand)
	-- lines (the line belongs to the court: the ball is out only when it lands fully past it)
	local lw = 16 * S
	local hx, hy = Shared.COURT_HX * S, Shared.COURT_HY * S
	for _, sx in { -1, 1 } do
		part(env, Vector3.new(lw, 0.06, hy * 2 + lw), CFrame.new(sx * hx, 0.05, 0), LINE)
		part(env, Vector3.new(hx * 2 + lw, 0.06, lw), CFrame.new(0, 0.05, sx * hy), LINE)
	end
	part(env, Vector3.new(hx * 2, 0.06, lw * 0.6), CFrame.new(0, 0.05, 0), LINE)

	-- the net: exactly the server's collider (y = 0 plane, full arena width, NET_TOP high)
	local top = Shared.NET_TOP * S
	local width = ARENA_HX * 2 * S
	local netColor = Color3.fromRGB(30, 34, 40)
	part(env, Vector3.new(width, 12 * S, 0.25), CFrame.new(0, top - 6 * S, 0), LINE) -- top tape
	part(env, Vector3.new(width, 6 * S, 0.2), CFrame.new(0, 26 * S, 0), LINE) -- bottom tape
	local rows = 7
	for i = 1, rows do
		local y = 26 * S + (top - 32 * S) * i / (rows + 1)
		part(env, Vector3.new(width, 0.12, 0.12), CFrame.new(0, y, 0), netColor)
	end
	local step = 3.2
	local n = math.floor(width / step)
	for i = 0, n do
		local x = -width / 2 + i * step
		part(env, Vector3.new(0.12, top - 26 * S, 0.12), CFrame.new(x, (top + 26 * S) / 2, 0), netColor)
	end
	-- posts at the court edges
	for _, sx in { -1, 1 } do
		local x = sx * (hx + 5)
		part(env, Vector3.new(top + 1.5, 1.1, 1.1), CFrame.new(x, (top + 1.5) / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(245, 245, 240), Enum.Material.Metal, Enum.PartType.Cylinder)
		part(env, Vector3.new(1.6, 1.6, 1.6), CFrame.new(x, top + 1.6, 0), Color3.fromRGB(255, 196, 64), Enum.Material.Neon, Enum.PartType.Ball)
	end
	-- above the net: cars can't cross (server wall), the ball can. A faint shimmer shows it.
	local wall = part(env, Vector3.new(width, 44, 0.2), CFrame.new(0, top + 22, 0), Color3.fromRGB(140, 210, 255), Enum.Material.ForceField)
	wall.Transparency = 0.35

	-- dressing outside the court
	palm(env, P(-3500, -4300, 0), 0.8, 1)
	palm(env, P(3500, -4300, 0), 2.3, 2)
	palm(env, P(-3500, 4300, 0), -0.8, 3)
	palm(env, P(3500, 4300, 0), -2.3, 4)
	palm(env, P(-3700, 0, 0), 0.1, 5)
	palm(env, P(3700, 0, 0), 3.1, 6)
	umbrella(env, P(-2600, -3000, 0), Color3.fromRGB(255, 90, 80))
	umbrella(env, P(2600, 3000, 0), Color3.fromRGB(40, 160, 255))
	umbrella(env, P(2700, -3300, 0), Color3.fromRGB(255, 196, 64))
	umbrella(env, P(-2700, 3300, 0), Color3.fromRGB(80, 200, 120))

	-- ball shadow on the sand
	local d = Shared.BALL_RADIUS * 2 * S
	local shadow = part(env, Vector3.new(0.08, d, d), CFrame.new(0, -500, 0), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	shadow.Transparency = 0.6
	self.shadow = shadow

	-- warm daylight (restored on Destroy)
	self.savedLighting = {
		ClockTime = Lighting.ClockTime, Brightness = Lighting.Brightness, Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient, ColorShift_Top = Lighting.ColorShift_Top,
		ColorShift_Bottom = Lighting.ColorShift_Bottom, ExposureCompensation = Lighting.ExposureCompensation,
	}
	Lighting.ClockTime = 14.2
	Lighting.Brightness = 3
	Lighting.Ambient = Color3.fromRGB(150, 140, 122)
	Lighting.OutdoorAmbient = Color3.fromRGB(175, 165, 145)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 236, 205)
	Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
	Lighting.ExposureCompensation = 0.1
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "BeachVolleyGrade"
	cc.Saturation = 0.12
	cc.Contrast = 0.04
	cc.TintColor = Color3.fromRGB(255, 248, 236)
	cc.Parent = Lighting
	self.grade = cc
	return self
end

function View.TeamNames(self: any): { any }
	local out = {}
	for team = 0, 1 do
		local ms = {}
		for _, p in self.round.participants do
			if p.team == team then table.insert(ms, p) end
		end
		table.insert(out, { label = "EQUIPO " .. TEAM_NAME[team], color = if team == 0 then BLUE else ORANGE, members = ms })
	end
	return out
end

local function names(round: any, team: number): string
	local out = {}
	for _, p in round.participants do
		if p.team == team then table.insert(out, Hud.Upper(p.name or "?")) end
	end
	return table.concat(out, " · ")
end

function View.HudState(self: any): any
	local r = self.round
	local myTeam = r.me and r.me.team
	local info = ""
	if self.phase == "rally" and r.state == "ACTIVE" then
		if self.bounces >= 1 then
			info = if myTeam == self.side then "¡YA BOTÓ EN TU LADO!" else "BOTÓ EN EL LADO " .. TEAM_NAME[self.side]
		end
	end
	local timeLeft = nil
	local note = ""
	if r.state == "ACTIVE" then
		timeLeft = math.max(0, Shared.REGULATION_TIME - r:PhaseElapsed())
		if self.suddenDeath then
			timeLeft = 0
			note = "MUERTE SÚBITA"
		else
			note = "PRIMERO A " .. Shared.WIN_POINTS
		end
	end
	return {
		left = { label = "AZUL" .. (if myTeam == 0 then " · TÚ" else ""), sub = names(r, 0), value = self.scoreA, color = BLUE },
		right = { label = (if myTeam == 1 then "TÚ · " else "") .. "NARANJA", sub = names(r, 1), value = self.scoreB, color = ORANGE },
		timeLeft = timeLeft, timeTotal = Shared.REGULATION_TIME, timerNote = note, info = info,
	}
end

function View.ControlsLocked(self: any): boolean
	return self.phase == "point"
end

-- the volley touch rule only runs during a rally (as on the server); prediction applies it then
function View.PostStepLive(self: any): boolean
	return self.phase == "rally"
end

local function sandPuff(parent: Instance, pos: Vector3, strength: number)
	local ring = part(parent, Vector3.new(0.1, 2, 2), CFrame.new(pos.X, 0.12, pos.Z) * CFrame.Angles(0, 0, math.rad(90)), LINE, Enum.Material.Neon, Enum.PartType.Cylinder)
	ring.Transparency = 0.2
	local size = 10 + 8 * strength
	TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quint), { Size = Vector3.new(0.1, size, size), Transparency = 1 }):Play()
	task.delay(0.6, function() ring:Destroy() end)
	local a = part(parent, Vector3.new(1, 1, 1), CFrame.new(pos.X, 0.4, pos.Z), SAND)
	a.Transparency = 1
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(SAND, SAND_OUT)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0.2) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.4, 0.8)
	pe.Speed = NumberRange.new(8, 16 + 10 * strength)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Acceleration = Vector3.new(0, -60, 0)
	pe.Rate = 0
	pe.Parent = a
	pe:Emit(math.floor(18 + 20 * strength))
	task.delay(1, function() a:Destroy() end)
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "state" then
		self.scoreA, self.scoreB = data.scoreA or self.scoreA, data.scoreB or self.scoreB
		self.side, self.bounces = data.side or self.side, data.bounces or 0
		self.phase = data.phase or self.phase
		self.suddenDeath = data.suddenDeath == true
	elseif kind == "serve" then
		self.phase = "rally"
		self.bounces = 0
		local mine = r.me and r.me.team == data.team
		Hud.Toast(if mine then "SACA TU EQUIPO" else "SACA " .. TEAM_NAME[data.team], if data.team == 0 then BLUE else ORANGE)
	elseif kind == "bounce" then
		self.side, self.bounces = data.side, data.count
		if data.pos then sandPuff(self.env, RenderMap.Pos(data.pos), 0.6) end
	elseif kind == "touch" then
		if data.pos then
			Effects.Hit(RenderMap.Pos(data.pos), math.clamp((data.speed or 0) / 1800, 0.2, 1))
		end
		if r.me and data.id == r.me.id then
			Camera.Shake(0.35)
			Rumble.Event("hit", math.clamp((data.speed or 0) / 1800, 0.2, 1))
		end
	elseif kind == "point" then
		self.phase = "point"
		self.scoreA, self.scoreB = data.scoreA, data.scoreB
		local color = if data.team == 0 then BLUE else ORANGE
		local mine = r.me and r.me.team == data.team
		if mine then Rumble.Event("goal") end
		Hud.Banner(if mine then "¡PUNTO PARA TU EQUIPO!" else "PUNTO " .. TEAM_NAME[data.team], (REASON[data.reason] or string.upper(tostring(data.reason))) .. "   ·   " .. data.scoreA .. " — " .. data.scoreB, color)
		if data.pos then
			local p = RenderMap.Pos(data.pos)
			sandPuff(self.env, p, 1)
			Effects.Goal(Vector3.new(p.X, math.max(p.Y, 2), p.Z), color, false)
		end
		Camera.Shake(0.8)
	elseif kind == "suddenDeath" then
		self.suddenDeath = true
		Hud.Banner("MUERTE SÚBITA", "EL PRÓXIMO PUNTO GANA", Color3.fromRGB(255, 90, 80))
	end
end

function View.Update(self: any, dt: number)
	local bp = self.round.ballPos
	if bp then
		local h = math.max(0, bp.Z - Shared.BALL_RADIUS)
		local k = math.clamp(h / 1200, 0, 1)
		local d = Shared.BALL_RADIUS * 2 * S * (1 - 0.35 * k)
		self.shadow.Size = Vector3.new(0.08, d, d)
		self.shadow.Transparency = 0.45 + 0.4 * k
		local p = RenderMap.Pos(Vector3.new(bp.X, bp.Y, 0))
		self.shadow.CFrame = CFrame.new(p.X, 0.09, p.Z) * CFrame.Angles(0, 0, math.rad(90))
	else
		self.shadow.CFrame = CFrame.new(0, -500, 0)
	end
end

function View.Destroy(self: any)
	for k, v in self.savedLighting do
		(Lighting :: any)[k] = v
	end
	if self.grade then self.grade:Destroy() end
	self.env:Destroy()
end

return View
