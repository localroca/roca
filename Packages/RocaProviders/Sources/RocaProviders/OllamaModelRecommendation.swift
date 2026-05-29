import Foundation
import RocaCore

public enum BrainModelRecommendationStatus: String, Codable, Equatable, Sendable {
    case preferred
    case acceptable
    case untested
    case discouraged
    case unsupported
}

public struct BrainModelRecommendation: Equatable, Sendable {
    public var status: BrainModelRecommendationStatus
    public var rank: Int
    public var reason: String

    public init(status: BrainModelRecommendationStatus, rank: Int, reason: String) {
        self.status = status
        self.rank = rank
        self.reason = reason
    }
}

public enum OllamaModelRecommendationPolicy {
    public static func recommendation(
        for modelID: String,
        role: BrainRole = .companionRouter
    ) -> BrainModelRecommendation {
        let normalized = normalize(modelID)
        if let known = knownRecommendations(for: role)[normalized] {
            return known
        }
        if isLikelyNonChatModel(normalized) {
            return BrainModelRecommendation(
                status: .unsupported,
                rank: -1_000,
                reason: "This looks like a non-chat model, so Roca should not use it as an assistant brain."
            )
        }
        return BrainModelRecommendation(
            status: .untested,
            rank: heuristicRank(for: normalized),
            reason: "Roca has not benchmarked this model for assistant chat yet."
        )
    }

    public static func sortedModels(
        _ models: [OllamaModel],
        role: BrainRole = .companionRouter
    ) -> [OllamaModel] {
        models.sorted { left, right in
            let leftRecommendation = recommendation(for: left.id, role: role)
            let rightRecommendation = recommendation(for: right.id, role: role)
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
        role: BrainRole = .companionRouter
    ) -> [OllamaModel] {
        sortedModels(models, role: role)
            .filter { recommendation(for: $0.id, role: role).status != .unsupported }
    }

    public static func isSelectable(
        _ modelID: String,
        role: BrainRole = .companionRouter
    ) -> Bool {
        recommendation(for: modelID, role: role).status != .unsupported
    }

    public static func recommendedModel(
        from models: [OllamaModel],
        role: BrainRole = .companionRouter
    ) -> OllamaModel? {
        selectableModels(models, role: role).first
    }

    private static func knownRecommendations(for role: BrainRole) -> [String: BrainModelRecommendation] {
        switch role {
        case .companionRouter, .generalChat:
            companionRecommendations
        default:
            [:]
        }
    }

    private static let companionRecommendations: [String: BrainModelRecommendation] = [
        normalize("qwen3:4b-instruct"): BrainModelRecommendation(
            status: .preferred,
            rank: 1_000,
            reason: "Best current local eval result for Roca's assistant chat and command routing."
        ),
        normalize("mistral:7b"): BrainModelRecommendation(
            status: .acceptable,
            rank: 900,
            reason: "Solid routing fallback, though less consistent with Roca's companion voice."
        ),
        normalize("qwen3:0.6b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 300,
            reason: "Fast, but current evals show unreliable routing and weak safety behavior."
        ),
        normalize("qwen2.5-coder:7b"): BrainModelRecommendation(
            status: .discouraged,
            rank: 250,
            reason: "Not recommended for assistant chat; current evals route casual conversation into actions too often."
        ),
        normalize("qwen3.5:4b-mlx"): BrainModelRecommendation(
            status: .discouraged,
            rank: 200,
            reason: "Timeout-prone through the current Ollama path in Roca's evals."
        )
    ]

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
