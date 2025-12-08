//
//  extensions.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/12/8.
//

import simd

extension simd_quatf {
    /// 返回 (pitch, yaw, roll) 的欧拉角（弧度）
    func toEulerAngles() -> SIMD3<Float> {
        let q = self.vector

        // yaw (y 轴旋转)
        let siny = 2.0 * (q.w * q.y + q.z * q.x)
        let cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
        let yaw = atan2(siny, cosy)

        // pitch (x 轴旋转)
        let sinp = 2.0 * (q.w * q.x - q.z * q.y)
        let pitch: Float
        if abs(sinp) >= 1 {
            pitch = copysign(.pi / 2, sinp)   // 90° 上下限
        } else {
            pitch = asin(sinp)
        }

        // roll (z 轴旋转)
        let sinr = 2.0 * (q.w * q.z + q.x * q.y)
        let cosr = 1.0 - 2.0 * (q.z * q.z + q.x * q.x)
        let roll = atan2(sinr, cosr)

        return SIMD3<Float>(pitch, yaw, roll)
    }
}
