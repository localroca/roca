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

    try writeFile("module github.com/example/sample-auth\n\ngo 1.24\n", at: "go.mod", in: workspaceURL)
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
          "name": "sample-auth-infra",
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
        import { SampleAuthServiceStack } from '../lib/sample-auth-service-stack.js';

        const app = new App();
        new SampleAuthServiceStack(app, 'SampleAuthService');
        """,
        at: "infra/bin/infra.js",
        in: workspaceURL
    )
    try writeFile(
        """
        import { Stack } from 'aws-cdk-lib';

        export class SampleAuthServiceStack extends Stack {}
        """,
        at: "infra/lib/sample-auth-service-stack.js",
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
                id: "sample-auth",
                displayName: "Sample Auth",
                aliases: ["sample-auth"],
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
    #expect(result.evidenceMarkdown.contains("infra/lib/sample-auth-service-stack.js"))
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

@Test
func spreadsheetSkillTreatsSummarizeAsSummaryNotSum() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-summary-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Region,Status,Amount
        North,Paid,100
        South,Draft,50
        """,
        at: "sales.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "Summarize the spreadsheet.",
            mode: .ask,
            project: ProjectIdentity(
                id: "sales",
                displayName: "sales.csv",
                aliases: ["sales"],
                localPath: workspaceURL.appendingPathComponent("sales.csv").path
            ),
            userInput: "Can you summarize the spreadsheet?"
        )
    )

    #expect(result.metadata["operation"] == "summary")
    #expect(result.evidenceMarkdown.contains("sales has 2 data rows and 3 columns."))
    #expect(!result.evidenceMarkdown.contains("No numeric target column"))
}

@Test
func spreadsheetSkillAveragesFilteredCsvColumn() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Region,Status,Amount
        North,Paid,100
        South,Draft,50
        North,Paid,300
        """,
        at: "sales.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "What is the average amount where status is paid?",
            mode: .ask,
            project: ProjectIdentity(
                id: "sales",
                displayName: "sales.csv",
                aliases: ["sales"],
                localPath: workspaceURL.appendingPathComponent("sales.csv").path
            ),
            userInput: "Can you average the Amount column where Status is Paid in this spreadsheet?"
        )
    )

    #expect(result.metadata["operation"] == "aggregate")
    #expect(result.metadata["selectedSheet"] == "sales")
    #expect(result.evidenceMarkdown.contains("The average of Amount is 200"))
    #expect(result.evidenceMarkdown.contains("Filters: Status = Paid"))
    #expect(result.evidenceMarkdown.contains("Matching rows: 2"))
    #expect(result.evidenceMarkdown.contains("Numeric rows used: 2"))
    #expect(result.evidenceMarkdown.contains("## Column Profiles"))
    #expect(result.evidenceMarkdown.contains("| Amount |"))
}

@Test
func spreadsheetSkillMarksAggregateWithoutTargetColumnPartial() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-missing-target-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Region,Status,Amount,Quantity
        North,Paid,100,2
        South,Paid,50,3
        North,Draft,300,4
        """,
        at: "sales.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "What is the total for paid rows?",
            mode: .ask,
            project: ProjectIdentity(
                id: "sales",
                displayName: "sales.csv",
                aliases: ["sales"],
                localPath: workspaceURL.appendingPathComponent("sales.csv").path
            ),
            userInput: "What is the total for paid rows?"
        )
    )

    #expect(result.metadata["operation"] == "aggregate")
    #expect(result.evidenceSummary.grade == .partial)
    #expect(result.evidenceMarkdown.contains("no numeric target column was clearly identified"))
    #expect(result.evidenceMarkdown.contains("Filters: Status = Paid"))
}

