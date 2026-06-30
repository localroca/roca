import Foundation

public struct AssistantContextAssembler: Sendable {
    public var recentTaskLimit: Int

    public init(recentTaskLimit: Int = 4) {
        self.recentTaskLimit = recentTaskLimit
    }

    public func contextMessages(
        lastPacket: AssistantContextPacket?,
        recentTasks: [AssistantTaskRecord]
    ) -> [BrainMessage] {
        guard let contextText = contextText(lastPacket: lastPacket, recentTasks: recentTasks) else {
            return []
        }
        return [BrainMessage(role: .assistant, content: contextText)]
    }

    public func memoryMessages(
        userText: String,
        packet: AssistantContextPacket
    ) -> [BrainMessage] {
        [
            BrainMessage(role: .user, content: userText),
            BrainMessage(role: .assistant, content: memoryText(for: packet))
        ]
    }

    public func priorAgentResult(from packet: AssistantContextPacket?) -> AssistantAgentResultContext? {
        packet?.priorAgentResult
    }

    public func currentTask(from packet: AssistantContextPacket?) -> AssistantAgentTaskContext? {
        packet?.currentTask
    }

    public func contextText(
        lastPacket: AssistantContextPacket?,
        recentTasks: [AssistantTaskRecord]
    ) -> String? {
        var sections: [String] = []
        if let lastPacket {
            sections.append(lastPacket.brainContextText)
        }

        let taskLines = recentTasks
            .filter(Self.isContextWorthy)
            .suffix(recentTaskLimit)
            .map(Self.taskContextLine)
        if !taskLines.isEmpty {
            sections.append((["Recent assistant task ledger:"] + taskLines).joined(separator: "\n"))
        }

        guard !sections.isEmpty else {
            return nil
        }
        return (["Assistant context bridge:"] + sections).joined(separator: "\n")
    }

    private static func isContextWorthy(_ task: AssistantTaskRecord) -> Bool {
        switch task.status {
        case .completed, .failed, .cancelled, .waitingForApproval, .waitingForClarification:
            return true
        case .created, .resolvingProject, .running, .formattingResult:
            return false
        }
    }

    private static func taskContextLine(_ task: AssistantTaskRecord) -> String {
        var parts = [
            "\(task.status.rawValue) task",
            task.providerName.map { "provider=\($0)" },
            task.mode.map { "mode=\($0.rawValue)" },
            task.resolvedProject.map { "project=\($0.displayName) at \($0.localPath)" },
            task.projectQuery.map { "projectQuery=\($0)" },
            task.providerSessionID.map { "providerSessionID=\($0)" }
        ].compactMap { $0 }

        if let failurePhase = task.failurePhase, let failureMessage = task.failureMessage {
            parts.append("failure=\(failurePhase): \(singleLine(failureMessage))")
        } else if let resultSummary = task.resultSummary {
            parts.append("summary=\(singleLine(resultSummary))")
        } else if let eventSummary = task.events.last(where: { $0.summary?.isEmpty == false })?.summary {
            parts.append("summary=\(singleLine(eventSummary))")
        }

        return "- " + parts.joined(separator: "; ")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func memoryText(for packet: AssistantContextPacket) -> String {
        if let result = packet.priorAgentResult {
            var parts = [
                "Roca completed a task",
                "provider=\(result.providerName)",
                "mode=\(result.mode.rawValue)",
                result.project.map { "project=\($0.displayName)" },
                "summary=\(Self.singleLine(result.summary))"
            ].compactMap { $0 }
            if let evidence = result.evidence {
                parts.append("evidence=\(evidence.grade.rawValue)")
            }
            return parts.joined(separator: "; ")
        }
        if let task = packet.currentTask {
            return [
                "Roca started a task",
                "provider=\(task.providerName)",
                "mode=\(task.mode.rawValue)",
                task.project.map { "project=\($0.displayName)" },
                "prompt=\(Self.singleLine(task.prompt))"
            ]
            .compactMap { $0 }
            .joined(separator: "; ")
        }
        return "Roca updated assistant context."
    }
}
