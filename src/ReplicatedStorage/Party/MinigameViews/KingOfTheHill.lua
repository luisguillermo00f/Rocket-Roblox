--!strict
-- MinigameViews/KingOfTheHill.lua: what King of the Hill looks like on the client. The hill is a ring with a tinted
-- floor: neutral when empty, the holder's colour when someone holds it alone, pulsing red when contested. The next
-- hill appears as a dashed ring with a "PRÓXIMA COLINA" marker (visible through walls) NEXT_WARN seconds before the
-- move. Control time comes from the server (discrete "control" changes + once-a-second "scores").
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("KingOfTheHillShared"))
local Net = require(script.Parent.Parent.Net)
local Hud = require(script.Parent.Parent.MinigameHud)

local S = RenderMap.S
local SEATS = {
	Color3.fromRGB(255, 200, 30),
	Color3.fromRGB(0, 225, 255),
	Color3.fromRGB(255, 60, 140),
	Color3.fromRGB(65, 255, 95),
}
local NEUTRAL = Color3.fromRGB(235, 235, 240)
local CONTESTED = Color3.fromRGB(255, 70, 70)
local SEGMENTS = 56
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

local function ring(parent: Instance, dashed: boolean): any
	local r = { parts = {}, dashed = dashed }
	for i = 1, SEGMENTS do
		if dashed and i % 2 == 0 then continue end
		table.insert(r.parts, part(parent, Vector3.new(1, 0.14, 1), CFrame.new(0, -500, 0), NEUTRAL))
	end
	return r
end

