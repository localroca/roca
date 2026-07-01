import Foundation
import RocaCore
import RocaServices
import RocaTestingSupport
import Testing

@Test
func workspaceResolutionResolvesLocalCatalogBeforeProviderDiscovery() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "other", displayName: "Other", localPath: "/workspace/other"),
                confidence: .high,
                score: 100
            )
        ]
    )
    let service = WorkspaceResolutionService(
        catalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
        ])
    )

    let outcome = try await service.resolve(
        query: "sample-auth",
        prompt: "what endpoints exist?",
        discoverer: agent
    )

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected local resolution, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "sample-auth")
    #expect(resolved.source == .localCatalog)
    #expect(await agent.discoveryQueries.isEmpty)
}

@Test
func workspaceResolutionReportsLocalAmbiguity() async throws {
    let service = WorkspaceResolutionService(
        catalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
            ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend")
        ])
    )

    let outcome = try await service.resolve(query: "nova", prompt: "read README", discoverer: nil)

    guard case .ambiguous(_, let candidates, let source) = outcome else {
        Issue.record("Expected ambiguity, got \(outcome).")
        return
    }
    #expect(source == .localCatalog)
    #expect(candidates.map(\.id) == ["nova-admin", "nova-backend"])
}

@Test
func workspaceResolutionDiscoversLocalFilesystemAmbiguityFromFolderHint() async throws {
    let work = try temporaryWorkspaceWorkFolder()
    try createProjectFolder(named: "nova-admin", under: work)
    try createProjectFolder(named: "nova-backend", under: work)
    try createProjectFolder(named: "nova-web", under: work)
    try createProjectFolder(named: "sample-auth", under: work)
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolveFromLocalFolders(
        query: "nova",
        hint: "It should be somewhere in \(work.path)"
    )

    guard case .ambiguous(_, let candidates, let source) = outcome else {
        Issue.record("Expected local filesystem ambiguity, got \(outcome).")
        return
    }
    #expect(source == .localFilesystem)
    #expect(candidates.map(\.displayName) == ["Nova Admin", "Nova Backend", "Nova Web"])
    #expect(candidates.map(\.localFolderName) == ["nova-admin", "nova-backend", "nova-web"])
}

@Test
func workspaceResolutionDiscoversDirectProjectFolderHint() async throws {
    let work = try temporaryWorkspaceWorkFolder()
    let projectURL = try createProjectFolder(named: "nova-backend", under: work)
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolveFromLocalFolders(
        query: "nova backend",
        hint: "It's at \(projectURL.path)"
    )

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected direct project folder resolution, got \(outcome).")
        return
    }
    #expect(resolved.source == .localFilesystem)
    #expect(resolved.project.displayName == "Nova Backend")
    #expect(resolved.project.localPath == projectURL.path)
}

@Test
func workspaceResolutionResolvesExplicitLocalFilePath() async throws {
    let work = try temporaryWorkspaceWorkFolder()
    let fileURL = work.appendingPathComponent("sales.csv")
    try "Name,Amount\nA,10\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolveLocal(
        query: fileURL.path,
        shouldVerifyBroadMatchWithProvider: false
    )

    guard case .resolved(let project) = outcome else {
        Issue.record("Expected explicit local file path resolution, got \(outcome).")
        return
    }
    #expect(project.displayName == "sales.csv")
    #expect(project.localPath == fileURL.path)
    #expect(project.aliases.contains(fileURL.path))
}

@Test
func workspaceResolutionResolvesNamedDownloadsSpreadsheetFile() async throws {
    let home = try temporaryWorkspaceWorkFolder()
    let downloads = home.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let fileURL = downloads.appendingPathComponent("sample-orders.csv")
    try "Name,Amount\nA,10\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let service = WorkspaceResolutionService(userHomeDirectory: home)

    let outcome = try await service.resolveLocal(
        query: "sample-orders.csv file in the Downloads folder",
        shouldVerifyBroadMatchWithProvider: false
    )

    guard case .resolved(let project) = outcome else {
        Issue.record("Expected named Downloads file resolution, got \(outcome).")
        return
    }
    #expect(project.displayName == "sample-orders.csv")
    #expect(project.localPath == fileURL.path)
    #expect(project.aliases.contains("sample-orders.csv"))
}

