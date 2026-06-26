import Foundation
@testable import RocaServices
import Testing

@Test
func claudeCodePathConfiguratorAddsZshPathBlockWhenNeeded() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/bin/zsh",
        environmentPath: "/usr/bin:/bin"
    )

    let notes = configurator.ensurePathIfNeeded()
    let zshrc = home.appendingPathComponent(".zshrc")
    let contents = try String(contentsOf: zshrc, encoding: .utf8)

    #expect(notes.contains { $0.contains("~/.zshrc") })
    #expect(contents.contains("# >>> Roca Claude Code PATH >>>"))
    #expect(contents.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
}

@Test
func claudeCodePathConfiguratorIsIdempotent() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/bin/zsh",
        environmentPath: "/usr/bin:/bin"
    )

    _ = configurator.ensurePathIfNeeded()
    _ = configurator.ensurePathIfNeeded()

    let contents = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
    #expect(contents.components(separatedBy: "# >>> Roca Claude Code PATH >>>").count == 2)
}

@Test
func claudeCodePathConfiguratorSkipsProfileWhenPathAlreadyVisible() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)
    let binPath = home.appendingPathComponent(".local/bin").path

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/bin/zsh",
        environmentPath: "/usr/bin:\(binPath):/bin"
    )

    let notes = configurator.ensurePathIfNeeded()

    #expect(notes.contains { $0.contains("available at ~/.local/bin/claude") })
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path) == false)
}

@Test
func claudeCodePathConfiguratorUsesBashProfileForBash() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/bin/bash",
        environmentPath: "/usr/bin:/bin"
    )

    _ = configurator.ensurePathIfNeeded()

    let bashProfile = home.appendingPathComponent(".bash_profile")
    let contents = try String(contentsOf: bashProfile, encoding: .utf8)
    #expect(contents.contains("Roca Claude Code PATH"))
}

@Test
func claudeCodePathConfiguratorUsesFishConfigForFish() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/opt/homebrew/bin/fish",
        environmentPath: "/usr/bin:/bin"
    )

    _ = configurator.ensurePathIfNeeded()

    let fishConfig = home.appendingPathComponent(".config/fish/config.fish")
    let contents = try String(contentsOf: fishConfig, encoding: .utf8)
    #expect(contents.contains("fish_add_path -g \"$HOME/.local/bin\""))
}

@Test
func claudeCodePathConfiguratorLeavesUnsupportedShellAlone() throws {
    let home = try temporaryHome()
    try installFakeClaude(in: home)

    let configurator = ClaudeCodePathConfigurator(
        homeDirectory: home,
        shellPath: "/bin/tcsh",
        environmentPath: "/usr/bin:/bin"
    )

    let notes = configurator.ensurePathIfNeeded()

    #expect(notes.contains { $0.contains("Add ~/.local/bin to your shell PATH") })
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".profile").path) == false)
}

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-provider-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func installFakeClaude(in home: URL) throws {
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
}
