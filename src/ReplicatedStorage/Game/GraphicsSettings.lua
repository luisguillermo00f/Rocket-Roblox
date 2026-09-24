--!strict
-- GraphicsSettings.lua: client graphics options + quality presets, applied live.
--   shadows     Lighting.GlobalShadows
--   post        Bloom / SunRays / ColorCorrection
--   atmosphere  Atmosphere haze
--   dof         depth of field in the menu cinematic and the pre-match intro
--   particles   "high" | "low" | "off"  (multiplier read by Effects / CarVisual / BoostPadVisuals)
--   lights      dynamic Point/Spot/Surface lights (pads, ball glow, boost, hit flashes, stadium)
--   trails      boost / ball / wheel trails
--   crowd       the 618 crowd blocks in the stands
--   menuFull    full menu cinematic (false = only the hero-reveal orbit, cheaper)
--   fps         on-screen FPS counter
--   rumble      controller vibration (Rumble)
--   deadzone    left-stick dead zone (InputController)
--   glyphs      button prompts: "auto" (follow the last device) | "gamepad" | "keyboard"   (InputGlyphs)
-- Saved with the player's profile (plus the camera settings and the Keybinds) through Remotes.SaveSettings.
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local GraphicsSettings = {}

local PRESETS = {
	low = { shadows = false, post = false, atmosphere = false, dof = false, particles = "low", lights = false, trails = false, crowd = false },
	medium = { shadows = false, post = true, atmosphere = true, dof = false, particles = "low", lights = true, trails = true, crowd = true },
	high = { shadows = true, post = true, atmosphere = true, dof = true, particles = "high", lights = true, trails = true, crowd = true },
}
GraphicsSettings.PresetOrder = { "low", "medium", "high" }
GraphicsSettings.PresetLabel = { low = "BAJA", medium = "MEDIA", high = "ALTA", custom = "PERSONALIZADA" }

local values: { [string]: any } = {
	quality = "high", shadows = true, post = true, atmosphere = true, dof = true, particles = "high", lights = true,
	trails = true, crowd = true, menuFull = true, fps = false,
	rumble = true, deadzone = 0.12, glyphs = "auto",
}
-- controller options don't touch the world: changing them skips the (costly) Apply
local CONTROL_KEYS = { rumble = true, deadzone = true, glyphs = true }
local CAMERA_KEYS = { "FOV", "Distance", "Height", "AngleDeg", "Stiffness", "SwivelSpeed", "TransitionSpeed", "Shake" }

local listeners: { () -> () } = {}
local stash: { [string]: any } = {}
local lightConn: RBXScriptConnection? = nil
local fpsGui: ScreenGui? = nil
local fpsConn: RBXScriptConnection? = nil

function GraphicsSettings.Get(key: string): any
	return values[key]
end

-- particle count multiplier for bursts / emission rates
function GraphicsSettings.ParticleMult(): number
	return if values.particles == "off" then 0 elseif values.particles == "low" then 0.35 else 1
end

function GraphicsSettings.OnChanged(fn: () -> ())
	table.insert(listeners, fn)
end

local function isLight(d: Instance): boolean
	return d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight")
end

local function setFps(on: boolean)
	if on and not fpsGui then
		local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
		if not pg then return end
		local g = Instance.new("ScreenGui")
		g.Name = "FpsCounter"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.DisplayOrder = 60
		g.Parent = pg
		local l = Instance.new("TextLabel")
		l.AnchorPoint = Vector2.new(1, 0)
		l.Position = UDim2.new(1, -14, 0, 10)
		l.Size = UDim2.fromOffset(200, 26)
		l.BackgroundTransparency = 1
		l.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
		l.TextSize = 22
		l.TextColor3 = Color3.new(1, 1, 1)
		l.TextStrokeTransparency = 0.4
		l.TextXAlignment = Enum.TextXAlignment.Right
		l.Parent = g
		fpsGui = g
		local n, t = 0, 0
		fpsConn = RunService.RenderStepped:Connect(function(dt)
			n += 1
			t += dt
			if t >= 0.5 then
				local fps = n / t
				l.Text = string.format("%d FPS  ·  %.1f MS", math.floor(fps + 0.5), t / n * 1000)
				l.TextColor3 = if fps >= 55 then Color3.fromRGB(140, 255, 160) elseif fps >= 40 then Color3.fromRGB(255, 220, 110) else Color3.fromRGB(255, 110, 100)
				n, t = 0, 0
			end
		end)
	elseif not on and fpsGui then
		if fpsConn then fpsConn:Disconnect() end
		fpsGui:Destroy()
		fpsGui = nil
		fpsConn = nil
	end
