import Foundation
import RocaCore

struct LocalProjectFolderDiscoverer {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func discoverProjects(matching query: String, hint: String) throws -> [ProjectDiscoveryCandidate] {
        let bases = candidateBases(from: hint)
        guard !bases.isEmpty else {
            return []
        }

        let normalizedQuery = ProjectIdentityResolver.normalizedKey(query)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        return try bases
            .flatMap { try projectDirectories(under: $0) }
            .compactMap { projectCandidate(for: $0, normalizedQuery: normalizedQuery) }
            .uniqueByPath()
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.project.displayName.localizedCaseInsensitiveCompare($1.project.displayName) == .orderedAscending
            }
    }

    private func candidateBases(from hint: String) -> [URL] {
        var urls = explicitPathHints(from: hint)
        if !urls.isEmpty {
            return uniqueExistingDirectories(urls)
        }

        let normalized = ProjectIdentityResolver.normalizedKey(hint)
        let tokens = Set(normalized.split(separator: " ").map(String.init))

        if tokens.contains("workspace") && tokens.contains("work") {
            urls.append(homeDirectory.appendingPathComponent("Workspace/work", isDirectory: true))
        } else if tokens.contains("workspace") {
            urls.append(homeDirectory.appendingPathComponent("Workspace", isDirectory: true))
        }
        if tokens.contains("desktop") {
            urls.append(homeDirectory.appendingPathComponent("Desktop", isDirectory: true))
        }
        if tokens.contains("documents") {
            urls.append(homeDirectory.appendingPathComponent("Documents", isDirectory: true))
        }
        if tokens.contains("downloads") {
            urls.append(homeDirectory.appendingPathComponent("Downloads", isDirectory: true))
        }

        return uniqueExistingDirectories(urls)
    }

    private func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .map { $0.standardizedFileURL }
            .filter { fileManager.directoryExists(at: $0) }
            .filter { seen.insert($0.path).inserted }
    }

    private func explicitPathHints(from hint: String) -> [URL] {
        let pattern = #"(?:~|/)[^\s,;]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(hint.startIndex..<hint.endIndex, in: hint)
        return regex.matches(in: hint, range: range).compactMap { match in
            guard let captureRange = Range(match.range, in: hint) else {
                return nil
            }
            let rawPath = String(hint[captureRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\"."))
            let expanded = rawPath.hasPrefix("~/")
                ? homeDirectory.path + String(rawPath.dropFirst(1))
                : rawPath
            let url = URL(fileURLWithPath: String(expanded)).standardizedFileURL
            if fileManager.directoryExists(at: url) {
                return url
            }
            if fileManager.fileExists(atPath: url.path) {
                return url.deletingLastPathComponent()
            }
            return nil
        }
    }

    private func projectDirectories(under base: URL, maxDepth: Int = 2) throws -> [URL] {
        var result: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(base, 0)]
        var seen = Set<String>()
        if isLikelyProjectDirectory(base) {
            result.append(base.standardizedFileURL)
        }

        while let item = queue.first {
            queue.removeFirst()
            guard seen.insert(item.url.standardizedFileURL.path).inserted else {
                continue
            }
            let children = try safeDirectoryContents(at: item.url)
            for child in children where shouldConsiderDirectory(child) {
                if isLikelyProjectDirectory(child) {
                    result.append(child.standardizedFileURL)
                }
                if item.depth < maxDepth, !isHeavyDirectory(child) {
                    queue.append((child, item.depth + 1))
                }
            }
        }

        return result
    }

    private func safeDirectoryContents(at url: URL) throws -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
    }

    private func shouldConsiderDirectory(_ url: URL) -> Bool {
        guard fileManager.directoryExists(at: url) else {
            return false
        }
        let name = url.lastPathComponent
        return !["node_modules", ".git", ".build", "DerivedData", "Pods", "vendor"].contains(name)
    }

    private func isHeavyDirectory(_ url: URL) -> Bool {
        ["node_modules", ".git", ".build", "DerivedData", "Pods"].contains(url.lastPathComponent)
    }

    private func isLikelyProjectDirectory(_ url: URL) -> Bool {
        let markers = [".git", "Package.swift", "package.json", "go.mod", "README.md", "README"]
        return markers.contains { marker in
            fileManager.fileExists(atPath: url.appendingPathComponent(marker).path)
        }
    }

    private func projectCandidate(for url: URL, normalizedQuery: String) -> ProjectDiscoveryCandidate? {
        let folderName = url.lastPathComponent
        let normalizedName = ProjectIdentityResolver.normalizedKey(folderName)
        let score = matchScore(normalizedQuery: normalizedQuery, normalizedName: normalizedName)
        guard score > 0 else {
            return nil
        }

        let project = ProjectIdentity(
            id: ProjectID(rawValue: "local-\(normalizedName.replacingOccurrences(of: " ", with: "-"))"),
            displayName: displayName(for: folderName),
            aliases: [folderName],
            localPath: url.path
        )
        return ProjectDiscoveryCandidate(
            project: project,
            confidence: score >= 80 ? .high : .medium,
            score: score,
            evidence: [
                ProjectDiscoveryEvidence(source: "local filesystem", detail: url.path)
            ]
        )
    }

    private func matchScore(normalizedQuery: String, normalizedName: String) -> Int {
        guard !normalizedQuery.isEmpty, !normalizedName.isEmpty else {
            return 0
        }
        if normalizedName == normalizedQuery {
            return 100
        }
        if normalizedName.hasPrefix("\(normalizedQuery) ") {
            return 90
        }
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        let nameTokens = normalizedName.split(separator: " ").map(String.init)
        if !queryTokens.isEmpty,
           queryTokens.allSatisfy({ queryToken in nameTokens.contains { $0.hasPrefix(queryToken) } }) {
            return 80
        }
        if queryTokens.count == 1,
           let queryToken = queryTokens.first,
           queryToken.count <= 4,
           nameTokens.contains(where: { $0.hasPrefix(queryToken) }) {
            return 75
        }
        return 0
    }

    private func displayName(for folderName: String) -> String {
        let acronymTokens = Set(["ai", "api", "aws", "cli", "ml", "ui"])
        return folderName
            .split { !$0.isLetter && !$0.isNumber }
            .map { token -> String in
                let value = String(token)
                return acronymTokens.contains(value.lowercased()) ? value.uppercased() : value.capitalized
            }
            .joined(separator: " ")
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private extension Array where Element == ProjectDiscoveryCandidate {
    func uniqueByPath() -> [ProjectDiscoveryCandidate] {
        var seen = Set<String>()
        return filter { candidate in
            seen.insert(ProjectIdentityResolver.normalizedKey(candidate.project.localPath)).inserted
        }
    }
}
