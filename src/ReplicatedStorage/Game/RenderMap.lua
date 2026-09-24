--!strict
-- RenderMap.lua: simulation space (RocketSim, UU, Z up) -> Roblox space (studs, Y up).
-- (x, y, z) -> (x, z, y) * STUDS_PER_UU. The swap is a mirror, which is exactly what keeps the car's +Y (right)
-- on the driver's right in Roblox's right-handed frame.
local C = require(script.Parent.Parent.Physics.PhysicsConstants)
local Q = require(script.Parent.Parent.Physics.Quaternion)

local S = C.STUDS_PER_UU
local RenderMap = {}

function RenderMap.Pos(uu: Vector3): Vector3
	return Vector3.new(uu.X * S, uu.Z * S, uu.Y * S)
end

function RenderMap.Dir(v: Vector3): Vector3
	return Vector3.new(v.X, v.Z, v.Y)
end

-- Body (BT position + quaternion) -> Roblox CFrame whose LookVector is the car forward
function RenderMap.CFrame(posUU: Vector3, rot: Q.Quat): CFrame
	local f, r, u = Q.toBasis(rot)
	return CFrame.fromMatrix(RenderMap.Pos(posUU), RenderMap.Dir(r), RenderMap.Dir(u))
end

-- Local offset in car space (forward, right, up) UU -> Roblox local offset (right = +X, up = +Y, forward = -Z)
function RenderMap.LocalOffset(fru: Vector3): Vector3
	return Vector3.new(fru.Y * S, fru.Z * S, -fru.X * S)
end

RenderMap.S = S
return RenderMap
