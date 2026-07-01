import Foundation
import RocaCore
import RocaStorage
import Testing

@Test
func projectIdentityStoreRoundTripsProjects() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let store = JSONProjectIdentityStore(fileURL: directory.appendingPathComponent("projects.json"))
    let project = ProjectIdentity(
        id: "sample-auth",
        displayName: "Sample Auth",
        aliases: ["sample-auth", "auth"],
        localPath: "/workspace/sample-auth",
        gitRemoteURL: "git@github.com:local/sample-auth.git",
        agentThreads: [
            ProjectAgentThreadReference(
                providerID: ProviderID(rawValue: "codex-agent"),
                threadID: "thread-1",
                title: "Logins",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        ]
    )

    try await store.save([project])
    let loaded = try await store.load()

    #expect(loaded == [project])
    #expect(try await store.projects() == [project])
}

@Test
func projectIdentityStoreUpsertsByPath() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RocaProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let store = JSONProjectIdentityStore(fileURL: directory.appendingPathComponent("projects.json"))

    try await store.upsert(ProjectIdentity(id: "old", displayName: "Old", localPath: "/workspace/roca"))
    try await store.upsert(ProjectIdentity(id: "new", displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca"))

    let loaded = try await store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == ProjectID(rawValue: "new"))
    #expect(loaded.first?.aliases == ["assistant"])
}
