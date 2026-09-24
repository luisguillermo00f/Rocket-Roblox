--!strict
-- MinigameSpawnManager.lua: creates the round's cars in the session World, places / respawns them, removes them.
-- Every car gets a small network id (netId) used in snapshots.
local RS = game:GetService("ReplicatedStorage")
local CarPhysics = require(RS.Physics.CarPhysics)
local CarConfig = require(RS.Physics.CarConfig)

local MinigameSpawnManager = {}
MinigameSpawnManager.__index = MinigameSpawnManager

function MinigameSpawnManager.new(world: any)
	return setmetatable({ world = world, nextNetId = 1, cars = {} }, MinigameSpawnManager)
end

-- member: { id, hitbox? }; returns the car
function MinigameSpawnManager.Spawn(self: any, member: any, team: number, posUU: Vector3, yaw: number): any
	local config = CarConfig[member.hitbox or "Octane"] or CarConfig.Octane
	local car = self.world:AddCar(team, config)
	car.netId = self.nextNetId
	self.nextNetId += 1
	self.cars[member.id] = car
	MinigameSpawnManager.Place(self, car, posUU, yaw)
	return car
end

function MinigameSpawnManager.Place(self: any, car: any, posUU: Vector3, yaw: number, boost: number?)
	-- clear this car's persistent contacts so the teleport doesn't warm-start stale ones
	for key in self.world.manifolds do
		if key == "b" .. car.id or string.find(key, "^x%d+:" .. car.id .. "$") or string.find(key, "^w" .. car.id .. ":") or string.find(key, "^c" .. car.id .. ":") or string.find(key, "^c%d+:" .. car.id .. "$") then
			self.world.manifolds[key] = nil
		end
	end
	local keepBoost = boost or car.boost or 100
	CarPhysics.ResetState(car, posUU, yaw, keepBoost, true)
	car.controls = CarPhysics.EmptyControls()
end

function MinigameSpawnManager.Remove(self: any, memberId: string)
	local car = self.cars[memberId]
	if car then
		self.world:RemoveCar(car)
		self.cars[memberId] = nil
	end
end

function MinigameSpawnManager.Get(self: any, memberId: string): any
	return self.cars[memberId]
end

return MinigameSpawnManager
