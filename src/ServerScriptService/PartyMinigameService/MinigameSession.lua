--!strict
-- MinigameSession.lua: one round of one minigame for one party. Owns the authoritative World (120 Hz), the cars,
-- the inputs, the bots, the phase machine and the network traffic of the round.
--
-- LOADING   world + cars built, clients told to load; waits for every human's MgReady (or a hard cap)
-- COUNTDOWN 3-2-1; simulation runs with controls locked so cars settle
-- ACTIVE    the minigame runs (Update each tick) until IsFinished() or MaxDuration
-- ENDING    gameplay frozen (no more steps), final snapshot
-- RESULTS   placements -> Party Points (PartyServer), shown to everyone
-- CLEANUP   minigame + session cleanup, physics overrides restored, clients return to the party lobby
-- A session can be cancelled from any phase (everyone left, error, server shutting down): it jumps to CLEANUP.
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Phys = RS:WaitForChild("Physics")
local World = require(Phys.World)
local CarPhysics = require(Phys.CarPhysics)
local Net = require(RS:WaitForChild("Party"):WaitForChild("Net"))

local State = require(script.Parent.MinigameState)
local Timer = require(script.Parent.MinigameTimer)
local Cleanup = require(script.Parent.MinigameCleanup)
local SpawnManager = require(script.Parent.MinigameSpawnManager)
local BotBase = require(script.Parent.MinigameBotController)
local Cosmetics = require(game:GetService("ServerScriptService"):WaitForChild("Economy"):WaitForChild("CosmeticsService"))

local MinigameSession = {}
MinigameSession.__index = MinigameSession

local TICK = Net.TICK
local MAX_TICKS_PER_FRAME = 10
local MAX_QUEUE = 12

function MinigameSession.new(service: any, party: any, def: any, members: { any }, roundId: number)
	local self = setmetatable({}, MinigameSession)
	self.service = service
	self.party = party
	self.def = def
	self.id = HttpService:GenerateGUID(false)
	self.roundId = roundId
	self.state = State.LOADING
	self.timer = Timer.new()
	self.cleanup = Cleanup.new()
	self.members = {}
	self.byId = {}
	for _, m in members do
		local copy = table.clone(m)
		table.insert(self.members, copy)
		self.byId[copy.id] = copy
	end
	self.inputs = {}
	self.bots = {}
	self.ready = {}
	self.acc = 0
	self.tick = 0
	self.remotes = service.remotes
	-- world options come from the minigame's shared module (the client builds the same world for prediction)
	local shared = require(RS.Party.MinigameShared:WaitForChild(def.SharedModule))
	self.shared = shared
	self.world = World.new(shared.WorldOptions())
	self.world.demoMode = shared.DemoMode or "disabled"
	if shared.SetupWorld then shared.SetupWorld(self.world) end -- per-world physics rules (also run on clients)
	self.spawns = SpawnManager.new(self.world)
	self.minigame = def.new(self)
	return self
end

-- ---------------------------------------------------------------- membership helpers
function MinigameSession.Humans(self: any): { any }
	local out = {}
	for _, m in self.members do
		if m.kind == "player" and m.player and m.player.Parent then
			table.insert(out, m)
		end
	end
	return out
end

function MinigameSession.MembersOnTeam(self: any, team: number): { any }
	local out = {}
	for _, m in self.members do
		if m.team == team then table.insert(out, m) end
	end
	return out
end

function MinigameSession.CarOf(self: any, memberId: string): any
	return self.spawns:Get(memberId)
end

function MinigameSession.MemberOfCar(self: any, car: any): any
	for _, m in self.members do
		if self.spawns:Get(m.id) == car then return m end
	end
	return nil
end

-- everyone in the party with a client (players + late joiners spectating)
function MinigameSession.Audience(self: any): { Player }
	local out = {}
	for _, m in self.party.members do
		if m.kind == "player" and m.player and m.player.Parent then
			table.insert(out, m.player)
		end
	end
	return out
