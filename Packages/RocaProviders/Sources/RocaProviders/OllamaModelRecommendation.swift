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
        if let known = knownRecommendations(for: role)[normalized] {
            return known
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

    private static func knownRecommendations(for role: BrainRole?) -> [String: BrainModelRecommendation] {
        guard let role else {
            return overallRecommendations
        }
        switch role {
        case .companionRouter:
            return routingRecommendations
        case .generalChat:
            return chatRecommendations
        default:
            return [:]
        }
    }

    private static let overallRecommendations: [String: BrainModelRecommendation] = [
        normalize("qwen3:4b-instruct"): BrainModelRecommendation(
            status: .preferred,
            rank: 1_000,
            reason: "Best current single-model baseline across Roca's routing and chat evals."
        ),
        normalize("mistral:7b"): BrainModelRecommendation(
            status: .acceptable,
            rank: 850,
            reason: "Usable baseline, but current evals show routing misses and slower chat responses."
        ),
        normalize("qwen3:0.6b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 260,
            reason: "Fast, but current evals show frequent routing mistakes and weak chat quality."
        ),
        normalize("qwen2.5-coder:7b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 240,
            reason: "Current evals show unsafe routing mistakes and inconsistent companion chat behavior."
        ),
        normalize("gemma4:12b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 220,
            reason: "Correct on a small smoke check, but too slow for Roca's current local assistant path."
        ),
        normalize("qwen3.5:4b-mlx"): BrainModelRecommendation(
            status: .discouraged,
            rank: 200,
            reason: "Correct on a small smoke check, but current Ollama eval latency is too high."
        )
    ]

    private static let routingRecommendations: [String: BrainModelRecommendation] = [
        normalize("qwen3:4b-instruct"): BrainModelRecommendation(
            status: .preferred,
            rank: 1_000,
            reason: "Best current routing eval result: fast, parse-clean, with misses limited to ambiguous follow-up commands."
        ),
        normalize("mistral:7b"): BrainModelRecommendation(
            status: .acceptable,
            rank: 820,
            reason: "Fast enough for routing, but current evals miss ambiguous follow-up commands."
        ),
        normalize("qwen3:0.6b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 260,
            reason: "Current routing evals show frequent critical mistakes, including unsafe command handling."
        ),
        normalize("qwen2.5-coder:7b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 240,
            reason: "Current routing evals show too many critical mistakes for command routing."
        ),
        normalize("gemma4:12b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 220,
            reason: "Correct on a tiny routing smoke check, but too slow for Roca's routing role."
        ),
        normalize("qwen3.5:4b-mlx"): BrainModelRecommendation(
            status: .discouraged,
            rank: 200,
            reason: "Correct on a tiny routing smoke check, but too slow through the current Ollama path."
        )
    ]

    private static let chatRecommendations: [String: BrainModelRecommendation] = [
        normalize("qwen3:4b-instruct"): BrainModelRecommendation(
            status: .preferred,
            rank: 1_000,
            reason: "Best current chat eval result: fast, parse-clean, and closest to Roca's companion tone."
        ),
        normalize("qwen2.5-coder:7b"): BrainModelRecommendation(
            status: .acceptable,
            rank: 820,
            reason: "Usable for chat, though current evals show inconsistent formatting and companion tone."
        ),
        normalize("mistral:7b"): BrainModelRecommendation(
            status: .acceptable,
            rank: 780,
            reason: "Usable for chat, but current evals are slower and more verbose than Roca's preferred tone."
        ),
        normalize("qwen3:0.6b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 300,
            reason: "Fast, but current chat evals show weak instruction following and shallow answers."
        ),
        normalize("gemma4:12b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 220,
            reason: "Chat quality is usable on a smoke check, but latency is too high for Roca's local chat role."
        ),
        normalize("qwen3.5:4b-mlx"): BrainModelRecommendation(
            status: .discouraged,
            rank: 200,
            reason: "Chat quality is usable on a smoke check, but latency is far too high through Ollama."
        )
    ]

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
        let latency = evidence.p95LatencyMilliseconds ?? evidence.medianLatencyMilliseconds
        let latencyPenalty = latency.map { min($0 / 1_000, 60) } ?? 0
        let status: BrainModelRecommendationStatus
        let baseRank: Int
        if evidence.parseFailures > 0
            || evidence.responseFailures > 0
            || failureRate >= 0.15 {
            status = .discouraged
            baseRank = 250
        } else if evidence.totalRequests >= 12 && (latency ?? 0) <= 12_000 {
            status = .preferred
            baseRank = 1_100
        } else {
            status = .acceptable
            baseRank = 850
        }
        return BrainModelRecommendation(
            status: status,
            rank: baseRank + min(evidence.totalRequests, 50) - latencyPenalty,
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
        let latency = evidence.p95LatencyMilliseconds.map { ", p95 \($0) ms" } ?? ""
        let failures = max(evidence.parseFailures, evidence.criticalRoutingFailures) + evidence.responseFailures
        return "Roca has \(roleDescription) eval evidence for this model: \(failures)/\(evidence.totalRequests) failures\(latency)."
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
