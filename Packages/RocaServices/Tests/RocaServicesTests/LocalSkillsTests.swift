import Foundation
import RocaCore
import RocaServices
import Testing

@Test
func codebaseSkillFindsNestedJavaScriptCdkInfrastructure() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-codebase-skill-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile("module github.com/example/uni-auth\n\ngo 1.24\n", at: "go.mod", in: workspaceURL)
    try writeFile(
        """
        package main

        func main() {}
        """,
        at: "cmd/server/main.go",
        in: workspaceURL
    )
    try writeFile(
        """
        {"app":"node bin/infra.js"}
        """,
        at: "infra/cdk.json",
        in: workspaceURL
    )
    try writeFile(
        """
        {
          "name": "uni-auth-infra",
          "type": "module",
          "dependencies": {
            "aws-cdk-lib": "^2.0.0",
            "constructs": "^10.0.0"
          }
        }
        """,
        at: "infra/package.json",
        in: workspaceURL
    )
    try writeFile(
        """
        import { App } from 'aws-cdk-lib';
        import { UniAuthServiceStack } from '../lib/uni-auth-service-stack.js';

        const app = new App();
        new UniAuthServiceStack(app, 'UniAuthService');
        """,
        at: "infra/bin/infra.js",
        in: workspaceURL
    )
    try writeFile(
        """
        import { Stack } from 'aws-cdk-lib';

        export class UniAuthServiceStack extends Stack {}
        """,
        at: "infra/lib/uni-auth-service-stack.js",
        in: workspaceURL
    )
    try writeFile("should not be read", at: "infra/cdk.out/tree.json", in: workspaceURL)
    try writeFile("should not be read", at: "node_modules/aws-cdk-lib/index.js", in: workspaceURL)

    let worker = CodebaseSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "codebase"),
            prompt: "what about its infrastructure code?",
            mode: .ask,
            project: ProjectIdentity(
                id: "uni-auth",
                displayName: "Uni Auth",
                aliases: ["uni-auth"],
                localPath: workspaceURL.path
            ),
            userInput: "No I mean the deployment infra stuff. It should be in the infra folder in that repo"
        )
    )

    #expect(result.metadata["taskProfile"] == "infrastructure")
    #expect(result.evidenceMarkdown.contains("## Language And Manifest Inventory"))
    #expect(result.evidenceMarkdown.contains("infra/package.json"))
    #expect(result.evidenceMarkdown.contains("infra/cdk.json"))
    #expect(result.evidenceMarkdown.contains("infra/bin/infra.js"))
    #expect(result.evidenceMarkdown.contains("infra/lib/uni-auth-service-stack.js"))
    #expect(result.evidenceMarkdown.contains("AWS CDK app"))
    #expect(result.evidenceMarkdown.contains("JavaScript"))
    #expect(result.evidenceMarkdown.contains("aws-cdk-lib"))
    #expect(!result.evidenceMarkdown.contains("node_modules/aws-cdk-lib/index.js"))
    #expect(!result.evidenceMarkdown.contains("infra/cdk.out/tree.json"))
}

@Test
func codebaseSkillClassifiesNuxtVueRepoAndReadsRepresentativeSources() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-codebase-skill-nuxt-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        {
          "name": "admin-portal",
          "scripts": {"dev": "nuxt dev"},
          "dependencies": {
            "nuxt": "^3.0.0",
            "vue": "^3.0.0"
          },
          "devDependencies": {
            "typescript": "^5.0.0"
          }
        }
        """,
        at: "package.json",
        in: workspaceURL
    )
    try writeFile(
        """
        export default defineNuxtConfig({
          modules: []
        })
        """,
        at: "nuxt.config.ts",
        in: workspaceURL
    )
    try writeFile(
        """
        <template>
          <NuxtPage />
        </template>
        """,
        at: "app.vue",
        in: workspaceURL
    )
    try writeFile(
        """
        <script setup lang="ts">
        const title = 'Dashboard'
        </script>

        <template>
          <h1>{{ title }}</h1>
        </template>
        """,
        at: "pages/index.vue",
        in: workspaceURL
    )
    try writeFile("export const apiBase = '/api'\n", at: "app/config/api.ts", in: workspaceURL)
    try writeFile("{\"ignored\": true}\n", at: "node_modules/vue/package.json", in: workspaceURL)

    let worker = CodebaseSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "codebase"),
            prompt: "what language is the project in?",
            mode: .ask,
            project: ProjectIdentity(
                id: "admin-portal",
                displayName: "Admin Portal",
                aliases: ["admin-portal"],
                localPath: workspaceURL.path
            ),
            userInput: "What language is this repo written in?"
        )
    )

    #expect(result.metadata["taskProfile"] == "languageInventory")
    #expect(result.evidenceMarkdown.contains("### Languages"))
    #expect(result.evidenceMarkdown.contains("Vue: 2 files"))
    #expect(result.evidenceMarkdown.contains("TypeScript: 2 files"))
    #expect(result.evidenceMarkdown.contains("### Framework Signals"))
    #expect(result.evidenceMarkdown.contains("Nuxt via `package.json`"))
    #expect(result.evidenceMarkdown.contains("Vue via `package.json`"))
    #expect(result.evidenceMarkdown.contains("### Support And Config Files"))
    #expect(result.evidenceMarkdown.contains("JSON: 1 files"))
    #expect(result.evidenceMarkdown.contains("### `app.vue`"))
    #expect(result.evidenceMarkdown.contains("### `pages/index.vue`"))
    #expect(result.evidenceMarkdown.contains("### `app/config/api.ts`"))
    #expect(!result.evidenceMarkdown.contains("node_modules/vue/package.json"))
}

private func writeFile(_ contents: String, at relativePath: String, in root: URL) throws {
    let fileURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
