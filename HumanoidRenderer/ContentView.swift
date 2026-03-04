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
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var liveKitVM: LiveKitViewModel
    @Environment(AppModel.self) private var appModel: AppModel
    @AppStorage("serverIP") private var serverIP: String = "localhost"
    @State private var showModifyServerIP: Bool = false
    @State private var showSplatFilePicker: Bool = false
    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)
            VStack {
                Text("欢迎来到EERenderer")
                Text("当前设定的服务器IP为：\(serverIP)")
                    .foregroundStyle(serverIP == "localhost" ? Color.red : Color.green)
                
                // MARK: - 渲染模式选择
                Picker("渲染模式", selection: Bindable(appModel).renderingMode) {
                    ForEach(RenderingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(appModel.immersiveSpaceState != .closed)
                
                // 3DGS 模式下显示文件选择
                if appModel.renderingMode == .gaussianSplat {
                    HStack {
                        if let url = appModel.splatFileURL {
                            Text("已选择: \(url.lastPathComponent)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("请选择 .ply / .splat / .spz 文件")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("选择文件") {
                            showSplatFilePicker = true
                        }
                        .disabled(appModel.immersiveSpaceState != .closed)
                    }
                    .padding(.vertical, 4)
                }
                
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
        .fileImporter(
            isPresented: $showSplatFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // 开始访问安全范围
                if url.startAccessingSecurityScopedResource() {
                    appModel.splatFileURL = url
                }
            }
        }
        // 注意: .task 在 View 出现时执行一次
        // 全景球模式需要 LiveKit; 3DGS 纯渲染模式不需要
        // .onChange 监听模式切换，在需要时再连接
        .onChange(of: appModel.renderingMode) {
            if appModel.renderingMode == .panoramaSphere {
                liveKitVM.connect(serverIP: serverIP)
            } else {
                liveKitVM.disconnect()
            }
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
