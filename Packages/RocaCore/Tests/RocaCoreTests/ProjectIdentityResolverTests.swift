import RocaCore
import Testing

@Test
func projectIdentityResolverMatchesAliasFolderAndGitRemote() {
    let resolver = ProjectIdentityResolver(projects: [
        project(displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth", gitRemoteURL: "git@github.com:local/uni-auth.git"),
        project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")
    ])

    #expect(resolver.resolve("uni-auth") == .resolved(project(displayName: "Uni Auth", aliases: ["uni-auth"], localPath: "/workspace/uni-auth", gitRemoteURL: "git@github.com:local/uni-auth.git")))
    #expect(resolver.resolve("/workspace/roca") == .resolved(project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")))
    #expect(resolver.resolve("assistant") == .resolved(project(displayName: "Roca", aliases: ["assistant"], localPath: "/workspace/roca", gitRemoteURL: "https://github.com/localroca/roca.git")))
}

@Test
func projectIdentityResolverReturnsAmbiguousPrefixMatches() {
    let backend = project(displayName: "TER Backend", aliases: ["ter-backend"], localPath: "/workspace/ter-backend")
    let admin = project(displayName: "TER Admin", aliases: ["ter-admin"], localPath: "/workspace/ter-admin")
    let frontend = project(displayName: "TER Frontend", aliases: ["ter-frontend"], localPath: "/workspace/ter-frontend")
    let resolver = ProjectIdentityResolver(projects: [backend, admin, frontend])

    #expect(resolver.resolve("ter") == .ambiguous(query: "ter", candidates: [admin, backend, frontend]))
}

@Test
func projectIdentityResolverReportsMissingProjects() {
    let resolver = ProjectIdentityResolver(projects: [
        project(displayName: "Roca", aliases: [], localPath: "/workspace/roca")
    ])

    #expect(resolver.resolve("uni-auth") == .missing(query: "uni-auth"))
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
