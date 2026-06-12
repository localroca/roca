import Foundation
import RocaCore
import RocaProviders

public enum EvalAssessmentWriter {
    public static func writeAssessments(
        for output: EvalRunOutput,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = Dictionary(
            uniqueKeysWithValues: OllamaModelAssessmentStore
                .loadAssessments(from: directory, fileManager: fileManager)
                .map { (OllamaModelAssessment.normalize($0.modelID), $0) }
        )
        let timestamp = iso8601String(output.run.completedAt)
        for modelID in output.run.models {
            let normalized = OllamaModelAssessment.normalize(modelID)
            var assessment = existing[normalized] ?? OllamaModelAssessment(
                modelID: modelID,
                displayName: displayName(for: modelID),
                lastUpdatedAt: timestamp
            )
            assessment.lastUpdatedAt = timestamp
            assessment.quality = mergedQuality(
                existing: assessment.quality,
                output: output,
                modelID: modelID,
                timestamp: timestamp
            )
            assessment.speed[output.run.deviceProfile.id] = mergedSpeedProfile(
                existing: assessment.speed[output.run.deviceProfile.id],
                output: output,
                modelID: modelID,
                timestamp: timestamp
            )

            let data = try encoder.encode(assessment)
            try data.write(
                to: directory.appendingPathComponent(OllamaModelAssessmentStore.fileName(for: modelID)),
                options: .atomic
            )
        }
    }

    private static func mergedQuality(
        existing: [String: ModelQualityAssessment],
        output: EvalRunOutput,
        modelID: String,
        timestamp: String
    ) -> [String: ModelQualityAssessment] {
        var quality = existing
        for summary in output.run.roleSummaries where summary.modelID == modelID {
            let roleKey = summary.role.rawValue
            let next = qualityAssessment(for: summary, runID: output.run.runID, timestamp: timestamp)
            if let current = quality[roleKey], current.totalRequests > next.totalRequests {
                continue
            }
            quality[roleKey] = next
        }
        return quality
    }

    private static func qualityAssessment(
        for summary: EvalRoleModelSummary,
        runID: String,
        timestamp: String
    ) -> ModelQualityAssessment {
        let evidence = BrainModelRecommendationEvidence(
            modelID: summary.modelID,
            role: summary.role,
            totalRequests: summary.totalRequests,
            parseFailures: summary.parseFailures,
            responseFailures: summary.responseFailures,
            criticalRoutingFailures: summary.criticalRoutingFailures,
            medianLatencyMilliseconds: summary.medianLatencyMilliseconds,
            p95LatencyMilliseconds: summary.p95LatencyMilliseconds
        )
        let recommendation = OllamaModelRecommendationPolicy.recommendation(
            for: summary.modelID,
            role: summary.role,
            evidence: [evidence]
        )
        return ModelQualityAssessment(
            status: recommendation.status,
            reason: recommendation.reason,
            totalRequests: summary.totalRequests,
            parseFailures: summary.parseFailures,
            responseFailures: summary.responseFailures,
            criticalRoutingFailures: summary.criticalRoutingFailures,
            sourceRunID: runID,
            lastUpdatedAt: timestamp
        )
    }

    private static func mergedSpeedProfile(
        existing: ModelSpeedProfileAssessment?,
        output: EvalRunOutput,
        modelID: String,
        timestamp: String
    ) -> ModelSpeedProfileAssessment {
        var companionRouter = existing?.companionRouter
        var generalChat = existing?.generalChat
        for summary in output.run.roleSummaries where summary.modelID == modelID {
            let measurement = ModelSpeedMeasurement(
                medianMs: summary.medianLatencyMilliseconds,
                p95Ms: summary.p95LatencyMilliseconds,
                sampleCount: summary.totalRequests
            )
            switch summary.role {
            case .companionRouter:
                if (companionRouter?.sampleCount ?? -1) <= measurement.sampleCount {
                    companionRouter = measurement
                }
            case .generalChat:
                if (generalChat?.sampleCount ?? -1) <= measurement.sampleCount {
                    generalChat = measurement
                }
            default:
                continue
            }
        }
        let status = speedStatus(companionRouter: companionRouter, generalChat: generalChat)
        return ModelSpeedProfileAssessment(
            status: status,
            reason: speedReason(status, deviceProfile: output.run.deviceProfile),
            deviceProfile: output.run.deviceProfile,
            companionRouter: companionRouter,
            generalChat: generalChat,
            sourceRunID: output.run.runID,
            lastUpdatedAt: timestamp
        )
    }

    private static func speedStatus(
        companionRouter: ModelSpeedMeasurement?,
        generalChat: ModelSpeedMeasurement?
    ) -> BrainModelSpeedStatus {
        let measurements = [companionRouter, generalChat].compactMap { $0 }
        guard !measurements.isEmpty else {
            return .unknown
        }
        if measurements.contains(where: { status(for: $0) == .slow }) {
            return .slow
        }
        if measurements.contains(where: { status(for: $0) == .okay }) {
            return .okay
        }
        if measurements.allSatisfy({ status(for: $0) == .fast }) {
            return .fast
        }
        return .unknown
    }

    private static func status(for measurement: ModelSpeedMeasurement) -> BrainModelSpeedStatus {
        guard let latency = measurement.p95Ms ?? measurement.medianMs else {
            return .unknown
        }
        if latency <= 2_500 {
            return .fast
        }
        if latency <= 12_000 {
            return .okay
        }
        return .slow
    }

    private static func speedReason(
        _ status: BrainModelSpeedStatus,
        deviceProfile: ModelAssessmentDeviceProfile
    ) -> String {
        let memory = deviceProfile.memoryGB.map { "\($0)GB " } ?? ""
        let mac = "\(memory)Mac".trimmingCharacters(in: .whitespaces)
        switch status {
        case .fast:
            return "Measured fast on this \(mac) profile."
        case .okay:
            return "Measured usable on this \(mac) profile."
        case .slow:
            return "Measured slow on this \(mac) profile."
        case .unknown:
            return "Roca does not have enough speed data for this device profile yet."
        }
    }

    private static func displayName(for modelID: String) -> String {
        modelID
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                if part.allSatisfy(\.isNumber) || part.lowercased().hasSuffix("b") {
                    return part.uppercased()
                }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
