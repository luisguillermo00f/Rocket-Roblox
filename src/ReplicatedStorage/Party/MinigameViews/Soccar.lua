--!strict
-- MinigameViews/Soccar.lua: the online match on the client, dressed exactly like the offline one: the pre-match
-- intro, Game.Hud (scoreboard, clock, boost, stat toasts, goal celebration, pinches), boost pads, the CAPS LOCK
-- scoreboard, goal explosions, demolitions, and the result screen with points and XP. Everything it shows comes
-- from the server (MgEvent "hud" events for this player, "goal", "clock", "board", "pad", "demo", "kickoff").
-- M opens a menu to leave the match (a bot takes your car, like in RL).
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local CarConfig = require(Phys.CarConfig)
local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local GameHud = require(Game.Hud)
local Scoreboard = require(Game.Scoreboard)
local Effects = require(Game.Effects)
local Camera = require(Game.CameraController)
local Input = require(Game.InputController)
local BoostPadVisuals = require(Game.BoostPadVisuals)
local Intro = require(Game.Intro)
local Progression = require(Game.Progression)
local Net = require(script.Parent.Parent.Net)

local View = {}
local activeView: any = nil
Input.On("pause", function()
	if activeView then activeView:LeaveMenu() end
end)
View.__index = View
View.CustomHud = true -- Game.Hud, not the minigame HUD
View.DeferReady = true -- tell the server we're ready when the intro ends

local BLUE, ORANGE = GameHud.BLUE, GameHud.ORANGE

