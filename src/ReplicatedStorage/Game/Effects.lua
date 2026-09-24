--!strict
-- Effects.lua: one-shot visual effects (hit sparks, goal explosion, demolition). Never affects physics.
-- Goal(pos, color, slowmo, goalId?) plays the scorer's goal explosion (a cosmetic, docs/cosmetics.md); no id or an
-- unknown one plays the classic explosion.
local TweenService = game:GetService("TweenService")
local GS = require(script.Parent.GraphicsSettings)
local Sounds = require(script.Parent.Sounds)
local CosmeticCatalog = require(script.Parent.Parent:WaitForChild("Economy"):WaitForChild("CosmeticCatalog"))

local Effects = {}
local folder: Folder? = nil

local function root(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "Effects"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function anchorPart(pos: Vector3, size: number): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(pos)
	p.Parent = root()
	return p
end

local function burst(parent: Instance, color: ColorSequence, count: number, speed: NumberRange, life: NumberRange, size: NumberSequence, light: number)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Color = color
	e.Speed = speed
	e.Lifetime = life
	e.Size = size
	e.SpreadAngle = Vector2.new(180, 180)
	e.LightEmission = light
	e.Drag = 3
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.3), NumberSequenceKeypoint.new(1, 1) })
	e.Parent = parent
	local n = math.floor(count * GS.ParticleMult() + 0.5)
	if n > 0 then e:Emit(n) end
	return e
end

-- strength 0..1
function Effects.Hit(pos: Vector3, strength: number)
	pcall(Sounds.Hit, pos, strength)
	local p = anchorPart(pos, 0.2)
	local s = math.clamp(strength, 0, 1)
	burst(p, ColorSequence.new(Color3.fromRGB(255, 250, 220), Color3.fromRGB(255, 190, 90)), math.floor(8 + 30 * s),
		NumberRange.new(10 + 30 * s, 25 + 60 * s), NumberRange.new(0.12, 0.3), NumberSequence.new(0.35 + 0.4 * s, 0), 1)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 230, 180)
	light.Range = 10 + 16 * s
	light.Brightness = 3 * s
	light.Parent = p
	TweenService:Create(light, TweenInfo.new(0.25), { Brightness = 0 }):Play()
	task.delay(0.6, function() p:Destroy() end)
end

-- ---------------------------------------------------------------- goal explosion styles (cosmetics)
local function neonPart(shape: Enum.PartType, color: Color3, size: Vector3, cf: CFrame, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = root()
	return p
end

local function flash(parent: Instance, color: Color3, range: number, brightness: number, t: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = parent
	TweenService:Create(light, TweenInfo.new(t), { Brightness = 0 }):Play()
end

-- horizontal ring (flat cylinder) that grows from r0 to r1 studs and fades
local function ring(pos: Vector3, color: Color3, r0: number, r1: number, t: number, tilt: CFrame?): Part
	local r = neonPart(Enum.PartType.Cylinder, color, Vector3.new(0.3, r0, r0), CFrame.new(pos) * (tilt or CFrame.identity) * CFrame.Angles(0, 0, math.rad(90)))
	r.Transparency = 0.15
	TweenService:Create(r, TweenInfo.new(t, Enum.EasingStyle.Quart), { Size = Vector3.new(0.3, r1, r1), Transparency = 1 }):Play()
	task.delay(t + 0.1, function() r:Destroy() end)
	return r
end

local function emitter(parent: Instance, props: { [string]: any }, count: number): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	for k, v in props do (e :: any)[k] = v end
	e.Parent = parent
	local n = math.floor(count * GS.ParticleMult() + 0.5)
	if n > 0 then e:Emit(n) end
	return e
end

local GOAL_STYLES: { [string]: (Vector3, Color3, boolean, { [string]: any }) -> () } = {}

GOAL_STYLES.shockwave = function(pos, color, slowmo)
	local k = if slowmo then 1.8 else 1
	local ground = Vector3.new(pos.X, math.max(pos.Y - 3, 0.5), pos.Z)
	ring(ground, color, 4, 110, 0.9 * k)
	task.delay(0.15 * k, function() ring(ground, Color3.new(1, 1, 1), 2, 80, 0.8 * k) end)
	local p = anchorPart(pos, 1)
	burst(p, ColorSequence.new(Color3.new(1, 1, 1), color), 90, NumberRange.new(40, 120), NumberRange.new(0.3, 0.7), NumberSequence.new(1.5, 0), 1)
	flash(p, color, 60, 6, 1)
	task.delay(2.5, function() p:Destroy() end)
end

GOAL_STYLES.confetti = function(pos, color, slowmo, params)
	local p = anchorPart(pos, 1)
	for _, c in params.colors or { color } do
		emitter(p, {
			Color = ColorSequence.new(c), Speed = NumberRange.new(30, 80), Lifetime = NumberRange.new(2, 3.2),
			SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, -35, 0), Drag = 1.5,
			Size = NumberSequence.new(0.7), Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-360, 360),
			LightEmission = 0.3, TimeScale = if slowmo then 0.5 else 1,
		}, 45)
	end
	flash(p, color, 50, 5, 1)
	task.delay(4, function() p:Destroy() end)
