--!strict
-- MainMenu.lua: main menu, pause menu and end-of-match screen. Same visual language as the HUD: cream panels
-- with bracket corners, black key chips, Oswald Bold. The main menu also shows the player's profile card (Roblox
-- avatar, level, XP, Créditos) that opens a full career-stats panel (P). Screens in their own modules (DESAFÍOS...)
-- reuse these helpers through MainMenu.UI.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local MainMenu = {}
MainMenu.ReturnToMenu = nil :: (() -> ())?

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local INK = Color3.fromRGB(18, 18, 20)
local CREAM = Color3.fromRGB(248, 244, 236)
local CHIP = Color3.fromRGB(12, 12, 14)
local WHITE = Color3.fromRGB(255, 255, 255)
local MUTED = Color3.fromRGB(120, 112, 100)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)

local Progression = require(script.Parent.Progression)
local InputGlyphs = require(script.Parent.InputGlyphs)

local gui: ScreenGui? = nil
local overlay: ScreenGui? = nil
local profileGui: ScreenGui? = nil
local profileData: { [string]: any }? = nil
local shownXp: number? = nil -- XP the card last displayed (to animate gains)
local card: { [string]: any }? = nil
local GOLD = Color3.fromRGB(255, 196, 64)
local currentOpenPlay: (() -> ())? = nil
local shownCredits: number? = nil -- credits the card last displayed (to animate gains)
local overlayPanel: Frame? = nil -- the open Modal's panel (the server's reward is shown under it)

local function frame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = WHITE
	for k, v in props do (f :: any)[k] = v end
	f.Parent = parent
	return f
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = OSWALD
	l.TextColor3 = INK
	l.TextSize = 24
	for k, v in props do (l :: any)[k] = v end
	l.Parent = parent
	return l
end

local function button(parent: Instance, props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Text = ""
	b.BackgroundColor3 = CREAM
	for k, v in props do (b :: any)[k] = v end
	b.Parent = parent
	return b
end

local function brackets(parent: GuiObject, color: Color3, inset: number, len: number, thick: number)
	for _, c in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local ax, ay = c[1], c[2]
		local px = if ax == 0 then inset else -inset
		local py = if ay == 0 then inset else -inset
		frame(parent, { AnchorPoint = Vector2.new(ax, ay), Position = UDim2.new(ax, px, ay, py), Size = UDim2.fromOffset(len, thick), BackgroundColor3 = color, ZIndex = 5 })
		frame(parent, { AnchorPoint = Vector2.new(ax, ay), Position = UDim2.new(ax, px, ay, py), Size = UDim2.fromOffset(thick, len), BackgroundColor3 = color, ZIndex = 5 })
	end
end

-- key chip; keys with a controller equivalent (ENTER, ESC, F, M, R, P) show that button's glyph on a gamepad
local function chip(parent: Instance, key: string, dark: boolean, anchorRight: boolean?)
	local w = 16 + #key * 12
	local c = frame(parent, {
		AnchorPoint = if anchorRight == false then Vector2.new(0, 0.5) else Vector2.new(1, 0.5),
		Position = if anchorRight == false then UDim2.new(0, 10, 0.5, 0) else UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(math.max(w, 30), 30),
		BackgroundColor3 = if dark then CHIP else WHITE,
		ZIndex = 4,
	})
	local label = text(c, { Size = UDim2.fromScale(1, 1), Text = key, TextSize = 17, TextColor3 = if dark then WHITE else INK, ZIndex = 5 })
	local action = InputGlyphs.ActionForKey(key)
	if action then
		local pads = InputGlyphs.ACTIONS[action].pad
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(1, 1)
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = 5
		pcall(function() img.Image = UIS:GetImageForKeyCode(pads[1]) end)
		img.Parent = c
		-- the glyphs are white buttons: on a light button they sit on a dark disc so they don't wash out
		local disc = Instance.new("UICorner")
		disc.CornerRadius = UDim.new(0.5, 0)
		local function draw(m: string)
			local pad = m == "gamepad" and img.Image ~= ""
			img.Visible = pad
			label.Visible = not pad
			c.BackgroundTransparency = if pad and not dark then 1 else 0
			disc.Parent = if pad and dark then c else nil
			img.Size = if pad and dark then UDim2.fromScale(0.84, 0.84) else UDim2.fromScale(1, 1)
			c.Size = if pad then UDim2.fromOffset(38, 38) else UDim2.fromOffset(math.max(w, 30), 30)
		end
		draw(InputGlyphs.Mode())
		c.Destroying:Connect(InputGlyphs.OnModeChanged(draw))
	end
	return c
end

local function newGui(name: string, order: number): ScreenGui
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild(name)
	if old then old:Destroy() end
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = order
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = pg
	local scale = Instance.new("UIScale")
	scale.Parent = g
	local function fit()
		local vp = workspace.CurrentCamera.ViewportSize
		scale.Scale = math.clamp(math.min(vp.Y / 1080, vp.X / 1920), 0.5, 1.3)
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	return g
end

-- Segmented control: returns setter
local function segmented(parent: Instance, y: number, title: string, options: { { id: string, label: string } }, onPick: (string) -> ())
	local titleLabel = text(parent, { Position = UDim2.fromOffset(28, y), Size = UDim2.new(1, -56, 0, 22), Text = title, TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
	local row = frame(parent, { Position = UDim2.fromOffset(28, y + 26), Size = UDim2.new(1, -56, 0, 44), BackgroundTransparency = 1 })
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 6)
	list.Parent = row
	local buttons = {}
	local n = #options
	for _, o in options do
		local b = button(row, { Size = UDim2.new(1 / n, -6 * (n - 1) / n, 1, 0), BackgroundColor3 = Color3.fromRGB(232, 226, 214) })
		local l = text(b, { Size = UDim2.fromScale(1, 1), Text = o.label, TextSize = if #o.label > 9 then 16 else 20 })
		buttons[o.id] = { b = b, l = l }
		b.MouseButton1Click:Connect(function() onPick(o.id) end)
	end
	local enabled = true
	local function set(id: string)
		for k, v in buttons do
			local on = k == id
			v.b.BackgroundColor3 = if on then CHIP else Color3.fromRGB(232, 226, 214)
			v.l.TextColor3 = if on then WHITE else INK
		end
	end
	local function setEnabled(on: boolean)
		enabled = on
		row.Visible = true
		for _, v in buttons do
			v.b.Active = on
			v.l.TextTransparency = if on then 0 else 0.6
			v.b.BackgroundTransparency = if on then 0 else 0.5
		end
	end
	local function setVisible(on: boolean)
		row.Visible = on
		titleLabel.Visible = on
	end
	return set, setEnabled, setVisible
end

local DIFF_TEXT = {
	noob = "Reacciona tarde, sin turbo y sin saltos a la pelota. Para aprender a moverte.",
	pro = "Turbo, flips, tiros de salto y aéreos hasta media altura. Rota en equipo.",
	freestyler = "Reacción casi instantánea, aéreos a cualquier altura, air roll y dodges en el aire.",
}

local function fmtInt(n: number): string
	local str = tostring(math.floor(n))
	local out = str:reverse():gsub("(%d%d%d)", "%1."):reverse()
	if out:sub(1, 1) == "." then out = out:sub(2) end
	return out
end

local function thumb(kind: Enum.ThumbnailType, size: Enum.ThumbnailSize, img: ImageLabel)
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(Players.LocalPlayer.UserId, kind, size)
		end)
		if ok and img.Parent then
			img.Image = content
			img.ImageTransparency = 1
			TweenService:Create(img, TweenInfo.new(0.3), { ImageTransparency = 0 }):Play()
		end
	end)
end

local function countUp(label: TextLabel, target: number, delay: number, suffix: string?)
	local v = Instance.new("NumberValue")
	v.Value = 0
	label.Text = "0" .. (suffix or "")
	v.Changed:Connect(function(x) label.Text = fmtInt(x) .. (suffix or "") end)
	task.delay(delay, function()
		local tw = TweenService:Create(v, TweenInfo.new(0.7, Enum.EasingStyle.Quart), { Value = target })
		tw:Play()
		tw.Completed:Connect(function() v:Destroy() end)
	end)
end

local function corner(parent: Instance, radius: UDim?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 6)
	c.Parent = parent
	return c
end

local function tween(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quart), props)
	tw:Play()
	return tw
end

-- Créditos icon: a small gold diamond (a rotated square; no font glyph needed)
local function gem(parent: Instance, props: { [string]: any }): Frame
	local g = frame(parent, { Size = UDim2.fromOffset(12, 12), BackgroundColor3 = GOLD, Rotation = 45 })
	for k, v in props do (g :: any)[k] = v end
	return g
end

-- shared look for the screens that live in their own modules (ChallengesScreen, GarageScreen, ShopScreen...)
MainMenu.UI = {
	frame = frame, text = text, button = button, brackets = brackets, chip = chip, newGui = newGui, corner = corner,
	tween = tween, gem = gem, fmtInt = fmtInt, countUp = countUp,
	BLUE = BLUE, ORANGE = ORANGE, INK = INK, CREAM = CREAM, CHIP = CHIP, WHITE = WHITE, MUTED = MUTED, GOLD = GOLD,
	PANEL = Color3.fromRGB(236, 230, 218), BAR = Color3.fromRGB(232, 226, 214), EDGE = Color3.fromRGB(64, 58, 52),
	OSWALD = OSWALD, OSWALD_REG = OSWALD_REG,
}

-- Profile chip (top-right): round avatar, name, level, credits and a hairline XP bar. Opens the full profile (P).
local function buildCard(g: ScreenGui)
	local lp = Players.LocalPlayer
	local c = button(g, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -56, 0, 74), Size = UDim2.fromOffset(560, 96), BackgroundTransparency = 1 })
	local av = frame(c, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(88, 88), BackgroundColor3 = INK, BackgroundTransparency = 0.25 })
	local ac = Instance.new("UICorner"); ac.CornerRadius = UDim.new(0.5, 0); ac.Parent = av
	local ring = Instance.new("UIStroke"); ring.Color = WHITE; ring.Transparency = 0.55; ring.Thickness = 1.5; ring.Parent = av
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Parent = av
	local ic = Instance.new("UICorner"); ic.CornerRadius = UDim.new(0.5, 0); ic.Parent = img
	thumb(Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150, img)
	text(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -104, 0, 2), Size = UDim2.fromOffset(450, 48), Text = string.upper(lp.DisplayName), TextSize = 44, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd })
	local lvl = text(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -104, 0, 52), Size = UDim2.fromOffset(110, 24), Text = "NIVEL 1", TextSize = 22, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right })
	local badgeScale = Instance.new("UIScale"); badgeScale.Parent = lvl
	local track = frame(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -226, 0, 63), Size = UDim2.fromOffset(170, 3), BackgroundColor3 = WHITE, BackgroundTransparency = 0.75 })
	local fill = frame(track, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD })
	local xpText = text(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -104, 0, 76), Size = UDim2.fromOffset(260, 18), Text = "", TextSize = 16, TextColor3 = WHITE, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Right, FontFace = OSWALD_REG })
	local levelUp = text(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -70, 1, 6), Size = UDim2.fromOffset(320, 22), Text = "", TextSize = 18, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Right })
	-- Créditos: "1.250 ◆" left of the XP bar
	local credits = text(c, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -424, 0, 52), Size = UDim2.fromOffset(140, 24), Text = "0", TextSize = 22, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right })
	gem(c, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -410, 0, 64) })
	c.MouseButton1Click:Connect(function() MainMenu.OpenProfile() end)
	card = { root = c, lvl = lvl, fill = fill, xpText = xpText, badgeScale = badgeScale, levelUp = levelUp, credits = credits }
end

