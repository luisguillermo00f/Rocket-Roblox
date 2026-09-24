--!strict
-- MinigameHud.lua: minimal HUD shared by every Party minigame, in the match HUD's language (cream / ink, Oswald).
--   * loading card: minigame name, one-line rule, who plays with whom
--   * top score line: left score · timer · right score (the view says what goes in each slot)
--   * 3-2-1 / ¡YA!, centre banners for big moments (a point, sudden death), bottom-left toasts for small ones
--   * boost meter bottom-right
--   * results: placements, the round's Party Points and the running totals (awarded by the server)
-- Pure presentation: it shows what the view / server say, it never decides anything.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local MinigameHud = {}

local INK = Color3.fromRGB(18, 18, 20)
local CREAM = Color3.fromRGB(248, 244, 236)
local MUTED = Color3.fromRGB(120, 112, 100)
local GOLD = Color3.fromRGB(255, 196, 64)
local WHITE = Color3.new(1, 1, 1)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)

local gui: ScreenGui? = nil
local refs: { [string]: any } = {}
local anim: { [string]: any } = {}

local function tween(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props):Play()
end

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

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function upper(s: string): string
	local up = string.upper(s)
	for lo, hi in { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" } do
		up = up:gsub(lo, hi)
	end
	return up
end
MinigameHud.Upper = upper

local function clock(sec: number): string
	local s = math.max(0, math.ceil(sec))
	return string.format("%d:%02d", s // 60, s % 60)
end
MinigameHud.Clock = clock

-- ---------------------------------------------------------------- build
function MinigameHud.Open(round: any)
	MinigameHud.Close()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local g = Instance.new("ScreenGui")
	g.Name = "MinigameHud"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 20
	g.Parent = pg
	gui = g
	refs = {}
	anim = { lastSecond = -1, lastLeft = nil, lastRight = nil, go = 0, boostShown = 0 }
	local sc = Instance.new("UIScale")
	sc.Parent = g
	refs.scale = sc

	-- top score line
	local top = frame(g, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 14), Size = UDim2.fromOffset(460, 64), BackgroundTransparency = 1 })
	refs.top = top
	local left = frame(top, { Size = UDim2.fromOffset(170, 64), BackgroundColor3 = CREAM })
	corner(left, 6)
	refs.leftBand = frame(left, { Size = UDim2.new(0, 8, 1, 0), BackgroundColor3 = GOLD })
	corner(refs.leftBand, 3)
	refs.leftLabel = text(left, { Position = UDim2.fromOffset(18, 6), Size = UDim2.new(1, -86, 0, 18), TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	refs.leftSub = text(left, { Position = UDim2.fromOffset(18, 26), Size = UDim2.new(1, -86, 0, 30), TextSize = 14, FontFace = OSWALD_REG, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "" })
	refs.leftValue = text(left, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.fromOffset(64, 64), TextSize = 46, TextXAlignment = Enum.TextXAlignment.Right, Text = "0" })
	refs.leftScale = Instance.new("UIScale"); refs.leftScale.Parent = refs.leftValue

	local mid = frame(top, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(108, 64), BackgroundColor3 = INK })
	corner(mid, 6)
	refs.timer = text(mid, { Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 40), TextSize = 34, TextColor3 = WHITE, Text = "" })
	refs.timerNote = text(mid, { Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 16), TextSize = 12, TextColor3 = GOLD, Text = "" })
	refs.timerScale = Instance.new("UIScale"); refs.timerScale.Parent = refs.timer

	local right = frame(top, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(170, 64), BackgroundColor3 = CREAM })
	corner(right, 6)
	refs.rightBand = frame(right, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 8, 1, 0), BackgroundColor3 = GOLD })
	corner(refs.rightBand, 3)
	refs.rightLabel = text(right, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 6), Size = UDim2.new(1, -86, 0, 18), TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Right, Text = "" })
	refs.rightSub = text(right, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 26), Size = UDim2.new(1, -86, 0, 30), TextSize = 14, FontFace = OSWALD_REG, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Text = "" })
	refs.rightValue = text(right, { Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(64, 64), TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left, Text = "0" })
	refs.rightScale = Instance.new("UIScale"); refs.rightScale.Parent = refs.rightValue

	-- small line under the score (e.g. "LADO A · 1 BOTE")
	refs.info = text(g, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 84), Size = UDim2.fromOffset(460, 26), TextSize = 18, TextColor3 = WHITE, TextStrokeTransparency = 0.5, Text = "" })

	-- centre message (countdown, ¡YA!) and banner (points)
	refs.msg = text(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromOffset(600, 150), TextSize = 120, TextColor3 = WHITE, TextStrokeTransparency = 0.4, Text = "" })
	refs.msgScale = Instance.new("UIScale"); refs.msgScale.Parent = refs.msg
	local banner = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3), Size = UDim2.new(1, 0, 0, 104), BackgroundColor3 = INK, BackgroundTransparency = 1 })
	refs.banner = banner
	refs.bannerBand = frame(banner, { Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = GOLD, BackgroundTransparency = 1 })
	refs.bannerTitle = text(banner, { Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 60), TextSize = 56, TextColor3 = WHITE, TextTransparency = 1, Text = "" })
	refs.bannerSub = text(banner, { Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 26), TextSize = 20, TextColor3 = GOLD, TextTransparency = 1, Text = "" })

	-- toasts (bottom-left)
	local toasts = frame(g, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 28, 1, -28), Size = UDim2.fromOffset(360, 200), BackgroundTransparency = 1 })
	local list = Instance.new("UIListLayout")
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = toasts
	refs.toasts = toasts
	anim.toastOrder = 0

	-- boost (bottom-right)
	local boost = frame(g, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -28, 1, -28), Size = UDim2.fromOffset(120, 64), BackgroundColor3 = INK, BackgroundTransparency = 0.1 })
	corner(boost, 6)
	text(boost, { Position = UDim2.fromOffset(12, 6), Size = UDim2.fromOffset(60, 16), TextSize = 13, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, Text = "TURBO" })
	refs.boostNum = text(boost, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 2), Size = UDim2.fromOffset(70, 40), TextSize = 34, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right, Text = "0" })
	local track = frame(boost, { Position = UDim2.new(0, 12, 1, -16), Size = UDim2.new(1, -24, 0, 6), BackgroundColor3 = Color3.fromRGB(48, 48, 54) })
	corner(track, 3)
	refs.boostFill = frame(track, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD })
	corner(refs.boostFill, 3)
	refs.boost = boost

	-- loading card
	MinigameHud.LoadingCard(round)
	refs.top.Visible = false
	refs.boost.Visible = round.me ~= nil