end

GOAL_STYLES.frost = function(pos, color, slowmo, params)
	local ice: Color3 = params.color or Color3.fromRGB(170, 225, 255)
	local shell = neonPart(Enum.PartType.Ball, ice, Vector3.new(4, 4, 4), CFrame.new(pos), Enum.Material.Glass)
	shell.Transparency = 0.3
	TweenService:Create(shell, TweenInfo.new(if slowmo then 1.6 else 0.8, Enum.EasingStyle.Quart), { Size = Vector3.new(70, 70, 70), Transparency = 1 }):Play()
	local p = anchorPart(pos, 1)
	burst(p, ColorSequence.new(Color3.new(1, 1, 1), ice), 140, NumberRange.new(20, 70), NumberRange.new(0.6, 1.2), NumberSequence.new(1.2, 0.2), 0.8)
	emitter(p, { -- slow snow
		Color = ColorSequence.new(Color3.new(1, 1, 1)), Speed = NumberRange.new(4, 12), Lifetime = NumberRange.new(2.5, 3.5),
		SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, -4, 0), Size = NumberSequence.new(0.35),
		LightEmission = 0.6,
	}, 80)
	flash(p, ice, 60, 6, 1.4)
	task.delay(4, function() p:Destroy(); shell:Destroy() end)
end

GOAL_STYLES.fireworks = function(pos, color, slowmo, params)
	local colors = params.colors or { color }
	local k = if slowmo then 1.6 else 1
	for i = 1, 5 do
		local c: Color3 = colors[(i - 1) % #colors + 1]
		task.delay((i - 1) * 0.12 * k, function()
			local rocket = neonPart(Enum.PartType.Ball, c, Vector3.new(0.8, 0.8, 0.8), CFrame.new(pos))
			local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(0, 0.3, 0); a0.Parent = rocket
			local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0, -0.3, 0); a1.Parent = rocket
			local tr = Instance.new("Trail")
			tr.Attachment0, tr.Attachment1 = a0, a1
			tr.Color = ColorSequence.new(Color3.new(1, 1, 1), c)
			tr.Lifetime = 0.35
			tr.LightEmission = 1
			tr.FaceCamera = true
			tr.Parent = rocket
			local ang = (i / 5) * math.pi * 2
			local top = pos + Vector3.new(math.cos(ang) * 14, 30 + i * 3, math.sin(ang) * 14)
			TweenService:Create(rocket, TweenInfo.new(0.55 * k, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = CFrame.new(top) }):Play()
			task.delay(0.55 * k, function()
				rocket.Transparency = 1
				local p = anchorPart(top, 1)
				burst(p, ColorSequence.new(Color3.new(1, 1, 1), c), 70, NumberRange.new(20, 45), NumberRange.new(0.8, 1.4), NumberSequence.new(0.9, 0), 1)
				flash(p, c, 40, 4, 0.8)
				task.delay(2, function() p:Destroy(); rocket:Destroy() end)
			end)
		end)
	end
	pcall(Sounds.Goal, pos)
