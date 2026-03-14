//
//  TrackTextureBridge.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/10.
//

import Foundation
import LiveKit
import CoreImage
import CoreVideo
import CoreGraphics
import RealityKit
import AVFoundation
import Metal
import MetalKit
import VideoToolbox
internal import Combine

@MainActor
final class TrackTextureBridge: NSObject, ObservableObject, VideoRenderer {
    // MARK: - VideoRenderer required
    var isAdaptiveStreamEnabled: Bool = false
    var adaptiveStreamSize: CGSize = .zero

    private static let renderBackendDefaultsKey = "renderBackendMode"
    private static let renderSampleTargetCount = 300
    private static let renderProgressLogStep = 60

    // MARK: - Internal state
    private var didLogFirstFrame = false
    private var didWarnLegacyCaptureUnsupported = false
    private var renderLatencySamplesMs: [Double] = []
    private var renderSampleStartAt: Date?
    private var renderSummaryLogged: Bool = false
    private let renderBackendMode: RenderBackendMode
    
    // MARK: - RealityKit Stable Resources
    let leftTexture: TextureResource
    let rightTexture: TextureResource
    
    // MARK: - Metal & LowLevelTexture
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    
    private var leftLowLevel: LowLevelTexture
    private var rightLowLevel: LowLevelTexture
    private let legacyLeftTexture: TextureResource
    private let legacyRightTexture: TextureResource
    
    // MARK: - Init
    override init() {
        let backendRaw = UserDefaults.standard.string(forKey: Self.renderBackendDefaultsKey) ?? ""
        self.renderBackendMode = RenderBackendMode(rawValue: backendRaw) ?? .lowLevelTexture

        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        
        // 加载 Metal Shader
        let library = device.makeDefaultLibrary()!
        let function = library.makeFunction(name: "nvl2ToRgba")!
        self.pipelineState = try! device.makeComputePipelineState(function: function)
        
        // 创建纹理缓存
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        // 初始化 LowLevelTexture
        let desc = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: 1920,
            height: 1080,
            textureUsage: [.shaderRead, .shaderWrite]
        )
        self.leftLowLevel = try! LowLevelTexture(descriptor: desc)
        self.rightLowLevel = try! LowLevelTexture(descriptor: desc)

        let lowLevelLeftTexture = try! TextureResource(from: self.leftLowLevel)
        let lowLevelRightTexture = try! TextureResource(from: self.rightLowLevel)

        let placeholder = Self.makePlaceholderImage(width: 2, height: 2)
        self.legacyLeftTexture = try! TextureResource(
            image: placeholder,
            options: .init(semantic: .color)
        )
        self.legacyRightTexture = try! TextureResource(
            image: placeholder,
            options: .init(semantic: .color)
        )
        
        switch self.renderBackendMode {
        case .lowLevelTexture:
            self.leftTexture = lowLevelLeftTexture
            self.rightTexture = lowLevelRightTexture
        case .legacyVideoToolbox:
            self.leftTexture = self.legacyLeftTexture
            self.rightTexture = self.legacyRightTexture
        }
        
        super.init()