end

function MinigameHud.Close()
	if gui then gui:Destroy() end
	gui = nil
	refs = {}
end

-- ---------------------------------------------------------------- loading card
function MinigameHud.LoadingCard(round: any)
	if not gui then return end
	local card = frame(gui, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(640, 300), BackgroundColor3 = CREAM })
	corner(card, 8)
	refs.card = card
	frame(card, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = GOLD })
	text(card, { Position = UDim2.fromOffset(36, 28), Size = UDim2.new(1, -72, 0, 18), TextSize = 16, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, Text = "MINIJUEGO " .. tostring(round.roundId or "") })
	text(card, { Position = UDim2.fromOffset(34, 46), Size = UDim2.new(1, -72, 0, 64), TextSize = 58, TextXAlignment = Enum.TextXAlignment.Left, Text = upper(round.displayName or "") })
	text(card, { Position = UDim2.fromOffset(36, 112), Size = UDim2.new(1, -72, 0, 48), TextSize = 19, FontFace = OSWALD_REG, TextColor3 = MUTED, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = round.description or "" })
	-- who plays: team columns if the view has teams, a single row otherwise
	local teams = round.view and round.view.TeamNames and round.view:TeamNames() or nil
	local rows = frame(card, { Position = UDim2.fromOffset(36, 176), Size = UDim2.new(1, -72, 0, 96), BackgroundTransparency = 1 })
	local cols = teams or { { label = "JUGADORES", color = GOLD, members = round.participants } }
	for i, col in cols do
		local w = 1 / #cols
		local c = frame(rows, { Position = UDim2.fromScale((i - 1) * w, 0), Size = UDim2.new(w, -12, 1, 0), BackgroundColor3 = Color3.fromRGB(236, 230, 218) })
		corner(c, 6)
		frame(c, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = col.color })
		text(c, { Position = UDim2.fromOffset(16, 6), Size = UDim2.new(1, -24, 0, 20), TextSize = 16, TextColor3 = col.color, TextXAlignment = Enum.TextXAlignment.Left, Text = col.label })
		local names = {}
		for _, p in col.members do
			local tag = if p == round.me then "  (TÚ)" elseif p.isBot then "  · BOT" else ""
			table.insert(names, upper(p.name or "?") .. tag)
		end
		text(c, { Position = UDim2.fromOffset(16, 28), Size = UDim2.new(1, -24, 1, -34), TextSize = 17, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = table.concat(names, "\n") })
	end
	card.Position = UDim2.fromScale(0.5, 0.56)
	tween(card, 0.5, { Position = UDim2.fromScale(0.5, 0.5) })
