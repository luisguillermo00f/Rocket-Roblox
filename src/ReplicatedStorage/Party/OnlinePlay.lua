--!strict
-- OnlinePlay.lua (client): the menu side of online matches (server: PartyMinigameService.MatchMaker).
--   * JUGAR public 1v1 / 2v2 and RANKED: a "BUSCANDO PARTIDA" pill with the wait and a cancel button
--   * SALA PRIVADA: a room screen with the SL-#### code to share, who's in, 1V1/2V2 and bot difficulty (host), start
--   * when the match starts it takes the screen (MinigameClient + MinigameViews.Soccar); when it ends you're back in
--     the menu - or in the room, ready for a rematch
--   * arriving from another server with a code (TeleportData) drops you straight into that party / room
-- Buttons only ask; the server answers with the new state.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")

local Party = script.Parent
local Net = require(Party.Net)
local MinigameClient = require(Party.MinigameClient)
local Upper = require(Party.MinigameHud).Upper
local InputGlyphs = require(RS:WaitForChild("Game"):WaitForChild("InputGlyphs"))
local GuiService = game:GetService("GuiService")

local OnlinePlay = {}

local INK = Color3.fromRGB(18, 18, 20)
local CREAM = Color3.fromRGB(248, 244, 236)
local MUTED = Color3.fromRGB(120, 112, 100)
local GOLD = Color3.fromRGB(255, 196, 64)
local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local WHITE = Color3.new(1, 1, 1)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)

local request: any = nil
local state: any = { status = "idle" }
local car = { skin = "Octane", hitbox = "Octane" }
local botDifficulty = "pro"
local gui: ScreenGui? = nil
local refs: { [string]: any } = {}
local inMatch = false
local initDone = false

-- ---------------------------------------------------------------- ui helpers
local function frame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = CREAM
	for k, v in props do (f :: any)[k] = v end
	f.Parent = parent
	return f
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = OSWALD
	l.TextColor3 = INK
	l.TextSize = 20
	for k, v in props do (l :: any)[k] = v end
	l.Parent = parent
	return l
end

local function button(parent: Instance, props: { [string]: any }, label: string, color: Color3, textColor: Color3?): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Text = ""
	b.BackgroundColor3 = color
	for k, v in props do (b :: any)[k] = v end
	b.Parent = parent
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
	text(b, { Size = UDim2.fromScale(1, 1), Text = label, TextSize = 20, TextColor3 = textColor or WHITE })
	b.MouseEnter:Connect(function() TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = color:Lerp(WHITE, 0.12) }):Play() end)
	b.MouseLeave:Connect(function() TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = color }):Play() end)
	return b
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = parent
end

local function ensureGui(): ScreenGui
	if gui and gui.Parent then return gui end
	local g = Instance.new("ScreenGui")
	g.Name = "OnlinePlay"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 34
	g.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = g
	return g
end

