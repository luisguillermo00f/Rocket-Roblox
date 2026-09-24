--!strict
-- PartyUI.lua: Minimal, clean, non-intrusive HUD for Party Mode.
-- Compact top pill (party code from the server), roster with Party Points, host controls (bots, join by code),
-- bottom action dock, and overlay modal for minigame selection. Buttons only ask; the server decides.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local MinigameRegistry = require(script.Parent.MinigameRegistry)
local InputGlyphs = require(game:GetService("ReplicatedStorage"):WaitForChild("Game"):WaitForChild("InputGlyphs"))
local PartyConfig = require(script.Parent.PartyConfig)

local PartyUI = {}
PartyUI.__index = PartyUI

local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)
local CREAM = PartyConfig.COLORS.CREAM
local INK = PartyConfig.COLORS.INK
local GOLD = PartyConfig.COLORS.GOLD
local MUTED = PartyConfig.COLORS.MUTED

local function frame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = CREAM
	for k, v in pairs(props) do (f :: any)[k] = v end
	f.Parent = parent
	return f
end

local function button(parent: Instance, props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Text = ""
	b.BackgroundColor3 = CREAM
	for k, v in pairs(props) do (b :: any)[k] = v end
	b.Parent = parent
	return b
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = OSWALD
	l.TextColor3 = INK
	l.TextSize = 20
	for k, v in pairs(props) do (l :: any)[k] = v end
	l.Parent = parent
	return l
end

-- string.upper only knows ASCII: map the Spanish accents too
local function upper(str: string): string
	local up = string.upper(str)
	for lo, hi in { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" } do
		up = up:gsub(lo, hi)
	end
	return up
end

function PartyUI.new(partyCode: string, isHost: boolean)
	local self = setmetatable({}, PartyUI)
	self.partyCode = partyCode
	self.isHost = isHost
	self.playerCount = 1
	self.selectedMinigames = {}
	self.isRandomMode = true

	local lp = Players.LocalPlayer
	local pg = lp:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("PartyUI")
	if old then old:Destroy() end

	local sg = Instance.new("ScreenGui")
	sg.Name = "PartyUI"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 25
	sg.Parent = pg
	self.screenGui = sg

	-- 1. Top Pill Header: Compact (Doesn't block the arena view)
	local topPill = frame(sg, {
		Position = UDim2.fromOffset(36, 72),
		Size = UDim2.fromOffset(520, 54),
		BackgroundColor3 = CREAM,
	})
	local tpc = Instance.new("UICorner"); tpc.CornerRadius = UDim.new(0, 8); tpc.Parent = topPill
	local tps = Instance.new("UIStroke"); tps.Color = Color3.fromRGB(50, 48, 44); tps.Thickness = 2; tps.Parent = topPill

	text(topPill, {
		Position = UDim2.fromOffset(20, 0),
		Size = UDim2.fromOffset(160, 54),
		Text = "MODO GRUPO",
		TextSize = 28,
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local countLbl = text(topPill, {
		Position = UDim2.fromOffset(180, 0),
		Size = UDim2.fromOffset(120, 54),
		Text = "1/4 JUGADORES",
		TextSize = 16,
		TextColor3 = MUTED,
		FontFace = OSWALD_REG,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	self.countLabel = countLbl

	-- Party Code Box
	local codeBox = frame(topPill, {
		Position = UDim2.new(1, -210, 0, 7),
		Size = UDim2.fromOffset(200, 40),
		BackgroundColor3 = Color3.fromRGB(238, 235, 226),
	})
	local cbc = Instance.new("UICorner"); cbc.CornerRadius = UDim.new(0, 6); cbc.Parent = codeBox

	self.codeLabel = text(codeBox, {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.fromOffset(100, 40),
		Text = partyCode,
		TextSize = 22,
		TextColor3 = Color3.fromRGB(0, 130, 255),
	})

	local copyBtn = button(codeBox, {
		Position = UDim2.new(1, -85, 0, 4),
		Size = UDim2.fromOffset(80, 32),
		BackgroundColor3 = Color3.fromRGB(30, 32, 40),
	})
	local cbtnc = Instance.new("UICorner"); cbtnc.CornerRadius = UDim.new(0, 4); cbtnc.Parent = copyBtn
	local copyTxt = text(copyBtn, {
		Size = UDim2.fromScale(1, 1),
		Text = "COPIAR",
		TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1),
	})

	copyBtn.MouseButton1Click:Connect(function()
		pcall(function() (setclipboard :: any)(self.partyCode) end)
		copyTxt.Text = "¡COPIADO!"
		copyTxt.TextColor3 = GOLD
		task.delay(1.5, function()
			if copyTxt and copyTxt.Parent then
				copyTxt.Text = "COPIAR"
				copyTxt.TextColor3 = Color3.new(1, 1, 1)
			end
		end)
	end)

	-- 2. Bottom Dock: Floating pill with Start Button and Minigames toggle
	local bottomDock = frame(sg, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -22),
		Size = UDim2.fromOffset(680, 64),
		BackgroundColor3 = CREAM,
	})
	local bdc = Instance.new("UICorner"); bdc.CornerRadius = UDim.new(0, 8); bdc.Parent = bottomDock
	local bds = Instance.new("UIStroke"); bds.Color = Color3.fromRGB(50, 48, 44); bds.Thickness = 2; bds.Parent = bottomDock

	local startBtn = button(bottomDock, {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(360, 48),
		BackgroundColor3 = Color3.fromRGB(65, 70, 80),
	})
	local sbc = Instance.new("UICorner"); sbc.CornerRadius = UDim.new(0, 6); sbc.Parent = startBtn

	local startLbl = text(startBtn, {
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "INICIAR PARTY",
		TextSize = 22,
		TextColor3 = Color3.new(1, 1, 1),
	})
	local startSub = text(startBtn, {
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 18),
		Text = "SE NECESITAN AL MENOS 2 JUGADORES",
		TextSize = 13,
		TextColor3 = Color3.fromRGB(200, 205, 215),
		FontFace = OSWALD_REG,
	})
	self.startButton = startBtn
	self.startLabel = startLbl
	self.startSub = startSub

	-- Minigames Button
	local mgBtn = button(bottomDock, {
		Position = UDim2.fromOffset(384, 8),
		Size = UDim2.fromOffset(284, 48),
		BackgroundColor3 = Color3.fromRGB(235, 230, 220),
	})
	local mbc = Instance.new("UICorner"); mbc.CornerRadius = UDim.new(0, 6); mbc.Parent = mgBtn

	text(mgBtn, {
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -28, 0, 22),
		Text = "MINIJUEGOS",
		TextSize = 18,
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local mgStatus = text(mgBtn, {
		Position = UDim2.fromOffset(14, 24),
		Size = UDim2.new(1, -28, 0, 18),
		Text = "ALEATORIO",
		TextSize = 14,
		TextColor3 = Color3.fromRGB(0, 140, 255),
		FontFace = OSWALD_REG,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	self.mgStatusLabel = mgStatus

	-- Host / join panel (Top Right): bots are added by the host on the server; friends join with the code
	local testBar = frame(sg, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -36, 0, 72),
		Size = UDim2.fromOffset(300, 92),
		BackgroundColor3 = Color3.fromRGB(24, 26, 34),
	})
	local tbc = Instance.new("UICorner"); tbc.CornerRadius = UDim.new(0, 6); tbc.Parent = testBar

	local simBtn = button(testBar, {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(0.62, -12, 0, 34),
		BackgroundColor3 = Color3.fromRGB(48, 54, 70),
	})
	local sbtnc = Instance.new("UICorner"); sbtnc.CornerRadius = UDim.new(0, 4); sbtnc.Parent = simBtn
	text(simBtn, { Size = UDim2.fromScale(1, 1), Text = "+ SIMULAR AMIGO", TextSize = 16, TextColor3 = Color3.new(1, 1, 1) })
	self.simButton = simBtn

	local rmBtn = button(testBar, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.new(0.38, -4, 0, 34),
		BackgroundColor3 = Color3.fromRGB(48, 54, 70),
	})
	local rmc = Instance.new("UICorner"); rmc.CornerRadius = UDim.new(0, 4); rmc.Parent = rmBtn
	text(rmBtn, { Size = UDim2.fromScale(1, 1), Text = "− QUITAR BOT", TextSize = 15, TextColor3 = Color3.fromRGB(200, 205, 215) })
	self.removeBotButton = rmBtn

	local codeInput = Instance.new("TextBox")
	codeInput.Position = UDim2.fromOffset(8, 50)
	codeInput.Size = UDim2.new(0.62, -12, 0, 34)
	codeInput.BackgroundColor3 = Color3.fromRGB(238, 235, 226)
	codeInput.BorderSizePixel = 0
	codeInput.FontFace = OSWALD
	codeInput.TextSize = 18
	codeInput.TextColor3 = INK
	codeInput.PlaceholderText = "CÓDIGO (RR-0000)"
	codeInput.PlaceholderColor3 = MUTED
	codeInput.Text = ""
	codeInput.ClearTextOnFocus = false
	codeInput.Parent = testBar
	local cic = Instance.new("UICorner"); cic.CornerRadius = UDim.new(0, 4); cic.Parent = codeInput
	self.codeInput = codeInput

	local joinBtn = button(testBar, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 50),
		Size = UDim2.new(0.38, -4, 0, 34),
		BackgroundColor3 = Color3.fromRGB(0, 130, 255),
	})
	local jbc = Instance.new("UICorner"); jbc.CornerRadius = UDim.new(0, 4); jbc.Parent = joinBtn
	text(joinBtn, { Size = UDim2.fromScale(1, 1), Text = "UNIRSE", TextSize = 17, TextColor3 = Color3.new(1, 1, 1) })
	self.joinButton = joinBtn

	-- Roster (left, under the top pill): who is in the party and their Party Points
	local roster = frame(sg, {
		Position = UDim2.fromOffset(36, 138),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	local rl = Instance.new("UIListLayout"); rl.Padding = UDim.new(0, 6); rl.SortOrder = Enum.SortOrder.LayoutOrder; rl.Parent = roster
	self.roster = roster

	-- Back / Exit Button (Bottom Right) - Only clickable button, no ESC key
	local exitBtn = button(sg, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -36, 1, -24),
		Size = UDim2.fromOffset(190, 42),
		BackgroundColor3 = Color3.fromRGB(24, 26, 34),
		BackgroundTransparency = 0.15,
	})
	local ebc = Instance.new("UICorner"); ebc.CornerRadius = UDim.new(0, 6); ebc.Parent = exitBtn
	local ebs = Instance.new("UIStroke"); ebs.Color = Color3.fromRGB(60, 65, 80); ebs.Thickness = 1.5; ebs.Parent = exitBtn
	local exitTxt = text(exitBtn, { Size = UDim2.fromScale(1, 1), Text = "VOLVER AL MENÚ", TextSize = 16, TextColor3 = GOLD })
	self.exitButton = exitBtn

	exitBtn.MouseEnter:Connect(function()
		exitBtn.BackgroundColor3 = Color3.fromRGB(38, 42, 54)
	end)
	exitBtn.MouseLeave:Connect(function()
		exitBtn.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	end)

	-- Notification Toast
	local notifFrame = frame(sg, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 28),
		Size = UDim2.fromOffset(420, 44),
		BackgroundColor3 = INK,
		BackgroundTransparency = 1,
	})
	local nfc = Instance.new("UICorner"); nfc.CornerRadius = UDim.new(0, 8); nfc.Parent = notifFrame
	local notifTxt = text(notifFrame, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 22, TextColor3 = GOLD, TextTransparency = 1 })
	self.notifFrame = notifFrame
	self.notifText = notifTxt

	-- Minigames Selection Modal
	self:BuildMinigameModal(sg)
	mgBtn.MouseButton1Click:Connect(function() self:ToggleMinigameModal(true) end)

	-- controller: INICIAR PARTY starts selected, the d-pad / stick moves between buttons; prompts at the bottom left
	mgBtn.Name = "MinigamesButton"
	startBtn.Name = "StartButton"
	InputGlyphs.PushPanel(sg, function() return startBtn end, nil)
	InputGlyphs.HintBar(sg, { { "confirm", "ELEGIR" }, { "minigames", "MINIJUEGOS" } }, {
		anchor = Vector2.new(0, 1), position = UDim2.new(0, 36, 1, -30), height = 34, textSize = 18,
	})

	return self
