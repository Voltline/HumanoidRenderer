//
//  Timer.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2025/12/8.
//

import Foundation
import RealityKit
import Observation
import QuartzCore

// 这是一个每帧都会更新的观察对象
@Observable
class FrameUpdater {
    var tick: Int = 0 // 持续增加的计数器
    private var displayLink: CADisplayLink?

    init() {
        start()
    }

    private func start() {
        // CADisplayLink 在屏幕刷新时调用目标方法
        let displayLink = CADisplayLink(target: self, selector: #selector(updateTick))
        // 确保它被添加到主 run loop
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func updateTick() {
        // 每帧递增计数器
        tick += 1
    }

    deinit {
        displayLink?.invalidate()
    }
}
