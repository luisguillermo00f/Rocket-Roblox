--!strict
-- LinearPieceCurve.lua: port of RocketSim Math.cpp LinearPieceCurve + the curves from RLConst.h
local LinearPieceCurve = {}
LinearPieceCurve.__index = LinearPieceCurve

export type Curve = { points: { { number } } }

function LinearPieceCurve.new(points: { { number } })
	return setmetatable({ points = points }, LinearPieceCurve)
end

function LinearPieceCurve.GetOutput(self: any, input: number, defaultOutput: number?): number
	local pts = self.points
	local n = #pts
	if n == 0 then
		return defaultOutput or 1
	end
	if input <= pts[1][1] then
		return pts[1][2]
	end
	for i = 2, n do
		local after = pts[i]
		if after[1] > input then
			local before = pts[i - 1]
			local t = (input - before[1]) / (after[1] - before[1])
			return before[2] + (after[2] - before[2]) * t
		end
	end
	return pts[n][2]
end

local new = LinearPieceCurve.new
LinearPieceCurve.STEER_ANGLE_FROM_SPEED = new({ { 0, 0.53356 }, { 500, 0.31930 }, { 1000, 0.18203 }, { 1500, 0.10570 }, { 1750, 0.08507 }, { 3000, 0.03454 } })
LinearPieceCurve.POWERSLIDE_STEER_ANGLE_FROM_SPEED = new({ { 0, 0.39235 }, { 2500, 0.12610 } })
LinearPieceCurve.DRIVE_SPEED_TORQUE_FACTOR = new({ { 0, 1.0 }, { 1400, 0.1 }, { 1410, 0.0 } })
LinearPieceCurve.NON_STICKY_FRICTION_FACTOR = new({ { 0, 0.1 }, { 0.7075, 0.5 }, { 1, 1.0 } })
LinearPieceCurve.LAT_FRICTION = new({ { 0, 1.0 }, { 1, 0.2 } })
LinearPieceCurve.LONG_FRICTION = new({})
LinearPieceCurve.HANDBRAKE_LAT_FRICTION_FACTOR = new({ { 0, 0.1 } })
LinearPieceCurve.HANDBRAKE_LONG_FRICTION_FACTOR = new({ { 0, 0.5 }, { 1, 0.9 } })
LinearPieceCurve.BALL_CAR_EXTRA_IMPULSE_FACTOR = new({ { 0, 0.65 }, { 500, 0.65 }, { 2300, 0.55 }, { 4600, 0.30 } })
LinearPieceCurve.BUMP_VEL_AMOUNT_GROUND = new({ { 0, 5 / 6 }, { 1400, 1100 }, { 2200, 1530 } })
LinearPieceCurve.BUMP_VEL_AMOUNT_AIR = new({ { 0, 5 / 6 }, { 1400, 1390 }, { 2200, 1945 } })
LinearPieceCurve.BUMP_UPWARD_VEL_AMOUNT = new({ { 0, 2 / 6 }, { 1400, 278 }, { 2200, 417 } })

return LinearPieceCurve
