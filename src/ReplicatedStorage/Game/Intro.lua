--!strict
-- Intro.lua: pre-match car introduction cinematic for 1v1 / 2v2 (~6.5 s, skippable with SPACE/ENTER).
--
-- The cars are the real ones (hitbox config + team skin) driven by scripted controls in a private copy of the
-- physics world, so every suspension bounce, jump, double jump and barrel roll is simulated by the RocketSim port.
-- The run is deterministic, so it is pre-simulated once to find the exact tick where the trajectories cross; the
-- freeze-frame and the crossing camera are built around that tick (it adapts to any hitbox).
--
-- Shots (sim time drives the cuts):
--   1. close dolly along my car (my pair in 2v2)       2. opponent(s) rushing past a low fixed camera
--   3. low wide shot from behind, extreme FOV; the cars suddenly accelerate away (speed ramp + FOV punch)
--   4. broadcast split: one full-quality camera low behind the pair, each team on its own half of the frame with a
--      team-coloured divider and name tags (a real render - ViewportFrames looked flat and low-res)
--   5. side 3/4 shot as the trajectories cross, ramping into slow motion -> freeze, names revealed over the cars
--   6. whip + flash into the kickoff camera
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local UIS = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Phys = script.Parent.Parent.Physics
local World = require(Phys.World)
local CarPhysics = require(Phys.CarPhysics)
local Q = require(Phys.Quaternion)
local RenderMap = require(script.Parent.RenderMap)
local CarVisual = require(script.Parent.CarVisual)
local GS = require(script.Parent.GraphicsSettings)
local InputGlyphs = require(script.Parent.InputGlyphs)

local Intro = {}

local BT = 50
local TICK = 1 / 120
local S = RenderMap.S

-- choreography (sim seconds), tuned headless: steer 0.25 for 0.35 s makes the paths cross at midfield ~0.65 s
-- after the jump, the high flyer ~185 uu above the low one
local ACCEL = 2.4
local STEER0, STEER_T, STEER = 2.5, 0.35, 0.25
local JUMP = 3.2
local Y_FRONT, Y_BACK, LANE = -3800, -4250, 420

-- shot boundaries (sim seconds)
local T_SHOT2, T_WIDE, T_SPLIT, T_CROSS = 1.1, 2.05, 2.95, 3.62
local FREEZE_HOLD, OUTRO = 1.75, 0.45

-- licensed library sounds (Pro Sound Effects / APM on the Roblox Creator Store)
local SFX = { cut = 9126229267, by = 9126229255, zoom = 9126228631, impact = 1837830314, freeze = 1837830324 }

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local INK = Color3.fromRGB(14, 14, 18)
local WHITE = Color3.new(1, 1, 1)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)

local gui: ScreenGui? = nil
local refs: { [string]: any } = {}
local st: any = nil -- running intro

-- string.upper only maps ASCII; names like "Vórtice" need the accented capitals too
local ACCENTS = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" }
local function upper(str: string): string
	local out = string.upper(str)
	for lo, up in ACCENTS do
		out = out:gsub(lo, up)
	end
	return out
