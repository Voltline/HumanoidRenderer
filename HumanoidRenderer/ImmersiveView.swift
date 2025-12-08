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

struct ImmersiveView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            RealityView { content in
                print(content)
                // MARK: 背景球
                var material = UnlitMaterial(color: .white)
                material.faceCulling = .none
                let backSphere = ModelEntity(mesh: .generateSphere(radius: 30), materials: [material])
                
                content.add(backSphere)
                
                // MARK: 材质球
                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.3))
                if let texture = try? await TextureResource(named: "Skybox-Sample") {
                    var smallMaterial = UnlitMaterial(texture: texture)
                    smallMaterial.faceCulling = .none
                    sphere.model?.materials = [smallMaterial]
                } else {
                    print("Failed to load texture")
                }
                sphere.name = "movingSphere"
                sphere.position = [2, 1, -3]
                
                content.add(sphere)
                
                // MARK: Plane + Head Anchor
                let headAnchor = AnchorEntity(.head)
                headAnchor.name = "headAnchor"

                let plane = MeshResource.generatePlane(width: 0.5, height: 0.3)
                let blueMat = UnlitMaterial(color: .blue)
                let patch = ModelEntity(mesh: plane, materials: [blueMat])
                patch.name = "patch"

                // 离脸 1 米
                patch.position = [0, 0, -1]

                headAnchor.addChild(patch)
                content.add(headAnchor)
                
                // subscribe to per-frame update
                var lastSampleTime = Date()
                _ = content.subscribe(to: SceneEvents.Update.self) { event in
                    let now = Date()
                    if now.timeIntervalSince(lastSampleTime) < 0.2 {  // 每 0.1 秒一次（10Hz）
                        return
                    }
                    lastSampleTime = now

                    Task {
                        let transform = await HeadTracker.shared.currentHeadTransform()
                        let pos = SIMD3<Float>(transform.columns.3.x,
                                               transform.columns.3.y,
                                               transform.columns.3.z)
                        let quat = simd_quatf(transform)
                        let euler = quat.toEulerAngles()

                        print("""
                        head pos: \(pos)
                        quat: \(quat)
                        euler (rad): \(euler)
                        """)
                    }
                }
                
            } update: { content in
                if let sphere = content.entities.first(where: { $0.name == "movingSphere" }) {
                    sphere.position.z += 0.001
                }
            }
            .task {
                await HeadTracker.shared.startTracking()
            }
        }
    }
}

#Preview(immersionStyle: .full) {
    ImmersiveView()
        .environment(AppModel())
}
