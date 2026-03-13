//
//  ImmersiveView.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/11/27.
//

import SwiftUI
import ARKit
import RealityKit
import RealityKitContent
import LiveKit
internal import Combine

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel: AppModel
    
    @StateObject private var bridge = TrackTextureBridge()
    // MARK: - 统一后的组件
    @State private var gimbalClient: GimbalClient?
    
    // MARK: - 背景资源
    @State private var patchEntity: ModelEntity?
    @State private var stereoMaterial: ShaderGraphMaterial?
    @State private var boundTrack: VideoTrack?
    
    @State private var lastYaw: Float = 0.0
    @State private var lastPitch: Float = 0.0
    @State private var hasBaseline: Bool = false
    @State private var latencyTestTask: Task<Void, Never>?
    
    @AppStorage("serverIP") private var serverIP: String = "192.168.31.247"
    
    var body: some View {
        RealityView { content in
            // MARK: 设置背景阵列
            let backgroundRoot = Entity()
            backgroundRoot.name = "BackgroundRoot"
            content.add(backgroundRoot)
            
            // 调用管理器构建球体
            BackgroundManager.buildRig(root: backgroundRoot)

            // MARK: - 前景透镜平面
            setupLensPlane(content)

            // MARK: - 头动采样与过滤
            var lastSampleTime = Date()
            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                let now = Date()
                if now.timeIntervalSince(lastSampleTime) < 0.05 { return }
                lastSampleTime = now
                
                // 执行跟随
                if appModel.phase == .live {
                    headPosTransformAndPost()
                }
            }
        } update: { _ in
            handleVideoTrackUpdate()
        }
        .onAppear {
            // 初始化组件
            let client = GimbalClient(serverIP: serverIP)
            self.gimbalClient = client
        }
        .onDisappear {
            latencyTestTask?.cancel()
            latencyTestTask = nil
            Task {
                await gimbalClient?.setLatencyVideoStamp(enabled: false)
                await finishLatencyTestIfNeeded(reason: "沉浸式退出")
            }
        }
        .task {
            await startAutomatedWorkflow()
        }
    }
    
    // MARK: - 自动化全流程
    func startAutomatedWorkflow() async {
        do {
            let runLatencyTest = appModel.latencyTestArmed
            if runLatencyTest {
                appModel.latencyTestArmed = false
                appModel.latencyTestSummary = ""
            } else {
                await gimbalClient?.setLatencyVideoStamp(enabled: false)
            }

            // 第一步 云台复位
            appModel.phase = .initializing
            AppLogger.shared.info("[全景球] 云台复位中...")
            try await gimbalClient?.initGimbal()

            if runLatencyTest {
                appModel.phase = .ready
                self.hasBaseline = false
                await gimbalClient?.setLatencyVideoStamp(enabled: true)
                await LatencyMetrics.shared.startSession()
                appModel.latencyTestRunning = true
                appModel.phase = .live
                await HeadTracker.shared.startTracking()
                AppLogger.shared.info("[MTP] 测试模式已启动：跳过背景生成，仅采集实时窗口时延")
                startLatencyTestCountdown()
                return
            }
            
            // 第二步 请求服务端扫描
            appModel.phase = .scanning
            AppLogger.shared.info("[全景球] 请求服务端扫描全景图集...")
            
            guard let panoData = try await gimbalClient?.fetchPanorama() else {
                AppLogger.shared.error("[全景球] 获取全景图失败")
                return
            }
            AppLogger.shared.info("[全景球] 全景图下载完成 (\(panoData.count / 1024) KB)")
            
            // 第三步 切片并应用纹理
            appModel.phase = .baking
            AppLogger.shared.info("[全景球] 正在烘焙纹理...")
            
            await MainActor.run {
                BackgroundManager.updatePanorama(imageData: panoData)
            }
            
            // 第四步 云台归位
            appModel.phase = .ready
            AppLogger.shared.info("[全景球] 云台归位...")
            try await gimbalClient?.initGimbal()
            
            // 第五步 开始实时跟随
            self.hasBaseline = false
            appModel.phase = .live
            await HeadTracker.shared.startTracking()
            
            AppLogger.shared.info("[全景球] 已进入实时跟随模式")
        } catch {
            AppLogger.shared.error("[全景球] 流水线出错: \(error.localizedDescription)")
        }
    }

    private func startLatencyTestCountdown() {
        latencyTestTask?.cancel()
        let durationSec = max(1.0, appModel.latencyTestDurationSec)
        let durationNs = UInt64(durationSec * 1_000_000_000.0)

        latencyTestTask = Task {
            try? await Task.sleep(nanoseconds: durationNs)
            await finishLatencyTestIfNeeded(reason: "固定时长结束")
        }
    }

    private func finishLatencyTestIfNeeded(reason: String) async {
        guard let summary = await LatencyMetrics.shared.endSession() else { return }

        await gimbalClient?.setLatencyVideoStamp(enabled: false)

        latencyTestTask?.cancel()
        latencyTestTask = nil

        await MainActor.run {
            appModel.latencyTestRunning = false
            appModel.latencyTestSummary = summary.compactDisplayText()
        }

        AppLogger.shared.perf(summary.oneLine())
        AppLogger.shared.info("[MTP] 测试结束原因: \(reason)")
    }

    // MARK: - 核心：突变过滤处理
    private func headPosTransformAndPost() {
        Task {
            let transform = await HeadTracker.shared.currentHeadTransform()
            let quat = simd_quatf(transform)
            let euler = quat.toEulerAngles()
            
            // 1. 初次基准建立
            if !hasBaseline {
                self.lastYaw = euler.y
                self.lastPitch = euler.x
                self.hasBaseline = true
                return
            }
            
            let deltaYaw = euler.y - self.lastYaw
            let deltaPitch = euler.x - self.lastPitch
            
            // 2. 突变过滤：如果单帧跳变超过 45度(0.78rad)，判定为 ARKit 坐标修正
            // 此时只更新基准，不向服务端发送指令
            if abs(deltaYaw) > 0.78 || abs(deltaPitch) > 0.78 {
                print("[Sensor] Mutation detected, re-baselining...")
                self.lastYaw = euler.y
                self.lastPitch = euler.x
                return
            }
            
            // 3. 正常发送增量
            self.lastYaw = euler.y
            self.lastPitch = euler.x
            
            // 使用统一后的 client 发送
            try? await gimbalClient?.sendDelta(yaw: deltaYaw, pitch: -deltaPitch)
        }
    }
    
    // MARK: - 透镜平面构建 (主视觉层)
    private func setupLensPlane(_ content: RealityViewContent) {
        let headAnchor = AnchorEntity(.head)
        headAnchor.name = "headAnchor"

        // 视频平面放置在 3m 处，角张角 ~65°H × 39°V (舒适观影距离)
        // half_w = 3.0 * tan(32.5°) ≈ 1.911,  half_h = half_w * 9/16 ≈ 1.075
        // width  = 3.822,  height = 2.150
        let planeMesh = MeshResource.generatePlane(width: 3.822, height: 2.150)
        let patch = ModelEntity(mesh: planeMesh, materials: [UnlitMaterial(color: .black)])
        patch.name = "patch"
        patch.position = [0, 0, -3] // 放置在前方 3 米

        headAnchor.addChild(patch)
        content.add(headAnchor)
        
        self.patchEntity = patch
        
        // 紧接着异步加载 ShaderGraph 材质
        loadAndBindMaterial(patch: patch)
    }

    // MARK: - 材质加载与绑定 (ShaderGraph)
    private func loadAndBindMaterial(patch: ModelEntity) {
        Task {
            do {
                let mat = try await ShaderGraphMaterial(
                    named: "/Root/StereoVideoMaterial",
                    from: "Immersive.usda",
                    in: realityKitContentBundle
                )
                
                await MainActor.run {
                    var finalMat = mat
                    finalMat.faceCulling = .none
                    
                    do {
                        // 核心：将 bridge 里的 LowLevelTexture 引用绑定到 ShaderGraph 的输入口
                        try finalMat.setParameter(name: "LeftImage", value: .textureResource(bridge.leftTexture))
                        try finalMat.setParameter(name: "RightImage", value: .textureResource(bridge.rightTexture))
                        
                        if var model = patch.model {
                            model.materials = [finalMat]
                            patch.model = model
                        }
                        self.stereoMaterial = finalMat
                        print("[RealityKit] ShaderGraphMaterial bound to LowLevelTexture.")
                    } catch {
                        print("[Error] Parameter binding failed: \(error)")
                    }
                }
            } catch {
                print("[Error] Failed to load ShaderGraphMaterial: \(error)")
            }
        }
    }
    // MARK: - 视频流动态绑定处理
    private func handleVideoTrackUpdate() {
        let newTrack = appModel.remoteVideoTrack

        // 如果轨道发生变更
        if boundTrack !== newTrack {
            if let old = boundTrack {
                old.remove(videoRenderer: bridge)
                print("[LiveKit] Old track removed from bridge.")
            }
            if let t = newTrack {
                t.add(videoRenderer: bridge)
                print("[LiveKit] New track added to bridge.")
            }
            // 确保在主线程更新状态
            Task { @MainActor in
                self.boundTrack = newTrack
            }
        }
    }
}