end

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end
local function tween(o: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
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
	l.TextColor3 = WHITE
	l.TextSize = 24
	for k, v in props do (l :: any)[k] = v end
	l.Parent = parent
	return l
end
local function sfx(id: number, vol: number?, speed: number?)
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://" .. id
	s.Volume = vol or 0.6
	s.PlaybackSpeed = speed or 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
	task.delay(8, function() if s.Parent then s:Destroy() end end)
end

-- ---------------------------------------------------------------- scripted driving (tick based -> deterministic)
-- role: { lane = -1 | 1, high = boolean }
local function drive(role: any, t: number, c: any)
	for k in c do
		if type(c[k]) == "number" then c[k] = 0 else c[k] = false end
	end
	c.throttle = if t < ACCEL then 0.4 else 1
	c.boost = t >= ACCEL + (if role.lane > 0 then 0.05 else 0)
	if t >= STEER0 and t < STEER0 + STEER_T then
		c.steer = STEER * role.lane
	end
	local roll = if role.lane < 0 then 1 else -1
	if role.high then
		if t >= JUMP and t < JUMP + 0.2 then c.jump = true end
		if t >= JUMP + 0.3 and t < JUMP + 0.34 then c.jump = true end -- double jump
		if t >= JUMP + 0.34 and t < JUMP + 0.5 then c.pitch = 0.5 end
		if t >= JUMP + 0.5 then c.roll = roll end
	else
		if t >= JUMP + 0.05 and t < JUMP + 0.13 then c.jump = true end
		if t >= JUMP + 0.3 then c.roll = roll end
	end
end

-- entries: { { team, config, name, tag } } in order: 1v1 = me, opponent; 2v2 = me, mate, opp1, opp2
local function roles(n: number): { any }
	if n >= 4 then
		return {
			{ lane = -1, high = true, y = Y_FRONT, pair = 1 }, { lane = -1, high = false, y = Y_BACK, pair = 2 },
			{ lane = 1, high = false, y = Y_FRONT, pair = 1 }, { lane = 1, high = true, y = Y_BACK, pair = 2 },
		}
	end
	return { { lane = -1, high = true, y = Y_FRONT, pair = 1 }, { lane = 1, high = false, y = Y_FRONT, pair = 1 } }
end

local function buildWorld(entries: { any }, rl: { any })
	local w = World.new({ seed = 7, boostPads = false })
	w.ballEnabled = false
	local cars = {}
	for i, e in entries do
		local car = w:AddCar(e.team, e.config)
		CarPhysics.ResetState(car, Vector3.new(LANE * rl[i].lane, rl[i].y, 17), math.pi / 2, 100, true)
		cars[i] = car
	end
	w:Step(1)
	return w, cars
end

local function stepWorld(w: any, cars: { any }, rl: { any }, tick: number)
	local t = tick * TICK
	for i, car in cars do
		drive(rl[i], t, car.controls)
	end
	w:Step()
end

-- pre-simulate: find the tick where pair 1 crosses (closest in x while airborne) -> freeze a few ticks later
local function plan(entries: { any }, rl: { any }): (number, Vector3)
	local w, cars = buildWorld(entries, rl)
	local a, b
	for i, r in rl do
		if r.pair == 1 then
			if r.lane < 0 then a = cars[i] else b = cars[i] end
		end
	end
	local bestDx, bestTick = math.huge, math.floor((JUMP + 0.65) / TICK)
	for tick = 1, math.floor(5 / TICK) do
		stepWorld(w, cars, rl, tick)
		if tick * TICK > JUMP + 0.25 then
			local dx = math.abs(a.body.pos.X - b.body.pos.X) * BT
			if dx < bestDx then
				bestDx, bestTick = dx, tick
			elseif dx > bestDx + 150 then
				break
			end
		end
	end
	local freezeTick = bestTick + 5 -- just past the crossing: the high car is already in front
	-- where everything is at the freeze tick (sim UU)
	local w2, cars2 = buildWorld(entries, rl)
	for tick = 1, freezeTick do
		stepWorld(w2, cars2, rl, tick)
	end
	local c = Vector3.zero
	for _, car in cars2 do
		c += car.body.pos * BT
	end
	return freezeTick, c / #cars2
end

-- ---------------------------------------------------------------- GUI + viewport split
-- build the overlay once
function Intro.Preload()
	if gui then return end
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local g = Instance.new("ScreenGui")
	g.Name = "Intro"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 25
	g.Enabled = false
	g.Parent = pg
	gui = g

	-- broadcast split overlay (drawn over the real render)
	local split = frame(g, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 2 })
	refs.split = split
	local div = frame(split, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = WHITE, ZIndex = 3 })
	refs.divider = div
	refs.divGlow = frame(split, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 28, 1, 0), BackgroundColor3 = WHITE, BackgroundTransparency = 0.75, ZIndex = 3 })
	local gg = Instance.new("UIGradient")
	gg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
	gg.Parent = refs.divGlow
	refs.sides = {}
	for i, x in { 0, 1 } do
		-- soft team-coloured edge on each half + a name tag at the top
		local edge = frame(split, { AnchorPoint = Vector2.new(x, 0), Position = UDim2.fromScale(x, 0), Size = UDim2.new(0.22, 0, 1, 0), BackgroundColor3 = BLUE, BackgroundTransparency = 0.55, ZIndex = 2 })
		local eg = Instance.new("UIGradient")
		eg.Transparency = NumberSequence.new(if x == 0 then 0 else 1, if x == 0 then 1 else 0)
		eg.Parent = edge
		local tag = frame(split, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(if x == 0 then 0.25 else 0.75, 0, 0.13, 0), Size = UDim2.fromOffset(340, 58), BackgroundColor3 = INK, BackgroundTransparency = 0.15, ZIndex = 4 })
		local bar = frame(tag, { Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = BLUE, ZIndex = 5 })
		local nm = text(tag, { Position = UDim2.fromOffset(0, 5), Size = UDim2.new(1, 0, 1, -5), TextSize = 32, ZIndex = 5 })
		refs.sides[i] = { edge = edge, tag = tag, bar = bar, name = nm }
	end

	-- speed lines
	refs.streaks = {}
	local rng = Random.new(11)
	for i = 1, 22 do
		local ang = (i / 22) * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local f = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(rng:NextInteger(90, 220), 2), BackgroundTransparency = 1, Rotation = math.deg(ang), ZIndex = 4 })
		table.insert(refs.streaks, { f = f, ang = ang, phase = rng:NextNumber(), speed = rng:NextNumber(1.8, 3.2) })
	end

	-- letterbox
	refs.barTop = frame(g, { Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 6 })
	refs.barBot = frame(g, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 6 })

	-- lower third (shots 1-2)
	local lt = frame(g, { Position = UDim2.new(0, 70, 0.78, -40), Size = UDim2.fromOffset(640, 110), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 7 })
	refs.lower = lt
	refs.lowerBar = frame(lt, { Size = UDim2.new(0, 10, 1, 0), BackgroundColor3 = BLUE, ZIndex = 7 })
	refs.lowerName = text(lt, { Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -28, 0, 70), TextSize = 64, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.6, ZIndex = 7 })
	refs.lowerSub = text(lt, { Position = UDim2.fromOffset(30, 70), Size = UDim2.new(1, -30, 0, 30), TextSize = 24, FontFace = OSWALD_REG, TextColor3 = Color3.fromRGB(220, 226, 236), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7 })

	-- names layer (freeze)
	refs.names = frame(g, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 8 })

	-- flash
	refs.flash = frame(g, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 10 })

	-- skip hint
	refs.skip = text(g, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -30, 1, -18), Size = UDim2.fromOffset(300, 26), Text = "SALTAR  ·  ESPACIO", TextSize = 18, FontFace = OSWALD_REG, TextColor3 = Color3.fromRGB(200, 204, 214), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 9 })
	local skipGlyph = Instance.new("ImageLabel")
	skipGlyph.BackgroundTransparency = 1
	skipGlyph.AnchorPoint = Vector2.new(1, 1)
	skipGlyph.Position = UDim2.new(1, -28, 1, -15)
	skipGlyph.Size = UDim2.fromOffset(32, 32)
	skipGlyph.ScaleType = Enum.ScaleType.Fit
	skipGlyph.ImageTransparency = 1
	skipGlyph.ZIndex = 9
	pcall(function() skipGlyph.Image = UIS:GetImageForKeyCode(Enum.KeyCode.ButtonA) end)
	skipGlyph.Parent = g
	refs.skipGlyph = skipGlyph
	local function skipHint(m: string)
		local pad = m == "gamepad" and skipGlyph.Image ~= ""
		refs.skip.Text = if pad then "SALTAR" else "SALTAR  ·  ESPACIO"
		refs.skip.Position = if pad then UDim2.new(1, -68, 1, -18) else UDim2.new(1, -30, 1, -18)
		skipGlyph.Visible = pad
	end
	skipHint(InputGlyphs.Mode())
	InputGlyphs.OnModeChanged(skipHint)

	task.spawn(function()
		local sounds = {}
		for _, id in SFX do
			local s = Instance.new("Sound")
			s.SoundId = "rbxassetid://" .. id
			table.insert(sounds, s)
		end
		pcall(function() ContentProvider:PreloadAsync(sounds) end)
	end)