end

function MinigameSession.Broadcast(self: any, kind: string, data: any?)
	local payload = { sessionId = self.id, roundId = self.roundId, kind = kind, data = data or {} }
	for _, p in MinigameSession.Audience(self) do
		self.remotes.MgEvent:FireClient(p, payload)
	end
end

function MinigameSession.SendTo(self: any, player: Player, kind: string, data: any?)
	self.remotes.MgEvent:FireClient(player, { sessionId = self.id, roundId = self.roundId, kind = kind, data = data or {} })
end

-- ---------------------------------------------------------------- lifecycle
function MinigameSession.LoadPayload(self: any): any
	local participants = {}
	for _, m in self.members do
		local car = self.spawns:Get(m.id)
		-- cosmetics come from the player's saved loadout (never from the client); bots wear the defaults
		local look = if m.kind == "player" and m.player then Cosmetics.LoadoutFor(m.player) else nil
		table.insert(participants, {
			id = m.id, name = m.name, team = m.team, isBot = m.kind == "bot", userId = m.userId,
			netId = car and car.netId, hitbox = m.hitbox or "Octane",
			skin = if look then Cosmetics.SkinOf(look) else m.skin or "Octane", cosmetics = look,
		})
	end
	return {
		minigameId = self.def.Id, displayName = self.def.DisplayName, description = self.def.Description,
		sharedModule = self.def.SharedModule, participants = participants, maxDuration = self.def.MaxDuration,
		state = self.state, startTime = self.timer.startTime, endTime = self.timer.endTime,
		public = self.minigame:PublicState(),
	}
end

function MinigameSession.Begin(self: any)
	local teams = self.minigame:AssignTeams(self.members)
	for _, m in self.members do
		m.team = teams[m.id] or 0
	end
	self.minigame:Setup()
	for _, m in self.members do
		self.inputs[m.id] = { queue = {}, last = CarPhysics.EmptyControls(), lastSeq = 0, maxSeq = 0, lastRecv = os.clock() }
		if m.kind == "bot" then
			local car = self.spawns:Get(m.id)
			local Ctl = self.def.BotController or BotBase
			self.bots[m.id] = Ctl.new(self, m, car, self.minigame)
		end
	end
	self.timer:Begin(State.LOADING, self.def.LoadingTime or State.DURATION.LOADING)
	self:Broadcast("load", self:LoadPayload())
end

function MinigameSession.SetState(self: any, to: string)
	if not State.CanTransition(self.state, to) then
		return
	end
	self.state = to
	-- a minigame may set its own phase lengths (e.g. the online match has its own kickoff countdown)
	local duration = if to == State.ACTIVE then self.def.MaxDuration else (self.def.PhaseTimes and self.def.PhaseTimes[to]) or State.DURATION[to]
	self.timer:Begin(to, duration)
	self:Broadcast("phase", { state = to, startTime = self.timer.startTime, endTime = self.timer.endTime })
	if to == State.ACTIVE then
		self.activeAt = os.clock()
		self.minigame:Start()
	elseif to == State.ENDING then
		self.activeFor = os.clock() - (self.activeAt or os.clock())
		self.minigame:End()
		self:SendSnapshots()
	elseif to == State.RESULTS then
		local placements = self.minigame:GetPlacements()
		-- Party Points only in party rounds (an online match has its own reward: the profile)
		local awarded = if self.def.NoPartyPoints then {} else self.service.party:AwardPartyPoints(self.party, placements)
		if not self.def.NoPartyPoints then
			self:SubmitRound(placements)
		end
		local rows = {}
		for _, p in placements do
			local m = self.byId[p.id]
			table.insert(rows, {
				id = p.id, name = m and m.name or "?", team = m and m.team, userId = m and m.userId,
				placement = p.placement, score = p.score, stats = p.stats, partyPoints = awarded[p.id] or 0,
				totalPoints = (self.party.points or {})[p.id] or 0,
			})
		end
		table.sort(rows, function(a, b) return a.placement < b.placement end)
		self:Broadcast("results", { rows = rows, summary = self.minigame.resultSummary })
		if self.minigame.OnResults then
			pcall(function() self.minigame:OnResults() end)
		end
	elseif to == State.CLEANUP then
		self:Finish()
	end
