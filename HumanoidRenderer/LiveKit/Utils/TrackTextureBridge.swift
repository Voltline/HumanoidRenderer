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
internal import Combine
import AVFoundation

@MainActor
final class TrackTextureBridge: NSObject, ObservableObject, VideoRenderer {
    var isAdaptiveStreamEnabled: Bool = false
    
    var adaptiveStreamSize: CGSize = .zero
    
    @Published private(set) var texture: TextureResource?
    
    private let ciContext = CIContext(options: nil)
    private var textureInitialized = false
    
    private var didLogFirstFrame = false
    
    func render(frame: VideoFrame,
                captureDevice: AVCaptureDevice?,
                captureOptions: VideoCaptureOptions?) {
        if !didLogFirstFrame {
            didLogFirstFrame = true
            print("[TrackTextureBridge] first frame arrived!")
        }
        guard let pb = frame.toCVPixelBuffer() else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pb)
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        Task {
            do {
                if !textureInitialized {
                    let tex = try TextureResource(image: cgImage, options: .init(semantic: nil))
                    self.texture = tex
                    self.textureInitialized = true
                } else if let tex = self.texture {
                    try tex.replace(withImage: cgImage, options: TextureResource.CreateOptions(semantic: nil))
                }
            } catch {
                print("[Error]: Texture update failed, \(error)")
            }
        }
    }
}