end

GOAL_STYLES.supernova = function(pos, color, slowmo)
	local k = if slowmo then 1.8 else 1
	local core = neonPart(Enum.PartType.Ball, Color3.new(1, 1, 1), Vector3.new(3, 3, 3), CFrame.new(pos))
	TweenService:Create(core, TweenInfo.new(0.5 * k, Enum.EasingStyle.Quart), { Size = Vector3.new(60, 60, 60), Color = color, Transparency = 1 }):Play()
	ring(pos, color, 6, 120, 1.1 * k, CFrame.Angles(math.rad(35), 0, 0))
	ring(pos, Color3.new(1, 1, 1), 6, 100, 1.0 * k, CFrame.Angles(math.rad(-35), math.rad(60), 0))
	local p = anchorPart(pos, 1)
	burst(p, ColorSequence.new(Color3.new(1, 1, 1), color), 200, NumberRange.new(40, 130), NumberRange.new(0.5, 1.2), NumberSequence.new(2.5, 0.3), 1)
	flash(p, Color3.new(1, 1, 1), 80, 10, 1.4)
	task.delay(3, function() p:Destroy(); core:Destroy() end)
end

GOAL_STYLES.blackhole = function(pos, color, slowmo, params)
	local rim: Color3 = params.color or color
	local k = if slowmo then 1.6 else 1
	local hole = neonPart(Enum.PartType.Ball, Color3.new(0, 0, 0), Vector3.new(2, 2, 2), CFrame.new(pos), Enum.Material.SmoothPlastic)
	TweenService:Create(hole, TweenInfo.new(0.5 * k, Enum.EasingStyle.Back), { Size = Vector3.new(22, 22, 22) }):Play()
	-- particles pulled in from a sphere around it
	local shellPart = anchorPart(pos, 50)
	shellPart.Shape = Enum.PartType.Ball
	emitter(shellPart, {
		Shape = Enum.ParticleEmitterShape.Sphere, ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward, Speed = NumberRange.new(30, 45), Lifetime = NumberRange.new(0.6, 0.8),
		Color = ColorSequence.new(rim, Color3.new(0, 0, 0)), Size = NumberSequence.new(0.8, 0.1), LightEmission = 1,
	}, 160)
	task.delay(0.9 * k, function()
		TweenService:Create(hole, TweenInfo.new(0.25 * k, Enum.EasingStyle.Quart, Enum.EasingDirection.In), { Size = Vector3.new(0.1, 0.1, 0.1) }):Play()
		task.delay(0.25 * k, function()
			local p = anchorPart(pos, 1)
			burst(p, ColorSequence.new(Color3.new(1, 1, 1), rim), 160, NumberRange.new(40, 120), NumberRange.new(0.4, 0.9), NumberSequence.new(1.8, 0), 1)
			flash(p, rim, 70, 9, 1)
			ring(pos, rim, 4, 90, 0.8)
			task.delay(2, function() p:Destroy() end)
		end)
	end)
	task.delay(3.5, function() hole:Destroy(); shellPart:Destroy() end)
end

GOAL_STYLES.lightning = function(pos, color, slowmo, params)
	local bolt: Color3 = params.color or Color3.fromRGB(200, 230, 255)
	local rng = Random.new()
	local parts = {}
	for _ = 1, 6 do
		local from = pos + Vector3.new(rng:NextNumber(-25, 25), 70, rng:NextNumber(-25, 25))
		local prev = from
		for i = 1, 6 do
			local t = i / 6
			local nextP = from:Lerp(pos, t) + (if i < 6 then Vector3.new(rng:NextNumber(-5, 5), 0, rng:NextNumber(-5, 5)) else Vector3.zero)
			local mid = (prev + nextP) / 2
			local len = (nextP - prev).Magnitude
			local seg = neonPart(Enum.PartType.Block, bolt, Vector3.new(0.4, 0.4, len), CFrame.lookAt(mid, nextP))
			table.insert(parts, seg)
			prev = nextP
		end
	end
	local p = anchorPart(pos, 1)
	flash(p, Color3.new(1, 1, 1), 90, 12, 0.9)
	burst(p, ColorSequence.new(Color3.new(1, 1, 1), bolt), 120, NumberRange.new(30, 90), NumberRange.new(0.3, 0.7), NumberSequence.new(1.2, 0), 1)
	for _, seg in parts do
		TweenService:Create(seg, TweenInfo.new(if slowmo then 1.2 else 0.6), { Transparency = 1 }):Play()
	end
	task.delay(2.5, function()
		p:Destroy()
		for _, seg in parts do seg:Destroy() end
	end)
