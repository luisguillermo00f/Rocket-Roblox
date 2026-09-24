--!strict
-- MinigameViews/Infection.lua: what Infection looks like on the client. The map ("CIUDAD NEÓN") is built by
-- MinigameClient from the shared module; this view turns the city to dusk, paints the infected cars toxic green
-- with a glow that shows through buildings (so hunters and runners can read the chase), and tells you what to do.
local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("InfectionShared"))
local Hud = require(script.Parent.Parent.MinigameHud)

local HEALTHY = Color3.fromRGB(235, 240, 255)
local TOXIC = Color3.fromRGB(110, 255, 60)
local SEATS = {
	Color3.fromRGB(255, 200, 30),
	Color3.fromRGB(0, 225, 255),
	Color3.fromRGB(255, 60, 140),
	Color3.fromRGB(170, 120, 255),
}

local View = {}
View.__index = View
View.BallCamDefault = false

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.infected = {}
	for _, id in pub.infected or {} do self.infected[id] = true end
	self.points = {}
	for _, p in round.participants do self.points[p.id] = 0 end
	for id, v in pub.points or {} do self.points[id] = v end
	self.lastId = nil
	self.glows = {}
	-- (the night lighting comes with the map: CiudadNeon's lighting preset)
	self.camping = false
	self.reveal = nil :: Highlight?
	for id in self.infected do self:Mark(id) end
	return self
end

function View.CarColor(self: any, p: any): Color3
	if self.infected and self.infected[p.id] then return TOXIC end
	return SEATS[(p.team or 0) % 4 + 1]
end

function View.TeamNames(self: any): { any }
	local cols = {}
	for _, p in self.round.participants do
		table.insert(cols, { label = Hud.Upper(p.name or "?"), color = SEATS[(p.team or 0) % 4 + 1], members = { p } })
	end
	return cols
end

-- paint a car infected: toxic paint + a glow visible through walls
function View.Mark(self: any, id: string)
	local r = self.round
	if r.Repaint then r:Repaint(id, TOXIC) end
	local e = r.visuals and r.visuals[id]
	if e and e.visual and e.visual.model and not self.glows[id] then
		local h = Instance.new("Highlight")
		h.Name = "Infected"
		h.FillColor = TOXIC
		h.FillTransparency = 0.65
		h.OutlineColor = TOXIC
		h.OutlineTransparency = 0.1
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = e.visual.model
		self.glows[id] = h
	end
	if r.me and id == r.me.id and r.pred and r.pred.car then
		r.pred.car.infected = true -- the boost rule in our prediction
	end
end

function View.HudState(self: any): any
	local r = self.round
	local meInf = r.me and self.infected[r.me.id]
	local healthy = 0
	for _, p in r.participants do if not self.infected[p.id] then healthy += 1 end end
	local leadId, lead = nil, -1
	for id, v in self.points do
		if v > lead then leadId, lead = id, v end
	end
	local leader = leadId and r.byId[leadId]
	local info = ""
	if r.state == "ACTIVE" and r.me then
		if meInf then
			info = if healthy > 0 then ("¡INFECTADO! TOCA A LOS SANOS · QUEDAN " .. healthy) else "¡TODOS INFECTADOS!"
		elseif self.camping then
			info = "¡BAJA DE LA AZOTEA! AHÍ ARRIBA NO SUMAS"
		elseif self.lastId == r.me.id then
			info = "¡ERES EL ÚLTIMO SANO! TODOS TE VEN"
		else
			info = "¡HUYE DE LOS VERDES! SUMAS CADA SEGUNDO"
		end
	end
	return {
		left = { label = if meInf then "INFECTADO" else "SANO", sub = "PUNTOS", value = tostring(if r.me then self.points[r.me.id] or 0 else 0), color = if meInf then TOXIC else HEALTHY },
		right = { label = "LÍDER", sub = if leader then Hud.Upper(leader.name or "?") else "", value = tostring(math.max(0, lead)), color = if leader then SEATS[(leader.team or 0) % 4 + 1] else HEALTHY },
		timeLeft = nil, timeTotal = Shared.MAX_TIME,
		timerNote = healthy .. (if healthy == 1 then " SANO" else " SANOS"),
		info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "infect" then
		self.infected[data.id] = true
		for _, id in data.infected or {} do self.infected[id] = true end
		for id, v in data.points or {} do self.points[id] = v end
		self:Mark(data.id)
		local who, by = r.byId[data.id], data.by and r.byId[data.by]
		if data.pos then pcall(function() Effects.Demolish(RenderMap.Pos(data.pos), TOXIC) end) end
		if r.me and data.id == r.me.id then
			Rumble.Event("demoed")
			Camera.Shake(0.7)
			Hud.Banner(if data.zero then "¡ERES EL PACIENTE CERO!" else "¡TE INFECTARON!", if data.zero then "CONTAGIA A TODOS" else ("POR " .. Hud.Upper(by and by.name or "?")), TOXIC)
		elseif r.me and data.by == r.me.id then
			Rumble.Event("demo")
			Hud.Banner("¡CONTAGIO!", Hud.Upper(who and who.name or "?") .. "  ·  +" .. Shared.PER_INFECTION, TOXIC)
		elseif data.zero then
			Hud.Banner("¡PACIENTE CERO: " .. Hud.Upper(who and who.name or "?") .. "!", "¡HUYE!", TOXIC)
		else
			Hud.Toast(Hud.Upper(by and by.name or "?") .. " INFECTA A " .. Hud.Upper(who and who.name or "?"), TOXIC)
		end
	elseif kind == "last" then
		self.lastId = data.id
		local who = r.byId[data.id]
		Hud.Toast("¡ÚLTIMO SANO: " .. Hud.Upper(who and who.name or "?") .. "! AHORA SE VE A TRAVÉS DE LOS EDIFICIOS", HEALTHY)
		-- the last survivor is revealed to everyone (a white outline through walls)
		local e = r.visuals and r.visuals[data.id]
		if e and e.visual and e.visual.model and not self.reveal then
			local h = Instance.new("Highlight")
			h.Name = "LastSurvivor"
			h.FillTransparency = 1
			h.OutlineColor = HEALTHY
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = e.visual.model
			self.reveal = h
		end
	elseif kind == "roof" then
		if r.me and data.id == r.me.id then
			self.camping = data.camping == true
			if self.camping then Hud.Toast("EN LA AZOTEA NO SUMAS PUNTOS", Color3.fromRGB(255, 170, 60)) end
		end
	elseif kind == "scores" then
		for id, v in data.points or {} do self.points[id] = v end
	end
end

function View.Update(self: any, dt: number)
	-- (the round adds its car visuals after creating the view: glow any infected car that has none yet)
	local r = self.round
	for id in self.infected do
		local e = r.visuals and r.visuals[id]
		if not self.glows[id] and e and e.visual and e.visual.model then self:Mark(id) end
	end
	-- glows pulse
	local k = 0.55 + 0.15 * math.sin(os.clock() * 6)
	for _, h in self.glows do h.FillTransparency = k end
end

function View.Destroy(self: any)
	for _, h in self.glows do h:Destroy() end
	if self.reveal then self.reveal:Destroy() end
end

return View
