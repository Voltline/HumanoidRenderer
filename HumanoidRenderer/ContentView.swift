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
    @Environment(AppModel.self) private var appModel: AppModel
    @AppStorage("serverIP") private var serverIP: String = "localhost"
    @State private var showModifyServerIP: Bool = false
    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)
            VStack {
                Text("欢迎来到EERenderer")
                Text("当前设定的服务器IP为：\(serverIP)")
                    .foregroundStyle(serverIP == "localhost" ? Color.red : Color.green)
                
                switch appModel.phase {
                case .idle:
                    Text("")
                case .initializing:
                    Text("正在将电机复位")
                case .scanning:
                    VStack {
                        Text("正在扫描")
                        ProgressView(value: appModel.scanProgress, total: 1)
                            .padding()
                    }
                case .baking:
                    Text("扫描完毕，正在烘焙材质")
                case .ready:
                    Text("即将就绪，请稍候")
                        .foregroundStyle(Color.green)
                case .live:
                    Text("串流中")
                        .foregroundStyle(Color.green)
                }
                
                HStack {
                    Button {
                        showModifyServerIP.toggle()
                    } label: {
                        Text("修改服务器IP")
                    }
                    ToggleImmersiveSpaceButton()
                }
            }
            .padding()
        }
        .alert("输入新的服务器IP", isPresented: $showModifyServerIP) {
            VStack {
                TextField("例如: 192.168.31.100", text: $serverIP)
            }
        }
        .task {
            liveKitVM.connect(serverIP: serverIP)
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
