import Foundation
import RocaCore
import RocaStorage
import Testing

@Test
func chatTranscriptLogStoreAppendsAndReadsRecentRows() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RocaChatTranscriptLogStoreTests")
        .appendingPathComponent(UUID().uuidString)
    let store = ChatTranscriptLogStore(logsDirectory: directory)

    let first = chatMessage(id: "first", text: "hello", role: .user)
    let second = chatMessage(
        id: "second",
        text: "hi there",
        role: .assistant,
        metadata: ChatMessageMetadata(
            inputMode: .typed,
            outputMode: .speakAll,
            brainProviderID: ProviderID(rawValue: "ollama"),
            brainModelID: "mistral:7b",
            brainDisplayName: "Mistral 7B",
            directiveType: .respond,
            directivePromptVersion: "assistant-router-test",
            responsePromptVersion: "companion-response-test"
        )
    )
    try await store.append(first)
    try await store.append(second)

    let recent = try await store.recent(limit: 2)
    #expect(recent.map(\.message.id.rawValue) == ["second", "first"])
    #expect(recent.map(\.message.text) == ["hi there", "hello"])
    #expect(recent.first?.message.metadata?.brainProviderID == ProviderID(rawValue: "ollama"))
    #expect(recent.first?.message.metadata?.brainModelID == "mistral:7b")
    #expect(recent.first?.message.metadata?.directiveType == .respond)

    let info = try await store.fileInfo()
    #expect(info.exists)
    #expect(info.rowCount == 2)
    #expect(info.byteCount > 0)
}

@Test
func assistantTurnMetricsLogStoreAppendsAndReadsRecentRows() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RocaMetricsLogStoreTests")
        .appendingPathComponent(UUID().uuidString)
    let store = AssistantTurnMetricsLogStore(logsDirectory: directory)

    let first = metrics(id: "first", totalMilliseconds: 120)
    let second = metrics(id: "second", totalMilliseconds: 240)
    try await store.append(first)
    try await store.append(second)

    let recent = try await store.recent(limit: 2)
    #expect(recent.map(\.turnID.rawValue) == ["second", "first"])
    #expect(recent.map(\.totalMilliseconds) == [240, 120])
}

@Test
func chatTranscriptLogStoreHandlesMissingFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RocaChatTranscriptLogStoreTests")
        .appendingPathComponent(UUID().uuidString)
    let store = ChatTranscriptLogStore(logsDirectory: directory)

    let info = try await store.fileInfo()
    #expect(!info.exists)
    #expect(info.rowCount == 0)
    #expect(info.byteCount == 0)

    try await store.delete()
    await #expect(throws: RocaError.storageFailed("Chat transcript log does not exist.")) {
        try await store.export(to: directory.appendingPathComponent("export.jsonl"))
    }
}

@Test
func chatTranscriptLogStoreExportsAndDeletesWithoutTouchingMetrics() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RocaChatTranscriptLogStoreTests")
        .appendingPathComponent(UUID().uuidString)
    let transcriptStore = ChatTranscriptLogStore(logsDirectory: directory)
    let metricsStore = AssistantTurnMetricsLogStore(logsDirectory: directory)
    let exportURL = directory
        .appendingPathComponent("Exports", isDirectory: true)
        .appendingPathComponent("transcript.jsonl")

    try await transcriptStore.append(chatMessage(id: "first", text: "hello", role: .user))
    try await metricsStore.append(metrics(id: "metrics", totalMilliseconds: 120))
    try await transcriptStore.export(to: exportURL)

    let originalData = try Data(contentsOf: transcriptStore.fileURL)
    let exportedData = try Data(contentsOf: exportURL)
    #expect(exportedData == originalData)

    try await transcriptStore.delete()

    #expect(!FileManager.default.fileExists(atPath: transcriptStore.fileURL.path))
    #expect(try await transcriptStore.recent(limit: 10).isEmpty)
    #expect(try await metricsStore.recent(limit: 10).map(\.turnID.rawValue) == ["metrics"])
}

private func chatMessage(
    id: String,
    text: String,
    role: ChatMessageRole,
    metadata: ChatMessageMetadata? = nil
) -> ChatMessage {
    ChatMessage(
        id: ChatMessageID(rawValue: id),
        turnID: BrainRequestID(rawValue: "turn-\(id)"),
        role: role,
        source: role == .user ? .typed : .assistant,
        text: text,
        status: .completed,
        metadata: metadata,
        createdAt: Date(timeIntervalSince1970: 1)
    )
}

private func metrics(id: String, totalMilliseconds: Int) -> AssistantTurnMetrics {
    let startedAt = Date(timeIntervalSince1970: 1)
    return AssistantTurnMetrics(
        turnID: BrainRequestID(rawValue: id),
        startedAt: startedAt,
        completedAt: startedAt.addingTimeInterval(Double(totalMilliseconds) / 1_000),
        outcome: .completed,
        directiveType: .respond,
        totalMilliseconds: totalMilliseconds,
        setupMilliseconds: 1,
        recordingMilliseconds: 2,
        transcriptionMilliseconds: 3,
        directiveBrainMilliseconds: 4,
        responseBrainMilliseconds: 5,
        actionMilliseconds: nil,
        ttsPreparationMilliseconds: 6,
        ttsFirstAudioMilliseconds: 7,
        ttsSynthesisMilliseconds: 8,
        ttsAudioDurationMilliseconds: 9,
        ttsPlaybackMilliseconds: 10,
        ttsUtteranceCount: 1,
        ttsAudioChunkCount: 1,
        capturedAudioFrameCount: 11,
        droppedAudioFrameCount: 0
    )
}
