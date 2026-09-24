--!strict
-- MatchMaker.lua: online matches (the menu's JUGAR / RANKED / SALA PRIVADA). Every match is a server session like the
-- Party minigames (Soccar), so it's the same server-authoritative netcode; bots take any empty seat.
--   * public queues (1v1, 2v2, ranked 1v1) on this server: full as soon as enough players queue, otherwise the
--     players waiting longest start after QUEUE_WAIT seconds with bots filling the rest
--   * private rooms: the host gets an SL-#### code (joinable from any server, see CodeDirectory), picks 1v1 / 2v2 and
--     starts when ready; bots fill empty seats; after the match everyone is back in the room for a rematch
-- Clients only ask (MatchRequest); every rule is checked here.
local RS = game:GetService("ReplicatedStorage")
local CarConfig = require(RS.Physics.CarConfig)
local CodeDirectory = require(script.Parent.CodeDirectory)

local MatchMaker = {}
MatchMaker.__index = MatchMaker

local QUEUE_WAIT = 8 -- s before a queue starts with bots filling the empty seats
local SIZE = { ["1v1"] = 2, ["2v2"] = 4 }
local DIFFICULTIES = { noob = true, pro = true, freestyler = true }
local SKINS = { Octane = true, Troll = true }
local BOT_NAMES = { "Vórtice", "Nitro", "Cometa", "Titán", "Raptor", "Ónix", "Pulso", "Cénit", "Órbita", "Rayo", "Halcón", "Tormenta" }

function MatchMaker.new(service: any)
	local self = setmetatable({}, MatchMaker)
	self.service = service
	self.queues = { ["1v1"] = {}, ["2v2"] = {}, ranked = {} } -- lists of entries { player, since, car }
	self.rooms = {} -- code -> room
	self.of = {} -- Player -> { kind = "queue", key } | { kind = "room", room } | { kind = "match", session, room? }
	self.nextBot = 1
	return self
end

-- the car a player asked for (validated)
local function carChoice(arg: any): any
	local skin = if type(arg) == "table" and SKINS[arg.skin] then arg.skin else "Octane"
	local hitbox = if type(arg) == "table" and type(arg.hitbox) == "string" and CarConfig[arg.hitbox] then arg.hitbox else "Octane"
	return { skin = skin, hitbox = hitbox }
end

local function newCode(rooms: { [string]: any }): string
	local rng = Random.new()
	for _ = 1, 50 do
		local code = ("SL-%04d"):format(rng:NextInteger(0, 9999))
		if not rooms[code] and not CodeDirectory.Taken(code) then return code end
	end
	return "SL-" .. tostring(os.clock()):gsub("%.", "")
end

-- ---------------------------------------------------------------- state sent to the client
function MatchMaker.State(self: any, player: Player): any
	local o = self.of[player]
	if not o then return { status = "idle" } end
	if o.kind == "queue" then
		local q = self.queues[o.key]
		return { status = "queue", key = o.key, since = o.since, waiting = #q, needed = if o.key == "2v2" then 4 else 2, wait = QUEUE_WAIT }
	end
	local room = o.room
	local roomState = nil
	if room then
		local members = {}
		for _, e in room.members do
			table.insert(members, { name = e.player.DisplayName, userId = e.player.UserId, isHost = e.player.UserId == room.hostUserId })
		end
		roomState = { code = room.code, mode = room.mode, hostUserId = room.hostUserId, members = members, size = SIZE[room.mode], inMatch = room.session ~= nil }
	end
	return { status = if o.kind == "match" then "match" else "room", room = roomState }
end

function MatchMaker.Push(self: any, player: Player)
	if player.Parent then
		self.service.remotes.MatchState:FireClient(player, self:State(player))
	end
end

function MatchMaker.PushRoom(self: any, room: any)
	for _, e in room.members do self:Push(e.player) end
end

-- everyone waiting in a queue sees the count change
function MatchMaker.PushQueue(self: any, key: string)
	for _, e in self.queues[key] do self:Push(e.player) end
end

-- ---------------------------------------------------------------- leaving whatever you're in
function MatchMaker.Leave(self: any, player: Player)
	local o = self.of[player]
	if not o then return end
	self.of[player] = nil
	if o.kind == "queue" then
		local q = self.queues[o.key]
		for i = #q, 1, -1 do
			if q[i].player == player then table.remove(q, i) end
		end
		self:PushQueue(o.key)
	elseif o.kind == "match" then
		if o.session then o.session:HandleLeave("u" .. player.UserId) end
	end
	local room = o.room
	if room then
		for i = #room.members, 1, -1 do
			if room.members[i].player == player then table.remove(room.members, i) end
		end
		if #room.members == 0 then
			self.rooms[room.code] = nil
			CodeDirectory.Unregister(room.code)
		else
			if room.hostUserId == player.UserId then room.hostUserId = room.members[1].player.UserId end
			self:PushRoom(room)
		end
	end
end

-- ---------------------------------------------------------------- matches
function MatchMaker.StartMatch(self: any, humans: { any }, mode: string, config: any, room: any?): (boolean, string?)
	local size = SIZE[mode]
	local members = {}
	-- humans first, alternating teams (so two friends in a 2v2 room face each other only if they're 2 of 4)
	for i, e in humans do
		table.insert(members, {
			id = "u" .. e.player.UserId, kind = "player", player = e.player, userId = e.player.UserId,
			name = e.player.DisplayName, hitbox = e.car.hitbox, skin = e.car.skin, team = (i - 1) % 2,
		})
	end
	local counts = { [0] = 0, [1] = 0 }
	for _, m in members do counts[m.team] += 1 end
	while #members < size do
		local team = if counts[0] <= counts[1] then 0 else 1
		counts[team] += 1
		local name = BOT_NAMES[(self.nextBot - 1) % #BOT_NAMES + 1]
		table.insert(members, { id = "b" .. self.nextBot, kind = "bot", name = name, hitbox = "Octane", skin = "Octane", team = team })
		self.nextBot += 1
	end
	local def = self.service.matchDef
	local party = { kind = "match", members = members, points = {}, config = config, room = room }
	local ok, s = pcall(function()
		return self.service:StartSession(party, def, members, 1)
	end)
	if not ok then
		warn("[MatchMaker] could not start a match:", s)
		return false, "no se pudo iniciar la partida"
	end
	party.session = s
	if room then room.session = s end
	for _, e in humans do
		self.of[e.player] = { kind = "match", session = s, room = room }
		self:Push(e.player)
	end
	return true, nil
end

function MatchMaker.OnSessionDone(self: any, s: any)
	local party = s.party
	local room = party.room
	if room then room.session = nil end
	for _, m in party.members do
		local p = m.player
		if p and self.of[p] and self.of[p].session == s then
			-- back to the room for a rematch, or back to idle after a public match
			local inRoom = false
			if room then
				for _, e in room.members do
					if e.player == p then inRoom = true end
				end
			end
			self.of[p] = if inRoom then { kind = "room", room = room } else nil
			self:Push(p)
		end
	end
end

-- queues: full -> go; oldest waited long enough -> go with bots
function MatchMaker.Update(self: any)
	local now = os.clock()
	for key, q in self.queues do
		local mode = if key == "2v2" then "2v2" else "1v1"
		local need = SIZE[mode]
		while #q >= need or (#q > 0 and now - q[1].since >= QUEUE_WAIT) do
			local take = {}
			for _ = 1, math.min(need, #q) do table.insert(take, table.remove(q, 1)) end
			local diff = take[1].difficulty or "pro"
			for _, e in take do self.of[e.player] = nil end
			self:StartMatch(take, mode, { mode = mode, ranked = key == "ranked", difficulty = diff }, nil)
		end
	end
	CodeDirectory.Tick()
end

-- ---------------------------------------------------------------- requests
function MatchMaker.Handle(self: any, player: Player, action: any, arg: any): any
	if type(action) ~= "string" then return { ok = false, error = "petición inválida" } end
	local o = self.of[player]
	local ok, err = true, nil
	if action == "queue" then
		if o and o.kind == "match" then return { ok = false, error = "ya estás en una partida", state = self:State(player) } end
		local mode = type(arg) == "table" and arg.mode
		local key = if type(arg) == "table" and arg.ranked == true then "ranked" elseif mode == "2v2" then "2v2" elseif mode == "1v1" then "1v1" else nil
		if not key then return { ok = false, error = "modo inválido" } end
		self:Leave(player)
		local diff = if type(arg) == "table" and DIFFICULTIES[arg.difficulty] then arg.difficulty else "pro"
		local entry = { player = player, since = os.clock(), car = carChoice(arg), difficulty = diff }
		table.insert(self.queues[key], entry)
		self.of[player] = { kind = "queue", key = key, since = workspace:GetServerTimeNow() }
		self:PushQueue(key)
	elseif action == "cancel" or action == "leave" then
		if o and o.kind == "match" then return { ok = false, error = "la partida está en curso" } end
		self:Leave(player)
	elseif action == "forfeit" then
		-- leave a running match: a bot takes the car (MinigameSession.HandleLeave); a room keeps its other members
		if not (o and o.kind == "match") then return { ok = false, error = "no estás en una partida" } end
		self:Leave(player) -- also leaves the room: they chose to go
	elseif action == "createRoom" then
		if o and o.kind == "match" then return { ok = false, error = "ya estás en una partida" } end
		self:Leave(player)
		local mode = if type(arg) == "table" and arg.mode == "2v2" then "2v2" else "1v1"
		local room = { code = newCode(self.rooms), mode = mode, hostUserId = player.UserId, members = { { player = player, car = carChoice(arg) } }, session = nil }
		self.rooms[room.code] = room
		CodeDirectory.Register(room.code)
		self.of[player] = { kind = "room", room = room }
		self:PushRoom(room)
	elseif action == "joinRoom" then
		local code = if type(arg) == "table" then arg.code else nil
		if type(code) ~= "string" or #code > 12 then return { ok = false, error = "código inválido" } end
		code = string.upper(code)
		local room = self.rooms[code]
		if not room then
			local entry = CodeDirectory.Lookup(code)
			if entry then
				local _, terr = CodeDirectory.TeleportTo(player, entry, { joinRoom = code })
				return { ok = false, error = terr or "viajando al servidor de la sala..." }
			end
			return { ok = false, error = "no existe esa sala" }
		end
		if o and o.room == room then return { ok = true, state = self:State(player) } end
		if o and o.kind == "match" then return { ok = false, error = "ya estás en una partida" } end
		if #room.members >= SIZE[room.mode] then return { ok = false, error = "la sala está llena" } end
		if room.session then return { ok = false, error = "la sala está jugando; espera a que termine" } end
		self:Leave(player)
		table.insert(room.members, { player = player, car = carChoice(arg) })
		self.of[player] = { kind = "room", room = room }
		self:PushRoom(room)
	elseif action == "setRoomMode" then
		local room = o and o.room
		if not room or room.hostUserId ~= player.UserId then return { ok = false, error = "solo el anfitrión" } end
		local mode = if arg == "2v2" then "2v2" elseif arg == "1v1" then "1v1" else nil
		if not mode then return { ok = false, error = "modo inválido" } end
		if #room.members > SIZE[mode] then return { ok = false, error = "hay demasiados jugadores para 1v1" } end
		room.mode = mode
		self:PushRoom(room)
	elseif action == "startRoom" then
		local room = o and o.room
		if not room or room.hostUserId ~= player.UserId then return { ok = false, error = "solo el anfitrión puede empezar" } end
		if room.session then return { ok = false, error = "ya están jugando" } end
		local diff = if type(arg) == "table" and DIFFICULTIES[arg.difficulty] then arg.difficulty else "pro"
		ok, err = self:StartMatch(room.members, room.mode, { mode = room.mode, ranked = false, difficulty = diff, private = true }, room)
	elseif action == "state" then
		ok = true
	else
		return { ok = false, error = "acción desconocida" }
	end
	return { ok = ok, error = err, state = self:State(player) }
end

return MatchMaker
