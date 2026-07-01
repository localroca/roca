import Foundation
import RocaCore

public enum WorkspaceResolutionSource: String, Codable, Equatable, Sendable {
    case localCatalog
    case localFilesystem
    case providerDiscovery
}

public struct WorkspaceResolvedProject: Equatable, Sendable {
    public var project: ProjectIdentity
    public var source: WorkspaceResolutionSource
    public var candidateCount: Int?

    public init(
        project: ProjectIdentity,
        source: WorkspaceResolutionSource,
        candidateCount: Int? = nil
    ) {
        self.project = project
        self.source = source
        self.candidateCount = candidateCount
    }
}

public enum WorkspaceResolutionOutcome: Equatable, Sendable {
    case resolved(WorkspaceResolvedProject)
    case ambiguous(query: String, candidates: [ProjectIdentity], source: WorkspaceResolutionSource)
    case needsMoreSpecificQuery(query: String, broadMatch: ProjectIdentity)
    case missing(query: String, providerSearched: Bool, candidateCount: Int?)
}

public enum WorkspaceLocalResolutionOutcome: Equatable, Sendable {
    case resolved(ProjectIdentity)
    case ambiguous(query: String, candidates: [ProjectIdentity])
    case needsProviderDiscovery(broadLocalMatch: ProjectIdentity?)
}

public struct WorkspaceResolutionService: Sendable {
    private let catalog: (any ProjectIdentityCatalog)?
    private let writer: (any ProjectIdentityWriting)?
    private let userHomeDirectory: URL

    public init(
        catalog: (any ProjectIdentityCatalog)? = nil,
        writer: (any ProjectIdentityWriting)? = nil,
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.catalog = catalog
        self.writer = writer
        self.userHomeDirectory = userHomeDirectory
    }

    public func resolve(
        query projectName: String,
        prompt: String,
        discoverer: (any AgentProjectDiscovering)?,
        excluding excludedProjectNames: [String] = []
    ) async throws -> WorkspaceResolutionOutcome {
        let localResolution = try await resolveLocal(
            query: projectName,
            shouldVerifyBroadMatchWithProvider: discoverer != nil,
            excluding: excludedProjectNames
        )
        switch localResolution {
        case .resolved(let project):
            return .resolved(WorkspaceResolvedProject(project: project, source: .localCatalog))
        case .ambiguous(_, let candidates):
            return .ambiguous(query: projectName, candidates: candidates, source: .localCatalog)
        case .needsProviderDiscovery(let broadLocalMatch):
            guard let discoverer else {
                if let broadLocalMatch {
                    return .needsMoreSpecificQuery(query: projectName, broadMatch: broadLocalMatch)
                }
                return .missing(query: projectName, providerSearched: false, candidateCount: nil)
            }
            let providerOutcome = try await resolveFromProvider(
                query: projectName,
                prompt: prompt,
                discoverer: discoverer,
                excluding: excludedProjectNames
            )
            if case .missing = providerOutcome, let broadLocalMatch {
                return .needsMoreSpecificQuery(query: projectName, broadMatch: broadLocalMatch)
            }
            return providerOutcome
        }
    }

    public func resolveLocal(
        query projectName: String,
        context: String? = nil,
        shouldVerifyBroadMatchWithProvider: Bool,
        excluding excludedProjectNames: [String] = []
    ) async throws -> WorkspaceLocalResolutionOutcome {
        let allProjects = try await catalog?.projects() ?? []
        let projects = allProjects.filter { !Self.project($0, matchesAny: excludedProjectNames) }
        if let directPathProject = Self.projectForExistingLocalPath(projectName)
            ?? Self.projectForExistingKnownFolderFile(projectName, userHomeDirectory: userHomeDirectory)
            ?? Self.projectForExistingKnownFolderFile(
                [projectName, context].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                userHomeDirectory: userHomeDirectory
            ),
           !Self.project(directPathProject, matchesAny: excludedProjectNames) {
            return .resolved(directPathProject)
        }
        switch ProjectIdentityResolver(projects: projects).resolve(projectName) {
        case .resolved(let project):
            if shouldVerifyBroadMatchWithProvider,
               Self.shouldVerifyBroadProjectResolution(query: projectName, resolvedProject: project) {
                return .needsProviderDiscovery(broadLocalMatch: project)
            }
            return .resolved(project)
        case .ambiguous(let query, let candidates):
            return .ambiguous(query: query, candidates: candidates)
        case .missing:
            return .needsProviderDiscovery(broadLocalMatch: nil)
        }
    }

