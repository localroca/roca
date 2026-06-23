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
            ProjectIdentity(id: "uni-auth", displayName: "UNI Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
        ])
    )

    let outcome = try await service.resolve(
        query: "uni-auth",
        prompt: "what endpoints exist?",
        discoverer: agent
    )

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected local resolution, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "uni-auth")
    #expect(resolved.source == .localCatalog)
    #expect(await agent.discoveryQueries.isEmpty)
}

@Test
func workspaceResolutionReportsLocalAmbiguity() async throws {
    let service = WorkspaceResolutionService(
        catalog: StaticProjectIdentityCatalog([
            ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
            ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend")
        ])
    )

    let outcome = try await service.resolve(query: "ter", prompt: "read README", discoverer: nil)

    guard case .ambiguous(_, let candidates, let source) = outcome else {
        Issue.record("Expected ambiguity, got \(outcome).")
        return
    }
    #expect(source == .localCatalog)
    #expect(candidates.map(\.id) == ["ter-admin", "ter-backend"])
}

@Test
func workspaceResolutionDiscoversProviderProjectAndWritesCache() async throws {
    let discovered = ProjectIdentity(id: "uni-auth", displayName: "UNI Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth")
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(project: discovered, confidence: .high, score: 120)
        ]
    )
    let writer = RecordingProjectWriter()
    let service = WorkspaceResolutionService(writer: writer)

    let outcome = try await service.resolve(query: "uni-auth", prompt: "what endpoints exist?", discoverer: agent)

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected provider resolution, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "uni-auth")
    #expect(resolved.source == .providerDiscovery)
    #expect(resolved.candidateCount == 1)
    #expect(await agent.discoveryQueries == [ProjectDiscoveryQuery(projectName: "uni-auth", prompt: "what endpoints exist?")])
    #expect(await writer.upsertedProjects == [discovered])
}

@Test
func workspaceResolutionPreservesBroadProviderAmbiguity() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
                confidence: .high,
                score: 140
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
                confidence: .high,
                score: 100
            )
        ]
    )
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolve(query: "ter", prompt: "read README", discoverer: agent)

    guard case .ambiguous(_, let candidates, let source) = outcome else {
        Issue.record("Expected provider ambiguity, got \(outcome).")
        return
    }
    #expect(source == .providerDiscovery)
    #expect(candidates.map(\.id) == ["ter-admin", "ter-backend"])
}

@Test
func workspaceResolutionExcludesNegatedProjectsFromProviderDiscovery() async throws {
    let agent = RecordingSessionAgentProvider(
        responseText: "unused",
        discoveryCandidates: [
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-backend", displayName: "TER Backend", localPath: "/workspace/ter-backend"),
                confidence: .high,
                score: 140
            ),
            ProjectDiscoveryCandidate(
                project: ProjectIdentity(id: "ter-admin", displayName: "TER Admin", localPath: "/workspace/ter-admin"),
                confidence: .high,
                score: 100
            )
        ]
    )
    let service = WorkspaceResolutionService()

    let outcome = try await service.resolve(
        query: "ter",
        prompt: "read README",
        discoverer: agent,
        excluding: ["ter-backend"]
    )

    guard case .resolved(let resolved) = outcome else {
        Issue.record("Expected provider resolution after exclusion, got \(outcome).")
        return
    }
    #expect(resolved.project.id == "ter-admin")
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
        _ = try await service.resolve(query: "uni-auth", prompt: "what endpoints exist?", discoverer: agent)
    }
}
