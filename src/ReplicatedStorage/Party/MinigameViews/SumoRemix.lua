--!strict
-- MinigameViews/SumoRemix.lua: what Sumo Remix looks like on the client. The safe zone is a neon ring with a lit
-- floor inside; the announced next zone is a dashed ring that pulses while it waits; every player has their own
-- colour. The zone geometry is computed from the server's plan with the shared ZoneAt(), on the server clock, so what
-- you see is what the server checks. Lighting changes are put back on Destroy.
local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Rumble = require(Game.Rumble)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SumoRemixShared"))
local Net = require(script.Parent.Parent.Net)
local Hud = require(script.Parent.Parent.MinigameHud)

local S = RenderMap.S
local SEATS = {
	Color3.fromRGB(255, 200, 30), -- gold
	Color3.fromRGB(0, 225, 255), -- cyan
	Color3.fromRGB(255, 60, 140), -- coral
	Color3.fromRGB(65, 255, 95), -- lime
}
local SAFE = Color3.fromRGB(80, 230, 255)
local NEXT = Color3.fromRGB(255, 255, 255)
local DANGER = Color3.fromRGB(255, 70, 70)
local SEGMENTS = 72

local View = {}
View.__index = View
View.BallCamDefault = false -- no ball: C does nothing useful, keep the car camera

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
	p.Parent = parent
	return p
end

local function makeRing(parent: Instance, color: Color3, dashed: boolean): any
	local ring = { parts = {}, dashed = dashed, color = color }
	for i = 1, SEGMENTS do
		if dashed and i % 2 == 0 then continue end
		table.insert(ring.parts, part(parent, Vector3.new(1, 0.12, 1), CFrame.new(0, -500, 0), color, Enum.Material.Neon))
	end
	return ring
end