end

-- party round finished: each human still in the round gets their placement written to their profile (XP, credits,
-- challenges - decided by ProfileService). Leavers are no longer members, and a cancelled round never gets here.
function MinigameSession.SubmitRound(self: any, placements: { any })
	local submit = self.service.submitMatch
	if not submit then return end
	local humans = self:Humans()
	for _, pl in placements do
		local m = self.byId[pl.id]
		if m and m.kind == "player" and m.player and m.player.Parent then
			submit(m.player, {
				kind = "minigame", minigameId = self.def.Id, placement = pl.placement,
				humans = #humans, activeSeconds = self.activeFor or 0,
			})
		end
	end
end

-- cancel from any phase (no results): everyone left, an error, server shutdown
function MinigameSession.Cancel(self: any, reason: string)
	if self.state == State.CLEANUP or self.state == State.DONE then return end
	self:Broadcast("cancel", { reason = reason })
	self:SetState(State.CLEANUP)
end

function MinigameSession.Finish(self: any)
	pcall(function() self.minigame:Cleanup() end)
	self.cleanup:Clean()
	for id in self.bots do self.bots[id] = nil end
	self.world.cars = {}
	self.state = State.DONE
	self:Broadcast("end", {})
	self.service:OnSessionDone(self)
end

-- ---------------------------------------------------------------- inputs (from MgInput, already decoded)
function MinigameSession.PushInputs(self: any, memberId: string, list: { any })
	local inp = self.inputs[memberId]
	if not inp then return end
	inp.lastRecv = os.clock()
	for _, e in list do
		if e.seq > inp.maxSeq then
			inp.maxSeq = e.seq
			table.insert(inp.queue, e)
		end
	end
	while #inp.queue > MAX_QUEUE do
		table.remove(inp.queue, 1)
	end
end

local STALE_INPUT = 1.0 -- s without packets (lag spike, frozen or AFK client): stop repeating the last input

local function popControls(inp: any): any
	if #inp.queue > 0 then
		local e = table.remove(inp.queue, 1)
		inp.last = e.controls
		inp.lastSeq = e.seq
	elseif os.clock() - inp.lastRecv > STALE_INPUT then
		inp.last = CarPhysics.EmptyControls() -- never keep a silent client's throttle held down
	end
	return inp.last
end

-- ---------------------------------------------------------------- simulation
function MinigameSession.Simulate(self: any, dt: number)
	self.acc += dt
	local n = 0
	while self.acc >= TICK and n < MAX_TICKS_PER_FRAME do
		self.acc -= TICK
		n += 1
		self:StepTick()
	end
	if self.acc > TICK * MAX_TICKS_PER_FRAME then
		self.acc = 0 -- server hitch: drop the backlog instead of spiralling
	end
end

function MinigameSession.StepTick(self: any)
	local active = self.state == State.ACTIVE
	local locked = (not active) or self.minigame:ControlsLocked()
	for _, m in self.members do
		local car = self.spawns:Get(m.id)
		if car then
			local controls
			if m.kind == "bot" then
				local bot = self.bots[m.id]
				controls = if bot and not locked and not car.netHidden then bot:Unstick(bot:Think(TICK), TICK) else CarPhysics.EmptyControls()
			else
				local inp = self.inputs[m.id]
				controls = if inp then popControls(inp) else CarPhysics.EmptyControls() -- consumed even when locked (keeps acks moving)
				if locked or car.netHidden then controls = CarPhysics.EmptyControls() end
			end
			car.controls = controls
		end
	end
	self.minigame:PreTick(TICK)
	self.world:Step()
	if active then
		self.minigame:Update(TICK)
	end
	self.tick += 1
	if self.tick % Net.SNAPSHOT_EVERY == 0 then
		self:SendSnapshots()
	end