local function toast(msg: string, color: Color3?)
	local g = ensureGui()
	local t = text(g, {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -40), Size = UDim2.fromOffset(640, 40),
		BackgroundTransparency = 0.15, BackgroundColor3 = INK, TextSize = 20, TextColor3 = color or GOLD, Text = msg, ZIndex = 20,
	})
	corner(t, 8)
	task.delay(2.6, function()
		TweenService:Create(t, TweenInfo.new(0.3), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		task.delay(0.35, function() t:Destroy() end)
	end)
end

-- ---------------------------------------------------------------- server
local function ask(action: string, arg: any?): any
	request = request or Net.Remote("MatchRequest")
	if not request then
		toast("SIN CONEXIÓN CON EL SERVIDOR", Color3.fromRGB(255, 90, 80))
		return nil
	end
	local ok, res = pcall(function() return request:InvokeServer(action, arg) end)
	if not ok or type(res) ~= "table" then
		toast("EL SERVIDOR NO RESPONDIÓ", Color3.fromRGB(255, 90, 80))
		return nil
	end
	if res.state then OnlinePlay.Apply(res.state) end
	if not res.ok and res.error then toast(Upper(tostring(res.error)), Color3.fromRGB(255, 90, 80)) end
	return res
end

-- ---------------------------------------------------------------- screens
local function clearScreens()
	if refs.queue then refs.queue:Destroy(); refs.queue = nil end
	if refs.room then refs.room:Destroy(); refs.room = nil end
	if refs.queueConn then refs.queueConn:Disconnect(); refs.queueConn = nil end
end

local function showQueue(st: any)
	if refs.queue then
		refs.queueInfo = st
		return
	end
	clearScreens()
	refs.queueInfo = st
	local g = ensureGui()
	local pill = frame(g, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 72), Size = UDim2.fromOffset(560, 74), BackgroundColor3 = INK })
	corner(pill, 10)
	refs.queue = pill
	local band = frame(pill, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = if st.key == "ranked" then ORANGE else BLUE })
	corner(band, 3)
	local title = text(pill, { Position = UDim2.fromOffset(22, 8), Size = UDim2.fromOffset(360, 32), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 26, TextColor3 = WHITE, Text = "" })
	local sub = text(pill, { Position = UDim2.fromOffset(22, 40), Size = UDim2.fromOffset(360, 22), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 15, FontFace = OSWALD_REG, TextColor3 = Color3.fromRGB(190, 190, 200), Text = "" })
	local cancel = button(pill, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(140, 44) }, "CANCELAR", Color3.fromRGB(56, 60, 72))
	cancel.MouseButton1Click:Connect(function() ask("cancel") end)
	-- controller: X cancels (the glyph sits on the button's left edge)
	cancel.Selectable = false -- the menu underneath keeps the d-pad
	InputGlyphs.Chip(cancel, "cancel", { anchor = Vector2.new(0.5, 0.5), position = UDim2.new(0, 2, 0.5, 0), height = 30 })
	refs.queueConn = game:GetService("RunService").Heartbeat:Connect(function()
		local q = refs.queueInfo
		if not q then return end
		local waited = math.max(0, workspace:GetServerTimeNow() - (q.since or workspace:GetServerTimeNow()))
		local mode = if q.key == "ranked" then "RANKED 1V1" elseif q.key == "2v2" then "2V2" else "1V1"
		local dots = string.rep(".", 1 + math.floor(os.clock() * 2) % 3)
		title.Text = "BUSCANDO PARTIDA " .. mode .. dots
		local left = math.max(0, math.ceil((q.wait or 8) - waited))
		sub.Text = string.format("%d/%d JUGADORES  ·  %d:%02d  ·  %s", q.waiting or 1, q.needed or 2, math.floor(waited) // 60, math.floor(waited) % 60,
			if left > 0 then ("BOTS COMPLETAN EN %d s"):format(left) else "EMPEZANDO...")
	end)
end

local function showRoom(st: any)
	-- keep the controller on the same button across refreshes (someone joins, the host changes the mode...)
	local prevSel = GuiService.SelectedObject
	local keepName = if prevSel and refs.room and prevSel:IsDescendantOf(refs.room) then prevSel.Name else nil
	clearScreens()
	local room = st.room
	if not room then return end
	local lp = Players.LocalPlayer
	local isHost = room.hostUserId == lp.UserId
	local g = ensureGui()
	local back = frame(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45 })
	refs.room = back
	local p = frame(back, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(760, 520) })
	corner(p, 10)
	local sc = Instance.new("UIScale"); sc.Parent = p
	sc.Scale = math.clamp(workspace.CurrentCamera.ViewportSize.Y / 900, 0.6, 1.2)
	frame(p, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = GOLD })
	text(p, { Position = UDim2.fromOffset(36, 26), Size = UDim2.fromOffset(400, 50), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 46, Text = "SALA PRIVADA" })
	text(p, { Position = UDim2.fromOffset(38, 74), Size = UDim2.fromOffset(520, 22), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 16, FontFace = OSWALD_REG, TextColor3 = MUTED,
		Text = "COMPARTE EL CÓDIGO: TUS AMIGOS LO ESCRIBEN EN JUGAR › PRIVADA › UNIRSE" })

	-- code
	local codeBox = frame(p, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -36, 0, 26), Size = UDim2.fromOffset(250, 60), BackgroundColor3 = INK })
	corner(codeBox, 8)
	text(codeBox, { Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -110, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 30, TextColor3 = GOLD, Text = room.code })
	local copy = button(codeBox, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(90, 40) }, "COPIAR", Color3.fromRGB(56, 60, 72))
	copy.MouseButton1Click:Connect(function()
		pcall(function() (setclipboard :: any)(room.code) end)
		toast("CÓDIGO " .. room.code)
	end)

	-- seats
	local size = room.size or 2
	for i = 1, 4 do
		local m = room.members[i]
		local active = i <= size
		local seat = frame(p, { Position = UDim2.fromOffset(36 + ((i - 1) % 2) * 350, 120 + math.floor((i - 1) / 2) * 76), Size = UDim2.fromOffset(338, 64),
			BackgroundColor3 = if active then Color3.fromRGB(236, 230, 218) else Color3.fromRGB(246, 242, 234) })
		corner(seat, 8)
		frame(seat, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = if not active then Color3.fromRGB(220, 214, 204) elseif m then (if i % 2 == 1 then BLUE else ORANGE) else Color3.fromRGB(200, 194, 184) })
		local label = if not active then "—" elseif m then (if m.isHost then "★ " else "") .. Upper(m.name) .. (if m.userId == lp.UserId then "  (TÚ)" else "") else "ESPERANDO...  (BOT SI NADIE ENTRA)"
		text(seat, { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -30, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextSize = if m then 22 else 16,
			TextColor3 = if m then INK else MUTED, FontFace = if m then OSWALD else OSWALD_REG, TextTruncate = Enum.TextTruncate.AtEnd, Text = label })
	end

	-- host settings
	local y = 290
	text(p, { Position = UDim2.fromOffset(38, y), Size = UDim2.fromOffset(300, 20), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 15, TextColor3 = MUTED, Text = "MODO" })
	for i, mode in { "1v1", "2v2" } do
		local on = room.mode == mode
		local b = button(p, { Position = UDim2.fromOffset(36 + (i - 1) * 130, y + 24), Size = UDim2.fromOffset(120, 44) }, string.upper(mode), if on then BLUE else Color3.fromRGB(228, 222, 210), if on then WHITE else INK)
		b.Name = "Mode_" .. mode
		b.MouseButton1Click:Connect(function()
			if not isHost then toast("SOLO EL ANFITRIÓN CAMBIA EL MODO") return end
			ask("setRoomMode", mode)
		end)
	end
	text(p, { Position = UDim2.fromOffset(330, y), Size = UDim2.fromOffset(300, 20), TextXAlignment = Enum.TextXAlignment.Left, TextSize = 15, TextColor3 = MUTED, Text = "BOTS DE RELLENO" })
	for i, d in { { "noob", "NOVATO" }, { "pro", "PRO" }, { "freestyler", "FREESTYLER" } } do
		local on = botDifficulty == d[1]
		local b = button(p, { Position = UDim2.fromOffset(328 + (i - 1) * 132, y + 24), Size = UDim2.fromOffset(124, 44) }, d[2], if on then INK else Color3.fromRGB(228, 222, 210), if on then WHITE else INK)
		b.Name = "Diff_" .. d[1]
		b.MouseButton1Click:Connect(function()
			botDifficulty = d[1]
			showRoom(state)
		end)
	end

	-- actions
	local start = button(p, { Position = UDim2.fromOffset(36, 420), Size = UDim2.fromOffset(460, 64) },
		if isHost then "EMPEZAR PARTIDA" else "ESPERANDO AL ANFITRIÓN...", if isHost then Color3.fromRGB(0, 170, 80) else Color3.fromRGB(90, 94, 104))
	start.MouseButton1Click:Connect(function()
		if isHost then ask("startRoom", { difficulty = botDifficulty }) end
	end)
	local leave = button(p, { Position = UDim2.fromOffset(510, 420), Size = UDim2.fromOffset(214, 64) }, "SALIR DE LA SALA", Color3.fromRGB(56, 60, 72), GOLD)
	leave.MouseButton1Click:Connect(function()
		ask("leave")
	end)
	start.Name = "Start"
	leave.Name = "Leave"
	copy.Name = "Copy"
	-- controller: A presses the selected button, B leaves the room
	InputGlyphs.PushPanel(back, function()
		local keep = keepName and p:FindFirstChild(keepName, true)
		return (keep :: any) or (if isHost then start else leave)
	end, function() ask("leave") end)
	if keepName then
		local keep = p:FindFirstChild(keepName, true)
		if keep then InputGlyphs.Focus(keep :: any) end
	end
