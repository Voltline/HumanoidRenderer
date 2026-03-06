//
//  HumanoidRendererApp.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI
import CompositorServices

@main
struct HumanroidRendererApp: App {
    @State private var appModel = AppModel()
    @StateObject private var liveKitVM: LiveKitViewModel
    
    init() {
        let model = AppModel()
        _appModel = State(wrappedValue: model)
        _liveKitVM = StateObject(wrappedValue: LiveKitViewModel(appModel: model))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environmentObject(liveKitVM)
        }

        // MARK: - 方案 A: 全景球 (RealityKit)
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        
        // MARK: - 方案 B: 3D Gaussian Splatting (CompositorServices)
        ImmersiveSpace(id: appModel.gaussianSplatSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                GaussianSplatRenderer.startRendering(
                    layerRenderer,
                    appModel: self.appModel,
                    serverIP: UserDefaults.standard.string(forKey: "serverIP") ?? "localhost"
                )
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
