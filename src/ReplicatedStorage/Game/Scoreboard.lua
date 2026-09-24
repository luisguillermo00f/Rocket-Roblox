--!strict
-- Scoreboard.lua: in-match scoreboard (hold CAPS LOCK). Both teams, each player with Roblox avatar (bots get a team
-- badge with their initial), name and PUNTOS / GOLES / ASIST. / ATAJADAS / TIROS, sorted by points. Pure UI.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Scoreboard = {}

local BLUE = Color3.fromRGB(38, 140, 255)
local ORANGE = Color3.fromRGB(255, 132, 36)
local INK = Color3.fromRGB(14, 14, 18)
local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 196, 64)
local OSWALD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local OSWALD_REG = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular)
local COLS = { { "points", "PUNTOS" }, { "goals", "GOLES" }, { "assists", "ASIST." }, { "saves", "ATAJADAS" }, { "shots", "TIROS" } }
local ACCENTS = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ" }

local gui: ScreenGui? = nil
local panel: Frame? = nil
local scale: UIScale? = nil
local rowsByKey: { [any]: any } = {}
local layoutSig = ""
local visible = false
local headshots: { [number]: string } = {}

local function upper(str: string): string
	local out = string.upper(str)
	for lo, hi in ACCENTS do out = out:gsub(lo, hi) end
	return out
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
local function round(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(r, 0)
	c.Parent = inst
end

function Scoreboard.Init()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("Scoreboard")
	if old then old:Destroy() end
	local g = Instance.new("ScreenGui")
	g.Name = "Scoreboard"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 15
	g.Enabled = false
	g.Parent = pg
	gui = g
	local sc = Instance.new("UIScale")
	sc.Parent = g
	scale = sc
	panel = frame(g, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1240, 600), BackgroundColor3 = INK, BackgroundTransparency = 0.12 })
end

local ROW_H = 72
local NAME_W = 520
local COL_W = 130

