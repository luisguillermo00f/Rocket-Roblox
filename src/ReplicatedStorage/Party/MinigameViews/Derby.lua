--!strict
-- MinigameViews/Derby.lua: what Demolition Derby looks like on the client. The map ("EL COLISEO") is built by
-- MinigameClient from the shared module. This view adds: a colour per player, demolition explosions and banners,
-- streak callouts, the FRENZY warning (and the rule switch in our own prediction) and a warm arena grade.
local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("DerbyShared"))
local Hud = require(script.Parent.Parent.MinigameHud)

local SEATS = {
	Color3.fromRGB(255, 200, 30),
	Color3.fromRGB(0, 225, 255),
	Color3.fromRGB(255, 60, 140),
	Color3.fromRGB(65, 255, 95),
}
local NEUTRAL = Color3.fromRGB(235, 235, 240)
local RED = Color3.fromRGB(255, 70, 50)
local STREAKS = { [2] = "¡DOBLE DEMOLICIÓN!", [3] = "¡TRIPLE DEMOLICIÓN!", [4] = "¡IMPARABLE!" }

local View = {}
View.__index = View
View.BallCamDefault = false

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.demos, self.deaths, self.points = {}, {}, {}
	for _, p in round.participants do self.demos[p.id], self.deaths[p.id], self.points[p.id] = 0, 0, 0 end
	for id, v in pub.demos or {} do self.demos[id] = v end
	for id, v in pub.points or {} do self.points[id] = v end
	self.shields = {} -- member id -> { until, highlight }
	for id, v in pub.deaths or {} do self.deaths[id] = v end
	self.frenzy = pub.frenzy == true
	if self.frenzy and round.pred then round.pred.pw.demoMode = "on_contact" end
	self.grade = Instance.new("ColorCorrectionEffect")
	self.grade.Name = "DerbyGrade"
	self.grade.Contrast = 0.08
	self.grade.Saturation = 0.1
	self.grade.TintColor = Color3.fromRGB(255, 244, 230)
	self.grade.Parent = Lighting
	return self
end

function View.CarColor(self: any, p: any): Color3
	return SEATS[(p.team or 0) % 4 + 1]
end

function View.TeamNames(self: any): { any }
	local cols = {}
	for _, p in self.round.participants do
		table.insert(cols, { label = Hud.Upper(p.name or "?"), color = self:CarColor(p), members = { p } })
	end
	return cols
end

function View.HudState(self: any): any
	local r = self.round
	local mine = if r.me then self.points[r.me.id] or 0 else 0
	local leadId, lead = nil, -1
	for id, v in self.points do
		if v > lead or (v == lead and r.me and id == r.me.id) then leadId, lead = id, v end
	end
	local leader = leadId and r.byId[leadId]
	local info = ""
	if r.state == "ACTIVE" then
		if r.meHidden then
			info = "¡TE DEMOLIERON! VUELVES EN UN MOMENTO"
		elseif r.me and self.shields[r.me.id] and os.clock() < self.shields[r.me.id].untilT then
			info = "ESCUDO DE APARICIÓN: NI TE DEMUELEN NI DEMUELES"
		elseif self.frenzy then
			info = "¡FRENESÍ! CUALQUIER CHOQUE DEMUELE"
		elseif r.pred and r.pred.car and not r.pred.car.isSupersonic then
			info = "GANA VELOCIDAD: SOLO DEMUELES A TODA MÁQUINA"
		end
	end
	return {
		left = { label = "TUS PUNTOS", sub = if r.me then (string.format("%d DEMOL. · DEMOLIDO %d", self.demos[r.me.id] or 0, self.deaths[r.me.id] or 0)) else "", value = tostring(mine), color = if r.me then self:CarColor(r.me) else NEUTRAL },
		right = { label = "LÍDER", sub = if leader then Hud.Upper(leader.name or "?") else "", value = tostring(math.max(0, lead)), color = if leader then self:CarColor(leader) else NEUTRAL },
		timeLeft = nil, timeTotal = Shared.MAX_TIME,
		timerNote = if self.frenzy then "¡FRENESÍ!" else "DERBI",
		info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "demo" then
		for id, v in data.demos or {} do self.demos[id] = v end
		for id, v in data.deaths or {} do self.deaths[id] = v end
		for id, v in data.points or {} do self.points[id] = v end
		local by, victim = r.byId[data.by], r.byId[data.victim]
		local col = if by then self:CarColor(by) else RED
		if data.pos then
			pcall(function() Effects.Demolish(RenderMap.Pos(data.pos), col) end)
		end
		local mineBy = r.me and data.by == r.me.id
		local mineVictim = r.me and data.victim == r.me.id
		if mineBy then
			Rumble.Event("demo")
			Camera.Shake(0.9)
			local sub = "A " .. Hud.Upper(victim and victim.name or "?")
			if data.farmed then
				sub ..= "  ·  REPETIDA: 0 PUNTOS"
			elseif data.bounty then
				sub ..= "  ·  ¡RECOMPENSA AL LÍDER! +" .. tostring(data.worth)
			end
			Hud.Banner(if data.bounty then "¡CAZASTE AL LÍDER!" else (STREAKS[data.streak or 1] or "¡DEMOLICIÓN!"), sub, col)
		elseif mineVictim then
			Rumble.Event("demoed")
			Hud.Banner("¡DEMOLIDO!", "POR " .. Hud.Upper(by and by.name or "?"), RED)
		else
			Hud.Toast(Hud.Upper(by and by.name or "?") .. " DEMUELE A " .. Hud.Upper(victim and victim.name or "?"), col)
		end
	elseif kind == "shield" then
		local e = r.visuals and r.visuals[data.id]
		local old = self.shields[data.id]
		if old and old.hl then old.hl:Destroy() end
		local hl: Highlight? = nil
		if e and e.visual and e.visual.model then
			hl = Instance.new("Highlight")
			hl.FillColor = Color3.fromRGB(200, 235, 255)
			hl.OutlineColor = Color3.fromRGB(230, 245, 255)
			hl.FillTransparency = 0.6
			hl.Parent = e.visual.model
		end
		self.shields[data.id] = { untilT = os.clock() + (data.time or 2.5), hl = hl }
	elseif kind == "scores" then
		for id, v in data.demos or {} do self.demos[id] = v end
		for id, v in data.deaths or {} do self.deaths[id] = v end
		for id, v in data.points or {} do self.points[id] = v end
	elseif kind == "frenzy" then
		self.frenzy = true
		if r.pred then r.pred.pw.demoMode = "on_contact" end
		Hud.Banner("¡FRENESÍ!", "CUALQUIER CHOQUE DEMUELE", RED)
		Camera.Shake(0.6)
	end
end

function View.Update(self: any, dt: number)
	-- shields flicker, then go
	local now = os.clock()
	for id, sh in self.shields do
		if now >= sh.untilT then
			if sh.hl then sh.hl:Destroy() end
			self.shields[id] = nil
		elseif sh.hl then
			sh.hl.FillTransparency = 0.45 + 0.35 * (0.5 + 0.5 * math.sin(now * 18))
		end
	end
	if self.frenzy then
		self.grade.TintColor = Color3.fromRGB(255, 225, 215):Lerp(Color3.fromRGB(255, 200, 190), 0.5 + 0.5 * math.sin(os.clock() * 5))
	end
end

function View.Destroy(self: any)
	for _, sh in self.shields do if sh.hl then sh.hl:Destroy() end end
	if self.grade then self.grade:Destroy() end
end

return View
