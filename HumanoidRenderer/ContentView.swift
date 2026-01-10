//
//  ContentView.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI
import RealityKit
import RealityKitContent
import LiveKit

struct ContentView: View {
    @EnvironmentObject private var liveKitVM: LiveKitViewModel
    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("欢迎来到EERenderer")
            ToggleImmersiveSpaceButton()
        }
        .task {
            liveKitVM.connect()
        }
        .padding()
    }
}

#Preview {
    let appModel = AppModel()
    var liveKitVM = LiveKitViewModel(appModel: appModel)
    ContentView()
        .environment(appModel)
        .environmentObject(liveKitVM)
}
