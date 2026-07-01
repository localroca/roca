import RocaCore
import Testing

@Test
func assistantTaskLedgerStoresEventsAndStatus() async {
    let ledger = InMemoryAssistantTaskLedger()
    let task = await ledger.createTask(
        AssistantTaskRecord(
            id: "task-1",
            turnID: "turn-1",
            userRequest: "ask Codex about logins",
            capabilityID: "codex-agent",
            providerID: "codex-agent",
            providerName: "Codex",
            mode: .ask,
            projectQuery: "sample-auth"
        )
    )

    await ledger.updateTask(
        task.id,
        status: .running,
        event: AssistantTaskEvent(
            kind: .providerRunStarted,
            turnID: "turn-1",
            status: .running,
            phase: "agentRun",
            summary: "Codex started."
        )
    ) { record in
        record.providerRunID = "run-1"
    }
    await ledger.updateTask(
        task.id,
        status: .completed,
        event: AssistantTaskEvent(
            kind: .completed,
            turnID: "turn-1",
            status: .completed,
            phase: "finish",
            summary: "Codex found the endpoints."
        )
    ) { record in
        record.resultSummary = "Codex found the endpoints."
    }

    let saved = await ledger.task(id: task.id)
    #expect(saved?.status == .completed)
    #expect(saved?.providerRunID == "run-1")
    #expect(saved?.resultSummary == "Codex found the endpoints.")
    #expect(saved?.events.map(\.kind) == [.created, .providerRunStarted, .completed])
}

@Test
func assistantTaskLedgerFiltersByTurn() async {
    let ledger = InMemoryAssistantTaskLedger()
    await ledger.createTask(AssistantTaskRecord(id: "first", turnID: "turn-a", userRequest: "first"))
    await ledger.createTask(AssistantTaskRecord(id: "second", turnID: "turn-b", userRequest: "second"))

    #expect(await ledger.tasks(for: "turn-a").map(\.id) == ["first"])
    await ledger.clear()
    #expect(await ledger.tasks().isEmpty)
}
