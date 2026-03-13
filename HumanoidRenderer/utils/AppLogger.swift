//
//  AppLogger.swift
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/5.
//
//  应用内日志系统，支持在 UI 面板中实时查看日志。
//  线程安全，可从任意线程调用。
//

import Foundation

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        enum Level: String {
            case info = "ℹ️"
            case warn = "⚠️"
            case error = "❌"
            case perf = "⏱️"
        }

        var formatted: String {
            let tf = Self.formatter
            return "\(tf.string(from: timestamp)) \(level.rawValue) \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []
    private static let maxEntries = 200

    /// 回调：主线程上通知 UI 刷新（由 View 设置）
    @MainActor var onChange: (() -> Void)?

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func info(_ message: String) { append(.info, message) }
    func warn(_ message: String) { append(.warn, message) }
    func error(_ message: String) { append(.error, message) }
    func perf(_ message: String) { append(.perf, message) }

    func clear() {
        lock.lock()
        _entries.removeAll()
        lock.unlock()
        notifyChange()
    }

    private func append(_ level: Entry.Level, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        lock.lock()
        _entries.append(entry)
        if _entries.count > Self.maxEntries {
            _entries.removeFirst(_entries.count - Self.maxEntries)
        }
        lock.unlock()
        notifyChange()
    }

    private func notifyChange() {
        Task { @MainActor in
            onChange?()
        }
    }
}

