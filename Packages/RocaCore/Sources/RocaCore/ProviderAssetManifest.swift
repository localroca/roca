import Foundation

public struct ProviderAssetManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = "0.1.0"

    public var schemaVersion: String
    public var providerID: ProviderID
    public var providerKind: ProviderKind
    public var displayName: String
    public var modelID: String
    public var revision: String
    public var runtime: ProviderAssetRuntime?
    public var files: [ProviderAssetFile]
    public var voiceGroups: [ProviderAssetVoiceGroup]

    public init(
        schemaVersion: String,
        providerID: ProviderID,
        providerKind: ProviderKind,
        displayName: String,
        modelID: String,
        revision: String,
        runtime: ProviderAssetRuntime? = nil,
        files: [ProviderAssetFile],
        voiceGroups: [ProviderAssetVoiceGroup]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerKind = providerKind
        self.displayName = displayName
        self.modelID = modelID
        self.revision = revision
        self.runtime = runtime
        self.files = files
        self.voiceGroups = voiceGroups
    }

    public static func load(from manifestURL: URL) throws -> ProviderAssetManifest {
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(ProviderAssetManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as RocaError {
            throw error
        } catch {
            throw RocaError.assetManifestInvalid(error.localizedDescription)
        }
    }

    public var defaultVoiceGroupIDs: [String] {
        voiceGroups.filter(\.defaultInstalled).map(\.id)
    }

    public func voiceGroup(id: String) -> ProviderAssetVoiceGroup? {
        voiceGroups.first { $0.id == id }
    }

    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw RocaError.assetManifestInvalid("Unsupported schema version \(schemaVersion).")
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("displayName must not be empty.")
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("modelID must not be empty.")
        }
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("revision must not be empty.")
        }
        try runtime?.validate()
        guard !files.isEmpty else {
            throw RocaError.assetManifestInvalid("At least one provider asset file is required.")
        }

        var assetIDs = Set<String>()
        for file in files {
            try file.validate(kind: "file")
            guard assetIDs.insert(file.id).inserted else {
                throw RocaError.assetManifestInvalid("Duplicate asset id \(file.id).")
            }
        }

        var groupIDs = Set<String>()
        var voiceIDs = Set<VoiceID>()
        for group in voiceGroups {
            try group.validate()
            guard groupIDs.insert(group.id).inserted else {
                throw RocaError.assetManifestInvalid("Duplicate voice group id \(group.id).")
            }
            for voice in group.voices {
                try voice.validate(groupID: group.id)
                try voice.asset.validate(kind: "voice")
                guard voiceIDs.insert(voice.id).inserted else {
                    throw RocaError.assetManifestInvalid("Duplicate voice id \(voice.id.rawValue).")
                }
                guard assetIDs.insert(voice.asset.id).inserted else {
                    throw RocaError.assetManifestInvalid("Duplicate asset id \(voice.asset.id).")
                }
            }
        }
    }
}

public struct ProviderAssetRuntime: Codable, Equatable, Sendable {
    public var engine: String?
    public var modelArch: String?

    public init(engine: String? = nil, modelArch: String? = nil) {
        self.engine = engine
        self.modelArch = modelArch
    }

    func validate() throws {
        if let engine {
            guard !engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RocaError.assetManifestInvalid("runtime engine must not be empty.")
            }
        }
        if let modelArch {
            guard !modelArch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RocaError.assetManifestInvalid("runtime modelArch must not be empty.")
            }
        }
        guard engine != nil || modelArch != nil else {
            throw RocaError.assetManifestInvalid("runtime must include at least one value.")
        }
    }
}

public struct ProviderAssetFile: Codable, Equatable, Sendable {
    public var id: String
    public var role: ProviderAssetRole
    public var path: String
    public var url: URL
    public var bundlePath: String?
    public var sha256: String
    public var byteCount: Int?
    public var required: Bool

    public init(
        id: String,
        role: ProviderAssetRole,
        path: String,
        url: URL,
        bundlePath: String? = nil,
        sha256: String,
        byteCount: Int?,
        required: Bool
    ) {
        self.id = id
        self.role = role
        self.path = path
        self.url = url
        self.bundlePath = bundlePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.required = required
    }

    func validate(kind: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("\(kind) id must not be empty.")
        }
        try Self.validateRelativePath(path, label: "\(kind) \(id)")
        guard url.scheme == "https" || url.scheme == "file" else {
            throw RocaError.assetManifestInvalid("\(kind) \(id) must use an https or file URL.")
        }
        if let bundlePath {
            try Self.validateRelativePath(bundlePath, label: "\(kind) \(id) bundlePath")
        }
        guard Self.isValidSHA256(sha256) else {
            throw RocaError.assetManifestInvalid("\(kind) \(id) must include a lowercase SHA256.")
        }
        if let byteCount, byteCount <= 0 {
            throw RocaError.assetManifestInvalid("\(kind) \(id) byteCount must be positive.")
        }
    }

    public static func validateRelativePath(_ path: String, label: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RocaError.assetManifestInvalid("\(label) path must not be empty.")
        }
        guard !trimmed.hasPrefix("/") else {
            throw RocaError.assetManifestInvalid("\(label) path must be relative.")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else {
            throw RocaError.assetManifestInvalid("\(label) path must not contain dot segments.")
        }
    }

    public static func isValidSHA256(_ value: String) -> Bool {
        guard value.count == 64 else {
            return false
        }
        return value.allSatisfy { character in
            ("0" ... "9").contains(character) || ("a" ... "f").contains(character)
        }
    }
}

public enum ProviderAssetRole: String, Codable, Equatable, Sendable {
    case model
    case voice
    case runtime
    case resource
}

public struct ProviderAssetVoiceGroup: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var locale: String
    public var defaultInstalled: Bool
    public var engineSupport: ProviderAssetEngineSupport?
    public var voices: [ProviderAssetVoice]

    public init(
        id: String,
        displayName: String,
        locale: String,
        defaultInstalled: Bool,
        engineSupport: ProviderAssetEngineSupport? = nil,
        voices: [ProviderAssetVoice]
    ) {
        self.id = id
        self.displayName = displayName
        self.locale = locale
        self.defaultInstalled = defaultInstalled
        self.engineSupport = engineSupport
        self.voices = voices
    }

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("Voice group id must not be empty.")
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("Voice group \(id) displayName must not be empty.")
        }
        guard !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("Voice group \(id) locale must not be empty.")
        }
        guard !voices.isEmpty else {
            throw RocaError.assetManifestInvalid("Voice group \(id) must include at least one voice.")
        }
    }
}

public enum ProviderAssetEngineSupport: String, Codable, Equatable, Sendable {
    case supported
    case planned
    case disabled
}

public struct ProviderAssetVoice: Codable, Equatable, Sendable {
    public var id: VoiceID
    public var displayName: String
    public var asset: ProviderAssetFile

    public init(id: VoiceID, displayName: String, asset: ProviderAssetFile) {
        self.id = id
        self.displayName = displayName
        self.asset = asset
    }

    func validate(groupID: String) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RocaError.assetManifestInvalid("Voice \(id.rawValue) in group \(groupID) displayName must not be empty.")
        }
    }
}
