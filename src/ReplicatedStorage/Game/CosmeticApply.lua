--!strict
-- CosmeticApply.lua: draws a resolved loadout (CosmeticCatalog.Resolve) on a CarVisual that is already built.
-- It only recolours / re-materials existing parts and swaps particle / trail settings: it never moves, resizes,
-- adds or removes body parts, so the visual fit to the hitbox (CarVisual) is exactly what it was. No physics here.
-- Which parts are "paint":
--   * attribute PaintSlot = "primary" / "secondary" / "wheel" (set on the Studio templates, optional; the procedural
--     car sets them itself);
--   * otherwise primary = parts named "Part 1", "Part 2", "Part", "Part 4" (the composite template's body panels,
--     the same convention MinigameClient.paint uses); wheel = non-black parts of a wheel (the tyre is black);
--     secondary = only the underglow light and the trail's second colour.
local CosmeticApply = {}

local TEXTURES = {
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
}
CosmeticApply.TEXTURES = TEXTURES

local PRIMARY_NAMES = { ["Part 1"] = true, ["Part 2"] = true, ["Part"] = true, ["Part 4"] = true }
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-- a finish of the team colour: saturation scaled, then lightened (shade > 0) or darkened (shade < 0)
function CosmeticApply.Shade(c: Color3, shade: number, sat: number): Color3
	local h, s, v = c:ToHSV()
	local base = Color3.fromHSV(h, math.clamp(s * sat, 0, 1), v)
	if shade > 0 then
		return base:Lerp(WHITE, math.clamp(shade, 0, 1))
	elseif shade < 0 then
		return base:Lerp(BLACK, math.clamp(-shade, 0, 1))
	end
	return base
end

local function luminance(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

local function tagged(root: Instance, tag: string): { BasePart }
	local out = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("PaintSlot") == tag then table.insert(out, d) end
	end
	return out
end

local function textured(p: BasePart): boolean
	return p:IsA("MeshPart") and (p :: MeshPart).TextureID ~= ""
end

local function paintPart(p: BasePart, color: Color3?, material: Enum.Material?, reflectance: number?)
	-- a textured mesh keeps its texture (Color would only tint the transparent bits): material / sheen only
	if color and not textured(p) then p.Color = color end
	if material then p.Material = material end
	if reflectance then p.Reflectance = reflectance end
end

local function primaryParts(v: any): { BasePart }
	local list = tagged(v.model, "primary")
	if #list > 0 then return list end
	for _, d in v.model:GetDescendants() do
		if d:IsA("BasePart") and PRIMARY_NAMES[d.Name] and d:GetAttribute("PaintSlot") == nil then table.insert(list, d) end
	end
	if #list == 0 and v.body and v.body:IsA("BasePart") then table.insert(list, v.body) end
	return list
end

local function wheelParts(v: any): { BasePart }
	local list = tagged(v.model, "wheel")
	if #list > 0 then return list end
	for _, wv in v.wheels do
		for _, p in wv.parts or {} do
			if p:IsA("BasePart") and luminance(p.Color) > 0.25 then table.insert(list, p) end
		end
	end
	return list
end

local function seq(k0: number, k1: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, k0), NumberSequenceKeypoint.new(1, k1) })
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)), ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 180, 50)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 245, 80)), ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 230, 110)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(70, 150, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 90, 255)),
})
CosmeticApply.RAINBOW = RAINBOW

