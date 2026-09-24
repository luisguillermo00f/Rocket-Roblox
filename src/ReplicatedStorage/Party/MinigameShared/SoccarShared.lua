--!strict
-- SoccarShared.lua: the online Rocket League match (1v1 / 2v2), shared by the server (authoritative) and the clients
-- (prediction + visuals). Standard Soccar arena with boost pads and demolitions, exactly the RocketSim rules the
-- offline match uses; only who runs the simulation changes.
local SC = {}

SC.Id = "soccar"
SC.MATCH_LENGTH = 300 -- s of regulation (the clock only runs while the ball is in play)
SC.KICKOFF_COUNTDOWN = 3 -- s, controls locked
SC.GOAL_PAUSE = 3 -- s after a goal before the next kickoff (cars can still drive)
SC.OVERTIME_CAP = 300 -- s of golden-goal overtime at most; a match can't run forever
SC.MAX_TIME = SC.MATCH_LENGTH + SC.OVERTIME_CAP + 120 -- session hard cap (kickoffs and goal pauses don't count)
SC.DemoMode = "normal"
SC.EXPLOSION_RADIUS = 1500 -- the goal explosion throws nearby cars (as in RL / the offline match)
SC.EXPLOSION_SPEED = 2800

function SC.WorldOptions(): any
	return { boostPads = true, seed = 1 }
end

function SC.PreTick(car: any, dt: number) end

return SC
