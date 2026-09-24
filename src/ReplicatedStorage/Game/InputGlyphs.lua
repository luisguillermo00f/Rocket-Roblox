--!strict
-- InputGlyphs.lua: keyboard / gamepad awareness for every screen.
--   * which device the player is using right now (last input): "keyboard" or "gamepad" (touch counts as keyboard)
--   * button prompts: Chip(parent, action) draws the key ("ENTER", "SHIFT"...) or the controller's own glyph
--     (Roblox's official images from UserInputService:GetImageForKeyCode: Xbox or PlayStation, whichever is plugged
--     in), and swaps live when the player switches device. HintBar() lays out "glyph + label" pairs.
--   * menus with a controller: panels push themselves on a focus stack (PushPanel) with a default button; with a
--     gamepad the top panel's button is selected (GuiService.SelectedObject, engine navigation with d-pad / stick,
--     A presses it), B calls the panel's back. A gold selection frame replaces Roblox's default highlight.
--   * OnDirection(): d-pad AND left stick as menu directions, with key-repeat, for the hand-made menus (the main
--     menu words, submenus, settings rows) that don't use engine selection.
-- The per-player "AUTO / TECLADO / MANDO" icon preference lives in GraphicsSettings ("glyphs"). Gameplay actions
-- (jump, boost, ball cam...) take their key and button from Keybinds, so a rebind redraws every prompt.
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local InputGlyphs = {}

local KC = Enum.KeyCode
local INK = Color3.fromRGB(18, 18, 20)
local CHIP = Color3.fromRGB(12, 12, 14)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 196, 64)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)

-- action -> keyboard label + controller button(s). One table for the whole game so prompts never disagree.
InputGlyphs.ACTIONS = {
	confirm = { key = "ENTER", pad = { KC.ButtonA } },
	back = { key = "ESC", pad = { KC.ButtonB } },
	alt = { key = "R", pad = { KC.ButtonX } }, -- secondary modal action
	menu = { key = "M", pad = { KC.ButtonY } }, -- "go to menu" style modal action
	pause = { key = "M", pad = { KC.ButtonSelect } }, -- tap (Roblox keeps Start for its own menu)
	profile = { key = "P", pad = { KC.ButtonY } },
	invite = { key = "F", pad = { KC.ButtonX } },
	join = { key = "U", pad = { KC.ButtonX } }, -- join a private room / party by code (main menu)
	tabs = { key = "Q/E", pad = { KC.ButtonL1, KC.ButtonR1 } },
	jump = { key = "ESPACIO", pad = { KC.ButtonA } },
	boost = { key = "SHIFT", pad = { KC.ButtonB } },
	powerslide = { key = "CTRL", pad = { KC.ButtonX } },
	airroll = { key = "Q/E", pad = { KC.ButtonL1, KC.ButtonR1 } },
	ballcam = { key = "C", pad = { KC.ButtonY } },
	scoreboard = { key = "BLOQ MAYÚS", pad = { KC.ButtonSelect } },
	controls = { key = "H", pad = { KC.ButtonR3 } },
	throttle = { key = "W", pad = { KC.ButtonR2 } },
	brake = { key = "S", pad = { KC.ButtonL2 } },
	steer = { key = "A/D", pad = { KC.Thumbstick1 } },
	camera = { key = "RATÓN", pad = { KC.Thumbstick2 } },
	skip = { key = "ESPACIO", pad = { KC.ButtonA } },
	minigames = { key = "M", pad = { KC.ButtonY } },
	cancel = { key = "", pad = { KC.ButtonX } }, -- cancel matchmaking (controller shortcut only)
	reset = { key = "R", pad = { KC.DPadDown } },
	launchBall = { key = "G", pad = { KC.DPadRight } },
	pinchDrill = { key = "T", pad = { KC.DPadLeft } },
	unlimitedBoost = { key = "B", pad = { KC.DPadUp } },
}

