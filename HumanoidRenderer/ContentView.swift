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
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @AppStorage("serverIP") private var serverIP: String = "localhost"
    @State private var showModifyServerIP: Bool = false
    @State private var showLogPanel: Bool = true
    @State private var logRefreshTick: Int = 0
    @State private var launchingLatencyTest: Bool = false
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

                if appModel.renderingMode == .panoramaSphere {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("时延测试时长: \(Int(appModel.latencyTestDurationSec))s")
                                .font(.caption)
                            Slider(
                                value: Bindable(appModel).latencyTestDurationSec,
                                in: 10...120,
                                step: 5
                            )
                            .disabled(appModel.immersiveSpaceState != .closed || appModel.latencyTestRunning)
                        }

                        if appModel.latencyTestRunning {
                            Text("时延测试进行中，正在采样四项延时...")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if !appModel.latencyTestSummary.isEmpty {
                            Text(appModel.latencyTestSummary)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal)
                }
                
                HStack {
                    Button {
                        showModifyServerIP.toggle()
                    } label: {
                        Text("修改服务器IP")
                    }
                    Button {
                        startLatencyTest()
                    } label: {
                        Text(launchingLatencyTest ? "启动中..." : "开始时延测试")
                    }
                    .disabled(
                        appModel.renderingMode != .panoramaSphere
                        || appModel.immersiveSpaceState != .closed
                        || appModel.latencyTestRunning
                        || launchingLatencyTest
                    )
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

    private func startLatencyTest() {
        Task { @MainActor in
            guard appModel.renderingMode == .panoramaSphere else {
                AppLogger.shared.warn("[MTP] 当前仅支持在全景球模式下启动时延测试")
                return
            }
            guard appModel.immersiveSpaceState == .closed else {
                AppLogger.shared.warn("[MTP] 请先退出沉浸式，再启动时延测试")
                return
            }

            launchingLatencyTest = true
            appModel.latencyTestArmed = true
            appModel.latencyTestSummary = ""
            appModel.phase = .idle
            appModel.immersiveSpaceState = .inTransition

            let result = await openImmersiveSpace(id: appModel.activeSpaceID)
            switch result {
            case .opened:
                AppLogger.shared.info("[MTP] 时延测试已触发，等待沉浸式初始化")
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                appModel.latencyTestArmed = false
                appModel.latencyTestRunning = false
                appModel.immersiveSpaceState = .closed
                AppLogger.shared.warn("[MTP] 时延测试启动失败：沉浸式未成功打开")
            }
            launchingLatencyTest = false
        }
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