end

function Effects.Goal(pos: Vector3, color: Color3, slowmo: boolean?, goalId: string?)
	local it = CosmeticCatalog.Get(goalId)
	local style = if it and it.slot == "goal" then it.params.style else "classic"
	if style ~= "classic" and GOAL_STYLES[style] then
		if style ~= "fireworks" then pcall(Sounds.Goal, pos) end
		local fn = GOAL_STYLES[style]
		local ok, err = pcall(function(): any
			fn(pos, color, slowmo == true, (it :: any).params)
			return nil
		end)
		if ok then return end
		warn("[Effects] goal style " .. tostring(style) .. ":", err)
	end
	pcall(Sounds.Goal, pos)
	local p = anchorPart(pos, 1)
	local e1 = burst(p, ColorSequence.new(Color3.new(1, 1, 1), color), 220, NumberRange.new(30, 110), NumberRange.new(0.6, 1.4),
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 0.5) }), 1)
	local e2 = burst(p, ColorSequence.new(color), 60, NumberRange.new(5, 25), NumberRange.new(1.2, 2.4),
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 12) }), 0.4)
	if slowmo then
		-- matches the 0.25x goal slow motion, then catches up to real time
		for _, em in { e1, e2 } do
			em.TimeScale = 0.25
			task.delay(0.8, function()
				if em.Parent then TweenService:Create(em, TweenInfo.new(0.6), { TimeScale = 1 }):Play() end
			end)
		end
	end
	-- expanding shock sphere
	local shell = Instance.new("Part")
	shell.Shape = Enum.PartType.Ball
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CastShadow = false
	shell.Material = Enum.Material.Neon
	shell.Color = color
	shell.Transparency = 0.2
	shell.Size = Vector3.new(4, 4, 4)
	shell.CFrame = CFrame.new(pos)
	shell.Parent = root()
	TweenService:Create(shell, TweenInfo.new(if slowmo then 1.6 else 0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = Vector3.new(90, 90, 90), Transparency = 1 }):Play()
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 60
	light.Brightness = 8
	light.Parent = p
	TweenService:Create(light, TweenInfo.new(1.2), { Brightness = 0 }):Play()
	task.delay(if slowmo then 4 else 2.6, function()
		p:Destroy()
		shell:Destroy()
	end)
end

