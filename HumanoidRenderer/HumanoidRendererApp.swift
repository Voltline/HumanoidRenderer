//
//  HumanoidRendererApp.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI

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
    }
}
