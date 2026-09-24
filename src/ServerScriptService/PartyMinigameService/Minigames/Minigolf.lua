--!strict
-- Minigolf.lua (server): Giant Minigolf. Three of the map's six holes per round, everyone on the same hole at once.
--   * every player has their own ball (world:AddBall(car)): only their car touches it; cars pass through each other
--   * a stroke = a new touch after STROKE_GAP without contact, or every PUSH_STROKE seconds of pushing it along
--   * the ball in the cup (slow enough) = holed; out of bounds (fallen off / over a wall) = back to its last resting
--     spot and +1 stroke; a car that falls off is put back behind its ball
--   * a hole ends when everyone has holed out (short pause) or on its timer; an unfinished hole scores
--     strokes + UNSUNK_PENALTY (at least par + UNSUNK_PENALTY)
--   * ranking: fewest total strokes, then holes finished, then time taken
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local BallPhysics = require(Phys.BallPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("MinigolfShared"))

local Base = script.Parent.Parent
local Score = require(Base.MinigameScore)
local Cleanup = require(Base.MinigameCleanup)

local BT = C.BT_TO_UU
local BALL_R = 91.25
local PARK = Vector3.new(0, 0, -30000)

local Minigolf = {}
Minigolf.__index = Minigolf

Minigolf.Id = Shared.Id
Minigolf.DisplayName = "MINIGOLF GIGANTE"
Minigolf.Description = "Cada uno con su balón: llévalo al hoyo con los menos toques posibles. Tres hoyos gigantes."
Minigolf.MinPlayers = 2
Minigolf.MaxPlayers = 4
Minigolf.MaxDuration = Shared.MAX_TIME
Minigolf.SharedModule = "MinigolfShared"
Minigolf.BotController = require(script.Parent.MinigolfBotController)

function Minigolf.new(session: any)
	local self = setmetatable({}, Minigolf)
	self.session = session
	self.world = session.world
	self.score = Score.new()
	self.cleanup = Cleanup.new()
	self.rng = Random.new()
	self.elapsed = 0
	self.order = {} -- the round's hole indices
	self.index = 0 -- position in self.order
	self.hole = 0 -- current hole (index into Shared.HOLES)
	self.phase = "between" -- "play" | "between"
	self.phaseT = 0
	self.balls = {} -- member id -> { ball, slot (extraBalls entry), lane }
	self.p = {} -- member id -> per-player state
	self.total = {} -- member id -> strokes over the round
	self.cards = {} -- member id -> { strokes per hole }
	self.holedAll = nil :: number?
	self.lastBalls = 0
	self.finished = false
	self.resultSummary = nil
	return self
end

function Minigolf.AssignTeams(self: any, members: { any }): { [string]: number }
	local out = {}
	for i, m in members do out[m.id] = i - 1 end
	return out
end

