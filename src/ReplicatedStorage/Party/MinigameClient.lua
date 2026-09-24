--!strict
-- MinigameClient.lua: the client side of a server-authoritative Party minigame round.
--
-- The server owns the round. This client only:
--   * reads the player's controls at 120 Hz, quantises them exactly like the server, and sends them in batches
--     (each packet repeats the last few inputs, so a lost packet costs nothing);
--   * shows the PRESENT while it has a car: its own car, the ball and ghosts of the other cars run in a local World
--     built from the minigame's shared module (Party.Prediction), rewound and replayed when the server disagrees -
--     so a touch or a bump happens where you see it, not ~100 ms after your car went through;
--   * as a spectator (no car / eliminated), draws everything from 30 Hz snapshots interpolated INTERP_DELAY behind;
--   * hands discrete events (points, phases, results) to the minigame's view and the HUD.
-- It never decides anything that matters: scores, bounces, checkpoints, eliminations all come from the server.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local CarPhysics = require(Phys.CarPhysics)
local CarConfig = require(Phys.CarConfig)
local FixedStep = require(Phys.FixedStep)
local Q = require(Phys.Quaternion)

local Game = RS:WaitForChild("Game")
local RenderMap = require(Game.RenderMap)
local Input = require(Game.InputController)
local Camera = require(Game.CameraController)
local CarVisual = require(Game.CarVisual)
local BallVisual = require(Game.BallVisual)
local Effects = require(Game.Effects)
local Sounds = require(Game.Sounds)
local GameHud = require(Game.Hud)

local Party = script.Parent
local Net = require(Party.Net)
local Hud = require(Party.MinigameHud)
local Prediction = require(Party.Prediction)
local Views = Party:WaitForChild("MinigameViews")

local BT = C.BT_TO_UU
local TICK = Net.TICK
local SEND_INTERVAL = 1 / 60
local SNAP_KEEP = 1.0 -- s of snapshots kept for interpolation
local SILENCE_TIMEOUT = 12 -- s without any server traffic in a live round: give up locally

local VIEW_MODULES = {
	beach_volley = "BeachVolley", sumo_remix = "SumoRemix", sky_ring_rush = "SkyRingRush", king_of_the_hill = "KingOfTheHill",
	soccar = "Soccar", heatseeker = "Heatseeker", derby = "Derby", infection = "Infection", minigolf = "Minigolf",
}

local MinigameClient = {}
local listeners = { start = {} :: { (any) -> () }, finish = {} :: { (any) -> () } }
local active: any = nil
local remotes: any = nil

-- both return a function that unsubscribes
local function subscribe(list: { (any) -> () }, fn: (any) -> ()): () -> ()
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then table.remove(list, i) end
	end
end

function MinigameClient.OnRoundStart(fn: (any) -> ()): () -> ()
	return subscribe(listeners.start, fn)
end

function MinigameClient.OnRoundEnd(fn: (any) -> ()): () -> ()
	return subscribe(listeners.finish, fn)
end

function MinigameClient.IsActive(): boolean
	return active ~= nil
end

function MinigameClient.Active(): any
	return active
end

local function teamColor(team: number?): Color3
	return if team == 1 then GameHud.ORANGE else GameHud.BLUE
end
MinigameClient.TeamColor = teamColor

-- body panels + boost flame in one colour (same parts the lobby paints)
local function paint(v: any, color: Color3)
	for _, p in v.model:GetDescendants() do
		if p:IsA("BasePart") and (p.Name == "Part 1" or p.Name == "Part 2" or p.Name == "Part" or p.Name == "Part 4") then
			p.Color = color
		end
	end
	if v.boostTrail then v.boostTrail.Color = ColorSequence.new(Color3.new(1, 1, 1), color) end
	if v.flame then v.flame.Color = ColorSequence.new(Color3.new(1, 1, 1), color) end
end

-- ================================================================ round
local Round = {}
Round.__index = Round

