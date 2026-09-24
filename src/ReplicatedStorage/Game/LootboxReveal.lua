--!strict
-- LootboxReveal.lua: the box opening animation (docs/lootboxes.md §12), all built from GUI frames and tweens (a
-- ParticleEmitter doesn't render inside a ViewportFrame, so the "particles" are small frames).
--   1. the box waits for the server in NEUTRAL colours (nothing about the rarity is shown before the answer)
--   2. it shakes harder and harder, ticking faster        3. flash in the rarity colour (Legendaria / Exótica: longer)
--   4. the lid flies off, particle burst                    5. item card: name, slot, rarity, NUEVO / DUPLICADO, GARANTÍA
-- No near misses: the colour appears only at the flash, and it is the real one. A / ENTER / click skips to the card.
-- Structure and logic only; timings and looks are tuned in Studio.
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local InputGlyphs = require(script.Parent.InputGlyphs)
local Sounds = require(script.Parent.Sounds)
local Economy = script.Parent.Parent:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))

local LootboxReveal = {}

local PARTICLES = { common = 20, rare = 35, epic = 50, legendary = 70, exotic = 70 }
local RAINBOW = {
	Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 180, 50), Color3.fromRGB(255, 245, 80),
	Color3.fromRGB(80, 230, 110), Color3.fromRGB(70, 150, 255), Color3.fromRGB(190, 90, 255),
}

local function sfx(name: string, opts: { [string]: any }?)
	pcall(function() Sounds.Play(name, nil, opts) end)
end

export type Opts = {
	again: (() -> ())?, -- ABRIR OTRA
	equip: ((result: any) -> ())?, -- EQUIPAR (new items)
	closed: (() -> ())?,
}

