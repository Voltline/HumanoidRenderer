//
//  HeadTracker.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/12/8.
//

import SwiftUI
import ARKit
import RealityKit
import RealityKitContent

@MainActor
class HeadTracker {
    static let shared = HeadTracker()
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    func startTracking() async {
        try? await session.run([worldTracking])
    }

    func currentHeadTransform() async -> simd_float4x4 {
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return matrix_identity_float4x4
        }
        return deviceAnchor.originFromAnchorTransform
    }
}