function Round.new(payload: any, sessionId: string, roundId: number)
	local self = setmetatable({}, Round)
	self.sessionId = sessionId
	self.roundId = roundId
	self.minigameId = payload.minigameId
	self.displayName = payload.displayName
	self.description = payload.description
	self.state = payload.state
	self.phaseStart = payload.startTime
	self.phaseEnd = payload.endTime
	self.public = payload.public or {}
	self.shared = require(Party.MinigameShared:WaitForChild(payload.sharedModule))
	self.folder = Instance.new("Folder")
	self.folder.Name = "MinigameRound"
	self.folder.Parent = workspace
	self.participants = {}
	self.byId = {}
	self.byNet = {}
	self.lastTraffic = os.clock()
	local lp = Players.LocalPlayer
	for _, p in payload.participants do
		table.insert(self.participants, p)
		self.byId[p.id] = p
		if p.netId then self.byNet[p.netId] = p end
		if p.userId == lp.UserId then self.me = p end
	end

	-- the present: our car, the ball and ghosts of the others, predicted locally (spectators have none)
	if self.me then
		self.pred = Prediction.new(self.shared, self.me, self.participants)
		self.myCar = self.pred.car
		self.fixed = FixedStep.new()
		self.lastSend = 0
		self.netStats = self.pred.stats -- prediction health, for debugging
	end

	-- a minigame on its own map: build it, put the stadium away, and let the camera collide with the map instead
	if self.shared.Map then
		local okMap, map = pcall(self.shared.Map)
		if okMap and map then
			self.map = map
			local MapKit = require(Party.MapKit)
			self.restoreStadium = MapKit.HideStadium()
			local okV, model = pcall(map.BuildVisual, map, self.folder)
			if okV then self.mapModel = model else warn("[MinigameClient] map visual:", model) end
			if map.ApplyLighting then
				local okL, restore = pcall(map.ApplyLighting, map)
				if okL then self.restoreLighting = restore end
			end
			Camera.SetArena(map:Arena())
		end
	end

	self.snaps = {}
	self.lastSnapTick = -1
	self.visuals = {} -- participant id -> { visual, proxy?, p, pos, hidden }
	local modName = VIEW_MODULES[self.minigameId]
	local mod = modName and Views:FindFirstChild(modName)
	self.view = if mod then require(mod :: ModuleScript).new(self) else nil

	-- visuals: our car draws the predicted car; the others draw proxy cars fed by snapshots
	for _, p in self.participants do
		self:AddVisual(p)
	end
	self.ball = BallVisual.new(self.folder)
	if not (self.view and self.view.CustomHud) then
		Hud.Open(self) -- (the online match brings the full match HUD instead)
	end
	return self
end

function Round.AddVisual(self: any, p: any)
	local skin = p.skin or "Octane"
	local car
	local proxy = nil
	if p == self.me then
		car = self.myCar
	else
		proxy = CarPhysics.new(CarConfig[p.hitbox] or CarConfig.Octane, p.team or 0, 100 + (p.netId or 0))
		car = proxy
	end
	local v = CarVisual.new(car, self.folder, skin)
	-- free-for-all minigames give every player their own colour (the view decides)
	local color = self.view and self.view.CarColor and self.view:CarColor(p) or nil
	if color then paint(v, color) end
	if p ~= self.me then
		v:SetNameplate(p.name or "?", color or teamColor(p.team))
	end
	v:Update(CFrame.new(), false)
	self.visuals[p.id] = { visual = v, proxy = proxy, p = p }
end

-- a view recolours a car mid-round (infection: the infected turn green)
function Round.Repaint(self: any, id: string, color: Color3)
	local e = self.visuals[id]
	if not e then return end
	paint(e.visual, color)
	if e.p ~= self.me and e.visual.SetNameplate then
		e.visual:SetNameplate(e.p.name or "?", color)
	end
end

-- tell the server we've loaded (once); views with DeferReady call this when they're done (e.g. an intro)
function Round.Ready(self: any)
	if self.readySent then return end
	self.readySent = true
	remotes.MgReady:FireServer(self.sessionId)
end

function Round.RemoveParticipant(self: any, id: string)
	local e = self.visuals[id]
	if e then
		e.visual:Destroy()
		self.visuals[id] = nil
	end
	local p = self.byId[id]
	if p then
		if p.netId then self.byNet[p.netId] = nil end
		self.byId[id] = nil
		local i = table.find(self.participants, p)
		if i then table.remove(self.participants, i) end
	end
end

function Round.Live(self: any): boolean
	return self.state == "COUNTDOWN" or self.state == "ACTIVE"
end

function Round.ControlsLocked(self: any): boolean
	if self.state ~= "ACTIVE" then return true end
	return self.view ~= nil and self.view.ControlsLocked ~= nil and self.view:ControlsLocked()
end

-- server clock seconds left in the current phase
function Round.PhaseLeft(self: any): number
	return math.max(0, (self.phaseEnd or 0) - Net.Now())
end

function Round.PhaseElapsed(self: any): number
	return math.max(0, Net.Now() - (self.phaseStart or 0))
end

