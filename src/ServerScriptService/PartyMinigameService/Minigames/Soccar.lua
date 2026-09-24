--!strict
-- Soccar.lua (server): an online Rocket League match (1v1 / 2v2), run by the server like every Party minigame.
-- The rules are the offline match's (GameClient), moved server-side:
--   * kickoff: RocketSim kickoff positions, 3 s countdown with controls locked
--   * goal: score, the goal explosion throws nearby cars, 3 s pause (cars keep driving), next kickoff
--   * 5:00 clock that only runs while the ball is in play; at 0:00 play goes on until the ball touches the ground;
--     a tie goes to golden-goal overtime (capped)
--   * demolitions and boost pads on (RocketSim)
--   * a player who leaves is replaced by a bot so the match stays fair for the others
-- Scoring stats come from the same MatchEvents module the offline HUD uses, one per human (their toasts, pinches and
-- points go only to them); the server writes the result to each player's profile itself (nothing is trusted from
-- clients).
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local BallPrediction = require(Phys.BallPrediction)
local MatchEvents = require(RS.Game.MatchEvents)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SoccarShared"))

local Base = script.Parent.Parent
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU

local Soccar = {}
Soccar.__index = Soccar

Soccar.Id = Shared.Id
Soccar.DisplayName = "PARTIDO"
Soccar.Description = "Rocket League de verdad, en línea. Mete más goles que el rival en 5 minutos."
Soccar.MinPlayers = 2
Soccar.MaxPlayers = 4
Soccar.MaxDuration = Shared.MAX_TIME
Soccar.SharedModule = "SoccarShared"
Soccar.BotController = require(script.Parent.SoccarBotController)
Soccar.NoPartyPoints = true
Soccar.LoadingTime = 10 -- the pre-match intro plays while loading
Soccar.ReplaceLeaversWithBots = true
Soccar.PhaseTimes = { COUNTDOWN = 0.3, RESULTS = 8 } -- the kickoff has its own 3-2-1; time to read the result

function Soccar.new(session: any)
	local self = setmetatable({}, Soccar)
	self.session = session
	self.world = session.world
	self.cleanup = Cleanup.new()
	local cfg = session.party.config or {}
	self.mode = cfg.mode or "1v1"
	self.ranked = cfg.ranked == true
	self.difficulty = cfg.difficulty or "pro"
	self.phase = "idle" -- idle | kickoff | play | goal
	self.phaseT = 0
	self.timeLeft = Shared.MATCH_LENGTH
	self.overtime = false
	self.otTime = 0
	self.score = { [0] = 0, [1] = 0 }
	self.lastScorer = -1
	self.events = {} -- member id -> MatchEvents (humans)
	self.board = nil -- MatchEvents that keeps the scoreboard for everyone
	self.prediction = BallPrediction.new(360) -- shared by the bots
	self.predTick = -1
	self.simTime = 0
	self.lastBoard = 0
	self.lastClock = 0
	self.finished = false
	self.winnerTeam = nil :: number?
	self.resultSummary = nil
	return self
end

-- teams come from the matchmaker (members arrive with .team)
function Soccar.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do
		out[m.id] = m.team or ((i - 1) % 2)
	end
	return out
end

function Soccar.Setup(self: any)
	for _, m in self.session.members do
		local car = self.session.spawns:Spawn(m, m.team, Vector3.new(0, 0, 17), 0)
		car.boost = C.BOOST_SPAWN_AMOUNT
	end
	self.world:ResetToKickoff()
	self.world.manifolds = {}
	self.world.ballEnabled = false
	self.board = MatchEvents.new(self.world, { team = -1 }) -- nobody's HUD: it only keeps everyone's scoreboard
	for _, m in self.session.members do
		if m.kind == "player" then
			self.events[m.id] = MatchEvents.new(self.world, self.session:CarOf(m.id))
		end
	end
end

function Soccar.Start(self: any)
	self:Kickoff()
end

function Soccar.Kickoff(self: any)
	self.world:ResetToKickoff()
	self.world.manifolds = {}
	self.world.ballEnabled = true
	self.phase = "kickoff"
	self.phaseT = 0
	for _, me in self.events do me:Reset() end
	self.board:Reset()
	for _, bot in self.session.bots do
		if bot.ResetForKickoff then bot:ResetForKickoff() end
	end
	self.session:Broadcast("kickoff", { endTime = workspace:GetServerTimeNow() + Shared.KICKOFF_COUNTDOWN })
	self:PushClock()
