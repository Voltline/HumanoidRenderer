//
//  BackgroundManager.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/31.
//

import RealityKit
import UIKit

class BackgroundManager {
    // 持有球体实体的引用，以便后续更新材质
    static var sphereEntity: ModelEntity?
    
    // MARK: - 构建全景球体
    @MainActor
    static func buildRig(root: Entity) {
        sphereEntity = nil
        
        // 创建全景球体
        let mesh = MeshResource.generateSphere(radius: 10)
        
        var material = UnlitMaterial()
        material.color = .init(tint: .darkGray)
        
        // 创建实体
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        sphere.name = "PanoramaSphere"
        
        sphere.scale = SIMD3<Float>(-1, 1, 1)
        sphere.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        
        // 添加到场景
        root.addChild(sphere)
        sphereEntity = sphere
        
        AppLogger.shared.info("[BackgroundManager]: 全景球体构建完成")
    }
    
    // MARK: - 更新全景纹理
    @MainActor
    static func updatePanorama(imageData: Data) {
        // 将二进制数据转为临时文件路径
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pano_temp.jpg")
        
        do {
            try imageData.write(to: tempURL)
            
            // 异步加载纹理
            let texture = try TextureResource.load(contentsOf: tempURL)
            
            // 创建新材质
            var material = UnlitMaterial()
            // 使用纹理作为颜色贴图
            material.color = .init(texture: .init(texture))
            
            // 应用到球体
            if let sphere = sphereEntity {
                sphere.model?.materials = [material]
                AppLogger.shared.info("[BackgroundManager]: 全景贴图已更新")
            } else {
                AppLogger.shared.warn("[BackgroundManager]: 球体实体未找到")
            }
            
        } catch {
            AppLogger.shared.error("[BackgroundManager]: 纹理加载失败: \(error)")
        }
    }
}
