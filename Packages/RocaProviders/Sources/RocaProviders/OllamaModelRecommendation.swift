import Foundation
import RocaCore

public enum BrainModelRecommendationStatus: String, Codable, Equatable, Sendable {
    case preferred
    case acceptable
    case untested
    case discouraged
    case unsupported
}

public struct BrainModelRecommendation: Codable, Equatable, Sendable {
    public var status: BrainModelRecommendationStatus
    public var rank: Int
    public var reason: String

    public init(status: BrainModelRecommendationStatus, rank: Int, reason: String) {
        self.status = status
        self.rank = rank
        self.reason = reason
    }
}

public struct BrainModelRecommendationEvidence: Codable, Equatable, Sendable {
    public var modelID: String
    public var role: BrainRole?
    public var totalRequests: Int
    public var parseFailures: Int
    public var responseFailures: Int
    public var criticalRoutingFailures: Int
    public var medianLatencyMilliseconds: Int?
    public var p95LatencyMilliseconds: Int?

    public init(
        modelID: String,
        role: BrainRole? = nil,
        totalRequests: Int,
        parseFailures: Int,
        responseFailures: Int,
        criticalRoutingFailures: Int,
        medianLatencyMilliseconds: Int?,
        p95LatencyMilliseconds: Int?
    ) {
        self.modelID = modelID
        self.role = role
        self.totalRequests = totalRequests
        self.parseFailures = parseFailures
        self.responseFailures = responseFailures
        self.criticalRoutingFailures = criticalRoutingFailures
        self.medianLatencyMilliseconds = medianLatencyMilliseconds
        self.p95LatencyMilliseconds = p95LatencyMilliseconds
    }
}

public enum OllamaModelRecommendationPolicy {
    private static let bundledAssessments = OllamaModelAssessmentStore.loadBundledAssessments()

    public static func recommendation(
        for modelID: String,
        role: BrainRole? = nil,
        evidence: [BrainModelRecommendationEvidence] = []
    ) -> BrainModelRecommendation {
        let normalized = normalize(modelID)
        if isLikelyNonChatModel(normalized) {
            return BrainModelRecommendation(
                status: .unsupported,
                rank: -1_000,
                reason: "This looks like a non-chat model, so Roca should not use it as an assistant brain."
            )
        }
        if let match = matchingEvidence(for: normalized, role: role, evidence: evidence) {
            return recommendation(from: match.evidence, requestedRole: role, isRoleSpecific: match.isRoleSpecific)
        }
        if let assessment = assessment(for: normalized) {
            return recommendation(from: assessment, role: role)
        }
        return BrainModelRecommendation(
            status: .untested,
            rank: heuristicRank(for: normalized),
            reason: "Roca has not benchmarked this model for assistant chat yet."
        )
    }