end

-- the clock only runs in play; clients count from this anchor
function Soccar.PushClock(self: any)
	self.lastClock = self.simTime
	self.session:Broadcast("clock", {
		timeLeft = self.timeLeft, overtime = self.overtime, otTime = self.otTime,
		running = self.phase == "play", at = workspace:GetServerTimeNow(),
	})
end

function Soccar.PublicState(self: any): any
	return {
		mode = self.mode, ranked = self.ranked, scoreA = self.score[0], scoreB = self.score[1],
		timeLeft = self.timeLeft, overtime = self.overtime, phase = self.phase,
	}
end

function Soccar.PreTick(self: any, dt: number) end

-- MatchEvents' HUD events reference cars; clients get names / member ids instead
function Soccar.Serialize(self: any, ev: any): any
	local out = table.clone(ev)
	for _, k in { "scorer", "assist", "ownGoalBy" } do
		if ev[k] then
			local m = self.session:MemberOfCar(ev[k])
			out[k] = nil
			out[k .. "Name"] = m and m.name
			out[k .. "Id"] = m and m.id
		end
	end
	return out
end

function Soccar.Explode(self: any, gp: Vector3)
	-- the goal explosion throws nearby cars away (RL): strongest at the ball, fading out by EXPLOSION_RADIUS
	local rng = Random.new()
	for _, car in self.world.cars do
		if not car.isDemoed then
			local d = (car.body.pos - gp) * BT
			local dist = d.Magnitude
			if dist < Shared.EXPLOSION_RADIUS then
				local k = (1 - dist / Shared.EXPLOSION_RADIUS) ^ 0.8
				local flat = Vector3.new(d.X, d.Y, 0)
				local dir = ((if flat.Magnitude > 1 then flat.Unit else Vector3.new(0, -math.sign(gp.Y), 0)) + Vector3.new(0, 0, 0.75)).Unit
				car.body.vel += dir * (Shared.EXPLOSION_SPEED * k) / BT
				car.body.angVel += Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * (7 * k)
			end
		end
	end
end

function Soccar.Update(self: any, dt: number)
	if self.finished then return end
	self.simTime += dt
	self.phaseT += dt
	local world = self.world
	local session = self.session

	-- stats / HUD feedback (same bookkeeping as the offline match)
	self.board:Tick({}, false)
	for id, me in self.events do
		local out = {}
		me:Tick(out, false)
		if #out > 0 then
			local m = session.byId[id]
			if m and m.player then
				local list = {}
				for _, ev in out do table.insert(list, self:Serialize(ev)) end
				session:SendTo(m.player, "hud", { events = list })
			end
		end
	end

	local grounded = world.ballEnabled and world.ball.body.pos.Z * BT <= C.BALL_REST_Z + 4
	for _, e in world.events do
		if e.type == "goal" and self.phase == "play" then
			self.score[e.team] += 1
			self.lastScorer = e.team
			local gp = world.ball.body.pos
			self:Explode(gp)
			self.phase = "goal"
			self.phaseT = 0
			world.ballEnabled = false
			session:Broadcast("goal", {
				team = e.team, scoreA = self.score[0], scoreB = self.score[1], pos = gp * BT,
				kmh = math.floor(world.ball.body.vel.Magnitude * BT * MatchEvents.KMH + 0.5),
			})
			self:PushClock()
		elseif e.type == "demo" then
			local v, b = session:MemberOfCar(e.victim), session:MemberOfCar(e.bumper)
			session:Broadcast("demo", { victim = v and v.id, bumper = b and b.id, pos = e.victim.body.pos * BT })
		elseif e.type == "pad" then
			local m = session:MemberOfCar(e.car)
			session:Broadcast("pad", { index = e.pad.index, id = m and m.id })
		end
	end

	if self.phase == "kickoff" then
		if self.phaseT >= Shared.KICKOFF_COUNTDOWN then
			self.phase = "play"
			self.phaseT = 0
			self:PushClock()
		end
	elseif self.phase == "play" then
		if self.overtime then
			self.otTime += dt
			if self.otTime >= Shared.OVERTIME_CAP then
				self:Finish("tiempo máximo")
				return
			end
		else
			self.timeLeft = math.max(0, self.timeLeft - dt)
			-- RL: at 0:00 play continues until the ball touches the ground
			if self.timeLeft <= 0 and grounded then
				if self.score[0] == self.score[1] then
					self.overtime = true
					session:Broadcast("overtime", {})
					self:Kickoff()
				else
					self:Finish("tiempo")
				end
				return
			end
		end
	elseif self.phase == "goal" then
		if self.phaseT >= Shared.GOAL_PAUSE then
			if self.overtime or self.timeLeft <= 0 then
				self:Finish(if self.overtime then "gol de oro" else "tiempo")
			else
				self:Kickoff()
			end
			return
		end
	end

	-- the scoreboard (CAPS LOCK) once a second, a clock re-sync every 5 s
	if self.simTime - self.lastBoard >= 1 then
		self.lastBoard = self.simTime
		local rows = {}
		for _, m in session.members do
			local car = session:CarOf(m.id)
			rows[m.id] = car and table.clone(self.board:Board(car)) or nil
		end
		session:Broadcast("board", { rows = rows, scoreA = self.score[0], scoreB = self.score[1] })
	end
	if self.simTime - self.lastClock >= 5 then
		self:PushClock()
	end
