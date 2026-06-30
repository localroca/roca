import Foundation

public struct AssistantContextPacket: Codable, Equatable, Sendable {
    public var currentTask: AssistantAgentTaskContext?
    public var priorAgentResult: AssistantAgentResultContext?
    public var approval: AssistantApprovalContext?

    public init(
        currentTask: AssistantAgentTaskContext? = nil,
        priorAgentResult: AssistantAgentResultContext? = nil,
        approval: AssistantApprovalContext? = nil
    ) {
        self.currentTask = currentTask
        self.priorAgentResult = priorAgentResult
        self.approval = approval
    }

    public var brainContextText: String {
        var lines = ["Context packet:"]
        if let currentTask {
            lines.append("- Current task: \(currentTask.brainContextText)")
        }
        if let priorAgentResult {
            lines.append("- Prior agent result: \(priorAgentResult.brainContextText)")
        }
        if let approval {
            lines.append("- Approval policy: \(approval.brainContextText)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct AssistantAgentTaskContext: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var providerName: String
    public var mode: AgentMode
    public var prompt: String
    public var project: ProjectIdentity?

    public init(
        providerID: ProviderID,
        providerName: String,
        mode: AgentMode,
        prompt: String,
        project: ProjectIdentity?
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.mode = mode
        self.prompt = prompt
        self.project = project
    }

    public var brainContextText: String {
        let projectText = project.map { "\($0.displayName) at \($0.localPath)" } ?? "no specific project"
        return "provider=\(providerName) (\(providerID.rawValue)); mode=\(mode.rawValue); project=\(projectText); prompt=\(prompt)"
    }
}

public struct AssistantAgentResultContext: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var providerName: String
    public var mode: AgentMode
    public var project: ProjectIdentity?
    public var summary: String
    public var detailsMarkdown: String?
    public var evidence: AssistantEvidenceSummary?

    public init(
        providerID: ProviderID,
        providerName: String,
        mode: AgentMode,
        project: ProjectIdentity?,
        summary: String,
        detailsMarkdown: String?,
        evidence: AssistantEvidenceSummary? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.mode = mode
        self.project = project
        self.summary = summary
        self.detailsMarkdown = detailsMarkdown
        self.evidence = evidence
    }

    public var brainContextText: String {
        let projectText = project.map { "\($0.displayName) at \($0.localPath)" } ?? "no specific project"
        var base = "provider=\(providerName) (\(providerID.rawValue)); mode=\(mode.rawValue); project=\(projectText); summary=\(summary)"
        if let evidence {
            base += "\nEvidence: \(evidence.brainContextText)"
        }
        guard let detailsMarkdown = AssistantContextBudgeter.budgetPriorDetails(detailsMarkdown) else {
            return base
        }
        return "\(base)\nDetails:\n\(detailsMarkdown)"
    }
}

public struct AssistantApprovalContext: Codable, Equatable, Sendable {
    public var riskLevel: CapabilityRiskLevel
    public var approvalBehavior: CapabilityApprovalBehavior
    public var decision: AgentApprovalDecision?

    public init(
        riskLevel: CapabilityRiskLevel,
        approvalBehavior: CapabilityApprovalBehavior,
        decision: AgentApprovalDecision? = nil
    ) {
        self.riskLevel = riskLevel
        self.approvalBehavior = approvalBehavior
        self.decision = decision
    }

    public var brainContextText: String {
        let decisionText = decision.map(\.rawValue) ?? "notRequested"
        return "risk=\(riskLevel.rawValue); behavior=\(approvalBehavior.rawValue); decision=\(decisionText)"
    }
}