end

-- the server's word on where we are
function OnlinePlay.Apply(st: any)
	if type(st) ~= "table" then return end
	state = st
	if inMatch then
		clearScreens()
		return
	end
	if st.status == "queue" then
		showQueue(st)
	elseif st.status == "room" then
		showRoom(st)
	else
		clearScreens()
	end
end

-- ---------------------------------------------------------------- entry points (main menu)
local function remember(opts: any?)
	if type(opts) == "table" then
		car.skin = opts.skin or car.skin
		car.hitbox = opts.hitbox or car.hitbox
		if opts.difficulty then botDifficulty = opts.difficulty end
	end
end

-- opts: { mode = "1v1" | "2v2", ranked = bool, difficulty, skin, hitbox }
function OnlinePlay.Queue(opts: any)
	remember(opts)
	ask("queue", { mode = opts.mode, ranked = opts.ranked == true, difficulty = opts.difficulty, skin = car.skin, hitbox = car.hitbox })
end

function OnlinePlay.CreateRoom(opts: any)
	remember(opts)
	ask("createRoom", { mode = opts.mode, skin = car.skin, hitbox = car.hitbox })
end

-- "sl1234", "SL 1234", "sl-1234", "1234" -> "SL-1234" (rooms); "rr1234" -> "RR-1234" (parties). nil if it can't be one.
function OnlinePlay.NormalizeCode(code: string?): string?
	local c = string.upper(string.gsub(code or "", "[%s_%.]", ""))
	if c == "" then return nil end
	local prefix, digits = string.match(c, "^(%a%a)%-?(%d+)$")
	if not prefix then
		digits = string.match(c, "^(%d+)$")
		prefix = "SL"
	end
	if not digits or #digits < 3 or #digits > 6 or (prefix ~= "SL" and prefix ~= "RR") then return nil end
	return prefix .. "-" .. digits