    public func resolveFromProvider(
        query projectName: String,
        prompt: String,
        discoverer: any AgentProjectDiscovering,
        excluding excludedProjectNames: [String] = []
    ) async throws -> WorkspaceResolutionOutcome {
        let candidates = try await discoverer.discoverProjects(
            matching: ProjectDiscoveryQuery(projectName: projectName, prompt: prompt)
        )
        switch Self.discoveryResolution(
            for: candidates,
            query: projectName,
            excluding: excludedProjectNames
        ) {
        case .resolved(let project):
            try? await writer?.upsert(project)
            return .resolved(
                WorkspaceResolvedProject(
                    project: project,
                    source: .providerDiscovery,
                    candidateCount: candidates.count
                )
            )
        case .ambiguous(_, let candidates):
            return .ambiguous(query: projectName, candidates: candidates, source: .providerDiscovery)
        case .missing:
            return .missing(query: projectName, providerSearched: true, candidateCount: candidates.count)
        }
    }

    public func resolveFromLocalFolders(
        query projectName: String,
        hint: String,
        excluding excludedProjectNames: [String] = []
    ) async throws -> WorkspaceResolutionOutcome {
        let candidates = try LocalProjectFolderDiscoverer().discoverProjects(matching: projectName, hint: hint)
        switch Self.discoveryResolution(for: candidates, query: projectName, excluding: excludedProjectNames) {
        case .resolved(let project):
            try? await writer?.upsert(project)
            return .resolved(
                WorkspaceResolvedProject(
                    project: project,
                    source: .localFilesystem,
                    candidateCount: candidates.count
                )
            )
        case .ambiguous(_, let candidates):
            return .ambiguous(query: projectName, candidates: candidates, source: .localFilesystem)
        case .missing:
            return .missing(query: projectName, providerSearched: false, candidateCount: candidates.count)
        }
    }

    public func remember(_ project: ProjectIdentity) async {
        try? await writer?.upsert(project)
    }

