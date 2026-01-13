//
//  NetUtils.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/10.
//

import ARKit
import Foundation

func uploadPose(pos: SIMD3<Float>, quat: simd_quatf) async {
    let url = URL(string: "http://192.168.31.232:30000/pose")!   // 别用 localhost！！
    
    if !(pos.x == pos.y && pos.y == pos.z && pos.z == 0) {
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "position": [pos.x, pos.y, pos.z],
            "quaternion": [quat.vector.x, quat.vector.y, quat.vector.z, quat.vector.w]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try! JSONSerialization.data(withJSONObject: payload)

        let _ = try? await URLSession.shared.data(for: req)
    }
}

func uploadDelta(delta_yaw: Float, delta_pitch: Float) async {
    let url = URL(string: "http://192.168.31.134:30000/gimbal/delta")!   // 别用 localhost！！
    let payload: [String: Any] = [
        "delta_yaw": delta_yaw,
        "delta_pitch": delta_pitch
    ]

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: payload)

    let _ = try? await URLSession.shared.data(for: req)
}
