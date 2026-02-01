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

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    var immersiveSpaceState = ImmersiveSpaceState.closed
    var remoteVideoTrack: VideoTrack?
    var phase: SystemPhase = .idle
    var scanProgress: Float = 0.0
    var bakedTextureResource: TextureResource?  // 存放烘焙后的材质
}