-- ---------------------------------------------------------------- prediction
-- we have a car, the server has told us where it is, and it isn't hidden (eliminated / demolished)
function Round.Present(self: any): boolean
	return self.pred ~= nil and self.pred.hasState and not self.meHidden
end

function Round.PredictTick(self: any)
	local pred = self.pred
	if not (pred and pred.hasState and self:Live()) or self.meHidden then return end
	local controls
	if self:ControlsLocked() then
		controls = CarPhysics.EmptyControls()
	else
		controls = Net.Quantize(Input.Read((pred.car.numWheelsInContact or 0) == 0))
	end
	-- the minigame's per-tick rule runs when the server runs it (e.g. only during a volley rally)
	pred.postLive = self.state == "ACTIVE" and (not (self.view and self.view.PostStepLive) or self.view:PostStepLive())
	pred:Tick(controls)
	-- sounds for what just happened in our predicted world: ball touches (ours and the ghosts') and bumps
	local pw = pred.pw
	for _, e in pw.events do
		if e.type == "hit" and e.car then
			local now = os.clock()
			if now - (e.car.lastTouchSound or 0) > 0.2 then
				e.car.lastTouchSound = now
				local ball = e.ball or pw.ball
				local strength = math.clamp((ball.body.vel * BT).Magnitude / 3500, 0, 1)
				pcall(Sounds.Hit, RenderMap.Pos(ball.body.pos * BT), strength)
				if e.car == pred.car and strength > 0.5 then Camera.Shake(strength * 0.35) end
			end
		elseif e.type == "bump" and (e.bumper == pred.car or e.victim == pred.car) then
			pcall(Sounds.Bump, RenderMap.Pos(e.victim.body.pos * BT))
		end
	end
end

function Round.SendInputs(self: any)
	local outbox = self.pred.outbox
	if #outbox == 0 then return end
	local now = os.clock()
	if now - self.lastSend < SEND_INTERVAL then return end
	self.lastSend = now
	remotes.MgInput:FireServer(Net.EncodeInputs(outbox))
end

function Round.OnLocalState(self: any, b: any)
	if not self.pred then return end
	local ack, tick, applyCar, applyBall, ballEnabled = Net.DecodeLocalState(b)
	if not (ack and tick and applyCar and applyBall) then return end
	self.lastTraffic = os.clock()
	if self.pred:OnLocalState(ack, tick, applyCar, applyBall, ballEnabled == true) == "reset" then
		local p, q = self.pred:CarRender(1)
		Camera.Reset(RenderMap.CFrame(p, q))
	end
end

-- ---------------------------------------------------------------- snapshots
function Round.OnSnapshot(self: any, b: any)
	local s = Net.DecodeSnapshot(b)
	if not s then return end
	if self.pred then self.pred:OnSnapshot(s) end
	if s.tick <= self.lastSnapTick then return end
	self.lastSnapTick = s.tick
	self.lastTraffic = os.clock()
	table.insert(self.snaps, s)
	local cutoff = s.serverTime - SNAP_KEEP
	while #self.snaps > 2 and self.snaps[1].serverTime < cutoff do
		table.remove(self.snaps, 1)
	end
end

-- two snapshots around the render time and the blend between them (spectator view)
function Round.Sample(self: any): (any, any, number)
	local snaps = self.snaps
	local n = #snaps
	if n == 0 then return nil, nil, 0 end
	local rt = Net.Now() - Net.INTERP_DELAY
	if rt >= snaps[n].serverTime or n == 1 then
		return snaps[n], snaps[n], 0
	end
	if rt <= snaps[1].serverTime then
		return snaps[1], snaps[1], 0
	end
	for i = n - 1, 1, -1 do
		local a = snaps[i]
		if a.serverTime <= rt then
			local b = snaps[i + 1]
			return a, b, (rt - a.serverTime) / math.max(1e-4, b.serverTime - a.serverTime)
		end
	end
	return snaps[n], snaps[n], 0
end

local function applyProxy(proxy: any, cs: any, dt: number)
	proxy.isBoosting = cs.boosting
	proxy.isSupersonic = cs.supersonic
	proxy.numWheelsInContact = if cs.onGround then 4 else 0
	local fwd = Q.toBasis(cs.rot)
	local speed = cs.vel:Dot(fwd)
	for i, w in proxy.wheels do
		local f = cs.susp[i] or 0.5
		w.suspensionLength = (w.restLen - w.travel) + f * 2 * w.travel
		w.steerAngle = if w.front then cs.steer * 0.45 else 0
		w.spin = (w.spin + (if cs.onGround then speed else speed * 0.3) / (w.radius * BT) * dt) % (2 * math.pi)
	end
end

-- ---------------------------------------------------------------- per frame
function Round.Frame(self: any, dt: number)
	local alpha = 0
	if self.pred then
		alpha = self.fixed:Advance(dt, function()
			self:PredictTick()
		end)
		self:SendInputs()
		self.pred:Decay(dt)
	end
	local latest = self.snaps[#self.snaps]
	if self.me and latest then
		local cs = latest.cars[self.me.netId]
		self.meHidden = cs ~= nil and (cs.hidden or cs.demoed) -- eliminated / demolished: spectate
	end
	local present = self:Present()
	local s0, s1, k = self:Sample()
	-- a view can take over the screen for a moment (the online match's intro): nothing of the round is drawn
	if self.view and self.view.CameraOverride and self.view:CameraOverride() then
		for _, e in self.visuals do e.visual:Update(CFrame.new(), false) end
		self.ball:Update(CFrame.new(), false)
		self.view:Update(dt)
		return
	end

	-- other cars: in the present next to ours, or interpolated for a spectator
	for _, e in self.visuals do
		local p = e.p
		if p == self.me then continue end
		local pos, rot, cs = nil, nil, nil
		if present then
			pos, rot, cs = self.pred:GhostRender(p.netId, alpha)
		elseif s0 and s1 then
			local a, b = s0.cars[p.netId], s1.cars[p.netId]
			if a and b then
				pos, rot, cs = a.pos:Lerp(b.pos, k), Q.slerp(a.rot, b.rot, k), if k < 0.5 then a else b
			end
		end
		if pos and cs then
			applyProxy(e.proxy, cs, dt)
			e.hidden = cs.hidden or cs.demoed
			e.visual:Update(RenderMap.CFrame(pos, rot), not e.hidden)
			e.pos = pos
		else
			e.visual:Update(CFrame.new(), false)
		end
	end

	-- our car
	local me = self.me and self.visuals[self.me.id]
	if me and present then
		local pos, rot = self.pred:CarRender(alpha)
		me.hidden = false
		me.visual:Update(RenderMap.CFrame(pos, rot), true)
		me.pos, me.rot = pos, rot
	elseif me then
		me.hidden = self.meHidden
		me.visual:Update(CFrame.new(), false)
	end

	-- ball: predicted with our car (touches show when they happen), interpolated for a spectator
	local ballPos, ballVisible = nil, latest ~= nil and latest.ballVisible
	if ballVisible and present then
		local rot
		ballPos, rot = self.pred:BallRender(alpha)
		self.ballVel = self.pred:BallVelocity()
		self.ball:Update(RenderMap.CFrame(ballPos, rot), true)
		self.ball:SetSpeed(self.ballVel.Magnitude)
	elseif s0 and s1 then
		ballVisible = s1.ballVisible and s0.ballVisible
		ballPos = s0.ball.pos:Lerp(s1.ball.pos, k)
		self.ball:Update(RenderMap.CFrame(ballPos, Q.slerp(s0.ball.rot, s1.ball.rot, k)), ballVisible)
		self.ball:SetSpeed(if ballVisible then s1.ball.vel.Magnitude else 0)
		self.ballVel = s1.ball.vel
	else
		self.ball:Update(CFrame.new(), false)
	end
	self.ballPos = if ballVisible then ballPos else nil

	self:UpdateCamera(dt, me)
	if self.view and self.view.Update then
		self.view:Update(dt)
	end
	if not (self.view and self.view.CustomHud) then
		Hud.Update(self, dt)
	end
end

function Round.UpdateCamera(self: any, dt: number, me: any)
	local ballCam = Input.Toggle("ballCam")
	if self.view and self.view.BallCamDefault == false then
		ballCam = not ballCam
	end
	if me and me.pos and self:Present() then
		local car = self.myCar
		local f, _, u = Q.toBasis(me.rot)
		local nSum = Vector3.zero
		for _, w in car.wheels do
			if w.isInContact then nSum += w.contactNormal end
		end
		Camera.Update(dt, {
			carPos = RenderMap.Dir(me.pos),
			carFwd = RenderMap.Dir(f),
			carUp = RenderMap.Dir(u),
			flipping = car.isFlipping,
			carVel = RenderMap.Dir(car.body.vel * BT),
			speedUU = car.body.vel.Magnitude * BT,
			onGround = (car.numWheelsInContact or 0) > 0,
			groundNormal = if nSum.Magnitude > 1e-3 then RenderMap.Dir(nSum.Unit) else nil,
			supersonic = car.isSupersonic,
			ballPos = if self.ballPos then RenderMap.Dir(self.ballPos) else nil,
			ballCam = ballCam,
		})
		return
	end
	-- spectator (late joiner / eliminated with no car): a high sideline view that follows the action
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local focus = self.ballPos
	if not focus then
		local sum, n = Vector3.zero, 0
		for _, e in self.visuals do
			if e.pos and not e.hidden then sum += e.pos; n += 1 end
		end
		focus = if n > 0 then sum / n else Vector3.new(0, 0, 200)
	end
	local want = RenderMap.Pos(focus :: Vector3)
	self.specFocus = if self.specFocus then self.specFocus:Lerp(want, 1 - math.exp(-4 * dt)) else want
	local eye = self.specFocus + Vector3.new(-120, 70, 0)
	cam.FieldOfView = 55
	cam.CFrame = CFrame.lookAt(eye, self.specFocus)
end

-- world-space position (studs) of a participant's car, for the view (effects, markers)
function Round.CarWorldPos(self: any, id: string): Vector3?
	local e = self.visuals[id]
	return e and e.pos and RenderMap.Pos(e.pos)
end

function Round.Destroy(self: any)
	if self.view and self.view.Destroy then
		pcall(function() self.view:Destroy() end)
	end
	if self.map then
		Camera.SetArena(nil)
		if self.restoreStadium then self.restoreStadium() end
		if self.restoreLighting then pcall(self.restoreLighting) end
	end
	Hud.Close()
	for _, e in self.visuals do
		e.visual:Destroy()
	end
	self.visuals = {}
	self.folder:Destroy()
end

-- ================================================================ events from the server
local function finishRound(reason: string?)
	local r = active
	if not r then return end
	active = nil
	r:Destroy()
	for _, fn in listeners.finish do
		task.spawn(fn, reason)
	end
end

local function onEvent(payload: any)
	if type(payload) ~= "table" or type(payload.data) ~= "table" then return end
	local kind, data = payload.kind, payload.data
	if kind == "load" then
		if active and active.sessionId == payload.sessionId then return end
		if active then finishRound("replaced") end
		local ok, r = pcall(Round.new, data, payload.sessionId, payload.roundId)
		if not ok then
			warn("[MinigameClient] could not load the round:", r)
			return
		end
		active = r
		for _, fn in listeners.start do
			task.spawn(fn, r)
		end
		if not (r.view and r.view.DeferReady) then
			r:Ready()
		end
		return
	end
	local r = active
	if not r or r.sessionId ~= payload.sessionId then return end
	r.lastTraffic = os.clock()
	if kind == "phase" then
		r.state = data.state
		r.phaseStart, r.phaseEnd = data.startTime, data.endTime
		Hud.Phase(r, data.state)
	elseif kind == "results" then
		Hud.Results(r, data)
	elseif kind == "cancel" then
		Hud.Banner("RONDA CANCELADA", string.upper(tostring(data.reason or "")), Color3.fromRGB(255, 90, 80))
	elseif kind == "end" then
		finishRound("end")
		return
	elseif kind == "left" then
		r:RemoveParticipant(data.id)
	end
	if r.view and r.view.OnEvent then
		r.view:OnEvent(kind, data)
	end
end

-- leave the current round on our side right away (the server has been told separately)
function MinigameClient.Abandon()
	finishRound("abandoned")
end

function MinigameClient.Init()
	if remotes then return end
	remotes = {
		MgEvent = Net.Remote("MgEvent"),
		MgInput = Net.Remote("MgInput"),
		MgReady = Net.Remote("MgReady"),
		MgSnapshot = Net.Remote("MgSnapshot"),
		MgLocalState = Net.Remote("MgLocalState"),
	}
	remotes.MgEvent.OnClientEvent:Connect(onEvent)
	remotes.MgSnapshot.OnClientEvent:Connect(function(b)
		if active then active:OnSnapshot(b) end
	end)
	remotes.MgLocalState.OnClientEvent:Connect(function(b)
		if active then active:OnLocalState(b) end
	end)
	RunService:BindToRenderStep("PartyMinigame", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local r = active
		if not r then return end
		local ok, err = pcall(r.Frame, r, dt)
		if not ok then
			warn("[MinigameClient] frame error:", err)
		end
		-- the server went quiet in a live round (crash, lost connection): don't leave the player stuck
		local silent = os.clock() - r.lastTraffic
		if r == active and ((r:Live() and silent > SILENCE_TIMEOUT) or silent > SILENCE_TIMEOUT * 2.5) then
			finishRound("timeout")
		end
	end)
end

return MinigameClient