end

function Soccar.Finish(self: any, why: string)
	if self.finished then return end
	self.finished = true
	local a, b = self.score[0], self.score[1]
	self.winnerTeam = if a > b then 0 elseif b > a then 1 else nil
	self.resultSummary = {
		title = if self.winnerTeam == 0 then "GANA AZUL" elseif self.winnerTeam == 1 then "GANA NARANJA" else "EMPATE",
		detail = ("AZUL %d  —  %d NARANJA  ·  %s"):format(a, b, why),
		scoreA = a, scoreB = b, winnerTeam = self.winnerTeam,
	}
end

function Soccar.ControlsLocked(self: any): boolean
	return self.phase == "kickoff" or self.finished
end

function Soccar.BallVisible(self: any): boolean
	return self.world.ballEnabled
end

function Soccar.HandlePlayerJoin(self: any, member: any) end
function Soccar.HandlePlayerEliminated(self: any, member: any) end

-- the session turns the leaver's car over to a bot; their stats stop here
function Soccar.HandlePlayerLeave(self: any, member: any)
	self.events[member.id] = nil
end

function Soccar.End(self: any)
	if not self.finished then self:Finish("tiempo máximo") end
end

function Soccar.GetScore(self: any, member: any): number
	local car = self.session:CarOf(member.id)
	return if car then self.board:Board(car).points else 0
end

function Soccar.IsFinished(self: any): boolean
	return self.finished
end

function Soccar.GetPlacements(self: any): { any }
	local out = {}
	for _, m in self.session.members do
		local placement = if self.winnerTeam == nil then 1 elseif m.team == self.winnerTeam then 1 else 2
		local car = self.session:CarOf(m.id)
		table.insert(out, { id = m.id, placement = placement, score = if car then self.board:Board(car).points else 0, stats = if car then table.clone(self.board:Board(car)) else {} })
	end
	return out
end

-- after the final whistle: every human's result goes to their profile, decided here
function Soccar.OnResults(self: any)
	local submit = self.session.service.submitMatch
	if not submit then return end
	-- humans still in the match per team (leavers were handed to bots): the profile rewards playing people
	local humans = { [0] = 0, [1] = 0 }
	for _, m in self.session.members do
		if m.kind == "player" and m.player then humans[m.team or 0] = (humans[m.team or 0] or 0) + 1 end
	end
	for id, me in self.events do
		local m = self.session.byId[id]
		if m and m.player and m.player.Parent then
			local result = if self.winnerTeam == nil then "draw" elseif m.team == self.winnerTeam then "win" else "loss"
			local st = me.stats
			local team = m.team or 0
			submit(m.player, {
				result = result, points = me.points, mode = self.mode, ranked = self.ranked, online = true,
				humanOpponents = humans[1 - team] or 0, activeSeconds = self.simTime,
				scoreFor = self.score[team], scoreAgainst = self.score[1 - team],
				goals = st.goals, assists = st.assists, saves = st.saves, epicSaves = st.epicSaves, shots = st.shots,
				clears = st.clears, demos = st.demos, aerials = st.aerials, bestKmh = st.bestKmh,
				pinches = st.pinches, bestPinchKmh = st.bestPinchKmh,
			})
		end
	end
end

function Soccar.Cleanup(self: any)
	self.cleanup:Clean()
end

return Soccar