end

function PartyUI:Notify(msg: string, color: Color3?)
	local nf = self.notifFrame
	local nt = self.notifText
	if not nf or not nt then return end

	nt.Text = msg
	nt.TextColor3 = color or GOLD
	nf.BackgroundTransparency = 0.15
	nt.TextTransparency = 0

	task.delay(2.6, function()
		if nf and nt then
			TweenService:Create(nf, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(nt, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		end
	end)
end

function PartyUI:UpdatePlayerCount(count: number)
	self.playerCount = count
	if self.countLabel then
		self.countLabel.Text = string.format("%d/4 JUGADORES", count)
	end

	if count >= PartyConfig.MIN_PLAYERS_TO_START and self.isHost then
		self.startButton.BackgroundColor3 = Color3.fromRGB(0, 195, 85)
		self.startSub.Text = "¡LISTO PARA JUGAR!"
		self.startSub.TextColor3 = Color3.fromRGB(230, 255, 230)
	elseif not self.isHost then
		self.startButton.BackgroundColor3 = Color3.fromRGB(65, 70, 80)
		self.startSub.Text = "EL ANFITRIÓN INICIA LA PARTY"
		self.startSub.TextColor3 = Color3.fromRGB(200, 205, 215)
	else
		self.startButton.BackgroundColor3 = Color3.fromRGB(65, 70, 80)
		self.startSub.Text = "SE NECESITAN AL MENOS 2 JUGADORES"
		self.startSub.TextColor3 = Color3.fromRGB(200, 205, 215)
	end
end

function PartyUI:SetCode(code: string)
	self.partyCode = code
	if self.codeLabel then self.codeLabel.Text = code end
end

function PartyUI:SetHost(isHost: boolean)
	self.isHost = isHost
	if self.simButton then self.simButton.Visible = isHost end
	if self.removeBotButton then self.removeBotButton.Visible = isHost end
	self:UpdatePlayerCount(self.playerCount)
end

-- members: { { id, name, isBot, isHost, points, color } } in party order
function PartyUI:SetRoster(members: { any })
	local roster = self.roster
	if not roster then return end
	for _, c in roster:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end
	local lp = Players.LocalPlayer
	for i, m in members do
		local row = frame(roster, { Size = UDim2.fromOffset(300, 40), BackgroundColor3 = INK, BackgroundTransparency = 0.2, LayoutOrder = i })
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row
		frame(row, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = m.color or GOLD })
		local tag = if m.isHost then "★ " elseif m.isBot then "BOT · " else ""
		local you = if m.userId == lp.UserId then "  (TÚ)" else ""
		text(row, {
			Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -90, 1, 0), TextSize = 18,
			TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			Text = tag .. upper(m.name or "?") .. you,
		})
		text(row, {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.fromOffset(70, 40), TextSize = 20,
			TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right, Text = tostring(m.points or 0) .. " PF",
		})
	end
