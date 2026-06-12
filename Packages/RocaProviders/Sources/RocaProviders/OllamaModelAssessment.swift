import Darwin
import Foundation
import RocaCore

public enum BrainModelSpeedStatus: String, Codable, Equatable, Sendable {
    case fast
    case okay
    case slow
    case unknown
}

public struct BrainModelSpeedRecommendation: Codable, Equatable, Sendable {
    public var status: BrainModelSpeedStatus
    public var rank: Int
    public var reason: String

    public init(status: BrainModelSpeedStatus, rank: Int, reason: String) {
        self.status = status
        self.rank = rank
        self.reason = reason
    }
}

public struct ModelAssessmentDeviceProfile: Codable, Equatable, Sendable {
    public var id: String
    public var chip: String?
    public var memoryGB: Int?
    public var os: String?

    public init(id: String, chip: String? = nil, memoryGB: Int? = nil, os: String? = nil) {
        self.id = id
        self.chip = chip
        self.memoryGB = memoryGB
        self.os = os
    }

    public static func current() -> ModelAssessmentDeviceProfile {
        let chip = hardwareString("machdep.cpu.brand_string")
        let memoryGB = memoryGigabytes(ProcessInfo.processInfo.physicalMemory)
        return ModelAssessmentDeviceProfile(
            id: stableID(chip: chip, memoryGB: memoryGB),
            chip: chip,
            memoryGB: memoryGB,
            os: operatingSystemDescription()
        )
    }

    public static func stableID(chip: String?, memoryGB: Int?) -> String {
        let memory = memoryGB.map { "\($0)gb" } ?? "unknown-memory"
        guard let chip = chip?.lowercased(), !chip.isEmpty else {
            return "unknown-\(memory)"
        }
        let normalizedChip = chip
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !normalizedChip.isEmpty else {
            return "unknown-\(memory)"
        }
        return "\(normalizedChip)-\(memory)"
    }

    private static func memoryGigabytes(_ bytes: UInt64) -> Int {
        let gibibyte = Double(1_073_741_824)
        return max(1, Int((Double(bytes) / gibibyte).rounded()))
    }

    private static func operatingSystemDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    private static func hardwareString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ModelQualityAssessment: Codable, Equatable, Sendable {
    public var status: BrainModelRecommendationStatus
    public var reason: String
    public var totalRequests: Int
    public var parseFailures: Int
    public var responseFailures: Int
    public var criticalRoutingFailures: Int
    public var sourceRunID: String
    public var lastUpdatedAt: String

    public init(
        status: BrainModelRecommendationStatus,
        reason: String,
        totalRequests: Int,
        parseFailures: Int,
        responseFailures: Int,
        criticalRoutingFailures: Int,
        sourceRunID: String,
        lastUpdatedAt: String
    ) {
        self.status = status
        self.reason = reason
        self.totalRequests = totalRequests
        self.parseFailures = parseFailures
        self.responseFailures = responseFailures
        self.criticalRoutingFailures = criticalRoutingFailures
        self.sourceRunID = sourceRunID
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct ModelSpeedMeasurement: Codable, Equatable, Sendable {
    public var medianMs: Int?
    public var p95Ms: Int?
    public var sampleCount: Int

    public init(medianMs: Int?, p95Ms: Int?, sampleCount: Int) {
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.sampleCount = sampleCount
    }
}

public struct ModelSpeedProfileAssessment: Codable, Equatable, Sendable {
    public var status: BrainModelSpeedStatus
    public var reason: String
    public var deviceProfile: ModelAssessmentDeviceProfile
    public var companionRouter: ModelSpeedMeasurement?
    public var generalChat: ModelSpeedMeasurement?
    public var sourceRunID: String
    public var lastUpdatedAt: String

    public init(
        status: BrainModelSpeedStatus,
        reason: String,
        deviceProfile: ModelAssessmentDeviceProfile,
        companionRouter: ModelSpeedMeasurement? = nil,
        generalChat: ModelSpeedMeasurement? = nil,
        sourceRunID: String,
        lastUpdatedAt: String
    ) {
        self.status = status
        self.reason = reason
        self.deviceProfile = deviceProfile
        self.companionRouter = companionRouter
        self.generalChat = generalChat
        self.sourceRunID = sourceRunID
        self.lastUpdatedAt = lastUpdatedAt
    }

    public func measurement(for role: BrainRole?) -> ModelSpeedMeasurement? {
        switch role {
        case .companionRouter:
            return companionRouter
        case .generalChat:
            return generalChat
        default:
            return [companionRouter, generalChat]
                .compactMap { $0 }
                .max { left, right in
                    (left.p95Ms ?? left.medianMs ?? 0) < (right.p95Ms ?? right.medianMs ?? 0)
                }
        }
    }
}

public struct OllamaModelAssessment: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var modelID: String
    public var displayName: String
    public var aliases: [String]
    public var lastUpdatedAt: String
    public var quality: [String: ModelQualityAssessment]
    public var speed: [String: ModelSpeedProfileAssessment]

    public init(
        schemaVersion: Int = 1,
        modelID: String,
        displayName: String,
        aliases: [String] = [],
        lastUpdatedAt: String,
        quality: [String: ModelQualityAssessment] = [:],
        speed: [String: ModelSpeedProfileAssessment] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.displayName = displayName
        self.aliases = aliases
        self.lastUpdatedAt = lastUpdatedAt
        self.quality = quality
        self.speed = speed
    }

    public func qualityAssessment(for role: BrainRole) -> ModelQualityAssessment? {
        quality[role.rawValue]
    }

    public func speedAssessment(for profile: ModelAssessmentDeviceProfile) -> ModelSpeedProfileAssessment? {
        speed[profile.id]
    }

    public func matches(modelID: String) -> Bool {
        let normalized = Self.normalize(modelID)
        return Self.normalize(self.modelID) == normalized
            || aliases.contains { Self.normalize($0) == normalized }
    }

    public static func normalize(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum OllamaModelAssessmentStore {
    public static func loadBundledAssessments() -> [OllamaModelAssessment] {
        loadBundledAssessments(bundle: .module)
    }

    public static func loadBundledAssessments(bundle: Bundle) -> [OllamaModelAssessment] {
        if let directory = bundle.url(forResource: "ModelAssessments", withExtension: nil) {
            return loadAssessments(from: directory)
        }
        guard let resourceURL = bundle.resourceURL else {
            return []
        }
        return loadAssessments(from: resourceURL)
    }

    public static func loadAssessments(from directory: URL, fileManager: FileManager = .default) -> [OllamaModelAssessment] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? decoder.decode(OllamaModelAssessment.self, from: data)
            }
    }

    public static func fileName(for modelID: String) -> String {
        let base = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber {
                    return character
                }
                return "-"
            }
        let collapsed = String(base)
            .split(separator: "-")
            .joined(separator: "-")
        return "\(collapsed).json"
    }
}
