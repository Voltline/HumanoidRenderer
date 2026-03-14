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
    @AppStorage("renderBackendMode") private var renderBackendModeRaw: String = RenderBackendMode.lowLevelTexture.rawValue
    @State private var showModifyServerIP: Bool = false
    @State private var showLogPanel: Bool = true
    @State private var logRefreshTick: Int = 0

    private var renderBackendBinding: Binding<RenderBackendMode> {
        Binding(
            get: {
                RenderBackendMode(rawValue: renderBackendModeRaw) ?? .lowLevelTexture
            },
            set: { newValue in
                renderBackendModeRaw = newValue.rawValue
            }
        )
    }

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

                if appModel.renderingMode == .panoramaSphere {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("渲染后端", selection: renderBackendBinding) {
                            ForEach(RenderBackendMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .disabled(appModel.immersiveSpaceState != .closed)

                        Text("对比实验建议: 手动切换后端后各跑一次，日志会自动输出300帧渲染耗时统计（mean/P95/P99）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                
                // 3DGS 模式下显示模型选择
                if appModel.renderingMode == .gaussianSplat {
                    Picker("生成模型", selection: Bindable(appModel).splatModel) {
                        ForEach(SplatModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .disabled(appModel.immersiveSpaceState != .closed)
                }
                
                switch appModel.phase {
                case .idle:
                    Text("")
                case .initializing:
                    Text("正在将电机复位")
                case .scanning:
                    VStack {
                        if appModel.renderingMode == .gaussianSplat {
                            Text("正在扫描并提交生成任务...")
                        } else {
                            Text("正在扫描")
                        }
                        ProgressView(value: appModel.scanProgress, total: 1)
                            .padding()
                    }
                case .baking:
                    VStack {
                        if appModel.renderingMode == .gaussianSplat {
                            Text("正在生成 3DGS 场景...")
                            if !appModel.generationProgress.isEmpty {
                                Text(appModel.generationProgress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView()
                                .padding(.top, 4)
                        } else {
                            Text("扫描完毕，正在烘焙材质")
                        }
                    }
                case .ready:
                    VStack {
                        if appModel.renderingMode == .gaussianSplat {
                            Text("正在下载并加载场景...")
                            ProgressView()
                                .padding(.top, 4)
                        } else {
                            Text("即将就绪，请稍候")
                                .foregroundStyle(Color.green)
                        }
                    }
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
                    Button {
                        showLogPanel.toggle()
                    } label: {
                        Text(showLogPanel ? "隐藏日志" : "查看日志")
                    }
                }
                
                // MARK: - 日志面板
                if showLogPanel {
                    LogPanelView(refreshTick: logRefreshTick)
                }
            }
            .padding()
        }
        .alert("输入新的服务器IP", isPresented: $showModifyServerIP) {
            VStack {
                TextField("例如: 192.168.31.100", text: $serverIP)
            }
        }
        // 注意: .task 在 View 出现时执行一次
        // 两种模式都需要 LiveKit 视频流
        .onChange(of: appModel.renderingMode) {
            liveKitVM.connect(serverIP: serverIP)
        }
        .onAppear {
            AppLogger.shared.onChange = { [self] in
                logRefreshTick += 1
            }
            liveKitVM.connect(serverIP: serverIP)
        }
        .padding()
    }
}

// MARK: - 日志面板
struct LogPanelView: View {
    let refreshTick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("📋 应用日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    AppLogger.shared.clear()
                }
                .font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(AppLogger.shared.entries) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(colorFor(entry.level))
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: refreshTick) {
                    if let last = AppLogger.shared.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func colorFor(_ level: AppLogger.Entry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .yellow
        case .error: return .red
        case .perf: return .cyan
        }
    }
}

#Preview {
    let appModel = AppModel()
    var liveKitVM = LiveKitViewModel(appModel: appModel)
    ContentView()
        .environment(appModel)
        .environmentObject(liveKitVM)
}
