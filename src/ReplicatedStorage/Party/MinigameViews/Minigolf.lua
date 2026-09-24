--!strict
-- MinigolfView (MinigameViews/Minigolf.lua): what Giant Minigolf looks like on the client. The map ("ISLAS DEL GOLF")
-- is built by MinigameClient from the shared module. Our own ball is the round's normal ball (predicted with our car:
-- the server sends each player THEIR ball); this view adds everyone else's balls (10 Hz, smoothed) in their colours,
-- a light beam over the current cup, the hole / par / strokes readout and the hole-in / out-of-bounds callouts.
local RS = game:GetService("ReplicatedStorage")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("MinigolfShared"))
local Net = require(script.Parent.Parent.Net)
local Hud = require(script.Parent.Parent.MinigameHud)

local S = RenderMap.S
local SEATS = {
	Color3.fromRGB(255, 200, 30),
	Color3.fromRGB(0, 225, 255),
	Color3.fromRGB(255, 60, 140),
	Color3.fromRGB(170, 120, 255),
}
local WHITE = Color3.fromRGB(245, 245, 245)
local GOLD = Color3.fromRGB(255, 205, 60)

local View = {}
View.__index = View
View.BallCamDefault = true

-- golf names for a score relative to par
local function scoreName(strokes: number, par: number): string
	if strokes == 1 then return "¡HOYO EN UNO!" end
	local d = strokes - par
	if d <= -3 then return "¡ALBATROS!" end
	if d == -2 then return "¡ÁGUILA!" end
	if d == -1 then return "¡BIRDIE!" end
	if d == 0 then return "¡PAR!" end
	if d == 1 then return "BOGEY" end
	if d == 2 then return "DOBLE BOGEY" end
	return "+" .. d
end

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.hole = pub.hole
	self.strokes, self.total, self.holed = {}, {}, {}
	for _, p in round.participants do self.strokes[p.id], self.total[p.id] = 0, 0 end
	for id, v in pub.total or {} do self.total[id] = v end
	if self.hole then
		for id, v in self.hole.strokes or {} do self.strokes[id] = v end
	end
	for _, id in pub.holed or {} do self.holed[id] = true end
	-- only our car touches our ball in our prediction; the world knows the current cup for its lip rule
	if round.pred then
		round.pred.pw.ballOwner = round.pred.car
		round.pred.pw.golfCup = self.hole and self.hole.cup
	end
	local env = Instance.new("Folder")
	env.Name = "Minigolf"
	env.Parent = round.folder
	self.env = env
	-- the other players' balls
	self.others = {}
	for _, p in round.participants do
		if p ~= round.me then
			local ball = Instance.new("Part")
			ball.Name = "Ball_" .. p.id
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.one * (182.5 * S)
			ball.Anchored = true
			ball.CanCollide = false
			ball.CanQuery = false
			ball.CanTouch = false
			ball.Material = Enum.Material.SmoothPlastic
			ball.Color = SEATS[(p.team or 0) % 4 + 1]:Lerp(WHITE, 0.35)
			ball.Transparency = 0.25
			ball.Position = Vector3.new(0, -500, 0)
			ball.Parent = env
			local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
			a0.Position, a1.Position = Vector3.new(0, 1.5, 0), Vector3.new(0, -1.5, 0)
			a0.Parent, a1.Parent = ball, ball
			local trail = Instance.new("Trail")
			trail.Attachment0, trail.Attachment1 = a0, a1
			trail.Lifetime = 0.35
			trail.Color = ColorSequence.new(ball.Color)
			trail.Transparency = NumberSequence.new(0.4, 1)
			trail.LightEmission = 0.5
			trail.Parent = ball
			self.others[p.id] = { part = ball, from = nil, to = nil, t = 0 }
		end
	end
	-- a beam of light over the current cup, seen from anywhere on the hole
	local beam = Instance.new("Part")
	beam.Name = "CupBeam"
	beam.Shape = Enum.PartType.Cylinder
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = GOLD
	beam.Transparency = 0.8
	beam.Size = Vector3.new(160, 9, 9)
	beam.Position = Vector3.new(0, -800, 0)
	beam.Parent = env
	self.beam = beam
	self.lastBallsAt = os.clock()
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

-- the per-tick lip rule runs in our prediction only while a hole is being played
function View.PostStepLive(self: any): boolean
	return self.hole ~= nil and self.hole.playing == true
end

