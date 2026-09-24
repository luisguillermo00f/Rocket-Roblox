--!strict
-- ChallengesScreen.lua: DESAFÍOS (docs/progression.md §6). The 3 daily + 3 weekly challenges exactly as the server
-- profile has them (texts, progress and rewards are resolved on the server); the client only draws them.
-- Controller: the cards are selectable (engine navigation, gold frame), B / ESC closes. Structure only - the visual
-- polish happens in Studio.
local UIS = game:GetService("UserInputService")

local InputGlyphs = require(script.Parent.InputGlyphs)
local EconomyClient = require(script.Parent.EconomyClient)
local DateUtil = require(script.Parent.Parent:WaitForChild("Economy"):WaitForChild("DateUtil"))

local ChallengesScreen = {}

local gui: ScreenGui? = nil

function ChallengesScreen.Close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

function ChallengesScreen.IsOpen(): boolean
	return gui ~= nil
end

-- UI: MainMenu.UI (the menu's own helpers and palette; passed in so this module doesn't require MainMenu back)
function ChallengesScreen.Open(UI: any)
	local frame, text, button = UI.frame, UI.text, UI.button
	ChallengesScreen.Close()
	local g = UI.newGui("ChallengesMenu", 40)
	gui = g
	local conns: { any } = {}
	g.Destroying:Connect(function()
		for _, c in conns do
			if typeof(c) == "RBXScriptConnection" then c:Disconnect() else c() end
		end
	end)

	local back = button(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, Selectable = false })
	back.MouseButton1Click:Connect(ChallengesScreen.Close)
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1240, 720), BackgroundColor3 = UI.CREAM })
	UI.brackets(p, UI.EDGE, 10, 18, 3)
	local ps = Instance.new("UIScale")
	ps.Scale = 0.94
	ps.Parent = p
	UI.tween(ps, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)

	text(p, { Position = UDim2.fromOffset(40, 24), Size = UDim2.fromOffset(600, 50), Text = "DESAFÍOS", TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left })
	text(p, { Position = UDim2.fromOffset(42, 72), Size = UDim2.fromOffset(900, 22), Text = "LOS CRÉDITOS Y LA XP SE SUMAN SOLOS AL COMPLETAR CADA DESAFÍO", TextSize = 16, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })

	-- columns (rebuilt by render)
	local cols = {}
	for i, kind in { "daily", "weekly" } do
		local x = 40 + (i - 1) * 590
		local col = frame(p, { Position = UDim2.fromOffset(x, 112), Size = UDim2.fromOffset(570, 500), BackgroundTransparency = 1 })
		text(col, { Size = UDim2.fromOffset(300, 34), Text = if kind == "daily" then "DIARIOS" else "SEMANALES", TextSize = 30, TextXAlignment = Enum.TextXAlignment.Left })
		local reset = text(col, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 8), Size = UDim2.fromOffset(300, 22), Text = "", TextSize = 16, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Right, FontFace = UI.OSWALD_REG })
		local body = frame(col, { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 1, -44), BackgroundTransparency = 1 })
		cols[kind] = { reset = reset, body = body, resetIn = 0 }
	end
	local capLabel = text(p, { Position = UDim2.fromOffset(42, 636), Size = UDim2.fromOffset(700, 26), Text = "", TextSize = 18, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
	local close = button(p, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -28, 1, -28), Size = UDim2.fromOffset(250, 64), BackgroundColor3 = UI.CHIP })
	text(close, { Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -100, 1, 0), Text = "CERRAR", TextSize = 28, TextColor3 = UI.WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	UI.chip(close, "ESC", false)
	close.MouseButton1Click:Connect(ChallengesScreen.Close)

	local firstCard: GuiObject? = nil
	local fetchedAt = EconomyClient.Now()

	local function card(parent: Instance, y: number, it: any): TextButton
		local b = button(parent, { Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 142), BackgroundColor3 = UI.PANEL })
		if it.done then
			frame(b, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = UI.GOLD })
		end
		text(b, { Position = UDim2.fromOffset(22, 12), Size = UDim2.new(1, -44, 0, 18), Text = string.upper(it.cat or "") .. (if it.scope == "online" then "  ·  EN LÍNEA" elseif it.scope == "minigame" then "  ·  FIESTA" else ""),
			TextSize = 14, TextColor3 = UI.MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
		text(b, { Position = UDim2.fromOffset(22, 32), Size = UDim2.new(1, -44, 0, 36), Text = it.text, TextSize = 28, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
		local track = frame(b, { Position = UDim2.fromOffset(22, 82), Size = UDim2.new(1, -170, 0, 10), BackgroundColor3 = UI.BAR })
		local frac = if it.target > 0 then math.clamp(it.progress / it.target, 0, 1) else 0
		local fill = frame(track, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = if it.done then UI.GOLD else UI.BLUE })
		UI.tween(fill, 0.6, { Size = UDim2.fromScale(frac, 1) })
		text(b, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -22, 0, 74), Size = UDim2.fromOffset(130, 26), Text = UI.fmtInt(it.progress) .. " / " .. UI.fmtInt(it.target), TextSize = 22, TextXAlignment = Enum.TextXAlignment.Right })
		text(b, { Position = UDim2.fromOffset(22, 104), Size = UDim2.new(1, -44, 0, 24), Text = string.format("+%s CRÉDITOS  ·  +%s XP", UI.fmtInt(it.credits), UI.fmtInt(it.xp)),
			TextSize = 19, TextColor3 = if it.done then UI.MUTED else UI.INK, TextXAlignment = Enum.TextXAlignment.Left, FontFace = UI.OSWALD_REG })
		if it.done then
			local stamp = frame(b, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -22, 0, 104), Size = UDim2.fromOffset(150, 28), BackgroundColor3 = UI.GOLD })
			text(stamp, { Size = UDim2.fromScale(1, 1), Text = "COMPLETADO", TextSize = 18 })
		end
		return b
	end

	local function render(prof: any)
		if gui ~= g then return end
		firstCard = nil
		local ch = prof and prof.challenges
		for _, kind in { "daily", "weekly" } do
			local c = cols[kind]
			c.body:ClearAllChildren()
			local slot = ch and ch[kind]
			if not slot then
				text(c.body, { Size = UDim2.new(1, 0, 0, 40), Text = "CARGANDO…", TextSize = 22, TextColor3 = UI.MUTED })
				continue
			end
			c.resetIn = slot.resetIn or 0
			for i, it in slot.items or {} do
				local b = card(c.body, (i - 1) * 154, it)
				if not firstCard then firstCard = b end
			end
		end
		fetchedAt = EconomyClient.Now()
		local cap = prof and prof.dailyCap
		capLabel.Text = if cap then string.format("CRÉDITOS DE PARTIDAS HOY: %s / %s", UI.fmtInt(cap.earned), UI.fmtInt(cap.max)) else ""
		InputGlyphs.RefreshFocus()
	end

	-- reset countdowns tick locally from the last server answer
	table.insert(conns, game:GetService("RunService").Heartbeat:Connect(function()
		local gone = EconomyClient.Now() - fetchedAt
		for _, c in cols do
			local left = c.resetIn - gone
			c.reset.Text = if left > 0 then "SE RENUEVAN EN " .. DateUtil.FormatLeft(left) else "RENOVANDO…"
		end
	end))

	render(EconomyClient.Get())
	table.insert(conns, EconomyClient.OnUpdate(function(prof) render(prof) end))
	task.spawn(EconomyClient.Refresh) -- fresh lists (a new UTC day may have started)

	table.insert(conns, UIS.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace then
			ChallengesScreen.Close()
		end
	end))
	InputGlyphs.PushPanel(g, function() return firstCard or close end, ChallengesScreen.Close)
end

return ChallengesScreen