local function refreshCard(animate: boolean)
	if not card or not profileData then return end
	local xp = profileData.xp or 0
	local fromXp = if animate and shownXp then shownXp else xp
	local fromLevel = Progression.FromXp(fromXp)
	local level, into, need = Progression.FromXp(xp)
	card.lvl.Text = "NIVEL " .. level
	card.xpText.Text = string.format("%s / %s XP", fmtInt(into), fmtInt(need))
	local target = UDim2.fromScale(into / need, 1)
	if animate and xp > fromXp then
		local _, fInto, fNeed = Progression.FromXp(fromXp)
		card.fill.Size = UDim2.fromScale(if level > fromLevel then 0 else fInto / fNeed, 1)
		TweenService:Create(card.fill, TweenInfo.new(0.9, Enum.EasingStyle.Quart), { Size = target }):Play()
		card.levelUp.Text = "+" .. fmtInt(xp - fromXp) .. " XP"
		if level > fromLevel then
			card.levelUp.Text = "¡SUBISTE A NIVEL " .. level .. "!  +" .. fmtInt(xp - fromXp) .. " XP"
			card.badgeScale.Scale = 1.6
			TweenService:Create(card.badgeScale, TweenInfo.new(0.6, Enum.EasingStyle.Elastic), { Scale = 1 }):Play()
		end
		card.levelUp.TextTransparency = 0
		task.delay(3, function()
			if card and card.levelUp.Parent then
				TweenService:Create(card.levelUp, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			end
		end)
	else
		card.fill.Size = target
	end
	shownXp = xp
	-- credits count up from what the card showed last
	local credits = profileData.credits or 0
	local from = if animate and shownCredits then shownCredits else credits
	if credits ~= from then
		local v = Instance.new("NumberValue")
		v.Value = from
		local label = card.credits
		v.Changed:Connect(function(x) label.Text = fmtInt(x) end)
		local tw = TweenService:Create(v, TweenInfo.new(0.9, Enum.EasingStyle.Quart), { Value = credits })
		tw:Play()
		tw.Completed:Connect(function() v:Destroy() end)
	else
		card.credits.Text = fmtInt(credits)
	end
	shownCredits = credits
end

-- data from the server profile (see ServerScriptService.ProfileService)
function MainMenu.SetProfile(data: { [string]: any })
	profileData = data
	refreshCard(true)
	-- one-time notice from the profile migration (credits for the levels reached before the economy existed)
	local n = data.notice
	local c = card
	if c and type(n) == "table" and (tonumber(n.welcomeBonus) or 0) > 0 then
		c.levelUp.Text = "BONO DE BIENVENIDA  +" .. fmtInt(n.welcomeBonus) .. " CRÉDITOS"
		c.levelUp.TextTransparency = 0
		task.delay(8, function()
			if c.levelUp.Parent then
				TweenService:Create(c.levelUp, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			end
		end)
	end
end

function MainMenu.CloseProfile()
	if profileGui then
		profileGui:Destroy()
		profileGui = nil
	end
end

function MainMenu.OpenProfile()
	MainMenu.CloseProfile()
	local d = profileData or {}
	local g = newGui("ProfileModal", 40)
	profileGui = g
	local back = button(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, Selectable = false })
	back.MouseButton1Click:Connect(MainMenu.CloseProfile)
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1160, 660), BackgroundColor3 = CREAM })
	brackets(p, Color3.fromRGB(64, 58, 52), 10, 18, 3)
	local ps = Instance.new("UIScale"); ps.Scale = 0.94; ps.Parent = p
	TweenService:Create(ps, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()

	-- left: full-body avatar on a dark stage
	local left = frame(p, { Size = UDim2.new(0, 380, 1, 0), BackgroundColor3 = INK })
	local lg = Instance.new("UIGradient")
	lg.Color = ColorSequence.new(Color3.fromRGB(34, 40, 58), Color3.fromRGB(14, 14, 18))
	lg.Rotation = 90
	lg.Parent = left
	frame(left, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 350), Size = UDim2.fromOffset(260, 8), BackgroundColor3 = BLUE, BackgroundTransparency = 0.2 })
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0)
	img.Position = UDim2.new(0.5, 0, 0, 24)
	img.Size = UDim2.fromOffset(330, 330)
	img.Parent = left
	thumb(Enum.ThumbnailType.AvatarThumbnail, Enum.ThumbnailSize.Size420x420, img)
	local lp = Players.LocalPlayer
	text(left, { Position = UDim2.fromOffset(0, 376), Size = UDim2.new(1, 0, 0, 50), Text = string.upper(lp.DisplayName), TextSize = 42, TextColor3 = WHITE, TextTruncate = Enum.TextTruncate.AtEnd })
	text(left, { Position = UDim2.fromOffset(0, 424), Size = UDim2.new(1, 0, 0, 22), Text = "@" .. lp.Name, TextSize = 18, TextColor3 = Color3.fromRGB(170, 176, 190), FontFace = OSWALD_REG })
	local level, into, need = Progression.FromXp(d.xp or 0)
	local lb = frame(left, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 468), Size = UDim2.fromOffset(170, 52), BackgroundColor3 = GOLD })
	text(lb, { Size = UDim2.fromScale(1, 1), Text = "NIVEL " .. level, TextSize = 32 })
	local lbs = Instance.new("UIScale"); lbs.Scale = 1.4; lbs.Parent = lb
	TweenService:Create(lbs, TweenInfo.new(0.6, Enum.EasingStyle.Elastic), { Scale = 1 }):Play()
	local track = frame(left, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 546), Size = UDim2.fromOffset(300, 12), BackgroundColor3 = Color3.fromRGB(50, 54, 66) })
	local fill = frame(track, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD })
	TweenService:Create(fill, TweenInfo.new(0.9, Enum.EasingStyle.Quart), { Size = UDim2.fromScale(into / need, 1) }):Play()
	text(left, { Position = UDim2.fromOffset(0, 564), Size = UDim2.new(1, 0, 0, 22), Text = string.format("%s / %s XP  ·  %s XP TOTAL", fmtInt(into), fmtInt(need), fmtInt(d.xp or 0)), TextSize = 16, TextColor3 = Color3.fromRGB(190, 194, 206), FontFace = OSWALD_REG })
	text(left, { Position = UDim2.fromOffset(0, 600), Size = UDim2.new(1, -24, 0, 30), Text = fmtInt((d :: any).credits or 0) .. " CRÉDITOS", TextSize = 26, TextColor3 = GOLD })
	gem(left, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -44, 0, 615) })

	-- right: career stats grid
	text(p, { Position = UDim2.fromOffset(420, 24), Size = UDim2.fromOffset(500, 50), Text = "PERFIL", TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left })
	text(p, { Position = UDim2.fromOffset(422, 72), Size = UDim2.fromOffset(700, 22), Text = "ESTADÍSTICAS DE CARRERA · PARTIDOS 1V1 Y 2V2 CONTRA BOTS", TextSize = 16, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
	local matches = d.matches or 0
	local tiles = {
		{ "PARTIDOS", matches }, { "VICTORIAS", d.wins or 0, BLUE }, { "DERROTAS", d.losses or 0, ORANGE }, { "% VICTORIAS", if matches > 0 then math.floor((d.wins or 0) / matches * 100) else 0, nil, "%" },
		{ "GOLES", d.goals or 0 }, { "ASISTENCIAS", d.assists or 0 }, { "ATAJADAS", d.saves or 0 }, { "TIROS A PUERTA", d.shots or 0 },
		{ "DEMOLICIONES", d.demos or 0 }, { "GOLPES AÉREOS", d.aerials or 0 }, { "TIRO MÁS FUERTE", d.bestKmh or 0, GOLD, " KM/H" }, { "MEJOR RACHA", d.bestStreak or 0, nil, " W" },
		{ "PINCHES", d.pinches or 0, GOLD }, { "PINCH MÁS FUERTE", d.bestPinchKmh or 0, GOLD, " KM/H" }, { "ATAJADAS ÉPICAS", d.epicSaves or 0 }, { "PUNTOS TOTALES", d.points or 0 },
	}
	for i, t in tiles do
		local col, row = (i - 1) % 4, (i - 1) // 4
		local tile = frame(p, { Position = UDim2.fromOffset(420 + col * 180, 108 + row * 112), Size = UDim2.fromOffset(168, 102), BackgroundColor3 = Color3.fromRGB(236, 230, 218) })
		if t[3] then
			frame(tile, { Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = t[3] })
		end
		local num = text(tile, { Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -20, 0, 52), Text = "0", TextSize = if t[4] == " KM/H" or (t[2] or 0) >= 10000 then 36 else 46, TextXAlignment = Enum.TextXAlignment.Left })
		text(tile, { Position = UDim2.fromOffset(15, 68), Size = UDim2.new(1, -20, 0, 22), Text = t[1], TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
		local ts = Instance.new("UIScale"); ts.Scale = 0.85; ts.Parent = tile
		tile.BackgroundTransparency = 1
		task.delay(0.03 * i, function()
			TweenService:Create(ts, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Scale = 1 }):Play()
			TweenService:Create(tile, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
		end)
		countUp(num, t[2], 0.1 + 0.03 * i, t[4])
	end
	local note = if d.persistent == false then "Sesión sin guardado en la nube (en Studio activa Game Settings › Security › API Services)." elseif profileData == nil then "Cargando perfil…" else "Guardado en la nube · se actualiza al terminar cada partido."
	text(p, { Position = UDim2.fromOffset(422, 588), Size = UDim2.fromOffset(440, 44), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Text = note, TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
	local close = button(p, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -28, 1, -28), Size = UDim2.fromOffset(250, 64), BackgroundColor3 = CHIP })
	text(close, { Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -100, 1, 0), Text = "CERRAR", TextSize = 28, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	chip(close, "ESC", false)
	close.MouseButton1Click:Connect(MainMenu.CloseProfile)
	local opened = os.clock()
	local conn
	conn = UIS.InputBegan:Connect(function(input)
		local k = input.KeyCode
		if os.clock() - opened < 0.25 then
			return -- the same P press that opened it
		end
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace or k == Enum.KeyCode.P or k == Enum.KeyCode.ButtonB or k == Enum.KeyCode.ButtonY then
			MainMenu.CloseProfile()
		end
	end)
	g.Destroying:Connect(function() conn:Disconnect() end)
end

-- ---------------------------------------------------------------- join a private room / party with a code
-- Big code field focused on open (paste works), accepts sl1234 / SL 1234 / 1234, shows the server's answer inline and
-- stays open on failure. Controller: the field starts selected (A opens the keyboard), B closes.
local joinGui: ScreenGui? = nil
function MainMenu.CloseJoinCode()
	if joinGui then joinGui:Destroy(); joinGui = nil end
end
function MainMenu.OpenJoinCode(opts: { [string]: any }?)
	MainMenu.CloseJoinCode()
	local g = newGui("JoinCode", 45)
	joinGui = g
	local back = button(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Selectable = false })
	back.MouseButton1Click:Connect(MainMenu.CloseJoinCode)
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(660, 350), BackgroundColor3 = CREAM })
	brackets(p, Color3.fromRGB(64, 58, 52), 10, 18, 3)
	frame(p, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = GOLD })
	local ps = Instance.new("UIScale"); ps.Scale = 0.94; ps.Parent = p
	TweenService:Create(ps, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	text(p, { Position = UDim2.fromOffset(36, 28), Size = UDim2.fromOffset(580, 50), Text = "UNIRSE CON CÓDIGO", TextSize = 46, TextXAlignment = Enum.TextXAlignment.Left })
	text(p, { Position = UDim2.fromOffset(38, 80), Size = UDim2.fromOffset(590, 40), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Text = "Pide el código a tu amigo: SL-0000 para una sala privada, RR-0000 para una fiesta. Funciona desde cualquier servidor.",
		TextSize = 17, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
	local box = Instance.new("TextBox")
	box.Position = UDim2.fromOffset(36, 128)
	box.Size = UDim2.fromOffset(588, 76)
	box.BackgroundColor3 = INK
	box.BorderSizePixel = 0
	box.FontFace = OSWALD
	box.TextSize = 44
	box.TextColor3 = WHITE
	box.PlaceholderText = "SL-0000"
	box.PlaceholderColor3 = Color3.fromRGB(110, 110, 120)
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = p
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 8); bc.Parent = box
	local status = text(p, { Position = UDim2.fromOffset(38, 210), Size = UDim2.fromOffset(588, 24), Text = "", TextSize = 17, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Left })
	local joinB = button(p, { Position = UDim2.fromOffset(36, 252), Size = UDim2.fromOffset(372, 64), BackgroundColor3 = BLUE })
	text(joinB, { Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -100, 1, 0), Text = "UNIRSE", TextSize = 28, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	chip(joinB, "ENTER", false)
	local backB = button(p, { Position = UDim2.fromOffset(424, 252), Size = UDim2.fromOffset(200, 64), BackgroundColor3 = CHIP })
	text(backB, { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -80, 1, 0), Text = "VOLVER", TextSize = 24, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	chip(backB, "ESC", false)
	backB.MouseButton1Click:Connect(MainMenu.CloseJoinCode)

	local OnlinePlay = require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("OnlinePlay"))
	-- live: upper-case as you type, and say what the code will be read as
	local busy = false
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local up = string.upper(box.Text)
		if up ~= box.Text then box.Text = up return end
		if busy then return end
		local c = OnlinePlay.NormalizeCode(up)
		status.TextColor3 = MUTED
		status.Text = if up == "" then "" elseif c and c ~= up then "SE USARÁ: " .. c elseif c then "" else "EJEMPLO: SL-1234"
	end)
	local function submit()
		if busy then return end
		local c = OnlinePlay.NormalizeCode(box.Text)
		if not c then
			status.TextColor3 = Color3.fromRGB(210, 60, 50)
			status.Text = "ESE CÓDIGO NO ES VÁLIDO · EJEMPLO: SL-1234"
			return
		end
		busy = true
		status.TextColor3 = GOLD
		status.Text = "BUSCANDO " .. c .. "…"
		task.spawn(function()
			local ok, err = OnlinePlay.JoinRoom(c, opts)
			busy = false
			if joinGui ~= g then return end
			if ok then
				MainMenu.CloseJoinCode()
			else
				status.TextColor3 = Color3.fromRGB(210, 60, 50)
				status.Text = err or "NO SE PUDO ENTRAR"
			end
		end)
	end
	joinB.MouseButton1Click:Connect(submit)
	box.FocusLost:Connect(function(enter) if enter then submit() end end)
	local opened = os.clock()
	local conn = UIS.InputBegan:Connect(function(inp, processed)
		if os.clock() - opened < 0.2 or joinGui ~= g then return end
		local k = inp.KeyCode
		if k == Enum.KeyCode.Escape then MainMenu.CloseJoinCode()
		elseif k == Enum.KeyCode.Return and not processed then submit() end
	end)
	g.Destroying:Connect(function() conn:Disconnect() end)
	InputGlyphs.PushPanel(g, function() return box end, MainMenu.CloseJoinCode)
	-- keyboard / mouse: the field is ready to type or paste into
	task.defer(function()
		if joinGui == g and not InputGlyphs.IsGamepad() then box:CaptureFocus() end
	end)
end

local SKINS = {
	{ id = "Octane", label = "OCTANE", sub = "El clásico. Equilibrado y agresivo." },
	{ id = "Troll", label = "CARRITO TROLL", sub = "El carrito de juguete. Misma física, cero dignidad." },
}
local DIFFS = { { id = "noob", label = "NOVATO" }, { id = "pro", label = "PRO" }, { id = "freestyler", label = "FREESTYLER" } }
local ACCENTS = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ" }
local function upper(str: string): string
	local out = string.upper(str)
	for lo, hi in ACCENTS do out = out:gsub(lo, hi) end
	return out
end

-- full screens opened from the menu words (their own modules); closing one mustn't leak the press to the words
local SCREEN_GUIS = { ChallengesMenu = true, GarageMenu = true, ShopMenu = true, LootboxMenu = true }

local reveal: { [string]: any }? = nil -- hero-reveal name block of the open menu
local settingsGui: ScreenGui? = nil

-- The menu is five big words over the live cinematic (Game.MenuCinematic). Clicking a word opens its submenu in the
-- same place: the words slide away, the submenu (title, options, ‹ VOLVER) slides in. No panels, no cards.
-- cfg: { mode, bot, difficulty, hitbox, skin } ; onPreview(cfg) when the car (skin / hitbox) changes
function MainMenu.Show(defaults: { [string]: any }, hitboxes: { string }, onPlay: ({ [string]: any }) -> (), onPreview: (({ [string]: any }) -> ())?)
	MainMenu.Hide()
	local g = newGui("MainMenu", 20)
	gui = g
	InputGlyphs.SetMenu("main", true)
	local cfg = table.clone(defaults)
	cfg.skin = cfg.skin or "Octane"
	cfg.difficulty = cfg.difficulty or "pro"
	local camS = require(script.Parent.CameraController).Settings
	local Q4 = TweenInfo.new(0.28, Enum.EasingStyle.Quart)

	-- a single soft shadow in the lower-left, only so the words read over bright grass
	local shade = frame(g, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromOffset(1250, 760), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4 })
	local sg = Instance.new("UIGradient")
	sg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.55, 0.78), NumberSequenceKeypoint.new(1, 1) })
	sg.Rotation = -30
	sg.Parent = shade

	-- wordmark
	text(g, { Position = UDim2.fromOffset(56, 104), Size = UDim2.fromOffset(900, 76), Text = "ROCKET ROBLOX", TextSize = 72, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.85 })
	frame(g, { Position = UDim2.fromOffset(60, 184), Size = UDim2.fromOffset(90, 6), BackgroundColor3 = BLUE })
	frame(g, { Position = UDim2.fromOffset(158, 184), Size = UDim2.fromOffset(90, 6), BackgroundColor3 = ORANGE })

	buildCard(g)
	refreshCard(false)

	local ITEMS = {
		{ id = "play", label = "JUGAR" }, { id = "garage", label = "GARAJE" }, { id = "challenges", label = "DESAFÍOS" },
		{ id = "training", label = "ENTRENAMIENTO" }, { id = "ranked", label = "RANKED" }, { id = "settings", label = "AJUSTES" },
	}
	local ROW = 80
	local LEFT = 56
	local list = frame(g, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, LEFT, 1, -84), Size = UDim2.fromOffset(700, #ITEMS * ROW), BackgroundTransparency = 1 })
	list.Name = "MenuList"
	local sub = frame(g, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, LEFT, 1, -84), Size = UDim2.fromOffset(820, 500), BackgroundTransparency = 1, Visible = false })
	-- carTag removed
	InputGlyphs.HintBar(g, { { "confirm", "ABRIR" }, { "back", "VOLVER" }, { "join", "UNIRSE CON CÓDIGO" }, { "profile", "PERFIL" } }, { position = UDim2.new(1, -56, 1, -30), height = 34, textSize = 18 })

	-- hero reveal: the player's name, big, lower right (driven by MenuCinematic via MainMenu.SetReveal)
	local lp = Players.LocalPlayer
	local rName = text(g, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -56, 1, -110), Size = UDim2.fromOffset(1100, 120), Text = upper(lp.DisplayName), TextSize = 112, TextColor3 = WHITE, TextTransparency = 1, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right })
	local rSub = text(g, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -60, 1, -226), Size = UDim2.fromOffset(800, 26), Text = "", TextSize = 22, TextColor3 = GOLD, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right })
	reveal = { name = rName, sub = rSub, on = false }

	local rows = {}
	for i, it in ITEMS do
		local b = button(list, { Position = UDim2.fromOffset(0, (i - 1) * ROW), Size = UDim2.fromOffset(700, ROW - 6), BackgroundTransparency = 1 })
		b.Name = it.id .. "Button"
		local bar = frame(b, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(0, 40), BackgroundColor3 = BLUE })
		local l = text(b, { Size = UDim2.fromScale(1, 1), Text = it.label, TextSize = 62, TextColor3 = WHITE, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.85 })
		rows[i] = { b = b, bar = bar, l = l }
	end

	local sel, subSel = 1, 1
	local opened = false
	local subRows: { any } = {}
	local subDesc: TextLabel? = nil
	local refresh: () -> () = function() end

	local function diffLabel(id: string): string
		for _, d in DIFFS do if d.id == id then return d.label end end
		return id
	end
	local function cycleDiff(dir: number)
		local idx = 1
		for i, d in DIFFS do if d.id == cfg.difficulty then idx = i end end
		cfg.difficulty = DIFFS[(idx - 1 + dir) % #DIFFS + 1].id
	end
	local function skinLabel(id: string): string
		for _, sk in SKINS do if sk.id == id then return sk.label end end
		return id
	end
	local function level(): number
		return (Progression.FromXp((profileData and profileData.xp) or 0))
	end
	local function rankedDiff(): string
		local l = level()
		return if l < 3 then "noob" elseif l < 8 then "pro" else "freestyler"
	end
	local function go()
		MainMenu.Hide()
		onPlay(cfg)
	end
	-- matches against people run online on the server (Party.OnlinePlay); bots take empty seats
	local function online(): any
		return require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("OnlinePlay"))
	end
	local function stepper(label: string, get: () -> string, set: (number) -> ()): any
		return { text = function() return label .. "   ‹  " .. get() .. "  ›" end, left = function() set(-1) end, right = function() set(1) end, small = true }
	end

	local closeSub: () -> () = function() end

	-- AJUSTES: its own screen with sub-menus (CÁMARA / GRÁFICOS / CARRO) on the left and their options on the right.
	-- Numbers get ‹ value › plus a slider (click or drag), on/off options a switch, choices ‹ value ›.
	local function openSettings()
		local GS = require(script.Parent.GraphicsSettings)
		if settingsGui then settingsGui:Destroy() end
		local sgui = newGui("SettingsMenu", 35)
		settingsGui = sgui
		g.Enabled = false -- the main menu words, logo and chip step aside while settings is open
		sgui.Destroying:Connect(function() if g.Parent then g.Enabled = true end end)
		local conns = {}
		sgui.Destroying:Connect(function() for _, c in conns do c:Disconnect() end end)
		local back = frame(sgui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1 })
		TweenService:Create(back, TweenInfo.new(0.25), { BackgroundTransparency = 0.3 }):Play()
		local root = frame(sgui, { Position = UDim2.fromOffset(110, 140), Size = UDim2.fromOffset(1700, 900), BackgroundTransparency = 1 })
		text(root, { Size = UDim2.fromOffset(900, 90), Text = "AJUSTES", TextSize = 88, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		frame(root, { Position = UDim2.fromOffset(4, 92), Size = UDim2.fromOffset(90, 6), BackgroundColor3 = BLUE })

		-- ---- controls
		local function num(key: string, stepv: number, lo: number, hi: number, fmt: string): any
			return {
				kind = "num",
				get = function() return string.format(fmt, camS[key]) end,
				frac = function() return (camS[key] - lo) / (hi - lo) end,
				step = function(d) camS[key] = math.clamp(math.floor((camS[key] + d * stepv) / stepv + 0.5) * stepv, lo, hi) end,
				setFrac = function(f) camS[key] = math.clamp(math.floor((lo + f * (hi - lo)) / stepv + 0.5) * stepv, lo, hi) end,
			}
		end
		local function toggle(get: () -> boolean, set: (boolean) -> ()): any
			return { kind = "toggle", on = get, flip = function() set(not get()) end }
		end
		local function gfxToggle(key: string): any
			return toggle(function() return GS.Get(key) == true end, function(v) GS.Set(key, v) end)
		end
		local function gfxNum(key: string, stepv: number, lo: number, hi: number, fmt: string): any
			local function cur(): number return GS.Get(key) or lo end
			return {
				kind = "num",
				get = function() return string.format(fmt, cur()) end,
				frac = function() return (cur() - lo) / (hi - lo) end,
				step = function(d) GS.Set(key, math.clamp(math.floor((cur() + d * stepv) / stepv + 0.5) * stepv, lo, hi)) end,
				setFrac = function(f) GS.Set(key, math.clamp(math.floor((lo + f * (hi - lo)) / stepv + 0.5) * stepv, lo, hi)) end,
			}
		end
		local function choice(options: { { string } }, get: () -> string, set: (string) -> ()): any
			local function idx()
				for i, o in options do if o[1] == get() then return i end end
				return 0
			end
			return {
				kind = "choice",
				get = function()
					local i = idx()
					return if i > 0 then options[i][2] else "PERSONALIZADA"
				end,
				step = function(d)
					local i = idx()
					if i == 0 then i = if d > 0 then 0 else #options + 1 end
					set(options[(i - 1 + d) % #options + 1][1])
				end,
			}
		end

		local CATS = {
			{ "CÁMARA", {
				{ "CAMPO DE VISIÓN", num("FOV", 1, 60, 110, "%d") },
				{ "DISTANCIA", num("Distance", 10, 100, 400, "%d") },
				{ "ALTURA", num("Height", 10, 40, 200, "%d") },
				{ "ÁNGULO", num("AngleDeg", 1, -15, 0, "%d") },
				{ "RIGIDEZ", num("Stiffness", 0.05, 0, 1, "%.2f") },
				{ "VELOCIDAD DE GIRO", num("SwivelSpeed", 0.5, 1, 10, "%.1f") },
				{ "TRANSICIÓN", num("TransitionSpeed", 0.1, 1, 2, "%.1f") },
				{ "SACUDIDA", toggle(function() return camS.Shake == true end, function(v) camS.Shake = v end) },
			}, "Así sigue la cámara a tu carro durante el partido." },
			{ "GRÁFICOS", {
				{ "CALIDAD", choice({ { "low", "BAJA" }, { "medium", "MEDIA" }, { "high", "ALTA" } }, function() return GS.Get("quality") end, function(v) GS.SetPreset(v) end) },
				{ "SOMBRAS", gfxToggle("shadows") },
				{ "EFECTOS DE LUZ", gfxToggle("post") },
				{ "NIEBLA", gfxToggle("atmosphere") },
				{ "DESENFOQUE CINEMÁTICO", gfxToggle("dof") },
				{ "PARTÍCULAS", choice({ { "off", "NO" }, { "low", "BAJAS" }, { "high", "ALTAS" } }, function() return GS.Get("particles") end, function(v) GS.Set("particles", v) end) },
				{ "LUCES DINÁMICAS", gfxToggle("lights") },
				{ "ESTELAS", gfxToggle("trails") },
				{ "PÚBLICO EN LAS GRADAS", gfxToggle("crowd") },
				{ "MENÚ ANIMADO COMPLETO", gfxToggle("menuFull") },
				{ "MOSTRAR FPS", gfxToggle("fps") },
			}, "BAJA desactiva sombras, efectos, luces, estelas y público: lo que más cuesta." },
			{ "CONTROL", {
				{ "VIBRACIÓN DEL MANDO", toggle(function() return GS.Get("rumble") ~= false end, function(v)
					GS.Set("rumble", v)
					if v then require(script.Parent.Rumble).Event("goal") end -- feel it right away
				end) },
				{ "ZONA MUERTA DEL STICK", gfxNum("deadzone", 0.02, 0, 0.3, "%.2f") },
				{ "ICONOS DE BOTONES", choice({ { "auto", "AUTOMÁTICO" }, { "gamepad", "MANDO" }, { "keyboard", "TECLADO" } }, function() return GS.Get("glyphs") end, function(v) GS.Set("glyphs", v) end) },
			}, "Automático muestra los botones del último dispositivo que usaste (Xbox y PlayStation se detectan solos).", "buttonMap" },
			{ "BOTONES", {}, "Elige una casilla y pulsa la tecla o el botón nuevo. Si ya estaba en uso, se intercambian.", "binds" },
			{ "CARRO", {
				{ "HITBOX", choice((function()
					local o = {}
					for _, h in hitboxes do table.insert(o, { h, string.upper(h) }) end
					return o
				end)(), function() return cfg.hitbox end, function(v)
					cfg.hitbox = v
					if onPreview then onPreview(cfg) end
				end) },
			}, "La hitbox cambia la física del choque; el aspecto se elige en el GARAJE." },
		}

		-- ---- layout: categories left, rows right
		local catCol = frame(root, { Position = UDim2.fromOffset(0, 140), Size = UDim2.fromOffset(360, 530), BackgroundTransparency = 1 })
		local page = frame(root, { Position = UDim2.fromOffset(400, 140), Size = UDim2.fromOffset(1250, 760), BackgroundTransparency = 1 })
		local catRows = {}
		local current = 1
		local redraws: { () -> () } = {}
		-- pad / keyboard: Up-Down picks a category, Right or A steps into its rows, then Up-Down picks a row and
		-- Left-Right (or A) changes it; B steps back out. LB/RB (Q/E) switch category from anywhere.
		local inRows = false
		local rowSel = 1
		local rowRefs: { any } = {}
		local BIND_VIEW = 600 -- height of the scrolling BOTONES list
		local function paintRows()
			for i, rr in rowRefs do
				local on = inRows and i == rowSel
				rr.r.BackgroundTransparency = if on then 0.88 else 1
				rr.label.TextColor3 = if on then GOLD else WHITE
				rr.mark.BackgroundTransparency = if on then 0 else 1
				if rr.ctl.paint then rr.ctl.paint(on) end
				if on and rr.scroll then
					local sc = rr.scroll :: ScrollingFrame
					local top = sc.CanvasPosition.Y
					if rr.y < top + 10 then
						sc.CanvasPosition = Vector2.new(0, math.max(0, rr.y - 50))
					elseif rr.y + 50 > top + BIND_VIEW then
						sc.CanvasPosition = Vector2.new(0, rr.y + 50 - BIND_VIEW + 40)
					end
				end
			end
		end

		-- ---- BOTONES: every gameplay action with its keyboard key and its controller button, rebindable.
		-- Pick a cell (TECLADO / MANDO), press A / Enter or click it, then press the new key or button. Esc or
		-- Backspace cancels; a key another action already uses is swapped with it (Keybinds.Set).
		local Keybinds = require(script.Parent.Keybinds)
		local capturing: any = nil
		local captureEndedAt = -1
		local bindStatus: TextLabel? = nil
		local bindHint = ""
		local function busy(): boolean
			return capturing ~= nil or os.clock() - captureEndedAt < 0.15
		end
		local function setStatus(msg: string?, warn: boolean?)
			local l = bindStatus
			if not l or not l.Parent then return end
			l.Text = msg or bindHint
			l.TextColor3 = if warn then Color3.fromRGB(255, 120, 100) elseif msg then GOLD else WHITE
			l.TextTransparency = if msg then 0 else 0.4
		end
		local function endCapture()
			capturing = nil
			captureEndedAt = os.clock()
			for _, f in redraws do f() end
		end
		local function startCapture(id: string, device: string)
			local a = Keybinds.Action(id)
			if not a then return end
			if device == "pad" and not a.pad then
				setStatus("CON MANDO SE GIRA CON EL STICK IZQUIERDO (NO SE PUEDE CAMBIAR)", true)
				return
			end
			local startedAt = os.clock()
			capturing = { id = id, device = device, at = startedAt }
			setStatus(if device == "pad" then "PULSA EL BOTÓN DEL MANDO PARA " .. a.label .. "   ·   ESC CANCELA" else "PULSA LA TECLA PARA " .. a.label .. "   ·   ESC CANCELA")
			for _, f in redraws do f() end
			local conn: RBXScriptConnection
			conn = UIS.InputBegan:Connect(function(inp)
				local c = capturing
				if not c or c.at ~= startedAt then conn:Disconnect() return end
				if os.clock() - c.at < 0.15 then return end -- the press that opened the capture
				local kc = inp.KeyCode
				if kc == Enum.KeyCode.Escape or kc == Enum.KeyCode.Backspace then
					conn:Disconnect()
					endCapture()
					setStatus(nil)
					return
				end
				local t = inp.UserInputType
				local name = if t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then t.Name
					elseif kc ~= Enum.KeyCode.Unknown then kc.Name else nil
				if not name then return end
				local isPad = string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 4) == "DPad"
				if (device == "pad") ~= isPad then return end -- the other device's column
				if not Keybinds.Accepts(device, name) then
					setStatus("ESA TECLA ESTÁ RESERVADA · PRUEBA OTRA", true)
					return
				end
				conn:Disconnect()
				local swapped = Keybinds.Set(device, id, name)
				endCapture()
				local sa = swapped and Keybinds.Action(swapped)
				setStatus(if sa then "INTERCAMBIADO CON " .. sa.label else nil)
			end)
			table.insert(conns, conn)
			task.delay(8, function()
				if capturing and capturing.at == startedAt then
					endCapture()
					setStatus(nil)
				end
			end)
		end

		local GROUPS = { drive = "CONDUCCIÓN", view = "CÁMARA Y MENÚS", training = "ENTRENAMIENTO" }
		local SOFT = Color3.fromRGB(150, 150, 160)
		local function cellDeco(cell: GuiObject): UIStroke
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = cell
			local st = Instance.new("UIStroke")
			st.Color = GOLD
			st.Thickness = 3
			st.Transparency = 1
			st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			st.Parent = cell
			return st
		end
		local function buildBinds(cat: any)
			bindHint = cat[3]
			text(page, { Position = UDim2.fromOffset(600, 0), Size = UDim2.fromOffset(260, 30), Text = "TECLADO", TextSize = 24, TextColor3 = WHITE, TextTransparency = 0.3 })
			text(page, { Position = UDim2.fromOffset(890, 0), Size = UDim2.fromOffset(200, 30), Text = "MANDO", TextSize = 24, TextColor3 = WHITE, TextTransparency = 0.3 })
			local scroll = Instance.new("ScrollingFrame")
			scroll.BackgroundTransparency = 1
			scroll.BorderSizePixel = 0
			scroll.Position = UDim2.fromOffset(0, 40)
			scroll.Size = UDim2.fromOffset(1250, BIND_VIEW)
			scroll.ScrollBarThickness = 6
			scroll.ScrollBarImageColor3 = WHITE
			scroll.ScrollingDirection = Enum.ScrollingDirection.Y
			scroll.Selectable = false
			scroll.Parent = page
			local y = 0
			local group = nil
			for _, a in Keybinds.ACTIONS do
				if a.group ~= group then
					group = a.group
					text(scroll, { Position = UDim2.fromOffset(20, y + 6), Size = UDim2.fromOffset(600, 26), Text = GROUPS[a.group] or "", TextSize = 20, TextColor3 = WHITE, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
					y += 36
				end
				local r = frame(scroll, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(1220, 46), BackgroundTransparency = 1, BackgroundColor3 = WHITE })
				local mark = frame(r, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(6, 30), BackgroundColor3 = GOLD, BackgroundTransparency = 1 })
				local lab = text(r, { Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(560, 46), Text = a.label, TextSize = 28, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
				local kbCell = button(r, { Position = UDim2.fromOffset(600, 4), Size = UDim2.fromOffset(260, 38), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Selectable = false })
				local kbText = text(kbCell, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 22, TextColor3 = WHITE })
				local padCell = button(r, { Position = UDim2.fromOffset(890, 4), Size = UDim2.fromOffset(200, 38), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Selectable = false })
				local padImg = Instance.new("ImageLabel")
				padImg.BackgroundTransparency = 1
				padImg.AnchorPoint = Vector2.new(0.5, 0.5)
				padImg.Position = UDim2.fromScale(0.5, 0.5)
				padImg.Size = UDim2.fromOffset(34, 34)
				padImg.ScaleType = Enum.ScaleType.Fit
				padImg.Parent = padCell
				local padText = text(padCell, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 20, TextColor3 = WHITE })
				local strokes = { cellDeco(kbCell), cellDeco(padCell) }
				local ctl: any = { kind = "bind", col = 1 }
				local function draw()
					local cap = capturing ~= nil and capturing.id == a.id
					if cap and capturing.device == "kb" then
						kbText.Text = "PULSA UNA TECLA…"
						kbText.TextColor3 = GOLD
					else
						kbText.Text = Keybinds.KbLabel(a.id)
						kbText.TextColor3 = WHITE
					end
					if not a.pad then
						padImg.Visible = false
						padText.Text = "STICK IZQ."
						padText.TextColor3 = SOFT
					elseif cap and capturing.device == "pad" then
						padImg.Visible = false
						padText.Text = "PULSA UN BOTÓN…"
						padText.TextColor3 = GOLD
					else
						local kc = Keybinds.PadKeyCode(a.id)
						local img = ""
						if kc then pcall(function() img = UIS:GetImageForKeyCode(kc) end) end
						padImg.Image = img
						padImg.Visible = img ~= ""
						padText.Text = if img == "" then Keybinds.Label(Keybinds.Get("pad", a.id)) else ""
						padText.TextColor3 = WHITE
					end
				end
				ctl.paint = function(on: boolean)
					strokes[1].Transparency = if on and ctl.col == 1 then 0 else 1
					strokes[2].Transparency = if on and ctl.col == 2 then 0 else 1
				end
				ctl.step = function(d: number)
					ctl.col = if d > 0 then 2 else 1
					paintRows()
				end
				ctl.activate = function()
					startCapture(a.id, if ctl.col == 2 then "pad" else "kb")
				end
				table.insert(rowRefs, { r = r, label = lab, mark = mark, ctl = ctl, scroll = scroll, y = y })
				local index = #rowRefs
				local function clickCell(col: number)
					if busy() then return end
					inRows = true
					rowSel = index
					ctl.col = col
					paintRows()
					ctl.activate()
				end
				kbCell.MouseButton1Click:Connect(function() clickCell(1) end)
				padCell.MouseButton1Click:Connect(function() clickCell(2) end)
				table.insert(redraws, draw)
				draw()
				y += 50
			end
			-- restore defaults
			y += 10
			local r = frame(scroll, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(1220, 50), BackgroundTransparency = 1, BackgroundColor3 = WHITE })
			local mark = frame(r, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(6, 30), BackgroundColor3 = GOLD, BackgroundTransparency = 1 })
			local resetBtn = button(r, { Position = UDim2.fromOffset(20, 4), Size = UDim2.fromOffset(520, 42), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Selectable = false })
			local lab = text(resetBtn, { Size = UDim2.fromScale(1, 1), Text = "RESTABLECER PREDETERMINADOS", TextSize = 24, TextColor3 = WHITE })
			local rs = cellDeco(resetBtn)
			local ctl: any = {
				kind = "action",
				activate = function()
					Keybinds.ResetDefaults()
					setStatus("CONTROLES RESTABLECIDOS (LOS DE ROCKET LEAGUE)")
				end,
				paint = function(on: boolean) rs.Transparency = if on then 0 else 1 end,
				step = function() end,
			}
			table.insert(rowRefs, { r = r, label = lab, mark = mark, ctl = ctl, scroll = scroll, y = y })
			local resetIndex = #rowRefs
			resetBtn.MouseButton1Click:Connect(function()
				if busy() then return end
				inRows = true
				rowSel = resetIndex
				paintRows()
				ctl.activate()
			end)
			y += 60
			scroll.CanvasSize = UDim2.fromOffset(0, y)
			bindStatus = text(page, { Position = UDim2.fromOffset(0, BIND_VIEW + 54), Size = UDim2.fromOffset(1200, 28), Text = bindHint, TextSize = 22, TextColor3 = WHITE, TextTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
			-- a swap changes another row too
			scroll.Destroying:Connect(Keybinds.OnChanged(function()
				for _, f in redraws do f() end
			end))
			rowSel = math.clamp(rowSel, 1, math.max(1, #rowRefs))
			paintRows()
		end

		-- the full button map for the current device (CONTROL page)
		local MAP = {
			{ "throttle", "ACELERAR" }, { "brake", "FRENAR / REVERSA" }, { "steer", "DIRECCIÓN / INCLINAR" },
			{ "jump", "SALTAR / DODGE" }, { "boost", "TURBO" }, { "powerslide", "DERRAPE / GIRO AÉREO" },
			{ "airroll", "GIRO AÉREO IZQ · DER" }, { "ballcam", "CÁMARA BALÓN" }, { "scoreboard", "MARCADOR (MANTENER)" },
			{ "pause", "PAUSA (TOCAR)" }, { "controls", "AYUDA DE CONTROLES" }, { "reset", "ENTRENAMIENTO: REINICIAR" },
		}
		local function buttonMap(y: number)
			text(page, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(600, 34), Text = "MAPA DE BOTONES", TextSize = 30, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
			frame(page, { Position = UDim2.fromOffset(2, y + 36), Size = UDim2.fromOffset(56, 4), BackgroundColor3 = BLUE })
			for i, m in MAP do
				local col, row = (i - 1) % 2, (i - 1) // 2
				local cell = frame(page, { Position = UDim2.fromOffset(col * 600, y + 54 + row * 48), Size = UDim2.fromOffset(580, 44), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.6 })
				text(cell, { Position = UDim2.fromOffset(16, 0), Size = UDim2.fromOffset(380, 44), Text = m[2], TextSize = 24, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
				InputGlyphs.Chip(cell, m[1], { dark = false, height = 32 })
			end
		end

		local function buildPage(ci: number)
			page:ClearAllChildren()
			redraws = {}
			rowRefs = {}
			capturing = nil
			bindStatus = nil
			local cat = CATS[ci]
			if cat[4] == "binds" then
				buildBinds(cat)
				return
			end
			local y = 0
			for _, row in cat[2] do
				local label, ctl = row[1], row[2]
				local r = frame(page, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(1250, 54), BackgroundTransparency = 1, BackgroundColor3 = WHITE })
				local mark = frame(r, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0, -8, 0.5, 0), Size = UDim2.fromOffset(6, 34), BackgroundColor3 = GOLD, BackgroundTransparency = 1 })
				local lab = text(r, { Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(480, 54), Text = label, TextSize = 34, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
				table.insert(rowRefs, { r = r, label = lab, mark = mark, ctl = ctl })
				local draw: () -> ()
				if ctl.kind == "toggle" then
					local sw = button(r, { Position = UDim2.fromOffset(520, 11), Size = UDim2.fromOffset(64, 32), BackgroundColor3 = WHITE, BackgroundTransparency = 0.75 })
					local swc = Instance.new("UICorner"); swc.CornerRadius = UDim.new(0.5, 0); swc.Parent = sw
					local knob = frame(sw, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.25, 0.5), Size = UDim2.fromOffset(24, 24), BackgroundColor3 = WHITE })
					local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(0.5, 0); kc.Parent = knob
					local st = text(r, { Position = UDim2.fromOffset(600, 0), Size = UDim2.fromOffset(120, 54), Text = "", TextSize = 28, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
					draw = function()
						local on = ctl.on()
						TweenService:Create(knob, TweenInfo.new(0.15), { Position = UDim2.fromScale(if on then 0.75 else 0.25, 0.5) }):Play()
						sw.BackgroundColor3 = if on then BLUE else WHITE
						sw.BackgroundTransparency = if on then 0 else 0.75
						st.Text = if on then "SÍ" else "NO"
					end
					sw.MouseButton1Click:Connect(function() ctl.flip(); for _, f in redraws do f() end end)
				else
					local minus = button(r, { Position = UDim2.fromOffset(510, 5), Size = UDim2.fromOffset(44, 44), BackgroundTransparency = 1 })
					text(minus, { Size = UDim2.fromScale(1, 1), Text = "‹", TextSize = 46, TextColor3 = WHITE })
					local val = text(r, { Position = UDim2.fromOffset(556, 0), Size = UDim2.fromOffset(240, 54), Text = "", TextSize = 34, TextColor3 = GOLD })
					local plus = button(r, { Position = UDim2.fromOffset(798, 5), Size = UDim2.fromOffset(44, 44), BackgroundTransparency = 1 })
					text(plus, { Size = UDim2.fromScale(1, 1), Text = "›", TextSize = 46, TextColor3 = WHITE })
					local fill, knob, track
					if ctl.kind == "num" then
						track = button(r, { Position = UDim2.fromOffset(880, 17), Size = UDim2.fromOffset(340, 20), BackgroundTransparency = 1 })
						local line = frame(track, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = WHITE, BackgroundTransparency = 0.7 })
						fill = frame(line, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = BLUE })
						knob = frame(track, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = WHITE })
						local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(0.5, 0); kc.Parent = knob
						local dragging = false
						local function fromMouse()
							local mx = UIS:GetMouseLocation().X
							ctl.setFrac(math.clamp((mx - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1))
							draw()
						end
						track.MouseButton1Down:Connect(function() dragging = true; fromMouse() end)
						table.insert(conns, UIS.InputChanged:Connect(function(inp)
							if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then fromMouse() end
						end))
						table.insert(conns, UIS.InputEnded:Connect(function(inp)
							if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
						end))
					end
					draw = function()
						val.Text = ctl.get()
						if fill then
							local f = math.clamp(ctl.frac(), 0, 1)
							fill.Size = UDim2.fromScale(f, 1)
							knob.Position = UDim2.fromScale(f, 0.5)
						end
					end
					minus.MouseButton1Click:Connect(function() ctl.step(-1); for _, f in redraws do f() end end)
					plus.MouseButton1Click:Connect(function() ctl.step(1); for _, f in redraws do f() end end)
				end
				table.insert(redraws, draw)
				draw()
				-- entrance
				r.Position = UDim2.fromOffset(30, y)
				r.BackgroundTransparency = 1
				TweenService:Create(r, TweenInfo.new(0.22, Enum.EasingStyle.Quart), { Position = UDim2.fromOffset(0, y) }):Play()
				y += 58
			end
			text(page, { Position = UDim2.fromOffset(0, y + 14), Size = UDim2.fromOffset(1200, 28), Text = cat[3], TextSize = 22, TextColor3 = WHITE, TextTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
			if cat[4] == "buttonMap" then buttonMap(y + 70) end
			rowSel = math.clamp(rowSel, 1, math.max(1, #rowRefs))
			paintRows()
		end

		local function selectCat(ci: number)
			current = ci
			for i, cr in catRows do
				local on = i == ci
				TweenService:Create(cr.l, TweenInfo.new(0.18, Enum.EasingStyle.Quart), { TextTransparency = if on then 0 else 0.5, Position = UDim2.fromOffset(if on then 20 else 0, 0) }):Play()
				TweenService:Create(cr.bar, TweenInfo.new(0.18, Enum.EasingStyle.Quart), { Size = UDim2.fromOffset(if on then 6 else 0, 36) }):Play()
			end
			buildPage(ci)
		end
		for i, cat in CATS do
			local b = button(catCol, { Position = UDim2.fromOffset(0, (i - 1) * 70), Size = UDim2.fromOffset(360, 64), BackgroundTransparency = 1 })
			local bar = frame(b, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(0, 36), BackgroundColor3 = BLUE })
			local l = text(b, { Size = UDim2.fromScale(1, 1), Text = cat[1], TextSize = 52, TextColor3 = WHITE, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left })
			catRows[i] = { b = b, l = l, bar = bar }
			b.MouseButton1Click:Connect(function() inRows = false; selectCat(i) end)
		end
		local function settingsDir(d: string)
			if settingsGui ~= sgui or busy() then return end
			if not inRows then
				if d == "Up" then selectCat((current - 2) % #CATS + 1)
				elseif d == "Down" then selectCat(current % #CATS + 1)
				elseif d == "Right" then inRows = true; rowSel = 1; paintRows() end
				return
			end
			if d == "Up" then rowSel = (rowSel - 2) % #rowRefs + 1; paintRows()
			elseif d == "Down" then rowSel = rowSel % #rowRefs + 1; paintRows()
			else
				local rr = rowRefs[rowSel]
				if not rr then return end
				if rr.ctl.kind == "toggle" then
					rr.ctl.flip()
				else
					rr.ctl.step(if d == "Right" then 1 else -1)
				end
				for _, f in redraws do f() end
			end
		end
		InputGlyphs.HintBar(sgui, { { "tabs", "CATEGORÍA" }, { "confirm", "CAMBIAR" }, { "back", "VOLVER" } }, { position = UDim2.new(1, -56, 1, -30), height = 34, textSize = 18 })
		local done = button(catCol, { Position = UDim2.fromOffset(0, #CATS * 70 + 40), Size = UDim2.fromOffset(360, 56), BackgroundTransparency = 1 })
		local dl = text(done, { Size = UDim2.fromScale(1, 1), Text = "‹  VOLVER", TextSize = 40, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		done.MouseEnter:Connect(function() dl.TextColor3 = GOLD end)
		done.MouseLeave:Connect(function() dl.TextColor3 = WHITE end)
		local function close()
			GS.Save(camS) -- persist graphics + camera in the profile
			if settingsGui == sgui then settingsGui = nil end
			sgui:Destroy()
			refresh()
		end
		done.MouseButton1Click:Connect(close)
		table.insert(conns, UIS.InputBegan:Connect(function(inp)
			if busy() then return end -- a key / button is being captured for BOTONES
			local k = inp.KeyCode
			if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
				if inRows then inRows = false; paintRows() else close() end
			elseif k == Enum.KeyCode.ButtonL1 or k == Enum.KeyCode.Q then
				rowSel = 1; selectCat((current - 2) % #CATS + 1)
			elseif k == Enum.KeyCode.ButtonR1 or k == Enum.KeyCode.E then
				rowSel = 1; selectCat(current % #CATS + 1)
			elseif k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Return then
				if not inRows then
					inRows = true; rowSel = 1; paintRows()
				else
					local rr = rowRefs[rowSel]
					if rr then
						if rr.ctl.activate then
							rr.ctl.activate()
						elseif rr.ctl.kind == "toggle" then
							rr.ctl.flip()
						else
							rr.ctl.step(1)
						end
						for _, f in redraws do f() end
					end
				end
			elseif k == Enum.KeyCode.Up then settingsDir("Up")
			elseif k == Enum.KeyCode.Down then settingsDir("Down")
			elseif k == Enum.KeyCode.Left then settingsDir("Left")
			elseif k == Enum.KeyCode.Right then settingsDir("Right") end
		end))
		local offDir = InputGlyphs.OnDirection(settingsDir) -- d-pad and left stick, with key-repeat
		sgui.Destroying:Connect(offDir)
		selectCat(1)
		root.Position = UDim2.fromOffset(150, 140)
		TweenService:Create(root, TweenInfo.new(0.3, Enum.EasingStyle.Quart), { Position = UDim2.fromOffset(110, 140) }):Play()
	end

	-- submenu content for a word
	local playGui: ScreenGui? = nil

	local function openPlayModal()
		-- modal body()
		if playGui then playGui:Destroy(); playGui = nil end
		local pgui = newGui("PlayMenu", 32)
		playGui = pgui
		g.Enabled = false
		pgui.Destroying:Connect(function()
			if playGui == pgui then playGui = nil end
			if g.Parent then g.Enabled = true end
		end)

		local conns = {}
		pgui.Destroying:Connect(function() for _, c in conns do c:Disconnect() end end)

		-- dark backdrop
		local back = button(pgui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, Selectable = false })
		TweenService:Create(back, TweenInfo.new(0.25), { BackgroundTransparency = 0.45 }):Play()

		-- main modal panel
		local p = frame(pgui, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1240, 720), BackgroundColor3 = CREAM })
		brackets(p, Color3.fromRGB(64, 58, 52), 10, 18, 3)
		local ps = Instance.new("UIScale"); ps.Scale = 0.94; ps.Parent = p
		TweenService:Create(ps, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()

		local function close()
			if playGui == pgui then playGui = nil end
			pgui:Destroy()
			refresh()
		end
		back.MouseButton1Click:Connect(close)

		table.insert(conns, UIS.InputBegan:Connect(function(inp)
			local k = inp.KeyCode
			if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
				close()
			end
		end))

		-- Header
		text(p, { Position = UDim2.fromOffset(36, 22), Size = UDim2.fromOffset(600, 48), Text = "JUGAR", TextSize = 48, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Left })
		text(p, { Position = UDim2.fromOffset(38, 70), Size = UDim2.fromOffset(700, 22), Text = "MODOS DE JUEGO · EMPAREJAMIENTO Y PARTIDAS PRIVADAS", TextSize = 16, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
		frame(p, { Position = UDim2.fromOffset(38, 96), Size = UDim2.fromOffset(50, 4), BackgroundColor3 = BLUE })
		frame(p, { Position = UDim2.fromOffset(92, 96), Size = UDim2.fromOffset(50, 4), BackgroundColor3 = ORANGE })
		-- ¿un amigo te pasó un código? straight there, whatever tab is open
		local joinCodeBtn = button(p, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -36, 0, 30), Size = UDim2.fromOffset(330, 52), BackgroundColor3 = INK })
		text(joinCodeBtn, { Size = UDim2.fromScale(1, 1), Text = "¿TIENES UN CÓDIGO?  UNIRSE", TextSize = 22, TextColor3 = WHITE })
		local function joinCode()
			close()
			MainMenu.OpenJoinCode({ skin = cfg.skin, hitbox = cfg.hitbox, difficulty = cfg.difficulty })
		end
		joinCodeBtn.MouseButton1Click:Connect(joinCode)
		table.insert(conns, UIS.InputBegan:Connect(function(inp, processed)
			if not processed and playGui == pgui and inp.KeyCode == Enum.KeyCode.U then joinCode() end
		end))

		-- State variables
		local selMode = cfg.mode or "1v1"
		local isParty = false
		local matchType = "public" -- "public" | "private"
		local botDiff = cfg.difficulty or "pro"

		local MODES = {
			{ id = "1v1", title = "1 VS 1", desc = "Duelo individual clásico de 5 minutos contra bot o matchmaking.", badge = nil, icon = "⚔️", color = BLUE },
			{ id = "2v2", title = "2 VS 2", desc = "Partido en parejas. Coordina pases y rotaciones de equipo.", badge = nil, icon = "👥", color = BLUE },
			{ id = "party", title = "PARTY MODE", desc = "Minijuegos con amigos: voleibol, sumo, anillos y rey de la colina.", badge = "NUEVO", icon = "🎉", color = GOLD },
			{ id = "training", title = "ENTRENAMIENTO", desc = "Práctica libre sin reloj, turbo infinito y lanzador de tiros.", badge = nil, icon = "🎯", color = Color3.fromRGB(60, 190, 120) },
			{ id = "ranked", title = "RANKED", desc = "Partida clasificatoria competitiva según tu nivel de carrera.", badge = "COMPETITIVO", icon = "🏆", color = ORANGE },
		}

		-- Containers
		local leftCol = frame(p, { Position = UDim2.fromOffset(36, 116), Size = UDim2.fromOffset(660, 520), BackgroundTransparency = 1 })
		local rightCol = frame(p, { Position = UDim2.fromOffset(720, 116), Size = UDim2.fromOffset(484, 520), BackgroundTransparency = 1 })

		-- Render functions
		local updateRight: () -> () = function() end
		local modeCards = {}
		-- real screenshots of each mode (captured in-game, uploaded as images)
		local SHOTS = {
			["1v1"] = "rbxassetid://125865980910917", ["2v2"] = "rbxassetid://117395794750813", party = "rbxassetid://131395911474951",
			training = "rbxassetid://136696525388153", ranked = "rbxassetid://130892119752242",
		}
		local byId = {}
		for _, m in MODES do byId[m.id] = m end

		-- hero: the selected mode, big, with a slow push-in and a cross-fade when it changes
		local HERO_H = 300
		local hero = frame(leftCol, { Size = UDim2.new(1, 0, 0, HERO_H), BackgroundColor3 = INK, ClipsDescendants = true })
		local hc = Instance.new("UICorner"); hc.CornerRadius = UDim.new(0, 8); hc.Parent = hero
		local heroImgs = {}
		for i = 1, 2 do
			local im = Instance.new("ImageLabel")
			im.BackgroundTransparency = 1
			im.AnchorPoint = Vector2.new(0.5, 0.5)
			im.Position = UDim2.fromScale(0.5, 0.5)
			im.Size = UDim2.fromScale(1, 1)
			im.ScaleType = Enum.ScaleType.Crop
			im.ImageTransparency = 1
			im.ZIndex = i
			im.Parent = hero
			local sc = Instance.new("UIScale"); sc.Parent = im
			heroImgs[i] = { img = im, scale = sc }
		end
		local shade = frame(hero, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.62, 0), BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 3 })
		local sg2 = Instance.new("UIGradient")
		sg2.Rotation = 90
		sg2.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.15) })
		sg2.Parent = shade
		local heroBand = frame(hero, { Position = UDim2.new(0, 24, 1, -106), Size = UDim2.fromOffset(64, 5), BackgroundColor3 = BLUE, ZIndex = 4 })
		local heroTitle = text(hero, { Position = UDim2.new(0, 24, 1, -98), Size = UDim2.new(1, -48, 0, 52), Text = "", TextSize = 50, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4, TextStrokeTransparency = 0.7 })
		local heroDesc = text(hero, { Position = UDim2.new(0, 25, 1, -44), Size = UDim2.new(1, -48, 0, 30), Text = "", TextSize = 19, TextColor3 = Color3.fromRGB(225, 228, 236), TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG, ZIndex = 4, TextWrapped = true })
		local heroBadge = frame(hero, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 18), Size = UDim2.fromOffset(150, 30), BackgroundColor3 = GOLD, ZIndex = 4, Visible = false })
		local hbc = Instance.new("UICorner"); hbc.CornerRadius = UDim.new(0, 6); hbc.Parent = heroBadge
		local heroBadgeText = text(heroBadge, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 15, TextColor3 = INK, ZIndex = 5 })
		local heroIcon = frame(hero, { Position = UDim2.fromOffset(18, 18), Size = UDim2.fromOffset(52, 52), BackgroundColor3 = INK, BackgroundTransparency = 0.2, ZIndex = 4 })
		local hic = Instance.new("UICorner"); hic.CornerRadius = UDim.new(0.5, 0); hic.Parent = heroIcon
		local heroIconStroke = Instance.new("UIStroke"); heroIconStroke.Thickness = 3; heroIconStroke.Color = BLUE; heroIconStroke.Parent = heroIcon
		local heroIconText = text(heroIcon, { Size = UDim2.fromScale(1, 1), Text = "", TextSize = 28, TextColor3 = WHITE, ZIndex = 5, FontFace = Font.fromEnum(Enum.Font.BuilderSans) })
		local front = 1
		local heroTweens = {}
		local function showHero(id: string, instant: boolean?)
			local m = byId[id]
			if not m then return end
			for _, t in heroTweens do t:Cancel() end
			table.clear(heroTweens)
			local nextI = if instant then front else 3 - front
			local cur, nxt = heroImgs[front], heroImgs[nextI]
			nxt.img.Image = SHOTS[id] or ""
			nxt.img.ZIndex = 2
			if cur ~= nxt then cur.img.ZIndex = 1 end
			nxt.scale.Scale = 1.02
			local fade = TweenService:Create(nxt.img, TweenInfo.new(if instant then 0 else 0.35, Enum.EasingStyle.Quad), { ImageTransparency = 0 })
			local push = TweenService:Create(nxt.scale, TweenInfo.new(7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.09 })
			fade:Play(); push:Play()
			table.insert(heroTweens, fade); table.insert(heroTweens, push)
			if cur ~= nxt then
				local out = TweenService:Create(cur.img, TweenInfo.new(0.35), { ImageTransparency = 1 })
				out:Play()
				table.insert(heroTweens, out)
			end
			front = nextI
			heroTitle.Text = m.title
			heroDesc.Text = m.desc
			heroBand.BackgroundColor3 = m.color
			heroIconText.Text = m.icon
			heroIconStroke.Color = m.color
			heroBadge.Visible = m.badge ~= nil
			heroBadgeText.Text = m.badge or ""
			heroBadge.BackgroundColor3 = if m.id == "party" then GOLD else INK
			heroBadgeText.TextColor3 = if m.id == "party" then INK else WHITE
			-- the title slides in
			heroTitle.Position = UDim2.new(0, 44, 1, -98)
			heroTitle.TextTransparency = 0.6
			TweenService:Create(heroTitle, TweenInfo.new(0.3, Enum.EasingStyle.Quart), { Position = UDim2.new(0, 24, 1, -98), TextTransparency = 0 }):Play()
		end

		-- tiles: every mode with its screenshot
		local TILE_Y = HERO_H + 12
		local gap = 9
		local tileW = math.floor((660 - gap * (#MODES - 1)) / #MODES)
		local tileH = 520 - TILE_Y
		for i, m in ipairs(MODES) do
			local cd = button(leftCol, { Position = UDim2.fromOffset((i - 1) * (tileW + gap), TILE_Y), Size = UDim2.fromOffset(tileW, tileH), BackgroundColor3 = Color3.fromRGB(240, 236, 226) })
			local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 8); cc.Parent = cd
			local tileScale = Instance.new("UIScale"); tileScale.Parent = cd
			local stroke = Instance.new("UIStroke"); stroke.Color = m.color; stroke.Thickness = 3; stroke.Transparency = 1; stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; stroke.Parent = cd
			local img = Instance.new("ImageLabel")
			img.BackgroundColor3 = INK
			img.BorderSizePixel = 0
			img.Position = UDim2.fromOffset(6, 6)
			img.Size = UDim2.new(1, -12, 0, tileH - 64)
			img.ScaleType = Enum.ScaleType.Crop
			img.Image = SHOTS[m.id] or ""
			img.Parent = cd
			local ic = Instance.new("UICorner"); ic.CornerRadius = UDim.new(0, 6); ic.Parent = img
			local iconBadge = frame(img, { Position = UDim2.fromOffset(6, 6), Size = UDim2.fromOffset(34, 34), BackgroundColor3 = INK, BackgroundTransparency = 0.15, ZIndex = 3 })
			local ibc = Instance.new("UICorner"); ibc.CornerRadius = UDim.new(0.5, 0); ibc.Parent = iconBadge
			local ibs = Instance.new("UIStroke"); ibs.Color = m.color; ibs.Thickness = 2; ibs.Parent = iconBadge
			text(iconBadge, { Size = UDim2.fromScale(1, 1), Text = m.icon, TextSize = 19, TextColor3 = WHITE, ZIndex = 4, FontFace = Font.fromEnum(Enum.Font.BuilderSans) })
			local bar = frame(cd, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -24, 0, 4), BackgroundColor3 = m.color, BackgroundTransparency = 1 })
			local tl = text(cd, { Position = UDim2.new(0, 8, 1, -54), Size = UDim2.new(1, -16, 0, 40), Text = m.title, TextSize = if #m.title > 11 then 17 else 22, TextColor3 = INK, TextWrapped = true })
			if m.badge then
				local tag = frame(img, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -6, 1, -6), Size = UDim2.fromOffset(if m.id == "party" then 58 else 92, 20), BackgroundColor3 = if m.id == "party" then GOLD else INK, ZIndex = 3 })
				local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 4); tc.Parent = tag
				text(tag, { Size = UDim2.fromScale(1, 1), Text = m.badge, TextSize = 12, TextColor3 = if m.id == "party" then INK else WHITE, ZIndex = 4 })
			end
			modeCards[m.id] = { btn = cd, bar = bar, title = tl, stroke = stroke, scale = tileScale }
			local function lift(on: boolean)
				TweenService:Create(tileScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Scale = if on then 1.05 else 1 }):Play()
			end
			cd.MouseEnter:Connect(function() lift(true) end)
			cd.MouseLeave:Connect(function() lift(false) end)
			cd.SelectionGained:Connect(function() lift(true) end)
			cd.SelectionLost:Connect(function() lift(false) end)

			cd.MouseButton1Click:Connect(function()
				if m.id == "party" then
					isParty = true
					selMode = "party"
				else
					isParty = false
					selMode = m.id
				end
				for mid, mc in modeCards do
					local on = mid == m.id
					mc.btn.BackgroundColor3 = if on then Color3.fromRGB(252, 250, 244) else Color3.fromRGB(240, 236, 226)
					mc.bar.BackgroundTransparency = if on then 0 else 1
					mc.stroke.Transparency = if on then 0 else 1
					mc.title.TextColor3 = if on then (if mid == "party" then Color3.fromRGB(180, 130, 20) else byId[mid].color) else INK
				end
				showHero(m.id)
				updateRight()
			end)
		end

		-- Right Column: Server & Social Settings
		text(rightCol, { Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 22), Text = "TIPO DE PARTIDA", TextSize = 16, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
		local serverRow = frame(rightCol, { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 })
		local setServerType, _, _ = segmented(serverRow, 0, "", { { id = "public", label = "PÚBLICA" }, { id = "private", label = "PRIVADA" } }, function(id)
			matchType = id
			updateRight()
		end)
		setServerType("public")

		-- Dynamic details container
		local detailsBox = frame(rightCol, { Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 175), BackgroundColor3 = Color3.fromRGB(236, 230, 218) })
		brackets(detailsBox, Color3.fromRGB(160, 150, 140), 6, 10, 2)
		local detailsTitle = text(detailsBox, { Position = UDim2.fromOffset(18, 14), Size = UDim2.new(1, -36, 0, 26), Text = "PARTIDA PÚBLICA", TextSize = 22, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Left })
		local detailsText = text(detailsBox, { Position = UDim2.fromOffset(18, 44), Size = UDim2.new(1, -36, 0, 60), Text = "Servidor abierto con emparejamiento automático de jugadores.", TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })

		-- join a friend's room (SL-####) or party (RR-####) with their code, from any server
		local codeChip = frame(detailsBox, { Position = UDim2.fromOffset(18, 114), Size = UDim2.new(1, -36, 0, 48), BackgroundColor3 = INK, Visible = false })
		local codeInput = Instance.new("TextBox")
		codeInput.Position = UDim2.fromOffset(8, 7)
		codeInput.Size = UDim2.new(1, -156, 0, 34)
		codeInput.BackgroundColor3 = Color3.fromRGB(238, 235, 226)
		codeInput.BorderSizePixel = 0
		codeInput.FontFace = OSWALD
		codeInput.TextSize = 20
		codeInput.TextColor3 = INK
		codeInput.PlaceholderText = "CÓDIGO DE UN AMIGO (SL-0000)"
		codeInput.PlaceholderColor3 = MUTED
		codeInput.Text = ""
		codeInput.ClearTextOnFocus = false
		codeInput.Parent = codeChip
		local joinBtn = button(codeChip, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(130, 34), BackgroundColor3 = BLUE })
		text(joinBtn, { Size = UDim2.fromScale(1, 1), Text = "UNIRSE", TextSize = 18, TextColor3 = WHITE })
		local function joinWithCode()
			local code = codeInput.Text
			if string.gsub(code, "%s", "") == "" then return end
			close()
			local OnlinePlay = require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("OnlinePlay"))
			OnlinePlay.JoinRoom(code, { skin = cfg.skin, hitbox = cfg.hitbox, difficulty = botDiff })
		end
		joinBtn.MouseButton1Click:Connect(joinWithCode)
		codeInput.FocusLost:Connect(function(enter) if enter then joinWithCode() end end)

		-- Bot Difficulty Row
		local botBox = frame(rightCol, { Position = UDim2.fromOffset(0, 275), Size = UDim2.new(1, 0, 0, 76), BackgroundTransparency = 1 })
		text(botBox, { Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 22), Text = "DIFICULTAD DE BOTS", TextSize = 15, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
		local botRow = frame(botBox, { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 })
		local setBotDiff, _, _ = segmented(botRow, 0, "", { { id = "noob", label = "NOVATO" }, { id = "pro", label = "PRO" }, { id = "freestyler", label = "FREESTYLER" } }, function(id)
			botDiff = id
			cfg.difficulty = id
		end)
		setBotDiff(botDiff)

		-- Social Invite Button
		local inviteBtn = button(rightCol, { Position = UDim2.fromOffset(0, 365), Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = INK })
		text(inviteBtn, { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -80, 1, 0), Text = "INVITAR AMIGOS AL JUEGO", TextSize = 22, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		chip(inviteBtn, "F", false)
		local toastLabel = text(rightCol, { Position = UDim2.fromOffset(0, 420), Size = UDim2.new(1, 0, 0, 20), Text = "", TextSize = 15, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, FontFace = OSWALD_REG })

		local function invite()
			local SocialService = game:GetService("SocialService")
			local ok = pcall(function()
				SocialService:PromptGameInvite(Players.LocalPlayer)
			end)
			toastLabel.Text = if ok then "¡Ventana de invitación abierta!" else "Invitación enviada a tus amigos."
			task.delay(2.5, function() if toastLabel.Parent then toastLabel.Text = "" end end)
		end
		inviteBtn.MouseButton1Click:Connect(invite)

		-- Start Match Button
		local startBtn = button(rightCol, { Position = UDim2.fromOffset(0, 448), Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = BLUE })
		local startScale = Instance.new("UIScale"); startScale.Parent = startBtn
		local startText = text(startBtn, { Size = UDim2.fromScale(1, 1), Text = "COMENZAR PARTIDA", TextSize = 28, TextColor3 = WHITE })
		chip(startBtn, "ENTER", true)

		startBtn.MouseEnter:Connect(function()
			TweenService:Create(startScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Scale = 1.03 }):Play()
		end)
		startBtn.MouseLeave:Connect(function()
			TweenService:Create(startScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
		end)

		updateRight = function()
			setServerType(matchType)
			if matchType == "public" then
				detailsTitle.Text = "PARTIDA PÚBLICA"
				detailsText.Text = "En línea contra jugadores reales de este servidor. Si en unos segundos no aparecen suficientes, los bots completan los equipos."
				codeChip.Visible = false
			else
				detailsTitle.Text = "SALA PRIVADA"
				detailsText.Text = "Crea una sala y comparte su código, o únete a la de un amigo con el suyo (funciona desde cualquier servidor):"
				codeChip.Visible = true
			end

			if selMode == "party" then
				startBtn.BackgroundColor3 = GOLD
				startText.TextColor3 = INK
				startText.Text = "CREAR GRUPO DE FIESTA"
				botBox.Visible = false
			elseif selMode == "training" then
				startBtn.BackgroundColor3 = BLUE
				startText.TextColor3 = WHITE
				startText.Text = "ENTRAR A ENTRENAMIENTO"
				botBox.Visible = false
			elseif matchType == "private" then
				startBtn.BackgroundColor3 = BLUE
				startText.TextColor3 = WHITE
				startText.Text = "CREAR SALA PRIVADA"
				botBox.Visible = true
			elseif selMode == "ranked" then
				startBtn.BackgroundColor3 = ORANGE
				startText.TextColor3 = WHITE
				startText.Text = "BUSCAR RANKED"
				botBox.Visible = false
			else
				startBtn.BackgroundColor3 = BLUE
				startText.TextColor3 = WHITE
				startText.Text = "BUSCAR PARTIDA"
				botBox.Visible = true
			end
		end

		local function start()
			if selMode == "party" then
				toastLabel.Text = "¡MODO GRUPO! INICIANDO LOBBY AÉREO NOCTURNO..."
				task.delay(0.35, function()
					close()
					MainMenu.Hide()
					local PartyManager = require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("PartyManager"))
					PartyManager.Start(nil, true)
				end)
				return
			elseif selMode == "training" then
				close()
				cfg.mode = "training"
				cfg.bot = false
				go()
			else
				-- every match against other people is online, run by the server (bots take empty seats)
				close()
				local OnlinePlay = require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("OnlinePlay"))
				local car = { skin = cfg.skin, hitbox = cfg.hitbox }
				if matchType == "private" then
					OnlinePlay.CreateRoom({ mode = if selMode == "2v2" then "2v2" else "1v1", skin = car.skin, hitbox = car.hitbox, difficulty = botDiff })
				elseif selMode == "ranked" then
					OnlinePlay.Queue({ mode = "1v1", ranked = true, difficulty = rankedDiff(), skin = car.skin, hitbox = car.hitbox })
				else
					OnlinePlay.Queue({ mode = if selMode == "2v2" then "2v2" else "1v1", difficulty = botDiff, skin = car.skin, hitbox = car.hitbox })
				end
			end
		end
		startBtn.MouseButton1Click:Connect(start)
		-- the shortcuts shown on the chips (on a pad, A presses the selected button and X invites)
		table.insert(conns, UIS.InputBegan:Connect(function(inp, processed)
			if processed or playGui ~= pgui then return end
			local k = inp.KeyCode
			if k == Enum.KeyCode.Return then start()
			elseif k == Enum.KeyCode.F or k == Enum.KeyCode.ButtonX then invite() end
		end))
		-- controller: the start button begins selected, the d-pad / stick moves between every button
		InputGlyphs.PushPanel(pgui, function() return startBtn end, nil)

		-- Return button at bottom-left of modal
		local closeBtn = button(p, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 36, 1, -16), Size = UDim2.fromOffset(200, 48), BackgroundColor3 = CHIP })
		text(closeBtn, { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -70, 1, 0), Text = "VOLVER", TextSize = 22, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		chip(closeBtn, "ESC", false)
		closeBtn.MouseButton1Click:Connect(close)

		-- Initial selection: 1v1
		do
			local mc = modeCards["1v1"]
			mc.btn.BackgroundColor3 = Color3.fromRGB(252, 250, 244)
			mc.bar.BackgroundTransparency = 0
			mc.stroke.Transparency = 0
			mc.title.TextColor3 = BLUE
			showHero("1v1", true)
		end
		updateRight()
	end


	local function defsFor(id: string): ({ any }, string)
		if id == "play" then
			return {
				{ text = function() return "1 VS 1  EN LÍNEA" end, act = function() online().Queue({ mode = "1v1", difficulty = cfg.difficulty, skin = cfg.skin, hitbox = cfg.hitbox }) end },
				{ text = function() return "2 VS 2  EN LÍNEA" end, act = function() online().Queue({ mode = "2v2", difficulty = cfg.difficulty, skin = cfg.skin, hitbox = cfg.hitbox }) end },
				{ text = function() return "SALA PRIVADA" end, act = function() online().CreateRoom({ mode = "1v1", difficulty = cfg.difficulty, skin = cfg.skin, hitbox = cfg.hitbox }) end },
				{ text = function() return "UNIRSE CON CÓDIGO" end, act = function() MainMenu.OpenJoinCode({ skin = cfg.skin, hitbox = cfg.hitbox, difficulty = cfg.difficulty }) end },
				{ text = function() return "CONTRA BOTS  ·  SIN CONEXIÓN" end, act = function() cfg.mode = "1v1"; cfg.bot = false; cfg.ranked = false; go() end },
				stepper("BOTS", function() return diffLabel(cfg.difficulty) end, cycleDiff),
			}, "Partido de 5 minutos en línea; los bots completan los equipos"
		elseif id == "garage" then
			local defs = {}
			for _, sk in SKINS do
				table.insert(defs, {
					text = function() return (if cfg.skin == sk.id then "●  " else "○  ") .. sk.label end,
					act = function()
						cfg.skin = sk.id
						if onPreview then onPreview(cfg) end
					end,
					desc = sk.sub,
				})
			end
			return defs, "Cambia tu carro. La física es la misma."
		elseif id == "training" then
			return {
				{ text = function() return "LIBRE" end, act = function() cfg.mode = "training"; cfg.bot = false; go() end },
				{ text = function() return "CON BOT  ·  " .. diffLabel(cfg.difficulty) end, act = function() cfg.mode = "training"; cfg.bot = true; go() end },
			}, if InputGlyphs.IsGamepad() then "Sin reloj, turbo infinito. Cruceta: → lanza el balón, ← pinch, ↓ reinicia, ↑ turbo." else "Sin reloj, turbo infinito. G lanza el balón, T práctica de pinch."
		elseif id == "ranked" then
			return { { text = function() return "BUSCAR PARTIDA" end, act = function() online().Queue({ mode = "1v1", ranked = true, difficulty = rankedDiff(), skin = cfg.skin, hitbox = cfg.hitbox }) end } },
				"1 VS 1 en línea · bot de relleno según tu nivel: " .. diffLabel(rankedDiff())
		end
		local function num(label: string, key: string, stepv: number, lo: number, hi: number, fmt: string): any
			return stepper(label, function() return string.format(fmt, camS[key]) end, function(d)
				camS[key] = math.clamp(math.floor((camS[key] + d * stepv) / stepv + 0.5) * stepv, lo, hi)
			end)
		end
		return {
			stepper("HITBOX", function() return string.upper(cfg.hitbox) end, function(d)
				local idx = table.find(hitboxes, cfg.hitbox) or 1
				cfg.hitbox = hitboxes[(idx - 1 + d) % #hitboxes + 1]
				if onPreview then onPreview(cfg) end
			end),
			num("FOV", "FOV", 1, 60, 110, "%d"),
			num("DISTANCIA", "Distance", 10, 100, 400, "%d"),
			num("ALTURA", "Height", 10, 40, 200, "%d"),
			num("ÁNGULO", "AngleDeg", 1, -15, 0, "%d"),
			num("RIGIDEZ", "Stiffness", 0.05, 0, 1, "%.2f"),
		}, if InputGlyphs.IsGamepad() then "Cruceta o stick ‹ › para cambiar" else "Clic en ‹ › (o flechas) para cambiar"
	end

	local function buildSub()
		sub:ClearAllChildren()
		subRows = {}
		local defs, desc = defsFor(ITEMS[sel].id)
		-- ‹ VOLVER always last
		table.insert(defs, { text = function() return "‹  VOLVER" end, act = function() closeSub() end, back = true, small = true })
		-- layout bottom-up so the submenu sits where the words were
		local y = 0
		local items = {}
		for i, d in defs do
			local size = if d.small then 40 else 54
			table.insert(items, { d = d, size = size, y = y })
			y += size + 18
		end
		local descH = 34
		local titleH = 96
		local total = titleH + y + descH
		sub.Size = UDim2.fromOffset(820, total)
		text(sub, { Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(820, 84), Text = ITEMS[sel].label, TextSize = 84, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.85 })
		frame(sub, { Position = UDim2.fromOffset(2, 86), Size = UDim2.fromOffset(56, 4), BackgroundColor3 = BLUE })
		for i, it in items do
			local d = it.d
			local b = button(sub, { Position = UDim2.fromOffset(0, titleH + it.y), Size = UDim2.fromOffset(820, it.size + 12), BackgroundTransparency = 1 })
			local l = text(b, { Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -28, 1, 0), Text = d.text(), TextSize = it.size, TextColor3 = WHITE, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.9 })
			local mark = frame(b, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(12, 3), BackgroundColor3 = GOLD, BackgroundTransparency = 1 })
			b.MouseEnter:Connect(function() subSel = i; refresh() end)
			b.MouseButton1Click:Connect(function()
				subSel = i
				if d.left and d.right then
					-- steppers: click on the left third goes back a value, anywhere else forward
					local mx = UIS:GetMouseLocation().X
					if mx < b.AbsolutePosition.X + b.AbsoluteSize.X * 0.33 then d.left() else d.right() end
				elseif d.act then
					d.act()
				end
				refresh()
			end)
			b.MouseButton2Click:Connect(function() if d.left then d.left(); refresh() end end)
			subRows[i] = { b = b, l = l, mark = mark, d = d }
		end
		subDesc = text(sub, { Position = UDim2.fromOffset(28, titleH + y + 2), Size = UDim2.fromOffset(800, 28), Text = desc, TextSize = 22, TextColor3 = WHITE, TextTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
	end

	local function openSub(i: number)
		if ITEMS[i].id == "settings" then
			sel = i
			openSettings()
			return
		end
		if ITEMS[i].id == "play" then
			sel = i
			openPlayModal()
			return
		end
		if ITEMS[i].id == "challenges" then
			sel = i
			require(script.Parent.ChallengesScreen).Open(MainMenu.UI)
			return
		end
		sel = i
		opened = true
		subSel = 1
		buildSub()
		-- words slide out to the left, submenu slides in from the right
		TweenService:Create(list, Q4, { Position = UDim2.new(0, LEFT - 90, 1, -84) }):Play()
		for _, r in rows do TweenService:Create(r.l, Q4, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play() end
		sub.Visible = true
		sub.Position = UDim2.new(0, LEFT + 90, 1, -84)
		TweenService:Create(sub, Q4, { Position = UDim2.new(0, LEFT, 1, -84) }):Play()
		for k, r in subRows do
			r.l.TextTransparency = 1
			task.delay(0.04 * k, function()
				if r.l.Parent then TweenService:Create(r.l, TweenInfo.new(0.22), { TextTransparency = 0.3 }):Play() end
			end)
		end
		task.delay(0.3, function() list.Visible = not opened end)
		refresh()
	end

	closeSub = function()
		if not opened then return end
		opened = false
		list.Visible = true
		TweenService:Create(sub, Q4, { Position = UDim2.new(0, LEFT + 90, 1, -84) }):Play()
		task.delay(0.2, function() if not opened then sub.Visible = false end end)
		TweenService:Create(list, Q4, { Position = UDim2.new(0, LEFT, 1, -84) }):Play()
		for _, r in rows do TweenService:Create(r.l, Q4, { TextStrokeTransparency = 0.85 }):Play() end
		refresh()
	end

	refresh = function()
		for i, r in rows do
			local on = i == sel
			if not opened then
				TweenService:Create(r.l, TweenInfo.new(0.18, Enum.EasingStyle.Quart), { TextTransparency = if on then 0 else 0.5, Position = UDim2.fromOffset(if on then 22 else 0, 0) }):Play()
				TweenService:Create(r.bar, TweenInfo.new(0.18, Enum.EasingStyle.Quart), { Size = UDim2.fromOffset(if on then 6 else 0, 40) }):Play()
			end
		end
		for i, r in subRows do
			local on = i == subSel
			r.l.Text = r.d.text()
			if r.l.TextTransparency < 0.99 then
				r.l.TextTransparency = if on then 0 else 0.3
			end
			r.l.TextColor3 = if on then GOLD else WHITE
			r.mark.BackgroundTransparency = if on then 0 else 1
			if on and r.d.desc and subDesc then subDesc.Text = r.d.desc end
		end
		-- carTag text removed
	end

	currentOpenPlay = openPlayModal

	for i, r in rows do
		r.b.MouseEnter:Connect(function()
			if opened then return end
			sel = i
			refresh()
		end)
		r.b.MouseButton1Click:Connect(function()
			if not opened then openSub(i) end
		end)
	end
	refresh()

	-- keyboard / gamepad (optional; the mouse does everything)
	local subClosedAt = -1
	local closeWatch = Players.LocalPlayer:WaitForChild("PlayerGui").ChildRemoved:Connect(function(c)
		if c.Name == "SettingsMenu" or c.Name == "ProfileModal" or SCREEN_GUIS[c.Name] then subClosedAt = os.clock() end
	end)
	g.Destroying:Connect(function() closeWatch:Disconnect() end)
	local function idle(): boolean
		return gui == g and not profileGui and not settingsGui and not playGui and not joinGui and not InputGlyphs.PanelOpen()
			and not InputGlyphs.JustClosed() and os.clock() - subClosedAt > 0.1
	end
	local function nav(d: string)
		if not idle() then return end
		if d == "Up" then
			if opened then subSel = (subSel - 2) % #subRows + 1 else sel = (sel - 2) % #ITEMS + 1 end
			refresh()
		elseif d == "Down" then
			if opened then subSel = subSel % #subRows + 1 else sel = sel % #ITEMS + 1 end
			refresh()
		elseif d == "Left" then
			local r = subRows[subSel]
			if opened and r and r.d.left then r.d.left(); refresh() else closeSub() end
		elseif d == "Right" then
			local r = subRows[subSel]
			if not opened then openSub(sel) elseif r and r.d.right then r.d.right(); refresh() end
		end
	end
	g.Destroying:Connect(InputGlyphs.OnDirection(nav)) -- d-pad and left stick, with key-repeat
	local conn
	conn = UIS.InputBegan:Connect(function(input, processed)
		if processed or not idle() then return end
		local k = input.KeyCode
		if k == Enum.KeyCode.P or k == Enum.KeyCode.ButtonY then
			MainMenu.OpenProfile()
		elseif k == Enum.KeyCode.U or k == Enum.KeyCode.ButtonX then
			MainMenu.OpenJoinCode({ skin = cfg.skin, hitbox = cfg.hitbox, difficulty = cfg.difficulty })
		elseif k == Enum.KeyCode.Escape or k == Enum.KeyCode.Backspace or k == Enum.KeyCode.ButtonB then
			closeSub()
		elseif k == Enum.KeyCode.Up then nav("Up")
		elseif k == Enum.KeyCode.Down then nav("Down")
		elseif k == Enum.KeyCode.Left then nav("Left")
		elseif k == Enum.KeyCode.Right then nav("Right")
		elseif k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Return then
			if not opened then openSub(sel)
			else
				local r = subRows[subSel]
				if r then
					if r.d.act then r.d.act() elseif r.d.right then r.d.right() end
					refresh()
				end
			end
		end
	end)
	g.Destroying:Connect(function() conn:Disconnect() end)

	-- entrance: the words slide in one by one
	for i, r in rows do
		r.b.Position = UDim2.fromOffset(-70, (i - 1) * ROW)
		task.delay(0.05 * (i - 1), function()
			if r.b.Parent then
				TweenService:Create(r.b, TweenInfo.new(0.4, Enum.EasingStyle.Quart), { Position = UDim2.fromOffset(0, (i - 1) * ROW) }):Play()
			end
		end)
	end
end

-- Hero reveal (called by the menu cinematic): the player's name rises in over the stationary car
function MainMenu.SetReveal(on: boolean, subtitle: string?)
	local r = reveal
	if not r or not r.name.Parent or r.on == on then return end
	r.on = on
	if on then
		r.sub.Text = ""
		r.sub.Visible = false
		r.name.Position = UDim2.new(1, -56, 1, -80)
		TweenService:Create(r.name, TweenInfo.new(0.7, Enum.EasingStyle.Quart), { TextTransparency = 0, TextStrokeTransparency = 0.8, Position = UDim2.new(1, -56, 1, -110) }):Play()
		task.delay(0.25, function()
			if r.on and r.sub.Parent then
				TweenService:Create(r.sub, TweenInfo.new(0.5), { TextTransparency = 0 }):Play()
			end
		end)
	else
		TweenService:Create(r.name, TweenInfo.new(0.35), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(r.sub, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
	end
end

function MainMenu.Hide()
	InputGlyphs.SetMenu("main", false)
	currentOpenPlay = nil
	MainMenu.CloseProfile()
	if settingsGui then settingsGui:Destroy(); settingsGui = nil end
	if gui then
		gui:Destroy()
		gui = nil
	end
	card = nil
	reveal = nil
end

function MainMenu.IsOpen(): boolean
	return gui ~= nil
end

function MainMenu.OpenPlayModal()
	if currentOpenPlay then
		currentOpenPlay()
	end
end

function MainMenu.LaunchParty(code: string?)
	MainMenu.Hide()
	local PartyManager = require(game:GetService("ReplicatedStorage"):WaitForChild("Party"):WaitForChild("PartyManager"))
	return PartyManager.Start(code, true)
end

-- Centered modal (pause / results). items: { { label, key, callback } }
-- opts.back: the key whose item B / Start trigger (e.g. "ENTER" = CONTINUAR on the pause menu); default "ESC".
-- With a controller the first button starts selected and A presses the selected one; X / Y are R / M.
function MainMenu.Modal(titleText: string, subtitle: string?, color: Color3?, items: { { any } }, opts: { [string]: any }?)
	MainMenu.CloseModal()
	local g = newGui("GameModal", 30)
	overlay = g
	frame(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45 })
	local h = 150 + #items * 84
	local p = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(560, h), BackgroundColor3 = CREAM })
	overlayPanel = p
	brackets(p, Color3.fromRGB(64, 58, 52), 10, 18, 3)
	if color then
		frame(p, { Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = color })
	end
	text(p, { Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 64), Text = titleText, TextSize = 60 })
	if subtitle then
		text(p, { Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 28), Text = subtitle, TextSize = 20, TextColor3 = MUTED, FontFace = OSWALD_REG })
	end
	local backKey = (opts and opts.back) or "ESC"
	local keyMap = {}
	local firstBtn: GuiObject? = nil
	for i, it in items do
		local b = button(p, { Position = UDim2.fromOffset(28, 130 + (i - 1) * 84), Size = UDim2.new(1, -56, 0, 70), BackgroundColor3 = if i == 1 then CHIP else Color3.fromRGB(232, 226, 214) })
		text(b, { Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -110, 1, 0), Text = it[1], TextSize = 30, TextColor3 = if i == 1 then WHITE else INK, TextXAlignment = Enum.TextXAlignment.Left })
		chip(b, it[2], i ~= 1)
		b.MouseButton1Click:Connect(function() it[3]() end)
		if i == 1 then firstBtn = b end
		keyMap[it[2]] = it[3]
	end
	local conn
	conn = UIS.InputBegan:Connect(function(input, processed)
		if processed and input.KeyCode ~= Enum.KeyCode.ButtonSelect then return end -- Roblox always flags Select
		local name = input.KeyCode.Name
		local lookup = { Return = "ENTER", M = "M", R = "R", Escape = "ESC", Backspace = "ESC", ButtonX = "R", ButtonY = "M", ButtonStart = backKey, ButtonSelect = backKey }
		local fn = keyMap[lookup[name] or name]
		if fn then fn() end
	end)
	g.Destroying:Connect(function() conn:Disconnect() end)
	InputGlyphs.PushPanel(g, function() return firstBtn end, keyMap[backKey])