function View.HudState(self: any): any
	local r = self.round
	local h = self.hole
	local me = r.me
	local mine = if me then self.strokes[me.id] or 0 else 0
	local myTotal = if me then self.total[me.id] or 0 else 0
	-- the leader: fewest total strokes (+ this hole's so far)
	local leadId, lead = nil, math.huge
	for _, p in r.participants do
		local v = (self.total[p.id] or 0) + (self.strokes[p.id] or 0)
		if v < lead then leadId, lead = p.id, v end
	end
	local leader = leadId and r.byId[leadId]
	local info = ""
	local timeLeft = nil
	if h and r.state == "ACTIVE" then
		if h.endTime and h.playing then timeLeft = math.max(0, h.endTime - Net.Now()) end
		if not h.playing then
			info = string.format("HOYO %d/%d · %s · PAR %d", h.index or 1, h.count or 3, h.name or "", h.par or 3)
		elseif me and self.holed[me.id] then
			info = "¡EMBOCADA! ESPERA A LOS DEMÁS"
		elseif r.ballPos and h.cup then
			local d = Vector3.new(h.cup.X - r.ballPos.X, h.cup.Y - r.ballPos.Y, 0).Magnitude
			info = string.format("TOCA TU BALÓN HACIA EL HOYO · %d m", math.floor(d / 100 + 0.5))
		end
	end
	return {
		left = { label = "GOLPES", sub = "TOTAL " .. (myTotal + mine), value = tostring(mine), color = if me then self:CarColor(me) else WHITE },
		right = { label = "LÍDER", sub = if leader then Hud.Upper(leader.name or "?") else "", value = tostring(if lead < math.huge then lead else 0), color = if leader then self:CarColor(leader) else WHITE },
		timeLeft = timeLeft, timeTotal = Shared.HOLE_TIME,
		timerNote = if h then string.format("HOYO %d/%d · PAR %d", h.index or 1, h.count or 3, h.par or 3) else "MINIGOLF",
		info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "hole" then
		local fresh = not self.hole or self.hole.index ~= data.index
		self.hole = data
		if r.pred then r.pred.pw.golfCup = data.cup end
		if fresh then
			self.holed = {}
			for _, p in r.participants do self.strokes[p.id] = 0 end
			for id, v in data.total or {} do self.total[id] = v end
			for _, o in self.others do o.from, o.to = nil, nil end
			Hud.Banner(string.format("HOYO %d · %s", data.index or 1, data.name or ""), "PAR " .. (data.par or 3), GOLD)
		elseif data.playing then
			Hud.Toast("¡A JUGAR!", GOLD)
		end
	elseif kind == "stroke" then
		self.strokes[data.id] = data.strokes
		if r.me and data.id == r.me.id then
			if data.why == "oob" then
				Hud.Toast("¡FUERA! +1 GOLPE", Color3.fromRGB(255, 90, 70))
			elseif data.why == "push" then
				Hud.Toast("EMPUJAR CUENTA COMO GOLPE", Color3.fromRGB(255, 170, 60))
			end
		end
	elseif kind == "oob" then
		if r.me and data.id == r.me.id then Rumble.Event("pinch") end
	elseif kind == "holed" then
		self.holed[data.id] = true
		self.strokes[data.id] = data.strokes
		local who = r.byId[data.id]
		local col = if who then self:CarColor(who) else GOLD
		local name = scoreName(data.strokes or 0, data.par or 3)
		if data.pos then pcall(function() Effects.Goal(RenderMap.Pos(data.pos), col, false) end) end
		if r.me and data.id == r.me.id then
			Rumble.Event("goal")
			Camera.Shake(0.5)
			Hud.Banner(name, string.format("%d GOLPE%s", data.strokes or 0, if data.strokes == 1 then "" else "S"), GOLD)
		else
			Hud.Toast(Hud.Upper(who and who.name or "?") .. " EMBOCA · " .. name, col)
		end
	elseif kind == "capped" then
		self.holed[data.id] = true
		self.strokes[data.id] = data.strokes
		local who = r.byId[data.id]
		if r.me and data.id == r.me.id then
			Hud.Banner("LÍMITE DE GOLPES", "HOYO CERRADO · CUENTA PAR + " .. Shared.MAX_OVER_PAR, Color3.fromRGB(255, 150, 80))
		else
			Hud.Toast(Hud.Upper(who and who.name or "?") .. " LLEGA AL LÍMITE DE GOLPES", Color3.fromRGB(255, 150, 80))
		end
	elseif kind == "holeEnd" then
		for id, v in data.total or {} do self.total[id] = v end
		for _, p in r.participants do self.strokes[p.id] = 0 end
	elseif kind == "final" then
		for id, v in data.total or {} do self.total[id] = v end
		for _, p in r.participants do self.strokes[p.id] = 0 end
	elseif kind == "balls" then
		local now = os.clock()
		for id, pos in data.pos or {} do
			local o = self.others[id]
			if o then
				o.from = if o.to then o.part.Position else RenderMap.Pos(pos)
				o.to = RenderMap.Pos(pos)
				o.t = 0
				o.span = math.clamp(now - self.lastBallsAt, 0.05, 0.25)
			end
		end
		self.lastBallsAt = now
	end
end

function View.Update(self: any, dt: number)
	for id, o in self.others do
		if o.to then
			o.t += dt
			local k = math.clamp(o.t / (o.span or 0.1), 0, 1)
			o.part.Position = o.from:Lerp(o.to, k)
			o.part.Transparency = if self.holed[id] then 0.7 else 0.25
		end
	end
	local h = self.hole
	if h and h.cup then
		local base = RenderMap.Pos(h.cup)
		self.beam.CFrame = CFrame.new(base + Vector3.new(0, 80, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		self.beam.Transparency = 0.78 + 0.08 * math.sin(os.clock() * 3)
	end
end

function View.Destroy(self: any)
	if self.env then self.env:Destroy() end
end

return View