        AppLogger.shared.info(
            "[RenderTest] 当前后端: \(renderBackendMode.title)，自动采样\(Self.renderSampleTargetCount)帧渲染时延"
        )
    }
    
    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        
        if status == kCVReturnSuccess, let cvTexture = cvTexture {
            return CVMetalTextureGetTexture(cvTexture)
        }
        return nil
    }
    
    private func dispatch(encoder: MTLComputeCommandEncoder, targetTexture: MTLTexture) {
        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        
        let groups = MTLSize(
            width: (targetTexture.width + w - 1) / w,
            height: (targetTexture.height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    // MARK: - LiveKit frame callback
    /// 渲染回调，LiveKit 会在后台线程调用此方法
    func render(
        frame: VideoFrame,
        captureDevice: AVCaptureDevice?,
        captureOptions: VideoCaptureOptions?
    ) {
        let renderStartNs = DispatchTime.now().uptimeNanoseconds

        // 尝试获取 PixelBuffer
        guard let pixelBuffer = frame.toCVPixelBuffer() else { return }

        if !didLogFirstFrame {
            didLogFirstFrame = true
            AppLogger.shared.info(
                "[RenderTest] 第一帧到达，口径: \(renderBackendMode.latencyBoundaryDescription)"
            )
        }

        switch renderBackendMode {
        case .lowLevelTexture:
            renderWithLowLevelTexture(pixelBuffer: pixelBuffer, renderStartNs: renderStartNs)
        case .legacyVideoToolbox:
            renderWithLegacyVideoToolbox(pixelBuffer: pixelBuffer, renderStartNs: renderStartNs)
        }
    }

    private func renderWithLowLevelTexture(pixelBuffer: CVPixelBuffer, renderStartNs: UInt64) {
        
        // 映射 Y 和 UV 纹理
        guard let yTexture = makeTexture(from: pixelBuffer, planeIndex: 0, pixelFormat: .r8Unorm),
              let uvTexture = makeTexture(from: pixelBuffer, planeIndex: 1, pixelFormat: .rg8Unorm) else {
            return
        }
        
        // 获取指令缓冲
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // 处理左眼
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(yTexture, index: 0)
            encoder.setTexture(uvTexture, index: 1)
            encoder.setTexture(leftLowLevel.read(), index: 2) // 写入左眼
            
            // 传入归一化偏移量
            var normOffset: Float = 0.0
            encoder.setBytes(&normOffset, length: MemoryLayout<UInt32>.size, index: 0)
            
            dispatch(encoder: encoder, targetTexture: leftLowLevel.read())
            encoder.endEncoding()
        }
        
        // 处理右眼
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(yTexture, index: 0)
            encoder.setTexture(uvTexture, index: 1)
            encoder.setTexture(rightLowLevel.read(), index: 2) // 写入右眼
            var normOffset: Float = 0.5
            encoder.setBytes(&normOffset, length: MemoryLayout<UInt32>.size, index: 0)
            
            dispatch(encoder: encoder, targetTexture: rightLowLevel.read())
            encoder.endEncoding()
        }

        let startNs = renderStartNs
        commandBuffer.addCompletedHandler { [weak self] _ in
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            Task { @MainActor in
                self?.recordRenderLatency(ms: elapsedMs)
            }
        }
        
        // 提交指令，GPU开始工作
        commandBuffer.commit()
    }

    private func renderWithLegacyVideoToolbox(pixelBuffer: CVPixelBuffer, renderStartNs: UInt64) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let fullImage = cgImage else {
            return
        }

        let width = fullImage.width
        let height = fullImage.height
        let halfHeight = height / 2
        guard halfHeight > 0,
              let leftCG = fullImage.cropping(to: CGRect(x: 0, y: 0, width: width, height: halfHeight)),
              let rightCG = fullImage.cropping(to: CGRect(x: 0, y: halfHeight, width: width, height: halfHeight)) else {
            return
        }

        do {
            try legacyLeftTexture.replace(withImage: leftCG, options: .init(semantic: .color))
            try legacyRightTexture.replace(withImage: rightCG, options: .init(semantic: .color))

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - renderStartNs) / 1_000_000.0
            recordRenderLatency(ms: elapsedMs)
        } catch {
            AppLogger.shared.warn("[RenderTest] Legacy纹理更新失败: \(error.localizedDescription)")
        }
    }

    private func recordRenderLatency(ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        guard renderLatencySamplesMs.count < Self.renderSampleTargetCount else { return }

        if renderSampleStartAt == nil {
            renderSampleStartAt = Date()
        }

        renderLatencySamplesMs.append(ms)
        let count = renderLatencySamplesMs.count

        if count == 1 || count % Self.renderProgressLogStep == 0 {
            let meanVal = Self.mean(renderLatencySamplesMs) ?? ms
            let p95Val = Self.percentile(renderLatencySamplesMs, p: 0.95) ?? ms
            AppLogger.shared.perf(
                String(
                    format: "[RenderTest][%@] progress %d/%d | mean=%.2fms P95=%.2fms",
                    renderBackendMode.title,
                    count,
                    Self.renderSampleTargetCount,
                    meanVal,
                    p95Val
                )
            )
        }

        if count == Self.renderSampleTargetCount && !renderSummaryLogged {
            renderSummaryLogged = true
            AppLogger.shared.perf(makeRenderSummary())
        }
    }

    private func makeRenderSummary() -> String {
        let samples = renderLatencySamplesMs
        let count = samples.count
        let meanVal = Self.mean(samples) ?? 0.0
        let p95Val = Self.percentile(samples, p: 0.95) ?? meanVal
        let p99Val = Self.percentile(samples, p: 0.99) ?? p95Val
        let minVal = samples.min() ?? meanVal
        let maxVal = samples.max() ?? meanVal
        let wallSec = renderSampleStartAt.map { Date().timeIntervalSince($0) } ?? 0.0

        return String(
            format: "[RenderTest][%@] DONE N=%d | mean=%.2fms P95=%.2fms P99=%.2fms min=%.2fms max=%.2fms wall=%.1fs",
            renderBackendMode.title,
            count,
            meanVal,
            p95Val,
            p99Val,
            minVal,
            maxVal,
            wallSec
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(p, 0.0), 1.0)
        let idx = min(sorted.count - 1, Int((Double(sorted.count - 1) * clamped).rounded()))
        return sorted[idx]
    }

    private static func makePlaceholderImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 0, count: bytesPerRow * height)
        let provider = CGDataProvider(data: data as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
    
    // 抓取当前左眼画面的静态副本
    func captureLatestFrame() -> MTLTexture? {
        guard renderBackendMode == .lowLevelTexture else {
            if !didWarnLegacyCaptureUnsupported {
                didWarnLegacyCaptureUnsupported = true
                AppLogger.shared.warn("[RenderTest] Legacy后端暂不支持captureLatestFrame")
            }
            return nil
        }

        // 获取当前正在被写入的底层纹理
        let sourceTexture = self.leftLowLevel.read()
        
        // 创建一个新的纹理描述
        let descriptior = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceTexture.pixelFormat,
            width: sourceTexture.width,
            height: sourceTexture.height,
            mipmapped: false
        )
        descriptior.usage = [.shaderRead, .shaderWrite]
        descriptior.storageMode = .private
        
        guard let destinationTexture = device.makeTexture(descriptor: descriptior),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        
        // 执行GPU拷贝
        blitEncoder.copy(from: sourceTexture, to: destinationTexture)
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // 同步等待拷贝完成
        
        return destinationTexture
    }
}