@Test
func workspaceResolutionUsesRequestContextForDownloadsSpreadsheetFile() async throws {
    let home = try temporaryWorkspaceWorkFolder()
    let downloads = home.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let fileURL = downloads.appendingPathComponent("sample-orders.csv")
    try "Name,Amount\nA,10\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let service = WorkspaceResolutionService(userHomeDirectory: home)

    let outcome = try await service.resolveLocal(
        query: "sample-orders.csv",
        context: "Can you summarize the sample-orders.csv file in the Downloads folder?",
        shouldVerifyBroadMatchWithProvider: false
    )

    guard case .resolved(let project) = outcome else {
        Issue.record("Expected named Downloads file resolution from context, got \(outcome).")
        return
    }
    #expect(project.displayName == "sample-orders.csv")
    #expect(project.localPath == fileURL.path)
}

@Test
func workspaceResolutionDiscoversProviderProjectAndWritesCache() async throws {
    let discovered = ProjectIdentity(id: "sample-auth", displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth")
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(project: discovered, confidence: .high, score: 120)
        ]
    )
    let writer = RecordingProjectWriter()
    let service = WorkspaceResolutionService(writer: writer)

    let outcome = try await service.resolve(query: "sample-auth", prompt: "what endpoints exist?", discoverer: agent)

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected provider resolution, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "sample-auth")
    #expect(resolved.source == .providerDiscovery)
    #expect(resolved.candidateCount == 1)
    #expect(await agent.discoveryQueries == [ProjectDiscoveryQuery(projectName: "sample-auth", prompt: "what endpoints exist?")])
    #expect(await writer.upsertedProjects == [discovered])
}

@Test
func workspaceResolutionPreservesBroadProviderAmbiguity() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
                confidence: .high,
                score: 140
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
                confidence: .high,
                score: 100
            )
        ]
    )
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolve(query: "nova", prompt: "read README", discoverer: agent)

    guard case .ambiguous(_, let candidates, let source) = outcome else {
        Issue.record("Expected provider ambiguity, got \(outcome).")
        return
    }
    #expect(source == .providerDiscovery)
    #expect(candidates.map(\.id) == ["nova-admin", "nova-backend"])
}

@Test
func workspaceResolutionExcludesNegatedProjectsFromProviderDiscovery() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-backend", displayName: "Nova Backend", localPath: "/workspace/nova-backend"),
                confidence: .high,
                score: 140
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "nova-admin", displayName: "Nova Admin", localPath: "/workspace/nova-admin"),
                confidence: .high,
                score: 100
            )
        ]
    )
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolve(
        query: "nova",
        prompt: "read README",
        discoverer: agent,
        excluding: ["nova-backend"]
    )

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected provider resolution after exclusion, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "nova-admin")
    #expect(resolved.source == .providerDiscovery)
}

@Test
func workspaceResolutionPropagatesProviderDiscoveryFailure() async throws {
    struct DiscoveryFailure: Error {}

    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryError: DiscoveryFailure()
    )
    let service = WorkspaceResolutionService()

    await #expect(throws: DiscoveryFailure.self) {
        _ = try await service.resolve(query: "sample-auth", prompt: "what endpoints exist?", discoverer: agent)
    }
}

private func temporaryWorkspaceWorkFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-workspace-\(UUID().uuidString)", isDirectory: true)
    let work = root.appendingPathComponent("Workspace/work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    return work
}

@discardableResult
private func createProjectFolder(named name: String, under parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "# \(name)\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    return url
}
