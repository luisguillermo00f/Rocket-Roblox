--!strict
-- Hud.lua: match HUD. Cream scoreboard with bracket corners + team squares and a "TÚ" tag, dark timer box with a
-- stopwatch glyph, right-hand action column (label + key chip), bottom-left utility buttons, and a dashed boost
-- meter bottom-center. Oswald Bold throughout. Pure presentation: it only reads the values passed to Update() and the
-- discrete events passed to Event().
-- Motion layer: score digits punch + board flash, timer bumps in the last 10 s, boost counts up with "+12"/"+100"
-- popups, a flash and a full-tank shine, low boost pulses red, centre messages slam in (countdown, ¡YA!, goal banner
-- with a team band and ball speed), stat toasts with points slide in under the timer, hit-speed popups and a ring at
-- the ball, supersonic speed streaks, and RL's Ball Arrow: a white chevron orbiting the car that points at the ball
-- whenever ball cam is off and the ball is out of view.
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local InputGlyphs = require(script.Parent:WaitForChild("InputGlyphs"))
local Rumble = require(script.Parent:WaitForChild("Rumble"))

local Hud = {}

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local INK = Color3.fromRGB(18, 18, 20)
local CREAM = Color3.fromRGB(248, 244, 236)
local TAN = Color3.fromRGB(214, 186, 150)
local CHIP = Color3.fromRGB(12, 12, 14)
local WHITE = Color3.fromRGB(255, 255, 255)

local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local MONO = Font.fromEnum(Enum.Font.Code)

local gui: ScreenGui
local overlay: ScreenGui -- viewport-space layer (no UIScale, no inset): ball arrow, hit popups, speed streaks
local refs: { [string]: any } = {}
local anim: { [string]: any } = { lastBlue = 0, lastOrange = 0, lastSecond = -1, lastMsg = "", boostShown = 33, lastBoost = 33, arrowAlpha = 0, streak = 0, lastClock = os.clock(), points = 0, pointsShown = 0 }

local function tween(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
-- snap a UIScale to `peak` and spring it back to 1
local function punch(sc: UIScale, peak: number, t: number?)
	sc.Scale = peak
	tween(sc, t or 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
end
local function uiScale(parent: Instance): UIScale
	local sc = Instance.new("UIScale")
	sc.Parent = parent
	return sc
end

local function frame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = WHITE
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = OSWALD
	l.TextColor3 = INK
	l.TextSize = 24
	for k, v in props do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

-- Four L-shaped corner brackets inset inside a box
local function brackets(parent: GuiObject, color: Color3, inset: number, len: number, thick: number)
	for _, c in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local ax, ay = c[1], c[2]
		local px = if ax == 0 then inset else -inset
		local py = if ay == 0 then inset else -inset
		frame(parent, { AnchorPoint = Vector2.new(ax, ay), Position = UDim2.new(ax, px, ay, py), Size = UDim2.fromOffset(len, thick), BackgroundColor3 = color, ZIndex = 3 })
		frame(parent, { AnchorPoint = Vector2.new(ax, ay), Position = UDim2.new(ax, px, ay, py), Size = UDim2.fromOffset(thick, len), BackgroundColor3 = color, ZIndex = 3 })
	end
end

-- Dashed rectangle outline made of short segments
local function dashed(parent: GuiObject, w: number, h: number, color: Color3)
	local dash, gap, t = 8, 6, 2
	local x = 0
	while x < w do
		local l = math.min(dash, w - x)
		frame(parent, { Position = UDim2.fromOffset(x, 0), Size = UDim2.fromOffset(l, t), BackgroundColor3 = color })
		frame(parent, { Position = UDim2.fromOffset(x, h - t), Size = UDim2.fromOffset(l, t), BackgroundColor3 = color })
		x += dash + gap
	end
	local y = 0
	while y < h do
		local l = math.min(dash, h - y)
		frame(parent, { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(t, l), BackgroundColor3 = color })
		frame(parent, { Position = UDim2.fromOffset(w - t, y), Size = UDim2.fromOffset(t, l), BackgroundColor3 = color })
		y += dash + gap
	end
end

local function measure(str: string, size: number): number
	local params = Instance.new("GetTextBoundsParams")
	params.Text = str
	params.Font = OSWALD
	params.Size = size
	params.Width = 1000
	local ok, v = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	return if ok then v.X else #str * 13
end

local UIS = game:GetService("UserInputService")
local function glyphImage(kc: Enum.KeyCode): string
	local ok, img = pcall(function() return UIS:GetImageForKeyCode(kc) end)
	return if ok and type(img) == "string" then img else ""
end

local function keyChip(parent: Instance, key: string, dark: boolean, height: number): Frame
	local w = math.max(height - 12, measure(key, 20) + 16)
	local chip = frame(parent, {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(w, height - 12),
		BackgroundColor3 = if dark then CHIP else WHITE,
	})
	text(chip, { Size = UDim2.fromScale(1, 1), Text = key, TextSize = if #key > 3 then 17 else 20, TextColor3 = if dark then WHITE else INK })
	return chip
end

-- controller glyph images right-aligned in a row (the images are round buttons already, no chip box)
local function padGlyphs(parent: Instance, action: string, height: number, onLight: boolean?): number
	local pads = InputGlyphs.Def(action).pad
	local size = height - 8
	local w = #pads * size + math.max(0, #pads - 1) * 3
	for i, kc in pads do
		local img = glyphImage(kc)
		local il = Instance.new("ImageLabel")
		il.BackgroundTransparency = 1
		il.Image = img
		il.ScaleType = Enum.ScaleType.Fit
		il.AnchorPoint = Vector2.new(1, 0.5)
		il.Size = UDim2.fromOffset(size, size)
		il.Position = UDim2.new(1, -6 - (#pads - i) * (size + 3), 0.5, 0)
		il.Parent = parent
		if onLight then
			-- white glyphs wash out on the cream rows: seat them on a dark disc
			local disc = frame(parent, { AnchorPoint = il.AnchorPoint, Position = il.Position, Size = il.Size, BackgroundColor3 = CHIP })
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = disc
			il.Size = UDim2.fromOffset(size - 6, size - 6)
			il.Position = il.Position - UDim2.fromOffset(3, 0)
			il.ZIndex = disc.ZIndex + 1
		end
	end
	return w
end

-- Right column row: translucent cream box, dark label, black key chip (controller: the button's glyph)
local function actionRow(parent: Instance, y: number, label: string, key: string, action: string?)
	if action then key = InputGlyphs.Def(action).key end -- rebindable: the player's key
	if action and InputGlyphs.IsGamepad() then
		local gw = 0
		local w0 = 16 + measure(label, 26) + 12
		local row = frame(parent, {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(w0, 46),
			BackgroundColor3 = CREAM, BackgroundTransparency = 0.25,
		})
		gw = padGlyphs(row, action, 46, true)
		row.Size = UDim2.fromOffset(w0 + gw + 8, 46)
		text(row, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -(gw + 26), 1, 0), Text = label, TextSize = 26, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Color3.fromRGB(46, 38, 30) })
		return row
	end
	local keyW = math.max(32, measure(key, 20) + 16)
	local w = 16 + measure(label, 26) + 12 + keyW + 8
	local row = frame(parent, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(w, 46),
		BackgroundColor3 = CREAM, BackgroundTransparency = 0.25,
	})
	text(row, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -(keyW + 26), 1, 0), Text = label, TextSize = 26, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Color3.fromRGB(46, 38, 30) })
	keyChip(row, key, true, 46)
	return row
end

-- Bottom-left button: black box, white label, white key chip (controller: the button's glyph)
local function utilButton(parent: Instance, y: number, label: string, key: string, action: string?)
	if action then key = InputGlyphs.Def(action).key end
	if action and InputGlyphs.IsGamepad() then
		local w0 = 14 + measure(label, 25) + 14
		local b = frame(parent, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, y), Size = UDim2.fromOffset(w0, 46), BackgroundColor3 = CHIP, BackgroundTransparency = 0.1 })
		local gw = padGlyphs(b, action, 46)
		b.Size = UDim2.fromOffset(w0 + gw + 8, 46)
		text(b, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -(gw + 24), 1, 0), Text = label, TextSize = 25, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
		return b
	end
	local keyW = math.max(32, measure(key, 20) + 16)
	local w = 14 + measure(label, 25) + 14 + keyW + 8
	local b = frame(parent, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, y), Size = UDim2.fromOffset(w, 46), BackgroundColor3 = CHIP, BackgroundTransparency = 0.1 })
	text(b, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -(keyW + 24), 1, 0), Text = label, TextSize = 25, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	keyChip(b, key, false, 46)
	return b