end

-- apply everything that lives in the world right now; dynamic objects read Get()/ParticleMult() when created
function GraphicsSettings.Apply()
	Lighting.GlobalShadows = values.shadows
	for _, e in Lighting:GetChildren() do
		if e:IsA("BloomEffect") or e:IsA("SunRaysEffect") or (e:IsA("ColorCorrectionEffect") and e.Name == "ColorCorrection") then
			e.Enabled = values.post
		end
	end
	-- atmosphere: park it outside Lighting when off
	local atm = Lighting:FindFirstChildWhichIsA("Atmosphere") or stash.atmosphere
	if atm then
		stash.atmosphere = atm
		atm.Parent = if values.atmosphere then Lighting else nil
	end
	-- crowd: the stands' blocks
	local arena = workspace:FindFirstChild("Arena")
	if arena then
		if not stash.crowd then
			stash.crowd = {}
			for _, c in arena:GetChildren() do
				if c.Name == "Crowd" then table.insert(stash.crowd, c) end
			end
		end
		for _, c in stash.crowd do
			c.Parent = if values.crowd then arena else nil
		end
	end
	-- dynamic lights: current ones now, new ones as they appear
	for _, d in workspace:GetDescendants() do
		if isLight(d) then (d :: any).Enabled = values.lights end
	end
	if not lightConn then
		lightConn = workspace.DescendantAdded:Connect(function(d)
			if isLight(d) and not values.lights then
				(d :: any).Enabled = false
			end
		end)
	end
	setFps(values.fps)
	for _, fn in listeners do
		task.spawn(fn)
	end
end

local function matchPreset(): string
	for _, name in GraphicsSettings.PresetOrder do
		local p = PRESETS[name]
		local same = true
		for k, v in p do
			if values[k] ~= v then same = false end
		end
		if same then return name end
	end
	return "custom"
end

function GraphicsSettings.SetPreset(name: string)
	local p = PRESETS[name]
	if not p then return end
	for k, v in p do values[k] = v end
	values.quality = name
	GraphicsSettings.Apply()
end

function GraphicsSettings.Set(key: string, v: any)
	values[key] = v
	if CONTROL_KEYS[key] then
		for _, fn in listeners do
			task.spawn(fn)
		end
		return
	end
	values.quality = matchPreset()
	GraphicsSettings.Apply()
end

-- saved blob: { gfx = {...}, cam = {...} }
function GraphicsSettings.Load(blob: any, camSettings: any)
	if type(blob) ~= "table" then
		GraphicsSettings.Apply()
		return
	end
	if type(blob.binds) == "table" then
		pcall(function() require(script.Parent.Keybinds).Load(blob.binds) end)
	end
	if type(blob.gfx) == "table" then
		for k, v in blob.gfx do
			if values[k] ~= nil and type(v) == type(values[k]) then values[k] = v end
		end
	end
	if camSettings and type(blob.cam) == "table" then
		for _, k in CAMERA_KEYS do
			local v = blob.cam[k]
			if v ~= nil and type(v) == type(camSettings[k]) then camSettings[k] = v end
		end
	end
	GraphicsSettings.Apply()
end

function GraphicsSettings.Save(camSettings: any)
	local rem = RS:FindFirstChild("Remotes")
	local ev = rem and rem:FindFirstChild("SaveSettings")
	if not ev then return end
	local cam = {}
	if camSettings then
		for _, k in CAMERA_KEYS do cam[k] = camSettings[k] end
	end
	local okB, binds = pcall(function() return require(script.Parent.Keybinds).Export() end)
	local remote = ev :: RemoteEvent
	remote:FireServer({ gfx = table.clone(values), cam = cam, binds = if okB then binds else nil })
end

return GraphicsSettings
