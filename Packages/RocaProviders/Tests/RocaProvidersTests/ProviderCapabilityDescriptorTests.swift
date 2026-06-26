import RocaCore
import RocaProviders
import Testing

@Test
func builtInCapabilityDescriptorsIncludeCodexAgent() {
    let codex = BuiltInCapabilityDescriptors.phaseTwo().first { $0.providerID == BuiltInProviderIDs.codexAgent }
    let claude = BuiltInCapabilityDescriptors.phaseTwo().first { $0.providerID == BuiltInProviderIDs.claudeCode }

    #expect(codex?.id == CapabilityID(rawValue: BuiltInProviderIDs.codexAgent.rawValue))
    #expect(codex?.kind == .agent)
    #expect(codex?.displayName == "Codex")
    #expect(codex?.supportedAgentModes == AgentMode.allCases)
    #expect(codex?.workspaceRequirement == .required)
    #expect(codex?.riskLevel == .high)
    #expect(codex?.approvalBehavior == .policyDriven)
    #expect(codex?.supportsCancellation == true)
    #expect(codex?.supportsProjectDiscovery == true)

    #expect(claude?.id == CapabilityID(rawValue: BuiltInProviderIDs.claudeCode.rawValue))
    #expect(claude?.kind == .agent)
    #expect(claude?.displayName == "Claude Code")
    #expect(claude?.supportedAgentModes == AgentMode.allCases)
    #expect(claude?.workspaceRequirement == .required)
    #expect(claude?.riskLevel == .high)
    #expect(claude?.approvalBehavior == .policyDriven)
    #expect(claude?.supportsCancellation == true)
    #expect(claude?.supportsProjectDiscovery == false)
}