end

local function stopwatch(parent: Instance, x: number)
	local ring = frame(parent, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, x, 0.5, 2), Size = UDim2.fromOffset(20, 20), BackgroundTransparency = 1 })
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = ring
	local st = Instance.new("UIStroke"); st.Color = WHITE; st.Thickness = 2.5; st.Parent = ring
	frame(ring, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.5, 1), Size = UDim2.fromOffset(2, 7) })
	frame(ring, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.fromOffset(5, 2) })
	frame(ring, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -1), Size = UDim2.fromOffset(6, 3) })
end

function Hud.Init()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("RLHud")
	if old then old:Destroy() end
	gui = Instance.new("ScreenGui")
	gui.Name = "RLHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- scoreboard flush with the very top of the screen
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg
	local scale = Instance.new("UIScale")
	scale.Parent = gui
	refs.scale = scale

	-- ===== Scoreboard =====
	local board = frame(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(262, 96), BackgroundColor3 = CREAM })
	brackets(board, Color3.fromRGB(64, 58, 52), 9, 16, 3)
	frame(board, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 30, 0.5, -4), Size = UDim2.fromOffset(22, 22), BackgroundColor3 = BLUE })
	frame(board, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -30, 0.5, -4), Size = UDim2.fromOffset(22, 22), BackgroundColor3 = ORANGE })
	refs.blue = text(board, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0.5, -22, 0.5, -4), Size = UDim2.fromOffset(70, 70), Text = "0", TextSize = 64, TextXAlignment = Enum.TextXAlignment.Right })
	refs.orange = text(board, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0.5, 22, 0.5, -4), Size = UDim2.fromOffset(70, 70), Text = "0", TextSize = 64, TextXAlignment = Enum.TextXAlignment.Left })
	refs.board = board
	refs.boardScale = uiScale(board)
	refs.blueScale = uiScale(refs.blue)
	refs.orangeScale = uiScale(refs.orange)
	refs.boardFlash = frame(board, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLUE, BackgroundTransparency = 1, ZIndex = 4 })
	frame(board, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -2), Size = UDim2.fromOffset(20, 5), BackgroundColor3 = TAN })
	local you = frame(board, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(0.5, -24, 1, -8), Size = UDim2.fromOffset(36, 16), BackgroundColor3 = BLUE })
	text(you, { Size = UDim2.fromScale(1, 1), Text = "TÚ", TextSize = 14, TextColor3 = WHITE })

	-- ===== Timer =====
	local tb = frame(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 104), Size = UDim2.fromOffset(124, 50), BackgroundColor3 = Color3.fromRGB(22, 22, 26), BackgroundTransparency = 0.05 })
	brackets(tb, Color3.fromRGB(150, 150, 150), 6, 10, 2)
	stopwatch(tb, 22)
	refs.timer = text(tb, { Position = UDim2.fromOffset(46, 0), Size = UDim2.new(1, -52, 1, 0), Text = "5:00", TextSize = 30, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left })
	refs.timerBox = tb
	refs.timerScale = uiScale(tb)

	-- ===== Points chip (under the timer) =====
	local pts = frame(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 162), Size = UDim2.fromOffset(124, 26), BackgroundColor3 = CREAM, BackgroundTransparency = 0.1 })
	refs.pointsScale = uiScale(pts)
	refs.points = text(pts, { Size = UDim2.fromScale(1, 1), Text = "0 PTS", TextSize = 18, TextColor3 = Color3.fromRGB(46, 38, 30) })

	-- ===== Stat toasts (bottom-left, above the tags; newest at the bottom, older ones pushed up) =====
	local feed = frame(gui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -176), Size = UDim2.fromOffset(380, 200), BackgroundTransparency = 1 })
	local fl = Instance.new("UIListLayout")
	fl.SortOrder = Enum.SortOrder.LayoutOrder
	fl.HorizontalAlignment = Enum.HorizontalAlignment.Left
	fl.VerticalAlignment = Enum.VerticalAlignment.Bottom
	fl.Padding = UDim.new(0, 6)
	fl.Parent = feed
	refs.feed = feed
	refs.feedOrder = 0

	-- ===== Right action column =====
	local col = frame(gui, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -178), Size = UDim2.fromOffset(320, 6 * 56), BackgroundTransparency = 1 })
	refs.actions = col
	local actions = {
		{ "Saltar", "SPACE", "jump" }, { "Turbo", "SHIFT", "boost" }, { "Derrape", "CTRL", "powerslide" },
		{ "Giro aéreo", "Q/E", "airroll" }, { "Cámara balón", "C", "ballcam" }, { "Marcador", "BLOQ MAYÚS", "scoreboard" },
	}
	local function buildActions()
		for _, c in col:GetChildren() do c:Destroy() end
		for i, a in actions do
			actionRow(col, (i - 1) * 56, a[1], a[2], a[3])
		end
	end
	buildActions()

	-- ===== Bottom-left utility buttons =====
	local util = frame(gui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(300, 200), BackgroundTransparency = 1 })
	local helpBtn = utilButton(util, 0, "Controles", "H", "controls")
	-- keyboard <-> controller, or a rebind: redraw the prompts
	InputGlyphs.OnModeChanged(function()
		if not col.Parent then return end
		buildActions()
		helpBtn:Destroy()
		helpBtn = utilButton(util, 0, "Controles", "H", "controls")
	end)
	refs.tags = frame(util, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -122), Size = UDim2.fromOffset(300, 26), BackgroundTransparency = 1 })
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.Padding = UDim.new(0, 6)
	tl.Parent = refs.tags

	-- ===== Boost meter (bottom center) =====
	local bm = frame(gui, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -12), Size = UDim2.fromOffset(240, 150), BackgroundTransparency = 1 }) -- bottom-right like RL, never over the car
	local box = frame(bm, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(150, 90), BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.72 })
	dashed(box, 150, 90, WHITE)
	refs.boostNum = text(box, { Size = UDim2.new(1, 0, 1, -6), Text = "33", TextSize = 60, TextColor3 = WHITE })
	refs.boostBox = box
	refs.boostScale = uiScale(box)
	refs.boostFlash = frame(box, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 190, 70), BackgroundTransparency = 1, ZIndex = 4 })
	refs.boostRoot = bm
	local chip = frame(box, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(64, 22), BackgroundColor3 = WHITE, ZIndex = 5 })
	refs.turboChip = chip
	refs.turboChipText = text(chip, { Size = UDim2.fromScale(1, 1), Text = "TURBO", TextSize = 15, ZIndex = 5 })
	refs.turboChipScale = uiScale(chip)
	-- big-pad rays: burst from behind the box
	local rays = frame(bm, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 57), Size = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, ZIndex = 0 })
	refs.rays = {}
	for i = 1, 12 do
		local r = frame(rays, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 5), BackgroundColor3 = Color3.fromRGB(255, 205, 80), BackgroundTransparency = 1, Rotation = (i - 1) * 30, ZIndex = 0 })
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.35, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = r
		table.insert(refs.rays, r)
	end
	local track = frame(bm, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 2), Size = UDim2.fromOffset(100, 5), BackgroundColor3 = Color3.fromRGB(245, 240, 232) })
	refs.boostBar = frame(track, { Size = UDim2.fromScale(0.33, 1), BackgroundColor3 = WHITE })
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 90)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 205, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 230, 150)),
	})
	grad.Parent = refs.boostBar
	refs.segments = {}
	for i = 0, 3 do
		local seg = frame(bm, { Position = UDim2.fromOffset(i * 61, 124), Size = UDim2.fromOffset(57, 22), BackgroundTransparency = 1 })
		local st = Instance.new("UIStroke"); st.Color = WHITE; st.Thickness = 2; st.Parent = seg
		local fill = frame(seg, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ORANGE, BackgroundTransparency = 0.05 })
		refs.segments[i + 1] = fill
		refs.segFlash = refs.segFlash or {}
		refs.segFlash[i + 1] = frame(seg, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 3 })
	end
	-- full-tank shine: a white bar that sweeps across the segments
	local shineClip = frame(bm, { Position = UDim2.fromOffset(0, 124), Size = UDim2.fromOffset(240, 22), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 5 })
	refs.shine = frame(shineClip, { Position = UDim2.new(0, -60, 0, 0), Size = UDim2.fromOffset(40, 22), BackgroundColor3 = WHITE, BackgroundTransparency = 0.25, Rotation = 0, ZIndex = 5 })
	local sg = Instance.new("UIGradient")
	sg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
	sg.Parent = refs.shine
	refs.shine.Visible = false

	-- ===== Center message =====
	refs.band = frame(gui, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38), Size = UDim2.new(0, 0, 0, 150), BackgroundColor3 = BLUE, BackgroundTransparency = 0.15, Visible = false })
	local bg = Instance.new("UIGradient")
	bg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.18, 0), NumberSequenceKeypoint.new(0.82, 0), NumberSequenceKeypoint.new(1, 1) })
	bg.Parent = refs.band
	refs.message = text(gui, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38), Size = UDim2.fromOffset(900, 140), Text = "", TextSize = 110, TextColor3 = WHITE, TextStrokeTransparency = 0.35, TextStrokeColor3 = INK })
	refs.messageScale = uiScale(refs.message)
	refs.sub = text(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.38, 62), Size = UDim2.fromOffset(900, 40), Text = "", TextSize = 32, TextColor3 = WHITE, TextStrokeTransparency = 0.5, TextStrokeColor3 = INK })

	-- ===== Pinch stamp (above the car) + gold edge flash =====
	refs.pinchFlash = frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 196, 64), BackgroundTransparency = 1, ZIndex = 0 })
	local pfg = Instance.new("UIGradient")
	pfg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.22, 1), NumberSequenceKeypoint.new(0.78, 1), NumberSequenceKeypoint.new(1, 0) })
	pfg.Parent = refs.pinchFlash
	refs.pinch = text(gui, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3), Size = UDim2.fromOffset(700, 130), Text = "", TextSize = 120, TextColor3 = Color3.fromRGB(255, 196, 64), TextStrokeTransparency = 1, TextStrokeColor3 = INK, TextTransparency = 1, ZIndex = 8 })
	refs.pinchScale = uiScale(refs.pinch)
	refs.pinchSub = text(gui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.3, 58), Size = UDim2.fromOffset(700, 40), Text = "", TextSize = 34, TextColor3 = WHITE, TextStrokeTransparency = 1, TextStrokeColor3 = INK, TextTransparency = 1, ZIndex = 8 })

	-- ===== Viewport overlay: Ball Arrow, hit popups, speed streaks =====
	local old2 = pg:FindFirstChild("RLHudOverlay")
	if old2 then old2:Destroy() end
	overlay = Instance.new("ScreenGui")
	overlay.Name = "RLHudOverlay"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = -1
	overlay.Parent = pg
	-- Ball Arrow: two stacked chevrons (the outer one pulses)
	local function chevron(parent: Instance, size: number, thick: number, transp: number): Frame
		local c = frame(parent, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 })
		for _, sgn in { -1, 1 } do
			local bar = frame(c, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, sgn * size * 0.2, 0.5, 0), Size = UDim2.fromOffset(size * 0.62, thick), BackgroundColor3 = WHITE, BackgroundTransparency = transp, Rotation = sgn * 45 })
			local cr = Instance.new("UICorner"); cr.CornerRadius = UDim.new(0.5, 0); cr.Parent = bar
			local stroke = Instance.new("UIStroke"); stroke.Color = INK; stroke.Transparency = 0.45; stroke.Thickness = 1.5; stroke.Parent = bar
		end
		return c
	end
	local arrow = frame(overlay, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(40, 40), BackgroundTransparency = 1, Visible = false })
	refs.arrow = arrow
	refs.arrowInner = chevron(arrow, 30, 6, 0)
	refs.arrowOuter = chevron(arrow, 30, 4, 0.3)
	refs.arrowOuter.Position = UDim2.new(0.5, 0, 0.5, -10)
	refs.arrowScale = uiScale(arrow)
	-- dev hook: fire Hud events from the command bar / tests (Instances cross script contexts, modules don't)
	local hook = Instance.new("BindableEvent")
	hook.Name = "HudEvent"
	hook.Parent = overlay
	hook.Event:Connect(function(ev) Hud.Event(ev, { team = 0 }) end)
	-- speed streaks
	refs.streaks = {}
	local rng = Random.new(7)
	for i = 1, 18 do
		local ang = (i / 18) * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local f = frame(overlay, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(rng:NextInteger(70, 150), 2), BackgroundColor3 = WHITE, BackgroundTransparency = 1, Rotation = math.deg(ang) })
		table.insert(refs.streaks, { f = f, ang = ang, phase = rng:NextNumber(), speed = rng:NextNumber(1.6, 2.6) })
	end

	-- ===== Stats (F3) panel =====
	local dbg = frame(gui, { Position = UDim2.fromOffset(16, 60), Size = UDim2.fromOffset(410, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Color3.fromRGB(14, 14, 18), BackgroundTransparency = 0.15, Visible = false })
	brackets(dbg, Color3.fromRGB(150, 150, 150), 5, 10, 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12); pad.PaddingBottom = UDim.new(0, 12); pad.PaddingLeft = UDim.new(0, 14); pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = dbg
	refs.debugFrame = dbg
	refs.debug = text(dbg, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, FontFace = MONO, TextSize = 13, TextColor3 = Color3.fromRGB(215, 235, 225), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
end

local lastTags = ""
local function setTags(list: { string })
	local key = table.concat(list, "|")
	if key == lastTags then
		return
	end
	lastTags = key
	for _, c in refs.tags:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end
	for _, t in list do
		local f = frame(refs.tags, { Size = UDim2.fromOffset(measure(t, 15) + 16, 24), BackgroundColor3 = CHIP, BackgroundTransparency = 0.2 })
		text(f, { Size = UDim2.fromScale(1, 1), Text = t, TextSize = 15, TextColor3 = WHITE })
	end
end

local GOOD = Color3.fromRGB(255, 205, 80)
local BAD = Color3.fromRGB(255, 96, 86)

local function teamColor(team: number): Color3
	return if team == 0 then BLUE else ORANGE
end

-- ---------- discrete events ----------
local function toast(title: string, points: number, color: Color3)
	refs.feedOrder += 1
	local row = frame(refs.feed, { Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, LayoutOrder = refs.feedOrder })
	local card = frame(row, { Position = UDim2.fromOffset(-40, 0), Size = UDim2.fromOffset(measure(title, 26) + (if points > 0 then 110 else 50), 40), BackgroundColor3 = CREAM, BackgroundTransparency = 1 })
	row.Size = UDim2.fromOffset(card.Size.X.Offset, 40)
	row.AutomaticSize = Enum.AutomaticSize.None
	local stripe = frame(card, { Size = UDim2.new(0, 6, 1, 0), BackgroundColor3 = color, BackgroundTransparency = 1 })
	local label = text(card, { Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -18, 1, 0), Text = title, TextSize = 26, TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1 })
	local chip, chipText
	if points > 0 then
		chip = frame(card, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(62, 28), BackgroundColor3 = CHIP, BackgroundTransparency = 1 })
		chipText = text(chip, { Size = UDim2.fromScale(1, 1), Text = "+" .. points, TextSize = 20, TextColor3 = GOOD, TextTransparency = 1 })
		local cs = uiScale(chip)
		task.delay(0.12, function() punch(cs, 1.5, 0.4) end)
	end
	local sc = uiScale(card)
	sc.Scale = 0.85
	tween(sc, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(card, 0.22, { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.05 })
	tween(stripe, 0.22, { BackgroundTransparency = 0 })
	tween(label, 0.22, { TextTransparency = 0 })
	if chip then
		tween(chip, 0.22, { BackgroundTransparency = 0 })
		tween(chipText, 0.22, { TextTransparency = 0 })
	end
	-- keep at most 4 visible
	local rows = {}
	for _, c in refs.feed:GetChildren() do
		if c:IsA("Frame") then table.insert(rows, c) end
	end
	table.sort(rows, function(x, y) return x.LayoutOrder < y.LayoutOrder end)
	for i = 1, #rows - 4 do rows[i]:Destroy() end
	task.delay(2.4, function()
		if not card.Parent then return end
		tween(card, 0.25, { Position = UDim2.fromOffset(-40, 0), BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(stripe, 0.25, { BackgroundTransparency = 1 })
		tween(label, 0.25, { TextTransparency = 1 })
		if chip then
			tween(chip, 0.25, { BackgroundTransparency = 1 })
			tween(chipText, 0.25, { TextTransparency = 1 })
		end
		task.delay(0.26, function() row:Destroy() end)
	end)
end

local function boostPopup(amount: number, big: boolean)
	local l = text(refs.boostRoot, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(120, 40), Text = "+" .. amount, TextSize = if big then 40 else 28, TextColor3 = GOOD, TextStrokeTransparency = 0.4, TextStrokeColor3 = INK, ZIndex = 6 })
	local sc = uiScale(l)
	punch(sc, 1.6, 0.3)
	tween(l, 0.8, { Position = UDim2.new(0.5, 0, 0, -38) })
	task.delay(0.45, function() tween(l, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 }) end)
	task.delay(0.85, function() l:Destroy() end)
	punch(refs.boostScale, if big then 1.22 else 1.1, if big then 0.45 else 0.3)
	refs.boostFlash.BackgroundTransparency = if big then 0.3 else 0.55
	tween(refs.boostFlash, if big then 0.55 else 0.35, { BackgroundTransparency = 1 })
	-- TURBO chip lights up gold
	refs.turboChip.BackgroundColor3 = GOOD
	tween(refs.turboChip, 0.5, { BackgroundColor3 = WHITE })
	punch(refs.turboChipScale, if big then 1.35 else 1.15, 0.3)
	anim.boostHotUntil = os.clock() + (if big then 0.9 else 0.45)
	if big then
		refs.turboChipText.Text = "¡LLENO!"
		task.delay(0.9, function() refs.turboChipText.Text = "TURBO" end)
		-- rays burst out from behind the box and fade
		for i, r in refs.rays do
			r.Size = UDim2.fromOffset(40, 5)
			r.BackgroundTransparency = 0
			tween(r, 0.5 + (i % 3) * 0.05, { Size = UDim2.fromOffset(150, 3), BackgroundTransparency = 1 }, Enum.EasingStyle.Quart)
		end
	end
end

local function hitPopup(screen: Vector2, kmh: number, strong: boolean, quiet: boolean?)
	local ring = frame(overlay, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(screen.X, screen.Y), Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1 })
	local cr = Instance.new("UICorner"); cr.CornerRadius = UDim.new(0.5, 0); cr.Parent = ring
	local st = Instance.new("UIStroke"); st.Color = if strong then GOOD else WHITE; st.Thickness = if strong then 4 else 2.5; st.Parent = ring
	local size = if strong then 150 else 90
	tween(ring, 0.35, { Size = UDim2.fromOffset(size, size) })
	tween(st, 0.35, { Transparency = 1, Thickness = 0.5 })
	task.delay(0.4, function() ring:Destroy() end)
	if kmh >= 40 and not quiet then
		local l = text(overlay, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(screen.X, screen.Y - 30), Size = UDim2.fromOffset(200, 40),
			Text = kmh .. " KM/H", TextSize = if strong then 34 else 24, TextColor3 = if strong then GOOD else WHITE, TextStrokeTransparency = 0.35, TextStrokeColor3 = INK })
		local sc = uiScale(l)
		punch(sc, if strong then 1.7 else 1.3, 0.35)
		tween(l, 0.9, { Position = UDim2.fromOffset(screen.X, screen.Y - 80) })
		task.delay(0.55, function() tween(l, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 }) end)
		task.delay(0.95, function() l:Destroy() end)
	end
