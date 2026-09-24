--!strict
-- MinigameViews/SkyRingRush.lua: what Sky Ring Rush looks like on the client. The route comes from the server (a new
-- random one every match). Neon rings drawn exactly where the server's checkpoint boxes are, and only the next few
-- exist for you: your next ring glows gold and pulses (with a "SIGUIENTE" marker you can see through walls), the one
-- after it is white, the one after that is faint; each ring pops into place as it comes up and vanishes once passed.
-- Shortcuts are violet.
-- Progress, positions and the finish come from the server's checkpoint events.
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SkyRingRushShared"))
local Net = require(script.Parent.Parent.Net)
local Hud = require(script.Parent.Parent.MinigameHud)

local S = RenderMap.S
local SEATS = {
	Color3.fromRGB(255, 200, 30),
	Color3.fromRGB(0, 225, 255),
	Color3.fromRGB(255, 60, 140),
	Color3.fromRGB(65, 255, 95),
}
local GOLD = Color3.fromRGB(255, 200, 40)
local WHITE = Color3.fromRGB(240, 244, 255)
local FAINT = Color3.fromRGB(90, 140, 230)
local SHORTCUT = Color3.fromRGB(190, 90, 255)
local SEGS = 28
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)

local View = {}
View.__index = View
View.BallCamDefault = false

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
	p.Material = material or Enum.Material.Neon
	if shape then p.Shape = shape end
	p.Parent = parent
	return p
end

local function buildRing(parent: Instance, r: any): any
	local n, u, v = Shared.RingAxes(r)
	local R = Shared.RING_R + 18
	local segLen = 2 * math.pi * R / SEGS * S * 1.08
	local thick = 26 * S
	local model = Instance.new("Model")
	model.Parent = parent
	local parts = {}
	for i = 0, SEGS - 1 do
		local a = (i + 0.5) / SEGS * math.pi * 2
		local pos = RenderMap.Pos(r.c + (u * math.cos(a) + v * math.sin(a)) * R)
		local tan = RenderMap.Dir(-u * math.sin(a) + v * math.cos(a))
		table.insert(parts, part(model, Vector3.new(segLen, thick, thick), CFrame.lookAt(pos, pos + tan) * CFrame.Angles(0, math.rad(90), 0), FAINT, Enum.Material.Neon, Enum.PartType.Cylinder))
	end
	-- a faint disc to read the ring's opening from afar
	local centre = RenderMap.Pos(r.c)
	local disc = part(model, Vector3.new(0.05, R * 2 * S, R * 2 * S), CFrame.lookAt(centre, centre + RenderMap.Dir(n)) * CFrame.Angles(0, math.rad(90), 0), FAINT, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	disc.Transparency = 0.93
	return { model = model, parts = parts, disc = disc, centre = centre, look = "" }
end

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.route = pub.route
	self.total = #self.route.checkpoints
	self.progress = {}
	for _, p in round.participants do self.progress[p.id] = 1 end
	for id, k in pub.progress or {} do self.progress[id] = k end
	self.deadline = nil
	self.finishOrder = {}

	local env = Instance.new("Folder")
	env.Name = "SkyRingRush"
	env.Parent = round.folder
	self.env = env
	self.rings = {} -- [k] = { ring visuals }
	for k, cp in self.route.checkpoints do
		self.rings[k] = {}
		for ri, r in cp do
			local rv = buildRing(env, r)
			rv.shortcut = ri > 1
			self.rings[k][ri] = rv
		end
	end

	-- "SIGUIENTE" marker (through walls) on the next ring
	local anchor = part(env, Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, -500, 0), GOLD)
	anchor.Transparency = 1
	self.anchor = anchor
	local bb = Instance.new("BillboardGui")
	bb.Name = "NextRingMarker"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(160, 46)
	bb.ResetOnSpawn = false
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 24)
	title.FontFace = OSWALD
	title.TextSize = 20
	title.TextColor3 = GOLD
	title.TextStrokeTransparency = 0.3
	title.Text = "SIGUIENTE"
	title.Parent = bb
	local dist = title:Clone()
	dist.Position = UDim2.fromOffset(0, 22)
	dist.TextSize = 16
	dist.TextColor3 = WHITE
	dist.Text = ""
	dist.Parent = bb
	self.markerDist = dist
	bb.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.marker = bb

	-- a clear evening sky suits neon rings
	self.saved = { ClockTime = Lighting.ClockTime, Brightness = Lighting.Brightness }
	Lighting.ClockTime = 18.3
	Lighting.Brightness = 2.2
	self.grade = Instance.new("ColorCorrectionEffect")
	self.grade.Name = "SkyRingGrade"
	self.grade.Saturation = 0.15
	self.grade.TintColor = Color3.fromRGB(255, 240, 230)
	self.grade.Parent = Lighting
	return self