end

function MinigameSession.SendSnapshots(self: any)
	local cars = {}
	for _, m in self.members do
		local car = self.spawns:Get(m.id)
		if car then table.insert(cars, car) end
	end
	local snap = Net.EncodeSnapshot(self.tick, Timer.Now(), cars, self.world.ball, self.minigame:BallVisible(), self.world.pads)
	for _, p in self:Audience() do
		self.remotes.MgSnapshot:FireClient(p, snap)
	end
	for _, m in self:Humans() do
		local car = self.spawns:Get(m.id)
		local inp = self.inputs[m.id]
		if car and inp then
			-- own-ball minigames (minigolf) send each player THEIR ball; everyone else the world's ball
			local ball, enabled = self.world.ball, self.world.ballEnabled
			if self.minigame.BallFor then
				local b, e = self.minigame:BallFor(m)
				if b then ball, enabled = b, e end
			end
			self.remotes.MgLocalState:FireClient(m.player, Net.EncodeLocalState(inp.lastSeq, self.tick, car, ball, enabled))
		end
	end
end

-- called every Heartbeat by the service
function MinigameSession.Step(self: any, dt: number)
	local st = self.state
	if st == State.LOADING then
		local allReady = true
		for _, m in self:Humans() do
			if not self.ready[m.userId] then allReady = false end
		end
		if allReady or self.timer:Expired() then
			self:SetState(State.COUNTDOWN)
		end
	elseif st == State.COUNTDOWN then
		self:Simulate(dt)
		if self.timer:Expired() then
			self:SetState(State.ACTIVE)
		end
	elseif st == State.ACTIVE then
		self:Simulate(dt)
		if self.minigame:IsFinished() or self.timer:Expired() then
			self:SetState(State.ENDING)
		end
	elseif st == State.ENDING then
		if self.timer:Expired() then
			self:SetState(State.RESULTS)
		end
	elseif st == State.RESULTS then
		if self.timer:Expired() then
			self:SetState(State.CLEANUP)
		end
	end
end

-- ---------------------------------------------------------------- membership changes mid-round
function MinigameSession.MarkReady(self: any, player: Player)
	self.ready[player.UserId] = true
end

function MinigameSession.HandleLeave(self: any, memberId: string)
	local m = self.byId[memberId]
	if not m then return end
	pcall(function() self.minigame:HandlePlayerLeave(m) end)
	local car = self.spawns:Get(memberId)
	if self.def.ReplaceLeaversWithBots and car and m.kind == "player" then
		-- the car stays in the match, driven by a bot from now on (RL does the same)
		m.kind = "bot"
		m.player = nil
		m.name = m.name .. " (BOT)"
		local Ctl = self.def.BotController or BotBase
		self.bots[memberId] = Ctl.new(self, m, car, self.minigame)
		self.inputs[memberId] = nil
		self:Broadcast("left", { id = memberId, replacedByBot = true, name = m.name })
		if #self:Humans() == 0 then
			self:Cancel("no players")
		end
		return
	end
	self.spawns:Remove(memberId)
	self.inputs[memberId] = nil
	self.bots[memberId] = nil
	local i = table.find(self.members, m)
	if i then table.remove(self.members, i) end
	self.byId[memberId] = nil
	self:Broadcast("left", { id = memberId })
	if #self:Humans() == 0 then
		self:Cancel("no players")
	end
end

-- a party member who joined while the round runs watches it (no car) and plays the next one
function MinigameSession.HandleLateJoin(self: any, member: any)
	pcall(function() self.minigame:HandlePlayerJoin(member) end)
	if member.player then
		self:SendTo(member.player, "load", self:LoadPayload())
	end
end

return MinigameSession
