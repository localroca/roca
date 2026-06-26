import Foundation
import RocaCore

public enum BuiltInProviderIDs {
    public static let kokoroNative = ProviderID(rawValue: "kokoro")
    public static let macOSVoice = ProviderID(rawValue: "macos-voice")
    public static let appleSpeechSTT = ProviderID(rawValue: "apple-speech")
    public static let moonshineSTT = ProviderID(rawValue: "moonshine")
    public static let whisperKitSTT = ProviderID(rawValue: "whisperkit")
    public static let ollamaBrain = ProviderID(rawValue: "ollama")
    public static let codexAgent = ProviderID(rawValue: "codex-agent")
    public static let claudeCode = ProviderID(rawValue: "claude-code")
}

public enum BuiltInProviderDescriptors {
    public static func phaseOne() -> [ProviderDescriptor] {
        phaseTwo()
    }

    public static func phaseTwo() -> [ProviderDescriptor] {
        [
            ProviderDescriptor(
                id: BuiltInProviderIDs.kokoroNative,
                kind: .tts,
                displayName: "Kokoro",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.macOSVoice,
                kind: .tts,
                displayName: "macOS Voices",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.appleSpeechSTT,
                kind: .stt,
                displayName: "Apple Speech",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.moonshineSTT,
                kind: .stt,
                displayName: "Moonshine",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.whisperKitSTT,
                kind: .stt,
                displayName: "WhisperKit",
                isEnabled: false,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.ollamaBrain,
                kind: .brain,
                displayName: "Ollama",
                isEnabled: true,
                isBuiltIn: true,
                locality: .local
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.codexAgent,
                kind: .agent,
                displayName: "Codex",
                isEnabled: true,
                isBuiltIn: true,
                locality: .remote
            ),
            ProviderDescriptor(
                id: BuiltInProviderIDs.claudeCode,
                kind: .agent,
                displayName: "Claude Code",
                isEnabled: true,
                isBuiltIn: true,
                locality: .remote
            )
        ]
    }
}

public enum BuiltInCapabilityDescriptors {
    public static func phaseTwo() -> [CapabilityDescriptor] {
        [
            CapabilityDescriptor.agent(
                providerID: BuiltInProviderIDs.codexAgent,
                displayName: "Codex",
                capabilities: AgentCapabilities(
                    supportsStreaming: true,
                    supportsToolApprovals: true,
                    supportsLocalExecution: true,
                    locality: .remote,
                    supportedModes: AgentMode.allCases
                ),
                supportsProjectDiscovery: true
            ),
            CapabilityDescriptor.agent(
                providerID: BuiltInProviderIDs.claudeCode,
                displayName: "Claude Code",
                capabilities: AgentCapabilities(
                    supportsStreaming: false,
                    supportsToolApprovals: false,
                    supportsLocalExecution: true,
                    locality: .remote,
                    supportedModes: AgentMode.allCases
                ),
                supportsProjectDiscovery: false,
                approvalBehavior: .policyDriven
            )
        ]
    }
}
