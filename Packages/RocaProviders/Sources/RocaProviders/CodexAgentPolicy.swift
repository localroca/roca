import Foundation
import RocaCore

enum CodexAgentPolicy {
    static func approvalScopedRequest(_ request: AgentRunRequest) -> AgentRunRequest {
        var dataScopes = request.dataScopes
        var actionScopes = request.actionScopes

        if request.workspacePath != nil {
            dataScopes.append(.workspaceFiles)
            actionScopes.append(contentsOf: [.readWorkspace, .runCommands])
        }
        if request.mode == .act {
            actionScopes.append(.editWorkspace)
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
        let scopedRequest = approvalScopedRequest(request)
        return AgentApprovalRequirement(
            providerID: providerID,
            role: scopedRequest.role,
            mode: scopedRequest.mode,
            workspacePath: scopedRequest.workspacePath,
            dataScopes: scopedRequest.dataScopes,
            actionScopes: scopedRequest.actionScopes
        )
    }

    static func requiresRocaApproval(_ request: AgentRunRequest) -> Bool {
        let scopedRequest = approvalScopedRequest(request)
        if scopedRequest.mode == .act {
            return true
        }

        let sensitiveDataScopes: Set<AgentDataScope> = [
            .selectedText,
            .transcriptSummary,
            .activeAppMetadata,
            .memory,
            .logs
        ]
        if !Set(scopedRequest.dataScopes).isDisjoint(with: sensitiveDataScopes) {
            return true
        }

        let elevatedActionScopes: Set<AgentActionScope> = [
            .editWorkspace,
            .useNetwork,
            .useBrowser,
            .createArtifacts,
            .pushBranch
        ]
        return !Set(scopedRequest.actionScopes).isDisjoint(with: elevatedActionScopes)
    }

    static func threadSandboxMode(for request: AgentRunRequest) -> String {
        request.mode == .act ? "workspace-write" : "read-only"
    }

    static func turnSandboxPolicy(for request: AgentRunRequest) -> CodexJSONValue {
        let scopedRequest = approvalScopedRequest(request)
        let networkAccess = scopedRequest.actionScopes.contains(.useNetwork)
        if scopedRequest.mode == .act {
            return .object([
                "type": .string("workspaceWrite"),
                "networkAccess": .bool(networkAccess),
                "writableRoots": .array(scopedRequest.workspacePath.map { [.string($0)] } ?? [])
            ])
        }
        return .object([
            "type": .string("readOnly"),
            "networkAccess": .bool(networkAccess)
        ])
    }
}
