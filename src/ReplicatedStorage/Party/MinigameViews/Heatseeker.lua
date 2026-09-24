--!strict
-- MinigameViews/Heatseeker.lua: what Heatseeker looks like on the client. The map ("CÚPULA NEÓN") is built by
-- MinigameClient from the shared module. This view adds: the ball glowing in the colour of the goal it's hunting
-- (with a trail that heats up with its speed), goal explosions, the score and "¡VA A TU PORTERÍA!" warnings.
local RS = game:GetService("ReplicatedStorage")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("HeatseekerShared"))
local Hud = require(script.Parent.Parent.MinigameHud)

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local HOT = Color3.fromRGB(255, 70, 40)

local View = {}
View.__index = View
View.BallCamDefault = true

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	local g = pub.goals or {}
	self.goals = { [0] = g.blue or 0, [1] = g.orange or 0 }
	self.overtime = pub.overtime == true
	self.heat = nil
	self.lone = pub.lone
	if self.lone and round.me and round.me.id == self.lone and round.pred then
		round.pred.car.loneWolf = true -- the same boost rule in our prediction
	end
	-- a glow that rides the ball in the colour of the goal it's hunting
	local glow = Instance.new("Part")
	glow.Name = "HeatGlow"
	glow.Shape = Enum.PartType.Ball
	glow.Anchored = true
	glow.CanCollide = false
	glow.CanQuery = false
	glow.CanTouch = false
	glow.CastShadow = false
	glow.Material = Enum.Material.Neon
	glow.Transparency = 1
	glow.Size = Vector3.new(11, 11, 11)
	glow.Parent = round.folder
	local light = Instance.new("PointLight")
	light.Range = 22
	light.Brightness = 3
	light.Enabled = false
	light.Parent = glow
	self.glow, self.light = glow, light
	return self
end

function View.TeamNames(self: any): { any }
	local out = {}
	for team = 0, 1 do
		local ms = {}
		for _, p in self.round.participants do
			if p.team == team then table.insert(ms, p) end
		end
		table.insert(out, { label = if team == 0 then "EQUIPO AZUL" else "EQUIPO NARANJA", color = if team == 0 then BLUE else ORANGE, members = ms })
	end
	return out
end

function View.HudState(self: any): any
	local r = self.round
	local myTeam = r.me and r.me.team
	local info = ""
	if r.state == "ACTIVE" and self.lone and r.me and r.me.id == self.lone and not self.heat then
		info = "LOBO SOLITARIO: TURBO RÁPIDO (SOLO EN EL SUELO)"
	elseif r.state == "ACTIVE" and self.heat and self.heat.team ~= nil then
		if myTeam ~= nil and self.heat.team ~= myTeam then
			info = "¡VA HACIA TU PORTERÍA! PONTE EN MEDIO"
		elseif myTeam ~= nil then
			info = "¡VA A LA PORTERÍA RIVAL!"
		end
	end
	return {
		left = { label = "AZUL", sub = "", value = tostring(self.goals[0]), color = BLUE },
		right = { label = "NARANJA", sub = "", value = tostring(self.goals[1]), color = ORANGE },
		timeLeft = nil, timeTotal = Shared.MAX_TIME,
		timerNote = if self.overtime then "¡GOL DE ORO!" elseif self.heat and self.heat.speed then string.format("BALÓN A %d KM/H", math.floor(self.heat.speed * 0.036 + 0.5)) else ("PRIMERO A " .. Shared.WIN_GOALS),
		info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "heat" then
		self.heat = if data.team ~= nil then { team = data.team, speed = data.speed } else nil
		-- the prediction world runs the same homing rule: give it the server's lock
		if r.pred then
			r.pred.pw.ball.heat = if data.team ~= nil then { team = data.team, speed = data.speed or Shared.START_SPEED } else nil
		end
	elseif kind == "goal" then
		local g = data.goals or {}
		self.goals = { [0] = g.blue or self.goals[0], [1] = g.orange or self.goals[1] }
		local col = if data.team == 0 then BLUE else ORANGE
		if data.pos then
			pcall(function() Effects.Goal(RenderMap.Pos(data.pos), col, false) end)
		end
		Camera.Shake(1.4)
		local scorer = data.scorer and r.byId[data.scorer]
		local mine = r.me and r.me.team == data.team
		if mine then Rumble.Event("goal") end
		Hud.Banner(if mine then "¡GOL DE TU EQUIPO!" else "¡GOL " .. (if data.team == 0 then "AZUL" else "NARANJA") .. "!",
			(if scorer and not data.ownGoal then Hud.Upper(scorer.name or "?") .. "  ·  " elseif data.ownGoal then "AUTOGOL  ·  " else "") .. (data.kmh or 0) .. " KM/H   ·   " .. self.goals[0] .. " — " .. self.goals[1], col)
		self.heat = nil
		if r.pred then r.pred.pw.ball.heat = nil end
	elseif kind == "camp" then
		if r.me and data.id == r.me.id then
			Hud.Toast("¡NO ACAMPES EN TU PORTERÍA! DE VUELTA AL CAMPO", Color3.fromRGB(255, 120, 90))
		end
	elseif kind == "redrop" then
		self.heat = nil
		if r.pred then r.pred.pw.ball.heat = nil end
		Hud.Toast("BALÓN ATASCADO: REINICIO AL CENTRO", Color3.fromRGB(200, 220, 255))
	elseif kind == "overtime" then
		self.overtime = true
		Hud.Banner("¡GOL DE ORO!", "EL PRÓXIMO GOL GANA", Color3.fromRGB(255, 200, 60))
	end
end

function View.Update(self: any, dt: number)
	local r = self.round
	local heat = self.heat
	if heat and heat.team ~= nil and r.ballPos then
		-- colour of the goal it hunts (the team that did NOT touch it), hotter with speed
		local goalCol = if heat.team == 0 then ORANGE else BLUE
		local k = math.clamp(((heat.speed or Shared.START_SPEED) - Shared.START_SPEED) / (Shared.MAX_SPEED - Shared.START_SPEED), 0, 1)
		local col = goalCol:Lerp(HOT, k * 0.6)
		self.glow.Color = col
		self.light.Color = col
		self.light.Enabled = true
		self.glow.Transparency = 0.55 + 0.15 * math.sin(os.clock() * 14)
		self.glow.CFrame = CFrame.new(RenderMap.Pos(r.ballPos))
	else
		self.glow.Transparency = 1
		self.light.Enabled = false
	end
end

function View.Destroy(self: any)
	if self.glow then self.glow:Destroy() end
end

return View