end

local function lowerThird(name: string, sub: string, color: Color3)
	refs.lowerBar.BackgroundColor3 = color
	refs.lowerName.Text = upper(name)
	refs.lowerSub.Text = sub
	refs.lower.Size = UDim2.fromOffset(0, 110)
	refs.lower.Visible = true
	tween(refs.lower, 0.28, { Size = UDim2.fromOffset(640, 110) }, Enum.EasingStyle.Quart)
	refs.lowerName.Position = UDim2.fromOffset(70, 0)
	tween(refs.lowerName, 0.35, { Position = UDim2.fromOffset(28, 0) }, Enum.EasingStyle.Quart)
end

local function blurPulse(size: number, t: number)
	if not st then return end
	st.blur.Size = size
	tween(st.blur, t, { Size = 0 })
end

local function flash(tr: number, t: number)
	refs.flash.BackgroundTransparency = tr
	tween(refs.flash, t, { BackgroundTransparency = 1 })
end

-- ---------------------------------------------------------------- per-car render state
local function carCF(e: any): CFrame
	local p = e.p0:Lerp(e.p1, st.alpha)
	local q = Q.slerp(e.q0, e.q1, st.alpha)
	return RenderMap.CFrame(p, q)
end

local function groupInfo(list: { any }): (Vector3, Vector3)
	local c = Vector3.zero
	for _, e in list do
		c += e.cf.Position
	end
	c /= #list
	local lv = list[1].cf.LookVector
	local f = Vector3.new(lv.X, 0, lv.Z)
	f = if f.Magnitude > 1e-3 then f.Unit else Vector3.zAxis
	return c, f
