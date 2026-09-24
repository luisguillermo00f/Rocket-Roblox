--!strict
-- LuckyBlockSystem.lua: Spawns and manages physical, interactive Lucky Blocks
-- in the Party Mode playground at Y = 500, applying fun, harmless, temporary effects.

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local PartyConfig = require(script.Parent.PartyConfig)

local LuckyBlockSystem = {}
LuckyBlockSystem.__index = LuckyBlockSystem

local CFG = PartyConfig.LUCKY_BLOCKS
local ORIGIN = PartyConfig.ORIGIN

local LUCKY_EFFECTS = {
	{
		id = "confetti",
		label = "¡FIESTA DE CONFETI!",
		color = Color3.fromRGB(255, 60, 180),
		apply = function(carModel: Model)
			local body = carModel:FindFirstChildWhichIsA("BasePart")
			if not body then return end
			local emitter = Instance.new("ParticleEmitter")
			emitter.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 100)),
				ColorSequenceKeypoint.new(0.3, Color3.fromRGB(0, 255, 200)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 230, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 50, 255)),
			})
			emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.0), NumberSequenceKeypoint.new(1, 0.15) })
			emitter.Rate = 50
			emitter.Speed = NumberRange.new(12, 22)
			emitter.SpreadAngle = Vector2.new(180, 180)
			emitter.Lifetime = NumberRange.new(1.0, 1.8)
			emitter.Drag = 3
			emitter.Parent = body
			task.delay(CFG.EFFECT_DURATION, function()
				if emitter and emitter.Parent then
					emitter.Enabled = false
					Debris:AddItem(emitter, 2.0)
				end
			end)
		end,
	},
	{
		id = "low_gravity",
		label = "¡GRAVEDAD LUNAR!",
		color = Color3.fromRGB(100, 200, 255),
		apply = function(carModel: Model)
			local body = carModel:FindFirstChildWhichIsA("BasePart")
			if not body then return end
			local antiGrav = Instance.new("BodyForce")
			antiGrav.Name = "PartyAntiGrav"
			antiGrav.Force = Vector3.new(0, body:GetMass() * workspace.Gravity * 0.65, 0)
			antiGrav.Parent = body
			task.delay(CFG.EFFECT_DURATION, function()
				if antiGrav and antiGrav.Parent then antiGrav:Destroy() end
			end)
		end,
	},
	{
		id = "giant_wheels",
		label = "¡RUEDAS GIGANTES!",
		color = Color3.fromRGB(255, 170, 0),
		apply = function(carModel: Model)
			local origScales = {}
			for _, p in ipairs(carModel:GetDescendants()) do
				if p:IsA("BasePart") and (p.Name:lower():find("wheel") or p.Name:lower():find("tire") or p.Shape == Enum.PartType.Cylinder) then
					origScales[p] = p.Size
					TweenService:Create(p, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Size = p.Size * 2.0 }):Play()
				end
			end
			task.delay(CFG.EFFECT_DURATION, function()
				for partObj, origSize in pairs(origScales) do
					if partObj and partObj.Parent then
						TweenService:Create(partObj, TweenInfo.new(0.35), { Size = origSize }):Play()
					end
				end
			end)
		end,
	},
	{
		id = "boost_burst",
		label = "¡TURBO COHETE!",
		color = Color3.fromRGB(255, 40, 40),
		apply = function(carModel: Model)
			local body = carModel:FindFirstChildWhichIsA("BasePart")
			if body and not body.Anchored then
				body.AssemblyLinearVelocity = body.AssemblyLinearVelocity + body.CFrame.LookVector * 100 + Vector3.new(0, 20, 0)
			end
		end,
	},
	{
		id = "spring_launch",
		label = "¡TRAMPOLÍN BOING!",
		color = Color3.fromRGB(80, 255, 100),
		apply = function(carModel: Model)
			local body = carModel:FindFirstChildWhichIsA("BasePart")
			if body and not body.Anchored then
				body.AssemblyLinearVelocity = Vector3.new(body.AssemblyLinearVelocity.X, 85, body.AssemblyLinearVelocity.Z)
			end
		end,
	},
	{
		id = "rainbow_color",
		label = "¡ARCOÍRIS NEÓN!",
		color = Color3.fromRGB(255, 230, 60),
		apply = function(carModel: Model)
			local parts = {}
			for _, p in ipairs(carModel:GetDescendants()) do
				if p:IsA("BasePart") and p.Shape ~= Enum.PartType.Cylinder then
					table.insert(parts, { part = p, origColor = p.Color })
				end
			end
			local t0 = os.clock()
			local active = true
			task.spawn(function()
				while active and os.clock() - t0 < CFG.EFFECT_DURATION do
					local hue = (os.clock() * 2) % 1
					local col = Color3.fromHSV(hue, 0.85, 1)
					for _, item in ipairs(parts) do
						if item.part and item.part.Parent then
							item.part.Color = col
						end
					end
					task.wait(0.05)
				end
				for _, item in ipairs(parts) do
					if item.part and item.part.Parent then
						item.part.Color = item.origColor
					end
				end
			end)
		end,
	},
}