function Minigolf.Setup(self: any)
	-- three holes, played in map order
	local pool = {}
	for k = 1, #Shared.HOLES do pool[k] = k end
	for i = #pool, 2, -1 do
		local j = self.rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	for i = 1, Shared.HOLES_PER_ROUND do self.order[i] = pool[i] end
	table.sort(self.order)
	self.world.ballEnabled = false
	BallPhysics.SetState(self.world.ball, PARK, Vector3.zero, Vector3.zero)
	for i, m in self.session.members do
		local ballPos, carPos = Shared.Tee(self.order[1], i)
		local car = self.session.spawns:Spawn(m, (i - 1) % 2, carPos, math.pi / 2)
		car.boost = 100
		local ball = self.world:AddBall(car)
		self.balls[m.id] = { ball = ball, slot = self.world.extraBalls[#self.world.extraBalls], lane = i }
		self.total[m.id] = 0
		self.cards[m.id] = {}
	end
	self:BeginHole(1)
end

-- the countdown is over: tee off on the first hole
function Minigolf.Start(self: any)
	self:Play()
end

-- move everyone to hole `idx` (balls on the tee, cars behind them); play starts after the pause (Play)
function Minigolf.BeginHole(self: any, idx: number)
	self.index = idx
	self.hole = self.order[idx]
	self.phase = "between"
	self.phaseT = 0
	self.holedAll = nil
	self.world.golfCup = Shared.Cup(self.hole)
	for _, m in self.session.members do
		local b = self.balls[m.id]
		local ballPos, carPos = Shared.Tee(self.hole, b.lane)
		BallPhysics.SetState(b.ball, ballPos, Vector3.zero, Vector3.zero)
		b.slot.enabled = false
		local car = self.session:CarOf(m.id)
		if car then self.session.spawns:Place(car, carPos, math.pi / 2, 100) end
		self.p[m.id] = { strokes = 0, holed = false, lastTouch = -10, pushFrom = nil, safe = ballPos, safeT = 0, holedAt = nil }
	end
	self.session:Broadcast("hole", self:HolePayload())
end

function Minigolf.Play(self: any)
	self.phase = "play"
	self.phaseT = 0
	self.playStart = self.elapsed
	for _, b in self.balls do b.slot.enabled = true end
	self.session:Broadcast("hole", self:HolePayload())
end

function Minigolf.HolePayload(self: any): any
	local h = Shared.HOLES[self.hole]
	local t0 = self.session.timer and self.session.timer.startTime
	return {
		index = self.index, count = #self.order, hole = self.hole, name = h.name, par = h.par,
		cup = Shared.Cup(self.hole), playing = self.phase == "play",
		endTime = if t0 and self.phase == "play" then t0 + self.elapsed - self.phaseT + Shared.HOLE_TIME else nil,
		strokes = self:StrokeTable(), total = self.total,
	}
end

function Minigolf.StrokeTable(self: any): { [string]: number }
	local out = {}
	for id, st in self.p do out[id] = st.strokes end
	return out
end

function Minigolf.PublicState(self: any): any
	local pub = { order = self.order, total = self.total }
	if self.hole > 0 then
		pub.hole = self:HolePayload()
		pub.holed = {}
		for id, st in self.p do if st.holed then table.insert(pub.holed, id) end end
	end
	return pub
end

-- own-ball minigame: each player's local state carries THEIR ball
function Minigolf.BallFor(self: any, member: any): (any, boolean)
	local b = self.balls[member.id]
	if not b then return nil, false end
	return b.ball, b.slot.enabled ~= false
end

function Minigolf.PreTick(self: any, dt: number)
	for _, car in self.world.cars do Shared.PreTick(car, dt) end
end

function Minigolf.ControlsLocked(self: any): boolean
	return self.finished or self.phase ~= "play"
end

function Minigolf.BallVisible(self: any): boolean
	return true -- (each client draws its own ball; the world's shared ball is parked out of sight)
end

function Minigolf.AddStroke(self: any, id: string, why: string?)
	local st = self.p[id]
	st.strokes += 1
	self.score:Stat(id, "strokes", 1)
	self.session:Broadcast("stroke", { id = id, strokes = st.strokes, why = why })
	-- stroke limit: at par + MAX_OVER_PAR the hole closes for this player (their ball is picked up)
	local cap = Shared.HOLES[self.hole].par + Shared.MAX_OVER_PAR
	if not st.holed and st.strokes >= cap then
		st.holed, st.capped, st.holedAt = true, true, self.phaseT
		local b = self.balls[id]
		b.slot.enabled = false
		BallPhysics.SetState(b.ball, Vector3.new(0, 0, -30000), Vector3.zero, Vector3.zero)
		self.session:Broadcast("capped", { id = id, strokes = st.strokes })
	end
end

-- what a hole scores for a player: their strokes, or (not finished) strokes + penalty, never above the cap
function Minigolf.HoleScore(self: any, st: any, par: number): number
	local cap = par + Shared.MAX_OVER_PAR
	if st.holed and not st.capped then return st.strokes end
	if st.capped then return cap end
	return math.min(cap, math.max(st.strokes + Shared.UNSUNK_PENALTY, par + Shared.UNSUNK_PENALTY))
end

function Minigolf.Update(self: any, dt: number)
	if self.finished then return end
	self.elapsed += dt
	self.phaseT += dt
	local w = self.world
	if self.phase == "between" then
		if self.phaseT >= Shared.BETWEEN then
			self:Play()
		end
		return
	end
	Shared.PostStep(w, true)
	local t = self.phaseT
	-- strokes: touches of each player's own ball
	for _, e in w.events do
		if e.type == "hit" and e.ball then
			local m = self.session:MemberOfCar(e.car)
			local st = m and self.p[m.id]
			if st and not st.holed and self.balls[m.id].ball == e.ball then
				if t - st.lastTouch > Shared.STROKE_GAP then
					self:AddStroke(m.id)
					st.pushFrom = t
				elseif st.pushFrom and t - st.pushFrom >= Shared.PUSH_STROKE then
					self:AddStroke(m.id, "push")
					st.pushFrom = t
				end
				st.lastTouch = t
			end
		end
	end
	local cup = Shared.Cup(self.hole)
	local arena = Shared.Map():Arena()
	for _, m in self.session.members do
		local st = self.p[m.id]
		local b = self.balls[m.id]
		if st.holed then continue end
		local body = b.ball.body
		local p = body.pos * BT
		local v = body.vel * BT
		-- in the cup?
		local flat = Vector3.new(p.X - cup.X, p.Y - cup.Y, 0).Magnitude
		if flat < Shared.CUP_R and math.abs(p.Z - (cup.Z + BALL_R)) < 70 and Vector3.new(v.X, v.Y, 0).Magnitude < Shared.SINK_SPEED then
			st.holed = true
			st.holedAt = t
			b.slot.enabled = false
			BallPhysics.SetState(b.ball, cup + Vector3.new(0, 0, BALL_R - 70), Vector3.zero, Vector3.zero)
			local par = Shared.HOLES[self.hole].par
			self.session:Broadcast("holed", { id = m.id, strokes = st.strokes, par = par, pos = cup })
			continue
		end
		-- out of bounds: back to the last resting spot, +1
		if Shared.OutOfBounds(self.hole, p) then
			BallPhysics.SetState(b.ball, st.safe, Vector3.zero, Vector3.zero)
			self:AddStroke(m.id, "oob")
			self.session:Broadcast("oob", { id = m.id, pos = st.safe })
		elseif v.Magnitude < 250 and t - st.safeT > 0.25 then
			-- remember where it rests (on something solid)
			local d = arena.Query(p)
			if d and d < BALL_R + 30 then
				st.safe = p + Vector3.new(0, 0, 4)
				st.safeT = t
			end
		end
		-- a car that fell off goes back behind its ball
		local car = self.session:CarOf(m.id)
		if car and Shared.OutOfBounds(self.hole, car.body.pos * BT) then
			local to = cup - p
			local dir = Vector3.new(to.X, to.Y, 0)
			dir = if dir.Magnitude > 1 then dir.Unit else Vector3.new(0, 1, 0)
			local pos = st.safe - dir * 500
			self.session.spawns:Place(car, Vector3.new(pos.X, pos.Y, st.safe.Z - BALL_R + 17), math.atan2(dir.Y, dir.X), car.boost)
		end
	end
	-- everyone else's balls, for drawing (10 Hz)
	if self.elapsed - self.lastBalls >= 0.1 then
		self.lastBalls = self.elapsed
		local out = {}
		for _, m in self.session.members do
			local b = self.balls[m.id]
			out[m.id] = b.ball.body.pos * BT
		end
		self.session:Broadcast("balls", { pos = out })
	end
	-- hole over?
	local all = true
	for _, m in self.session.members do
		if not self.p[m.id].holed then all = false break end
	end
	if all and not self.holedAll then self.holedAll = t end
	if (self.holedAll and t - self.holedAll >= 1.6) or t >= Shared.HOLE_TIME then
		self:EndHole()
	end
end

function Minigolf.EndHole(self: any)
	local par = Shared.HOLES[self.hole].par
	local card = {}
	for _, m in self.session.members do
		local st = self.p[m.id]
		local s = self:HoleScore(st, par)
		if not st.holed or st.capped then
			-- (not a finished hole)
		else
			self.score:Stat(m.id, "holes", 1)
			self.score:Stat(m.id, "time", st.holedAt or Shared.HOLE_TIME)
		end
		self.total[m.id] += s
		self.cards[m.id][self.index] = s
		card[m.id] = { strokes = s, holed = st.holed }
	end
	self.session:Broadcast("holeEnd", { index = self.index, card = card, total = self.total, par = par })
	if self.index >= #self.order then
		self:Finish("fin del recorrido")
		return
	end
	self:BeginHole(self.index + 1)
end

function Minigolf.Standings(self: any): { any }
	local entries = {}
	for _, m in self.session.members do
		local st = self.score:Member(m.id).stats
		table.insert(entries, { id = m.id, keys = { -(self.total[m.id] or 0), st.holes or 0, -math.floor((st.time or 0) * 10) } })
	end
	return Score.Rank(entries)
end

function Minigolf.Finish(self: any, why: string)
	if self.finished then return end
	-- a hole cut short by the round's clock still counts as played
	if self.phase == "play" and (self.cards[self.session.members[1].id] or {})[self.index] == nil then
		self.phase = "done"
		local par = Shared.HOLES[self.hole].par
		for _, m in self.session.members do
			local st = self.p[m.id]
			local s = self:HoleScore(st, par)
			self.total[m.id] += s
			self.cards[m.id][self.index] = s
		end
	end
	self.finished = true
	local parTotal = 0
	for _, k in self.order do parTotal += Shared.HOLES[k].par end
	for id, v in self.total do self.score:Add(id, -v) end
	local st = self:Standings()
	local w = st[1] and self.session.byId[st[1].id]
	local wt = w and self.total[w.id] or 0
	local rel = wt - parTotal
	self.resultSummary = {
		title = if w then ("%s GANA"):format(w.name) else "SIN GANADOR",
		detail = if w then ("%d golpes (%s%d al par)  ·  %s"):format(wt, if rel > 0 then "+" elseif rel == 0 then "±" else "", rel, why) else why,
	}
	self.session:Broadcast("final", { total = self.total, cards = self.cards })
end

function Minigolf.IsFinished(self: any): boolean
	return self.finished
end

function Minigolf.End(self: any)
	if not self.finished then self:Finish("tiempo") end
end

function Minigolf.HandlePlayerJoin(self: any, member: any) end
function Minigolf.HandlePlayerLeave(self: any, member: any) end
function Minigolf.HandlePlayerEliminated(self: any, member: any) end

function Minigolf.GetScore(self: any, member: any): number
	return self.total[member.id] or 0
end

function Minigolf.GetPlacements(self: any): { any }
	local out = {}
	for _, p in self:Standings() do
		local st = self.score:Member(p.id).stats
		st.total = self.total[p.id] or 0
		table.insert(out, { id = p.id, placement = p.placement, score = st.total, stats = st })
	end
	return out
end

function Minigolf.Cleanup(self: any)
	self.cleanup:Clean()
end

return Minigolf
