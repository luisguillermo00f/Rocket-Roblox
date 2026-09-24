--!strict
-- CarVisual.lua: "Striker", an original low-poly car skin. It is built in the car's local frame around the
-- simulation origin (center of mass) and only follows the physics state - wheels sit where the suspension
-- rays put them, steer by the real wheel angle and spin with ground speed. It has no collision.
-- Cosmetics (docs/cosmetics.md): new() takes a skin name ("Octane") or a loadout (slot -> item id); the loadout is
-- drawn by CosmeticApply on the finished car (colours, materials, boost, title) - the shape and fit never change.
local RenderMap = require(script.Parent.RenderMap)
local CosmeticApply = require(script.Parent.CosmeticApply)
local CosmeticCatalog = require(script.Parent.Parent:WaitForChild("Economy"):WaitForChild("CosmeticCatalog"))
local GS = require(script.Parent.GraphicsSettings)
local Sounds = require(script.Parent.Sounds)
local C = require(script.Parent.Parent.Physics.PhysicsConstants)

local S = RenderMap.S
local CarVisual = {}
CarVisual.__index = CarVisual

local TEAM_COLORS = {
	[0] = { body = Color3.fromRGB(34, 104, 214), accent = Color3.fromRGB(120, 190, 255) },
	[1] = { body = Color3.fromRGB(232, 112, 28), accent = Color3.fromRGB(255, 196, 120) },
}
local DARK = Color3.fromRGB(28, 30, 36)
local GLASS = Color3.fromRGB(14, 16, 22)

local function part(parent: Instance, className: string, sizeUU: Vector3, color: Color3, material: Enum.Material?): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Size = sizeUU * S
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Mesh skin: body fitted over the hitbox, wheels placed by the suspension. Front of the source mesh is +Z.
local BODY_SIZE = Vector3.new(5.1, 2.35, 6.5) -- studs (W, H, L): wraps the Octane hitbox like RL's visual cars
local WHEEL_VISUAL_SCALE = 1.25 -- visual tyre radius vs simulated wheel radius (RL renders bigger tyres than the rays)
local FLIP = CFrame.Angles(0, math.pi, 0)

local function buildFromMesh(self: any, tpl: Model, car: any, model: Model, colors: any)
	local hc = car.hitboxOffset * C.BT_TO_UU -- forward/right/up UU
	local body = (tpl:FindFirstChild("Body") :: MeshPart):Clone()
	body.Size = tpl:GetAttribute("BodySize") or BODY_SIZE
	body.CastShadow = true
	body.Reflectance = 0.06 -- a touch of clear-coat sheen
	body.Parent = model
	-- team underglow: soft light under the chassis
	local glow = Instance.new("PointLight")
	glow.Color = colors.accent
	glow.Range = 7
	glow.Brightness = 1.1
	glow.Shadows = false
	local ga = Instance.new("Attachment")
	ga.Position = Vector3.new(0, -body.Size.Y * 0.45, 0)
	ga.Parent = body
	glow.Parent = ga
	self.underglow = glow
	table.insert(self.parts, body)
	local center = RenderMap.LocalOffset(Vector3.new(hc.X, 0, hc.Z)) + Vector3.new(0, 0.02, 0)
	table.insert(self.offsets, CFrame.new(center) * FLIP)
	self.body = body

	-- exhaust anchor (invisible) for the boost flame
	local nozzle = part(model, "Part", Vector3.new(8, 8, 8), Color3.new(0, 0, 0))
	nozzle.Transparency = 1
	nozzle.CastShadow = false
	table.insert(self.parts, nozzle)
	table.insert(self.offsets, CFrame.new(RenderMap.LocalOffset(Vector3.new(hc.X - car.hitboxHalf.X * C.BT_TO_UU - 2, 0, hc.Z + 2))))
	self.nozzle = nozzle

	local map = { [1] = "WheelFR", [2] = "WheelFL", [3] = "WheelRR", [4] = "WheelRL" }
	if tpl:GetAttribute("SwapWheelSides") then
		-- the mesh is drawn rotated 180 deg, so its right-side wheel (rim facing out) belongs on our left
		map = { [1] = "WheelFL", [2] = "WheelFR", [3] = "WheelRL", [4] = "WheelRR" }
	end
	for i, w in car.wheels do
		local src = tpl:FindFirstChild(map[i]) :: MeshPart
		local wp = src:Clone()
		local dia = w.radius * C.BT_TO_UU * 2 * S * WHEEL_VISUAL_SCALE
		local k = dia / src.Size.Y
		wp.Size = src.Size * k
		wp.CastShadow = true
		wp.Parent = model
		self.wheels[i] = { parts = { wp }, w = w, mesh = true }
	end
	-- wide bodies: draw the wheels at the body's edge (visual only; the rays stay where the physics has them)
	self.wheelTrackUU = tpl:GetAttribute("WheelTrackUU")
	if false then
	end
