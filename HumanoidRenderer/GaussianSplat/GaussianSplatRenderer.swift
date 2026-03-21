//
//  GaussianSplatRenderer.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/4.
//
//  基于 CompositorServices 的 3D Gaussian Splatting 背景渲染器。
//  参考 MetalSplatter SampleApp 的 VisionSceneRenderer 编写。
//  负责：
//    1. 加载并渲染 .ply/.splat/.spz 格式的 3DGS 场景作为沉浸式背景
//    2. 在前景绘制头部锁定的立体视频 quad
//    3. 头部追踪 → 云台跟随
//

import CompositorServices
import Metal
import MetalSplatter
import SplatIO
import ARKit
import simd
import os
import LiveKit
import AVFoundation
import CoreVideo

// MARK: - 渲染器视口描述 (与 MetalSplatter 的 ViewportDescriptor 对应)
struct SplatViewportDescriptor {
    var viewport: MTLViewport
    var projectionMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var screenSize: SIMD2<Int>
}

// MARK: - VideoQuad Uniforms (与 Metal shader 对齐)
struct VideoQuadUniforms {
    var modelViewProjection: (simd_float4x4, simd_float4x4) = (matrix_identity_float4x4, matrix_identity_float4x4)
}

// MARK: - GaussianSplatRenderer
final class GaussianSplatRenderer: @unchecked Sendable {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "GaussianSplatRenderer"
    )
    
    private static let maxSimultaneousRenders = 3
    
    // MARK: Metal 核心对象
    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    // MARK: 3DGS 渲染
    private var splatRenderer: SplatRenderer?
    
    // MARK: 视频 Quad 渲染管线
    private var videoQuadPipelineState: MTLRenderPipelineState?
    
    // MARK: 视频纹理桥接
    private let videoBridge: GaussianSplatVideoBridge
    
    // MARK: ARKit
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    
    // MARK: 头部追踪 → 云台跟随
    private var gimbalClient: GimbalClient?
    private var lastYaw: Float = 0.0
    private var lastPitch: Float = 0.0
    private var hasBaseline: Bool = false
    private var headTrackingTask: Task<Void, Never>?
    
    // MARK: 并发控制
    let inFlightSemaphore: DispatchSemaphore
    
    // MARK: 视频轨道
    private var boundTrack: VideoTrack?
    
    // MARK: AppModel 引用
    private var appModel: AppModel?
    
    // MARK: 服务器 IP
    private let serverIP: String
    
    init(_ layerRenderer: LayerRenderer, serverIP: String) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = device.makeCommandQueue()!
        self.serverIP = serverIP
        
        self.worldTracking = WorldTrackingProvider()
        self.arSession = ARKitSession()
        
        self.inFlightSemaphore = DispatchSemaphore(value: Self.maxSimultaneousRenders)
        
        self.videoBridge = GaussianSplatVideoBridge(device: device)
        
        buildVideoQuadPipeline()
    }
    
    // MARK: - 静态入口
    nonisolated static func startRendering(
        _ layerRenderer: LayerRenderer,
        appModel: AppModel?,
        serverIP: String
    ) {
        let renderer = GaussianSplatRenderer(layerRenderer, serverIP: serverIP)
        renderer.appModel = appModel
        
        // 必须使用 Task.detached 断开 @MainActor 继承
        // CompositorLayer 在 App.body 中构建，body 是 @MainActor，
        // 普通 Task {} 会继承 @MainActor 导致加载和渲染调度
        // 在主线程执行，阻塞 UI 交互
        Task.detached(priority: .userInitiated) {
            // 在线生成 3DGS 场景
            await renderer.runOnlineGenerationPipeline()
            
            // 启动渲染循环
            await AppLogger.shared.info("[3DGS] 启动渲染循环")
            await renderer.startRenderLoop()
        }
    }
    
    // MARK: - 在线 3DGS 生成流水线
    private func runOnlineGenerationPipeline() async {
        guard let appModel else {
            AppLogger.shared.warn("[3DGS] AppModel 不可用，跳过在线生成")
            return
        }
        
        let client = GimbalClient(serverIP: serverIP)
        let model = await appModel.splatModel.apiValue
        
        do {
            // 云台复位
            await MainActor.run { appModel.phase = .initializing }
            AppLogger.shared.info("[3DGS] 云台复位中...")
            try await client.initGimbal()
            
            // 触发扫描 + 等待提交 (复用 scanning 状态)
            await MainActor.run { appModel.phase = .scanning }
            AppLogger.shared.info("[3DGS] 触发 4 帧扫描任务 (model=\(model))...")
            let jobId = try await client.startGaussianSplatGeneration(model: model)
            AppLogger.shared.info("[3DGS] 任务已创建: \(jobId.prefix(8))...")
            
            // 轮询本地 job 状态 (1.5s 间隔)
            var operationId: String?
            while true {
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                let job = try await client.pollJobStatus(jobId: jobId)
                
                switch job.status {
                case "SUBMITTED":
                    operationId = job.operationId
                    AppLogger.shared.info("[3DGS] 扫描完成，已提交 World Labs 生成")
                case "FAILED":
                    AppLogger.shared.error("[3DGS] 任务失败: \(job.error ?? "未知错误")")
                    await MainActor.run { appModel.phase = .idle }
                    return
                case "SCANNING":
                    await MainActor.run { appModel.generationProgress = "正在扫描环境..." }
                case "UPLOADING":
                    await MainActor.run { appModel.generationProgress = "正在上传图片..." }
                default:
                    break
                }
                
                if operationId != nil { break }
            }
            
            guard let opId = operationId else { return }
            
            // 轮询 World Labs 生成进度
            await MainActor.run {
                appModel.phase = .baking
                appModel.generationProgress = "等待 World Labs 生成..."
            }
            AppLogger.shared.info("[3DGS] 开始轮询生成进度 (operation=\(opId.prefix(16))...)")
            
            var fullResUrl: String?
            while true {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                let op = try await client.pollOperationStatus(operationId: opId)
                
                if let desc = op.progressDescription {
                    await MainActor.run { appModel.generationProgress = desc }
                    AppLogger.shared.info("[3DGS] 进度: \(desc)")
                }
                
                if op.done {
                    fullResUrl = op.fullResSpzUrl
                    AppLogger.shared.info("[3DGS] 生成完成!")
                    break
                }
            }
            
            guard let spzUrl = fullResUrl else {
                AppLogger.shared.error("[3DGS] 生成完成但未获取到 SPZ 下载链接")
                await MainActor.run { appModel.phase = .idle }
                return
            }
            
            // 下载 SPZ + 加载渲染器
            await MainActor.run {
                appModel.phase = .ready
                appModel.generationProgress = ""
            }
            AppLogger.shared.info("[3DGS] 开始下载 SPZ (full_res)...")
            
            let spzData = try await client.downloadAsset(assetUrl: spzUrl)
            AppLogger.shared.info("[3DGS] SPZ 下载完成: \(ByteCountFormatter.string(fromByteCount: Int64(spzData.count), countStyle: .file))")
            
            // 写入临时文件
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("generated_scene.spz")
            try spzData.write(to: tempFile)
            
            // 加载到渲染器
            let loadStart = CFAbsoluteTimeGetCurrent()
            try await loadSplatScene(url: tempFile)
            let elapsed = CFAbsoluteTimeGetCurrent() - loadStart
            AppLogger.shared.perf("[3DGS] 场景加载完成，耗时 \(String(format: "%.2f", elapsed))s")
            
            // 云台归位 → 进入 live
            AppLogger.shared.info("[3DGS] 云台归位...")
            try await client.initGimbal()
            
            await MainActor.run {
                appModel.phase = .live
            }
            AppLogger.shared.info("[3DGS] 已进入实时跟随模式")
            
        } catch {
            AppLogger.shared.error("[3DGS] 在线生成流水线出错: \(error.localizedDescription)")
            await MainActor.run { appModel.phase = .idle }
        }
    }
    
    // MARK: - 加载 3DGS 场景
    func loadSplatScene(url: URL) async throws {
        AppLogger.shared.info("[3DGS] 开始加载 3DGS 场景: \(url.lastPathComponent)")
        
        var t0 = CFAbsoluteTimeGetCurrent()
        let splat = try SplatRenderer(
            device: device,
            colorFormat: layerRenderer.configuration.colorFormat,
            depthFormat: layerRenderer.configuration.depthFormat,
            sampleCount: 1,
            maxViewCount: layerRenderer.properties.viewCount,
            maxSimultaneousRenders: Self.maxSimultaneousRenders
        )
        AppLogger.shared.perf("[3DGS] SplatRenderer 创建: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        
        t0 = CFAbsoluteTimeGetCurrent()
        let reader = try AutodetectSceneReader(url)
        let points = try await reader.readAll()
        AppLogger.shared.perf("[3DGS] 读取点云 (\(points.count) 点): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        
        t0 = CFAbsoluteTimeGetCurrent()
        let chunk = try SplatChunk(device: device, from: points)
        AppLogger.shared.perf("[3DGS] SplatChunk 创建: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        
        t0 = CFAbsoluteTimeGetCurrent()
        await splat.addChunk(chunk)
        AppLogger.shared.perf("[3DGS] addChunk (排序): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        
        self.splatRenderer = splat
        AppLogger.shared.info("3DGS 场景加载完成，共 \(points.count) 个 splat")
    }
    
    // MARK: - 构建视频 Quad 管线
    private func buildVideoQuadPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            AppLogger.shared.error("无法获取默认 Metal 库")
            return
        }
        
        guard let vertexFunc = library.makeFunction(name: "videoQuadVertexShader"),
              let fragmentFunc = library.makeFunction(name: "videoQuadFragmentShader") else {
            AppLogger.shared.error("无法找到视频 Quad 着色器")
            return
        }
        
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        if layerRenderer.configuration.layout == .layered {
            desc.inputPrimitiveTopology = .triangle
            desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        }
        desc.rasterSampleCount = 1
        
        do {
            videoQuadPipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            AppLogger.shared.error("构建视频 Quad 管线失败: \(error)")
        }
    }
    
    // MARK: - 视频轨道绑定
    private func bindVideoTrack(_ track: VideoTrack?) {
        if let old = boundTrack {
            old.remove(videoRenderer: videoBridge)
        }
        if let t = track {
            t.add(videoRenderer: videoBridge)
        }
        boundTrack = track
    }
    
    // MARK: - 渲染循环
    func startRenderLoop() {
        // 使用 GCD 直接在专用渲染队列上运行，
        // 避免 Swift Task 的 actor 继承和 executor 偏好不确定性
        let renderQueue = DispatchQueue(label: "GaussianSplatRenderQueue", qos: .userInteractive)
        renderQueue.async { [self] in
            
            // ARKit 会话需要通过 Task 启动（async API）
            let arReady = DispatchSemaphore(value: 0)
            Task.detached { [self] in
                do {
                    try await self.arSession.run([self.worldTracking])
                } catch {
                    await AppLogger.shared.error("[3DGS] ARKit 启动失败: \(error.localizedDescription)")
                }
                arReady.signal()
            }
            arReady.wait()
            
            // 初始化云台
            let client = GimbalClient(serverIP: self.serverIP)
            self.gimbalClient = client
            
            // 启动独立的头部追踪任务 (20Hz，与全景球模式一致)
            self.startHeadTrackingLoop()
            
            self.renderLoop()
            
            // 渲染循环退出后，主动清理所有资源
            self.cleanup()
        }
    }
    
    private func renderLoop() {
        while true {
            autoreleasepool {
                if layerRenderer.state == .invalidated {
                    AppLogger.shared.warn("LayerRenderer 已失效")
                    return
                } else if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    return
                } else {
                    renderFrame()
                }
            }
            if layerRenderer.state == .invalidated {
                return
            }
        }
    }
    
    // MARK: - 单帧渲染
    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        updateVideoTrackBinding()
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }
        
        // 如果 splat 渲染器还没准备好，仅提交空帧
        guard let splatRenderer, splatRenderer.isReadyToRender else {
            frame.startSubmission()
            for drawable in drawables {
                guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
            }
            frame.endSubmission()
            return
        }
        
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        
        frame.startSubmission()
        
        let primaryDrawable = drawables[0]
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: primaryDrawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        
        let layered = layerRenderer.configuration.layout == .layered
        
        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
            
            drawable.deviceAnchor = deviceAnchor
            
            if index == drawables.count - 1 {
                let semaphore = inFlightSemaphore
                commandBuffer.addCompletedHandler { _ in
                    semaphore.signal()
                }
            }
            
            let viewports = buildViewports(drawable: drawable, deviceAnchor: deviceAnchor)
            
            // 渲染 3DGS 背景
            do {
                let msViewports = viewports.map { vp in
                    SplatRenderer.ViewportDescriptor(
                        viewport: vp.viewport,
                        projectionMatrix: vp.projectionMatrix,
                        viewMatrix: vp.viewMatrix,
                        screenSize: vp.screenSize
                    )
                }
                
                try splatRenderer.render(
                    viewports: msViewports,
                    colorTexture: drawable.colorTextures[0],
                    colorStoreAction: .store,
                    depthTexture: drawable.depthTextures[0],
                    rasterizationRateMap: drawable.rasterizationRateMaps.first,
                    renderTargetArrayLength: layered ? drawable.views.count : 1,
                    to: commandBuffer
                )
            } catch {
                AppLogger.shared.error("3DGS 渲染失败: \(error.localizedDescription)")
            }
            
            // 叠加头部锁定的立体视频 Quad
            if videoBridge.hasTexture, let pipelineState = videoQuadPipelineState {
                renderVideoQuad(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    pipelineState: pipelineState,
                    layered: layered
                )
            }
            
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
        
        frame.endSubmission()
    }
    
    // MARK: - 构建视口
    private func buildViewports(
        drawable: LayerRenderer.Drawable,
        deviceAnchor: DeviceAnchor?
    ) -> [SplatViewportDescriptor] {
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // 将视点下移到场景内部
        // 如果场景原点在地面附近，用户的 ARKit 头部高度 ~1.7m 会导致视角浮在上方
        let sceneOffset = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1.5, 0, 1)  // Y 方向上移 1.5m
        )
        
        return drawable.views.enumerated().map { (index, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            let screenSize = SIMD2(
                x: Int(view.textureMap.viewport.width),
                y: Int(view.textureMap.viewport.height)
            )
            
            return SplatViewportDescriptor(
                viewport: view.textureMap.viewport,
                projectionMatrix: projectionMatrix,
                viewMatrix: userViewpointMatrix * sceneOffset,
                screenSize: screenSize
            )
        }
    }
    
    // MARK: - 渲染头部锁定的立体视频 Quad
    private func renderVideoQuad(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        pipelineState: MTLRenderPipelineState,
        layered: Bool
    ) {
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDesc.colorAttachments[0].loadAction = .load
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDesc.depthAttachment.loadAction = .load
        renderPassDesc.depthAttachment.storeAction = .store
        
        if layered {
            renderPassDesc.renderTargetArrayLength = drawable.views.count
        }
        
        if let rasterizationRateMap = drawable.rasterizationRateMaps.first {
            renderPassDesc.rasterizationRateMap = rasterizationRateMap
        }
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        
        var uniforms = VideoQuadUniforms()
        for (i, view) in drawable.views.prefix(2).enumerated() {
            let eyeViewMatrix = view.transform.inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: i)
            let mvp = projectionMatrix * eyeViewMatrix
            if i == 0 { uniforms.modelViewProjection.0 = mvp }
            else { uniforms.modelViewProjection.1 = mvp }
        }
        
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoQuadUniforms>.size, index: 0)
        
        if let leftTex = videoBridge.currentTexture {
            encoder.setFragmentTexture(leftTex, index: 0)
        }
        if let rightTex = videoBridge.rightTexture {
            encoder.setFragmentTexture(rightTex, index: 1)
        }
        
        if layered {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: 0  // shader 已通过 ampID 设置 renderTargetArrayIndex
                )
            }
            encoder.setVertexAmplificationCount(drawable.views.count, viewMappings: &viewMappings)
        }
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        encoder.setViewports(viewports)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
    
    // MARK: - 视频轨道绑定更新
    private func updateVideoTrackBinding() {
        guard let appModel else { return }
        let newTrack = appModel.remoteVideoTrack
        if boundTrack !== newTrack {
            bindVideoTrack(newTrack)
        }
    }
    
    // MARK: - 头部追踪循环 (20Hz)
    private func startHeadTrackingLoop() {
        headTrackingTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                
                // 只在 live 阶段执行
                let phase = await self.appModel?.phase
                if phase == .live {
                    let time = CACurrentMediaTime()
                    if let anchor = self.worldTracking.queryDeviceAnchor(atTimestamp: time) {
                        let quat = simd_quatf(anchor.originFromAnchorTransform)
                        let euler = quat.toEulerAngles()
                        
                        if !self.hasBaseline {
                            self.lastYaw = euler.y
                            self.lastPitch = euler.x
                            self.hasBaseline = true
                        } else {
                            let deltaYaw = euler.y - self.lastYaw
                            let deltaPitch = euler.x - self.lastPitch
                            
                            // 突变过滤
                            if abs(deltaYaw) > 0.78 || abs(deltaPitch) > 0.78 {
                                self.lastYaw = euler.y
                                self.lastPitch = euler.x
                            } else {
                                self.lastYaw = euler.y
                                self.lastPitch = euler.x
                                try? await self.gimbalClient?.sendDelta(yaw: deltaYaw, pitch: -deltaPitch)
                            }
                        }
                    }
                }
                
                // 50ms 间隔 = 20Hz，与全景球模式一致
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    
    // MARK: - 头部追踪 → 云台跟随 (已移至独立循环)
    
    // MARK: - 资源清理 (渲染循环退出时调用)
    private func cleanup() {
        AppLogger.shared.info("[3DGS] 开始资源清理")
        
        headTrackingTask?.cancel()
        headTrackingTask = nil
        bindVideoTrack(nil)
        
        // 等待所有command buffer完成
        for _ in 0..<Self.maxSimultaneousRenders {
            inFlightSemaphore.wait()
        }
        // 立即释放回去，避免影响后续流程
        for _ in 0..<Self.maxSimultaneousRenders {
            inFlightSemaphore.signal()
        }
        
        // 清理 videoBridge GPU 资源
        videoBridge.cleanup()
        
        // 释放 3DGS 渲染器
        splatRenderer = nil
        
        // 停止 ARKit 会话
        arSession.stop()
        
        // 清除引用
        gimbalClient = nil
        appModel = nil
        
        AppLogger.shared.info("[3DGS] 资源清理完成")
    }
}
