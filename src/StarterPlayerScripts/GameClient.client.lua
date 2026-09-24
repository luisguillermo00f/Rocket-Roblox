--!strict
-- GameClient.client.lua
-- Main menu -> match (training / 1v1 / 2v2 with bots) -> results.
-- The simulation (RocketSim port) runs client-side at a fixed 120 Hz; bots read the same world through the
-- ball prediction and drive with ordinary controls, exactly like the player. Rendering never feeds back into physics.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Phys = RS:WaitForChild("Physics")
local Game = RS:WaitForChild("Game")
local C = require(Phys:WaitForChild("PhysicsConstants"))
local World = require(Phys:WaitForChild("World"))
local CarPhysics = require(Phys:WaitForChild("CarPhysics"))
local BallPhysics = require(Phys:WaitForChild("BallPhysics"))
local CarConfig = require(Phys:WaitForChild("CarConfig"))
local BallPrediction = require(Phys:WaitForChild("BallPrediction"))
local FixedStep = require(Phys:WaitForChild("FixedStep"))
local Q = require(Phys:WaitForChild("Quaternion"))

local RenderMap = require(Game:WaitForChild("RenderMap"))
local Input = require(Game:WaitForChild("InputController"))
local Camera = require(Game:WaitForChild("CameraController"))
local Hud = require(Game:WaitForChild("Hud"))
local CarVisual = require(Game:WaitForChild("CarVisual"))
local BallVisual = require(Game:WaitForChild("BallVisual"))
local BoostPadVisuals = require(Game:WaitForChild("BoostPadVisuals"))
local DebugDraw = require(Game:WaitForChild("DebugDraw"))
local Effects = require(Game:WaitForChild("Effects"))
local BotAI = require(Game:WaitForChild("BotAI"))
local MainMenu = require(Game:WaitForChild("MainMenu"))
local MatchEvents = require(Game:WaitForChild("MatchEvents"))
local Scoreboard = require(Game:WaitForChild("Scoreboard"))
local UIS = game:GetService("UserInputService")
local matchNames: { [any]: string } = {} -- car -> display name (player + bots) for the scoreboard and the goal banner
-- scoreboard: shown while CAPS LOCK / Select is physically held (polled each frame; its release event isn't reliable)
local Progression = require(Game:WaitForChild("Progression"))
local Intro = require(Game:WaitForChild("Intro"))
local MenuCinematic = require(Game:WaitForChild("MenuCinematic"))
local GraphicsSettings = require(Game:WaitForChild("GraphicsSettings"))
local InputGlyphs = require(Game:WaitForChild("InputGlyphs"))
local Sounds = require(Game:WaitForChild("Sounds"))
Sounds.Init()
InputGlyphs.Start() -- device tracking, controller glyphs, menu selection frame
local BOT_NAMES = { "Vórtice", "Nitro", "Cometa", "Titán", "Raptor", "Ónix", "Pulso", "Cénit", "Órbita", "Rayo", "Halcón", "Tormenta" }

local BT = C.BT_TO_UU
local MATCH_LENGTH = 300
local COUNTDOWN = 3
local GOAL_PAUSE = 3

local HITBOXES = { "Octane", "Dominus", "Plank", "Breakout", "Hybrid", "Merc" }

local renderFolder = Instance.new("Folder")
renderFolder.Name = "Render"
renderFolder.Parent = workspace

Hud.Init()
DebugDraw.Init()
Scoreboard.Init()
task.defer(Intro.Preload)
GraphicsSettings.Apply() -- builds the split-screen arena copies once, off the critical path

-- ===== session state =====
local state = "menu" -- "menu" | "match"
local cfg = { mode = "1v1", bot = false, difficulty = "pro", hitbox = "Octane", skin = "Octane" }
local world: any = nil
local player: any = nil
local bots: { any } = {}
local visuals: { [any]: any } = {}
local snaps: { [any]: any } = {}
local ballVisual: any = nil
local padVisuals: any = nil
local prediction: any = nil
local fixed = FixedStep.new()
local simTime = 0

local phase = "countdown"
local phaseTime = 0
local timeLeft = MATCH_LENGTH
local overtime = false
local overtimeTime = 0
local score = { [0] = 0, [1] = 0 }
local lastScorer = -1
local paused = false
local unlimitedBoost = false
local lastTickMs = 0
local menuCar: any = nil
local matchEvents: any = nil
local hudEvents: { any } = {}
-- slow motion: { t, low, hold, ease, goal } - `low` time scale for `hold` s, then eases back to 1 over `ease` s
local slowmo: { [string]: any }? = nil
local ballGroundedLatch = false -- set by any sim tick where the ball touches the floor (RL: the match ends at 0:00 only then)

-- profile (server: ServerScriptService.ProfileService)
local function remotes(): Instance?
	return RS:FindFirstChild("Remotes") or RS:WaitForChild("Remotes", 8)
end
local settingsLoaded = false
local function refreshProfile(delay: number)
	task.spawn(function()
		task.wait(delay)
		local rem = remotes()
		local rf = rem and rem:WaitForChild("GetProfile", 5) :: RemoteFunction?
		if not rf then return end
		local ok, data = pcall(function() return rf:InvokeServer() end)
		if ok and type(data) == "table" and not settingsLoaded then
			settingsLoaded = true
			GraphicsSettings.Load(data.settings, Camera.Settings)
		end
		if ok and type(data) == "table" and state == "menu" then
			MainMenu.SetProfile(data)
		end
	end)
end

local function clearScene()
	for _, v in visuals do v:Destroy() end
	visuals = {}
	snaps = {}
	if ballVisual then ballVisual.model:Destroy(); ballVisual = nil end
	renderFolder:ClearAllChildren()
	padVisuals = nil
	menuCar = nil
end

local function snapCar(car: any)
	return { p = car.body.pos * BT, q = car.body.rot }
end
local function snapAll()
	for _, car in world.cars do
		local s = snapCar(car)
		snaps[car] = { prev = s, cur = s }
	end
	local b = world.ball.body
	local bs = { p = b.pos * BT, q = b.rot }
	snaps.ball = { prev = bs, cur = bs }
end

local function kickoff()
	world.ballEnabled = true
	world:ResetToKickoff()
	for _, b in bots do
		b.plan = nil
		b.aerial = nil
		b.actions = {}
	end
	phase = if cfg.mode == "training" and not cfg.bot then "play" else "countdown"
	phaseTime = 0
	if matchEvents then matchEvents:Reset() end
	table.clear(hudEvents)
	snapAll()
	Camera.Reset(RenderMap.CFrame(player.body.pos * BT, player.body.rot))
end

local function openMenu()
	MainMenu.CloseModal()
	Sounds.Ambient(false)
	state = "menu"
	paused = false
	clearScene()
	Hud.SetVisible(false)
	DebugDraw.SetVisible(false, false)
	-- the menu is a live cinematic around the player's real, physically simulated car
	refreshProfile(0.4)
	MenuCinematic.Start(cfg, function(on)
		MainMenu.SetReveal(on, string.upper(cfg.skin == "Troll" and "Carrito Troll" or "Octane") .. "  ·  HITBOX " .. string.upper(cfg.hitbox))
	end)
	local function preview(newCfg)
		cfg.skin = newCfg.skin
		cfg.hitbox = newCfg.hitbox
		MenuCinematic.SetCar(cfg)
	end
	MainMenu.Show(cfg, HITBOXES, function(newCfg)
		MenuCinematic.Stop()
		cfg = newCfg
		-- start the match
		clearScene()
		world = World.new({ seed = math.floor(os.clock() * 1000) % 100000 })
		player = world:AddCar(0, CarConfig[cfg.hitbox])
		bots = {}
		local diff = cfg.difficulty
		-- one name per bot for the whole match (intro + nameplates)
		local seed = math.floor(os.clock() * 7) % #BOT_NAMES
		local function botName(i: number): string
			return BOT_NAMES[(seed + i) % #BOT_NAMES + 1]
		end
		if cfg.mode == "2v2" then
			local mate = world:AddCar(0, CarConfig.Octane)
			table.insert(bots, BotAI.new(world, mate, diff, 11))
			table.insert(bots, BotAI.new(world, world:AddCar(1, CarConfig.Octane), diff, 21))
			table.insert(bots, BotAI.new(world, world:AddCar(1, CarConfig.Octane), diff, 22))
		elseif cfg.mode == "1v1" or cfg.bot then
			table.insert(bots, BotAI.new(world, world:AddCar(1, CarConfig.Octane), diff, 21))
		end
		local carNames = {}
		matchNames = carNames
		carNames[player] = Players.LocalPlayer.DisplayName
		for i, b in bots do
			-- 2v2: mate, opp, opp -> names 1,2,3 ; 1v1: opp -> 2
			carNames[b.car] = botName(if cfg.mode == "2v2" then i else 2)
		end
		for _, car in world.cars do
			visuals[car] = CarVisual.new(car, renderFolder, if car == player then cfg.skin else "Octane")
			if car ~= player and carNames[car] then
				visuals[car]:SetNameplate(carNames[car], if car.team == 0 then Hud.BLUE else Hud.ORANGE)
			end
		end
		ballVisual = BallVisual.new(renderFolder)
		padVisuals = BoostPadVisuals.new(world.pads, renderFolder)
		prediction = BallPrediction.new(360)
		score[0], score[1] = 0, 0
		timeLeft = MATCH_LENGTH
		overtime = false
		overtimeTime = 0
		unlimitedBoost = cfg.mode == "training"
		matchEvents = MatchEvents.new(world, player)
		Hud.ResetStats()
		if cfg.mode == "training" then
			state = "match"
			Hud.SetVisible(true)
			kickoff()
		else
			-- pre-match introduction with the real cars, then the kickoff
			state = "intro"
			Hud.SetVisible(false)
			kickoff()
			for _, v in visuals do v:Update(CFrame.new(), false) end
			ballVisual:Update(CFrame.new(), false)
			-- the low cinematic cameras skim the pads; hide them until kickoff
			local pads = renderFolder:FindFirstChild("BoostPads")
			if pads then pads.Parent = nil end
			local diffLabel = BotAI.Difficulties[cfg.difficulty].label
			local entries = { { team = 0, skin = cfg.skin, config = CarConfig[cfg.hitbox], name = Players.LocalPlayer.DisplayName, tag = "TÚ  ·  " .. string.upper(cfg.hitbox) } }
			if cfg.mode == "2v2" then
				table.insert(entries, { team = 0, config = CarConfig.Octane, name = botName(1), tag = "COMPAÑERO  ·  BOT " .. diffLabel })
				table.insert(entries, { team = 1, config = CarConfig.Octane, name = botName(2), tag = "RIVAL  ·  BOT " .. diffLabel })
				table.insert(entries, { team = 1, config = CarConfig.Octane, name = botName(3), tag = "RIVAL  ·  BOT " .. diffLabel })
			else
				table.insert(entries, { team = 1, config = CarConfig.Octane, name = botName(2), tag = "RIVAL  ·  BOT " .. diffLabel })
			end
			Intro.Play({ entries = entries }, function()
				if pads then pads.Parent = renderFolder end
				Sounds.Ambient(true)
				state = "match"
				Hud.SetVisible(true)
				kickoff()
			end)
		end
	end, preview)
end

local function endMatch()
	phase = "over"
	local mine, theirs = score[0], score[1]
	Sounds.Result(mine > theirs)
	local title = if mine > theirs then "VICTORIA" elseif mine < theirs then "DERROTA" else "EMPATE"
	local color = if mine > theirs then Hud.BLUE elseif mine < theirs then Hud.ORANGE else nil
	local result = if mine > theirs then "win" elseif mine < theirs then "loss" else "draw"
	local points = if matchEvents then matchEvents.points else 0
	local xp = Progression.MatchXp(points, result)
	local rem = RS:FindFirstChild("Remotes")
	local submit = rem and rem:FindFirstChild("SubmitMatch") :: RemoteEvent?
	if submit and matchEvents then
		local st = matchEvents.stats
		submit:FireServer({
			result = result, points = points, mode = cfg.mode, difficulty = cfg.difficulty,
			goals = st.goals, assists = st.assists, saves = st.saves, epicSaves = st.epicSaves, shots = st.shots,
			clears = st.clears, demos = st.demos, aerials = st.aerials, bestKmh = st.bestKmh,
			pinches = st.pinches, bestPinchKmh = st.bestPinchKmh,
		})
	end
	MainMenu.Modal(title, string.format("AZUL %d  —  %d NARANJA   ·   %d PTS   ·   +%d XP", mine, theirs, points, xp), color, {
		{ "REVANCHA", "ENTER", function()
			MainMenu.CloseModal()
			score[0], score[1] = 0, 0
			timeLeft = MATCH_LENGTH
			overtime = false
			overtimeTime = 0
			matchEvents = MatchEvents.new(world, player)
			Hud.ResetStats()
			kickoff()
		end },
		{ "MENÚ PRINCIPAL", "M", openMenu },
	})
end

local function togglePause()
	if state ~= "match" or phase == "over" then
		return
	end
	if paused then
		paused = false
		MainMenu.CloseModal()
		return
	end
	paused = true
	MainMenu.Modal("PAUSA", nil, nil, {
		{ "CONTINUAR", "ENTER", function() paused = false; MainMenu.CloseModal() end },
		{ "REINICIAR KICKOFF", "R", function() paused = false; MainMenu.CloseModal(); kickoff() end },
		{ "MENÚ PRINCIPAL", "M", openMenu },
	}, { back = "ENTER" })
end

Input.On("pause", function()
	if MainMenu.ModalOpen() and not paused then
		return -- result screen handles its own keys
	end
	if paused then
		return -- the pause modal handles M itself
	end
	togglePause()
end)
Input.On("reset", function()
	if state == "match" and cfg.mode == "training" and not paused then
		kickoff()
	end
end)
Input.On("unlimitedBoost", function()
	if state == "match" and cfg.mode == "training" then
		unlimitedBoost = not unlimitedBoost
	end
end)
-- Training drill: the car dives onto a resting ball (the ground-pinch setup measured against RocketSim).
-- The player keeps full control, so it's practice for timing the squeeze, not an automatic pinch.
Input.On("pinchDrill", function()
	if state ~= "match" or cfg.mode ~= "training" or paused then
		return
	end
	local f = player.body.fwd
	local f2 = Vector3.new(f.X, f.Y, 0)
	f2 = if f2.Magnitude > 1e-3 then f2.Unit else Vector3.new(0, 1, 0)
	local cp = player.body.pos * BT
	local ball = cp + f2 * 700
	ball = Vector3.new(math.clamp(ball.X, -3400, 3400), math.clamp(ball.Y, -4200, 4200), C.BALL_REST_Z)
	BallPhysics.SetState(world.ball, ball, Vector3.zero, Vector3.zero)
	world.ballEnabled = true
	local yaw = math.atan2(f2.Y, f2.X)
	CarPhysics.ResetState(player, ball - f2 * 200 + Vector3.new(0, 0, 170 - C.BALL_REST_Z), yaw, 100, false)
	player.body.vel = (f2 * 2300 + Vector3.new(0, 0, -1800)) / BT
	if matchEvents then matchEvents:Reset() end
	phase = "play"
	snapAll()
end)

Input.On("launchBall", function()
	if state ~= "match" or cfg.mode ~= "training" or paused then
		return
	end
	local cp = player.body.pos * BT
	local f = player.body.fwd
	local f2 = Vector3.new(f.X, f.Y, 0)
	f2 = if f2.Magnitude > 1e-3 then f2.Unit else Vector3.new(0, 1, 0)
	local start = cp + f2 * 2600 + Vector3.new(0, 0, 200)
	start = Vector3.new(math.clamp(start.X, -3600, 3600), math.clamp(start.Y, -4600, 4600), start.Z)
	local landing = cp + f2 * 900
	local v = (landing - start) / 1.6
	BallPhysics.SetState(world.ball, start, Vector3.new(v.X, v.Y, 1100), Vector3.zero)
	world.ballEnabled = true
	phase = "play"
end)

local function simTick()
	for car, s in snaps do
		s.prev = s.cur
	end
	if state ~= "match" or paused or phase == "countdown" or phase == "over" then
		return
	end
	simTime += C.TICK_TIME
	player.controls = Input.Read((player.numWheelsInContact or 0) == 0)
	if unlimitedBoost then
		player.boost = 100
	end
	local t0 = os.clock()
	if #bots > 0 then
		if world.ballEnabled then
			prediction:Update(world)
			local ctx = BotAI.BuildContext(world, prediction, simTime)
			for _, b in bots do
				b:Tick(C.TICK_TIME, ctx)
			end
		else
			-- goal pause: the frozen ball would force a full 360-step re-prediction every tick (~5 ms); bots just coast
			for _, b in bots do
				b.car.controls = CarPhysics.EmptyControls()
			end
		end
	end
	world:Step()
	lastTickMs = (os.clock() - t0) * 1000
	for _, e in world.events do
		if e.type == "goal" and phase == "play" then
			score[e.team] += 1
			lastScorer = e.team
			phase = "goal"
			phaseTime = 0
			local color = if e.team == 0 then Hud.BLUE else Hud.ORANGE
			Effects.Goal(RenderMap.Pos(world.ball.body.pos * BT), color, true)
			Camera.Shake(3.2)
			-- the goal explosion throws nearby cars away (RL): strongest at the ball, fading out by 1500 uu
			local gp = world.ball.body.pos
			local rng = Random.new()
			for _, car in world.cars do
				if not car.isDemoed then
					local d = (car.body.pos - gp) * BT
					local dist = d.Magnitude
					if dist < 1500 then
						local k = (1 - dist / 1500) ^ 0.8
						local flat = Vector3.new(d.X, d.Y, 0)
						local dir = ((if flat.Magnitude > 1 then flat.Unit else Vector3.new(0, -math.sign(gp.Y), 0)) + Vector3.new(0, 0, 0.75)).Unit
						car.body.vel += dir * (2800 * k) / BT
						car.body.angVel += Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * (7 * k)
					end
				end
			end
			slowmo = { t = 0, low = 0.25, hold = 0.8, ease = 0.6, goal = true }
			world.ballEnabled = false
		elseif e.type == "hit" then
			local extra = e.car.ballHitInfo.extraHitVel.Magnitude
			-- every touch sounds (the sparks below are only for the strong ones)
			if extra <= 150 and os.clock() - (e.car.lastTouchSound or 0) > 0.2 then
				e.car.lastTouchSound = os.clock()
				Sounds.Hit(RenderMap.Pos(world.ball.body.pos * BT), math.clamp((world.ball.body.vel * BT).Magnitude / 4000, 0, 0.4))
			end
			if extra > 150 and e.car.ballHitInfo.tickCountWhenExtraImpulseApplied == world.tickCount - 1 then
				local bp = world.ball.body.pos
				local cp = CarPhysics.GetHitboxCenter(e.car)
				local contact = bp + (cp - bp).Unit * world.ball.radius
				local strength = math.clamp(extra / 1400, 0, 1)
				Effects.Hit(RenderMap.Pos(contact * BT), strength)
				if strength > 0.45 and e.car == player then
					Camera.Shake(strength * 0.5)
				end
			end
		elseif e.type == "pad" and padVisuals then
			local car = e.car
			Effects.BoostPickup(padVisuals:PadPos(e.pad), e.pad.isBig, function()
				local sn = snaps[car]
				return if sn then RenderMap.Pos(sn.cur.p) else RenderMap.Pos(car.body.pos * BT)
			end)
		elseif e.type == "demo" then
			Effects.Demolish(RenderMap.Pos(e.victim.body.pos * BT), if e.victim.team == 0 then Hud.BLUE else Hud.ORANGE)
		elseif e.type == "bump" then
			Sounds.Bump(RenderMap.Pos(e.victim.body.pos * BT))
		end
	end
	if matchEvents then
		matchEvents:Tick(hudEvents, unlimitedBoost)
	end
	if world.ballEnabled and world.ball.body.pos.Z * BT <= C.BALL_REST_Z + 4 then
		ballGroundedLatch = true
	end
	for _, car in world.cars do
		snaps[car].cur = snapCar(car)
	end
	local b = world.ball.body
	snaps.ball.cur = { p = b.pos * BT, q = b.rot }
end

local function debugText(): string
	local b = player.body
	local ball = world.ball.body
	local v = b.vel * BT
	local lines = {
		string.format("tick %d   sim %.2f ms/tick   hitbox %s   bots %d", world.tickCount, lastTickMs, player.config.name, #bots),
		string.format("CAR  speed %7.1f uu/s  %s", v.Magnitude, if player.isSupersonic then "SUPERSONIC" else ""),
		string.format("     pos (%7.1f %7.1f %7.1f)", b.pos.X * BT, b.pos.Y * BT, b.pos.Z * BT),
		string.format("     wheels %d/4  onGround %s  boost %.0f", player.numWheelsInContact or 0, tostring(player.isOnGround), player.boost),
		string.format("     jumped %s dbl %s flipped %s flipping %s", tostring(player.hasJumped), tostring(player.hasDoubleJumped), tostring(player.hasFlipped), tostring(player.isFlipping)),
		string.format("BALL speed %7.1f  pos (%6.0f %6.0f %6.0f)", ball.vel.Magnitude * BT, ball.pos.X * BT, ball.pos.Y * BT, ball.pos.Z * BT),
	}
	for i, bot in bots do
		local p = bot.plan
		table.insert(lines, string.format("BOT%d %s team %d  %s  plan t=%.2f z=%.0f%s", i, bot.difficulty, bot.car.team,
			if bot.aerial then "AERIAL" else "", p and p.t or -1, p and p.height or -1, if bot.car.isDemoed then " DEMOED" else ""))
	end
	return table.concat(lines, "\n")
end

local function lerpSnap(s: any, alpha: number)
	return s.prev.p:Lerp(s.cur.p, alpha), Q.slerp(s.prev.q, s.cur.q, alpha)
end

local elapsed = 0
RunService:BindToRenderStep("RocketSimLoop", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	elapsed += dt
	if state == "menu" then
		MenuCinematic.Update(dt)
		return
	end

	if state == "intro" then
		Intro.Update(dt)
		return
	end

	-- match clock / phases (real time)
	if not paused then
		phaseTime += dt
		local timed = cfg.mode ~= "training"
		if phase == "countdown" and phaseTime >= COUNTDOWN then
			phase = "play"
			phaseTime = 0
		elseif phase == "goal" and phaseTime >= GOAL_PAUSE then
			if timed and (overtime or timeLeft <= 0) then
				endMatch()
			else
				kickoff()
			end
		elseif phase == "play" and timed then
			if overtime then
				overtimeTime += dt
			else
				timeLeft -= dt
				if timeLeft <= 0 then
					timeLeft = 0
					-- RL rule: at 0:00 play continues until the ball touches the ground
					if ballGroundedLatch then
						if score[0] == score[1] then
							overtime = true
							kickoff()
						else
							endMatch()
						end
					end
				end
			end
		end
	end

	ballGroundedLatch = false
	-- goal slow motion: 0.25x for 0.8 s, then eases back to real time over 0.6 s (sim, shake and goal burst)
	local timeScale = 1
	if slowmo then
		slowmo.t += dt
		local k = math.clamp((slowmo.t - slowmo.hold) / slowmo.ease, 0, 1)
		timeScale = slowmo.low + (1 - slowmo.low) * (k * k * (3 - 2 * k))
		if k >= 1 or state ~= "match" or (slowmo.goal and phase ~= "goal") then
			slowmo = nil
			timeScale = 1
		end
	end
	Camera.SetTimeScale(timeScale)
	local alpha = fixed:Advance(dt * timeScale, simTick)
	if state ~= "match" then
		return
	end

	local playerCF = nil
	for _, car in world.cars do
		local p, q = lerpSnap(snaps[car], alpha)
		local cf = RenderMap.CFrame(p, q)
		visuals[car]:Update(cf, not car.isDemoed)
		if car == player then playerCF = cf end
	end
	local bp, bq = lerpSnap(snaps.ball, alpha)
	local ballCF = RenderMap.CFrame(bp, bq)
	local ballVisible = world.ballEnabled
	ballVisual:Update(ballCF, ballVisible)
	ballVisual:SetSpeed(if ballVisible then world.ball.body.vel.Magnitude * BT else 0)
	if padVisuals then padVisuals:Update(elapsed) end

	local ballCamOn = Input.Toggle("ballCam") and ballVisible
	do
		-- camera works in UU with Roblox axes
		local pp, pq = lerpSnap(snaps[player], alpha)
		local f, _, u = Q.toBasis(pq)
		local nSum = Vector3.zero
		for _, w in player.wheels do
			if w.isInContact then
				nSum += w.contactNormal
			end
		end
		Camera.Update(dt, {
			carPos = RenderMap.Dir(pp),
			carFwd = RenderMap.Dir(f),
			carUp = RenderMap.Dir(u),
			flipping = player.isFlipping,
			carVel = RenderMap.Dir(player.body.vel * BT),
			speedUU = player.body.vel.Magnitude * BT,
			onGround = (player.numWheelsInContact or 0) > 0,
			groundNormal = if nSum.Magnitude > 1e-3 then RenderMap.Dir(nSum.Unit) else nil,
			supersonic = player.isSupersonic,
			ballPos = if ballVisible then RenderMap.Dir(bp) else nil,
			ballCam = ballCamOn,
		})
	end

	local debugOn = Input.Toggle("debug")
	local predOn = Input.Toggle("prediction") and ballVisible
	if predOn and #bots == 0 then
		prediction = prediction or BallPrediction.new(720)
		prediction:Update(world)
	end
	DebugDraw.SetVisible(debugOn, predOn)
	DebugDraw.Update(player, world.ball, playerCF, ballCF.Position, prediction, debugOn, predOn)

	local msg, msgColor = "", nil
	if phase == "countdown" then
		msg = tostring(math.max(1, math.ceil(COUNTDOWN - phaseTime)))
	elseif phase == "play" and phaseTime < 0.6 and cfg.mode ~= "training" then
		msg = if overtime and overtimeTime < 0.6 then "¡PRÓRROGA!" else "¡YA!"
	elseif phase == "goal" then
		msg = "¡GOL!"
		msgColor = if lastScorer == 0 then Hud.BLUE else Hud.ORANGE
	end
	local tags = { player.config.name:upper() }
	if cfg.mode == "training" then table.insert(tags, "ENTRENAMIENTO") end
	if #bots > 0 then table.insert(tags, "BOTS " .. BotAI.Difficulties[cfg.difficulty].label) end
	if ballCamOn then table.insert(tags, "CÁMARA BALÓN") end
	if unlimitedBoost then table.insert(tags, "TURBO ∞") end
	if player.isSupersonic then table.insert(tags, "SUPERSÓNICO") end
	local timerText = nil
	if cfg.mode == "training" then
		timerText = "LIBRE"
	elseif overtime then
		local t = math.floor(overtimeTime)
		timerText = string.format("+%d:%02d", t // 60, t % 60)
	end
	local timerNote = if cfg.mode ~= "training" and not overtime and timeLeft <= 0 and phase == "play" then "¡BALÓN EN JUEGO!" else nil
	for _, ev in hudEvents do
		if ev.kind == "goal" then
			local function nm(car) return car and matchNames[car] and string.upper(matchNames[car]) or nil end
			ev.scorerName = nm(ev.scorer)
			ev.assistName = nm(ev.assist)
		end
		if ev.kind == "hit" then
			ev.worldStuds = RenderMap.Pos(ev.pos)
		elseif ev.kind == "pinch" then
			-- hit-stop: a short freeze-frame, then the ball rockets off glowing gold
			if not slowmo then
				slowmo = { t = 0, low = 0.15, hold = 0.12, ease = 0.3 }
			end
			Camera.Shake(1.2 + math.clamp((ev.kmh - 90) / 60, 0, 1.2))
			ballVisual:Flare(1.6)
		end
		Hud.Event(ev, { team = player.team })
	end
	table.clear(hudEvents)
	local showBoard = Input.ScoreboardHeld() and matchEvents ~= nil and state == "match"
	Scoreboard.SetVisible(showBoard)
	if showBoard then
		local entries = {}
		for _, car in world.cars do
			table.insert(entries, {
				key = car, name = matchNames[car] or (if car == player then Players.LocalPlayer.DisplayName else "BOT"),
				team = car.team, isLocal = car == player, bot = car ~= player,
				userId = if car == player then Players.LocalPlayer.UserId else nil,
				stats = matchEvents:Board(car),
			})
		end
		local tLeft = math.max(0, math.ceil(timeLeft))
		Scoreboard.Update(entries, score[0], score[1], timerText or string.format("%d:%02d", tLeft // 60, tLeft % 60))
	end
	Hud.Update({
		blue = score[0], orange = score[1], timeLeft = timeLeft, timerText = timerText,
		boost = player.boost, unlimitedBoost = unlimitedBoost,
		carWorld = if playerCF then playerCF.Position else nil,
		ballWorld = if ballVisible then ballCF.Position else nil,
		ballCam = ballCamOn, supersonic = player.isSupersonic, timerNote = timerNote,
		tags = tags,
		message = msg, messageColor = msgColor,
		help = Input.Toggle("help"),
		debugText = if debugOn then debugText() else nil,
	})
end)

MainMenu.ReturnToMenu = openMenu

local returnEvent = Game:WaitForChild("ReturnToMenuEvent", 5) :: BindableEvent?
if returnEvent then
	returnEvent.Event:Connect(openMenu)
end

Players.LocalPlayer.CharacterAdded:Connect(function(ch) ch:Destroy() end)
openMenu()

-- online matches / private rooms (server-run): queue pill, room screen, and joining by code after a teleport
task.spawn(function()
	local OnlinePlay = require(RS:WaitForChild("Party"):WaitForChild("OnlinePlay"))
	OnlinePlay.Init()
end)