end

-- skins: "Octane" (default) or "Troll"; each has a blue template <Skin> and an orange one <Skin>Orange in CarModels
CarVisual.Skins = { "Octane", "Troll" }

-- Composite skin (multi-part model): template pivot sits at the midpoint of its four wheel centres with LookVector =
-- car forward; the body is anchored so those wheel centres coincide with the sim wheels at rest (visual only).
-- The body is then fitted to the car's real hitbox along its length: centred on it, and shrunk (uniformly) when it is
-- longer than the hitbox + HITBOX_MARGIN, so a hit happens where you see the bumper - not after the nose has already
-- sunk into the ball or another car. Wheel sub-models (WheelFR/FL/RR/RL, pivot at the tyre centre) steer and spin
-- as a group; no wheel models = rigid skin.
local HITBOX_MARGIN = 6 -- uu the body may overhang the hitbox at each end (paint and bumper lips)
local function buildComposite(self: any, tpl: Model, car: any, model: Model)
	local mid = Vector3.zero
	for _, w in car.wheels do
		local c = w.conn * C.BT_TO_UU
		mid += Vector3.new(c.X, c.Y, c.Z - w.restLen * C.BT_TO_UU)
	end
	mid /= #car.wheels
	local pivot = tpl.WorldPivot
	local body = tpl:FindFirstChild("Body")
	-- body length in the pivot frame (forward = -Z)
	local zMin, zMax = math.huge, -math.huge
	for _, p in body:GetDescendants() do
		if p:IsA("BasePart") then
			local cf = pivot:ToObjectSpace(p.CFrame)
			local h = p.Size / 2
			for _, sx in { -1, 1 } do for _, sy in { -1, 1 } do for _, sz in { -1, 1 } do
				local z = (cf * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)).Z
				zMin, zMax = math.min(zMin, z), math.max(zMax, z)
			end end end
		end
	end
	local hc = car.hitboxOffset * C.BT_TO_UU
	local hitLen = car.hitboxHalf.X * C.BT_TO_UU * 2
	local bodyLen = (zMax - zMin) / S
	local k = math.clamp((hitLen + 2 * HITBOX_MARGIN) / bodyLen, 0.8, 1)
	local bodyFwd = -(zMin + zMax) / 2 / S -- body centre, forward uu from the anchor
	local shiftFwd = hc.X - (mid.X + bodyFwd * k)
	local anchor = CFrame.new(RenderMap.LocalOffset(mid + Vector3.new(shiftFwd, 0, 0)))
	local biggest, bigVol = nil, -1
	for _, p in body:GetDescendants() do
		if p:IsA("BasePart") then
			local cp = p:Clone()
			cp.CastShadow = cp.Transparency < 0.5 -- the whole body shades the pitch, not just the wheels
			if k < 1 then
				cp.Size = p.Size * k
				local sm = cp:FindFirstChildOfClass("SpecialMesh")
				if sm then sm.Scale *= k end
			end
			cp.Parent = model
			table.insert(self.parts, cp)
			local o = pivot:ToObjectSpace(p.CFrame)
			table.insert(self.offsets, anchor * CFrame.new(o.Position * k) * o.Rotation)
			local vol = p.Size.X * p.Size.Y * p.Size.Z
			if vol > bigVol then biggest, bigVol = cp, vol end
		end
	end
	self.body = biggest
	-- exhaust anchor (invisible) for the boost flame
	local nozzle = part(model, "Part", Vector3.new(8, 8, 8), Color3.new(0, 0, 0))
	nozzle.Transparency = 1
	nozzle.CastShadow = false
	table.insert(self.parts, nozzle)
	table.insert(self.offsets, CFrame.new(RenderMap.LocalOffset(Vector3.new(hc.X - car.hitboxHalf.X * C.BT_TO_UU - 2, 0, hc.Z + 2))))
	self.nozzle = nozzle
	local map = { [1] = "WheelFR", [2] = "WheelFL", [3] = "WheelRR", [4] = "WheelRL" }
	for i, w in car.wheels do
		local wm = tpl:FindFirstChild(map[i])
		if wm then
			local dia = w.radius * C.BT_TO_UU * 2 * S * WHEEL_VISUAL_SCALE
			local kw = dia / (wm:GetAttribute("Diameter") or dia)
			local wp = wm.WorldPivot
			local parts, offs = {}, {}
			for _, p in wm:GetDescendants() do
				if p:IsA("BasePart") then
					local cp = p:Clone()
					cp.CastShadow = cp.Transparency < 0.5
					cp.Size = p.Size * kw
					cp.Parent = model
					table.insert(parts, cp)
					local o = wp:ToObjectSpace(p.CFrame)
					table.insert(offs, CFrame.new(o.Position * kw) * o.Rotation)
				end
			end
			self.wheels[i] = { parts = parts, offs = offs, w = w, composite = true }
		end
	end
