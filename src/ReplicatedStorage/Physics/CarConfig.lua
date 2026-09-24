--!strict
-- CarConfig.lua: RocketSim CarConfig.cpp hitbox families (UU). The visual car is only a skin on top of these.
local CarConfig = {}

export type WheelPair = { radius: number, suspensionRestLength: number, connectionPointOffset: Vector3 }
export type Config = {
	name: string,
	hitboxSize: Vector3,
	hitboxPosOffset: Vector3,
	frontWheels: WheelPair,
	backWheels: WheelPair,
	dodgeDeadzone: number,
}

local function make(name, size, offset, fRad, bRad, fRest, bRest, fOff, bOff): Config
	return {
		name = name,
		hitboxSize = size,
		hitboxPosOffset = offset,
		frontWheels = { radius = fRad, suspensionRestLength = fRest, connectionPointOffset = fOff },
		backWheels = { radius = bRad, suspensionRestLength = bRest, connectionPointOffset = bOff },
		dodgeDeadzone = 0.5,
	}
end

CarConfig.Octane = make("Octane", Vector3.new(120.507, 86.6994, 38.6591), Vector3.new(13.8757, 0, 20.755),
	12.50, 15.00, 38.755, 37.055, Vector3.new(51.25, 25.90, 20.755), Vector3.new(-33.75, 29.50, 20.755))
CarConfig.Dominus = make("Dominus", Vector3.new(130.427, 85.7799, 33.8), Vector3.new(9.0, 0, 15.75),
	12.00, 13.50, 33.95, 33.85, Vector3.new(50.30, 31.10, 15.75), Vector3.new(-34.75, 33.00, 15.75))
CarConfig.Plank = make("Plank", Vector3.new(131.32, 87.1704, 31.8944), Vector3.new(9.00857, 0, 12.0942),
	12.50, 17.00, 31.9242, 27.9242, Vector3.new(49.97, 27.80, 12.0942), Vector3.new(-35.43, 20.28, 12.0942))
CarConfig.Breakout = make("Breakout", Vector3.new(133.992, 83.021, 32.8), Vector3.new(12.5, 0, 11.75),
	13.50, 15.00, 29.7, 29.666, Vector3.new(51.50, 26.67, 11.75), Vector3.new(-35.75, 35.00, 11.75))
CarConfig.Hybrid = make("Hybrid", Vector3.new(129.519, 84.6879, 36.6591), Vector3.new(13.8757, 0, 20.755),
	12.50, 15.00, 38.755, 37.055, Vector3.new(51.25, 25.90, 20.755), Vector3.new(-34.00, 29.50, 20.755))
CarConfig.Merc = make("Merc", Vector3.new(123.22, 79.2103, 44.1591), Vector3.new(11.3757, 0, 21.505),
	15.00, 15.00, 39.505, 39.105, Vector3.new(51.25, 25.90, 21.505), Vector3.new(-33.75, 29.50, 21.505))

CarConfig.All = { CarConfig.Octane, CarConfig.Dominus, CarConfig.Plank, CarConfig.Breakout, CarConfig.Hybrid, CarConfig.Merc }

return CarConfig