end

function MainMenu.CloseModal()
	if overlay then
		overlay:Destroy()
		overlay = nil
		overlayPanel = nil
	end
end

-- The server's reward for the match that just ended (ProfileUpdate): on the result screen it replaces the "+N XP"
-- estimate with the real number and adds a strip under the panel (credits, level up, challenges completed).
function MainMenu.ShowReward(reward: { [string]: any })
	local p = overlayPanel
	if not p or not p.Parent or type(reward) ~= "table" then return end
	for _, l in p:GetChildren() do
		if l:IsA("TextLabel") and string.find(l.Text, "XP", 1, true) then
			l.Text = string.gsub(l.Text, "%+[%d%.]+ XP", "+" .. fmtInt(reward.xp or 0) .. " XP")
		end
	end
	local parts = {}
	if (reward.credits or 0) > 0 then table.insert(parts, "+" .. fmtInt(reward.credits) .. " CRÉDITOS") end
	if reward.firstWin then table.insert(parts, "PRIMERA VICTORIA DEL DÍA") end
	if reward.levelTo and reward.levelFrom and reward.levelTo > reward.levelFrom then table.insert(parts, "¡NIVEL " .. reward.levelTo .. "!") end
	if reward.capped then table.insert(parts, "TOPE DIARIO DE CRÉDITOS ALCANZADO") end
	if reward.eligible == false then table.insert(parts, "SIN RECOMPENSA (PARTIDA DEMASIADO CORTA O SEGUIDA)") end
	for _, c in reward.challenges or {} do table.insert(parts, "DESAFÍO COMPLETADO: " .. tostring(c.text)) end
	if #parts == 0 then return end
	local old = (p.Parent :: Instance):FindFirstChild("RewardStrip")
	if old then old:Destroy() end
	local strip = frame(p.Parent :: Instance, {
		Name = "RewardStrip", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, p.Size.Y.Offset / 2 + 16), -- offsets: the gui's UIScale applies
		Size = UDim2.fromOffset(760, 30 * #parts + 16), BackgroundColor3 = CHIP, BackgroundTransparency = 0.15,
	})
	for i, t in parts do
		text(strip, { Position = UDim2.fromOffset(0, 8 + (i - 1) * 30), Size = UDim2.new(1, 0, 0, 30), Text = t, TextSize = 22, TextColor3 = if i == 1 then GOLD else WHITE })
	end
	strip.BackgroundTransparency = 1
	tween(strip, 0.3, { BackgroundTransparency = 0.15 })
end

function MainMenu.ModalOpen(): boolean
	return overlay ~= nil
end

return MainMenu