end

local function construct(car: any, parent: Instance, skin: string?): any
	local self = setmetatable({ car = car, parts = {}, offsets = {}, wheels = {} }, CarVisual)
	local model = Instance.new("Model")
	model.Name = "Striker_" .. car.id
	model.Parent = parent
	self.model = model
	local colors = TEAM_COLORS[car.team] or TEAM_COLORS[0]
	local tplFolder = script.Parent:FindFirstChild("CarModels")
	local sk = skin or "Octane"
	local tpl = nil
	if tplFolder then
		tpl = if car.team == 1 then tplFolder:FindFirstChild(sk .. "Orange") else nil
		tpl = tpl or tplFolder:FindFirstChild(sk) or tplFolder:FindFirstChild(if car.team == 1 then "StrikerOrange" else "Striker")
	end
	if tpl and tpl:GetAttribute("Composite") then
		buildComposite(self, tpl, car, model)
		CarVisual._effects(self, colors)
		return self
	end
	if tpl then
		buildFromMesh(self, tpl, car, model, colors)
		CarVisual._effects(self, colors)
		return self
	end

	-- body pieces: (className, size L/W/H in UU, center forward/right/up in UU, color, material)
	local function add(className: string, lwh: Vector3, fru: Vector3, color: Color3, material: Enum.Material?)
		-- Roblox local size is (width, height, length)
		local p = part(model, className, Vector3.new(lwh.Y, lwh.Z, lwh.X), color, material)
		table.insert(self.parts, p)
		table.insert(self.offsets, CFrame.new(RenderMap.LocalOffset(fru)))
		return p
	end

	add("Part", Vector3.new(116, 78, 13), Vector3.new(12, 0, 10), DARK) -- chassis
	add("Part", Vector3.new(104, 84, 12), Vector3.new(8, 0, 21), colors.body):SetAttribute("PaintSlot", "primary") -- body shell
	add("WedgePart", Vector3.new(30, 80, 10), Vector3.new(58, 0, 26), colors.body):SetAttribute("PaintSlot", "primary") -- hood slope
	add("Part", Vector3.new(44, 64, 13), Vector3.new(-4, 0, 33), GLASS, Enum.Material.Glass).Reflectance = 0.15 -- cabin
	add("Part", Vector3.new(30, 58, 3), Vector3.new(-8, 0, 40.5), colors.body):SetAttribute("PaintSlot", "primary") -- roof
	add("Part", Vector3.new(106, 6, 3), Vector3.new(10, 0, 28.5), colors.accent):SetAttribute("PaintSlot", "secondary") -- center stripe
	add("Part", Vector3.new(10, 86, 3), Vector3.new(71, 0, 6), DARK) -- splitter
	add("Part", Vector3.new(9, 84, 3), Vector3.new(-45, 0, 41), DARK):SetAttribute("PaintSlot", "secondary") -- spoiler wing
	add("Part", Vector3.new(4, 4, 8), Vector3.new(-42, 24, 36), DARK) -- spoiler struts
	add("Part", Vector3.new(4, 4, 8), Vector3.new(-42, -24, 36), DARK)
	add("Part", Vector3.new(3, 14, 5), Vector3.new(72, 28, 20), Color3.fromRGB(235, 240, 255), Enum.Material.Neon) -- headlights
	add("Part", Vector3.new(3, 14, 5), Vector3.new(72, -28, 20), Color3.fromRGB(235, 240, 255), Enum.Material.Neon)
	add("Part", Vector3.new(2, 16, 4), Vector3.new(-45, 28, 26), Color3.fromRGB(220, 30, 40), Enum.Material.Neon) -- tail lights
	add("Part", Vector3.new(2, 16, 4), Vector3.new(-45, -28, 26), Color3.fromRGB(220, 30, 40), Enum.Material.Neon)
	for _, w in car.wheels do
		local c = w.conn * C.BT_TO_UU
		add("Part", Vector3.new(30, 7, 9), Vector3.new(c.X, (math.abs(c.Y) + 13) * math.sign(c.Y), 24), colors.body):SetAttribute("PaintSlot", "primary") -- fender arches
	end
	local nozzle = add("Part", Vector3.new(6, 16, 10), Vector3.new(-47, 0, 17), Color3.fromRGB(70, 72, 80), Enum.Material.Metal)
	self.nozzle = nozzle

	CarVisual._effects(self, colors)
	if true then
		-- procedural wheels below
	end
	-- (legacy flame block kept for the procedural car)
	local att = Instance.new("Attachment")
	att.Name = "Exhaust"
	att.Position = Vector3.new(0, 0, 4 * S)
	att.Parent = nozzle
	local flame = Instance.new("ParticleEmitter")
	flame.Name = "BoostFlame"
	flame.EmissionDirection = Enum.NormalId.Back
	flame.Rate = 0
	flame.Lifetime = NumberRange.new(0.12, 0.2)
	flame.Speed = NumberRange.new(14, 20)
	flame.SpreadAngle = Vector2.new(6, 6)
	flame.LightEmission = 1
	flame.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.75), NumberSequenceKeypoint.new(1, 0.1) })
	flame.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	flame.Color = ColorSequence.new(Color3.fromRGB(255, 210, 120), Color3.fromRGB(255, 90, 20))
	flame.Parent = att
	self.flame = flame

	-- wheels
	for i, w in car.wheels do
		local rUU = w.radius * C.BT_TO_UU
		local tire = part(model, "Part", Vector3.new(11, rUU * 2, rUU * 2), Color3.fromRGB(22, 22, 24))
		tire.Shape = Enum.PartType.Cylinder
		local hub = part(model, "Part", Vector3.new(11.6, rUU * 1.1, rUU * 1.1), Color3.fromRGB(150, 155, 165), Enum.Material.Metal)
		hub.Shape = Enum.PartType.Cylinder
		local spoke = part(model, "Part", Vector3.new(11.8, rUU * 1.6, 3), Color3.fromRGB(150, 155, 165), Enum.Material.Metal)
		hub:SetAttribute("PaintSlot", "wheel")
		spoke:SetAttribute("PaintSlot", "wheel")
		self.wheels[i] = { parts = { tire, hub, spoke }, w = w, tire = tire }
		-- supersonic streak on the back wheels
		if not w.front then
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, -rUU * 0.4 * S, 0)
			a0.Parent = tire
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, rUU * 0.4 * S, 0)
			a1.Parent = tire
			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Lifetime = 0.25
			trail.LightEmission = 0.6
			trail.Color = ColorSequence.new(colors.accent)
			trail.Transparency = NumberSequence.new(0.35, 1)
			trail.Enabled = false
			trail.Parent = tire
			self.wheels[i].trail = trail
		end
	end
	return self