@Test
func spreadsheetSkillGroupsCsvAggregation() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-group-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Region,Status,Amount
        North,Paid,100
        South,Paid,50
        North,Paid,300
        South,Draft,25
        """,
        at: "sales.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "Sum Amount by Region where Status is Paid.",
            mode: .ask,
            project: ProjectIdentity(
                id: "sales",
                displayName: "Sales Folder",
                aliases: ["sales"],
                localPath: workspaceURL.path
            ),
            userInput: "What is the total amount by region for paid rows?"
        )
    )

    #expect(result.metadata["operation"] == "groupAggregate")
    #expect(result.evidenceMarkdown.contains("Grouped by: Region"))
    #expect(result.evidenceMarkdown.contains("- North: 400"))
    #expect(result.evidenceMarkdown.contains("- South: 50"))
    #expect(result.evidenceMarkdown.contains("Filters: Status = Paid"))
}

@Test
func spreadsheetSkillUsesByPhraseForGroupedAggregation() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-group-phrase-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Status,Region,Amount
        Paid,North,100
        Paid,South,50
        Paid,North,300
        Draft,South,25
        """,
        at: "sales.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "Sum Amount by Region where Status is Paid.",
            mode: .ask,
            project: ProjectIdentity(
                id: "sales",
                displayName: "Sales Folder",
                aliases: ["sales"],
                localPath: workspaceURL.path
            ),
            userInput: "What is the total amount by region for paid rows?"
        )
    )

    #expect(result.metadata["operation"] == "groupAggregate")
    #expect(result.evidenceMarkdown.contains("Grouped by: Region"))
    #expect(result.evidenceMarkdown.contains("Filters: Status = Paid"))
}

@Test
func spreadsheetSkillPrefersExactFilenameInSimilarSpreadsheetFolder() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-filename-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile("Name,Amount\nA,10\n", at: "sales.csv", in: workspaceURL)
    try writeFile("Name,Amount\nB,99\n", at: "sales-q2.csv", in: workspaceURL)

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "Summarize sales.csv.",
            mode: .ask,
            project: ProjectIdentity(
                id: "reports",
                displayName: "Reports",
                aliases: ["reports"],
                localPath: workspaceURL.path
            ),
            userInput: "Can you summarize sales.csv in this folder?"
        )
    )

    #expect(result.metadata["operation"] == "summary")
    #expect(result.metadata["selectedSheet"] == "sales")
    #expect(result.evidenceMarkdown.contains("/sales.csv`"))
    #expect(!result.evidenceMarkdown.contains("sales-q2.csv"))
}

@Test
func spreadsheetSkillRanksCsvRowsByFeeColumn() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-ranking-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Record ID,Type,Product,Service Fee,Service Fee (Local),Amount,Grand Total,Fee Currency
        small,order,basic-local,1,10,100,1000,LOCAL
        large,refund,basic-local,90,,900,0,USD
        medium,order,basic-usd,70,,700,700,USD
        local-large,adjustment,basic-local,50,500,500,0,LOCAL
        """,
        at: "orders.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "What are the top five orders by service fee size?",
            mode: .ask,
            project: ProjectIdentity(
                id: "orders",
                displayName: "orders.csv",
                aliases: ["orders"],
                localPath: workspaceURL.appendingPathComponent("orders.csv").path
            ),
            userInput: "Can you tell me the top five orders by service fee size?"
        )
    )

    #expect(result.metadata["operation"] == "topRows")
    #expect(result.evidenceMarkdown.contains("Sorted by: Service Fee"))
    #expect(result.evidenceMarkdown.contains("### Computed Ranking"))
    #expect(result.evidenceMarkdown.contains("| Rank | Row | Service Fee | Service Fee (Local) | Record ID | Type | Product | Amount | Grand Total | Fee Currency |"))
    #expect(result.evidenceMarkdown.contains("| 1 | 3 | 90 |  | large | refund | basic-local | 900 | 0 | USD |"))
    #expect(result.evidenceMarkdown.contains("| 2 | 4 | 70 |  | medium | order | basic-usd | 700 | 700 | USD |"))
    #expect(!result.evidenceMarkdown.contains("| 1 | 2 | 1"))
}

@Test
func spreadsheetSkillRanksCsvRowsByExplicitLocalFeeColumn() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-local-ranking-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Record ID,Type,Product,Service Fee,Service Fee (Local)
        small,order,basic-local,1,10
        large,refund,basic-local,90,
        local-large,adjustment,basic-local,50,500
        """,
        at: "orders.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "What are the top two orders by Service Fee (Local)?",
            mode: .ask,
            project: ProjectIdentity(
                id: "orders",
                displayName: "orders.csv",
                aliases: ["orders"],
                localPath: workspaceURL.appendingPathComponent("orders.csv").path
            ),
            userInput: "Show the top two orders by Service Fee in local units."
        )
    )

    #expect(result.metadata["operation"] == "topRows")
    #expect(result.evidenceMarkdown.contains("Sorted by: Service Fee (Local)"))
    #expect(result.evidenceMarkdown.contains("| 1 | 4 | 500 | 50 | local-large | adjustment | basic-local |"))
    #expect(result.evidenceMarkdown.contains("| 2 | 2 | 10 | 1 | small | order | basic-local |"))
}