    public static func sortedModels(
        _ models: [OllamaModel],
        role: BrainRole? = nil,
        evidence: [BrainModelRecommendationEvidence] = []
    ) -> [OllamaModel] {
        models.sorted { left, right in
            let leftRecommendation = recommendation(for: left.id, role: role, evidence: evidence)
            let rightRecommendation = recommendation(for: right.id, role: role, evidence: evidence)
            let leftPriority = priority(leftRecommendation.status)
            let rightPriority = priority(rightRecommendation.status)
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            if leftRecommendation.rank != rightRecommendation.rank {
                return leftRecommendation.rank > rightRecommendation.rank
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    public static func selectableModels(
        _ models: [OllamaModel],
        role: BrainRole? = nil,
        evidence: [BrainModelRecommendationEvidence] = []
    ) -> [OllamaModel] {
        sortedModels(models, role: role, evidence: evidence)
            .filter { recommendation(for: $0.id, role: role, evidence: evidence).status != .unsupported }
    }

    public static func isSelectable(
        _ modelID: String,
        role: BrainRole? = nil,
        evidence: [BrainModelRecommendationEvidence] = []
    ) -> Bool {
        recommendation(for: modelID, role: role, evidence: evidence).status != .unsupported
    }

    public static func recommendedModel(
        from models: [OllamaModel],
        role: BrainRole? = nil,
        evidence: [BrainModelRecommendationEvidence] = []
    ) -> OllamaModel? {
        selectableModels(models, role: role, evidence: evidence).first
    }

    public static func speedRecommendation(
        for model: OllamaModel,
        role: BrainRole? = nil,
        deviceProfile: ModelAssessmentDeviceProfile = .current()
    ) -> BrainModelSpeedRecommendation {
        speedRecommendation(
            for: model.id,
            size: model.size,
            role: role,
            deviceProfile: deviceProfile
        )
    }

    public static func speedRecommendation(
        for modelID: String,
        size: Int64? = nil,
        role: BrainRole? = nil,
        deviceProfile: ModelAssessmentDeviceProfile = .current()
    ) -> BrainModelSpeedRecommendation {
        let normalized = normalize(modelID)
        if let assessment = assessment(for: normalized),
           let speed = assessment.speedAssessment(for: deviceProfile) {
            return speedRecommendation(from: speed, role: role)
        }
        return estimatedSpeedRecommendation(
            for: normalized,
            size: size,
            deviceProfile: deviceProfile
        )
    }

    private static func assessment(for normalizedModelID: String) -> OllamaModelAssessment? {
        bundledAssessments.first { assessment in
            assessment.matches(modelID: normalizedModelID)
        }
    }

    private static func recommendation(from assessment: OllamaModelAssessment, role: BrainRole?) -> BrainModelRecommendation {
        if let role,
           let quality = assessment.qualityAssessment(for: role) {
            return BrainModelRecommendation(
                status: quality.status,
                rank: assessmentRank(for: quality.status, modelID: assessment.modelID, sampleCount: quality.totalRequests),
                reason: quality.reason
            )
        }

        let roles = [BrainRole.companionRouter, .generalChat]
        let qualities = roles.compactMap { assessment.qualityAssessment(for: $0) }
        guard !qualities.isEmpty else {
            return BrainModelRecommendation(
                status: .untested,
                rank: heuristicRank(for: normalize(assessment.modelID)),
                reason: "Roca has an assessment file for this model, but no quality result for this role yet."
            )
        }

        let status: BrainModelRecommendationStatus
        if qualities.contains(where: { $0.status == .unsupported }) {
            status = .unsupported
        } else if qualities.contains(where: { $0.status == .discouraged }) {
            status = .discouraged
        } else if qualities.contains(where: { $0.status == .untested }) || qualities.count < roles.count {
            status = .untested
        } else if qualities.allSatisfy({ $0.status == .preferred }) {
            status = .preferred
        } else {
            status = .acceptable
        }
        let sampleCount = qualities.map(\.totalRequests).reduce(0, +)
        return BrainModelRecommendation(
            status: status,
            rank: assessmentRank(for: status, modelID: assessment.modelID, sampleCount: sampleCount),
            reason: "Based on Roca's current routing and chat assessments."
        )
    }

    private static func assessmentRank(
        for status: BrainModelRecommendationStatus,
        modelID: String,
        sampleCount: Int
    ) -> Int {
        let base: Int
        switch status {
        case .preferred:
            base = 1_000
        case .acceptable:
            base = 800
        case .untested:
            base = 500
        case .discouraged:
            base = 200
        case .unsupported:
            base = -1_000
        }
        return base + min(sampleCount, 50) + heuristicRank(for: normalize(modelID))
    }

    private static func speedRecommendation(
        from speed: ModelSpeedProfileAssessment,
        role: BrainRole?
    ) -> BrainModelSpeedRecommendation {
        if let measurement = speed.measurement(for: role) {
            return BrainModelSpeedRecommendation(
                status: speedStatus(for: measurement),
                rank: speedRank(speedStatus(for: measurement)),
                reason: speed.reason
            )
        }
        return BrainModelSpeedRecommendation(
            status: speed.status,
            rank: speedRank(speed.status),
            reason: speed.reason
        )
    }

    private static func estimatedSpeedRecommendation(
        for normalizedModelID: String,
        size: Int64?,
        deviceProfile: ModelAssessmentDeviceProfile
    ) -> BrainModelSpeedRecommendation {
        guard let status = estimatedSpeedStatus(
            for: normalizedModelID,
            size: size,
            memoryGB: deviceProfile.memoryGB
        ) else {
            return BrainModelSpeedRecommendation(
                status: .unknown,
                rank: speedRank(.unknown),
                reason: "Roca does not have speed data for this model on this Mac yet."
            )
        }
        return BrainModelSpeedRecommendation(
            status: status,
            rank: speedRank(status),
            reason: "Estimated from model size and this Mac's memory; run evals for measured speed."
        )
    }

    private static func estimatedSpeedStatus(
        for normalizedModelID: String,
        size: Int64?,
        memoryGB: Int?
    ) -> BrainModelSpeedStatus? {
        guard let memoryGB else {
            return nil
        }
        if let size {
            let sizeGB = Double(size) / 1_000_000_000
            if sizeGB <= Double(memoryGB) * 0.20 {
                return .fast
            }
            if sizeGB <= Double(memoryGB) * 0.45 {
                return .okay
            }
            return .slow
        }
        guard let parameterBillions = parameterBillions(in: normalizedModelID) else {
            return nil
        }
        if parameterBillions <= 4, memoryGB >= 16 {
            return .fast
        }
        if parameterBillions <= 8, memoryGB >= 16 {
            return .okay
        }
        if parameterBillions <= 14, memoryGB >= 32 {
            return .okay
        }
        return .slow
    }

    private static func parameterBillions(in normalizedModelID: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(normalizedModelID.startIndex ..< normalizedModelID.endIndex, in: normalizedModelID)
        guard let match = regex.firstMatch(in: normalizedModelID, range: range),
              let valueRange = Range(match.range(at: 1), in: normalizedModelID)
        else {
            return nil
        }
        return Double(normalizedModelID[valueRange])
    }

    private static func speedStatus(for measurement: ModelSpeedMeasurement) -> BrainModelSpeedStatus {
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

    private static func speedRank(_ status: BrainModelSpeedStatus) -> Int {
        switch status {
        case .fast:
            return 400
        case .okay:
            return 300
        case .unknown:
            return 200
        case .slow:
            return 100
        }
    }

    private static func matchingEvidence(
        for normalizedModelID: String,
        role: BrainRole?,
        evidence: [BrainModelRecommendationEvidence]
    ) -> (evidence: BrainModelRecommendationEvidence, isRoleSpecific: Bool)? {
        if let role {
            if let roleSpecific = evidence.first(where: {
                normalize($0.modelID) == normalizedModelID && $0.role == role
            }) {
                return (roleSpecific, true)
            }
        }
        if let general = evidence.first(where: {
            normalize($0.modelID) == normalizedModelID && $0.role == nil
        }) {
            return (general, false)
        }
        return nil
    }

    private static func recommendation(
        from evidence: BrainModelRecommendationEvidence,
        requestedRole: BrainRole?,
        isRoleSpecific: Bool
    ) -> BrainModelRecommendation {
        guard evidence.totalRequests > 0 else {
            return BrainModelRecommendation(
                status: .untested,
                rank: heuristicRank(for: normalize(evidence.modelID)),
                reason: "Roca has eval evidence for this model, but it does not include completed requests yet."
            )
        }

        let failureCount = max(evidence.parseFailures, evidence.criticalRoutingFailures) + evidence.responseFailures
        let failureRate = Double(failureCount) / Double(evidence.totalRequests)
        let status: BrainModelRecommendationStatus
        let baseRank: Int
        if evidence.totalRequests < 12 {
            status = .untested
            baseRank = 500
        } else if evidence.parseFailures > 0
            || evidence.responseFailures > 0
            || failureRate >= 0.30 {
            status = .discouraged
            baseRank = 250
        } else if failureRate >= 0.15 {
            status = .acceptable
            baseRank = 850
        } else {
            status = .preferred
            baseRank = 1_100
        }
        return BrainModelRecommendation(
            status: status,
            rank: baseRank + min(evidence.totalRequests, 50),
            reason: evidenceReason(for: evidence, requestedRole: requestedRole, isRoleSpecific: isRoleSpecific)
        )
    }

    private static func evidenceReason(
        for evidence: BrainModelRecommendationEvidence,
        requestedRole: BrainRole?,
        isRoleSpecific: Bool
    ) -> String {
        let roleDescription: String
        if isRoleSpecific, let requestedRole {
            roleDescription = displayName(for: requestedRole).lowercased()
        } else {
            roleDescription = "general assistant"
        }
        let failures = max(evidence.parseFailures, evidence.criticalRoutingFailures) + evidence.responseFailures
        return "Roca has \(roleDescription) eval evidence for this model: \(failures)/\(evidence.totalRequests) failures."
    }

    private static func displayName(for role: BrainRole) -> String {
        switch role {
        case .companionRouter:
            "Companion routing"
        case .generalChat:
            "General chat"
        case .coding:
            "Coding"
        case .writing:
            "Writing"
        case .localPrivate:
            "Local private"
        case .cloudQuality:
            "Cloud quality"
        }
    }

    private static func priority(_ status: BrainModelRecommendationStatus) -> Int {
        switch status {
        case .preferred:
            5
        case .acceptable:
            4
        case .untested:
            3
        case .discouraged:
            2
        case .unsupported:
            1
        }
    }

    private static func isLikelyNonChatModel(_ normalizedModelID: String) -> Bool {
        normalizedModelID.contains("embed")
            || normalizedModelID.contains("embedding")
            || normalizedModelID.contains("rerank")
    }

    private static func heuristicRank(for normalizedModelID: String) -> Int {
        var score = 0
        if normalizedModelID.contains("instruct") || normalizedModelID.contains("chat") {
            score += 40
        }
        if normalizedModelID.contains("qwen") {
            score += 30
        }
        if normalizedModelID.contains("llama") {
            score += 25
        }
        if normalizedModelID.contains("mistral") {
            score += 20
        }
        if normalizedModelID.contains("gemma") {
            score += 15
        }
        if normalizedModelID.contains("coder") || normalizedModelID.contains("code") {
            score -= 15
        }
        return score
    }

    private static func normalize(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
