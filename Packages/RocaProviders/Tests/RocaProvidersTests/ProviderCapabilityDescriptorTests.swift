import RocaCore
import RocaProviders
import Testing

@Test
func builtInCapabilityDescriptorsIncludeCodexAgent() {
    let codex = BuiltInCapabilityDescriptors.phaseTwo().first { $0.providerID == BuiltInProviderIDs.codexAgent }

    #expect(codex?.id == CapabilityID(rawValue: BuiltInProviderIDs.codexAgent.rawValue))
    #expect(codex?.kind == .agent)
    #expect(codex?.displayName == "Codex")
    #expect(codex?.supportedAgentModes == AgentMode.allCases)
    #expect(codex?.workspaceRequirement == .required)
    #expect(codex?.riskLevel == .high)
    #expect(codex?.approvalBehavior == .policyDriven)
    #expect(codex?.supportsCancellation == true)
    #expect(codex?.supportsProjectDiscovery == true)
}