-- entries: { { key, name, team, userId?, isLocal, bot, stats = { points, goals, assists, saves, shots } } }
local function build(entries: { any }, blue: number, orange: number, timeText: string)
	local p = panel :: Frame
	p:ClearAllChildren()
	rowsByKey = {}
	local teams = { [0] = {}, [1] = {} }
	for _, e in entries do table.insert(teams[e.team], e) end
	local y = 0
	-- header: score line
	local head = frame(p, { Size = UDim2.new(1, 0, 0, 86), BackgroundTransparency = 1 })
	text(head, { Position = UDim2.fromOffset(32, 0), Size = UDim2.fromOffset(400, 86), Text = "MARCADOR", TextSize = 44, TextXAlignment = Enum.TextXAlignment.Left })
	local score = text(head, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 90, 0, 0), Size = UDim2.fromOffset(300, 86), Text = "", TextSize = 52 })
	local timeL = text(head, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -32, 0, 0), Size = UDim2.fromOffset(240, 86), Text = "", TextSize = 34, TextColor3 = WHITE, TextTransparency = 0.25, TextXAlignment = Enum.TextXAlignment.Right })
	rowsByKey.__score = score
	rowsByKey.__time = timeL
	y = 86
	-- column captions
	for i, c in COLS do
		text(p, { Position = UDim2.fromOffset(NAME_W + (i - 1) * COL_W, y), Size = UDim2.fromOffset(COL_W, 30), Text = c[2], TextSize = 20, TextColor3 = WHITE, TextTransparency = 0.45, FontFace = OSWALD_REG })
	end
	y += 34
	for team = 0, 1 do
		local color = if team == 0 then BLUE else ORANGE
		frame(p, { Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = color })
		y += 8
		for _, e in teams[team] do
			local row = frame(p, { Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, ROW_H), BackgroundColor3 = color, BackgroundTransparency = if e.isLocal then 0.72 else 0.9 })
			-- avatar
			local av = frame(row, { Position = UDim2.fromOffset(26, 8), Size = UDim2.fromOffset(56, 56), BackgroundColor3 = color, BackgroundTransparency = 0.2 })
			round(av, 0.5)
			if e.userId and e.userId > 0 then
				local img = Instance.new("ImageLabel")
				img.BackgroundTransparency = 1
				img.Size = UDim2.fromScale(1, 1)
				img.Image = headshots[e.userId] or ""
				img.Parent = av
				round(img, 0.5)
				if not headshots[e.userId] then
					task.spawn(function()
						local ok, content = pcall(function()
							return Players:GetUserThumbnailAsync(e.userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
						end)
						if ok then
							headshots[e.userId] = content
							if img.Parent then img.Image = content end
						end
					end)
				end
			else
				text(av, { Size = UDim2.fromScale(1, 1), Text = upper(string.sub(e.name, 1, 1)), TextSize = 32 })
			end
			text(row, { Position = UDim2.fromOffset(98, 0), Size = UDim2.fromOffset(NAME_W - 110, ROW_H), Text = upper(e.name), TextSize = 34, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
			if e.bot then
				text(row, { Position = UDim2.fromOffset(98, 48), Size = UDim2.fromOffset(200, 18), Text = "BOT", TextSize = 15, TextColor3 = WHITE, TextTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Left, FontFace = OSWALD_REG })
			elseif e.isLocal then
				text(row, { Position = UDim2.fromOffset(98, 48), Size = UDim2.fromOffset(200, 18), Text = "TÚ", TextSize = 15, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Left })
			end
			local cells = {}
			for i, c in COLS do
				cells[c[1]] = text(row, { Position = UDim2.fromOffset(NAME_W + (i - 1) * COL_W, 0), Size = UDim2.fromOffset(COL_W, ROW_H), Text = "0", TextSize = if i == 1 then 38 else 34, TextColor3 = if i == 1 then GOLD else WHITE })
			end
			rowsByKey[e.key] = { cells = cells, last = {} }
			y += ROW_H + 4
		end
		y += 14
	end
	p.Size = UDim2.fromOffset(NAME_W + #COLS * COL_W + 30, y + 8)
end

function Scoreboard.Update(entries: { any }, blue: number, orange: number, timeText: string)
	if not gui or not visible then return end
	local sig = ""
	for _, e in entries do sig ..= tostring(e.key) .. e.team .. "|" end
	if sig ~= layoutSig then
		layoutSig = sig
		build(entries, blue, orange, timeText)
	end
	-- sort order: within a team by points (rebuild rows' Y)
	local sorted = { [0] = {}, [1] = {} }
	for _, e in entries do table.insert(sorted[e.team], e) end
	for t = 0, 1 do
		table.sort(sorted[t], function(a, b) return a.stats.points > b.stats.points end)
	end
	local y0 = 86 + 34
	local y = y0
	for t = 0, 1 do
		y += 8
		for _, e in sorted[t] do
			local r = rowsByKey[e.key]
			if r then
				local rowFrame = r.cells.points.Parent :: Frame
				rowFrame.Position = UDim2.fromOffset(0, y)
				for k, cell in r.cells do
					local v = e.stats[k] or 0
					if r.last[k] ~= v then
						if r.last[k] ~= nil then
							-- a stat went up: pop it
							local s = Instance.new("UIScale")
							s.Scale = 1.5
							s.Parent = cell
							TweenService:Create(s, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Scale = 1 }):Play()
							task.delay(0.4, function() s:Destroy() end)
						end
						r.last[k] = v
						cell.Text = tostring(v)
					end
				end
			end
			y += ROW_H + 4
		end
		y += 14
	end
	local score = rowsByKey.__score
	if score then
		score.RichText = true
		score.Text = string.format('<font color="#268CFF">%d</font>  <font transparency="0.5">—</font>  <font color="#FF8424">%d</font>', blue, orange)
		rowsByKey.__time.Text = timeText
	end
	if scale then
		scale.Scale = math.clamp(workspace.CurrentCamera.ViewportSize.Y / 1080, 0.55, 1.2)
	end
end

function Scoreboard.SetVisible(on: boolean)
	if not gui or visible == on then return end
	visible = on
	local g = gui :: ScreenGui
	local p = panel :: Frame
	if on then
		layoutSig = "" -- rebuild on first update (new match / new cars)
		g.Enabled = true
		p.Position = UDim2.new(0.5, 0, 0.5, 24)
		p.BackgroundTransparency = 0.5
		TweenService:Create(p, TweenInfo.new(0.18, Enum.EasingStyle.Quart), { Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 0.12 }):Play()
	else
		g.Enabled = false
	end
end

function Scoreboard.IsVisible(): boolean
	return visible
end

return Scoreboard