local function applyBoost(v: any, p: any, team: any)
	local flame: ParticleEmitter? = v.flame
	local c0: Color3 = if p.team then team.accent else (p.flame and p.flame[1]) or WHITE
	local c1: Color3 = if p.team then team.body else (p.flame and p.flame[2]) or c0
	if flame then
		flame.Color = ColorSequence.new(c0, c1)
		local k = math.clamp(p.flameSize or 1, 0.5, 1.5)
		flame.Size = seq(0.9 * k, 0.1 * k)
		if p.texture and TEXTURES[p.texture] then flame.Texture = TEXTURES[p.texture] end
	end
	local trail: Trail? = v.boostTrail
	if trail then
		if p.rainbow then
			trail.Color = RAINBOW
		else
			local t0 = if p.team then team.accent else (p.trail and p.trail[1]) or c0
			local t1 = if p.team then team.accent else (p.trail and p.trail[2]) or team.accent
			trail.Color = ColorSequence.new(t0, t1)
		end
		local w = math.clamp(p.trailWidth or 1, 0.5, 1.5)
		trail.WidthScale = seq(w, 0.1 * w)
		trail.Lifetime = math.clamp(p.trailLife or 0.3, 0.1, 1)
	end
	local light: PointLight? = v.boostLight
	if light then
		if p.light == false then
			light.Enabled = false
		elseif typeof(p.light) == "Color3" then
			light.Color = p.light
		end
	end
	if v.boostExtra then
		v.boostExtra:Destroy()
		v.boostExtra = nil
	end
	local att = v.nozzle and v.nozzle:FindFirstChild("Exhaust")
	if p.extra and att then
		local e = Instance.new("ParticleEmitter")
		e.Name = "BoostExtra"
		e.EmissionDirection = Enum.NormalId.Back
		e.Rate = 0
		e.Lifetime = NumberRange.new(0.3, 0.6)
		e.Speed = NumberRange.new(6, 14)
		e.SpreadAngle = Vector2.new(25, 25)
		e.LightEmission = 1
		e.Size = seq(0.35, 0)
		e.Color = ColorSequence.new(p.extra.color or WHITE)
		if TEXTURES[p.extra.texture] then e.Texture = TEXTURES[p.extra.texture] end
		e.Parent = att
		v.boostExtra = e -- CarVisual.Update turns it on while boosting
	end
end

-- loadout: CosmeticCatalog.Resolve(...) ; team: { body = Color3, accent = Color3 } (CarVisual's team colours)
function CosmeticApply.Car(v: any, loadout: { [string]: any }, team: { [string]: Color3 })
	-- primary: finish of the team colour each panel already has
	local pr = loadout.primary.params
	for _, p in primaryParts(v) do
		paintPart(p, CosmeticApply.Shade(p.Color, pr.shade or 0, pr.sat or 1), pr.material, pr.reflectance)
	end
	-- secondary: accent parts + underglow
	local sc = loadout.secondary.params
	for _, p in tagged(v.model, "secondary") do
		paintPart(p, sc.color, sc.material, nil)
	end
	if v.underglow then v.underglow.Color = sc.color end
	-- wheels: rims only
	local wp = loadout.wheels.params
	local rimColor: Color3 = if wp.teamAccent then team.accent else wp.color
	for _, p in wheelParts(v) do
		paintPart(p, rimColor, wp.material, nil)
		if wp.glow and not p:FindFirstChild("RimGlow") then
			local l = Instance.new("PointLight")
			l.Name = "RimGlow"
			l.Color = rimColor
			l.Range = 4
			l.Brightness = 1.2
			l.Shadows = false
			l.Parent = p
		end
	end
	if wp.sparkle then
		for _, wv in v.wheels do
			local p = wv.parts and wv.parts[1]
			if p and not (wv.w and wv.w.front) and not p:FindFirstChild("RimSparkle") then
				local e = Instance.new("ParticleEmitter")
				e.Name = "RimSparkle"
				e.Rate = 6
				e.Lifetime = NumberRange.new(0.3, 0.5)
				e.Speed = NumberRange.new(1, 3)
				e.Size = seq(0.2, 0)
				e.LightEmission = 1
				e.Color = ColorSequence.new(rimColor)
				e.Texture = TEXTURES.sparkles
				e.Parent = p
			end
		end
	end
	applyBoost(v, loadout.boost.params, team)
	v.title = loadout.title.params
end

-- avatar frame on a UIStroke (menu card, profile)
function CosmeticApply.Frame(stroke: UIStroke, params: { [string]: any }): () -> ()
	local old = stroke:FindFirstChildOfClass("UIGradient")
	if old then old:Destroy() end
	stroke.Thickness = params.thickness or 1.5
	stroke.Transparency = params.transparency or 0
	stroke.Color = params.color or WHITE
	if not params.gradient then
		return function() end
	end
	stroke.Color = WHITE
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(params.gradient[1], params.gradient[2] or params.gradient[1])
	g.Parent = stroke
	if not params.spin then
		return function() end
	end
	local conn = game:GetService("RunService").RenderStepped:Connect(function(dt: number)
		g.Rotation = (g.Rotation + dt * 90) % 360
	end)
	stroke.Destroying:Connect(function() conn:Disconnect() end)
	return function() conn:Disconnect() end
end

return CosmeticApply