-- box: LootboxData box ; waitResult() yields until the server's answer ({ ok, item, rarity, dup, gave, pity, left })
function LootboxReveal.Play(UI: any, box: any, waitResult: () -> any, opts: Opts)
	local frame, text, button = UI.frame, UI.text, UI.button
	local g = UI.newGui("LootboxOpening", 45)
	local conns: { RBXScriptConnection } = {}
	local function close()
		if g.Parent then g:Destroy() end
		if opts.closed then opts.closed() end
	end
	g.Destroying:Connect(function()
		for _, c in conns do c:Disconnect() end
	end)
	frame(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.25, Active = true }) -- sinks clicks
	local stage = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1200, 800), BackgroundTransparency = 1 })
	local center = UDim2.fromScale(0.5, 0.5)

	-- the box: neutral body with the box type's band (the type is known; the rarity isn't)
	local boxRoot = frame(stage, { AnchorPoint = Vector2.new(0.5, 0.5), Position = center, Size = UDim2.fromOffset(260, 250), BackgroundTransparency = 1 })
	local body = frame(boxRoot, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(260, 190), BackgroundColor3 = Color3.fromRGB(46, 48, 58) })
	frame(body, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70), Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = box.color })
	UI.brackets(body, Color3.fromRGB(200, 200, 210), 8, 16, 3)
	local lid = frame(boxRoot, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(290, 60), BackgroundColor3 = Color3.fromRGB(60, 62, 74) })
	frame(lid, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 20), Size = UDim2.new(1, 0, 0, 12), BackgroundColor3 = box.color })
	local label = text(stage, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 170), Size = UDim2.fromOffset(900, 40), Text = box.name, TextSize = 34, TextColor3 = UI.WHITE })

	local skip = false
	local finished = false
	table.insert(conns, UIS.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if not finished and (k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Return or k == Enum.KeyCode.Space
			or input.UserInputType == Enum.UserInputType.MouseButton1) then
			skip = true
		end
	end))
	local function pause(t: number)
		local t0 = os.clock()
		while not skip and os.clock() - t0 < t do task.wait() end
	end

	-- 1. waiting for the server: a slow neutral wobble
	local phase, amp, t = "wait", 2, 0
	table.insert(conns, RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		if phase == "wait" then
			boxRoot.Rotation = math.sin(t * 3) * amp
		elseif phase == "shake" then
			boxRoot.Rotation = math.sin(t * 40) * amp
			boxRoot.Position = center + UDim2.fromOffset(math.sin(t * 57) * amp * 1.5, math.cos(t * 49) * amp)
		else
			boxRoot.Rotation = 0
			boxRoot.Position = center
		end
	end))
	local result = waitResult()
	if not g.Parent then return end
	if type(result) ~= "table" or not result.ok then
		phase = "idle"
		finished = true
		label.Text = tostring(type(result) == "table" and result.error or "NO SE PUDO ABRIR")
		label.TextColor3 = UI.ORANGE
		local b = button(stage, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 230), Size = UDim2.fromOffset(260, 60), BackgroundColor3 = UI.CHIP })
		text(b, { Size = UDim2.fromScale(1, 1), Text = "CERRAR", TextSize = 26, TextColor3 = UI.WHITE })
		b.MouseButton1Click:Connect(close)
		InputGlyphs.PushPanel(g, function() return b end, close)
		return
	end
	local it = Catalog.Get(result.item)
	local rarity = Catalog.RARITIES[result.rarity] or Catalog.RARITIES.common
	local order = rarity.order
	local color = rarity.color

	-- 2. shake, ticking faster
	phase = "shake"
	local t0 = os.clock()
	local nextTick = 0
	while not skip and os.clock() - t0 < 1.2 do
		local k = (os.clock() - t0) / 1.2
		amp = 2 + 10 * k
		if os.clock() - t0 >= nextTick then
			sfx("tick", { pitch = 0.9 + k * 0.6, volume = 0.4 })
			nextTick += 0.25 - 0.18 * k
		end
		task.wait()
	end
	-- Legendaria / Exótica: a longer build-up, still in white
	if order >= 4 then
		local glow = frame(stage, { AnchorPoint = Vector2.new(0.5, 0.5), Position = center, Size = UDim2.fromOffset(300, 300), BackgroundColor3 = UI.WHITE, BackgroundTransparency = 1 })
		UI.corner(glow, UDim.new(0.5, 0))
		glow.ZIndex = 0
		UI.tween(glow, 0.6, { Size = UDim2.fromOffset(620, 620), BackgroundTransparency = 0.6 })
		sfx("boom", { volume = 0.35 })
		pause(0.6)
		glow:Destroy()
	end
	phase = "open"

	-- 3. flash in the rarity colour
	local flash = frame(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 0.15, ZIndex = 20 })
	UI.tween(flash, 0.6, { BackgroundTransparency = 1 })
	task.delay(0.7, function() flash:Destroy() end)
	sfx("whoosh")
	if order >= 4 then sfx("goalBoom", { volume = 0.5 }) end
	if order == 5 then sfx("crowdGoal", { volume = 0.4 }) end

	-- 4. lid off + particles
	UI.tween(lid, 0.5, { Position = UDim2.new(0.5, 120, 0, -260), Rotation = 50, BackgroundTransparency = 1 })
	local rng = Random.new()
	local function burst(n: number, colors: { Color3 })
		for i = 1, n do
			local s = rng:NextInteger(8, 18)
			local p = frame(stage, { AnchorPoint = Vector2.new(0.5, 0.5), Position = center, Size = UDim2.fromOffset(s, s), BackgroundColor3 = colors[(i - 1) % #colors + 1], Rotation = rng:NextInteger(0, 90) })
			local a = rng:NextNumber(0, math.pi * 2)
			local d = rng:NextNumber(180, 520)
			UI.tween(p, rng:NextNumber(0.6, 1.1), { Position = center + UDim2.fromOffset(math.cos(a) * d, math.sin(a) * d), BackgroundTransparency = 1, Rotation = rng:NextInteger(90, 360) })
			task.delay(1.2, function() p:Destroy() end)
		end
	end
	burst(PARTICLES[result.rarity] or 20, { color, UI.WHITE })
	if order >= 4 then
		-- light rays turning behind the card
		local rays = frame(stage, { AnchorPoint = Vector2.new(0.5, 0.5), Position = center, Size = UDim2.fromOffset(10, 10), BackgroundTransparency = 1 })
		for i = 1, 8 do
			local r = frame(rays, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 900), BackgroundColor3 = color, BackgroundTransparency = 0.75, Rotation = i * 22.5 })
			r.ZIndex = 0
		end
		table.insert(conns, RunService.RenderStepped:Connect(function(dt: number) rays.Rotation += dt * 25 end))
	end
	if order == 5 then
		task.delay(0.3, function()
			if g.Parent then burst(60, RAINBOW) end
		end)
		local s0 = os.clock()
		local shakeConn: RBXScriptConnection
		shakeConn = RunService.RenderStepped:Connect(function()
			local k = 1 - (os.clock() - s0) / 0.6
			if k <= 0 or not stage.Parent then
				stage.Position = UDim2.fromScale(0.5, 0.5)
				shakeConn:Disconnect()
				return
			end
			stage.Position = UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(rng:NextNumber(-12, 12) * k, rng:NextNumber(-12, 12) * k)
		end)
		table.insert(conns, shakeConn)
	end
	pause(0.35)
	boxRoot.Visible = false
	label.Visible = false
	finished = true

	-- 5. the item card
	local card = frame(stage, { AnchorPoint = Vector2.new(0.5, 0.5), Position = center, Size = UDim2.fromOffset(620, 340), BackgroundColor3 = UI.CREAM })
	card.ZIndex = 2
	UI.brackets(card, UI.EDGE, 10, 18, 3)
	local cs = Instance.new("UIScale")
	cs.Scale = 0.6
	cs.Parent = card
	UI.tween(cs, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	frame(card, { Size = UDim2.new(1, 0, 0, 12), BackgroundColor3 = color })
	text(card, { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 30), Text = rarity.name .. "  ·  " .. (if it then Catalog.SLOT_NAMES[it.slot] or "" else ""), TextSize = 26, TextColor3 = color })
	text(card, { Position = UDim2.fromOffset(20, 62), Size = UDim2.new(1, -40, 0, 110), Text = if it then it.name else tostring(result.item), TextSize = 64, TextWrapped = true })
	local line
	if result.dup then
		line = if result.gave and result.gave.credits then "DUPLICADO  →  +" .. UI.fmtInt(result.gave.credits) .. " CRÉDITOS"
			else "DUPLICADO  →  +" .. UI.fmtInt(result.gave and result.gave.fragments or 0) .. " FRAGMENTOS"
	else
		line = "¡NUEVO!"
	end
	text(card, { Position = UDim2.fromOffset(0, 180), Size = UDim2.new(1, 0, 0, 34), Text = line, TextSize = 30, TextColor3 = if result.dup then UI.MUTED else UI.BLUE })
	if result.pity then
		local tag = frame(card, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 24), Size = UDim2.fromOffset(130, 30), BackgroundColor3 = UI.GOLD })
		text(tag, { Size = UDim2.fromScale(1, 1), Text = "GARANTÍA", TextSize = 20 })
	end
	if order >= 3 then sfx("win", { volume = 0.45 }) end

	-- 6. buttons
	local row = frame(card, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -22), Size = UDim2.fromOffset(580, 60), BackgroundTransparency = 1 })
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.Padding = UDim.new(0, 12)
	rl.Parent = row
	local first: GuiObject? = nil
	local function btn(textLabel: string, dark: boolean, fn: () -> ())
		local b = button(row, { Size = UDim2.fromOffset(180, 60), BackgroundColor3 = if dark then UI.CHIP else UI.BAR })
		text(b, { Size = UDim2.fromScale(1, 1), Text = textLabel, TextSize = 24, TextColor3 = if dark then UI.WHITE else UI.INK })
		b.MouseButton1Click:Connect(fn)
		if not first then first = b end
	end
	local again = opts.again
	if again and (result.left or 0) > 0 then
		btn("ABRIR OTRA", true, function() g:Destroy(); again() end)
	end
	local equip = opts.equip
	if equip and not result.dup and it then
		btn("EQUIPAR", first == nil, function() equip(result); close() end)
	end
	btn("CERRAR", first == nil, close)
	task.defer(function()
		InputGlyphs.PushPanel(g, function() return first end, close)
	end)
end


return LootboxReveal