end

-- skin: "Octane" / "Troll" (as before) or a loadout { slot = item id } (the player's cosmetics; bad ids -> defaults)
function CarVisual.new(car: any, parent: Instance, skin: any?)
	if type(skin) ~= "table" then
		return construct(car, parent, skin)
	end
	local loadout = CosmeticCatalog.Resolve(skin)
	local self = construct(car, parent, loadout.body.params.template)
	local ok, err = pcall(function(): any
		CosmeticApply.Car(self, loadout, TEAM_COLORS[car.team] or TEAM_COLORS[0])
		return nil
	end)
	if not ok then warn("[CarVisual] cosmetics:", err) end
	return self
end

function CarVisual._effects(self: any, colors: any)
	local nozzle = self.nozzle
	local att = Instance.new("Attachment")
	att.Name = "Exhaust"
	att.Parent = nozzle
	local flame = Instance.new("ParticleEmitter")
	flame.Name = "BoostFlame"
	flame.EmissionDirection = Enum.NormalId.Back
	flame.Rate = 0
	flame.Lifetime = NumberRange.new(0.1, 0.18)
	flame.Speed = NumberRange.new(16, 24)
	flame.SpreadAngle = Vector2.new(5, 5)
	flame.LightEmission = 1
	flame.LockedToPart = false
	flame.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0.1) })
	flame.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	flame.Color = ColorSequence.new(Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 110, 30))
	flame.Parent = att
	self.flame = flame
	-- boost ribbon in team color
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.14, 0)
	a0.Parent = nozzle
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.14, 0)
	a1.Parent = nozzle
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.3
	trail.LightEmission = 0.9
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 150), colors.accent)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new(1, 0.1)
	trail.Enabled = false
	trail.Parent = nozzle
	self.boostTrail = trail
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 160, 70)
	glow.Range = 8
	glow.Brightness = 0
	glow.Parent = nozzle
	self.boostLight = glow