    public static func discoveryResolution(
        for candidates: [ProjectDiscoveryCandidate],
        query: String,
        excluding excludedProjectNames: [String] = []
    ) -> ProjectResolution {
        let usable = candidates
            .filter { $0.confidence != .low }
            .filter { !project($0.project, matchesAny: excludedProjectNames) }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.project.displayName.localizedCaseInsensitiveCompare($1.project.displayName) == .orderedAscending
            }
        guard let best = usable.first else {
            return .missing(query: query)
        }
        let broadMatches = broadDiscoveryMatches(for: query, candidates: usable)
        if broadMatches.count > 1 {
            return .ambiguous(query: query, candidates: broadMatches)
        }
        if let runnerUp = usable.dropFirst().first, best.score - runnerUp.score < 25 {
            return .ambiguous(query: query, candidates: uniqueProjects(usable.map(\.project)))
        }
        return .resolved(best.project)
    }

    private static func shouldVerifyBroadProjectResolution(
        query: String,
        resolvedProject: ProjectIdentity
    ) -> Bool {
        let normalizedQuery = ProjectIdentityResolver.normalizedKey(query)
        let queryTokens = normalizedQuery.split(separator: " ")
        guard queryTokens.count == 1, let queryToken = queryTokens.first, queryToken.count <= 4 else {
            return false
        }
        let names = intrinsicSearchNames(for: resolvedProject)
        let hasExactIntrinsicName = names.contains { ProjectIdentityResolver.normalizedKey($0) == normalizedQuery }
        guard !hasExactIntrinsicName else {
            return false
        }
        let token = String(queryToken)
        return names.contains { broadProjectNameMatches(queryToken: token, name: $0) }
    }

    private static func broadDiscoveryMatches(
        for query: String,
        candidates: [ProjectDiscoveryCandidate]
    ) -> [ProjectIdentity] {
        let normalizedQuery = ProjectIdentityResolver.normalizedKey(query)
        let queryTokens = normalizedQuery.split(separator: " ")
        guard queryTokens.count == 1, let queryToken = queryTokens.first, queryToken.count <= 4 else {
            return []
        }
        let token = String(queryToken)
        return uniqueProjects(candidates.compactMap { candidate in
            intrinsicSearchNames(for: candidate.project).contains { name in
                broadProjectNameMatches(queryToken: token, name: name)
            } ? candidate.project : nil
        })
    }

    private static func intrinsicSearchNames(for project: ProjectIdentity) -> [String] {
        [project.displayName, project.localFolderName, project.gitRemoteName].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    private static func broadProjectNameMatches(queryToken: String, name: String) -> Bool {
        let normalizedName = ProjectIdentityResolver.normalizedKey(name)
        guard !normalizedName.isEmpty else {
            return false
        }
        if normalizedName == queryToken || normalizedName.hasPrefix("\(queryToken) ") {
            return true
        }
        return normalizedName.split(separator: " ").contains { $0.hasPrefix(queryToken) }
    }

    private static func uniqueProjects(_ projects: [ProjectIdentity]) -> [ProjectIdentity] {
        var seen = Set<String>()
        return projects
            .filter { seen.insert(ProjectIdentityResolver.normalizedKey($0.localPath)).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func project(_ project: ProjectIdentity, matchesAny rawNames: [String]) -> Bool {
        rawNames.contains { rawName in
            let normalizedName = ProjectIdentityResolver.normalizedKey(rawName)
            guard !normalizedName.isEmpty else {
                return false
            }
            return intrinsicSearchNames(for: project).contains { name in
                let normalizedProjectName = ProjectIdentityResolver.normalizedKey(name)
                return normalizedProjectName == normalizedName
                    || normalizedProjectName.hasPrefix("\(normalizedName) ")
                    || normalizedProjectName.split(separator: " ").contains { $0 == normalizedName }
            }
        }
    }

    private static func projectForExistingLocalPath(_ rawPath: String) -> ProjectIdentity? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return projectForExistingURL(url, aliases: [trimmed, url.path])
    }

    private static func projectForExistingKnownFolderFile(
        _ rawQuery: String,
        userHomeDirectory: URL
    ) -> ProjectIdentity? {
        let normalizedQuery = ProjectIdentityResolver.normalizedKey(rawQuery)
        let queryTokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        let candidateFolders: [(aliases: Set<String>, url: URL)] = [
            (["download", "downloads"], userHomeDirectory.appendingPathComponent("Downloads")),
            (["desktop"], userHomeDirectory.appendingPathComponent("Desktop")),
            (["document", "documents"], userHomeDirectory.appendingPathComponent("Documents"))
        ]
        let mentionedFolders = candidateFolders.filter { folder in
            folder.aliases.contains { queryTokens.contains($0) }
        }
        guard !mentionedFolders.isEmpty else {
            return nil
        }
        for fileName in localSpreadsheetFileNames(in: rawQuery) {
            for folder in mentionedFolders {
                let url = folder.url.appendingPathComponent(fileName).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continue
                }
                return projectForExistingURL(url, aliases: [rawQuery, fileName, url.path])
            }
        }
        return nil
    }

    private static func localSpreadsheetFileNames(in rawQuery: String) -> [String] {
        let supportedExtensions: Set<String> = ["csv", "tsv", "xlsx"]
        let punctuation = CharacterSet(charactersIn: "\"'`.,;:()[]{}<>")
        var seen = Set<String>()
        return rawQuery
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { rawToken -> String? in
                let token = rawToken
                    .trimmingCharacters(in: punctuation)
                    .replacingOccurrences(of: "\\", with: "/")
                guard !token.isEmpty else {
                    return nil
                }
                let fileName = URL(fileURLWithPath: token).lastPathComponent
                let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
                guard supportedExtensions.contains(fileExtension), seen.insert(fileName).inserted else {
                    return nil
                }
                return fileName
            }
    }

    private static func projectForExistingURL(_ url: URL, aliases: [String]) -> ProjectIdentity {
        let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return ProjectIdentity(
            id: ProjectID(rawValue: "local-path-\(ProjectIdentityResolver.normalizedKey(url.path).replacingOccurrences(of: " ", with: "-"))"),
            displayName: displayName,
            aliases: aliases,
            localPath: url.path
        )
    }
}