-- gameplay prompts -> Keybinds actions (a list = several buttons side by side, e.g. air roll left + right)
local BIND_OF: { [string]: any } = {
	jump = "jump", boost = "boost", powerslide = "powerslide", airroll = { "airRollLeft", "airRollRight" },
	ballcam = "ballCam", scoreboard = "scoreboard", pause = "pause", controls = "help", throttle = "throttle",
	brake = "reverse", steer = { "steerLeft", "steerRight" }, reset = "reset", launchBall = "launchBall",
	pinchDrill = "pinchDrill", unlimitedBoost = "unlimitedBoost",
}
local Keybinds: any = nil
local function binds(): any
	if Keybinds == nil then
		local ok, m = pcall(function() return require(script.Parent.Keybinds) end)
		Keybinds = if ok then m else false
	end
	return Keybinds
end

-- what a prompt shows right now: { key = keyboard label, pad = { KeyCode } }
function InputGlyphs.Def(action: string): any
	local base = InputGlyphs.ACTIONS[action] or { key = action, pad = {} }
	local m = BIND_OF[action]
	local K = binds()
	if not m or not K then return base end
	local ids = if type(m) == "table" then m else { m }
	local keys, pads = {}, {}
	for _, id in ids do
		table.insert(keys, K.KbLabel(id))
		local kc = K.PadKeyCode(id)
		if kc and not table.find(pads, kc) then table.insert(pads, kc) end
	end
	return { key = table.concat(keys, "/"), pad = if #pads > 0 then pads else base.pad }
end

-- modal key labels (MainMenu.Modal) -> action
local KEY_ACTION = { ENTER = "confirm", ESC = "back", R = "alt", M = "menu", F = "invite", P = "profile" }
function InputGlyphs.ActionForKey(key: string): string?
	return KEY_ACTION[key]
end

-- ---------------------------------------------------------------- device mode
local mode = "keyboard"
local modeListeners: { (string) -> () } = {}

local function preference(): string
	local ok, GS = pcall(function() return require(script.Parent.GraphicsSettings) end)
	return if ok and GS then (GS.Get("glyphs") or "auto") else "auto"
end

local function computeMode(t: Enum.UserInputType): string?
	local n = t.Name
	if string.sub(n, 1, 7) == "Gamepad" then return "gamepad" end
	if t == Enum.UserInputType.Keyboard or string.sub(n, 1, 5) == "Mouse" or t == Enum.UserInputType.Touch then return "keyboard" end
	return nil
end

-- what the prompts should show (the preference can force one)
function InputGlyphs.Mode(): string
	local p = preference()
	if p == "gamepad" or p == "keyboard" then return p end
	return mode
end

function InputGlyphs.IsGamepad(): boolean
	return InputGlyphs.Mode() == "gamepad"
end

-- fn(mode) whenever the prompts should change; returns a disconnect function
function InputGlyphs.OnModeChanged(fn: (string) -> ()): () -> ()
	table.insert(modeListeners, fn)
	return function()
		local i = table.find(modeListeners, fn)
		if i then table.remove(modeListeners, i) end
	end
end

local lastShown = "keyboard"
local function notify()
	local m = InputGlyphs.Mode()
	if m == lastShown then return end
	lastShown = m
	for _, fn in table.clone(modeListeners) do
		task.spawn(fn, m)
	end
	InputGlyphs.RefreshFocus()
end
InputGlyphs.Refresh = notify -- call after the glyph preference changes

-- ---------------------------------------------------------------- glyph images
local function imageFor(kc: Enum.KeyCode): string
	local ok, img = pcall(function() return UIS:GetImageForKeyCode(kc) end)
	return if ok and type(img) == "string" then img else ""
end

-- text fallback when an image isn't available (Xbox names; PlayStation shapes come as images)
local PAD_TEXT = {
	ButtonA = "A", ButtonB = "B", ButtonX = "X", ButtonY = "Y", ButtonL1 = "LB", ButtonR1 = "RB", ButtonL2 = "LT",
	ButtonR2 = "RT", ButtonL3 = "L3", ButtonR3 = "R3", ButtonStart = "≡", ButtonSelect = "⧉", DPadUp = "↑", DPadDown = "↓",
	DPadLeft = "←", DPadRight = "→", Thumbstick1 = "L", Thumbstick2 = "R",
}

-- ---------------------------------------------------------------- chips
-- A key chip that follows the device. opts: { dark = bool, height = px, anchorRight = bool (default true),
-- position = UDim2?, anchor = Vector2? }. Returns the frame; its width fits the content and changes with the mode.
function InputGlyphs.Chip(parent: Instance, action: string, opts: any?): Frame
	local o = opts or {}
	local h = o.height or 30
	local dark = o.dark ~= false
	local chip = Instance.new("Frame")
	chip.Name = "Glyph_" .. action
	chip.BorderSizePixel = 0
	local right = o.anchorRight ~= false
	chip.AnchorPoint = o.anchor or (if right then Vector2.new(1, 0.5) else Vector2.new(0, 0.5))
	chip.Position = o.position or (if right then UDim2.new(1, -10, 0.5, 0) else UDim2.new(0, 10, 0.5, 0))
	chip.ZIndex = o.zIndex or 4
	chip.Parent = parent

	local function draw(m: string)
		for _, c in chip:GetChildren() do c:Destroy() end
		local def = InputGlyphs.Def(action)
		local pad = def.pad or {}
		if m == "gamepad" and #pad > 0 then
			-- controller glyphs: the images are already round buttons, so the chip itself goes transparent
			chip.BackgroundTransparency = 1
			local size = h + 2
			chip.Size = UDim2.fromOffset(#pad * size + (#pad - 1) * 2, size)
			for i, kc in pad do
				local img = imageFor(kc)
				if img ~= "" then
					local il = Instance.new("ImageLabel")
					il.BackgroundTransparency = 1
					il.Image = img
					il.Size = UDim2.fromOffset(size, size)
					il.Position = UDim2.fromOffset((i - 1) * (size + 2), 0)
					il.ScaleType = Enum.ScaleType.Fit
					il.ZIndex = chip.ZIndex + 1
					il.Parent = chip
				else
					local b = Instance.new("TextLabel")
					b.BackgroundColor3 = if dark then CHIP else WHITE
					b.Size = UDim2.fromOffset(size, size)
					b.Position = UDim2.fromOffset((i - 1) * (size + 2), 0)
					b.FontFace = OSWALD
					b.TextSize = math.floor(size * 0.5)
					b.TextColor3 = if dark then WHITE else INK
					b.Text = PAD_TEXT[kc.Name] or kc.Name
					b.ZIndex = chip.ZIndex + 1
					local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = b
					b.Parent = chip
				end
			end
		elseif def.key == "" then
			chip.BackgroundTransparency = 1
			chip.Size = UDim2.fromOffset(0, h)
		else
			chip.BackgroundTransparency = 0
			chip.BackgroundColor3 = if dark then CHIP else WHITE
			local label = def.key
			local w = math.max(h, 16 + #label * math.floor(h * 0.42))
			chip.Size = UDim2.fromOffset(w, h)
			local t = Instance.new("TextLabel")
			t.BackgroundTransparency = 1
			t.Size = UDim2.fromScale(1, 1)
			t.FontFace = OSWALD
			t.TextSize = math.floor(h * (if #label > 3 then 0.55 else 0.62))
			t.TextColor3 = if dark then WHITE else INK
			t.Text = label
			t.ZIndex = chip.ZIndex + 1
			t.Parent = chip
		end
	end
	draw(InputGlyphs.Mode())
	local off = InputGlyphs.OnModeChanged(draw)
	chip.Destroying:Connect(off)
	return chip
end

-- "glyph LABEL · glyph LABEL" row (right-aligned by default). items: { { action, label } }
function InputGlyphs.HintBar(parent: Instance, items: { { string } }, opts: any?): Frame
	local o = opts or {}
	local bar = Instance.new("Frame")
	bar.Name = "HintBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = o.anchor or Vector2.new(1, 1)
	bar.Position = o.position or UDim2.new(1, -56, 1, -36)
	bar.Size = UDim2.fromOffset(0, o.height or 32)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Parent = parent
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.HorizontalAlignment = if bar.AnchorPoint.X > 0.5 then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = bar
	for i, it in items do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(0, o.height or 32)
		holder.AutomaticSize = Enum.AutomaticSize.X
		holder.LayoutOrder = i * 2
		holder.Parent = bar
		local hl = Instance.new("UIListLayout")
		hl.FillDirection = Enum.FillDirection.Horizontal
		hl.VerticalAlignment = Enum.VerticalAlignment.Center
		hl.Padding = UDim.new(0, 6)
		hl.SortOrder = Enum.SortOrder.LayoutOrder
		hl.Parent = holder
		local chip = InputGlyphs.Chip(holder, it[1], { dark = o.dark ~= false, height = (o.height or 32) - 6, position = UDim2.fromOffset(0, 0), anchor = Vector2.zero })
		chip.LayoutOrder = 1
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AutomaticSize = Enum.AutomaticSize.X
		l.Size = UDim2.fromOffset(0, o.height or 32)
		l.FontFace = OSWALD_REG
		l.TextSize = o.textSize or 17
		l.TextColor3 = o.textColor or WHITE
		l.TextTransparency = o.textTransparency or 0.25
		l.Text = it[2]
		l.LayoutOrder = 2
		l.Parent = holder
		if i < #items then
			local dot = Instance.new("TextLabel")
			dot.BackgroundTransparency = 1
			dot.Size = UDim2.fromOffset(10, o.height or 32)
			dot.FontFace = OSWALD_REG
			dot.TextSize = o.textSize or 17
			dot.TextColor3 = o.textColor or WHITE
			dot.TextTransparency = 0.55
			dot.Text = "·"
			dot.LayoutOrder = i * 2 + 1
			dot.Parent = bar
		end
	end
	return bar
end

-- ---------------------------------------------------------------- panels + engine selection
type Panel = { root: Instance, default: () -> GuiObject?, back: (() -> ())?, id: number }
local stack: { Panel } = {}
local lastClosed = -1
local nextId = 0

local function alive(o: Instance?): boolean
	return o ~= nil and o:IsDescendantOf(game)
end

-- on screen: every GuiObject up the chain Visible and its ScreenGui Enabled (a lobby hidden during a round
-- keeps its panel on the stack but must not take the controller)
local function shown(o: Instance): boolean
	local x: Instance? = o
	while x do
		if x:IsA("GuiObject") and not x.Visible then return false end
		if x:IsA("LayerCollector") then return (x :: any).Enabled end
		x = x.Parent
	end
	return false
end

local function topPanel(): Panel?
	for i = #stack, 1, -1 do
		local p = stack[i]
		if alive(p.root) and shown(p.root) then return p end
	end
	return nil
end

function InputGlyphs.RefreshFocus()
	local top = topPanel()
	if not top then
		local sel = GuiService.SelectedObject
		if sel and (not InputGlyphs.IsGamepad() or not shown(sel)) then GuiService.SelectedObject = nil end
		return
	end
	if InputGlyphs.IsGamepad() then
		local sel = GuiService.SelectedObject
		if not (sel and sel:IsDescendantOf(top.root) and sel.Visible) then
			local d = top.default()
			if d and alive(d) then GuiService.SelectedObject = d end
		end
	elseif GuiService.SelectedObject then
		GuiService.SelectedObject = nil
	end
end

-- A screen that takes the controller: root (its ScreenGui or frame), default() -> the button to select first, and
-- what B does. Returns pop(); the panel also pops itself when root is destroyed.
function InputGlyphs.PushPanel(root: Instance, default: () -> GuiObject?, back: (() -> ())?): () -> ()
	nextId += 1
	local p: Panel = { root = root, default = default, back = back, id = nextId }
	table.insert(stack, p)
	local popped = false
	local function pop()
		if popped then return end
		popped = true
		lastClosed = os.clock()
		local i = table.find(stack, p)
		if i then table.remove(stack, i) end
		local sel = GuiService.SelectedObject
		if sel and sel:IsDescendantOf(root) then GuiService.SelectedObject = nil end
		InputGlyphs.RefreshFocus()
	end
	root.Destroying:Connect(pop)
	task.defer(InputGlyphs.RefreshFocus)
	return pop
end

-- is a controller-driven panel on screen? (hand-made menus underneath should ignore the pad meanwhile)
function InputGlyphs.PanelOpen(): boolean
	for i = #stack, 1, -1 do
		if not alive(stack[i].root) then table.remove(stack, i) end
	end
	return topPanel() ~= nil
end

-- hand-made menus (main menu words, lobby...) register themselves so gameplay pad buttons (Y ball cam, d-pad
-- training tools, Start pause) don't fire underneath them
local menus: { [string]: boolean } = {}
function InputGlyphs.SetMenu(name: string, open: boolean)
	menus[name] = if open then true else nil
end
function InputGlyphs.MenuActive(): boolean
	return next(menus) ~= nil or InputGlyphs.PanelOpen()
end

-- a panel closed this very instant (listeners of one press run newest-first, so the press that closed a menu
-- can still reach older handlers after it's gone)
function InputGlyphs.JustClosed(): boolean
	return os.clock() - lastClosed < 0.1
end

-- select a specific button now (gamepad only)
function InputGlyphs.Focus(obj: GuiObject?)
	if obj and InputGlyphs.IsGamepad() then GuiService.SelectedObject = obj end
end

-- ---------------------------------------------------------------- directions for hand-made menus
local dirListeners: { (string) -> () } = {}
function InputGlyphs.OnDirection(fn: (string) -> ()): () -> ()
	table.insert(dirListeners, fn)
	return function()
		local i = table.find(dirListeners, fn)
		if i then table.remove(dirListeners, i) end
	end
end
local function fireDir(d: string)
	for _, fn in table.clone(dirListeners) do task.spawn(fn, d) end
end

local DPAD = { [KC.DPadUp] = "Up", [KC.DPadDown] = "Down", [KC.DPadLeft] = "Left", [KC.DPadRight] = "Right" }
local held: { dir: string?, nextAt: number } = { dir = nil, nextAt = 0 }
local STICK_ON, STICK_OFF = 0.6, 0.35
local REPEAT_FIRST, REPEAT_NEXT = 0.38, 0.11

-- ---------------------------------------------------------------- init
local started = false
function InputGlyphs.Start()
	if started then return end
	started = true
	GuiService.AutoSelectGuiEnabled = false -- Select is the scoreboard in a match, not "toggle UI navigation"
	local first = computeMode(UIS:GetLastInputType())
	if first then mode = first end
	if UIS.GamepadEnabled and not UIS.KeyboardEnabled then mode = "gamepad" end
	lastShown = InputGlyphs.Mode()
	pcall(function()
		require(script.Parent.GraphicsSettings).OnChanged(notify) -- the "ICONOS" preference
	end)
	-- a rebind: redraw every prompt with the same mode
	local K = binds()
	if K then
		K.OnChanged(function()
			local m = InputGlyphs.Mode()
			for _, fn in table.clone(modeListeners) do task.spawn(fn, m) end
		end)
	end
	UIS.LastInputTypeChanged:Connect(function(t)
		if t == Enum.UserInputType.Keyboard then return end -- InputBegan decides from the key
		if t == Enum.UserInputType.MouseMovement then return end -- a nudge isn't a device switch (see InputChanged)
		local m = computeMode(t)
		if m and m ~= mode then
			mode = m
			notify()
		end
	end)
	UIS.GamepadConnected:Connect(function()
		lastShown = "" -- a different controller may use different glyphs (Xbox <-> PlayStation)
		notify()
	end)

	-- on-brand selection frame instead of Roblox's default highlight
	task.spawn(function()
		local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
		local sel = Instance.new("Frame")
		sel.Name = "GamepadSelection"
		sel.BackgroundColor3 = GOLD
		sel.BackgroundTransparency = 0.82
		sel.Size = UDim2.new(1, 8, 1, 8)
		sel.Position = UDim2.fromOffset(-4, -4)
		local st = Instance.new("UIStroke")
		st.Color = GOLD
		st.Thickness = 3
		st.Parent = sel
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = sel
		pg.SelectionImageObject = sel
	end)

	-- B on the top panel = back
	UIS.InputBegan:Connect(function(input, processed)
		local kc = input.KeyCode
		-- device from the key itself too (some drivers / remote inputs report pad buttons with a keyboard type)
		local kn = kc.Name
		local m = if string.sub(kn, 1, 6) == "Button" or string.sub(kn, 1, 4) == "DPad" or string.sub(kn, 1, 10) == "Thumbstick" then "gamepad"
			elseif input.UserInputType == Enum.UserInputType.Keyboard and kc ~= Enum.KeyCode.Unknown then "keyboard"
			else nil
		if m and m ~= mode then
			mode = m
			notify()
		end
		if DPAD[kc] then
			held.dir = DPAD[kc]
			held.nextAt = os.clock() + REPEAT_FIRST
			if not InputGlyphs.PanelOpen() then fireDir(DPAD[kc]) end
		elseif kc == KC.ButtonB then
			local top = topPanel()
			if top and top.back then top.back() end
		end
	end)
	-- the mouse takes over only after a real move (focusing the window or bumping the desk shouldn't swap prompts)
	local moved, movedAt = 0, 0
	UIS.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or mode ~= "gamepad" then
			moved = 0
			return
		end
		local now = os.clock()
		if now - movedAt > 0.4 then moved = 0 end -- scattered nudges don't add up
		movedAt = now
		moved += input.Delta.Magnitude
		if moved > 40 then
			moved = 0
			mode = "keyboard"
			notify()
		end
	end)
	UIS.InputEnded:Connect(function(input)
		if DPAD[input.KeyCode] and held.dir == DPAD[input.KeyCode] then held.dir = nil end
	end)
	-- left stick as d-pad (with hysteresis and key-repeat) for the hand-made menus
	local stickDir: string? = nil
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if UIS.GamepadEnabled then
			local pos = Vector2.zero
			for _, s in UIS:GetGamepadState(Enum.UserInputType.Gamepad1) do
				if s.KeyCode == KC.Thumbstick1 then pos = Vector2.new(s.Position.X, s.Position.Y) end
			end
			local mag = pos.Magnitude
			local d: string? = stickDir
			if mag < STICK_OFF then
				d = nil
			elseif mag > STICK_ON then
				d = if math.abs(pos.X) > math.abs(pos.Y) then (if pos.X > 0 then "Right" else "Left") else (if pos.Y > 0 then "Up" else "Down")
			end
			if d ~= stickDir then
				stickDir = d
				if d then
					held.dir = d
					held.nextAt = now + REPEAT_FIRST
					if not InputGlyphs.PanelOpen() then fireDir(d) end
				elseif held.dir and not UIS:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, KC.DPadUp)
					and not UIS:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, KC.DPadDown)
					and not UIS:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, KC.DPadLeft)
					and not UIS:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, KC.DPadRight) then
					held.dir = nil
				end
			end
		end
		-- key-repeat while held
		if held.dir and now >= held.nextAt then
			held.nextAt = now + REPEAT_NEXT
			if not InputGlyphs.PanelOpen() then fireDir(held.dir) end
		end
	end)
end

return InputGlyphs
