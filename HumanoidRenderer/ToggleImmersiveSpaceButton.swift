//
//  ToggleImmersiveSpaceButton.swift
//  HumanroidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {

    @Environment(AppModel.self) private var appModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Button {
            Task { @MainActor in
                switch appModel.immersiveSpaceState {
                    case .open:
                        appModel.immersiveSpaceState = .inTransition
                        await dismissImmersiveSpace()
                        // 对于 CompositorLayer (3DGS模式) 没有 .onDisappear 回调，
                        // 需要在这里直接设置为 closed
                        if appModel.renderingMode == .gaussianSplat {
                            appModel.immersiveSpaceState = .closed
                        }
                        // RealityKit 模式的状态在 ImmersiveView.onDisappear() 中设置

                    case .closed:
                        appModel.immersiveSpaceState = .inTransition
                    appModel.phase = .idle
                        switch await openImmersiveSpace(id: appModel.activeSpaceID) {
                            case .opened:
                                // 对于 CompositorLayer (3DGS模式) 没有 .onAppear 回调，
                                // 需要在这里直接设置状态
                                if appModel.renderingMode == .gaussianSplat {
                                    appModel.immersiveSpaceState = .open
                                }
                                // RealityKit 模式的状态在 ImmersiveView.onAppear() 中设置
                                break

                            case .userCancelled, .error:
                                // On error, we need to mark the immersive space
                                // as closed because it failed to open.
                                fallthrough
                            @unknown default:
                                // On unknown response, assume space did not open.
                                appModel.immersiveSpaceState = .closed
                        }

                    case .inTransition:
                        // This case should not ever happen because button is disabled for this case.
                        break
                }
            }
        } label: {
            Text(appModel.immersiveSpaceState == .open ? "退出沉浸式场景" : "进入沉浸式场景")
                .foregroundStyle(appModel.immersiveSpaceState == .open ? Color.red : Color.green)
        }
        .disabled(appModel.immersiveSpaceState == .inTransition)
        .animation(.none, value: 0)
        .fontWeight(.semibold)
    }
}
