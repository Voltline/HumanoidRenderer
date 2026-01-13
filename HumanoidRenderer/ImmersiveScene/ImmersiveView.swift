//
//  ImmersiveView.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI
import ARKit
import RealityKit
import RealityKitContent
import LiveKit
internal import Combine

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel: AppModel
    
    @StateObject private var bridge = TrackTextureBridge()
    @State private var patchEntity: ModelEntity?
    
    @State private var boundTrack: VideoTrack?
    
    @State private var lastYaw: Float = 0.0
    @State private var lastPitch: Float = 0.0
    @State private var hasBaseline: Bool = false
    
    var body: some View {
        RealityView { content in
            /// MARK: 背景球
            var material = UnlitMaterial(color: .white)
            material.faceCulling = .none
            let backSphere = ModelEntity(mesh: .generateSphere(radius: 30), materials: [material])
            content.add(backSphere)
            
            /// MARK: Plane + Head Anchor
            // 绑定到头部
            let headAnchor = AnchorEntity(.head)
            headAnchor.name = "headAnchor"
            // 创建平面
            let plane = MeshResource.generatePlane(width: 1.778, height: 2)
            var mat = UnlitMaterial(color: .blue)
            mat.faceCulling = .none
            let patch = ModelEntity(mesh: plane, materials: [mat])
            patch.name = "patch"

            // 离脸 1 米
            patch.position = [0, 0, -3]
            headAnchor.addChild(patch)
            content.add(headAnchor)
            patchEntity = patch
            
            // subscribe to per-frame update
            var lastSampleTime = Date()
            _ = content.subscribe(to: SceneEvents.Update.self) { event in
                let now = Date()
                if now.timeIntervalSince(lastSampleTime) < 0.05 {  // 每 0.05 秒一次（20Hz）
                    return
                }
                lastSampleTime = now
                headPosTransformAndPost()
            }
        } update: { _ in
            let newTrack = appModel.remoteVideoTrack
            
            if boundTrack !== newTrack {
                if let old = boundTrack {
                    old.remove(videoRenderer: bridge)
                }
                
                if let t = newTrack {
                    t.add(videoRenderer: bridge)
                }
                
                boundTrack = newTrack
            }
            
            if let tex = bridge.texture, let patch = patchEntity {
                var m = UnlitMaterial(texture: tex)
                m.faceCulling = .none
                patch.model?.materials = [m]
            }
        }
        .onAppear {
            headPosTranferInit()
        }
        .onDisappear {
            if let old = boundTrack {
                old.remove(videoRenderer: bridge)
                boundTrack = nil
            }
        }
        .task {
            await HeadTracker.shared.startTracking()
        }
    }
    
    private func headPosTransformAndPost() {
        Task {
            let transform = await HeadTracker.shared.currentHeadTransform()
            let pos = SIMD3<Float>(transform.columns.3.x,
                                   transform.columns.3.y,
                                   transform.columns.3.z)
            let quat = simd_quatf(transform)
            let euler = quat.toEulerAngles()
            if !hasBaseline {
                self.lastYaw = euler.y
                self.lastPitch = euler.x
                self.hasBaseline = true
                return
            }
            
            let deltaYaw = euler.y - self.lastYaw
            let deltaPitch = euler.x - self.lastPitch
            
            self.lastYaw = euler.y
            self.lastPitch = euler.x
            await uploadDelta(delta_yaw: deltaYaw, delta_pitch: -deltaPitch)
        }
    }
    private func headPosTranferInit() {
        Task {
            let url = URL(string: "http://192.168.31.134:30000/init")!

            var req = URLRequest(url: url)
            req.httpMethod = "GET"

            let _ = try? await URLSession.shared.data(for: req)
        }
    }
}