-- Boost pickup: sparks burst up from the pad, a flat shock ring on the ground, and (big pads) the orb flies into
-- the car and pops. getCarPos returns the car's current render position so the orb homes on a moving car.
local BOOST_HOT = Color3.fromRGB(255, 200, 70)
local BOOST_CORE = Color3.fromRGB(255, 140, 30)
function Effects.BoostPickup(padPos: Vector3, big: boolean, getCarPos: () -> Vector3)
	pcall(Sounds.Pickup, padPos, big)
	local p = anchorPart(padPos + Vector3.new(0, 0.4, 0), 0.5)
	local up = Instance.new("ParticleEmitter")
	up.Rate = 0
	up.Color = ColorSequence.new(Color3.fromRGB(255, 245, 200), BOOST_CORE)
	up.LightEmission = 1
	up.Speed = if big then NumberRange.new(14, 34) else NumberRange.new(8, 20)
	up.Lifetime = NumberRange.new(0.25, 0.55)
	up.Size = NumberSequence.new(if big then 0.55 else 0.35, 0)
	up.SpreadAngle = Vector2.new(35, 35)
	up.EmissionDirection = Enum.NormalId.Top
	up.Acceleration = Vector3.new(0, -30, 0)
	up.Drag = 2
	up.Parent = p
	local n = math.floor((if big then 40 else 16) * GS.ParticleMult() + 0.5)
	if n > 0 then up:Emit(n) end
	-- shock ring on the ground
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = BOOST_HOT
	ring.Transparency = 0.25
	local r0 = if big then 4 else 2.5
	ring.Size = Vector3.new(0.08, r0, r0)
	ring.CFrame = CFrame.new(padPos + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = root()
	local r1 = if big then 22 else 11
	TweenService:Create(ring, TweenInfo.new(0.35, Enum.EasingStyle.Quart), { Size = Vector3.new(0.08, r1, r1), Transparency = 1 }):Play()
	local light = Instance.new("PointLight")
	light.Color = BOOST_HOT
	light.Range = if big then 22 else 12
	light.Brightness = if big then 4 else 2
	light.Parent = p
	TweenService:Create(light, TweenInfo.new(0.4), { Brightness = 0 }):Play()
	if big then
		-- the orb flies into the car and pops on it
		local orb = Instance.new("Part")
		orb.Shape = Enum.PartType.Ball
		orb.Anchored = true
		orb.CanCollide = false
		orb.CanQuery = false
		orb.CanTouch = false
		orb.CastShadow = false
		orb.Material = Enum.Material.Neon
		orb.Color = BOOST_HOT
		orb.Size = Vector3.new(2.6, 2.6, 2.6)
		local from = padPos + Vector3.new(0, 3.2, 0)
		orb.CFrame = CFrame.new(from)
		orb.Parent = root()
		local t0 = os.clock()
		local conn: RBXScriptConnection
		conn = game:GetService("RunService").RenderStepped:Connect(function()
			local k = math.clamp((os.clock() - t0) / 0.16, 0, 1)
			local to = getCarPos()
			local e2 = k * k
			orb.CFrame = CFrame.new(from:Lerp(to, e2) + Vector3.new(0, math.sin(k * math.pi) * 1.5, 0))
			local sz = 2.6 * (1 - 0.7 * k)
			orb.Size = Vector3.new(sz, sz, sz)
			if k >= 1 then
				conn:Disconnect()
				orb:Destroy()
				local pop = anchorPart(to, 0.5)
				burst(pop, ColorSequence.new(Color3.fromRGB(255, 250, 220), BOOST_CORE), 28, NumberRange.new(10, 26), NumberRange.new(0.15, 0.35),
					NumberSequence.new(0.5, 0), 1)
				local pl = Instance.new("PointLight")
				pl.Color = BOOST_HOT
				pl.Range = 16
				pl.Brightness = 3
				pl.Parent = pop
				TweenService:Create(pl, TweenInfo.new(0.3), { Brightness = 0 }):Play()
				task.delay(0.6, function() pop:Destroy() end)
			end
		end)
	end
	task.delay(0.8, function()
		p:Destroy()
		ring:Destroy()
	end)
end

function Effects.Demolish(pos: Vector3, color: Color3)
	pcall(Sounds.Demolish, pos)
	local p = anchorPart(pos, 1)
	burst(p, ColorSequence.new(Color3.fromRGB(255, 220, 120), color), 120, NumberRange.new(15, 60), NumberRange.new(0.4, 1),
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 0.3) }), 1)
	burst(p, ColorSequence.new(Color3.fromRGB(60, 60, 64)), 40, NumberRange.new(4, 12), NumberRange.new(1.5, 2.5),
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 8) }), 0)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 180, 90)
	light.Range = 40
	light.Brightness = 6
	light.Parent = p
	TweenService:Create(light, TweenInfo.new(0.8), { Brightness = 0 }):Play()
	task.delay(2.6, function() p:Destroy() end)
end

return Effects
