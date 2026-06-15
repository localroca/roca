import RocaCore
import Testing

@Test
func capabilityDescriptorDerivesAgentMetadata() {
    let descriptor = CapabilityDescriptor.agent(
        providerID: "codex-agent",
        displayName: "Codex",
        capabilities: AgentCapabilities(
            supportsStreaming: true,
            supportsToolApprovals: true,
            supportsLocalExecution: true,
            locality: .remote,
            supportedModes: [.ask, .plan, .act]
        ),
        supportsProjectDiscovery: true
    )

    #expect(descriptor.id == "codex-agent")
    #expect(descriptor.providerID == "codex-agent")
    #expect(descriptor.kind == .agent)
    #expect(descriptor.supportedAgentModes == [.ask, .plan, .act])
    #expect(descriptor.workspaceRequirement == .required)
    #expect(descriptor.riskLevel == .high)
    #expect(descriptor.approvalBehavior == .policyDriven)
    #expect(descriptor.supportsStreaming)
    #expect(descriptor.supportsCancellation)
    #expect(descriptor.supportsProjectDiscovery)
    #expect(descriptor.locality == .remote)
}

@Test
func capabilityRegistryStoresAndFiltersCapabilities() async {
    let registry = InMemoryCapabilityRegistry(
        descriptors: [
            CapabilityDescriptor(
                id: "desktop.open-app",
                kind: .desktopAction,
                displayName: "Open App",
                workspaceRequirement: .none,
                riskLevel: .low,
                approvalBehavior: .notRequired,
                supportsStreaming: false,
                supportsCancellation: false,
                supportsProjectDiscovery: false,
                locality: .local
            ),
            CapabilityDescriptor(
                id: "codex-agent",
                providerID: "codex-agent",
                kind: .agent,
                displayName: "Codex",
                supportedAgentModes: [.ask, .plan, .act],
                workspaceRequirement: .required,
                riskLevel: .high,
                approvalBehavior: .policyDriven,
                supportsStreaming: true,
                supportsCancellation: true,
                supportsProjectDiscovery: true,
                locality: .remote
            )
        ]
    )

    #expect(await registry.capabilities().map(\.displayName) == ["Codex", "Open App"])
    #expect(await registry.capabilities(kind: .agent).map(\.id) == ["codex-agent"])

    let localChat = CapabilityDescriptor(
        id: "local.chat",
        kind: .localChat,
        displayName: "Local Chat",
        workspaceRequirement: .optional,
        riskLevel: .low,
        approvalBehavior: .notRequired,
        supportsStreaming: true,
        supportsCancellation: true,
        supportsProjectDiscovery: false,
        locality: .local
    )
    await registry.register(localChat)

    #expect(await registry.capability(id: "local.chat") == localChat)
}