end

-- ids the server can run right now; the others are shown as coming soon and can't be picked
function PartyUI:SetAvailable(available: { [string]: boolean })
	self.available = available
	local n = 0
	for id, refs in self.rowRefs or {} do
		local ok = available[id] == true
		if not ok then
			self.selectedMinigames[id] = false
		end
		local on = ok and self.selectedMinigames[id] ~= false
		if ok and self.selectedMinigames[id] == nil then self.selectedMinigames[id] = true end
		refs.chk.BackgroundColor3 = if not ok then Color3.fromRGB(200, 196, 188) elseif on then Color3.fromRGB(0, 180, 80) else Color3.fromRGB(150, 150, 160)
		refs.chkLbl.Text = if not ok then "PRONTO" elseif on then "ACTIVO" else "NO"
		refs.row.BackgroundTransparency = if ok then 0 else 0.45
		if on then n += 1 end
	end
	if self.mgStatusLabel and self.isRandomMode then
		self.mgStatusLabel.Text = string.format("ALEATORIO (%d %s)", n, if n == 1 then "RETO" else "RETOS")
	end
end

function PartyUI:BuildMinigameModal(parent: ScreenGui)
	local modal = frame(parent, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(820, 520),
		BackgroundColor3 = CREAM,
		Visible = false,
	})
	local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = modal
	local ms = Instance.new("UIStroke"); ms.Color = Color3.fromRGB(50, 48, 44); ms.Thickness = 2; ms.Parent = modal
	self.minigameModal = modal

	text(modal, {
		Position = UDim2.fromOffset(32, 20),
		Size = UDim2.fromOffset(400, 36),
		Text = "SELECCIÓN DE MINIJUEGOS",
		TextSize = 32,
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	text(modal, {
		Position = UDim2.fromOffset(34, 56),
		Size = UDim2.fromOffset(600, 22),
		Text = "CONFIGURA QUÉ RETOS PARTICIPARÁN EN ESTA SESIÓN",
		TextSize = 15,
		TextColor3 = MUTED,
		FontFace = OSWALD_REG,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local tabRandom = button(modal, { Position = UDim2.fromOffset(34, 90), Size = UDim2.fromOffset(180, 40), BackgroundColor3 = Color3.fromRGB(0, 140, 255) })
	local trc = Instance.new("UICorner"); trc.CornerRadius = UDim.new(0, 6); trc.Parent = tabRandom
	local tabChoose = button(modal, { Position = UDim2.fromOffset(224, 90), Size = UDim2.fromOffset(210, 40), BackgroundColor3 = Color3.fromRGB(230, 225, 215) })
	local tcc = Instance.new("UICorner"); tcc.CornerRadius = UDim.new(0, 6); tcc.Parent = tabChoose

	local trTxt = text(tabRandom, { Size = UDim2.fromScale(1, 1), Text = "ALEATORIO", TextSize = 18, TextColor3 = Color3.new(1, 1, 1) })
	local tcTxt = text(tabChoose, { Size = UDim2.fromScale(1, 1), Text = "ELEGIR MINIJUEGOS", TextSize = 18, TextColor3 = INK })

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(34, 142)
	scroll.Size = UDim2.fromOffset(752, 290)
	scroll.BackgroundTransparency = 1
	scroll.ScrollBarThickness = 5
	scroll.Parent = modal

	local allGames = MinigameRegistry.GetAll()
	local itemH = 64
	self.rowRefs = {}
	for i, gDef in ipairs(allGames) do
		self.selectedMinigames[gDef.id] = true
		local row = frame(scroll, {
			Position = UDim2.fromOffset(0, (i - 1) * (itemH + 8)),
			Size = UDim2.new(1, -12, 0, itemH),
			BackgroundColor3 = Color3.fromRGB(242, 238, 230),
		})
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row

		local tagF = frame(row, { Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(95, 18), BackgroundColor3 = gDef.tagColor })
		local tfc = Instance.new("UICorner"); tfc.CornerRadius = UDim.new(0, 4); tfc.Parent = tagF
		text(tagF, { Size = UDim2.fromScale(1, 1), Text = gDef.tag, TextSize = 12, TextColor3 = Color3.new(1, 1, 1) })

		text(row, { Position = UDim2.fromOffset(14, 30), Size = UDim2.fromOffset(240, 24), Text = gDef.name, TextSize = 20, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Left })
		text(row, { Position = UDim2.fromOffset(260, 12), Size = UDim2.new(1, -350, 0, 40), Text = gDef.description, TextSize = 14, TextColor3 = MUTED, FontFace = OSWALD_REG, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left })

		local chk = button(row, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(68, 34), BackgroundColor3 = Color3.fromRGB(0, 180, 80) })
		local chkc = Instance.new("UICorner"); chkc.CornerRadius = UDim.new(0, 6); chkc.Parent = chk
		local chkLbl = text(chk, { Size = UDim2.fromScale(1, 1), Text = "ACTIVO", TextSize = 15, TextColor3 = Color3.new(1, 1, 1) })

		self.rowRefs[gDef.id] = { chk = chk, chkLbl = chkLbl, row = row }
		chk.MouseButton1Click:Connect(function()
			if self.available and not self.available[gDef.id] then return end
			local active = not self.selectedMinigames[gDef.id]
			self.selectedMinigames[gDef.id] = active
			if self.available then
				self:SetAvailable(self.available)
			else
				chk.BackgroundColor3 = if active then Color3.fromRGB(0, 180, 80) else Color3.fromRGB(150, 150, 160)
				chkLbl.Text = if active then "ACTIVO" else "NO"
			end
		end)
	end
	scroll.CanvasSize = UDim2.fromOffset(0, #allGames * (itemH + 8))

	local closeBtn = button(modal, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -34, 1, -18), Size = UDim2.fromOffset(140, 42), BackgroundColor3 = Color3.fromRGB(30, 32, 40) })
	self.minigameClose = closeBtn
	local clc = Instance.new("UICorner"); clc.CornerRadius = UDim.new(0, 6); clc.Parent = closeBtn
	text(closeBtn, { Size = UDim2.fromScale(1, 1), Text = "GUARDAR", TextSize = 20, TextColor3 = Color3.new(1, 1, 1) })
	closeBtn.MouseButton1Click:Connect(function() self:ToggleMinigameModal(false) end)

	tabRandom.MouseButton1Click:Connect(function()
		self.isRandomMode = true
		tabRandom.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
		trTxt.TextColor3 = Color3.new(1, 1, 1)
		tabChoose.BackgroundColor3 = Color3.fromRGB(230, 225, 215)
		tcTxt.TextColor3 = INK
		if self.available then self:SetAvailable(self.available) end
	end)

	tabChoose.MouseButton1Click:Connect(function()
		self.isRandomMode = false
		tabChoose.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
		tcTxt.TextColor3 = Color3.new(1, 1, 1)
		tabRandom.BackgroundColor3 = Color3.fromRGB(230, 225, 215)
		trTxt.TextColor3 = INK
		self.mgStatusLabel.Text = "SELECCIÓN MANUAL"
	end)
end

function PartyUI:ToggleMinigameModal(open: boolean)
	if self.minigameModal then self.minigameModal.Visible = open end
	-- controller: the modal takes the selection while open (B = GUARDAR), then it goes back to the lobby
	if open and not self.popModal and self.minigameModal then
		self.popModal = InputGlyphs.PushPanel(self.minigameModal, function() return self.minigameClose end, function()
			self:ToggleMinigameModal(false)
		end)
	elseif not open and self.popModal then
		local pop = self.popModal
		self.popModal = nil
		pop()
	end
end

function PartyUI:Destroy()
	if self.screenGui then self.screenGui:Destroy(); self.screenGui = nil end
end

return PartyUI
