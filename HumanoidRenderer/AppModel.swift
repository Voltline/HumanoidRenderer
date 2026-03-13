//
//  AppModel.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI
import LiveKit
internal import Combine
import RealityKit

enum SystemPhase {
    case idle           // 初始状态
    case initializing   // 云台复位中
    case scanning       // 背景采集
    case baking         // Metal 纹理烘焙中
    case ready          // 背景就绪，云台归位
    case live           // 实时跟随状态
}

enum ImmersiveSpaceState {
    case closed
    case inTransition
    case open
}

/// 渲染模式：全景球 vs 3DGS
enum RenderingMode: String, CaseIterable, Identifiable {
    case panoramaSphere = "全景球"
    case gaussianSplat = "3D Gaussian Splatting"
    
    var id: String { rawValue }
}

/// 3DGS 生成模型选择
enum SplatModel: String, CaseIterable, Identifiable {
    case plus = "Marble 0.1-plus"
    case mini = "Marble 0.1-mini"
    
    var id: String { rawValue }
    var apiValue: String { rawValue }
}

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let gaussianSplatSpaceID = "GaussianSplatSpace"
    var immersiveSpaceState = ImmersiveSpaceState.closed
    var renderingMode: RenderingMode = .panoramaSphere
    var remoteVideoTrack: VideoTrack?
    var phase: SystemPhase = .idle
    var scanProgress: Float = 0.0
    var bakedTextureResource: TextureResource?  // 存放烘焙后的材质
    var splatModel: SplatModel = .plus  // 3DGS 生成模型
    var generationProgress: String = ""  // 3DGS 生成进度文案
    var latencyTestArmed: Bool = false
    var latencyTestRunning: Bool = false
    var latencyTestDurationSec: Double = 30.0
    var latencyTestSummary: String = ""
    
    /// 根据当前渲染模式返回对应的 ImmersiveSpace ID
    var activeSpaceID: String {
        switch renderingMode {
        case .panoramaSphere: return immersiveSpaceID
        case .gaussianSplat: return gaussianSplatSpaceID
        }
    }
}
