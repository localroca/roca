import RocaCore
import Testing

@Test
func projectIdentityResolverMatchesAliasFolderAndGitRemote() {
    let resolver = ProjectIdentityResolver(projects: [
        project(displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth", gitRemoteURL: "git@github.com:local/sample-auth.git"),
        project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")
    ])

    #expect(resolver.resolve("sample-auth") == .resolved(project(displayName: "Sample Auth", aliases: ["sample-auth"], localPath: "/workspace/sample-auth", gitRemoteURL: "git@github.com:local/sample-auth.git")))
    #expect(resolver.resolve("/workspace/roca") == .resolved(project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")))
    #expect(resolver.resolve("assistant") == .resolved(project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")))
}

@Test
func projectIdentityResolverReturnsAmbiguousPrefixMatches() {
    let backend = project(displayName: "Nova Backend", aliases: ["nova-backend"], localPath: "/workspace/nova-backend")
    let admin = project(displayName: "Nova Admin", aliases: ["nova-admin"], localPath: "/workspace/nova-admin")
    let frontend = project(displayName: "Nova Frontend", aliases: ["nova-frontend"], localPath: "/workspace/nova-frontend")
    let resolver = ProjectIdentityResolver(projects: [backend, admin, frontend])

    #expect(resolver.resolve("nova") == .ambiguous(query: "nova", candidates: [admin, backend, frontend]))
}

@Test
func projectIdentityResolverReportsMissingProjects() {
    let resolver = ProjectIdentityResolver(projects: [
        project(displayName: "Roca", aliases: [], localPath: "/workspace/roca")
    ])

    #expect(resolver.resolve("sample-auth") == .missing(query: "sample-auth"))
}

private func project(
    displayName: String,
    aliases: [String],
    localPath: String,
    gitRemoteURL: String? = nil
) -> ProjectIdentity {
    ProjectIdentity(
        id: ProjectID(rawValue: localPath),
        displayName: displayName,
        aliases: aliases,
        localPath: localPath,
        gitRemoteURL: gitRemoteURL
    )
}