end

-- ---------------------------------------------------------------- names at the freeze
-- Name cards are placed ONCE (the camera is locked during the freeze) so the text is perfectly still and sharp.
-- In each crossing pair the higher car gets its card above it, the lower car below it, so they never overlap.
local function nameCard(e: any, delay: number, screen: Vector2, below: boolean, width: number, stemDX: number)
	local color = if e.team == 0 then BLUE else ORANGE
	local big = width >= 300
	local holder = frame(refs.names, {
		AnchorPoint = Vector2.new(0.5, if below then 0 else 1),
		Position = UDim2.fromOffset(math.floor(screen.X + 0.5), math.floor(screen.Y + 0.5)),
		Size = UDim2.fromOffset(width, 92), BackgroundTransparency = 1, ZIndex = 8,
	})
	local cardY = if below then 22 else 0
	local clip = frame(holder, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, cardY), Size = UDim2.fromOffset(0, 70), BackgroundColor3 = INK, BackgroundTransparency = 0.08, ClipsDescendants = true, ZIndex = 8 })
	frame(clip, { Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = color, ZIndex = 9 })
	local nm = text(clip, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 40, 0, 6), Size = UDim2.fromOffset(width, 44), Text = upper(e.name), TextSize = if big then 38 else 30, TextScaled = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 9 })
	text(clip, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 46), Size = UDim2.fromOffset(width, 20), Text = e.tag, TextSize = if big then 16 else 14, FontFace = OSWALD_REG, TextColor3 = color, ZIndex = 9 })
	local stem = frame(holder, { AnchorPoint = Vector2.new(0.5, if below then 0 else 0), Position = UDim2.new(0.5, math.clamp(stemDX, -width / 2 + 6, width / 2 - 6), 0, if below then 0 else 70), Size = UDim2.fromOffset(3, 0), BackgroundColor3 = color, ZIndex = 8 })
	task.delay(delay, function()
		if not st then return end
		sfx(SFX.cut, 0.35, 1.25)
		-- wipe open + name slides into place; no scaling, so the text never resamples
		tween(clip, 0.22, { Size = UDim2.fromOffset(width, 70) }, Enum.EasingStyle.Quart)
		tween(nm, 0.28, { Position = UDim2.new(0.5, 0, 0, 6) }, Enum.EasingStyle.Quart)
		tween(stem, 0.2, { Size = UDim2.fromOffset(3, 22) })
	end)
	e.card = holder
end

local function revealNames()
	local cam = workspace.CurrentCamera
	local pts = {}
	for _, e in st.entries do
		local v = cam:WorldToViewportPoint(e.cf.Position)
		pts[e] = Vector2.new(v.X, v.Y)
	end
	local width = if #st.entries >= 4 then 230 else 300
	local cards = {}
	for i, e in st.entries do
		-- partner = the other car of the same crossing pair
		local partner
		for _, o in st.entries do
			if o ~= e and o.role.pair == e.role.pair then partner = o end
		end
		local p = pts[e]
		local below = partner ~= nil and p.Y > pts[partner].Y
		table.insert(cards, { e = e, i = i, below = below, x = p.X, carX = p.X, y = p.Y + (if below then 34 else -34) })
	end
	-- spread cards that share a row (above / below) so they keep a 14 px gap
	for _, row in { false, true } do
		local r = {}
		for _, c in cards do if c.below == row then table.insert(r, c) end end
		table.sort(r, function(a, b) return a.x < b.x end)
		for _ = 1, 4 do
			for j = 2, #r do
				local gap = (r[j].x - r[j - 1].x) - (width + 14)
				if gap < 0 then
					r[j - 1].x += gap / 2
					r[j].x -= gap / 2
				end
			end
		end
	end
	for _, c in cards do
		nameCard(c.e, 0.12 + (c.i - 1) * 0.1, Vector2.new(c.x, c.y), c.below, width, c.carX - c.x)
	end
