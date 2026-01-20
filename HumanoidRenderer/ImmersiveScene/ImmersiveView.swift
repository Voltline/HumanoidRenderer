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
    @State private var stereoMaterial: ShaderGraphMaterial?
    
    @State private var boundTrack: VideoTrack?
    
    @State private var lastYaw: Float = 0.0
    @State private var lastPitch: Float = 0.0
    @State private var hasBaseline: Bool = false
    
    @AppStorage("serverIP") private var serverIP: String = "192.168.31.247"
    
    var body: some View {
        RealityView { content in
            // MARK: - Background sphere
            var bgMat = UnlitMaterial(color: .white)
            bgMat.faceCulling = .none
            let backSphere = ModelEntity(
                mesh: .generateSphere(radius: 30),
                materials: [bgMat]
            )
            content.add(backSphere)

            // MARK: - Head anchor + plane
            let headAnchor = AnchorEntity(.head)
            headAnchor.name = "headAnchor"

            let planeMesh = MeshResource.generatePlane(width: 1.778, height: 1.0)
            let patch = ModelEntity(mesh: planeMesh, materials: [])
            patch.name = "patch"
            patch.position = [0, 0, -2]

            headAnchor.addChild(patch)
            content.add(headAnchor)

            patchEntity = patch

            // MARK: - Load and bind ShaderGraphMaterial ONCE
            Task {
                do {
                    let mat = try await ShaderGraphMaterial(
                        named: "/Root/StereoVideoMaterial",
                        from: "Immersive.usda",
                        in: realityKitContentBundle
                    )
                    
                    await MainActor.run {
                        var finalMat = mat
                        finalMat.faceCulling = .none
                        
                        // 初始赋值
                        patch.model?.materials = [finalMat]
                        self.stereoMaterial = finalMat
                        
                        print("[RealityKit] StereoVideoMaterial loaded successfully!")
                    }
                } catch {
                    // 如果这里报错，控制台会立刻告诉你原因（比如路径不对）
                    print("[RealityKit] Failed to load material: \(error)")
                }
            }

            // MARK: - Head pose sampling (unchanged)
            var lastSampleTime = Date()
            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                let now = Date()
                if now.timeIntervalSince(lastSampleTime) < 0.05 { return }
                lastSampleTime = now
                headPosTransformAndPost()
            }

        } update: { _ in
            // MARK: - Video track binding
            let newTrack = appModel.remoteVideoTrack

            if boundTrack !== newTrack {
                if let old = boundTrack {
                    old.remove(videoRenderer: bridge)
                }
                if let t = newTrack {
                    t.add(videoRenderer: bridge)
                }
                Task { @MainActor in
                    boundTrack = newTrack
                }
            }

            // MARK: - Stereo texture parameter
            guard
                let left = bridge.leftTexture,
                let right = bridge.rightTexture,
                var mat = stereoMaterial
            else {
                print("left and right texture Guard failed!")
                return
            }
            
            do {
                try mat.setParameter(name: "LeftImage", value: .textureResource(left))
                try mat.setParameter(name: "RightImage", value: .textureResource(right))
                if var model = patchEntity?.components[ModelComponent.self] as? ModelComponent {
                    model.materials = [mat]
                    patchEntity?.components[ModelComponent.self] = model
                    
                    print("@State stereoMaterial update!")
                    Task { @MainActor in self.stereoMaterial = mat }
                }
            } catch {
                print("Material update failed: \(error)")
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
            await uploadDelta(delta_yaw: deltaYaw, delta_pitch: -deltaPitch, serverIP: serverIP)
        }
    }
    private func headPosTranferInit() {
        Task {
            let url = URL(string: "http://\(serverIP):30000/init")!

            var req = URLRequest(url: url)
            req.httpMethod = "GET"

            let _ = try? await URLSession.shared.data(for: req)
        }
    }
}