@Test
func spreadsheetSkillDoesNotFilterOutBlankLocalFeeRowsWhenUserNegatesLocalColumn() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-negated-local-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile(
        """
        Record ID,Type,Product,Currency,Service Fee,Service Fee (Local),Fee Currency,Amount
        local-only,adjustment,basic-local,LOCAL,50,500,USD,500
        usd-top,refund,basic-local,USD,90,,USD,900
        usd-second,order,basic-usd,USD,70,,USD,700
        small,order,basic-local,LOCAL,1,10,USD,100
        """,
        at: "orders.csv",
        in: workspaceURL
    )

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: #"Can you give me the top five "Service Fee" values, not "Service Fee (Local)" values"#,
            mode: .ask,
            project: ProjectIdentity(
                id: "orders",
                displayName: "orders.csv",
                aliases: ["orders"],
                localPath: workspaceURL.appendingPathComponent("orders.csv").path
            ),
            userInput: #"Can you give me the top five "Service Fee" values, not "Service Fee (Local)" values"#
        )
    )

    #expect(result.metadata["operation"] == "topRows")
    #expect(result.evidenceMarkdown.contains("Sorted by: Service Fee"))
    #expect(result.evidenceMarkdown.contains("Filters: none"))
    #expect(result.evidenceMarkdown.contains("| 1 | 3 | 90 |  | usd-top | refund | basic-local | 900 |"))
    #expect(result.evidenceMarkdown.contains("| 2 | 4 | 70 |  | usd-second | order | basic-usd | 700 |"))
    #expect(!result.evidenceMarkdown.contains("Sorted by: Service Fee (Local)"))
}

@Test
func spreadsheetSkillAsksForClarificationWhenFolderHasMultipleSpreadsheets() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roca-spreadsheet-skill-ambiguous-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    try writeFile("Name,Amount\nA,1\n", at: "sales.csv", in: workspaceURL)
    try writeFile("Name,Amount\nB,2\n", at: "expenses.csv", in: workspaceURL)

    let worker = SpreadsheetSkillWorker()
    let result = try await worker.run(
        LocalSkillRunRequest(
            skillID: SkillID(rawValue: "spreadsheet"),
            prompt: "Summarize the spreadsheet.",
            mode: .ask,
            project: ProjectIdentity(
                id: "folder",
                displayName: "Reports",
                aliases: ["reports"],
                localPath: workspaceURL.path
            ),
            userInput: "Can you summarize the spreadsheet in this folder?"
        )
    )

    #expect(result.metadata["needsClarification"] == "true")
    #expect(result.evidenceSummary.grade == .insufficient)
    #expect(result.evidenceMarkdown.contains("## Clarification Needed"))
    #expect(result.evidenceMarkdown.contains("sales.csv"))
    #expect(result.evidenceMarkdown.contains("expenses.csv"))
}

private func writeFile(_ contents: String, at relativePath: String, in root: URL) throws {
    let fileURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
