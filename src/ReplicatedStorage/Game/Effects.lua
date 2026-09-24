--!strict
-- Effects.lua: one-shot visual effects (hit sparks, goal explosion, demolition). Never affects physics.
local TweenService = game:GetService("TweenService")
local GS = require(script.Parent.GraphicsSettings)
local Sounds = require(script.Parent.Sounds)

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

function Effects.Goal(pos: Vector3, color: Color3, slowmo: boolean?)
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
