--!strict
-- Quaternion.lua: unit quaternion orientation with Bullet's exact integrator
-- (btTransformUtil::integrateTransform: exponential map, clamped to ANGULAR_MOTION_THRESHOLD per step).
local C = require(script.Parent.PhysicsConstants)

export type Quat = { x: number, y: number, z: number, w: number }

local Q = {}

function Q.identity(): Quat
	return { x = 0, y = 0, z = 0, w = 1 }
end

function Q.fromAxisAngle(axis: Vector3, angle: number): Quat
	local u = axis.Unit
	local s = math.sin(angle * 0.5)
	return { x = u.X * s, y = u.Y * s, z = u.Z * s, w = math.cos(angle * 0.5) }
end

-- RocketSim Angle(yaw, 0, 0).ToRotMat(): rotation about +Z
function Q.fromYaw(yaw: number): Quat
	return { x = 0, y = 0, z = math.sin(yaw * 0.5), w = math.cos(yaw * 0.5) }
end

function Q.mul(a: Quat, b: Quat): Quat
	return {
		w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
		x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		y = a.w * b.y + a.y * b.w + a.z * b.x - a.x * b.z,
		z = a.w * b.z + a.z * b.w + a.x * b.y - a.y * b.x,
	}
end

function Q.normalize(q: Quat): Quat
	local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
	return { x = q.x / l, y = q.y / l, z = q.z / l, w = q.w / l }
end

-- Columns of the rotation matrix: forward (X), right (Y), up (Z) in simulation space.
function Q.toBasis(q: Quat): (Vector3, Vector3, Vector3)
	local x, y, z, w = q.x, q.y, q.z, q.w
	local s = 2 / (x * x + y * y + z * z + w * w)
	local xs, ys, zs = x * s, y * s, z * s
	local wx, wy, wz = w * xs, w * ys, w * zs
	local xx, xy, xz = x * xs, x * ys, x * zs
	local yy, yz, zz = y * ys, y * zs, z * zs
	return Vector3.new(1 - (yy + zz), xy + wz, xz - wy),
		Vector3.new(xy - wz, 1 - (xx + zz), yz + wx),
		Vector3.new(xz + wy, yz - wx, 1 - (xx + yy))
end

-- Inverse of toBasis (Shepperd's method), used when a state is set from a matrix
function Q.fromBasis(f: Vector3, r: Vector3, u: Vector3): Quat
	local m00, m01, m02 = f.X, r.X, u.X
	local m10, m11, m12 = f.Y, r.Y, u.Y
	local m20, m21, m22 = f.Z, r.Z, u.Z
	local trace = m00 + m11 + m22
	local q: Quat
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		q = { w = 0.25 * s, x = (m21 - m12) / s, y = (m02 - m20) / s, z = (m10 - m01) / s }
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		q = { w = (m21 - m12) / s, x = 0.25 * s, y = (m01 + m10) / s, z = (m02 + m20) / s }
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		q = { w = (m02 - m20) / s, x = (m01 + m10) / s, y = 0.25 * s, z = (m12 + m21) / s }
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		q = { w = (m10 - m01) / s, x = (m02 + m20) / s, y = (m12 + m21) / s, z = 0.25 * s }
	end
	return Q.normalize(q)
end

-- btTransformUtil::integrateTransform (rotation part)
function Q.integrate(q: Quat, angVel: Vector3, dt: number): Quat
	local fAngle = angVel.Magnitude
	if fAngle * dt > C.ANGULAR_MOTION_THRESHOLD then
		fAngle = C.ANGULAR_MOTION_THRESHOLD / dt
	end
	local axis: Vector3
	if fAngle < 0.001 then
		axis = angVel * (0.5 * dt - (dt * dt * dt) * 0.020833333333 * fAngle * fAngle)
	else
		axis = angVel * (math.sin(0.5 * fAngle * dt) / fAngle)
	end
	local dorn = { x = axis.X, y = axis.Y, z = axis.Z, w = math.cos(fAngle * dt * 0.5) }
	local r = Q.mul(dorn, q)
	local l2 = r.x * r.x + r.y * r.y + r.z * r.z + r.w * r.w
	if l2 > 1.1920929e-07 then
		return Q.normalize(r)
	end
	return q
end

function Q.slerp(a: Quat, b: Quat, t: number): Quat
	local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	local bx, by, bz, bw = b.x, b.y, b.z, b.w
	if d < 0 then
		d = -d; bx, by, bz, bw = -bx, -by, -bz, -bw
	end
	if d > 0.9995 then
		return Q.normalize({ x = a.x + (bx - a.x) * t, y = a.y + (by - a.y) * t, z = a.z + (bz - a.z) * t, w = a.w + (bw - a.w) * t })
	end
	local th = math.acos(d)
	local s = math.sin(th)
	local wa, wb = math.sin((1 - t) * th) / s, math.sin(t * th) / s
	return { x = a.x * wa + bx * wb, y = a.y * wa + by * wb, z = a.z * wa + bz * wb, w = a.w * wa + bw * wb }
end

-- RocketSim Angle::FromRotMat roll (btMatrix3x3::getEulerYPR, roll negated)
function Q.rollFromBasis(f: Vector3, r: Vector3, u: Vector3): number
	local pitch = -math.asin(math.clamp(f.Z, -1, 1))
	local cp = math.cos(pitch)
	if math.abs(f.Z) >= 1 then
		return 0
	end
	return -math.atan2(r.Z / cp, u.Z / cp)
end

return Q
