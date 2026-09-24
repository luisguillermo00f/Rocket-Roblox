--!strict
-- SoccarBotController.lua: the offline match's bots (Game.BotAI: novato / pro / freestyler), driving a car in the
-- server's online match. One ball prediction per match is shared by all its bots and refreshed once per tick.
local RS = game:GetService("ReplicatedStorage")
local CarPhysics = require(RS.Physics.CarPhysics)
local BotAI = require(RS.Game.BotAI)
local Base = require(script.Parent.Parent.MinigameBotController)

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

local seedN = 0

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	seedN += 1
	self.ai = BotAI.new(session.world, car, minigame.difficulty or "pro", seedN)
	return self
end

function Bot.ResetForKickoff(self: any)
	self.ai.plan = nil
	self.ai.aerial = nil
	self.ai.actions = {}
end

function Bot.Think(self: any, dt: number): any
	local mg = self.mg
	local world = self.session.world
	-- goal pause: the ball is frozen, re-predicting it every tick would be wasted work; bots just coast
	if not world.ballEnabled then
		return CarPhysics.EmptyControls()
	end
	if mg.predTick ~= world.tickCount then
		mg.predTick = world.tickCount
		mg.prediction:Update(world)
		mg.ctx = BotAI.BuildContext(world, mg.prediction, mg.simTime)
	end
	self.ai:Tick(dt, mg.ctx)
	return self.car.controls
end

return Bot
