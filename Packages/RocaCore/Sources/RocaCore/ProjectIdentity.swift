import Foundation

public struct ProjectIdentity: Codable, Equatable, Identifiable, Sendable {
    public var id: ProjectID
    public var displayName: String
    public var aliases: [String]
    public var localPath: String
    public var gitRemoteURL: String?
    public var agentThreads: [ProjectAgentThreadReference]

    public init(
        id: ProjectID = .make(),
        displayName: String,
        aliases: [String] = [],
        localPath: String,
        gitRemoteURL: String? = nil,
        agentThreads: [ProjectAgentThreadReference] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = Self.normalizedList(aliases)
        self.localPath = localPath
        self.gitRemoteURL = gitRemoteURL
        self.agentThreads = agentThreads
    }

    public var localFolderName: String {
        URL(fileURLWithPath: localPath).lastPathComponent
    }

    public var gitRemoteName: String? {
        guard let gitRemoteURL else {
            return nil
        }
        var value = gitRemoteURL
        if let lastSlash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: lastSlash)...])
        }
        if let colon = value.lastIndex(of: ":") {
            value = String(value[value.index(after: colon)...])
        }
        return value.replacingOccurrences(of: ".git", with: "")
    }

    public var searchNames: [String] {
        Self.normalizedList([displayName, localFolderName, gitRemoteName].compactMap { $0 } + aliases)
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = ProjectIdentityResolver.normalizedKey(trimmed)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}

public struct ProjectAgentThreadReference: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var threadID: String
    public var title: String?
    public var updatedAt: Date?

    public init(providerID: ProviderID, threadID: String, title: String? = nil, updatedAt: Date? = nil) {
        self.providerID = providerID
        self.threadID = threadID
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum ProjectResolution: Equatable, Sendable {
    case resolved(ProjectIdentity)
    case ambiguous(query: String, candidates: [ProjectIdentity])
    case missing(query: String)
}

public protocol ProjectIdentityCatalog: Sendable {
    func projects() async throws -> [ProjectIdentity]
}

public protocol ProjectIdentityWriting: Sendable {
    func upsert(_ project: ProjectIdentity) async throws
}

public struct ProjectDiscoveryQuery: Equatable, Sendable {
    public var projectName: String
    public var prompt: String

    public init(projectName: String, prompt: String) {
        self.projectName = projectName
        self.prompt = prompt
    }
}

public enum ProjectDiscoveryConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public struct ProjectDiscoveryEvidence: Codable, Equatable, Sendable {
    public var source: String
    public var detail: String

    public init(source: String, detail: String) {
        self.source = source
        self.detail = detail
    }
}

public struct ProjectDiscoveryCandidate: Equatable, Sendable {
    public var project: ProjectIdentity
    public var confidence: ProjectDiscoveryConfidence
    public var score: Int
    public var evidence: [ProjectDiscoveryEvidence]

    public init(
        project: ProjectIdentity,
        confidence: ProjectDiscoveryConfidence,
        score: Int,
        evidence: [ProjectDiscoveryEvidence] = []
    ) {
        self.project = project
        self.confidence = confidence
        self.score = score
        self.evidence = evidence
    }
}

public protocol AgentProjectDiscovering: Sendable {
    func discoverProjects(matching query: ProjectDiscoveryQuery) async throws -> [ProjectDiscoveryCandidate]
}

public struct StaticProjectIdentityCatalog: ProjectIdentityCatalog {
    private let knownProjects: [ProjectIdentity]

    public init(_ knownProjects: [ProjectIdentity]) {
        self.knownProjects = knownProjects
    }

    public func projects() async throws -> [ProjectIdentity] {
        knownProjects
    }
}

public struct ProjectIdentityResolver: Sendable {
    public var projects: [ProjectIdentity]

    public init(projects: [ProjectIdentity] = []) {
        self.projects = projects
    }

    public func resolve(_ rawQuery: String?) -> ProjectResolution {
        guard let query = clean(rawQuery) else {
            return .missing(query: "")
        }
        let normalizedQuery = Self.normalizedKey(query)
        let directPathMatches = projects.filter { project in
            project.localPath == query
                || URL(fileURLWithPath: project.localPath).standardizedFileURL.path == URL(fileURLWithPath: query).standardizedFileURL.path
        }
        if !directPathMatches.isEmpty {
            return resolution(for: directPathMatches, query: query)
        }

        let exactMatches = projects.filter { project in
            project.searchNames.contains { Self.normalizedKey($0) == normalizedQuery }
        }
        if !exactMatches.isEmpty {
            return resolution(for: exactMatches, query: query)
        }

        let tokenMatches = projects.filter { project in
            project.searchNames.contains { name in
                Self.matches(normalizedQuery: normalizedQuery, normalizedName: Self.normalizedKey(name))
            }
        }
        guard !tokenMatches.isEmpty else {
            return .missing(query: query)
        }
        return resolution(for: tokenMatches, query: query)
    }

    public static func normalizedKey(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func resolution(for matches: [ProjectIdentity], query: String) -> ProjectResolution {
        let unique = uniqueProjects(matches)
        if unique.count == 1, let project = unique.first {
            return .resolved(project)
        }
        return .ambiguous(query: query, candidates: unique)
    }

    private func uniqueProjects(_ matches: [ProjectIdentity]) -> [ProjectIdentity] {
        var seen = Set<ProjectID>()
        return matches
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func matches(normalizedQuery: String, normalizedName: String) -> Bool {
        guard !normalizedQuery.isEmpty else {
            return false
        }
        if normalizedName.hasPrefix(normalizedQuery) {
            return true
        }
        let queryTokens = normalizedQuery.split(separator: " ")
        let nameTokens = normalizedName.split(separator: " ")
        return !queryTokens.isEmpty && queryTokens.allSatisfy { queryToken in
            nameTokens.contains { nameToken in
                nameToken.hasPrefix(queryToken)
            }
        }
    }
}
