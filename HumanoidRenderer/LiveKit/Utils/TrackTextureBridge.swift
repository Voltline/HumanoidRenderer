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
import RealityKit
import AVFoundation
import Metal
import MetalKit
internal import Combine

@MainActor
final class TrackTextureBridge: NSObject, ObservableObject, VideoRenderer {
    // MARK: - VideoRenderer required
    var isAdaptiveStreamEnabled: Bool = false
    var adaptiveStreamSize: CGSize = .zero

    // MARK: - Internal state
    private var didLogFirstFrame = false
    
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
    
    // MARK: - Init
    override init() {
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
        
        // 包装为 TextureResource
        self.leftTexture = try! TextureResource(from: self.leftLowLevel)
        self.rightTexture = try! TextureResource(from: self.rightLowLevel)
        
        super.init()
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
        // 尝试获取 PixelBuffer
        guard let pixelBuffer = frame.toCVPixelBuffer() else { return }
        
        let width = 1920
        let height = 2160
        
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
        
        // 提交指令，GPU开始工作
        commandBuffer.commit()
    }
    
    // 抓取当前左眼画面的静态副本
    func captureLatestFrame() -> MTLTexture? {
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