end

-- carCF: Roblox CFrame of the simulation origin. wheelState supplies suspension length, steer and spin.
function CarVisual.Update(self: any, carCF: CFrame, visible: boolean)
	local car = self.car
	local parts, cfs = {}, {}
	if not visible then
		carCF = CFrame.new(0, -500, 0)
	end
	for i, p in self.parts do
		parts[i] = p
		cfs[i] = carCF * self.offsets[i]
	end
	for i, wv in self.wheels do
		-- the car's CURRENT wheel: resets (kickoff, training reset, respawn) rebuild car.wheels, and a wheel kept
		-- from when the visual was made would freeze its spin, steer and suspension
		local w = car.wheels[i] or wv.w
		local c = w.conn * C.BT_TO_UU
		if self.wheelTrackUU and wv.mesh then
			c = Vector3.new(c.X, math.sign(c.Y) * math.max(math.abs(c.Y), self.wheelTrackUU), c.Z)
		end
		local suspUU = w.suspensionLength * C.BT_TO_UU
		local center = carCF * CFrame.new(RenderMap.LocalOffset(Vector3.new(c.X, c.Y, c.Z - suspUU)))
		local steer = CFrame.Angles(0, -w.steerAngle, 0)
		local base
		if wv.composite then
			local b = center * steer * CFrame.Angles(-w.spin, 0, 0)
			for j, p in wv.parts do
				table.insert(parts, p)
				table.insert(cfs, b * wv.offs[j])
			end
			continue
		elseif wv.mesh then
			base = center * steer * CFrame.Angles(-w.spin, 0, 0) * FLIP
		else
			base = center * steer * CFrame.Angles(-w.spin, 0, 0)
		end
		for _, p in wv.parts do
			table.insert(parts, p)
			table.insert(cfs, base)
		end
		if wv.trail then
			wv.trail.Enabled = visible and car.isSupersonic and GS.Get("trails")
		end
	end
	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	if self.nameplate then self.nameplate.Enabled = visible end
	-- engine, boost and wind loops (menu showcase cars are muted with SetAudio(false))
	if self.audioOn ~= false then
		local anchor = self.body or self.parts[1]
		if not self.audio and anchor then self.audio = Sounds.CarRig(anchor) end
		if self.audio then
			local now = os.clock()
			local dt = math.clamp(now - (self.audioT or now), 0, 0.1)
			self.audioT = now
			local vel = car.body and car.body.vel or Vector3.zero
			pcall(Sounds.CarRigUpdate, self.audio, dt, (vel * C.BT_TO_UU).Magnitude, car.isBoosting == true, car.isSupersonic == true,
				car.numWheelsInContact or 4, visible, carCF.Position)
		end
	end
	local boosting = visible and car.isBoosting
	self.flame.Rate = if boosting then 140 * math.max(GS.ParticleMult(), 0.2) else 0
	if self.boostExtra then self.boostExtra.Rate = if boosting then 40 * GS.ParticleMult() else 0 end
	if self.boostTrail then
		self.boostTrail.Enabled = boosting and GS.Get("trails")
		self.boostLight.Brightness = if boosting then 2.5 else 0
	end