end

local function dropCard()
	local card = refs.card
	if not card then return end
	refs.card = nil
	tween(card, 0.35, { Position = UDim2.fromScale(0.5, 0.44) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, d in card:GetDescendants() do
		if d:IsA("TextLabel") then tween(d, 0.3, { TextTransparency = 1 }) end
		if d:IsA("Frame") then tween(d, 0.3, { BackgroundTransparency = 1 }) end
	end
	tween(card, 0.3, { BackgroundTransparency = 1 })
	task.delay(0.4, function() card:Destroy() end)
end

-- ---------------------------------------------------------------- phases
function MinigameHud.Phase(round: any, state: string)
	if not gui then return end
	if state == "COUNTDOWN" then
		dropCard()
		refs.top.Visible = true
		refs.top.Position = UDim2.new(0.5, 0, 0, -80)
		tween(refs.top, 0.5, { Position = UDim2.new(0.5, 0, 0, 14) })
	elseif state == "ACTIVE" then
		anim.go = 0.7
	elseif state == "ENDING" then
		MinigameHud.Message("¡FIN!", GOLD)
	end
end

local function sfx(): any
	local ok, m = pcall(function() return require(game:GetService("ReplicatedStorage").Game.Sounds) end)
	return if ok then m else nil
end

function MinigameHud.Message(str: string, color: Color3?)
	if not gui then return end
	local S = sfx()
	if S then pcall(S.Message, str) end
	refs.msg.Text = str
	refs.msg.TextColor3 = color or WHITE
	refs.msg.TextTransparency = 0
	refs.msg.TextStrokeTransparency = 0.4
	refs.msgScale.Scale = 1.6
	tween(refs.msgScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	anim.msgHold = 0.8
end

-- big centre band for a moment that matters (a point, sudden death)
function MinigameHud.Banner(title: string, sub: string?, color: Color3?)
	if not gui then return end
	local S = sfx()
	if S then pcall(S.Banner) end
	local c = color or GOLD
	refs.bannerTitle.Text = title
	refs.bannerSub.Text = sub or ""
	refs.bannerBand.BackgroundColor3 = c
	refs.bannerSub.TextColor3 = c
	refs.banner.BackgroundTransparency = 0.25
	refs.bannerBand.BackgroundTransparency = 0
	refs.bannerTitle.TextTransparency = 0
	refs.bannerSub.TextTransparency = 0
	refs.banner.Size = UDim2.new(1, 0, 0, 0)
	tween(refs.banner, 0.3, { Size = UDim2.new(1, 0, 0, 104) }, Enum.EasingStyle.Back)
	anim.bannerId = (anim.bannerId or 0) + 1
	local id = anim.bannerId
	task.delay(1.5, function()
		if not gui or anim.bannerId ~= id then return end
		tween(refs.banner, 0.35, { BackgroundTransparency = 1 })
		tween(refs.bannerBand, 0.35, { BackgroundTransparency = 1 })
		tween(refs.bannerTitle, 0.35, { TextTransparency = 1 })
		tween(refs.bannerSub, 0.35, { TextTransparency = 1 })
	end)
end

function MinigameHud.Toast(str: string, color: Color3?)
	if not gui then return end
	anim.toastOrder += 1
	local row = frame(refs.toasts, { Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = INK, BackgroundTransparency = 0.15, LayoutOrder = anim.toastOrder })
	corner(row, 5)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14); pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = row
	frame(row, { Position = UDim2.fromOffset(-14, 0), Size = UDim2.new(0, 5, 1, 0), BackgroundColor3 = color or GOLD })
	local l = text(row, { Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextSize = 18, TextColor3 = WHITE, Text = str })
	local sc = Instance.new("UIScale"); sc.Scale = 0.6; sc.Parent = row
	tween(sc, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(2.4, function()
		if row.Parent then
			tween(row, 0.3, { BackgroundTransparency = 1 })
			tween(l, 0.3, { TextTransparency = 1 })
			task.delay(0.32, function() row:Destroy() end)
		end
	end)
	local kids = {}
	for _, k in refs.toasts:GetChildren() do if k:IsA("Frame") then table.insert(kids, k) end end
	if #kids > 4 then
		table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		kids[1]:Destroy()
	end
end

local function punch(sc: UIScale)
	sc.Scale = 1.5
	tween(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- ---------------------------------------------------------------- per frame
function MinigameHud.Update(round: any, dt: number)
	if not gui then return end
	local cam = workspace.CurrentCamera
	refs.scale.Scale = math.clamp(cam.ViewportSize.Y / 1080, 0.6, 1.4)
	local hs = round.view and round.view.HudState and round.view:HudState() or {}

	-- score slots
	local L, R = hs.left, hs.right
	if L then
		refs.leftLabel.Text = L.label or ""
		refs.leftSub.Text = L.sub or ""
		refs.leftBand.BackgroundColor3 = L.color or GOLD
		local v = tostring(L.value or "")
		if refs.leftValue.Text ~= v then
			refs.leftValue.Text = v
			if anim.lastLeft ~= nil then punch(refs.leftScale) end
		end
		anim.lastLeft = v
	end
	if R then
		refs.rightLabel.Text = R.label or ""
		refs.rightSub.Text = R.sub or ""
		refs.rightBand.BackgroundColor3 = R.color or GOLD
		local v = tostring(R.value or "")
		if refs.rightValue.Text ~= v then
			refs.rightValue.Text = v
			if anim.lastRight ~= nil then punch(refs.rightScale) end
		end
		anim.lastRight = v
	end

	-- timer: the view's clock during play, the phase clock otherwise
	local st = round.state
	local tText, note, urgent = "", hs.timerNote or "", false
	if st == "ACTIVE" then
		if hs.timerText then
			tText = hs.timerText
		else
			local left = if hs.timeLeft then hs.timeLeft else round:PhaseLeft()
			tText = clock(left)
			urgent = left <= 10
			local sec = math.ceil(left)
			if urgent and sec ~= anim.lastSecond and sec > 0 then punch(refs.timerScale) end
			anim.lastSecond = sec
		end
	elseif st == "COUNTDOWN" or st == "LOADING" then
		tText = clock(hs.timeTotal or 60)
	else
		tText = "0:00"
	end
	refs.timer.Text = tText
	refs.timer.TextColor3 = if urgent then Color3.fromRGB(255, 120, 90) else WHITE
	refs.timerNote.Text = note
	refs.info.Text = hs.info or ""

	-- countdown / go
	if st == "COUNTDOWN" then
		local n = math.max(1, math.ceil(round:PhaseLeft()))
		if refs.msg.Text ~= tostring(n) then MinigameHud.Message(tostring(n)) end
		anim.msgHold = 0.5
	elseif anim.go > 0 then
		if refs.msg.Text ~= "¡YA!" then MinigameHud.Message("¡YA!", GOLD) end
		anim.go -= dt
	end
	if anim.msgHold then
		anim.msgHold -= dt
		if anim.msgHold <= 0 then
			anim.msgHold = nil
			tween(refs.msg, 0.25, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end

	-- boost
	if round.myCar then
		local b = round.myCar.boost or 0
		anim.boostShown += (b - anim.boostShown) * (1 - math.exp(-14 * dt))
		refs.boostNum.Text = tostring(math.floor(anim.boostShown + 0.5))
		refs.boostFill.Size = UDim2.fromScale(math.clamp(anim.boostShown / 100, 0, 1), 1)
	end
end

-- ---------------------------------------------------------------- results
function MinigameHud.Results(round: any, data: any)
	if not gui then return end
	if refs.results then refs.results:Destroy() end
	local root = frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, ZIndex = 10 })
	refs.results = root
	tween(root, 0.4, { BackgroundTransparency = 0.45 })
	local rows = data.rows or {}
	local h = 190 + #rows * 66
	do
		local S = sfx()
		local first = false
		for _, r in rows do
			if r.userId == Players.LocalPlayer.UserId and r.placement == 1 then first = true end
		end
		if S then pcall(S.Result, first) end
	end
	local card = frame(root, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.56), Size = UDim2.fromOffset(700, h), BackgroundColor3 = CREAM, ZIndex = 11 })
	corner(card, 8)
	tween(card, 0.5, { Position = UDim2.fromScale(0.5, 0.5) })
	frame(card, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = GOLD, ZIndex = 12 })
	local summary = data.summary or {}
	text(card, { Position = UDim2.fromOffset(36, 24), Size = UDim2.new(1, -72, 0, 18), TextSize = 16, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, Text = upper(round.displayName or ""), ZIndex = 12 })
	text(card, { Position = UDim2.fromOffset(34, 42), Size = UDim2.new(1, -72, 0, 60), TextSize = 54, TextXAlignment = Enum.TextXAlignment.Left, Text = upper(summary.title or "RESULTADOS"), ZIndex = 12 })
	text(card, { Position = UDim2.fromOffset(36, 102), Size = UDim2.new(1, -72, 0, 24), TextSize = 18, FontFace = OSWALD_REG, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, Text = upper(summary.detail or ""), ZIndex = 12 })
	-- header
	local hy = 140
	text(card, { Position = UDim2.new(1, -250, 0, hy), Size = UDim2.fromOffset(90, 18), TextSize = 13, TextColor3 = MUTED, Text = "PUNTOS FIESTA", ZIndex = 12 })
	text(card, { Position = UDim2.new(1, -140, 0, hy), Size = UDim2.fromOffset(100, 18), TextSize = 13, TextColor3 = MUTED, Text = "TOTAL", ZIndex = 12 })
	local medal = { GOLD, Color3.fromRGB(190, 196, 206), Color3.fromRGB(206, 140, 92), Color3.fromRGB(150, 150, 156) }
	local lp = Players.LocalPlayer
	for i, r in rows do
		local y = hy + 26 + (i - 1) * 66
		local mine = r.userId == lp.UserId
		local row = frame(card, { Position = UDim2.fromOffset(28, y), Size = UDim2.new(1, -56, 0, 58), BackgroundColor3 = if mine then Color3.fromRGB(255, 240, 200) else Color3.fromRGB(238, 232, 220), ZIndex = 12 })
		corner(row, 6)
		local badge = frame(row, { Position = UDim2.fromOffset(10, 9), Size = UDim2.fromOffset(40, 40), BackgroundColor3 = medal[r.placement] or MUTED, ZIndex = 13 })
		corner(badge, 20)
		text(badge, { Size = UDim2.fromScale(1, 1), TextSize = 22, TextColor3 = INK, Text = tostring(r.placement), ZIndex = 14 })
		local tc = if r.team == 0 then Color3.fromRGB(38, 140, 255) elseif r.team == 1 then Color3.fromRGB(255, 132, 36) else INK
		text(row, { Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -330, 1, 0), TextSize = 24, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = upper(r.name or "?") .. (if mine then "  (TÚ)" else ""), ZIndex = 13 })
		frame(row, { Position = UDim2.new(1, -262, 0, 14), Size = UDim2.fromOffset(4, 30), BackgroundColor3 = tc, ZIndex = 13 })
		local pp = text(row, { Position = UDim2.new(1, -250, 0, 0), Size = UDim2.fromOffset(90, 58), TextSize = 28, TextColor3 = Color3.fromRGB(0, 150, 80), Text = "+0", ZIndex = 13 })
		text(row, { Position = UDim2.new(1, -140, 0, 0), Size = UDim2.fromOffset(100, 58), TextSize = 28, Text = tostring(r.totalPoints or 0), ZIndex = 13 })
		-- count the Party Points up, row by row
		task.delay(0.45 + i * 0.18, function()
			local target = r.partyPoints or 0
			local t0 = os.clock()
			while pp.Parent and os.clock() - t0 < 0.5 do
				pp.Text = "+" .. tostring(math.floor(target * (os.clock() - t0) / 0.5 + 0.5))
				task.wait()
			end
			if pp.Parent then pp.Text = "+" .. tostring(target) end
		end)
	end
	text(card, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.new(1, -72, 0, 18), TextSize = 14, TextColor3 = MUTED, Text = "VOLVIENDO AL LOBBY…", ZIndex = 12 })
end

return MinigameHud