function View.new(round: any)
	local self = setmetatable({}, View)
	self.round = round
	local pub = round.public or {}
	self.mode = pub.mode or "1v1"
	self.ranked = pub.ranked == true
	self.scoreA, self.scoreB = pub.scoreA or 0, pub.scoreB or 0
	self.clock = { timeLeft = pub.timeLeft or 300, overtime = pub.overtime == true, otTime = 0, running = false, at = Net.Now() }
	self.board = {}
	self.kickoffEnd = nil
	self.lastScorer = -1
	self.goalAt = nil
	self.goMsgUntil = 0
	self.otMsgUntil = 0

	-- boost pads in the World's order (big ones first, then small), shown from the snapshot's pad bits
	self.pads = {}
	for i, p in C.BOOSTPAD_LOCS_BIG do
		table.insert(self.pads, { pos = p, isBig = true, isActive = true, index = i })
	end
	for i, p in C.BOOSTPAD_LOCS_SMALL do
		table.insert(self.pads, { pos = p, isBig = false, isActive = true, index = #C.BOOSTPAD_LOCS_BIG + i })
	end
	self.padVisuals = BoostPadVisuals.new(self.pads, round.folder)

	GameHud.ResetStats()
	GameHud.SetVisible(false)

	-- the pre-match introduction with everyone's real cars; the server waits for it (DeferReady)
	local me = round.me
	local entries = {}
	for _, p in round.participants do
		local tag
		if p == me then
			tag = "TÚ  ·  " .. string.upper(p.hitbox or "OCTANE")
		elseif p.isBot then
			tag = (if me and p.team == me.team then "COMPAÑERO" else "RIVAL") .. "  ·  BOT"
		else
			tag = if me and p.team == me.team then "COMPAÑERO" else "RIVAL"
		end
		table.insert(entries, { team = p.team, skin = p.cosmetics or p.skin, config = CarConfig[p.hitbox] or CarConfig.Octane, name = p.name, tag = tag })
	end
	self.introPlaying = true
	local ok = pcall(function()
		Intro.Play({ entries = entries }, function()
			self:IntroDone()
		end)
	end)
	if not ok then self:IntroDone() end

	-- M / tap Select (InputController "pause"), or Start if Roblox lets it through: leave-the-match menu
	activeView = self
	self.keyConn = UIS.InputBegan:Connect(function(inp, processed)
		if processed then return end
		if inp.KeyCode == Enum.KeyCode.ButtonStart then
			self:LeaveMenu()
		end
	end)
	return self
end

function View.IntroDone(self: any)
	if not self.introPlaying then return end
	self.introPlaying = false
	GameHud.SetVisible(true)
	self.round:Ready()
end

-- while the intro plays, it owns the camera and our round's cars / ball stay hidden
function View.CameraOverride(self: any): boolean
	return self.introPlaying
end

function View.ControlsLocked(self: any): boolean
	return self.kickoffEnd ~= nil and Net.Now() < self.kickoffEnd
end

function View.LeaveMenu(self: any)
	local MainMenu = require(Game.MainMenu)
	if MainMenu.ModalOpen() then return end
	MainMenu.Modal("PARTIDA EN LÍNEA", "SI TE VAS, UN BOT OCUPA TU COCHE", nil, {
		{ "CONTINUAR", "ENTER", function() MainMenu.CloseModal() end },
		{ "ABANDONAR PARTIDA", "M", function()
			MainMenu.CloseModal()
			local OnlinePlay = require(script.Parent.Parent.OnlinePlay)
			OnlinePlay.Forfeit()
		end },
	}, { back = "ENTER" })
end

-- ---------------------------------------------------------------- server events
function View.OnEvent(self: any, kind: string, data: any)
	local r = self.round
	local myTeam = if r.me then r.me.team else 0
	if kind == "hud" then
		for _, ev in data.events or {} do
			if ev.kind == "hit" and ev.pos then
				ev.worldStuds = RenderMap.Pos(ev.pos)
			elseif ev.kind == "pinch" then
				Camera.Shake(1.2 + math.clamp(((ev.kmh or 90) - 90) / 60, 0, 1.2))
				r.ball:Flare(1.6)
			end
			GameHud.Event(ev, { team = myTeam })
		end
	elseif kind == "kickoff" then
		self.kickoffEnd = data.endTime
		self.goalAt = nil
	elseif kind == "clock" then
		self.clock = { timeLeft = data.timeLeft, overtime = data.overtime, otTime = data.otTime or 0, running = data.running, at = data.at }
		if data.running and self.kickoffEnd then
			self.kickoffEnd = nil
			self.goMsgUntil = os.clock() + 0.6
		end
	elseif kind == "goal" then
		self.scoreA, self.scoreB = data.scoreA, data.scoreB
		self.lastScorer = data.team
		self.goalAt = os.clock()
		local color = if data.team == 0 then BLUE else ORANGE
		-- the scorer's goal explosion (cosmetic; the server says who scored)
		local scorer = data.scorer and r.visuals[data.scorer]
		local goalId = scorer and scorer.p and scorer.p.cosmetics and scorer.p.cosmetics.goal
		if data.pos then Effects.Goal(RenderMap.Pos(data.pos), color, true, goalId) end
		Camera.Shake(3.2)
		if not r.me then
			-- spectators get no personal HUD events: show the goal banner from the broadcast
			GameHud.Event({ kind = "goal", team = data.team, kmh = data.kmh, who = "team" }, { team = data.team })
		end
	elseif kind == "overtime" then
		self.otMsgUntil = os.clock() + 1.2
	elseif kind == "board" then
		self.board = data.rows or {}
		self.scoreA, self.scoreB = data.scoreA or self.scoreA, data.scoreB or self.scoreB
	elseif kind == "pad" then
		local pad = self.pads[data.index]
		if pad then
			local id = data.id
			Effects.BoostPickup(self.padVisuals:PadPos(pad), pad.isBig, function()
				return r:CarWorldPos(id) or self.padVisuals:PadPos(pad)
			end)
		end
	elseif kind == "demo" then
		local v = data.victim and r.byId[data.victim]
		if data.pos then Effects.Demolish(RenderMap.Pos(data.pos), if v and v.team == 1 then ORANGE else BLUE) end
	elseif kind == "left" and data.replacedByBot then
		local p = r.byId[data.id]
		if p then
			p.name = data.name
			p.isBot = true
		end
	elseif kind == "results" then
		self:Results(data)
	end
end

function View.Results(self: any, data: any)
	local r = self.round
	local MainMenu = require(Game.MainMenu)
	local s = data.summary or {}
	local myTeam = if r.me then r.me.team else 0
	local win = s.winnerTeam
	local result = if win == nil then "draw" elseif win == myTeam then "win" else "loss"
	local title = if result == "win" then "VICTORIA" elseif result == "loss" then "DERROTA" else "EMPATE"
	local color = if result == "win" then (if myTeam == 0 then BLUE else ORANGE) elseif result == "loss" then (if myTeam == 0 then ORANGE else BLUE) else nil
	local points = 0
	if r.me and self.board[r.me.id] then points = self.board[r.me.id].points or 0 end
	for _, row in data.rows or {} do
		if r.me and row.id == r.me.id and row.stats and row.stats.points then points = row.stats.points end
	end
	local xp = Progression.MatchXp(points, result)
	MainMenu.Modal(title, string.format("AZUL %d  —  %d NARANJA   ·   %d PTS   ·   +%d XP", s.scoreA or self.scoreA, s.scoreB or self.scoreB, points, xp), color, {
		{ "CONTINUAR", "ENTER", function() MainMenu.CloseModal() end },
	}, { back = "ENTER" })
end

-- ---------------------------------------------------------------- per frame
local function clockText(sec: number): string
	local t = math.max(0, math.ceil(sec))
	return string.format("%d:%02d", t // 60, t % 60)
end

function View.Update(self: any, dt: number)
	local r = self.round
	if self.introPlaying then
		Intro.Update(dt)
		return
	end

	-- pads from the newest snapshot
	local latest = r.snaps[#r.snaps]
	if latest and latest.pads then
		for i, on in latest.pads do
			if self.pads[i] then self.pads[i].isActive = on end
		end
	end
	self.padVisuals:Update(os.clock())

	-- clock (anchored on the server's last report)
	local ck = self.clock
	local since = if ck.running then math.max(0, Net.Now() - ck.at) else 0
	local timeLeft = if ck.overtime then 0 else math.max(0, ck.timeLeft - since)
	local timerText = nil
	if ck.overtime then
		local t = math.floor(ck.otTime + since)
		timerText = string.format("+%d:%02d", t // 60, t % 60)
	end
	local timerNote = if not ck.overtime and timeLeft <= 0 and ck.running then "¡BALÓN EN JUEGO!" else nil

	-- centre message
	local msg, msgColor = "", nil
	if self.kickoffEnd and Net.Now() < self.kickoffEnd then
		msg = tostring(math.max(1, math.ceil(self.kickoffEnd - Net.Now())))
	elseif os.clock() < self.otMsgUntil then
		msg = "¡PRÓRROGA!"
	elseif os.clock() < self.goMsgUntil then
		msg = if ck.overtime then "¡PRÓRROGA!" else "¡YA!"
	elseif self.goalAt and os.clock() - self.goalAt < 3 then
		msg = "¡GOL!"
		msgColor = if self.lastScorer == 0 then BLUE else ORANGE
	end

	local car = r.myCar
	local me = r.me and r.visuals[r.me.id]
	local tags = { string.upper(if r.me then (r.me.hitbox or "Octane") else "ESPECTADOR"), "EN LÍNEA" }
	if self.ranked then table.insert(tags, "RANKED") end
	if Input.Toggle("ballCam") and r.ballPos then table.insert(tags, "CÁMARA BALÓN") end
	if car and car.isSupersonic then table.insert(tags, "SUPERSÓNICO") end

	-- scoreboard while CAPS LOCK / Select is held
	local showBoard = Input.ScoreboardHeld()
	Scoreboard.SetVisible(showBoard)
	if showBoard then
		local entries = {}
		for _, p in r.participants do
			table.insert(entries, {
				key = p.id, name = p.name, team = p.team, isLocal = p == r.me, bot = p.isBot == true,
				userId = if p.isBot then nil else p.userId, stats = self.board[p.id] or { points = 0, goals = 0, assists = 0, saves = 0, shots = 0 },
			})
		end
		Scoreboard.Update(entries, self.scoreA, self.scoreB, timerText or clockText(timeLeft))
	end

	GameHud.Update({
		blue = self.scoreA, orange = self.scoreB, timeLeft = timeLeft, timerText = timerText,
		boost = if car then car.boost else 0, unlimitedBoost = false,
		carWorld = if me and me.pos and not me.hidden then RenderMap.Pos(me.pos) else nil,
		ballWorld = if r.ballPos then RenderMap.Pos(r.ballPos) else nil,
		ballCam = Input.Toggle("ballCam") and r.ballPos ~= nil, supersonic = car ~= nil and car.isSupersonic, timerNote = timerNote,
		tags = tags, message = msg, messageColor = msgColor, help = Input.Toggle("help"), debugText = nil,
	})
end

function View.TeamNames(self: any): { any }
	return {}
end

function View.Destroy(self: any)
	if activeView == self then activeView = nil end
	if self.keyConn then self.keyConn:Disconnect() end
	GameHud.SetVisible(false)
	Scoreboard.SetVisible(false)
end

return View