end

function View.CarColor(self: any, p: any): Color3
	return SEATS[(p.team or 0) % 4 + 1]
end

function View.TeamNames(self: any): { any }
	local cols = {}
	for _, p in self.round.participants do
		table.insert(cols, { label = "CARRIL " .. ((p.team or 0) + 1), color = self:CarColor(p), members = { p } })
	end
	return cols
end

local function ordinal(n: number): string
	return tostring(n) .. "º"
end

-- my position right now: finished first by order, then by rings passed, then by distance to the next ring
function View.MyPlace(self: any): number
	local r = self.round
	if not r.me then return 0 end
	local rows = {}
	for _, p in r.participants do
		local k = self.progress[p.id] or 1
		local fin = table.find(self.finishOrder, p.id)
		local d = math.huge
		local e = r.visuals[p.id]
		local cp = self.route.checkpoints[k]
		if cp and e and e.pos then
			for _, ring in cp do d = math.min(d, (e.pos - ring.c).Magnitude) end
		end
		table.insert(rows, { id = p.id, fin = fin or math.huge, k = k, d = d })
	end
	table.sort(rows, function(a, b)
		if a.fin ~= b.fin then return a.fin < b.fin end
		if a.k ~= b.k then return a.k > b.k end
		return a.d < b.d
	end)
	for i, row in rows do
		if row.id == r.me.id then return i end
	end
	return 0
end

function View.HudState(self: any): any
	local r = self.round
	local myK = if r.me then self.progress[r.me.id] or 1 else 1
	local passed = math.min(myK - 1, self.total)
	local timerText, note = nil, ""
	if r.state == "ACTIVE" and self.deadline then
		timerText = Hud.Clock(math.max(0, self.deadline - Net.Now()))
		note = "¡ÚLTIMOS SEGUNDOS!"
	end
	local info = ""
	if r.me and myK > self.total then
		local fin = table.find(self.finishOrder, r.me.id)
		info = "¡EN META! " .. (if fin then ordinal(fin) else "")
	elseif self.nextDist then
		info = string.format("SIGUIENTE ANILLO · %d m", math.floor(self.nextDist / 100 + 0.5))
	end
	return {
		left = { label = "ANILLOS", sub = "RUTA #" .. self.route.name, value = string.format("%d/%d", passed, self.total), color = GOLD },
		right = { label = "POSICIÓN", sub = "", value = if r.me then ordinal(self:MyPlace()) else "-", color = WHITE },
		timerText = timerText, timeTotal = Shared.MAX_TIME, timerNote = note, info = info,
	}
end