end

-- ev: { kind = "toast"|"pad"|"hit"|"goal", ... } (from MatchEvents); ctx: { team = player team }
local GOLD = Color3.fromRGB(255, 196, 64)
-- ---------- goal celebration (RL-style banner): team band sweeps open, one clean "¡GOL!" punches in with a light
-- sweep across it, then a chip with scorer / assist / speed. Flash + confetti around it. ~2.8 s, then fades.
local celebrating: Frame? = nil
local function celebrate(ev: { [string]: any }, color: Color3)
	if celebrating then celebrating:Destroy() end
	local RunService = game:GetService("RunService")
	local layer = frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 20 })
	celebrating = layer
	local conns = {}
	layer.Destroying:Connect(function() for _, c in conns do c:Disconnect() end end)
	local Y = 0.34

	-- flash
	local flash = frame(layer, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 0.35, ZIndex = 20 })
	tween(flash, 0.55, { BackgroundTransparency = 1 })

	-- band: opens from the centre, edges fade out
	local band = frame(layer, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, Y), Size = UDim2.new(0, 0, 0, 250), BackgroundColor3 = color, BackgroundTransparency = 0.12, ZIndex = 21 })
	local bg = Instance.new("UIGradient")
	bg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0), NumberSequenceKeypoint.new(0.8, 0), NumberSequenceKeypoint.new(1, 1) })
	bg.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, color:Lerp(Color3.new(0, 0, 0), 0.35)), ColorSequenceKeypoint.new(0.5, color), ColorSequenceKeypoint.new(1, color:Lerp(Color3.new(0, 0, 0), 0.35)) })
	bg.Parent = band
	tween(band, 0.32, { Size = UDim2.new(1, 0, 0, 250) }, Enum.EasingStyle.Quart)
	for _, top in { 0, 1 } do
		local line = frame(band, { AnchorPoint = Vector2.new(0.5, top), Position = UDim2.new(0.5, 0, top, if top == 0 then -8 else 8), Size = UDim2.new(0, 0, 0, 3), BackgroundColor3 = WHITE, BackgroundTransparency = 0.2, ZIndex = 21 })
		local lg = Instance.new("UIGradient")
		lg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
		lg.Parent = line
		task.delay(0.12, function()
			if line.Parent then tween(line, 0.45, { Size = UDim2.new(0.8, 0, 0, 3) }, Enum.EasingStyle.Quart) end
		end)
	end

	-- the word: one label + a soft offset shadow
	local holder = frame(layer, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, Y), Size = UDim2.fromOffset(1100, 270), BackgroundTransparency = 1, ZIndex = 22 })
	local hs = Instance.new("UIScale")
	hs.Scale = 2.3
	hs.Parent = holder
	local shadow = text(holder, { Position = UDim2.fromOffset(8, 10), Size = UDim2.fromScale(1, 1), Text = "¡GOL!", TextScaled = true, TextColor3 = Color3.new(0, 0, 0), TextTransparency = 1, ZIndex = 22 })
	local word = text(holder, { Size = UDim2.fromScale(1, 1), Text = "¡GOL!", TextScaled = true, TextColor3 = WHITE, TextTransparency = 1, ZIndex = 23 })
	-- a light sweep across the letters
	local shine = Instance.new("UIGradient")
	shine.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, WHITE), ColorSequenceKeypoint.new(0.45, WHITE), ColorSequenceKeypoint.new(0.5, color:Lerp(WHITE, 0.55)), ColorSequenceKeypoint.new(0.55, WHITE), ColorSequenceKeypoint.new(1, WHITE) })
	shine.Offset = Vector2.new(-1, 0)
	shine.Rotation = 20
	shine.Parent = word
	task.delay(0.08, function()
		if not holder.Parent then return end
		tween(hs, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(word, 0.12, { TextTransparency = 0 })
		tween(shadow, 0.2, { TextTransparency = 0.55 })
		task.delay(0.35, function()
			if shine.Parent then
				TweenService:Create(shine, TweenInfo.new(0.6, Enum.EasingStyle.Sine), { Offset = Vector2.new(1, 0) }):Play()
			end
		end)
	end)

	-- info chip: scorer (+ assist) + speed counting up
	local who = if ev.who == "you" then "¡ANOTASTE!" elseif ev.who == "autogol" then "AUTOGOL" elseif ev.scorerName then ev.scorerName else ""
	local chip = frame(layer, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, Y, 150), Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = INK, BackgroundTransparency = 1, ZIndex = 22 })
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 26); pad.PaddingRight = UDim.new(0, 26)
	pad.Parent = chip
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.VerticalAlignment = Enum.VerticalAlignment.Center
	cl.Padding = UDim.new(0, 22)
	cl.Parent = chip
	local nameL = text(chip, { Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X, Text = who, TextSize = 40, TextColor3 = WHITE, TextTransparency = 1, LayoutOrder = 1, ZIndex = 23 })
	local assistL
	if ev.assistName then
		assistL = text(chip, { Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X, Text = "ASIST. " .. ev.assistName, TextSize = 26, TextColor3 = GOLD, TextTransparency = 1, LayoutOrder = 2, ZIndex = 23 })
	end
	local speedL = text(chip, { Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X, Text = "0 KM/H", TextSize = 34, TextColor3 = color:Lerp(WHITE, 0.45), TextTransparency = 1, LayoutOrder = 3, ZIndex = 23 })
	task.delay(0.42, function()
		if not chip.Parent then return end
		chip.Position = UDim2.new(0.5, 0, Y, 176)
		tween(chip, 0.3, { Position = UDim2.new(0.5, 0, Y, 150), BackgroundTransparency = 0.15 }, Enum.EasingStyle.Quart)
		tween(nameL, 0.3, { TextTransparency = 0 })
		if assistL then tween(assistL, 0.3, { TextTransparency = 0 }) end
		tween(speedL, 0.3, { TextTransparency = 0 })
		local v = Instance.new("NumberValue")
		v.Changed:Connect(function(x) speedL.Text = string.format("%d KM/H", math.floor(x + 0.5)) end)
		local tw = TweenService:Create(v, TweenInfo.new(0.9, Enum.EasingStyle.Quart), { Value = ev.kmh or 0 })
		tw:Play()
		tw.Completed:Connect(function() v:Destroy() end)
	end)

	-- confetti in team colours
	local palette = { color, WHITE, GOLD, color:Lerp(WHITE, 0.4) }
	local rng = Random.new()
	for _ = 1, 60 do
		local c = frame(layer, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(rng:NextNumber(0.05, 0.95), 0, -0.05, 0),
			Size = UDim2.fromOffset(rng:NextInteger(8, 12), rng:NextInteger(14, 20)),
			BackgroundColor3 = palette[rng:NextInteger(1, #palette)],
			Rotation = rng:NextNumber(0, 360),
			ZIndex = 20,
		})
		local dur = rng:NextNumber(1.8, 2.8)
		task.delay(rng:NextNumber(0.1, 0.5), function()
			if not c.Parent then return end
			TweenService:Create(c, TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
				Position = UDim2.new(c.Position.X.Scale + rng:NextNumber(-0.1, 0.1), 0, 1.08, 0), Rotation = c.Rotation + rng:NextNumber(-500, 500),
			}):Play()
		end)
	end

	-- gentle living pulse on the word
	local t0 = os.clock()
	table.insert(conns, RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if t > 0.55 then
			hs.Scale = 1 + 0.025 * math.sin((t - 0.55) * 6)
		end
	end))

	-- out: word and chip lift away, band closes
	task.delay(2.6, function()
		if not layer.Parent then return end
		tween(word, 0.3, { TextTransparency = 1 })
		tween(shadow, 0.3, { TextTransparency = 1 })
		tween(holder, 0.3, { Position = UDim2.new(0.5, 0, Y, -30) })
		tween(chip, 0.3, { BackgroundTransparency = 1 })
		for _, l in { nameL, assistL, speedL } do
			if l then tween(l, 0.3, { TextTransparency = 1 }) end
		end
		tween(band, 0.3, { Size = UDim2.new(0, 0, 0, 250) }, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
		task.delay(0.35, function()
			if celebrating == layer then celebrating = nil end
			layer:Destroy()
		end)
	end)
end

function Hud.Event(ev: { [string]: any }, ctx: { [string]: any }?)
	if not gui then return end
	local team = if ctx then ctx.team else 0
	-- controller vibration (only with a gamepad and VIBRACIÓN on)
	if ev.kind == "hit" then
		Rumble.Event("hit", math.clamp(((ev.kmh or 0) - 20) / 100, 0, 1))
	elseif ev.kind == "pad" then
		Rumble.Event("pad", if ev.big then 1 else 0)
	elseif ev.kind == "pinch" then
		Rumble.Event("pinch")
	elseif ev.kind == "goal" then
		Rumble.Event("goal")
	elseif ev.kind == "toast" and ev.title == "DEMOLIDO" then
		Rumble.Event("demoed")
	elseif ev.kind == "toast" and ev.title == "¡DEMOLICIÓN!" then
		Rumble.Event("demo")
	end
	if ev.kind == "toast" then
		local color = if ev.color == "bad" then BAD else teamColor(team)
		toast(ev.title, ev.points, color)
		anim.points = ev.total or anim.points
		if ev.points > 0 then punch(refs.pointsScale, 1.25, 0.3) end
	elseif ev.kind == "pad" then
		boostPopup(ev.amount, ev.big)
	elseif ev.kind == "hit" then
		local cam = workspace.CurrentCamera
		local p = ev.worldStuds :: Vector3
		if p then
			local v, onScreen = cam:WorldToViewportPoint(p)
			if onScreen then hitPopup(Vector2.new(v.X, v.Y), ev.kmh, ev.strong, ev.quiet) end
		end
	elseif ev.kind == "goal" then
		anim.goal = ev
		celebrate(ev, teamColor(ev.team))
	elseif ev.kind == "pinch" then
		local names = { PISO = "PISO", PARED = "PARED", TECHO = "TECHO", KUXIR = "KUXIR", CARROS = "ENTRE CARROS", EQUIPO = "EN EQUIPO" }
		refs.pinch.Text = if ev.surface == "KUXIR" then "¡KUXIR PINCH!" else "¡PINCH!"
		refs.pinchSub.Text = string.format("%s  ·  %d KM/H%s  ·  +%d", names[ev.surface] or "", ev.kmh, if ev.count > 1 then string.format("  ·  ×%s", if ev.mult % 1 == 0 then tostring(ev.mult) else string.format("%.1f", ev.mult)) else "", ev.points)
		anim.pinchId = (anim.pinchId or 0) + 1
		local id = anim.pinchId
		refs.pinch.Rotation = -9
		refs.pinchScale.Scale = 2.6
		refs.pinch.TextTransparency = 0
		refs.pinch.TextStrokeTransparency = 0.2
		tween(refs.pinchScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(refs.pinch, 0.4, { Rotation = -3 }, Enum.EasingStyle.Back)
		refs.pinchSub.TextTransparency = 1
		refs.pinchSub.TextStrokeTransparency = 1
		task.delay(0.15, function()
			tween(refs.pinchSub, 0.2, { TextTransparency = 0, TextStrokeTransparency = 0.4 })
		end)
		refs.pinchFlash.BackgroundTransparency = 0.35
		tween(refs.pinchFlash, 0.7, { BackgroundTransparency = 1 })
		task.delay(1.3, function()
			if anim.pinchId ~= id then return end
			tween(refs.pinch, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
			tween(refs.pinchSub, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end)
	end
end

-- ---------- per-frame ----------
local function ballArrow(s: { [string]: any }, dt: number)
	local cam = workspace.CurrentCamera
	local want = false
	local carW: Vector3?, ballW: Vector3? = s.carWorld, s.ballWorld
	local vp = cam.ViewportSize
	if carW and ballW and not s.ballCam then
		local bv, bOn = cam:WorldToViewportPoint(ballW)
		local margin = 40
		local inView = bOn and bv.X > margin and bv.X < vp.X - margin and bv.Y > margin and bv.Y < vp.Y - margin
		want = not inView
	end
	anim.arrowAlpha += ((if want then 1 else 0) - anim.arrowAlpha) * (1 - math.exp(-14 * dt))
	local arrow = refs.arrow
	arrow.Visible = anim.arrowAlpha > 0.02
	if not arrow.Visible or not carW or not ballW then return end
	local cv = cam:WorldToViewportPoint(carW)
	-- direction to the ball in the camera's ground frame: 0 = straight ahead (top of the orbit)
	local look = cam.CFrame.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.zAxis
	local right = fwd:Cross(Vector3.yAxis)
	local rel = ballW - carW
	local th = math.atan2(rel:Dot(right), rel:Dot(fwd))
	local rx = vp.Y * 0.12
	local ry = rx * 0.55
	local off = Vector2.new(math.sin(th) * rx, -math.cos(th) * ry)
	arrow.Position = UDim2.fromOffset(cv.X + off.X, cv.Y + off.Y - vp.Y * 0.01)
	arrow.Rotation = math.deg(math.atan2(off.Y, off.X)) + 90
	-- closer ball -> bigger, faster pulse
	local dist = rel.Magnitude / 0.05 -- studs -> uu
	local near = math.clamp(1 - dist / 4000, 0, 1)
	local pulse = (os.clock() * (2 + 4 * near)) % 1
	refs.arrowScale.Scale = (0.85 + 0.35 * near) * (0.6 + 0.4 * anim.arrowAlpha)
	refs.arrowOuter.Position = UDim2.new(0.5, 0, 0.5, -8 - 10 * pulse)
	for _, bar in refs.arrowInner:GetChildren() do
		if bar:IsA("Frame") then bar.BackgroundTransparency = 1 - anim.arrowAlpha end
	end
	for _, bar in refs.arrowOuter:GetChildren() do
		if bar:IsA("Frame") then bar.BackgroundTransparency = 1 - anim.arrowAlpha * (1 - pulse) * 0.8 end
	end
end

local function streaks(on: boolean, dt: number)
	anim.streak += ((if on then 1 else 0) - anim.streak) * (1 - math.exp(-6 * dt))
	local vp = workspace.CurrentCamera.ViewportSize
	local c = vp / 2
	local diag = vp.Magnitude / 2
	for _, st in refs.streaks do
		st.phase = (st.phase + dt * st.speed) % 1
		local r = diag * (0.55 + 0.45 * st.phase)
		st.f.Position = UDim2.fromOffset(c.X + math.cos(st.ang) * r, c.Y + math.sin(st.ang) * r)
		st.f.BackgroundTransparency = 1 - anim.streak * 0.55 * math.sin(st.phase * math.pi)
	end
end

function Hud.Update(s: { [string]: any })
	local now = os.clock()
	local dt = math.clamp(now - anim.lastClock, 0, 0.1)
	anim.lastClock = now
	-- keep the layout proportional on small windows (designed for 1080p)
	local cam = workspace.CurrentCamera
	refs.scale.Scale = math.clamp(cam.ViewportSize.Y / 1080, 0.6, 1.2)

	-- score: punch the digit that changed, flash the board in that team's colour
	for _, side in { { key = "blue", team = 0 }, { key = "orange", team = 1 } } do
		local v = s[side.key]
		local lastKey = if side.team == 0 then "lastBlue" else "lastOrange"
		if v ~= anim[lastKey] then
			if v > anim[lastKey] then
				punch(refs[side.key .. "Scale"], 1.9, 0.5)
				punch(refs.boardScale, 1.12, 0.4)
				refs.boardFlash.BackgroundColor3 = teamColor(side.team)
				refs.boardFlash.BackgroundTransparency = 0.25
				tween(refs.boardFlash, 0.6, { BackgroundTransparency = 1 })
			end
			anim[lastKey] = v
		end
	end
	refs.blue.Text = tostring(s.blue)
	refs.orange.Text = tostring(s.orange)

	if s.timerText then
		refs.timer.Text = s.timerText
		refs.timer.TextColor3 = WHITE
	else
		local t = math.max(0, math.ceil(s.timeLeft))
		refs.timer.Text = string.format("%d:%02d", t // 60, t % 60)
		refs.timer.TextColor3 = if t <= 30 and t > 0 then BAD else WHITE
		if t ~= anim.lastSecond then
			if t <= 10 and t > 0 and anim.lastSecond > t then punch(refs.timerScale, 1.22, 0.35) end
			anim.lastSecond = t
		end
	end

	-- points counter ticks up
	anim.pointsShown += (anim.points - anim.pointsShown) * (1 - math.exp(-10 * dt))
	if math.abs(anim.points - anim.pointsShown) < 0.5 then anim.pointsShown = anim.points end
	if s.timerNote then
		-- 0:00 with the ball still in the air: the chip turns into a pulsing warning
		refs.points.Text = s.timerNote
		refs.points.TextColor3 = BAD
		refs.pointsScale.Scale = 1 + 0.06 * math.abs(math.sin(now * 6))
	else
		refs.points.Text = string.format("%d PTS", math.floor(anim.pointsShown + 0.5))
		refs.points.TextColor3 = Color3.fromRGB(46, 38, 30)
	end

	-- boost: counts up smoothly, drains immediately; low boost pulses; full tank shines
	local boost = math.clamp(s.boost, 0, 100)
	local rate = if boost > anim.boostShown then 9 else 40
	anim.boostShown += (boost - anim.boostShown) * (1 - math.exp(-rate * dt))
	if math.abs(boost - anim.boostShown) < 0.5 then anim.boostShown = boost end
	local prevShown = anim.prevShown or anim.boostShown
	local shown = anim.boostShown
	anim.prevShown = shown
	refs.boostNum.Text = tostring(math.floor(shown + 0.5))
	for i, fl in refs.segFlash do
		local edge = i * 25
		if prevShown < edge - 0.5 and shown >= edge - 0.5 then
			fl.BackgroundTransparency = 0.1
			tween(fl, 0.35, { BackgroundTransparency = 1 })
		end
	end
	if anim.boostHotUntil and now < anim.boostHotUntil then
		refs.boostNum.TextColor3 = GOOD
	elseif boost < 20 and not s.unlimitedBoost then
		local k = 0.5 + 0.5 * math.sin(now * 9)
		refs.boostNum.TextColor3 = WHITE:Lerp(BAD, k)
	else
		refs.boostNum.TextColor3 = WHITE
	end
	if boost >= 99.5 and anim.lastBoost < 99.5 and not s.unlimitedBoost then
		refs.shine.Visible = true
		refs.shine.Position = UDim2.new(0, -60, 0, 0)
		tween(refs.shine, 0.55, { Position = UDim2.new(0, 260, 0, 0) }, Enum.EasingStyle.Sine)
		task.delay(0.56, function() refs.shine.Visible = false end)
	end
	anim.lastBoost = boost
	refs.boostBar.Size = UDim2.fromScale(shown / 100, 1)
	for i, fill in refs.segments do
		local v = math.clamp((shown - (i - 1) * 25) / 25, 0, 1)
		fill.Size = UDim2.fromScale(v, 1)
	end

	-- centre message: slam in whenever it changes; goal gets a team band + subtitle
	local msg = s.message or ""
	if msg == "¡GOL!" then msg = "" end -- the goal has its own celebration layer
	if msg ~= anim.lastMsg then
		anim.lastMsg = msg
		if msg ~= "" then
			pcall(function() require(script.Parent.Sounds).Message(msg) end)
			refs.message.TextTransparency = 1
			refs.message.TextStrokeTransparency = 1
			refs.messageScale.Scale = if msg == "¡GOL!" then 2.6 else 1.9
			tween(refs.messageScale, if msg == "¡GOL!" then 0.45 else 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			tween(refs.message, 0.15, { TextTransparency = 0, TextStrokeTransparency = 0.35 })
		end
		if msg == "¡GOL!" then
			local g = anim.goal
			refs.band.Visible = true
			refs.band.BackgroundColor3 = s.messageColor or BLUE
			refs.band.Size = UDim2.new(0, 0, 0, 150)
			tween(refs.band, 0.35, { Size = UDim2.new(1, 0, 0, 150) }, Enum.EasingStyle.Quart)
			local who = if g and g.who == "you" then "¡ANOTASTE!" elseif g and g.who == "team" then "ANOTA TU EQUIPO" elseif g and g.who == "autogol" then "AUTOGOL" else "ANOTA EL RIVAL"
			refs.sub.Text = if g then string.format("%s   ·   %d KM/H", who, g.kmh) else ""
			refs.sub.TextTransparency = 1
			task.delay(0.2, function() tween(refs.sub, 0.25, { TextTransparency = 0 }) end)
			refs.message.TextColor3 = WHITE
		else
			if refs.band.Visible then
				tween(refs.band, 0.25, { Size = UDim2.new(0, 0, 0, 150) }, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
				task.delay(0.26, function() if anim.lastMsg ~= "¡GOL!" then refs.band.Visible = false end end)
			end
			refs.sub.Text = ""
		end
	end
	refs.message.Text = msg
	if msg ~= "¡GOL!" then
		refs.message.TextColor3 = s.messageColor or WHITE
	end

	refs.actions.Visible = s.help
	refs.debugFrame.Visible = s.debugText ~= nil
	if s.debugText then
		refs.debug.Text = s.debugText
	end
	setTags(s.tags or {})

	ballArrow(s, dt)
	streaks(s.supersonic == true, dt)
end

function Hud.ResetStats()
	anim.points = 0
	anim.pointsShown = 0
	anim.lastBlue, anim.lastOrange = 0, 0
	if refs.feed then
		for _, c in refs.feed:GetChildren() do
			if c:IsA("Frame") then c:Destroy() end
		end
	end
end

function Hud.SetVisible(on: boolean)
	if gui then
		gui.Enabled = on
	end
	if overlay then
		overlay.Enabled = on
	end
end

Hud.BLUE = BLUE
Hud.ORANGE = ORANGE
return Hud
