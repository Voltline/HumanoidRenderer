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

    func reportRenderLatencySamples(
        mode: String,
        durationSec: Double,
        samplesMs: [Double],
        meanMs: Double,
        p95Ms: Double,
        p99Ms: Double
    ) async -> Bool {
        guard !samplesMs.isEmpty else {
            AppLogger.shared.warn("[RenderTest] 无可上报样本，跳过上传")
            return false
        }

        let body: [String: Any] = [
            "client_timestamp_unix_ms": Date().timeIntervalSince1970 * 1000.0,
            "mode": mode,
            "duration_sec": durationSec,
            "render_count": samplesMs.count,
            "t_render_mean_ms": meanMs,
            // 渲染对比实验下仅关注渲染项，沿用已有汇总字段方便统一落表。
            "t_mtp_mean_ms": meanMs,
            "t_mtp_p95_ms": p95Ms,
            "raw_sample_count": samplesMs.count,
            "raw_samples": [
                "t_render_ms": samplesMs,
            ],
        ]

        do {
            let result = try await send(path: "/latency/report", method: "POST", body: body)
            let reportId = result["report_id"] as? String ?? "N/A"
            let totalReports = parseDouble(result["total_reports"]).map { Int($0) } ?? 0
            let writtenRaw = parseDouble(result["raw_samples_written"]).map { Int($0) } ?? 0
            let totalRaw = parseDouble(result["total_raw_samples"]).map { Int($0) } ?? 0
            let storagePath = result["db_path"] as? String ?? ""

            AppLogger.shared.info(String(
                format: "[RenderTest] 渲染样本已上报 (id=%@, raw=%d, totalReports=%d, totalRaw=%d, mean=%.2fms, P95=%.2fms, P99=%.2fms)",
                reportId,
                writtenRaw,
                totalReports,
                totalRaw,
                meanMs,
                p95Ms,
                p99Ms
            ))
            if !storagePath.isEmpty {
                AppLogger.shared.info("[RenderTest] 服务端存储: \(storagePath)")
            }
            return true
        } catch {
            AppLogger.shared.warn("[RenderTest] 上报渲染样本失败: \(error.localizedDescription)")
            return false
        }
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

    // MARK: - 3DGS 在线生成 API

    /// 触发 3DGS 生成，返回 job_id
    func startGaussianSplatGeneration(model: String) async throws -> String {
        let body: [String: Any] = ["model": model]
        let result = try await send(path: "/scan/3dgs", method: "POST", body: body)
        guard let jobId = result["job_id"] as? String else {
            throw NSError(domain: "3DGS", code: -1, userInfo: [NSLocalizedDescriptionKey: "未返回 job_id"])
        }
        return jobId
    }

    /// 轮询本地 3DGS 任务状态 (SCANNING → UPLOADING → SUBMITTED / FAILED)
    struct JobStatus {
        let status: String
        let operationId: String?
        let worldId: String?
        let error: String?
    }

    func pollJobStatus(jobId: String) async throws -> JobStatus {
        let result = try await send(path: "/3dgs/job/\(jobId)", method: "GET")
        return JobStatus(
            status: result["status"] as? String ?? "UNKNOWN",
            operationId: result["operation_id"] as? String,
            worldId: result["world_id"] as? String,
            error: result["error"] as? String
        )
    }

    /// 轮询 World Labs 生成进度
    struct OperationStatus {
        let done: Bool
        let progressDescription: String?
        let worldId: String?
        /// 生成完成时，response.assets.splats.spz_urls.full_res
        let fullResSpzUrl: String?
    }

    func pollOperationStatus(operationId: String) async throws -> OperationStatus {
        let result = try await send(path: "/3dgs/operation/\(operationId)", method: "GET")
        let done = result["done"] as? Bool ?? false
        let metadata = result["metadata"] as? [String: Any]
        let progress = metadata?["progress"] as? [String: Any]
        let progressDesc = progress?["description"] as? String
        let worldId = metadata?["world_id"] as? String

        var fullResUrl: String? = nil
        if done, let response = result["response"] as? [String: Any],
           let assets = response["assets"] as? [String: Any],
           let splats = assets["splats"] as? [String: Any],
           let spzUrls = splats["spz_urls"] as? [String: Any] {
            fullResUrl = spzUrls["full_res"] as? String
        }

        return OperationStatus(
            done: done,
            progressDescription: progressDesc,
            worldId: worldId,
            fullResSpzUrl: fullResUrl
        )
    }

    /// 代理下载资产文件 (SPZ)
    func downloadAsset(assetUrl: String) async throws -> Data {
        guard var urlComponents = URLComponents(url: baseURL.appendingPathComponent("/3dgs/asset"), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "3DGS", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 构建失败"])
        }
        urlComponents.queryItems = [URLQueryItem(name: "url", value: assetUrl)]
        guard let url = urlComponents.url else {
            throw NSError(domain: "3DGS", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 构建失败"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300.0 // SPZ 可能较大

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "3DGS", code: -1, userInfo: [NSLocalizedDescriptionKey: "资产下载失败"])
        }
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

    private func parseDouble(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.doubleValue
        }
        return nil
    }
}