end

-- RL-style nameplate: the player's name in their team colour, floating above the car (always on top)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
function CarVisual.SetNameplate(self: any, name: string, color: Color3)
	local anchor = self.body or self.parts[1]
	if self.nameplate then self.nameplate:Destroy() end
	local bb = Instance.new("BillboardGui")
	bb.Name = "Nameplate"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	-- scale part is in studs (shrinks with distance); the small offset keeps far names readable
	bb.Size = UDim2.new(6, 30, 0.9, 7)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0)
	bb.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = OSWALD
	local up = string.upper(name)
	for lo, hi in { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ" } do up = up:gsub(lo, hi) end
	label.Text = up
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.fromRGB(10, 10, 14)
	label.TextStrokeTransparency = 0.25
	label.Parent = bb
	-- equipped title (cosmetic): a smaller second line under the name
	local title = self.title
	if type(title) == "table" and type(title.text) == "string" then
		bb.Size = UDim2.new(6, 30, 1.3, 10)
		label.Size = UDim2.fromScale(1, 0.68)
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Position = UDim2.fromScale(0, 0.68)
		t.Size = UDim2.fromScale(1, 0.32)
		t.FontFace = OSWALD
		t.Text = title.text
		t.TextScaled = true
		t.TextColor3 = title.color or Color3.new(1, 1, 1)
		t.TextStrokeColor3 = Color3.fromRGB(10, 10, 14)
		t.TextStrokeTransparency = if title.glow then 0.6 else 0.35
		t.Parent = bb
	end
	-- lives in PlayerGui (adorned to the car) so it always renders
	local lp = game:GetService("Players").LocalPlayer
	bb.Parent = if lp then lp:WaitForChild("PlayerGui") else self.model
	self.nameplate = bb
end

function CarVisual.SetAudio(self: any, on: boolean)
	self.audioOn = on
	if not on and self.audio then
		Sounds.CarRigDestroy(self.audio)
		self.audio = nil
	end
end

function CarVisual.Destroy(self: any)
	if self.audio then Sounds.CarRigDestroy(self.audio) end
	if self.nameplate then self.nameplate:Destroy() end
	self.model:Destroy()
end

return CarVisual