end

-- ---------------------------------------------------------------- public
-- opts: { entries = { { team, config, name, tag } } } ; onDone called when the kickoff camera should take over
function Intro.Play(opts: { [string]: any }, onDone: () -> ())
	Intro.Preload()
	local entries = opts.entries
	local rl = roles(#entries)
	local freezeTick, center = plan(entries, rl)
	local w, cars = buildWorld(entries, rl)
	local folder = Instance.new("Folder")
	folder.Name = "IntroCars"
	folder.Parent = workspace
	local list = {}
	for i, e in entries do
		local car = cars[i]
		local p, q = car.body.pos * BT, car.body.rot
		table.insert(list, { car = car, team = e.team, name = e.name, tag = e.tag, role = rl[i], visual = CarVisual.new(car, folder, e.skin), p0 = p, p1 = p, q0 = q, q1 = q, cf = CFrame.identity })
	end
	local blue, orange = {}, {}
	for _, e in list do
		table.insert(if e.team == 0 then blue else orange, e)
	end

	local blur = Instance.new("BlurEffect"); blur.Name = "IntroBlur"; blur.Size = 0; blur.Parent = Lighting
	local dof = Instance.new("DepthOfFieldEffect"); dof.Name = "IntroDOF"; dof.FarIntensity = 0.55; dof.NearIntensity = 0.2; dof.InFocusRadius = 5; dof.FocusDistance = 8; dof.Parent = Lighting
	if not GS.Get("dof") then dof.Parent = nil end -- graphics option: no depth of field
	local grade = Instance.new("ColorCorrectionEffect"); grade.Name = "IntroGrade"; grade.Contrast = 0.12; grade.Saturation = 0.12; grade.Parent = Lighting

	st = {
		world = w, cars = cars, roles = rl, entries = list, blue = blue, orange = orange, folder = folder,
		freezeTick = freezeTick, center = RenderMap.Pos(center), tick = 0, acc = 0, alpha = 0, real = 0,
		phase = "run", shot = 0, frozenAt = nil, outroAt = nil, onDone = onDone,
		blur = blur, dof = dof, grade = grade, streak = 0,
	}
	-- skip
	st.skipConn = UIS.InputBegan:Connect(function(input, processed)
		if processed or not st or st.phase == "outro" then return end
		local k = input.KeyCode
		if k == Enum.KeyCode.Space or k == Enum.KeyCode.Return or k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.ButtonStart then
			st.phase = "outro"
			st.outroAt = st.real
			sfx(SFX.zoom, 0.5, 1.3)
		end
	end)

	local g = gui :: ScreenGui
	g.Enabled = true
	refs.split.Visible = false
	refs.lower.Visible = false
	refs.names:ClearAllChildren()
	refs.skip.TextTransparency = 0
	refs.skipGlyph.ImageTransparency = 0
	refs.barTop.Size = UDim2.new(1, 0, 0, 0)
	refs.barBot.Size = UDim2.new(1, 0, 0, 0)
	tween(refs.barTop, 0.35, { Size = UDim2.new(1, 0, 0.1, 0) }, Enum.EasingStyle.Quart)
	tween(refs.barBot, 0.35, { Size = UDim2.new(1, 0, 0.1, 0) }, Enum.EasingStyle.Quart)
	flash(0, 0.35)
end

function Intro.IsPlaying(): boolean
	return st ~= nil
end

local function finish()
	if not st then return end
	local s = st
	st = nil
	s.skipConn:Disconnect()
	for _, e in s.entries do e.visual:Destroy() end
	s.folder:Destroy()
	s.dof:Destroy()
	s.grade:Destroy()
	-- the blur keeps fading over the kickoff camera
	tween(s.blur, 0.35, { Size = 0 }).Completed:Connect(function() s.blur:Destroy() end)
	refs.split.Visible = false
	refs.names:ClearAllChildren()
	refs.lower.Visible = false
	refs.skip.TextTransparency = 1
	refs.skipGlyph.ImageTransparency = 1
	for _, sk in refs.streaks do sk.f.BackgroundTransparency = 1 end
	tween(refs.barTop, 0.3, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quart)
	tween(refs.barBot, 0.3, { Size = UDim2.new(1, 0, 0, 0) }, Enum.EasingStyle.Quart)
	tween(refs.flash, 0.35, { BackgroundTransparency = 1 })
	task.delay(0.4, function()
		if not st and gui then (gui :: ScreenGui).Enabled = false end
	end)
	s.onDone()
end

-- sim time scale (speed ramps): anticipation dip before the launch, punch after it, slow motion into the freeze
local function timeScale(simT: number): number
	if st.phase ~= "run" then
		return 0
	end
	if simT >= ACCEL - 0.12 and simT < ACCEL then
		return 0.45
	end
	if simT >= ACCEL and simT < ACCEL + 0.25 then
		return 1.35
	end
	local fT = st.freezeTick * TICK
	if simT >= T_CROSS then
		local k = smooth((simT - T_CROSS) / math.max(0.05, fT - T_CROSS))
		return lerp(0.9, 0.16, k)
	end
	return 1
end

local function setCam(pos: Vector3, look: Vector3, fov: number, roll: number?)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local cf = CFrame.lookAt(pos, look)
	if roll then cf *= CFrame.Angles(0, 0, roll) end
	if st.shake and st.shake > 0.01 then
		local t = os.clock() * 30
		cf *= CFrame.new(math.noise(t, 1) * 0.3 * st.shake, math.noise(t, 2) * 0.3 * st.shake, 0) * CFrame.Angles(math.noise(t, 3) * 0.01 * st.shake, math.noise(t, 4) * 0.01 * st.shake, 0)
	end
	cam.CFrame = cf
	cam.FieldOfView = fov
end

function Intro.Update(dt: number)
	if not st then return end
	st.real += dt
	st.shake = math.max(0, (st.shake or 0) - dt * 2.5)

	-- advance the private world at 120 Hz with the speed ramp
	local simT = st.tick * TICK
	if st.phase == "run" then
		st.acc += dt * timeScale(simT)
		while st.acc >= TICK and st.tick < st.freezeTick do
			st.acc -= TICK
			st.tick += 1
			for _, e in st.entries do
				e.p0, e.q0 = e.p1, e.q1
			end
			stepWorld(st.world, st.cars, st.roles, st.tick)
			for _, e in st.entries do
				e.p1, e.q1 = e.car.body.pos * BT, e.car.body.rot
			end
		end
		st.alpha = math.clamp(st.acc / TICK, 0, 1)
		if st.tick >= st.freezeTick then
			st.alpha = 1
			st.phase = "freeze"
			st.frozenAt = st.real
		end
		simT = st.tick * TICK
	end
	for _, e in st.entries do
		e.cf = carCF(e)
		e.visual:Update(e.cf, true)
		if st.phase ~= "run" then
			e.visual.flame.Rate = 0 -- frozen frame: no new flame particles
		end
	end

	local mine, mineF = groupInfo(if #st.entries >= 4 then st.blue else { st.entries[1] })
	local theirs, theirsF = groupInfo(if #st.entries >= 4 then st.orange else { st.entries[2] })
	local all, allF = groupInfo(st.entries)
	local pairScale = if #st.entries >= 4 then 1.8 else 1
	local up = Vector3.yAxis

	-- ---- shot selection
	local shot
	if st.phase == "outro" then shot = 6
	elseif st.phase == "freeze" then shot = 5
	elseif simT < T_SHOT2 then shot = 1
	elseif simT < T_WIDE then shot = 2
	elseif simT < T_SPLIT then shot = 3
	elseif simT < T_CROSS then shot = 4
	else shot = 5 end
	local entered = shot ~= st.shot
	if entered then
		local prev = st.shot
		st.shot = shot
		st.shotStart = st.real
		if shot == 1 then
			local me = st.entries[1]
			lowerThird(me.name, (if #st.entries >= 4 then "EQUIPO AZUL  ·  " else "") .. me.tag, BLUE)
		elseif shot == 2 then
			sfx(SFX.cut, 0.5)
			blurPulse(14, 0.18)
			local opp = if #st.entries >= 4 then st.entries[3] else st.entries[2]
			lowerThird(if #st.entries >= 4 then "EQUIPO NARANJA" else opp.name, if #st.entries >= 4 then (st.entries[3].name .. "  ·  " .. st.entries[4].name) else opp.tag, ORANGE)
			-- fixed low camera well ahead of them: they rush past it
			st.fixedCam = theirs + theirsF * (38 * pairScale) - theirsF:Cross(up) * (3 * pairScale) + up * 0.7
			st.passed = false
		elseif shot == 3 then
			sfx(SFX.cut, 0.5, 0.9)
			blurPulse(16, 0.2)
			refs.lower.Visible = false
			st.dof.Enabled = false
			-- low tracking rig behind everyone, moving at the cars' current speed (they'll pull away)
			st.rigPos = all - allF * (34 * (if #st.entries >= 4 then 1.3 else 1)) + up * 0.8
			st.rigVel = allF * (st.entries[1].car.body.vel.Magnitude * BT * S)
			st.launched = false
		elseif shot == 4 then
			sfx(SFX.zoom, 0.55, 1.15)
			flash(0.5, 0.2)
			refs.split.Visible = true
			-- which team ends up on which half of this camera (the render map mirrors x)
			local cam = workspace.CurrentCamera
			local mineLeft = cam.CFrame:PointToObjectSpace(mine).X < cam.CFrame:PointToObjectSpace(theirs).X
			local mineName = if #st.entries >= 4 then "EQUIPO AZUL" else st.entries[1].name
			local theirName = if #st.entries >= 4 then "EQUIPO NARANJA" else st.entries[2].name
			for i, side in refs.sides do
				local isMine = (i == 1) == mineLeft
				local col = if isMine then BLUE else ORANGE
				side.edge.BackgroundColor3 = col
				side.bar.BackgroundColor3 = col
				side.name.Text = upper(if isMine then mineName else theirName)
				side.tag.Size = UDim2.fromOffset(0, 58)
				tween(side.tag, 0.25, { Size = UDim2.fromOffset(340, 58) }, Enum.EasingStyle.Quart)
				side.edge.BackgroundTransparency = 1
				tween(side.edge, 0.3, { BackgroundTransparency = 0.6 })
			end
			refs.divider.Size = UDim2.new(0, 4, 0, 0)
			tween(refs.divider, 0.25, { Size = UDim2.new(0, 4, 1, 0) }, Enum.EasingStyle.Quart)
			refs.divider.BackgroundTransparency = 0
			refs.divGlow.BackgroundTransparency = 0.75
			st.jumped = false
		elseif shot == 5 and prev == 4 then
			sfx(SFX.by, 0.55)
			flash(0.35, 0.18)
			blurPulse(10, 0.2)
			refs.split.Visible = false
			-- crossing camera: side 3/4, low, on the side the high flyer is heading to (it ends up in front)
			local side = RenderMap.Dir(Vector3.new(1, 0, 0)).Unit
			local fwd = RenderMap.Dir(Vector3.new(0, 1, 0)).Unit
			local D = 46 * (if #st.entries >= 4 then 1.35 else 1)
			st.crossA = st.center + side * D - fwd * (D * 0.45) + up * 0.6
			st.crossB = st.center + side * (D * 0.82) + fwd * (D * 0.2) + up * 2.2
		elseif shot == 6 then
			st.outroFrom = workspace.CurrentCamera.CFrame
		end
	end
	local u = st.real - (st.shotStart or 0)

	-- ---- cameras
	if shot == 1 then
		local e = st.entries[1]
		local k = smooth(simT / T_SHOT2)
		local cf = CFrame.lookAt(mine, mine + mineF)
		local off = Vector3.new(lerp(3.6, 3.1, k), lerp(0.45, 1.15, k), lerp(-4.4, 4.2, k)) * pairScale
		local pos = (cf * CFrame.new(off)).Position
		local look = mine + mineF * lerp(1.2, 0.2, k) * pairScale + up * 0.4
		setCam(pos, look, lerp(36, 30, k), math.rad(lerp(-4, 3, k)))
		st.dof.Enabled = true
		st.dof.FocusDistance = (pos - e.cf.Position).Magnitude
	elseif shot == 2 then
		local pos = st.fixedCam
		local toCam = (pos - theirs)
		if not st.passed and toCam:Dot(theirsF) < 6 then
			st.passed = true
			sfx(SFX.by, 0.7)
			blurPulse(8, 0.25)
			st.shake = 0.8
		end
		local k = smooth((simT - T_SHOT2) / (T_WIDE - T_SHOT2))
		setCam(pos, theirs + up * 0.6, lerp(40, 62, k), math.rad(lerp(3, -5, k)))
		st.dof.Enabled = true
		st.dof.FocusDistance = toCam.Magnitude
	elseif shot == 3 then
		st.rigPos += st.rigVel * dt
		if not st.launched and simT >= ACCEL then
			st.launched = true
			sfx(SFX.impact, 0.9)
			sfx(SFX.by, 0.6, 0.85)
			st.shake = 1.4
			blurPulse(6, 0.4)
		end
		-- broadcast wide lens, not fisheye: the speed comes from the cars leaving the dolly behind, not from FOV
		local fov = if st.launched then lerp(70, 80, smooth((simT - ACCEL) / 0.3)) else 70
		setCam(st.rigPos, st.rigPos + allF * 30 + up * 0.9, fov)
		st.streak = if st.launched then 1 else 0
	elseif shot == 4 then
		-- one full-quality camera low behind the pair: each team fills its half of the frame
		if not st.jumped and simT >= JUMP then
			st.jumped = true
			sfx(SFX.cut, 0.45, 0.8)
			st.shake = 0.6
		end
		local k = smooth((simT - T_SPLIT) / (T_CROSS - T_SPLIT))
		local back = 15 * pairScale
		local pos = all - allF * back + up * lerp(1.6, 2.6, k)
		local look = all + allF * 12 + up * lerp(0.6, 2.2, k)
		setCam(pos, look, lerp(60, 66, k))
		-- the divider fades as the cars converge toward the middle
		local fade = smooth((simT - (T_CROSS - 0.25)) / 0.25)
		refs.divider.BackgroundTransparency = fade
		refs.divGlow.BackgroundTransparency = 0.75 + 0.25 * fade
		for _, side in refs.sides do
			side.edge.BackgroundTransparency = 0.6 + 0.4 * fade
		end
		st.streak = 1
	elseif shot == 5 then
		st.streak = 0
		st.dof.Enabled = false
		local fT = st.freezeTick * TICK
		local k
		if st.phase == "freeze" then
			k = 1
		else
			k = smooth((simT - T_CROSS) / math.max(0.05, fT - T_CROSS))
		end
		local pos = (st.crossA or all):Lerp(st.crossB or all, k)
		local fov = lerp(58, 48, k)
		if st.phase == "freeze" then
			local h = st.real - st.frozenAt
			pos = st.crossB or pos
			fov = 48
			if not st.freezeHit then
				-- the freeze hit: sound + flash + grade punch; the camera is locked from here so the names stay still
				st.freezeHit = true
				st.shake = 0
				sfx(SFX.freeze, 1)
				sfx(SFX.impact, 0.6, 1.2)
				flash(0.55, 0.3)
				st.grade.Saturation = -0.15
				st.grade.Contrast = 0.35
				tween(st.grade, 0.8, { Saturation = 0.1, Contrast = 0.2 })
				setCam(pos, all + up * 0.3, fov)
				revealNames()
			end
			-- (dev: set attribute DevHold on PlayerGui.Intro to hold the freeze for inspection)
			if h >= FREEZE_HOLD and not (gui and (gui :: ScreenGui):GetAttribute("DevHold")) then
				st.phase = "outro"
				st.outroAt = st.real
				sfx(SFX.zoom, 0.6, 1.2)
			end
		end
		setCam(pos, all + up * 0.3, fov)
	elseif shot == 6 then
		-- whip: yank the camera sideways/up with a blur ramp and flash, then hand over to the kickoff camera
		local k = math.clamp((st.real - st.outroAt) / OUTRO, 0, 1)
		local from = st.outroFrom or workspace.CurrentCamera.CFrame
		local e = k * k * k
		workspace.CurrentCamera.CFrame = from * CFrame.Angles(math.rad(25 * e), math.rad(-80 * e), 0) + up * (6 * e)
		workspace.CurrentCamera.FieldOfView = lerp(48, 78, e)
		st.blur.Size = 28 * e
		refs.flash.BackgroundTransparency = 1 - 0.9 * math.clamp((k - 0.6) / 0.4, 0, 1)
		for _, c in refs.names:GetChildren() do
			if c:IsA("GuiObject") then c.Visible = k < 0.35 end
		end
		if k >= 1 then
			finish()
			return
		end
	end

	-- speed lines
	st.streakShown = lerp(st.streakShown or 0, st.streak, 1 - math.exp(-8 * dt))
	local vp = workspace.CurrentCamera.ViewportSize
	local c = vp / 2
	local diag = vp.Magnitude / 2
	for _, sk in refs.streaks do
		sk.phase = (sk.phase + dt * sk.speed) % 1
		local r = diag * (0.5 + 0.5 * sk.phase)
		sk.f.Position = UDim2.fromOffset(c.X + math.cos(sk.ang) * r, c.Y + math.sin(sk.ang) * r)
		sk.f.BackgroundTransparency = 1 - st.streakShown * 0.6 * math.sin(sk.phase * math.pi)
	end
end

return Intro