local function place(r: any, c: Vector2, radius: number, width: number, y: number)
	local cfs = {}
	local step = if r.dashed then 2 else 1
	local len = 2 * math.pi * radius / SEGMENTS * S * (if r.dashed then 0.6 else 1.05)
	for i, p in r.parts do
		local a = ((i - 1) * step + 0.5) / SEGMENTS * math.pi * 2
		local pos = RenderMap.Pos(Vector3.new(c.X + math.cos(a) * radius, c.Y + math.sin(a) * radius, 0))
		local tan = RenderMap.Dir(Vector3.new(-math.sin(a), math.cos(a), 0))
		local size = Vector3.new(width, 0.14, len)
		if p.Size ~= size then p.Size = size end
		cfs[i] = CFrame.lookAt(Vector3.new(pos.X, y, pos.Z), Vector3.new(pos.X, y, pos.Z) + tan)
	end
	workspace:BulkMoveTo(r.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

local function hide(r: any)
	local cfs = {}
	for i in r.parts do cfs[i] = CFrame.new(0, -500, 0) end
	workspace:BulkMoveTo(r.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.hills = pub.hills or { Vector2.zero }
	self.index = pub.index or 0
	self.count = pub.count or Shared.HILLS
	self.startTime = pub.startTime
	self.control = {}
	for _, p in round.participants do self.control[p.id] = 0 end
	for id, v in pub.control or {} do self.control[id] = v end
	self.holder = pub.holder
	self.shownAt = os.clock()

	local env = Instance.new("Folder")
	env.Name = "KingOfTheHill"
	env.Parent = round.folder
	self.env = env
	self.disc = part(env, Vector3.new(0.1, 1, 1), CFrame.new(0, -500, 0), NEUTRAL, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	self.disc.Transparency = 0.7
	self.ring = ring(env, false)
	self.nextRing = ring(env, true)
	-- a beacon column over the hill so it reads from anywhere in the arena
	self.beam = part(env, Vector3.new(60, 1.2, 1.2), CFrame.new(0, -500, 0), NEUTRAL, Enum.Material.Neon, Enum.PartType.Cylinder)
	self.beam.Transparency = 0.75

	local anchor = part(env, Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, -500, 0), NEUTRAL)
	anchor.Transparency = 1
	self.anchor = anchor
	local bb = Instance.new("BillboardGui")
	bb.Name = "NextHillMarker"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(200, 30)
	bb.ResetOnSpawn = false
	bb.Enabled = false
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.FontFace = OSWALD
	l.TextSize = 20
	l.TextColor3 = NEUTRAL
	l.TextStrokeTransparency = 0.3
	l.Text = "PRÓXIMA COLINA"
	l.Parent = bb
	bb.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	self.marker = bb

	self.grade = Instance.new("ColorCorrectionEffect")
	self.grade.Name = "KingOfTheHillGrade"
	self.grade.Contrast = 0.06
	self.grade.Saturation = 0.12
	self.grade.Parent = Lighting
	return self
end

function View.CarColor(self: any, p: any): Color3
	return SEATS[(p.team or 0) % 4 + 1]
end

function View.TeamNames(self: any): { any }
	local cols = {}
	for _, p in self.round.participants do
		table.insert(cols, { label = "JUGADOR " .. ((p.team or 0) + 1), color = self:CarColor(p), members = { p } })
	end
	return cols
end

function View.HillTime(self: any): (number, number)
	if not self.startTime then return 0, Shared.HILL_TIME end
	local t = math.max(0, Net.Now() - self.startTime)
	return t, math.max(0, Shared.HILL_TIME - t)
end

function View.HudState(self: any): any
	local r = self.round
	local mine = if r.me then self.control[r.me.id] or 0 else 0
	-- the leader other than me (or me if I lead)
	local leadId, lead = nil, -1
	for id, v in self.control do
		if v > lead then leadId, lead = id, v end
	end
	local leader = leadId and r.byId[leadId]
	local _, left = self:HillTime()
	local info = ""
	if r.state == "ACTIVE" and r.me then
		if self.holder == r.me.id then
			info = "¡DOMINAS LA COLINA!"
		elseif self.holder == "contested" then
			info = "¡DISPUTADA! NADIE SUMA"
		elseif self.hillDist then
			info = string.format("VE A LA COLINA · %d m", math.floor(self.hillDist / 100 + 0.5))
		end
	end
	return {
		left = { label = "TU TIEMPO", sub = "", value = string.format("%.1f", mine), color = if r.me then self:CarColor(r.me) else NEUTRAL },
		right = { label = "LÍDER", sub = if leader then Hud.Upper(leader.name or "?") else "", value = string.format("%.1f", math.max(0, lead)), color = if leader then self:CarColor(leader) else NEUTRAL },
		timeLeft = nil, timeTotal = Shared.MAX_TIME,
		timerNote = if r.state == "ACTIVE" then (if left <= Shared.NEXT_WARN and self.index < self.count then "LA COLINA SE MUEVE" else string.format("COLINA %d/%d", math.max(1, self.index), self.count)) else "",
		info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "hill" then
		self.hills = data.hills or self.hills
		self.index = data.index
		self.count = data.count or self.count
		self.startTime = data.startTime
		if data.index > 1 then
			Hud.Toast(string.format("LA COLINA SE MOVIÓ · %d/%d", data.index, self.count), NEUTRAL)
		end
	elseif kind == "scores" then
		for id, v in data.control or {} do self.control[id] = v end
	elseif kind == "control" then
		local prev = self.holder
		self.holder = data.holder
		if r.me and data.holder == r.me.id and prev ~= r.me.id then
			Rumble.Event("ring")
			Hud.Toast("¡LA COLINA ES TUYA!", self:CarColor(r.me))
		elseif r.me and prev == r.me.id and data.holder ~= r.me.id then
			if data.holder == "contested" then
				Hud.Toast("¡TE LA DISPUTAN!", CONTESTED)
			end
		end
	end
end

function View.Update(self: any, dt: number)
	local r = self.round
	local c = self.hills[math.max(1, self.index)]
	local t, left = self:HillTime()
	-- colour by who holds it
	local col = NEUTRAL
	if self.holder == "contested" then
		col = NEUTRAL:Lerp(CONTESTED, 0.55 + 0.45 * math.sin(os.clock() * 12))
	elseif self.holder and r.byId[self.holder] then
		col = self:CarColor(r.byId[self.holder])
	end
	place(self.ring, c, Shared.RADIUS, 28 * S, 0.13)
	for _, p in self.ring.parts do p.Color = col end
	local dp = RenderMap.Pos(Vector3.new(c.X, c.Y, 0))
	local d = Shared.RADIUS * 2 * S
	if self.disc.Size.Y ~= d then self.disc.Size = Vector3.new(0.1, d, d) end
	self.disc.CFrame = CFrame.new(dp.X, 0.09, dp.Z) * CFrame.Angles(0, 0, math.rad(90))
	self.disc.Color = col
	self.beam.CFrame = CFrame.new(dp.X, 30, dp.Z) * CFrame.Angles(0, 0, math.rad(90))
	self.beam.Color = col

	-- next hill, announced
	local nextC = self.hills[self.index + 1]
	if nextC and self.index >= 1 and left <= Shared.NEXT_WARN and r.state == "ACTIVE" then
		place(self.nextRing, nextC, Shared.RADIUS, 20 * S, 0.15)
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
		for _, p in self.nextRing.parts do p.Transparency = 0.5 * (1 - pulse) end
		self.anchor.CFrame = CFrame.new(RenderMap.Pos(Vector3.new(nextC.X, nextC.Y, 300)))
		self.marker.Enabled = true
	else
		hide(self.nextRing)
		self.marker.Enabled = false
	end

	self.hillDist = nil
	local me = r.me and r.visuals[r.me.id]
	if me and me.pos then
		self.hillDist = math.max(0, (Vector2.new(me.pos.X, me.pos.Y) - c).Magnitude - Shared.RADIUS)
	end
end

function View.Destroy(self: any)
	if self.grade then self.grade:Destroy() end
	if self.marker then self.marker:Destroy() end
	self.env:Destroy()
end

return View