end

-- join a friend's private room (SL-) or party (RR-) by code, from any server. Returns ok, error text.
function OnlinePlay.JoinRoom(code: string, opts: any?): (boolean, string?)
	remember(opts)
	local c = OnlinePlay.NormalizeCode(code)
	if not c then return false, "ESE CÓDIGO NO ES VÁLIDO · EJEMPLO: SL-1234" end
	if string.find(c, "^RR%-") then
		-- a party code: open the party lobby and join it there
		local s = require(RS.Game.MainMenu).LaunchParty()
		if s then s:JoinByCode(c) end
		return true, nil
	end
	local res = ask("joinRoom", { code = c, skin = car.skin, hitbox = car.hitbox })
	if res and res.ok then
		toast("¡DENTRO DE LA SALA " .. c .. "!", BLUE)
		return true, nil
	end
	return false, if res and res.error then Upper(tostring(res.error)) else "NO SE PUDO ENTRAR"
end

function OnlinePlay.Forfeit()
	ask("forfeit")
	MinigameClient.Abandon()
end

function OnlinePlay.State(): any
	return state
end

-- ---------------------------------------------------------------- matches taking the screen
local function returnToMenu()
	local ev = RS.Game:FindFirstChild("ReturnToMenuEvent") :: BindableEvent?
	if ev then
		ev:Fire()
	else
		local MainMenu = require(RS.Game.MainMenu) :: any
		if MainMenu.ReturnToMenu then MainMenu.ReturnToMenu() end
	end
end

-- X cancels matchmaking from anywhere (the pill shows the glyph)
game:GetService("UserInputService").InputBegan:Connect(function(inp, processed)
	if processed or inMatch then return end
	if inp.KeyCode == Enum.KeyCode.ButtonX and refs.queue and state.status == "queue" and not InputGlyphs.PanelOpen() then
		ask("cancel")
	end
end)

function OnlinePlay.Init()
	if initDone then return end
	initDone = true
	MinigameClient.Init()
	local st = Net.Remote("MatchState")
	if st then st.OnClientEvent:Connect(OnlinePlay.Apply) end

	MinigameClient.OnRoundStart(function(round: any)
		if round.minigameId ~= "soccar" then return end
		inMatch = true
		clearScreens()
		-- the match takes over from the menu
		pcall(function()
			local MC = require(RS.Game.MenuCinematic)
			if MC.IsRunning() then MC.Stop() end
		end)
		pcall(function()
			local MainMenu = require(RS.Game.MainMenu)
			MainMenu.CloseModal()
			MainMenu.Hide()
		end)
	end)
	MinigameClient.OnRoundEnd(function()
		if not inMatch then return end
		inMatch = false
		returnToMenu()
		task.delay(0.3, function() OnlinePlay.Apply(state) end) -- back into the room, if we were in one
	end)

	-- arriving from another server with a code: finish the join here
	task.delay(1.5, function()
		local ok, data = pcall(function() return TeleportService:GetLocalPlayerTeleportData() end)
		if not ok or type(data) ~= "table" then return end
		if type(data.joinRoom) == "string" then
			OnlinePlay.JoinRoom(data.joinRoom)
		elseif type(data.joinParty) == "string" then
			OnlinePlay.JoinRoom(data.joinParty)
		end
	end)
	task.spawn(function() ask("state") end)
end

return OnlinePlay