local function flash(env: Instance, rv: any, color: Color3)
	for _, p in rv.parts do
		local g = p:Clone()
		g.Color = color
		g.Size = p.Size * 1.8
		g.Transparency = 0.1
		g.Parent = env
		TweenService:Create(g, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = p.Size * 3.2, Transparency = 1 }):Play()
		task.delay(0.55, function() g:Destroy() end)
	end
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "state" then
		for id, k in data.progress or {} do self.progress[id] = k end
	elseif kind == "checkpoint" then
		self.progress[data.id] = data.index + 1
		if data.deadline then self.deadline = data.deadline end
		local p = r.byId[data.id]
		if data.done then table.insert(self.finishOrder, data.id) end
		if r.me and data.id == r.me.id then
			local rv = self.rings[data.index] and self.rings[data.index][data.ring]
			if rv then flash(self.env, rv, if data.ring > 1 then SHORTCUT else GOLD) end
			Rumble.Event(if data.done then "goal" else "ring")
			if data.done then
				Hud.Banner("¡META!", ordinal(#self.finishOrder) .. " PUESTO", GOLD)
				Camera.Shake(0.8)
			elseif data.ring > 1 then
				Hud.Toast(string.format("¡ATAJO! ANILLO %d/%d", data.index, self.total), SHORTCUT)
			else
				Hud.Toast(string.format("ANILLO %d/%d", data.index, self.total), GOLD)
			end
		elseif data.done and p then
			Hud.Toast(Hud.Upper(p.name or "?") .. " LLEGÓ A META (" .. ordinal(#self.finishOrder) .. ")", self:CarColor(p))
			if #self.finishOrder == 1 then
				Hud.Banner(Hud.Upper(p.name or "?") .. " EN META", string.format("QUEDAN %d s", Shared.GRACE), self:CarColor(p))
			end
		end
	end
end

function View.Update(self: any, dt: number)
	local r = self.round
	local myK = if r.me then self.progress[r.me.id] or 1 else 1
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	for k, list in self.rings do
		for _, rv in list do
			local look
			if k < myK or k > myK + 2 then
				look = "gone"
			elseif k == myK then
				look = if rv.shortcut then "nextShort" else "next"
			elseif k == myK + 1 then
				look = if rv.shortcut then "short" else "after"
			else
				look = if rv.shortcut then "short" else "faint"
			end
			if look ~= rv.look then
				if (rv.look == "gone" or rv.look == "") and look ~= "gone" then
					rv.appear = os.clock() -- comes up: pop it into place
				end
				rv.look = look
				local color = if look == "next" then GOLD elseif look == "nextShort" or look == "short" then SHORTCUT elseif look == "after" then WHITE else FAINT
				local tr = if look == "gone" then 1 elseif look == "faint" or look == "short" then 0.55 else 0
				for _, p in rv.parts do
					p.Color = color
					p.Transparency = tr
				end
				rv.disc.Color = color
				rv.disc.Transparency = if look == "gone" then 1 elseif look == "next" or look == "nextShort" then 0.85 else 0.95
			end
			if look == "next" then
				rv.disc.Transparency = 0.8 + 0.12 * pulse
			end
			if rv.appear then
				local u = math.clamp((os.clock() - rv.appear) / 0.45, 0, 1)
				-- back-out ease: overshoots a little, then settles
				local s1 = 1.70158
				local e = 1 + (s1 + 1) * (u - 1) ^ 3 + s1 * (u - 1) ^ 2
				rv.model:ScaleTo(math.max(0.02, e))
				if u >= 1 then
					rv.model:ScaleTo(1)
					rv.appear = nil
				end
			end
		end
	end
	-- marker on the nearest ring of my next checkpoint
	self.nextDist = nil
	local cp = self.route.checkpoints[myK]
	local me = r.me and r.visuals[r.me.id]
	if cp and me and me.pos then
		local best, bd = nil, math.huge
		for _, ring in cp do
			local d = (me.pos - ring.c).Magnitude
			if d < bd then best, bd = ring, d end
		end
		self.nextDist = bd
		self.anchor.CFrame = CFrame.new(RenderMap.Pos(best.c) + Vector3.new(0, (Shared.RING_R + 90) * S, 0))
		self.markerDist.Text = string.format("%d m", math.floor(bd / 100 + 0.5))
		self.marker.Enabled = true
	else
		self.marker.Enabled = false
	end
end

function View.Destroy(self: any)
	for k, v in self.saved do (Lighting :: any)[k] = v end
	if self.grade then self.grade:Destroy() end
	if self.marker then self.marker:Destroy() end
	self.env:Destroy()
end

return View