function LuckyBlockSystem.new(container: Instance)
	local self = setmetatable({}, LuckyBlockSystem)
	self.container = container
	self.blocks = {}

	local floorY = ORIGIN.Y
	local spawnOffsets = {
		Vector3.new(-42, floorY + 2.8, -15),
		Vector3.new(42, floorY + 2.8, -15),
		Vector3.new(-34, floorY + 2.8, 38),
		Vector3.new(34, floorY + 2.8, 38),
		Vector3.new(0, floorY + 3.2, -50),
		Vector3.new(0, floorY + 3.0, 65),
	}

	for i, pos in ipairs(spawnOffsets) do
		self:CreateBlock(i, pos)
	end

	return self
end

function LuckyBlockSystem:CreateBlock(id: number, basePos: Vector3)
	local model = Instance.new("Model")
	model.Name = "LuckyBlock_" .. id
	model.Parent = self.container

	-- Main Golden Crate
	local box = Instance.new("Part")
	box.Name = "BoxPart"
	box.Size = CFG.BOX_SIZE
	box.CFrame = CFrame.new(basePos)
	box.Color = CFG.COLOR
	box.Material = Enum.Material.Metal
	box.Anchored = true
	box.CanCollide = false
	box.CastShadow = true
	box.Parent = model
	model.PrimaryPart = box

	-- Question mark labels on 4 vertical faces
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }) do
		local sg = Instance.new("SurfaceGui")
		sg.Face = face
		sg.LightInfluence = 0.2
		sg.AlwaysOnTop = false
		sg.Parent = box

		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.fromScale(1, 1)
		txt.BackgroundTransparency = 1
		txt.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
		txt.Text = "?"
		txt.TextSize = 56
		txt.TextColor3 = Color3.fromRGB(35, 26, 12)
		txt.Parent = sg
	end

	-- Soft subtle warm light (NOT blinding)
	local light = Instance.new("PointLight")
	light.Color = CFG.COLOR
	light.Range = 8
	light.Brightness = 0.8
	light.Parent = box

	local blockData = {
		id = id,
		basePos = basePos,
		model = model,
		box = box,
		light = light,
		isReady = true,
	}
	self.blocks[id] = blockData

	-- Gentle floating bob
	task.spawn(function()
		local t0 = id * 1.2
		while box and box.Parent do
			if blockData.isReady then
				local now = os.clock()
				local bob = math.sin(now * 1.8 + t0) * 0.4
				local rot = (now * CFG.ROTATION_SPEED) % (math.pi * 2)
				box.CFrame = CFrame.new(basePos + Vector3.new(0, bob, 0)) * CFrame.Angles(0, rot, 0)
			end
			task.wait(0.03)
		end
	end)

	return blockData
end

function LuckyBlockSystem:Trigger(blockId: number, carModel: Model, onNotify: ((text: string, color: Color3) -> ())?)
	local b = self.blocks[blockId]
	if not b or not b.isReady then return end

	b.isReady = false
	b.box.Transparency = 1
	b.light.Enabled = false

	local effect = LUCKY_EFFECTS[math.random(1, #LUCKY_EFFECTS)]
	effect.apply(carModel)

	if onNotify then
		onNotify(effect.label, effect.color)
	end

	task.delay(CFG.RESPAWN_SECONDS, function()
		if not b.box or not b.box.Parent then return end
		b.box.CFrame = CFrame.new(b.basePos)
		b.box.Size = Vector3.zero
		b.box.Transparency = 0
		b.light.Enabled = true
		
		TweenService:Create(b.box, TweenInfo.new(0.4, Enum.EasingStyle.Back), { Size = CFG.BOX_SIZE }):Play()
		b.isReady = true
	end)
end

function LuckyBlockSystem:CheckProximity(carPos: Vector3, carModel: Model, onNotify: ((text: string, color: Color3) -> ())?)
	for id, b in pairs(self.blocks) do
		if b.isReady and b.box and b.box.Parent then
			local d = (b.box.Position - carPos).Magnitude
			if d < 6.0 then
				self:Trigger(id, carModel, onNotify)
			end
		end
	end
end

function LuckyBlockSystem:Destroy()
	for _, b in pairs(self.blocks) do
		if b.model and b.model.Parent then
			b.model:Destroy()
		end
	end
	table.clear(self.blocks)
end

return LuckyBlockSystem
