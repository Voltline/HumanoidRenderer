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
    
    // MARK: - 构建全景球体 (Equirectangular Sphere)
    @MainActor
    static func buildRig(root: Entity) {
        // 清理旧引用
        sphereEntity = nil
        
        // 1. 创建巨大的球体网格 (半径 100米)
        // 使用较大的段数 (128) 保证球体边缘圆滑
        let mesh = MeshResource.generateSphere(radius: 100)
        
        // 2. 初始材质 (深灰色，避免全黑看不见)
        var material = UnlitMaterial()
        material.color = .init(tint: .darkGray)
        
        // 3. 创建实体
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        sphere.name = "PanoramaSphere"
        
        // 4. 【关键】翻转球体
        // 将 X 轴缩放设为 -1，有两个作用：
        // A. 让材质渲染在球体内部 (Flip Normals)
        // B. 修正全景图的镜像问题 (Mirroring)
        sphere.scale = SIMD3<Float>(-1, 1, 1)
        
        // 5. 旋转修正 (可选)
        // 根据实际体验，如果发现正前方(Z-)对应的不是画面的中心，可以调整这里的 Y 轴旋转
        sphere.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        
        // 6. 添加到场景
        root.addChild(sphere)
        sphereEntity = sphere
        
        print("[BackgroundManager]: 全景球体构建完成")
    }
    
    // MARK: - 更新全景纹理
    @MainActor
    static func updatePanorama(imageData: Data) {
        // 1. 将二进制数据转为临时文件路径 (TextureResource 需要 URL 加载比较稳妥)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pano_temp.jpg")
        
        do {
            try imageData.write(to: tempURL)
            
            // 2. 异步加载纹理
            // 注意：TextureResource 加载可能是异步的，但在 RealityKit 中通常很快
            let texture = try TextureResource.load(contentsOf: tempURL)
            
            // 3. 创建新材质
            var material = UnlitMaterial()
            // 使用纹理作为颜色贴图
            material.color = .init(texture: .init(texture))
            
            // 4. 应用到球体
            if let sphere = sphereEntity {
                sphere.model?.materials = [material]
                print("[BackgroundManager]: 全景贴图已更新")
            } else {
                print("[BackgroundManager]: 球体实体未找到")
            }
            
        } catch {
            print("[BackgroundManager]: 纹理加载失败: \(error)")
        }
    }
}
