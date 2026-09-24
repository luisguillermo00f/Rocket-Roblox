--!strict
-- MapKit.lua: build a minigame's own map ONCE and get both sides from the same description:
--   * physics: the solid pieces -> a CustomArena (World.new{ arena = map:Arena() }), used by the server and by the
--     client's prediction alike, so what you drive on is exactly what you see;
--   * visuals: the same pieces as Parts, plus set dressing that has no collision (props, beams, signs, lights),
--     built on the client by MinigameClient.
-- Units: UU, sim axes (x across, y along, z up); yaw = angle of the piece's forward (+x rotated toward +y).
--
-- Solids:      Box · Floor · Block (rotated box) · Ramp (wedge) · Fillet / QuarterPipe (concave curves) · Barrier
--              (invisible wall / ceiling: keeps cars inside the map)
-- Dressing:    Prop (block / ball / cylinder / wedge) · Cyl (standing cylinder) · Beam (between two points)
--              · Ring (a circle of segments on the floor) · Light · Sign (a board with text)
-- Looks:       { color, material, transparency, reflectance, name, visible, shadow,
--                shape = "wedge" | "corner" | "ball" | "cyl" (horizontal, along the piece's width),
--                upright = true (a standing cylinder: size = diameter, diameter, height),
--                gui = one or a list of surface decorations (see decorate below),
--                glow = { color, range, brightness, spot = face? }, fire = { size, heat, color }, emit = "water"|"sparks"|"smoke"|"embers" }
-- Map-wide:    m.lighting = { ClockTime, Brightness, Ambient, OutdoorAmbient, ExposureCompensation, FogColor, FogEnd,
--                atmosphere = { Density, Offset, Color, Decay, Glare, Haze }, grade = { Brightness, Contrast, Saturation, TintColor },
--                bloom = { Intensity, Size, Threshold } }  -- applied by MinigameClient while the round lasts
local RS = game:GetService("ReplicatedStorage")
local CustomArena = require(RS:WaitForChild("Physics"):WaitForChild("CustomArena"))

local MapKit = {}
MapKit.__index = MapKit

local S = 0.05 -- studs per uu (RenderMap)
local function toRoblox(p: Vector3): Vector3
	return Vector3.new(p.X, p.Z, p.Y) * S
end
local function dirRoblox(d: Vector3): Vector3
	return Vector3.new(d.X, d.Z, d.Y)
end
MapKit.ToRoblox = toRoblox

function MapKit.new(name: string): any
	local self = setmetatable({}, MapKit)
	self.name = name
	self.prims = {}
	self.visuals = {} -- descriptions for BuildVisual
	self.spawns = {}
	self.data = {} -- anything the minigame wants to keep with the map (holes, goals, waypoints...)
	self.lighting = nil
	self.arena = nil
	return self
end

local function add(self: any, prim: any, vis: any?)
	table.insert(self.prims, prim)
	if vis then table.insert(self.visuals, vis) end
	self.arena = nil
	return prim
end

-- ---------------------------------------------------------------- solids
-- axis-aligned solid box (min / max corners, UU)
function MapKit.Box(self: any, minP: Vector3, maxP: Vector3, look: any?): any
	local c, h = (minP + maxP) / 2, (maxP - minP) / 2
	local l = look or {}
	return add(self, { kind = "box", c = c, h = h }, if l.visible == false then nil else { kind = "block", c = c, size = h * 2, yaw = 0, look = l })
end

-- a floor slab whose TOP is at z (default 0)
function MapKit.Floor(self: any, x0: number, y0: number, x1: number, y1: number, z: number?, look: any?, thick: number?): any
	local top = z or 0
	return self:Box(Vector3.new(math.min(x0, x1), math.min(y0, y1), top - (thick or 200)), Vector3.new(math.max(x0, x1), math.max(y0, y1), top), look)
end

-- invisible solid (map bounds, ceilings over open maps)
function MapKit.Barrier(self: any, minP: Vector3, maxP: Vector3): any
	return self:Box(minP, maxP, { visible = false })
end

-- oriented block: centre, full size (length along forward, width, height), yaw
function MapKit.Block(self: any, center: Vector3, size: Vector3, yaw: number, look: any?): any
	if math.abs(yaw) < 1e-6 then
		return self:Box(center - size / 2, center + size / 2, look)
	end
	local f = Vector3.new(math.cos(yaw), math.sin(yaw), 0)
	local r = Vector3.new(-math.sin(yaw), math.cos(yaw), 0)
	local z = Vector3.zAxis
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local planes = {
		{ n = f, off = center:Dot(f) + hx }, { n = -f, off = -center:Dot(f) + hx },
		{ n = r, off = center:Dot(r) + hy }, { n = -r, off = -center:Dot(r) + hy },
		{ n = z, off = center.Z + hz }, { n = -z, off = -center.Z + hz },
	}
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, sx in { -1, 1 } do for _, sy in { -1, 1 } do for _, sz in { -1, 1 } do
		local p = center + f * hx * sx + r * hy * sy + z * hz * sz
		mn, mx = mn:Min(p), mx:Max(p)
	end end end
	local l = look or {}
	return add(self, { kind = "hull", planes = planes, min = mn, max = mx }, if l.visible == false then nil else { kind = "block", c = center, size = size, yaw = yaw, look = l })
end

-- wedge ramp: `base` = centre of its footprint (its z = the ramp's foot), rising from 0 at the back to `size.Z` at the
-- front (front = the yaw direction). size = (length, width, height)
function MapKit.Ramp(self: any, base: Vector3, size: Vector3, yaw: number, look: any?): any
	local f = Vector3.new(math.cos(yaw), math.sin(yaw), 0)
	local r = Vector3.new(-math.sin(yaw), math.cos(yaw), 0)
	local L, W, H = size.X, size.Y, size.Z
	local nRaw = Vector3.zAxis - f * (H / L)
	local nLen = nRaw.Magnitude
	local planes = {
		{ n = -Vector3.zAxis, off = -base.Z }, -- bottom
		{ n = f, off = base:Dot(f) + L / 2 }, -- high end face
		{ n = r, off = base:Dot(r) + W / 2 }, { n = -r, off = -base:Dot(r) + W / 2 }, -- sides
		{ n = nRaw / nLen, off = (base:Dot(nRaw) + H / 2) / nLen }, -- the slope
	}
	local mn, mx = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, su in { -1, 1 } do for _, sv in { -1, 1 } do for _, sz in { 0, 1 } do
		local p = base + f * (L / 2) * su + r * (W / 2) * sv + Vector3.zAxis * H * sz
		mn, mx = mn:Min(p), mx:Max(p)
	end end end
	local l = look or {}
	return add(self, { kind = "hull", planes = planes, min = mn, max = mx }, if l.visible == false then nil else { kind = "ramp", base = base, size = size, yaw = yaw, look = l })
end

-- concave curve joining two solids whose free-space normals are n1 and n2 (both perpendicular to `axis`).
-- c0 = a point on the curve's axis; [t0, t1] its extent along the axis; r the radius.
function MapKit.Fillet(self: any, c0: Vector3, axis: Vector3, t0: number, t1: number, n1: Vector3, n2: Vector3, r: number, look: any?): any
	local u1, u2 = -n1.Unit, -n2.Unit
	local prim = { kind = "fillet", c = c0, a = axis.Unit, t0 = t0, t1 = t1, u1 = u1, u2 = u2, g = u1:Dot(u2), r = r }
	local l = look or {}
	return add(self, prim, if l.visible == false then nil else { kind = "fillet", prim = prim, look = l })
end

-- a quarter pipe along the floor line p0 -> p1 (at floor height), curving up into a wall whose free-space normal is
-- `wallNormal` (horizontal)
function MapKit.QuarterPipe(self: any, p0: Vector3, p1: Vector3, wallNormal: Vector3, r: number, look: any?): any
	local axis = p1 - p0
	local len = axis.Magnitude
	local n = Vector3.new(wallNormal.X, wallNormal.Y, 0).Unit
	local c0 = p0 + n * r + Vector3.zAxis * r
	return self:Fillet(c0, axis / len, 0, len, Vector3.zAxis, n, r, look)
end

-- the same curve where a wall meets a CEILING at height p0.Z
function MapKit.CeilingPipe(self: any, p0: Vector3, p1: Vector3, wallNormal: Vector3, r: number, look: any?): any
	local axis = p1 - p0
	local len = axis.Magnitude
	local n = Vector3.new(wallNormal.X, wallNormal.Y, 0).Unit
	local c0 = p0 + n * r - Vector3.zAxis * r
	return self:Fillet(c0, axis / len, 0, len, -Vector3.zAxis, n, r, look)
end

-- a rounded vertical corner between two walls (free-space normals n1, n2), from z0 to z1. `corner` = where the two
-- wall faces meet (at any height)
function MapKit.CornerPipe(self: any, corner: Vector3, n1: Vector3, n2: Vector3, z0: number, z1: number, r: number, look: any?): any
	local c0 = Vector3.new(corner.X, corner.Y, 0) + (n1.Unit + n2.Unit) * r
	return self:Fillet(Vector3.new(c0.X, c0.Y, 0), Vector3.zAxis, z0, z1, n1, n2, r, look)
end

-- ---------------------------------------------------------------- dressing (visual only)
-- a Part description in sim space. size = (length along forward, width, height)
function MapKit.Prop(self: any, center: Vector3, size: Vector3, yaw: number, look: any?, shape: Enum.PartType?)
	table.insert(self.visuals, { kind = "block", c = center, size = size, yaw = yaw, look = look or {}, shape = shape, prop = true })
end

-- a standing cylinder: base centre (its z = bottom), radius, height
function MapKit.Cyl(self: any, base: Vector3, radius: number, height: number, look: any?)
	local l = table.clone(look or {})
	l.upright = true
	self:Prop(base + Vector3.new(0, 0, height / 2), Vector3.new(radius * 2, radius * 2, height), 0, l, Enum.PartType.Cylinder)
end

-- a bar between two points (any direction). thick = width (and depth unless depth given). round = cylinder
function MapKit.Beam(self: any, p0: Vector3, p1: Vector3, thick: number, look: any?, round: boolean?, depth: number?)
	table.insert(self.visuals, { kind = "beam", p0 = p0, p1 = p1, t = thick, d = depth or thick, look = look or {}, round = round })
end

-- a flat ring on a surface (floor markings): centre, radius, line width, segments
function MapKit.Ring(self: any, center: Vector3, radius: number, width: number, segs: number, look: any?, arc0: number?, arc1: number?)
	local a0, a1 = arc0 or 0, arc1 or math.pi * 2
	local step = (a1 - a0) / segs
	local chord = 2 * radius * math.sin(step / 2) * 1.04
	for i = 0, segs - 1 do
		local a = a0 + (i + 0.5) * step
		local p = center + Vector3.new(math.cos(a), math.sin(a), 0) * radius
		self:Prop(p, Vector3.new(width, chord, 4), a, look)
	end
end

-- a glowing light fixture (decoration)
function MapKit.Light(self: any, center: Vector3, color: Color3, range: number?, brightness: number?, spotDir: Vector3?, angle: number?)
	table.insert(self.visuals, { kind = "light", c = center, color = color, range = range or 40, brightness = brightness or 2, spot = spotDir, angle = angle })
end

-- a board with text on its front face (the yaw direction). size = (thickness, width, height)
function MapKit.Sign(self: any, center: Vector3, size: Vector3, yaw: number, text: string, textColor: Color3?, look: any?)
	local l = table.clone(look or {})
	local gui = { kind = "text", text = text, color = textColor or Color3.new(1, 1, 1), face = "Front", font = l.font, glow = l.glowText }
	if l.gui then
		local list = if l.gui.kind then { l.gui } else table.clone(l.gui)
		table.insert(list, gui)
		l.gui = list
	else
		l.gui = gui
	end
	self:Prop(center, size, yaw, l)
end

function MapKit.Spawn(self: any, pos: Vector3, yaw: number)
	table.insert(self.spawns, { pos = pos, yaw = yaw })
end

-- the physics side (cached: the same arena object serves every world built from this map)
function MapKit.Arena(self: any): any
	if not self.arena then
		self.arena = CustomArena.new(self.prims)
	end
	return self.arena
end

-- ---------------------------------------------------------------- visuals (client)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local FACES = { Front = Enum.NormalId.Front, Back = Enum.NormalId.Back, Top = Enum.NormalId.Top, Bottom = Enum.NormalId.Bottom, Left = Enum.NormalId.Left, Right = Enum.NormalId.Right }

-- a deterministic pseudo-random stream (the same map looks the same on every client)
local function prng(seed: number)
	local s = seed % 2147483647
	if s <= 0 then s += 2147483646 end
	return function(): number
		s = (s * 16807) % 2147483647
		return (s - 1) / 2147483646
	end
end

local function surface(p: BasePart, face: string?, ppsHint: number?): SurfaceGui
	local sg = Instance.new("SurfaceGui")
	sg.Face = FACES[face or "Front"] or Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = ppsHint or 12
	sg.LightInfluence = 0.35
	sg.ResetOnSpawn = false
	sg.Parent = p
	return sg
end

-- surface decorations: text · windows (a lit / dark grid) · gradient · stripes · panel (a framed inset)
local function decorate(p: BasePart, g: any)
	local faces = if type(g.face) == "table" then g.face else { g.face or "Front" }
	for _, face in faces do
		local sg = surface(p, face, g.pps)
		if g.kind == "text" then
			sg.LightInfluence = if g.glow == false then 0.6 else 0
			sg.Brightness = if g.glow == false then 1 else 1.6
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Size = UDim2.fromScale(1, 1)
			l.FontFace = g.font or OSWALD
			l.TextScaled = true
			l.Text = g.text
			l.TextColor3 = g.color or Color3.new(1, 1, 1)
			l.TextStrokeTransparency = 0.6
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft, pad.PaddingRight = UDim.new(0.06, 0), UDim.new(0.06, 0)
			pad.PaddingTop, pad.PaddingBottom = UDim.new(0.12, 0), UDim.new(0.12, 0)
			pad.Parent = l
			l.Parent = sg
		elseif g.kind == "windows" then
			-- a façade: a grid of windows, some lit (warm / cool), some dark; ground floor can be a shop front
			sg.LightInfluence = 0.15
			sg.Brightness = 1.3
			sg.PixelsPerStud = 4
			local rnd = prng(g.seed or 1)
			local cols, rows = g.cols or 6, g.rows or 10
			local holder = Instance.new("Frame")
			holder.BackgroundTransparency = 1
			holder.Size = UDim2.fromScale(1, 1)
			holder.Parent = sg
			local lit = g.lit or { Color3.fromRGB(255, 214, 150), Color3.fromRGB(190, 225, 255), Color3.fromRGB(255, 240, 210) }
			local dark = g.dark or Color3.fromRGB(20, 24, 36)
			local density = g.density or 0.45
			local mx, my = 0.08, 0.06 -- margins
			local cw, ch = (1 - 2 * mx) / cols, (1 - 2 * my - (g.shop and 0.12 or 0)) / rows
			for r = 0, rows - 1 do
				for c = 0, cols - 1 do
					local f = Instance.new("Frame")
					f.BorderSizePixel = 0
					f.Position = UDim2.fromScale(mx + c * cw + cw * 0.14, my + r * ch + ch * 0.18)
					f.Size = UDim2.fromScale(cw * 0.72, ch * 0.62)
					local on = rnd() < density
					f.BackgroundColor3 = if on then lit[1 + math.floor(rnd() * #lit)] else dark
					f.BackgroundTransparency = if on then 0.05 else 0.25
					f.Parent = holder
				end
			end
			if g.shop then
				local shop = Instance.new("Frame")
				shop.BorderSizePixel = 0
				shop.Position = UDim2.fromScale(mx, 1 - my - 0.1)
				shop.Size = UDim2.fromScale(1 - 2 * mx, 0.1)
				shop.BackgroundColor3 = g.shop
				shop.BackgroundTransparency = 0.1
				shop.Parent = holder
				local grad = Instance.new("UIGradient")
				grad.Rotation = 90
				grad.Transparency = NumberSequence.new(0, 0.5)
				grad.Parent = shop
			end
		elseif g.kind == "gradient" then
			sg.LightInfluence = g.lightInfluence or 0.2
			sg.Brightness = g.brightness or 1.2
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.Size = UDim2.fromScale(1, 1)
			f.BackgroundColor3 = Color3.new(1, 1, 1)
			f.Parent = sg
			local grad = Instance.new("UIGradient")
			grad.Color = ColorSequence.new(g.a or Color3.new(1, 1, 1), g.b or Color3.new(0, 0, 0))
			grad.Transparency = NumberSequence.new(g.ta or 0, g.tb or 0)
			grad.Rotation = g.rot or 0
			grad.Parent = f
		elseif g.kind == "stripes" then
			-- hazard / crosswalk stripes across the face
			sg.LightInfluence = g.lightInfluence or 0.8
			local n = g.count or 8
			for i = 0, n - 1 do
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.BackgroundColor3 = if i % 2 == 0 then (g.a or Color3.fromRGB(255, 200, 30)) else (g.b or Color3.fromRGB(20, 20, 24))
				f.BackgroundTransparency = if i % 2 == 0 then (g.ta or 0) else (g.tb or 0)
				if g.vertical then
					f.Position = UDim2.fromScale(i / n, 0)
					f.Size = UDim2.fromScale(1 / n + 0.001, 1)
				else
					f.Position = UDim2.fromScale(0, i / n)
					f.Size = UDim2.fromScale(1, 1 / n + 0.001)
				end
				f.Parent = sg
			end
			if g.rot then
				for _, f in sg:GetChildren() do
					if f:IsA("Frame") then f.Rotation = g.rot end
				end
			end
		elseif g.kind == "panel" then
			-- a framed inset panel (walls): border colour + inner colour + an optional accent line
			sg.LightInfluence = g.lightInfluence or 0.9
			local outer = Instance.new("Frame")
			outer.BorderSizePixel = 0
			outer.Size = UDim2.fromScale(1, 1)
			outer.BackgroundColor3 = g.border or Color3.fromRGB(40, 44, 56)
			outer.Parent = sg
			local inner = Instance.new("Frame")
			inner.BorderSizePixel = 0
			inner.AnchorPoint = Vector2.new(0.5, 0.5)
			inner.Position = UDim2.fromScale(0.5, 0.5)
			inner.Size = UDim2.fromScale(g.inset or 0.9, g.insetY or g.inset or 0.86)
			inner.BackgroundColor3 = g.fill or Color3.fromRGB(60, 66, 82)
			inner.Parent = outer
			if g.accent then
				local a = Instance.new("Frame")
				a.BorderSizePixel = 0
				a.Position = UDim2.fromScale(0, g.accentY or 0.78)
				a.Size = UDim2.fromScale(1, g.accentH or 0.04)
				a.BackgroundColor3 = g.accent
				a.Parent = inner
			end
		end
	end
end

local function applyLook(p: BasePart, look: any)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Color = look.color or Color3.fromRGB(90, 96, 110)
	p.Material = look.material or Enum.Material.SmoothPlastic
	p.Transparency = look.transparency or 0
	p.Reflectance = look.reflectance or 0
	p.CastShadow = look.shadow ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if look.name then p.Name = look.name end
	if look.gui then
		if look.gui.kind then decorate(p, look.gui) else for _, g in look.gui do decorate(p, g) end end
	end
	if look.glow then
		local gl = look.glow
		local l: Light
		if gl.spot then
			local s = Instance.new("SpotLight")
			s.Face = FACES[gl.spot] or Enum.NormalId.Bottom
			s.Angle = gl.angle or 70
			l = s
		else
			l = Instance.new("PointLight")
		end
		l.Color = gl.color or p.Color
		l.Range = gl.range or 16
		l.Brightness = gl.brightness or 2
		l.Shadows = gl.shadows == true
		l.Parent = p
	end
	if look.fire then
		local f = Instance.new("Fire")
		f.Size = look.fire.size or 6
		f.Heat = look.fire.heat or 9
		f.Color = look.fire.color or Color3.fromRGB(255, 140, 40)
		f.SecondaryColor = look.fire.secondary or Color3.fromRGB(255, 60, 20)
		f.Parent = p
	end
	if look.emit then
		local e = Instance.new("ParticleEmitter")
		if look.emit == "water" then
			e.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
			e.LightEmission = 0.3
			e.Size = NumberSequence.new(0.6, 1.4)
			e.Transparency = NumberSequence.new(0.3, 1)
			e.Lifetime = NumberRange.new(1, 1.6)
			e.Rate = 40
			e.Speed = NumberRange.new(10, 16)
			e.SpreadAngle = Vector2.new(12, 12)
			e.Acceleration = Vector3.new(0, -30, 0)
			e.EmissionDirection = Enum.NormalId.Top
		elseif look.emit == "fall" then
			e.Color = ColorSequence.new(Color3.fromRGB(220, 240, 255))
			e.LightEmission = 0.2
			e.Size = NumberSequence.new(1.5, 3)
			e.Transparency = NumberSequence.new(0.2, 1)
			e.Lifetime = NumberRange.new(2, 3)
			e.Rate = 30
			e.Speed = NumberRange.new(4, 8)
			e.Acceleration = Vector3.new(0, -25, 0)
			e.EmissionDirection = Enum.NormalId.Bottom
		elseif look.emit == "embers" then
			e.Color = ColorSequence.new(Color3.fromRGB(255, 180, 80), Color3.fromRGB(255, 80, 20))
			e.LightEmission = 1
			e.Size = NumberSequence.new(0.25, 0)
			e.Lifetime = NumberRange.new(1.5, 3)
			e.Rate = 8
			e.Speed = NumberRange.new(2, 5)
			e.Acceleration = Vector3.new(0, 4, 0)
			e.EmissionDirection = Enum.NormalId.Top
			e.SpreadAngle = Vector2.new(30, 30)
		elseif look.emit == "smoke" then
			e.Color = ColorSequence.new(Color3.fromRGB(80, 80, 90))
			e.Size = NumberSequence.new(2, 6)
			e.Transparency = NumberSequence.new(0.6, 1)
			e.Lifetime = NumberRange.new(3, 5)
			e.Rate = 4
			e.Speed = NumberRange.new(2, 4)
			e.EmissionDirection = Enum.NormalId.Top
		elseif look.emit == "sparkle" then
			e.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
			e.LightEmission = 1
			e.Size = NumberSequence.new(0.3, 0)
			e.Lifetime = NumberRange.new(0.8, 1.4)
			e.Rate = 6
			e.Speed = NumberRange.new(1, 2)
			e.SpreadAngle = Vector2.new(180, 180)
		end
		e.Parent = p
	end
end

function MapKit.BuildVisual(self: any, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "Map_" .. self.name
	local count = 0
	for _, v in self.visuals do
		if v.kind == "block" then
			local look = v.look
			local shape = look.shape or v.shape
			local p: BasePart
			if shape == "wedge" then
				p = Instance.new("WedgePart")
			elseif shape == "corner" then
				p = Instance.new("CornerWedgePart")
			else
				local part = Instance.new("Part")
				if shape == "ball" then
					part.Shape = Enum.PartType.Ball
				elseif shape == "cyl" or shape == Enum.PartType.Cylinder then
					part.Shape = Enum.PartType.Cylinder
				elseif typeof(shape) == "EnumItem" then
					part.Shape = shape
				end
				p = part
			end
			local f = Vector3.new(math.cos(v.yaw), math.sin(v.yaw), 0)
			local pos = toRoblox(v.c)
			if (shape == Enum.PartType.Cylinder or shape == "cyl") and look.upright then
				-- a standing cylinder: Roblox cylinders run along their X, so turn X up. size = (diameter, diameter, height)
				p.Size = Vector3.new(v.size.Z, v.size.Y, v.size.X) * S
				p.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
			elseif shape == "wedge" then
				-- a wedge rising toward the piece's forward
				p.Size = Vector3.new(v.size.Y, v.size.Z, v.size.X) * S
				p.CFrame = CFrame.lookAt(pos, pos - dirRoblox(f))
			else
				-- Roblox size: (width across = y-size, height, length along forward)
				p.Size = Vector3.new(v.size.Y, v.size.Z, v.size.X) * S
				p.CFrame = CFrame.lookAt(pos, pos + dirRoblox(f))
			end
			applyLook(p, look)
			p.Parent = model
			count += 1
		elseif v.kind == "ramp" then
			local p = Instance.new("WedgePart")
			local f = Vector3.new(math.cos(v.yaw), math.sin(v.yaw), 0)
			p.Size = Vector3.new(v.size.Y, v.size.Z, v.size.X) * S
			local c = v.base + Vector3.new(0, 0, v.size.Z / 2)
			local pos = toRoblox(c)
			-- a WedgePart is tallest at its local +Z: point local +Z (= -LookVector) along the ramp's forward
			p.CFrame = CFrame.lookAt(pos, pos - dirRoblox(f))
			applyLook(p, v.look)
			p.Parent = model
			count += 1
		elseif v.kind == "beam" then
			local a, b = toRoblox(v.p0), toRoblox(v.p1)
			local len = (b - a).Magnitude
			if len > 1e-3 then
				local p = Instance.new("Part")
				local mid = (a + b) / 2
				local dir = (b - a) / len
				local up = if math.abs(dir.Y) > 0.95 then Vector3.xAxis else Vector3.yAxis
				local cf = CFrame.lookAt(mid, b, up)
				if v.round then
					p.Shape = Enum.PartType.Cylinder
					p.Size = Vector3.new(len, v.t * S, v.t * S)
					p.CFrame = cf * CFrame.Angles(0, math.pi / 2, 0)
				else
					p.Size = Vector3.new(v.t * S, v.d * S, len)
					p.CFrame = cf
				end
				applyLook(p, v.look)
				p.Parent = model
				count += 1
			end
		elseif v.kind == "fillet" then
			local pr = v.prim
			local total = math.acos(math.clamp(pr.g, -1, 1))
			local segs = math.max(6, math.floor(total / math.rad(6)))
			local perp = (pr.u2 - pr.u1 * pr.g).Unit
			local len = pr.t1 - pr.t0
			local mid = pr.c + pr.a * ((pr.t0 + pr.t1) / 2)
			for k = 0, segs - 1 do
				local th = (k + 0.5) / segs * total
				local dir = pr.u1 * math.cos(th) + perp * math.sin(th)
				local surf = mid + dir * (pr.r + 10)
				local chord = 2 * pr.r * math.sin(total / segs / 2) + 2
				local p = Instance.new("Part")
				-- a thin panel: normal = -dir, long side along the axis
				local n, u = dirRoblox(-dir), dirRoblox(pr.a)
				local w = u:Cross(n)
				p.Size = Vector3.new(len * S, 20 * S, chord * S)
				p.CFrame = CFrame.fromMatrix(toRoblox(surf), u, n, w)
				applyLook(p, v.look)
				p.Parent = model
				count += 1
			end
		elseif v.kind == "light" then
			local p = Instance.new("Part")
			p.Size = Vector3.new(1, 1, 1)
			p.Transparency = 1
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Position = toRoblox(v.c)
			local l: Light
			if v.spot then
				local s = Instance.new("SpotLight")
				s.Face = Enum.NormalId.Front
				s.Angle = v.angle or 60
				p.CFrame = CFrame.lookAt(p.Position, p.Position + dirRoblox(v.spot))
				l = s
			else
				l = Instance.new("PointLight")
			end
			l.Color = v.color
			l.Range = v.range
			l.Brightness = v.brightness
			l.Shadows = false
			l.Parent = p
			p.Parent = model
		end
	end
	model:SetAttribute("Parts", count)
	model.Parent = parent
	return model
end

-- the map's lighting for the round. Returns restore().
function MapKit.ApplyLighting(self: any): () -> ()
	local L = game:GetService("Lighting")
	local cfg = self.lighting
	if not cfg then return function() end end
	local saved: { [string]: any } = {}
	local made: { Instance } = {}
	local touched: { { any } } = {}
	for k, v in cfg do
		if type(v) ~= "table" then
			local ok, old = pcall(function() return (L :: any)[k] end)
			if ok then
				saved[k] = old
				pcall(function() (L :: any)[k] = v end)
			end
		end
	end
	local function setOn(className: string, props: any)
		if not props then return end
		local inst = L:FindFirstChildOfClass(className)
		if not inst then
			inst = Instance.new(className)
			inst.Parent = L
			table.insert(made, inst)
		end
		for k, v in props do
			local ok, old = pcall(function() return (inst :: any)[k] end)
			if ok then
				table.insert(touched, { inst, k, old })
				pcall(function() (inst :: any)[k] = v end)
			end
		end
	end
	setOn("Atmosphere", cfg.atmosphere)
	setOn("BloomEffect", cfg.bloom)
	local grade: ColorCorrectionEffect? = nil
	if cfg.grade then
		grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "MapGrade"
		for k, v in cfg.grade do pcall(function() (grade :: any)[k] = v end) end
		grade.Parent = L
	end
	return function()
		for k, v in saved do pcall(function() (L :: any)[k] = v end) end
		for i = #touched, 1, -1 do
			local t = touched[i]
			pcall(function() t[1][t[2]] = t[3] end)
		end
		for _, m in made do m:Destroy() end
		if grade then grade:Destroy() end
	end
end

-- a custom map takes the screen: hide the Soccar stadium while it is up. Returns restore().
function MapKit.HideStadium(): () -> ()
	local arena = workspace:FindFirstChild("Arena")
	if not arena then return function() end end
	arena.Parent = nil
	return function()
		if arena and not arena.Parent then arena.Parent = workspace end
	end
end

return MapKit
