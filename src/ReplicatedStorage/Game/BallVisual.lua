--!strict
-- BallVisual.lua: RL-style ball - hex/pentagon panels with glowing cyan seams (spin stays readable), a seam light
-- and a trail that grow with speed.
local RenderMap = require(script.Parent.RenderMap)
local GS = require(script.Parent.GraphicsSettings)
local C = require(script.Parent.Parent.Physics.PhysicsConstants)

local S = RenderMap.S
local BallVisual = {}
BallVisual.__index = BallVisual

local SEAM = Color3.fromRGB(90, 200, 255)

-- Old look (plain sphere + 12 panels), used only if the mesh template is missing
local function buildFallback(self: any, model: Model, d: number)
	local ball = Instance.new("Part")
	ball.Name = "Sphere"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(d, d, d)
	ball.Color = Color3.fromRGB(214, 218, 224)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Reflectance = 0.1 -- glossy shell
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Parent = model
	table.insert(self.parts, ball)
	table.insert(self.offsets, CFrame.identity)
	local phi = (1 + math.sqrt(5)) / 2
	for _, v in { { -1, phi, 0 }, { 1, phi, 0 }, { -1, -phi, 0 }, { 1, -phi, 0 }, { 0, -1, phi }, { 0, 1, phi }, { 0, -1, -phi }, { 0, 1, -phi }, { phi, 0, -1 }, { phi, 0, 1 }, { -phi, 0, -1 }, { -phi, 0, 1 } } do
		local n = Vector3.new(v[1], v[2], v[3]).Unit
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(0.2, d * 0.24, d * 0.24)
		p.Color = Color3.fromRGB(58, 64, 76)
		p.Material = Enum.Material.Metal -- hex panels, like RL's ball
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = model
		table.insert(self.parts, p)
		table.insert(self.offsets, CFrame.lookAt(n * (d / 2 - 0.07), n * d) * CFrame.Angles(0, math.rad(90), 0))
	end
	return ball
end

function BallVisual.new(parent: Instance)
	local self = setmetatable({ parts = {}, offsets = {} }, BallVisual)
	local model = Instance.new("Model")
	model.Name = "Ball"
	model.Parent = parent
	self.model = model
	local d = C.BALL_COLLISION_RADIUS_SOCCAR * 2 * S

	-- RL-style ball: hex/pentagon panels with glowing cyan seams (AI-generated mesh, Game.BallModels.Hex)
	local template = script.Parent:FindFirstChild("BallModels") and script.Parent.BallModels:FindFirstChild("Hex")
	local ball: BasePart
	if template then
		local m = template:Clone() :: MeshPart
		m.Size = Vector3.new(d, d, d)
		m.Anchored = true
		m.CanCollide = false
		m.CanQuery = false
		m.CanTouch = false
		m.CastShadow = true
		m.Parent = model
		ball = m
		table.insert(self.parts, m)
		table.insert(self.offsets, CFrame.identity)
	else
		ball = buildFallback(self, model, d)
	end

	-- seam glow: a soft cyan light that brightens with speed
	local glow = Instance.new("PointLight")
	glow.Color = SEAM
	glow.Range = d * 1.6
	glow.Brightness = 0.4
	glow.Shadows = false
	glow.Parent = ball
	self.glow = glow

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, d * 0.16, 0)
	a0.Parent = ball
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -d * 0.16, 0)
	a1.Parent = ball
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.3
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(Color3.fromRGB(220, 245, 255), SEAM)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new(1, 0.2)
	trail.Enabled = false
	trail.Parent = ball
	self.trail = trail
	return self
end

local GOLD = Color3.fromRGB(255, 196, 64)

-- Pinch flare: gold trail + strong glow for `dur` seconds
function BallVisual.Flare(self: any, dur: number)
	self.flareUntil = os.clock() + dur
	self.trail.Color = ColorSequence.new(Color3.fromRGB(255, 250, 220), GOLD)
	self.trail.Lifetime = 0.5
	self.trail.WidthScale = NumberSequence.new(1.6, 0.2)
	self.glow.Color = GOLD
end

function BallVisual.SetSpeed(self: any, speedUU: number)
	if self.flareUntil then
		if os.clock() < self.flareUntil then
			self.trail.Enabled = GS.Get("trails")
			self.glow.Brightness = 4
			self.glow.Range = (C.BALL_COLLISION_RADIUS_SOCCAR * 2 * S) * 3.2
			return
		end
		self.flareUntil = nil
		self.trail.Color = ColorSequence.new(Color3.fromRGB(220, 245, 255), SEAM)
		self.trail.Lifetime = 0.3
		self.trail.WidthScale = NumberSequence.new(1, 0.2)
		self.glow.Color = SEAM
	end
	self.trail.Enabled = speedUU > 1800 and GS.Get("trails")
	local k = math.clamp((speedUU - 800) / 3000, 0, 1)
	self.glow.Brightness = 0.4 + 2.2 * k
	self.glow.Range = (C.BALL_COLLISION_RADIUS_SOCCAR * 2 * S) * (1.6 + 1.2 * k)
end

function BallVisual.Update(self: any, cf: CFrame, visible: boolean)
	if not visible then
		cf = CFrame.new(0, -500, 0)
	end
	local cfs = {}
	for i = 1, #self.parts do
		cfs[i] = cf * self.offsets[i]
	end
	workspace:BulkMoveTo(self.parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

return BallVisual
