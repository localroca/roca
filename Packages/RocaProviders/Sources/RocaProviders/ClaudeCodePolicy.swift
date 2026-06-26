import Foundation
import RocaCore

enum ClaudeCodePolicy {
    static let setupInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let setupGuidance = "Install Claude Code, sign in with a Claude Code-capable account, then recheck Claude Code."

    static func approvalScopedRequest(_ request: AgentRunRequest) -> AgentRunRequest {
        var dataScopes = request.dataScopes
        var actionScopes = request.actionScopes

        if request.workspacePath != nil {
            dataScopes.append(.workspaceFiles)
            actionScopes.append(.readWorkspace)
        }
        if request.mode == .act {
            actionScopes.append(contentsOf: [.runCommands, .editWorkspace])
        }

        return AgentRunRequest(
            runID: request.runID,
            prompt: request.prompt,
            mode: request.mode,
            role: request.role,
            workspacePath: request.workspacePath,
            modelID: request.modelID,
            dataScopes: dataScopes,
            actionScopes: actionScopes,
            metadata: request.metadata
        )
    }

    static func approvalRequirement(providerID: ProviderID, request: AgentRunRequest) -> AgentApprovalRequirement {
        let scoped = approvalScopedRequest(request)
        return AgentApprovalRequirement(
            providerID: providerID,
            role: scoped.role,
            mode: scoped.mode,
            workspacePath: scoped.workspacePath,
            dataScopes: scoped.dataScopes,
            actionScopes: scoped.actionScopes
        )
    }

    static func requiresRocaApproval(_ request: AgentRunRequest) -> Bool {
        let scoped = approvalScopedRequest(request)
        if scoped.mode == .act {
            return true
        }
        let sensitiveDataScopes: Set<AgentDataScope> = [
            .selectedText,
            .transcriptSummary,
            .activeAppMetadata,
            .memory,
            .logs
        ]
        if !Set(scoped.dataScopes).isDisjoint(with: sensitiveDataScopes) {
            return true
        }
        let elevatedActionScopes: Set<AgentActionScope> = [
            .editWorkspace,
            .useNetwork,
            .useBrowser,
            .createArtifacts,
            .pushBranch
        ]
        return !Set(scoped.actionScopes).isDisjoint(with: elevatedActionScopes)
    }

    static func arguments(for request: AgentRunRequest) -> [String] {
        var arguments = [
            "-p",
            request.prompt,
            "--output-format",
            "text",
            "--no-session-persistence",
            "--max-turns",
            "20",
            "--permission-mode",
            permissionMode(for: request),
            "--tools",
            tools(for: request).joined(separator: ",")
        ]
        if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
            arguments.append(contentsOf: ["--model", modelID])
        }
        return arguments
    }

    private static func permissionMode(for request: AgentRunRequest) -> String {
        switch request.mode {
        case .ask:
            "default"
        case .plan:
            "plan"
        case .act:
            "acceptEdits"
        }
    }

    private static func tools(for request: AgentRunRequest) -> [String] {
        switch request.mode {
        case .ask:
            ["Read", "Glob", "Grep"]
        case .plan:
            ["Read", "Glob", "Grep"]
        case .act:
            ["Read", "Glob", "Grep", "Bash", "Edit", "Write"]
        }
    }
}
