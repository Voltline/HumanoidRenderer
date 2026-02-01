//
//  NetUtils.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/10.
//

import Foundation

actor GimbalClient {
    private let baseURL: URL
    private let session: URLSession

    init(serverIP: String) {
        // 确保端口与服务端 Python 代码一致 (30000)
        self.baseURL = URL(string: "http://\(serverIP):30000")!
        let config = URLSessionConfiguration.default
        // 扫描+拼接过程涉及机械运动，建议保持较长的超时时间
        config.timeoutIntervalForRequest = 120.0
        self.session = URLSession(configuration: config)
    }

    // MARK: - 云台控制 API
    func initGimbal() async throws {
        _ = try await send(path: "/init", method: "GET")
    }

    func sendDelta(yaw: Float, pitch: Float) async throws {
        let body: [String: Any] = ["delta_yaw": yaw, "delta_pitch": pitch]
        _ = try await send(path: "/gimbal/delta", method: "POST", body: body)
    }

    // MARK: - 全景扫描 API
    // 修改注释：现在获取的是单张 JPEG 全景图，而非 Atlas 数据包
    func fetchPanorama() async throws -> Data {
        let url = baseURL.appendingPathComponent("/scan/panorama")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // 预留足够时间给服务端进行 7x3 扫描和 cv2.remap 计算
        request.timeoutInterval = 180.0
        
        print("[GimbalClient] 开始请求环境扫描 (等待机械动作)...")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "PanoramaError", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器返回非200状态码"])
        }
        
        print("[GimbalClient] 全景图下载完成，大小: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        return data
    }

    // MARK: - 通用私有方法
    private func send(path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await session.data(for: request)
        // 简单的容错处理，防止空返回崩溃
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