actor LatencyMetrics {
    static let shared = LatencyMetrics()

    struct Summary: Sendable {
        let durationSec: Double
        let cmdCount: Int
        let mechCount: Int
        let videoCount: Int
        let renderCount: Int
        let tCmdMean: Double
        let tMechMean: Double
        let tVideoMean: Double
        let tRenderMean: Double
        let tMtpMean: Double
        let tMtpP95: Double

        func oneLine() -> String {
            String(
                format: "[MTP] TEST DONE %.1fs | N(cmd/mech/video/r)=%d/%d/%d/%d | mean(ms) %.2f/%.2f/%.2f/%.2f => %.2f | P95≈%.2f",
                durationSec,
                cmdCount,
                mechCount,
                videoCount,
                renderCount,
                tCmdMean,
                tMechMean,
                tVideoMean,
                tRenderMean,
                tMtpMean,
                tMtpP95
            )
        }

        func compactDisplayText() -> String {
            String(
                format: "时延测试完成(%.1fs)\n样本 N(cmd/mech/video/r): %d/%d/%d/%d\nmean(ms): cmd=%.2f mech=%.2f video=%.2f render=%.2f\nMTP≈%.2f ms, P95≈%.2f ms",
                durationSec,
                cmdCount,
                mechCount,
                videoCount,
                renderCount,
                tCmdMean,
                tMechMean,
                tVideoMean,
                tRenderMean,
                tMtpMean,
                tMtpP95
            )
        }

        func reportPayload(mode: String = "panorama") -> [String: Any] {
            [
                "client_timestamp_unix_ms": Date().timeIntervalSince1970 * 1000.0,
                "mode": mode,
                "duration_sec": durationSec,
                "cmd_count": cmdCount,
                "mech_count": mechCount,
                "video_count": videoCount,
                "render_count": renderCount,
                "t_cmd_mean_ms": tCmdMean,
                "t_mech_mean_ms": tMechMean,
                "t_video_mean_ms": tVideoMean,
                "t_render_mean_ms": tRenderMean,
                "t_mtp_mean_ms": tMtpMean,
                "t_mtp_p95_ms": tMtpP95,
            ]
        }
    }

    struct RawSamples: Sendable {
        let tCmdUpMs: [Double]
        let tMechMs: [Double]
        let tVideoDownMs: [Double]
        let tRenderMs: [Double]
        let tMtpApproxMs: [Double]

        var totalCount: Int {
            max(
                tCmdUpMs.count,
                tMechMs.count,
                tVideoDownMs.count,
                tRenderMs.count,
                tMtpApproxMs.count
            )
        }

        func payload() -> [String: Any] {
            [
                "t_cmd_up_ms": tCmdUpMs,
                "t_mech_ms": tMechMs,
                "t_video_down_ms": tVideoDownMs,
                "t_render_ms": tRenderMs,
                "t_mtp_approx_ms": tMtpApproxMs,
            ]
        }
    }

    private var renderSamplesMs: [Double] = []
    private var cmdUpSamplesMs: [Double] = []
    private var mechSamplesMs: [Double] = []
    private var videoDownSamplesMs: [Double] = []
    private var serverClockOffsetMs: Double?
    private var hasDirectVideoDownSamples: Bool = false

    private let maxSamples = 300
    private let summaryIntervalNs: UInt64 = 3_000_000_000
    private var lastSummaryNs: UInt64 = 0
    private var sessionStartNs: UInt64?
    private var sessionRunning: Bool = false

    func startSession() {
        renderSamplesMs.removeAll(keepingCapacity: true)
        cmdUpSamplesMs.removeAll(keepingCapacity: true)
        mechSamplesMs.removeAll(keepingCapacity: true)
        videoDownSamplesMs.removeAll(keepingCapacity: true)
        serverClockOffsetMs = nil
        hasDirectVideoDownSamples = false
        lastSummaryNs = 0
        sessionStartNs = DispatchTime.now().uptimeNanoseconds
        sessionRunning = true
        AppLogger.shared.info("[MTP] 测试会话开始采样")
    }

    func endSession() -> Summary? {
        guard sessionRunning else { return nil }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let durationSec: Double
        if let sessionStartNs {
            durationSec = Double(nowNs - sessionStartNs) / 1_000_000_000.0
        } else {
            durationSec = 0.0
        }
        sessionRunning = false
        sessionStartNs = nil
        return makeSummary(durationSec: durationSec)
    }

    func snapshotRawSamples() -> RawSamples {
        let mtpCount = min(
            cmdUpSamplesMs.count,
            mechSamplesMs.count,
            videoDownSamplesMs.count,
            renderSamplesMs.count
        )

        var mtpApproxSamplesMs: [Double] = []
        mtpApproxSamplesMs.reserveCapacity(mtpCount)
        if mtpCount > 0 {
            for index in 0..<mtpCount {
                mtpApproxSamplesMs.append(
                    cmdUpSamplesMs[index]
                        + mechSamplesMs[index]
                        + videoDownSamplesMs[index]
                        + renderSamplesMs[index]
                )
            }
        }

        return RawSamples(
            tCmdUpMs: cmdUpSamplesMs,
            tMechMs: mechSamplesMs,
            tVideoDownMs: videoDownSamplesMs,
            tRenderMs: renderSamplesMs,
            tMtpApproxMs: mtpApproxSamplesMs
        )
    }

    func isSessionRunning() -> Bool {
        sessionRunning
    }

    func recordRender(ms: Double) {
        append(ms, to: &renderSamplesMs)
        maybeLogSummary()
    }

    func recordCommand(rttMs: Double, serverProcMs: Double?, mechanicalMs: Double?) {
        let cmdUpMs: Double
        if let serverProcMs {
            cmdUpMs = max(0.0, (rttMs - serverProcMs) * 0.5)
        } else {
            cmdUpMs = max(0.0, rttMs * 0.5)
        }
        append(cmdUpMs, to: &cmdUpSamplesMs)

        if let mechanicalMs {
            append(max(0.0, mechanicalMs), to: &mechSamplesMs)
        }
        maybeLogSummary()
    }

    func recordVideoDownEstimate(rttMs: Double) {
        if hasDirectVideoDownSamples { return }
        append(max(0.0, rttMs * 0.5), to: &videoDownSamplesMs)
        maybeLogSummary()
    }

    func updateClockSync(serverUnixMs: Double, clientSendUnixMs: Double, clientRecvUnixMs: Double) {
        let midpoint = (clientSendUnixMs + clientRecvUnixMs) * 0.5
        let sampleOffset = serverUnixMs - midpoint
        if let old = serverClockOffsetMs {
            // 指数平滑，降低网络抖动对时钟偏移估计的影响。
            serverClockOffsetMs = old * 0.8 + sampleOffset * 0.2
        } else {
            serverClockOffsetMs = sampleOffset
        }
    }

    func recordVideoDownMeasured(serverSendUnixMs: Double, clientRecvUnixMs: Double) {
        guard let offsetMs = serverClockOffsetMs else { return }
        let estimatedClientClockSendMs = serverSendUnixMs - offsetMs
        let delayMs = clientRecvUnixMs - estimatedClientClockSendMs
        guard delayMs >= 0.0, delayMs <= 2_000.0 else { return }

        hasDirectVideoDownSamples = true
        append(delayMs, to: &videoDownSamplesMs)
        maybeLogSummary()
    }

    private func append(_ value: Double, to array: inout [Double]) {
        array.append(value)
        if array.count > maxSamples {
            array.removeFirst(array.count - maxSamples)
        }
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))
        return sorted[idx]
    }

    private func maybeLogSummary() {
        guard let tCmd = mean(cmdUpSamplesMs),
              let tMech = mean(mechSamplesMs),
              let tVideo = mean(videoDownSamplesMs),
              let tRender = mean(renderSamplesMs) else {
            return
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs - lastSummaryNs >= summaryIntervalNs else { return }
        lastSummaryNs = nowNs

        let mtpApprox = tCmd + tMech + tVideo + tRender
        let mtpP95 = (p95(cmdUpSamplesMs) ?? tCmd)
            + (p95(mechSamplesMs) ?? tMech)
            + (p95(videoDownSamplesMs) ?? tVideo)
            + (p95(renderSamplesMs) ?? tRender)

        AppLogger.shared.perf(String(
            format: "[MTP] mean(ms) T_cmd_up=%.2f T_m=%.2f T_video_down=%.2f T_r=%.2f => T_mtp≈%.2f | P95≈%.2f",
            tCmd,
            tMech,
            tVideo,
            tRender,
            mtpApprox,
            mtpP95
        ))
    }

    private func makeSummary(durationSec: Double) -> Summary? {
        guard let tCmd = mean(cmdUpSamplesMs),
              let tMech = mean(mechSamplesMs),
              let tVideo = mean(videoDownSamplesMs),
              let tRender = mean(renderSamplesMs) else {
            return nil
        }

        let mtpApprox = tCmd + tMech + tVideo + tRender
        let mtpP95 = (p95(cmdUpSamplesMs) ?? tCmd)
            + (p95(mechSamplesMs) ?? tMech)
            + (p95(videoDownSamplesMs) ?? tVideo)
            + (p95(renderSamplesMs) ?? tRender)

        return Summary(
            durationSec: durationSec,
            cmdCount: cmdUpSamplesMs.count,
            mechCount: mechSamplesMs.count,
            videoCount: videoDownSamplesMs.count,
            renderCount: renderSamplesMs.count,
            tCmdMean: tCmd,
            tMechMean: tMech,
            tVideoMean: tVideo,
            tRenderMean: tRender,
            tMtpMean: mtpApprox,
            tMtpP95: mtpP95
        )
    }
}