-- place a ring of radius r (uu) around centre c (sim xy)
local function placeRing(ring: any, c: Vector2, r: number, width: number, y: number)
	local cfs = {}
	local step = if ring.dashed then 2 else 1
	local seg = 2 * math.pi * r / SEGMENTS * S
	local len = seg * (if ring.dashed then 0.6 else 1.04)
	for i, p in ring.parts do
		local k = (i - 1) * step
		local a = (k + 0.5) / SEGMENTS * math.pi * 2
		local pos = RenderMap.Pos(Vector3.new(c.X + math.cos(a) * r, c.Y + math.sin(a) * r, 0))
		local tangent = RenderMap.Dir(Vector3.new(-math.sin(a), math.cos(a), 0))
		local size = Vector3.new(width, 0.12, len)
		if p.Size ~= size then p.Size = size end
		cfs[i] = CFrame.lookAt(Vector3.new(pos.X, y, pos.Z), Vector3.new(pos.X, y, pos.Z) + tangent)
	end
	workspace:BulkMoveTo(ring.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.zones = pub.zones or { { c = Vector2.zero, r = Shared.R0 } }
	self.phase = pub.phase or 0
	self.phases = pub.phases or #Shared.RADII
	self.phaseStart = pub.phaseStart
	self.alive = {}
	for _, p in round.participants do self.alive[p.id] = true end
	self.aliveCount = #round.participants

	local env = Instance.new("Folder")
	env.Name = "SumoRemix"
	env.Parent = round.folder
	self.env = env
	-- lit floor inside the safe zone
	self.disc = part(env, Vector3.new(0.1, 1, 1), CFrame.new(0, -500, 0), SAFE, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	self.disc.Transparency = 0.82
	self.ring = makeRing(env, SAFE, false)
	self.nextRing = makeRing(env, NEXT, true)

	-- a little cooler, more contrast: it's a ring fight
	self.grade = Instance.new("ColorCorrectionEffect")
	self.grade.Name = "SumoRemixGrade"
	self.grade.Contrast = 0.08
	self.grade.Saturation = 0.1
	self.grade.TintColor = Color3.fromRGB(240, 246, 255)
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

-- zone now (server clock) and the time left to the next check
function View.Zone(self: any): (Vector2, number, number, number)
	local k = self.phase
	if k < 1 or not self.phaseStart then
		local z = self.zones[1]
		return z.c, z.r, Shared.PHASE, 0
	end
	local t = math.max(0, Net.Now() - self.phaseStart)
	local c, r = Shared.ZoneAt(self.zones, k, math.min(t, Shared.PHASE))
	return c, r, math.max(0, Shared.PHASE - t), t
end

function View.HudState(self: any): any
	local r = self.round
	local _, _, left, t = self:Zone()
	local info = ""
	local note = if t < Shared.WARN then "PRÓXIMA ZONA" else "SE CIERRA"
	if r.me then
		if r.meHidden or not self.alive[r.me.id] then
			info = "ELIMINADO · MIRANDO"
		elseif self.outside then
			info = "¡FUERA DE LA ZONA! VUELVE AL CÍRCULO"
		end
	end
	return {
		left = { label = "EN PIE", sub = "", value = string.format("%d/%d", self.aliveCount, #r.participants), color = SAFE },
		right = { label = "FASE", sub = "", value = string.format("%d/%d", math.max(1, self.phase), self.phases), color = NEXT },
		timerText = if r.state == "ACTIVE" then Hud.Clock(left) else nil,
		timeTotal = Shared.PHASE, timerNote = if r.state == "ACTIVE" then note else "", info = info,
	}
end

function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	if kind == "zone" then
		self.zones = data.zones or self.zones
		self.phase = data.phase
		self.phases = data.phases or self.phases
		self.phaseStart = data.phaseStart
		if data.phase > 1 then
			Hud.Toast(string.format("FASE %d · LA ZONA SE MUEVE", data.phase), NEXT)
		end
	elseif kind == "state" then
		self.alive = {}
		for _, id in data.alive or {} do self.alive[id] = true end
		self.aliveCount = #(data.alive or {})
	elseif kind == "eliminated" then
		self.alive[data.id] = nil
		self.aliveCount = data.left or self.aliveCount
		local p = r.byId[data.id]
		local by = data.by and r.byId[data.by]
		local name = Hud.Upper(p and p.name or "?")
		local color = p and self:CarColor(p) or DANGER
		if r.me and data.id == r.me.id then
			Hud.Banner("¡ELIMINADO!", if by then "TE ECHÓ " .. Hud.Upper(by.name or "?") else string.upper(data.why or ""), DANGER)
			Camera.Shake(1.2)
			Rumble.Event("eliminated")
		elseif r.me and data.by == r.me.id then
			Rumble.Event("demo")
			Hud.Banner("¡FUERA " .. name .. "!", "TU EMPUJÓN LO SACÓ", color)
		else
			Hud.Toast(if by then Hud.Upper(by.name or "?") .. " ECHÓ A " .. name else name .. " ELIMINADO", color)
		end
		if data.pos then
			Effects.Demolish(RenderMap.Pos(data.pos), color)
		end
	end
end

function View.Update(self: any, dt: number)
	local c, r, left, t = self:Zone()
	placeRing(self.ring, c, r, 22 * S, 0.12)
	local dp = RenderMap.Pos(Vector3.new(c.X, c.Y, 0))
	local d = r * 2 * S
	if self.disc.Size.Y ~= d then self.disc.Size = Vector3.new(0.1, d, d) end
	self.disc.CFrame = CFrame.new(dp.X, 0.08, dp.Z) * CFrame.Angles(0, 0, math.rad(90))
	-- danger: the ring turns red in the last seconds before the check
	local hot = left < 3 and self.round.state == "ACTIVE"
	local col = if hot then SAFE:Lerp(DANGER, 0.5 + 0.5 * math.sin(os.clock() * 14)) else SAFE
	for _, p in self.ring.parts do p.Color = col end

	-- the announced next zone
	local nz = self.zones[self.phase + 1]
	if nz and self.phase >= 1 and t < Shared.PHASE then
		placeRing(self.nextRing, nz.c, nz.r, 16 * S, 0.14)
		local pulse = if t < Shared.WARN then 0.5 + 0.5 * math.sin(os.clock() * 6) else 1
		for _, p in self.nextRing.parts do p.Transparency = 0.5 * (1 - pulse) end
	else
		for _, p in self.nextRing.parts do p.Transparency = 1 end
	end

	-- am I outside?
	self.outside = false
	local me = self.round.me and self.round.visuals[self.round.me.id]
	if me and me.pos and not self.round.meHidden then
		self.outside = Shared.Outside(me.pos, c, r)
	end
end

function View.Destroy(self: any)
	if self.grade then self.grade:Destroy() end
	self.env:Destroy()
end

return View
