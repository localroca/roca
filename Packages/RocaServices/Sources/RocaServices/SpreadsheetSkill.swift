import Foundation
import RocaCore

public struct SpreadsheetSkillWorker: LocalSkillWorking {
    public let skillID = SkillID(rawValue: "spreadsheet")
    public let displayName = "Spreadsheet Skill"

    private let maxRowsPerSheet: Int
    private let maxPreviewRows: Int

    public init(maxRowsPerSheet: Int = 10_000, maxPreviewRows: Int = 8) {
        self.maxRowsPerSheet = maxRowsPerSheet
        self.maxPreviewRows = maxPreviewRows
    }

    public func run(_ request: LocalSkillRunRequest) async throws -> LocalSkillRunResult {
        let rootURL = URL(fileURLWithPath: request.project.localPath).standardizedFileURL
        let queryText = [request.prompt, request.userInput, request.project.displayName].joined(separator: " ")
        let selection = try SpreadsheetFileSelector.selectSpreadsheetFiles(under: rootURL, queryText: queryText)

        switch selection {
        case .missing:
            let evidence = SpreadsheetEvidenceBuilder.missingEvidence(rootURL: rootURL, request: request)
            return makeResult(request, evidence: evidence, grade: .insufficient, filesScanned: 0)
        case .ambiguous(let candidates):
            let evidence = SpreadsheetEvidenceBuilder.ambiguousEvidence(rootURL: rootURL, candidates: candidates, request: request)
            return makeResult(
                request,
                evidence: evidence,
                grade: .insufficient,
                filesScanned: candidates.count,
                metadata: ["needsClarification": "true"]
            )
        case .selected(let fileURL, let candidateCount):
            let document = try SpreadsheetDocumentLoader(maxRowsPerSheet: maxRowsPerSheet).load(fileURL)
            let analysis = SpreadsheetAnalyzer(maxPreviewRows: maxPreviewRows).analyze(document: document, request: request)
            let evidence = SpreadsheetEvidenceBuilder.analysisEvidence(document: document, analysis: analysis, request: request)
            return makeResult(
                request,
                evidence: evidence,
                grade: analysis.grade,
                filesScanned: candidateCount,
                metadata: analysis.metadata
            )
        }
    }

    private func makeResult(
        _ request: LocalSkillRunRequest,
        evidence: SpreadsheetEvidence,
        grade: AssistantEvidenceGrade,
        filesScanned: Int,
        metadata: [String: String] = [:]
    ) -> LocalSkillRunResult {
        let evidenceSummary = AssistantEvidenceSummary(
            sourceKind: .localSkill,
            sourceID: skillID.rawValue,
            sourceName: displayName,
            grade: grade,
            projectID: request.project.id.rawValue,
            projectName: request.project.displayName,
            workspacePath: request.project.localPath,
            scannedFileCount: filesScanned,
            manifestCount: evidence.sheetCount,
            inspectedPaths: evidence.inspectedPaths,
            searchTerms: SpreadsheetText.significantTokens(in: [request.prompt, request.userInput].joined(separator: " ")),
            omittedPathCount: 0,
            originalCharacterCount: evidence.markdown.count,
            budgetedCharacterCount: evidence.markdown.count,
            isTruncated: false,
            coverageNotes: [
                "Read local spreadsheet data only.",
                "Returned bounded previews and calculation provenance instead of dumping full workbook data."
            ],
            limitations: evidence.limitations
        )
        var resultMetadata = metadata
        resultMetadata["toolCount"] = "1"
        resultMetadata["filesScanned"] = String(filesScanned)
        resultMetadata["sheetCount"] = String(evidence.sheetCount)
        resultMetadata["evidenceGrade"] = grade.rawValue
        resultMetadata["evidenceCharacters"] = String(evidence.markdown.count)
        resultMetadata["skillID"] = skillID.rawValue
        return LocalSkillRunResult(
            runID: request.runID,
            skillID: request.skillID,
            evidenceMarkdown: evidence.markdown,
            evidenceSummary: evidenceSummary,
            metadata: resultMetadata
        )
    }
}

private enum SpreadsheetFileSelection {
    case selected(URL, candidateCount: Int)
    case ambiguous([URL])
    case missing
}

private enum SpreadsheetFileSelector {
    static func selectSpreadsheetFiles(under rootURL: URL, queryText: String) throws -> SpreadsheetFileSelection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if !isDirectory.boolValue {
            return isSupported(rootURL) ? .selected(rootURL, candidateCount: 1) : .missing
        }

        let candidates = try spreadsheetFiles(in: rootURL)
        guard !candidates.isEmpty else {
            return .missing
        }
        guard candidates.count > 1 else {
            return .selected(candidates[0], candidateCount: 1)
        }

        let scored = candidates
            .map { ($0, score(fileURL: $0, queryText: queryText)) }
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.path.localizedCaseInsensitiveCompare($1.0.path) == .orderedAscending
            }
        if let best = scored.first, best.1 > 0 {
            let runnerUp = scored.dropFirst().first?.1 ?? 0
            if best.1 >= runnerUp + 2 {
                return .selected(best.0, candidateCount: candidates.count)
            }
        }
        return .ambiguous(Array(scored.prefix(12).map(\.0)))
    }

    private static func spreadsheetFiles(in rootURL: URL) throws -> [URL] {
        let skippedNames = Set([".git", ".build", "node_modules", "DerivedData", "Pods"])
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true {
                if skippedNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isSupported(fileURL) {
                files.append(fileURL)
            }
            if files.count >= 50 {
                break
            }
        }
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func isSupported(_ fileURL: URL) -> Bool {
        switch fileURL.pathExtension.lowercased() {
        case "csv", "tsv", "xlsx":
            true
        default:
            false
        }
    }

    private static func score(fileURL: URL, queryText: String) -> Int {
        let fileTokens = Set(SpreadsheetText.significantTokens(in: fileURL.deletingPathExtension().lastPathComponent))
        let queryTokens = Set(SpreadsheetText.significantTokens(in: queryText))
        let overlap = fileTokens.intersection(queryTokens).count
        let normalizedFileName = SpreadsheetText.normalized(fileURL.lastPathComponent)
        let normalizedBaseName = SpreadsheetText.normalized(fileURL.deletingPathExtension().lastPathComponent)
        let normalizedPath = SpreadsheetText.normalized(fileURL.path)
        let normalizedQuery = SpreadsheetText.normalized(queryText)
        var score = overlap * 3 + (normalizedQuery.contains(normalizedPath) ? 4 : 0)
        if SpreadsheetText.containsTokenPhrase(normalizedQuery, normalizedFileName) {
            score += 100
        } else if SpreadsheetText.containsTokenPhrase(normalizedQuery, normalizedBaseName) {
            score += 30
        }
        return score
    }
}

private struct SpreadsheetDocument {
    var fileURL: URL
    var format: String
    var sheets: [SpreadsheetSheet]
}

private struct SpreadsheetSheet {
    var name: String
    var rows: [[SpreadsheetCell]]
    var truncated: Bool
}

private struct SpreadsheetCell {
    var text: String
    var formula: String?

    static let empty = SpreadsheetCell(text: "", formula: nil)

    var number: Double? {
        SpreadsheetNumberParser.number(from: text)
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && formula?.isEmpty != false
    }
}

private struct SpreadsheetDocumentLoader {
    var maxRowsPerSheet: Int

    func load(_ fileURL: URL) throws -> SpreadsheetDocument {
        switch fileURL.pathExtension.lowercased() {
        case "csv":
            return try loadDelimited(fileURL, delimiter: ",", format: "CSV")
        case "tsv":
            return try loadDelimited(fileURL, delimiter: "\t", format: "TSV")
        case "xlsx":
            return try SpreadsheetXLSXReader(maxRowsPerSheet: maxRowsPerSheet).load(fileURL)
        default:
            throw RocaError.selectionUnavailable("Unsupported spreadsheet format: \(fileURL.lastPathComponent)")
        }
    }

    private func loadDelimited(_ fileURL: URL, delimiter: Character, format: String) throws -> SpreadsheetDocument {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let rows = SpreadsheetCSVParser.parse(text, delimiter: delimiter, maxRows: maxRowsPerSheet)
        return SpreadsheetDocument(
            fileURL: fileURL,
            format: format,
            sheets: [
                SpreadsheetSheet(
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    rows: rows,
                    truncated: rows.count >= maxRowsPerSheet
                )
            ]
        )
    }
}

private enum SpreadsheetCSVParser {
    static func parse(_ text: String, delimiter: Character, maxRows: Int) -> [[SpreadsheetCell]] {
        var rows: [[SpreadsheetCell]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, characters.indices.contains(index + 1), characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter && !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n" && !inQuotes {
                append(row: &row, field: &field, to: &rows, maxRows: maxRows)
                if rows.count >= maxRows { break }
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }

        if rows.count < maxRows, !field.isEmpty || !row.isEmpty {
            append(row: &row, field: &field, to: &rows, maxRows: maxRows)
        }
        return rows
    }

    private static func append(row: inout [String], field: inout String, to rows: inout [[SpreadsheetCell]], maxRows: Int) {
        guard rows.count < maxRows else { return }
        row.append(field)
        rows.append(row.map { SpreadsheetCell(text: $0.trimmingCharacters(in: .whitespacesAndNewlines), formula: nil) })
        row = []
        field = ""
    }
}

private struct SpreadsheetXLSXReader {
    var maxRowsPerSheet: Int

    func load(_ fileURL: URL) throws -> SpreadsheetDocument {
        guard let workbookXML = try UnzipReader.readText(entry: "xl/workbook.xml", from: fileURL),
              let relationshipsXML = try UnzipReader.readText(entry: "xl/_rels/workbook.xml.rels", from: fileURL)
        else {
            throw RocaError.selectionUnavailable("Could not read workbook metadata from \(fileURL.lastPathComponent).")
        }
        let sheets = WorkbookSheetParser.parse(workbookXML)
        let relationships = WorkbookRelationshipParser.parse(relationshipsXML)
        let sharedStrings = try UnzipReader.readText(entry: "xl/sharedStrings.xml", from: fileURL)
            .map(SharedStringsParser.parse) ?? []

        let parsedSheets = try sheets.compactMap { sheet -> SpreadsheetSheet? in
            guard let target = relationships[sheet.relationshipID] else {
                return nil
            }
            let entry = normalizedWorkbookTarget(target)
            guard let worksheetXML = try UnzipReader.readText(entry: entry, from: fileURL) else {
                return nil
            }
            let rows = WorksheetParser.parse(worksheetXML, sharedStrings: sharedStrings, maxRows: maxRowsPerSheet)
            return SpreadsheetSheet(name: sheet.name, rows: rows, truncated: rows.count >= maxRowsPerSheet)
        }
        guard !parsedSheets.isEmpty else {
            throw RocaError.selectionUnavailable("Could not read any worksheets from \(fileURL.lastPathComponent).")
        }
        return SpreadsheetDocument(fileURL: fileURL, format: "XLSX", sheets: parsedSheets)
    }

    private func normalizedWorkbookTarget(_ target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        if target.hasPrefix("xl/") {
            return target
        }
        return "xl/\(target)"
    }
}

private enum UnzipReader {
    static func readText(entry: String, from fileURL: URL) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", fileURL.path, entry]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

private struct WorkbookSheet {
    var name: String
    var relationshipID: String
}

private final class WorkbookSheetParser: NSObject, XMLParserDelegate {
    private var sheets: [WorkbookSheet] = []

    static func parse(_ xml: String) -> [WorkbookSheet] {
        let delegate = WorkbookSheetParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.sheets
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"]
        else {
            return
        }
        sheets.append(WorkbookSheet(name: name, relationshipID: relationshipID))
    }
}

private final class WorkbookRelationshipParser: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    static func parse(_ xml: String) -> [String: String] {
        let delegate = WorkbookRelationshipParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.relationships
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"]
        else {
            return
        }
        relationships[id] = target
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inStringItem = false
    private var inText = false

    static func parse(_ xml: String) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            current = ""
            inStringItem = true
        } else if elementName == "t", inStringItem {
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            current += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            inText = false
        } else if elementName == "si" {
            strings.append(current)
            current = ""
            inStringItem = false
        }
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let maxRows: Int
    private var rows: [[SpreadsheetCell]] = []
    private var currentCells: [Int: SpreadsheetCell] = [:]
    private var currentCellRef = ""
    private var currentCellType: String?
    private var currentValue = ""
    private var currentFormula = ""
    private var currentInlineText = ""
    private var textTarget: TextTarget?
    private var inRow = false

    private enum TextTarget {
        case value
        case formula
        case inlineText
    }

    init(sharedStrings: [String], maxRows: Int) {
        self.sharedStrings = sharedStrings
        self.maxRows = maxRows
    }

    static func parse(_ xml: String, sharedStrings: [String], maxRows: Int) -> [[SpreadsheetCell]] {
        let delegate = WorksheetParser(sharedStrings: sharedStrings, maxRows: maxRows)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            inRow = true
            currentCells = [:]
        case "c":
            currentCellRef = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"]
            currentValue = ""
            currentFormula = ""
            currentInlineText = ""
        case "v":
            textTarget = .value
        case "f":
            textTarget = .formula
        case "t":
            if currentCellType == "inlineStr" {
                textTarget = .inlineText
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch textTarget {
        case .value:
            currentValue += string
        case .formula:
            currentFormula += string
        case .inlineText:
            currentInlineText += string
        case nil:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "f", "t":
            textTarget = nil
        case "c":
            let columnIndex = SpreadsheetCellAddress.columnIndex(from: currentCellRef) ?? currentCells.count
            let text = resolvedCellText()
            currentCells[columnIndex] = SpreadsheetCell(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                formula: currentFormula.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        case "row":
            if rows.count < maxRows {
                let maxColumn = currentCells.keys.max() ?? -1
                if maxColumn >= 0 {
                    rows.append((0...maxColumn).map { currentCells[$0] ?? .empty })
                }
            }
            inRow = false
            currentCells = [:]
        default:
            break
        }
    }

    private func resolvedCellText() -> String {
        if currentCellType == "s",
           let index = Int(currentValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        if currentCellType == "inlineStr" {
            return currentInlineText
        }
        return currentValue
    }
}

private struct SpreadsheetAnalysis {
    var selectedSheet: SpreadsheetSheet?
    var table: SpreadsheetTable?
    var operation: SpreadsheetOperationResult?
    var previews: [SpreadsheetPreview]
    var profiles: [SpreadsheetColumnProfile]
    var formulaCells: [SpreadsheetFormulaCell]
    var grade: AssistantEvidenceGrade
    var limitations: [String]
    var metadata: [String: String]
}

private struct SpreadsheetAnalyzer {
    var maxPreviewRows: Int

    func analyze(document: SpreadsheetDocument, request: LocalSkillRunRequest) -> SpreadsheetAnalysis {
        let queryText = [request.prompt, request.userInput].joined(separator: " ")
        let tables = document.sheets.compactMap { SpreadsheetTable.infer(from: $0) }
        guard let table = selectTable(from: tables, queryText: queryText) else {
            return SpreadsheetAnalysis(
                selectedSheet: document.sheets.first,
                table: nil,
                operation: nil,
                previews: document.sheets.map { SpreadsheetPreview(sheet: $0, maxRows: maxPreviewRows) },
                profiles: [],
                formulaCells: document.sheets.flatMap { SpreadsheetFormulaCell.collect(from: $0) },
                grade: .partial,
                limitations: ["No clear header row was detected; Roca could only preview workbook contents."],
                metadata: ["operation": "preview"]
            )
        }

        let plan = SpreadsheetQueryPlanner.plan(queryText: queryText, table: table)
        let operation = SpreadsheetOperationExecutor.execute(plan: plan, table: table)
        let profiles = table.columnProfiles()
        let formulaCells = document.sheets.flatMap { SpreadsheetFormulaCell.collect(from: $0) }
        var limitations: [String] = []
        if table.sheet.truncated {
            limitations.append("The selected sheet was truncated at \(table.sheet.rows.count) rows.")
        }
        if operation?.limitations.isEmpty == false {
            limitations.append(contentsOf: operation?.limitations ?? [])
        }
        return SpreadsheetAnalysis(
            selectedSheet: table.sheet,
            table: table,
            operation: operation,
            previews: [SpreadsheetPreview(table: table, maxRows: maxPreviewRows)],
            profiles: profiles,
            formulaCells: formulaCells,
            grade: operation?.grade ?? .verified,
            limitations: limitations,
            metadata: [
                "operation": operation?.kind.rawValue ?? "summary",
                "selectedSheet": table.sheet.name,
                "rowCount": String(table.dataRows.count),
                "columnCount": String(table.columns.count)
            ]
        )
    }

    private func selectTable(from tables: [SpreadsheetTable], queryText: String) -> SpreadsheetTable? {
        guard !tables.isEmpty else { return nil }
        let queryTokens = Set(SpreadsheetText.significantTokens(in: queryText))
        return tables.max { lhs, rhs in
            score(table: lhs, queryTokens: queryTokens) < score(table: rhs, queryTokens: queryTokens)
        }
    }

    private func score(table: SpreadsheetTable, queryTokens: Set<String>) -> Int {
        let sheetTokens = Set(SpreadsheetText.significantTokens(in: table.sheet.name))
        let headerTokens = Set(table.columns.flatMap { SpreadsheetText.significantTokens(in: $0.name) })
        return sheetTokens.intersection(queryTokens).count * 4
            + headerTokens.intersection(queryTokens).count * 2
            + min(table.dataRows.count, 100) / 20
    }
}

private struct SpreadsheetTable {
    var sheet: SpreadsheetSheet
    var headerRowIndex: Int
    var columns: [SpreadsheetColumn]
    var dataRows: [SpreadsheetDataRow]

    static func infer(from sheet: SpreadsheetSheet) -> SpreadsheetTable? {
        guard let headerIndex = headerRowIndex(in: sheet.rows) else {
            return nil
        }
        let headerRow = sheet.rows[headerIndex]
        let columns = headerRow.enumerated().map { index, cell in
            SpreadsheetColumn(index: index, name: normalizedHeader(cell.text, index: index))
        }
        let dataRows = sheet.rows.dropFirst(headerIndex + 1).enumerated().compactMap { offset, cells -> SpreadsheetDataRow? in
            guard cells.contains(where: { !$0.isEmpty }) else {
                return nil
            }
            return SpreadsheetDataRow(rowNumber: headerIndex + offset + 2, cells: cells)
        }
        return SpreadsheetTable(sheet: sheet, headerRowIndex: headerIndex, columns: columns, dataRows: dataRows)
    }

    func cell(row: SpreadsheetDataRow, column: SpreadsheetColumn) -> SpreadsheetCell {
        guard row.cells.indices.contains(column.index) else {
            return .empty
        }
        return row.cells[column.index]
    }

    func columnProfiles() -> [SpreadsheetColumnProfile] {
        columns.map { column in
            let cells = dataRows.map { cell(row: $0, column: column) }
            return SpreadsheetColumnProfile(column: column, cells: cells)
        }
    }

    private static func headerRowIndex(in rows: [[SpreadsheetCell]]) -> Int? {
        let searchRows = rows.prefix(25)
        for (index, row) in searchRows.enumerated() {
            let nonEmpty = row.filter { !$0.isEmpty }
            guard nonEmpty.count >= 2 else { continue }
            let stringLike = nonEmpty.filter { $0.number == nil }.count
            let nextNonEmpty = rows.dropFirst(index + 1).first?.filter { !$0.isEmpty }.count ?? 0
            if stringLike >= max(1, nonEmpty.count / 2), nextNonEmpty >= 2 {
                return index
            }
        }
        return rows.firstIndex { $0.filter { !$0.isEmpty }.count >= 2 }
    }

    private static func normalizedHeader(_ text: String, index: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "Column \(SpreadsheetCellAddress.columnName(for: index))"
    }
}

private struct SpreadsheetColumn: Hashable {
    var index: Int
    var name: String

    var addressName: String {
        SpreadsheetCellAddress.columnName(for: index)
    }
}

private struct SpreadsheetDataRow {
    var rowNumber: Int
    var cells: [SpreadsheetCell]
}

private struct SpreadsheetColumnProfile {
    var column: SpreadsheetColumn
    var nonEmptyCount: Int
    var numericCount: Int
    var sum: Double?
    var average: Double?
    var min: Double?
    var max: Double?
    var examples: [String]

    init(column: SpreadsheetColumn, cells: [SpreadsheetCell]) {
        self.column = column
        let nonEmpty = cells.filter { !$0.isEmpty }
        let numbers = nonEmpty.compactMap(\.number)
        self.nonEmptyCount = nonEmpty.count
        self.numericCount = numbers.count
        self.sum = numbers.isEmpty ? nil : numbers.reduce(0, +)
        self.average = numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        self.min = numbers.min()
        self.max = numbers.max()
        var seen = Set<String>()
        self.examples = nonEmpty.compactMap { cell in
            let value = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(SpreadsheetText.normalized(value)).inserted else {
                return nil
            }
            return value
        }.prefix(3).map { $0 }
    }
}

private enum SpreadsheetAggregateKind: String {
    case sum
    case average
    case count
    case min
    case max

    var displayName: String {
        switch self {
        case .sum: "sum"
        case .average: "average"
        case .count: "count"
        case .min: "minimum"
        case .max: "maximum"
        }
    }
}

private enum SpreadsheetPlan {
    case summary
    case formulas
    case aggregate(kind: SpreadsheetAggregateKind, valueColumn: SpreadsheetColumn?, filters: [SpreadsheetFilter])
    case groupAggregate(kind: SpreadsheetAggregateKind, valueColumn: SpreadsheetColumn, groupColumn: SpreadsheetColumn, filters: [SpreadsheetFilter])
    case topRows(sortColumn: SpreadsheetColumn, limit: Int, descending: Bool, filters: [SpreadsheetFilter])
    case profile(column: SpreadsheetColumn?)
}

private struct SpreadsheetFilter {
    var column: SpreadsheetColumn
    var value: String

    var displayText: String {
        "\(column.name) = \(value)"
    }
}

private enum SpreadsheetQueryPlanner {
    static func plan(queryText: String, table: SpreadsheetTable) -> SpreadsheetPlan {
        let normalized = SpreadsheetText.normalized(queryText)
        if normalized.contains("formula") || normalized.contains("formulas") {
            return .formulas
        }

        if normalized.contains("top ") || normalized.contains("highest") || normalized.contains("largest")
            || normalized.contains("bottom ") || normalized.contains("lowest") || normalized.contains("smallest") {
            let descending = !(normalized.contains("bottom") || normalized.contains("lowest") || normalized.contains("smallest"))
            if let sortColumn = bestColumn(in: table, matching: normalized, numericOnly: true) {
                return .topRows(
                    sortColumn: sortColumn,
                    limit: explicitLimit(in: normalized) ?? 5,
                    descending: descending,
                    filters: inferredFilters(in: table, normalizedQuery: normalized, excluding: [sortColumn])
                )
            }
        }

        if let aggregateKind = aggregateKind(in: normalized) {
            let valueColumn = bestColumn(in: table, matching: normalized, numericOnly: aggregateKind != .count)
            let filters = inferredFilters(in: table, normalizedQuery: normalized, excluding: [valueColumn].compactMap { $0 })
            if aggregateKind != .count,
               let valueColumn,
               let groupColumn = groupColumn(in: table, normalizedQuery: normalized, excluding: valueColumn) {
                return .groupAggregate(kind: aggregateKind, valueColumn: valueColumn, groupColumn: groupColumn, filters: filters)
            }
            return .aggregate(kind: aggregateKind, valueColumn: valueColumn, filters: filters)
        }

        if normalized.contains("profile") || normalized.contains("summarize column") || normalized.contains("describe column") {
            return .profile(column: bestColumn(in: table, matching: normalized, numericOnly: false))
        }

        return .summary
    }

    private static func aggregateKind(in normalized: String) -> SpreadsheetAggregateKind? {
        let tokens = Set(normalized.split(separator: " ").map(String.init))
        func containsAnyToken(_ candidates: [String]) -> Bool {
            candidates.contains { tokens.contains($0) }
        }

        if containsAnyToken(["average", "mean", "avg"]) {
            return .average
        }
        if containsAnyToken(["sum", "total", "totals"])
            || SpreadsheetText.containsTokenPhrase(normalized, "add up") {
            return .sum
        }
        if containsAnyToken(["minimum", "min", "smallest"]) {
            return .min
        }
        if containsAnyToken(["maximum", "max", "largest"]) {
            return .max
        }
        if containsAnyToken(["count"]) || SpreadsheetText.containsTokenPhrase(normalized, "how many") {
            return .count
        }
        return nil
    }

    private static func explicitLimit(in normalized: String) -> Int? {
        let parts = normalized.split(separator: " ")
        for (index, part) in parts.enumerated() where ["top", "bottom"].contains(String(part)) {
            if parts.indices.contains(index + 1), let limit = numericLimit(from: String(parts[index + 1])) {
                return max(1, min(limit, 25))
            }
        }
        return nil
    }

    private static func numericLimit(from value: String) -> Int? {
        if let limit = Int(value) {
            return limit
        }
        return [
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10
        ][value]
    }

    private static func bestColumn(
        in table: SpreadsheetTable,
        matching normalizedQuery: String,
        numericOnly: Bool,
        excluding excludedColumns: [SpreadsheetColumn] = []
    ) -> SpreadsheetColumn? {
        let excluded = Set(excludedColumns.map(\.index))
        let profiles = table.columnProfiles()
        let scored = table.columns.compactMap { column -> (SpreadsheetColumn, Int)? in
            guard !excluded.contains(column.index) else { return nil }
            if numericOnly,
               profiles.first(where: { $0.column.index == column.index })?.numericCount ?? 0 == 0 {
                return nil
            }
            let header = SpreadsheetText.normalized(column.name)
            if isNegatedHeader(header, in: normalizedQuery) {
                return nil
            }
            let tokens = SpreadsheetText.significantTokens(in: column.name)
            var score = 0
            if normalizedQuery.contains(header) {
                score += 12
            }
            score += tokens.filter { normalizedQuery.contains($0) }.count * 2
            if numericOnly, score > 0 {
                score += 1
            }
            return score > 0 ? (column, score) : nil
        }
        if let best = scored.sorted(by: { $0.1 > $1.1 }).first {
            return best.0
        }
        if numericOnly {
            let numericColumns = profiles.filter { $0.numericCount > 0 }
            if numericColumns.count == 1 {
                return numericColumns[0].column
            }
        }
        return nil
    }

    private static func isNegatedHeader(_ header: String, in normalizedQuery: String) -> Bool {
        guard !header.isEmpty else { return false }
        return ["not \(header)", "not the \(header)", "instead of \(header)"].contains { phrase in
            normalizedQuery == phrase
                || [" one", " ones", " column", " columns", " field", " fields", " value", " values"].contains { suffix in
                    normalizedQuery.contains("\(phrase)\(suffix)")
                }
        }
    }

    private static func groupColumn(
        in table: SpreadsheetTable,
        normalizedQuery: String,
        excluding valueColumn: SpreadsheetColumn
    ) -> SpreadsheetColumn? {
        guard normalizedQuery.contains(" by ") || normalizedQuery.contains(" per ") || normalizedQuery.contains(" grouped ") else {
            return nil
        }
        if let groupPhrase = groupPhrase(in: normalizedQuery),
           let groupColumn = bestColumn(in: table, matching: groupPhrase, numericOnly: false, excluding: [valueColumn]) {
            return groupColumn
        }
        return bestColumn(in: table, matching: normalizedQuery, numericOnly: false, excluding: [valueColumn])
    }

    private static func groupPhrase(in normalizedQuery: String) -> String? {
        for marker in [" grouped by ", " group by ", " by ", " per "] {
            guard let range = normalizedQuery.range(of: marker) else { continue }
            let phrase = boundedGroupPhrase(String(normalizedQuery[range.upperBound...]))
            if !phrase.isEmpty {
                return phrase
            }
        }
        return nil
    }

    private static func boundedGroupPhrase(_ value: String) -> String {
        var phrase = value
        for marker in [" where ", " with ", " for "] {
            if let range = phrase.range(of: marker) {
                phrase = String(phrase[..<range.lowerBound])
            }
        }
        return phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferredFilters(
        in table: SpreadsheetTable,
        normalizedQuery: String,
        excluding excludedColumns: [SpreadsheetColumn]
    ) -> [SpreadsheetFilter] {
        let excluded = Set(excludedColumns.map(\.index))
        var filters: [SpreadsheetFilter] = []
        for column in table.columns where !excluded.contains(column.index) {
            let values = distinctValues(for: column, in: table)
            guard !values.isEmpty else { continue }
            let columnKey = SpreadsheetText.normalized(column.name)
            let explicitPrefixes = ["\(columnKey) is ", "\(columnKey) equals ", "\(columnKey) equal ", "\(columnKey) "]
            for prefix in explicitPrefixes where normalizedQuery.contains(prefix) {
                if let value = values.first(where: { candidate in
                    let candidateKey = SpreadsheetText.normalized(candidate)
                    guard candidateKey.count >= 2 else { return false }
                    guard let range = normalizedQuery.range(of: prefix) else { return false }
                    let tail = normalizedQuery[range.upperBound...]
                    return tail.hasPrefix(candidateKey) || tail.contains(" \(candidateKey)")
                }) {
                    filters.append(SpreadsheetFilter(column: column, value: value))
                    break
                }
            }
            if filters.contains(where: { $0.column.index == column.index }) {
                continue
            }
            if shouldSkipImplicitValueFilter(for: column) {
                continue
            }
            guard values.count <= 40 else { continue }
            for value in values {
                let valueKey = SpreadsheetText.normalized(value)
                guard valueKey.count >= 3, !SpreadsheetText.commonTokens.contains(valueKey) else {
                    continue
                }
                if SpreadsheetText.containsTokenPhrase(normalizedQuery, valueKey) {
                    filters.append(SpreadsheetFilter(column: column, value: value))
                    break
                }
            }
        }
        return filters
    }

    private static func shouldSkipImplicitValueFilter(for column: SpreadsheetColumn) -> Bool {
        let header = SpreadsheetText.normalized(column.name)
        return header == "currency" || header.contains("currency")
    }

    private static func distinctValues(for column: SpreadsheetColumn, in table: SpreadsheetTable) -> [String] {
        var seen = Set<String>()
        return table.dataRows.compactMap { row in
            let value = table.cell(row: row, column: column).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SpreadsheetText.normalized(value)
            guard !value.isEmpty, seen.insert(key).inserted else {
                return nil
            }
            return value
        }
    }
}

private struct SpreadsheetOperationResult {
    enum Kind: String {
        case summary
        case formulas
        case aggregate
        case groupAggregate
        case topRows
        case profile
    }

    var kind: Kind
    var title: String
    var summary: String
    var details: [String]
    var rows: [SpreadsheetDataRow]
    var columns: [SpreadsheetColumn]
    var grade: AssistantEvidenceGrade
    var limitations: [String]
    var sortColumn: SpreadsheetColumn? = nil
}

private enum SpreadsheetOperationExecutor {
    static func execute(plan: SpreadsheetPlan, table: SpreadsheetTable) -> SpreadsheetOperationResult? {
        switch plan {
        case .summary:
            return SpreadsheetOperationResult(
                kind: .summary,
                title: "Workbook summary",
                summary: "\(table.sheet.name) has \(table.dataRows.count) data rows and \(table.columns.count) columns.",
                details: [],
                rows: Array(table.dataRows.prefix(8)),
                columns: table.columns,
                grade: .verified,
                limitations: []
            )
        case .formulas:
            let formulas = SpreadsheetFormulaCell.collect(from: table.sheet)
            return SpreadsheetOperationResult(
                kind: .formulas,
                title: "Formula inventory",
                summary: formulas.isEmpty ? "No formulas were found in \(table.sheet.name)." : "Found \(formulas.count) formula cell(s) in \(table.sheet.name).",
                details: formulas.prefix(25).map { "- \($0.address): `\($0.formula)`" },
                rows: [],
                columns: [],
                grade: .verified,
                limitations: formulas.count > 25 ? ["Only the first 25 formula cells are listed."] : []
            )
        case .aggregate(let kind, let valueColumn, let filters):
            return aggregate(kind: kind, valueColumn: valueColumn, filters: filters, table: table)
        case .groupAggregate(let kind, let valueColumn, let groupColumn, let filters):
            return groupAggregate(kind: kind, valueColumn: valueColumn, groupColumn: groupColumn, filters: filters, table: table)
        case .topRows(let sortColumn, let limit, let descending, let filters):
            return topRows(sortColumn: sortColumn, limit: limit, descending: descending, filters: filters, table: table)
        case .profile(let column):
            return profile(column: column, table: table)
        }
    }

    private static func aggregate(
        kind: SpreadsheetAggregateKind,
        valueColumn: SpreadsheetColumn?,
        filters: [SpreadsheetFilter],
        table: SpreadsheetTable
    ) -> SpreadsheetOperationResult {
        let rows = filteredRows(filters, in: table)
        if kind == .count {
            return SpreadsheetOperationResult(
                kind: .aggregate,
                title: "Count",
                summary: "Counted \(rows.count) matching row(s).",
                details: provenance(kind: kind, valueColumn: valueColumn, filters: filters, matchingRows: rows.count, numericRows: nil),
                rows: Array(rows.prefix(8)),
                columns: table.columns,
                grade: .verified,
                limitations: []
            )
        }
        guard let valueColumn else {
            return SpreadsheetOperationResult(
                kind: .aggregate,
                title: "\(kind.displayName.capitalized) needs a column",
                summary: "I found \(rows.count) matching row(s), but no numeric target column was clearly identified for the \(kind.displayName).",
                details: provenance(kind: kind, valueColumn: nil, filters: filters, matchingRows: rows.count, numericRows: nil),
                rows: Array(rows.prefix(8)),
                columns: table.columns,
                grade: .partial,
                limitations: ["No numeric target column was clearly identified, so Roca counted matching rows."]
            )
        }
        let numbers = rows.compactMap { table.cell(row: $0, column: valueColumn).number }
        guard let value = aggregateValue(kind: kind, numbers: numbers) else {
            return SpreadsheetOperationResult(
                kind: .aggregate,
                title: kind.displayName.capitalized,
                summary: "I found \(rows.count) matching row(s), but no numeric values in \(valueColumn.name).",
                details: provenance(kind: kind, valueColumn: valueColumn, filters: filters, matchingRows: rows.count, numericRows: numbers.count),
                rows: Array(rows.prefix(8)),
                columns: table.columns,
                grade: .partial,
                limitations: ["The selected column did not contain numeric values for the requested calculation."]
            )
        }
        return SpreadsheetOperationResult(
            kind: .aggregate,
            title: kind.displayName.capitalized,
            summary: "The \(kind.displayName) of \(valueColumn.name) is \(SpreadsheetNumberParser.format(value)) across \(numbers.count) numeric row(s).",
            details: provenance(kind: kind, valueColumn: valueColumn, filters: filters, matchingRows: rows.count, numericRows: numbers.count),
            rows: Array(rows.prefix(8)),
            columns: table.columns,
            grade: .verified,
            limitations: rows.count != numbers.count ? ["Some matching rows were skipped because \(valueColumn.name) was blank or non-numeric."] : []
        )
    }

    private static func groupAggregate(
        kind: SpreadsheetAggregateKind,
        valueColumn: SpreadsheetColumn,
        groupColumn: SpreadsheetColumn,
        filters: [SpreadsheetFilter],
        table: SpreadsheetTable
    ) -> SpreadsheetOperationResult {
        let rows = filteredRows(filters, in: table)
        let groups = Dictionary(grouping: rows) { row in
            table.cell(row: row, column: groupColumn).text.nilIfBlank ?? "(blank)"
        }
        let lines = groups.compactMap { group, rows -> (String, Double, Int)? in
            let numbers = rows.compactMap { table.cell(row: $0, column: valueColumn).number }
            guard let value = aggregateValue(kind: kind, numbers: numbers) else { return nil }
            return (group, value, numbers.count)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
        }
        let detailLines = lines.prefix(25).map { group, value, count in
            "- \(group): \(SpreadsheetNumberParser.format(value)) (\(count) numeric row(s))"
        }
        return SpreadsheetOperationResult(
            kind: .groupAggregate,
            title: "\(kind.displayName.capitalized) by \(groupColumn.name)",
            summary: "Grouped \(valueColumn.name) by \(groupColumn.name) across \(rows.count) matching row(s).",
            details: provenance(kind: kind, valueColumn: valueColumn, filters: filters, matchingRows: rows.count, numericRows: nil)
                + ["Grouped by: \(groupColumn.name)", ""] + detailLines,
            rows: Array(rows.prefix(8)),
            columns: table.columns,
            grade: .verified,
            limitations: lines.count > 25 ? ["Only the first 25 groups are listed."] : []
        )
    }

    private static func topRows(
        sortColumn: SpreadsheetColumn,
        limit: Int,
        descending: Bool,
        filters: [SpreadsheetFilter],
        table: SpreadsheetTable
    ) -> SpreadsheetOperationResult {
        let rows = filteredRows(filters, in: table)
        let sorted = rows
            .filter { table.cell(row: $0, column: sortColumn).number != nil }
            .sorted {
                let lhs = table.cell(row: $0, column: sortColumn).number ?? 0
                let rhs = table.cell(row: $1, column: sortColumn).number ?? 0
                if lhs == rhs {
                    return $0.rowNumber < $1.rowNumber
                }
                return descending ? lhs > rhs : lhs < rhs
            }
        return SpreadsheetOperationResult(
            kind: .topRows,
            title: descending ? "Top rows" : "Bottom rows",
            summary: "Found \(min(limit, sorted.count)) \(descending ? "top" : "bottom") row(s) by \(sortColumn.name).",
            details: [
                "Operation: \(descending ? "top rows" : "bottom rows")",
                "Sorted by: \(sortColumn.name)",
                "Direction: \(descending ? "descending" : "ascending")",
                "Matching rows before sort: \(rows.count)",
                "Numeric rows used: \(sorted.count)"
            ] + filterDetails(filters),
            rows: Array(sorted.prefix(limit)),
            columns: table.columns,
            grade: .verified,
            limitations: sorted.count != rows.count ? ["Rows with blank or non-numeric \(sortColumn.name) values were skipped."] : [],
            sortColumn: sortColumn
        )
    }

    private static func profile(column: SpreadsheetColumn?, table: SpreadsheetTable) -> SpreadsheetOperationResult {
        let profiles = table.columnProfiles()
        let selected = column.flatMap { target in profiles.first { $0.column.index == target.index } }
        let detailProfiles = selected.map { [$0] } ?? profiles
        return SpreadsheetOperationResult(
            kind: .profile,
            title: selected.map { "Column profile: \($0.column.name)" } ?? "Column profiles",
            summary: selected.map { "\($0.column.name) has \($0.nonEmptyCount) non-empty value(s)." }
                ?? "Profiled \(profiles.count) column(s).",
            details: detailProfiles.prefix(12).map { profile in
                "- \(profile.column.name): \(profile.nonEmptyCount) non-empty, \(profile.numericCount) numeric"
            },
            rows: Array(table.dataRows.prefix(8)),
            columns: table.columns,
            grade: .verified,
            limitations: detailProfiles.count > 12 ? ["Only the first 12 column profiles are listed."] : []
        )
    }

    private static func filteredRows(_ filters: [SpreadsheetFilter], in table: SpreadsheetTable) -> [SpreadsheetDataRow] {
        guard !filters.isEmpty else {
            return table.dataRows
        }
        return table.dataRows.filter { row in
            filters.allSatisfy { filter in
                let value = table.cell(row: row, column: filter.column).text
                let normalizedValue = SpreadsheetText.normalized(value)
                let normalizedFilter = SpreadsheetText.normalized(filter.value)
                return normalizedValue == normalizedFilter
                    || SpreadsheetText.containsTokenPhrase(normalizedValue, normalizedFilter)
            }
        }
    }

    private static func aggregateValue(kind: SpreadsheetAggregateKind, numbers: [Double]) -> Double? {
        guard !numbers.isEmpty else { return nil }
        switch kind {
        case .sum:
            return numbers.reduce(0, +)
        case .average:
            return numbers.reduce(0, +) / Double(numbers.count)
        case .count:
            return Double(numbers.count)
        case .min:
            return numbers.min()
        case .max:
            return numbers.max()
        }
    }

    private static func provenance(
        kind: SpreadsheetAggregateKind,
        valueColumn: SpreadsheetColumn?,
        filters: [SpreadsheetFilter],
        matchingRows: Int,
        numericRows: Int?
    ) -> [String] {
        var details = [
            "Operation: \(kind.displayName)",
            "Value column: \(valueColumn?.name ?? "not specified")",
            "Matching rows: \(matchingRows)"
        ]
        if let numericRows {
            details.append("Numeric rows used: \(numericRows)")
        }
        details.append(contentsOf: filterDetails(filters))
        return details
    }

    private static func filterDetails(_ filters: [SpreadsheetFilter]) -> [String] {
        guard !filters.isEmpty else {
            return ["Filters: none"]
        }
        return ["Filters: \(filters.map(\.displayText).joined(separator: "; "))"]
    }
}

private struct SpreadsheetFormulaCell {
    var sheetName: String
    var address: String
    var formula: String

    static func collect(from sheet: SpreadsheetSheet) -> [SpreadsheetFormulaCell] {
        sheet.rows.enumerated().flatMap { rowIndex, row in
            row.enumerated().compactMap { columnIndex, cell in
                guard let formula = cell.formula, !formula.isEmpty else {
                    return nil
                }
                return SpreadsheetFormulaCell(
                    sheetName: sheet.name,
                    address: "\(sheet.name)!\(SpreadsheetCellAddress.columnName(for: columnIndex))\(rowIndex + 1)",
                    formula: formula
                )
            }
        }
    }
}

private struct SpreadsheetPreview {
    var sheetName: String
    var columns: [String]
    var rows: [[String]]

    init(sheet: SpreadsheetSheet, maxRows: Int) {
        self.sheetName = sheet.name
        let width = sheet.rows.map(\.count).max() ?? 0
        self.columns = (0..<width).map { SpreadsheetCellAddress.columnName(for: $0) }
        self.rows = sheet.rows.prefix(maxRows).map { row in
            (0..<width).map { index in row.indices.contains(index) ? row[index].text : "" }
        }
    }

    init(table: SpreadsheetTable, maxRows: Int) {
        self.sheetName = table.sheet.name
        self.columns = table.columns.map(\.name)
        self.rows = table.dataRows.prefix(maxRows).map { row in
            table.columns.map { table.cell(row: row, column: $0).text }
        }
    }
}

private struct SpreadsheetEvidence {
    var markdown: String
    var sheetCount: Int
    var inspectedPaths: [String]
    var limitations: [String]
}

private enum SpreadsheetEvidenceBuilder {
    static func missingEvidence(rootURL: URL, request: LocalSkillRunRequest) -> SpreadsheetEvidence {
        let markdown = """
        # Spreadsheet Skill Evidence

        ## Workbook
        No supported spreadsheet file was found at `\(rootURL.path)`.

        ## Evidence Contract
        Roca looked for `.csv`, `.tsv`, and `.xlsx` files locally. Ask the user for a specific spreadsheet file or folder.
        """
        return SpreadsheetEvidence(markdown: markdown, sheetCount: 0, inspectedPaths: [], limitations: ["No supported spreadsheet file was found."])
    }

    static func ambiguousEvidence(rootURL: URL, candidates: [URL], request: LocalSkillRunRequest) -> SpreadsheetEvidence {
        let list = candidates.map { "- `\($0.path)`" }.joined(separator: "\n")
        let markdown = """
        # Spreadsheet Skill Evidence

        ## Clarification Needed
        Multiple spreadsheet files matched under `\(rootURL.path)`.

        \(list)

        ## Evidence Contract
        Ask the user which spreadsheet to analyze before calculating sums, averages, filters, or formula summaries.
        """
        return SpreadsheetEvidence(
            markdown: markdown,
            sheetCount: 0,
            inspectedPaths: candidates.map(\.path),
            limitations: ["Multiple spreadsheet files matched; no calculation was run."]
        )
    }

    static func analysisEvidence(document: SpreadsheetDocument, analysis: SpreadsheetAnalysis, request: LocalSkillRunRequest) -> SpreadsheetEvidence {
        var sections: [String] = [
            """
            # Spreadsheet Skill Evidence

            ## Workbook
            - File: `\(document.fileURL.path)`
            - Format: \(document.format)
            - Sheets: \(document.sheets.count)
            - Selected sheet: \(analysis.selectedSheet?.name ?? "none")
            - Mode: \(request.mode.rawValue)
            """
        ]

        if let operation = analysis.operation {
            sections.append(operationMarkdown(operation, table: analysis.table))
        }

        sections.append(sheetInventoryMarkdown(document.sheets))
        if !analysis.profiles.isEmpty {
            sections.append(columnProfileMarkdown(analysis.profiles))
        }
        for preview in analysis.previews {
            sections.append(previewMarkdown(preview))
        }
        if !analysis.formulaCells.isEmpty {
            sections.append(formulaMarkdown(analysis.formulaCells))
        }
        sections.append(
            """
            ## Evidence Contract
            Roca inspected local spreadsheet values and formula text only. Calculations are based on the selected sheet/table and bounded to parsed rows. Treat blank, non-numeric, or truncated rows according to the calculation notes above.
            """
        )
        return SpreadsheetEvidence(
            markdown: sections.joined(separator: "\n\n"),
            sheetCount: document.sheets.count,
            inspectedPaths: [document.fileURL.path],
            limitations: analysis.limitations
        )
    }

    private static func operationMarkdown(_ operation: SpreadsheetOperationResult, table: SpreadsheetTable?) -> String {
        var body = [
            "## \(operation.title)",
            operation.summary
        ]
        if !operation.details.isEmpty {
            body.append("")
            body.append(contentsOf: operation.details)
        }
        if operation.kind == .topRows, let table, let sortColumn = operation.sortColumn {
            body.append("")
            body.append(computedRankingMarkdown(operation: operation, table: table, sortColumn: sortColumn))
        } else if !operation.rows.isEmpty, let table {
            body.append("")
            body.append("### Matching Row Preview")
            body.append(markdownTable(columns: operation.columns.map(\.name), rows: operation.rows.prefix(8).map { row in
                operation.columns.map { table.cell(row: row, column: $0).text }
            }))
        }
        return body.joined(separator: "\n")
    }

    private static func computedRankingMarkdown(
        operation: SpreadsheetOperationResult,
        table: SpreadsheetTable,
        sortColumn: SpreadsheetColumn
    ) -> String {
        let supportingColumns = rankingSupportingColumns(in: table, sortColumn: sortColumn)
        let columns = ["Rank", "Row", sortColumn.name] + supportingColumns.map(\.name)
        let rows = operation.rows.enumerated().map { index, row in
            let sortCell = table.cell(row: row, column: sortColumn)
            let sortValue = sortCell.number.map(SpreadsheetNumberParser.format) ?? sortCell.text
            return [String(index + 1), String(row.rowNumber), sortValue]
                + supportingColumns.map { table.cell(row: row, column: $0).text }
        }
        return """
        ### Computed Ranking
        \(markdownTable(columns: columns, rows: rows))
        """
    }

    private static func rankingSupportingColumns(
        in table: SpreadsheetTable,
        sortColumn: SpreadsheetColumn
    ) -> [SpreadsheetColumn] {
        var selected: [SpreadsheetColumn] = []
        var selectedIndexes = Set([sortColumn.index])
        func append(_ column: SpreadsheetColumn?) {
            guard let column, selectedIndexes.insert(column.index).inserted else { return }
            selected.append(column)
        }

        let sortBase = relatedMetricBase(sortColumn.name)
        if !sortBase.isEmpty {
            let profiles = table.columnProfiles()
            for column in table.columns where column.index != sortColumn.index {
                let header = SpreadsheetText.normalized(column.name)
                guard header.contains(sortBase), !header.contains("currency") else { continue }
                guard profiles.first(where: { $0.column.index == column.index })?.numericCount ?? 0 > 0 else { continue }
                append(column)
            }
        }

        for preferredName in ["Record ID", "TX ID", "Type", "Product", "Amount", "Amount (USD)", "Grand Total", "Fee Currency", "Commission Currency", "Timestamp"] {
            let preferredKey = SpreadsheetText.normalized(preferredName)
            append(table.columns.first { SpreadsheetText.normalized($0.name) == preferredKey })
        }
        return Array(selected.prefix(7))
    }

    private static func relatedMetricBase(_ columnName: String) -> String {
        let withoutParenthetical = columnName
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let normalized = SpreadsheetText.normalized(withoutParenthetical)
        return normalized.count >= 3 ? normalized : ""
    }

    private static func sheetInventoryMarkdown(_ sheets: [SpreadsheetSheet]) -> String {
        let rows = sheets.map { sheet in
            [
                sheet.name,
                String(sheet.rows.count),
                String(sheet.rows.map(\.count).max() ?? 0),
                sheet.truncated ? "yes" : "no"
            ]
        }
        return """
        ## Sheet Inventory
        \(markdownTable(columns: ["Sheet", "Rows Parsed", "Max Columns", "Truncated"], rows: rows))
        """
    }

    private static func columnProfileMarkdown(_ profiles: [SpreadsheetColumnProfile]) -> String {
        let rows = profiles.prefix(20).map { profile in
            [
                "\(profile.column.addressName): \(profile.column.name)",
                String(profile.nonEmptyCount),
                String(profile.numericCount),
                profile.sum.map(SpreadsheetNumberParser.format) ?? "",
                profile.average.map(SpreadsheetNumberParser.format) ?? "",
                profile.examples.joined(separator: ", ")
            ]
        }
        return """
        ## Column Profiles
        \(markdownTable(columns: ["Column", "Non-empty", "Numeric", "Sum", "Average", "Examples"], rows: rows))
        """
    }

    private static func previewMarkdown(_ preview: SpreadsheetPreview) -> String {
        """
        ## Preview: \(preview.sheetName)
        \(markdownTable(columns: preview.columns, rows: preview.rows))
        """
    }

    private static func formulaMarkdown(_ formulas: [SpreadsheetFormulaCell]) -> String {
        let lines = formulas.prefix(25).map { "- \($0.address): `\($0.formula)`" }
        let suffix = formulas.count > 25 ? "\n\n\(formulas.count - 25) additional formula cell(s) omitted from the preview." : ""
        return """
        ## Formula Inventory
        \(lines.joined(separator: "\n"))\(suffix)
        """
    }

    private static func markdownTable(columns: [String], rows: [[String]]) -> String {
        guard !columns.isEmpty else {
            return "No table data."
        }
        let header = "| " + columns.map(escapeTableCell).joined(separator: " | ") + " |"
        let separator = "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
        let body = rows.map { row in
            let padded = (0..<columns.count).map { index in row.indices.contains(index) ? row[index] : "" }
            return "| " + padded.map(escapeTableCell).joined(separator: " | ") + " |"
        }
        return ([header, separator] + body).joined(separator: "\n")
    }

    private static func escapeTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum SpreadsheetNumberParser {
    static func number(from text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var multiplier = 1.0
        if value.hasPrefix("("), value.hasSuffix(")") {
            multiplier = -1
            value = String(value.dropFirst().dropLast())
        }
        if value.hasSuffix("%") {
            multiplier *= 0.01
            value.removeLast()
        }
        value = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"[A-Za-z]"#, options: .regularExpression) == nil else {
            return nil
        }
        return Double(value).map { $0 * multiplier }
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private enum SpreadsheetCellAddress {
    static func columnIndex(from cellRef: String) -> Int? {
        let letters = cellRef.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }
        var result = 0
        for scalar in String(letters).uppercased().unicodeScalars {
            let value = scalar.value
            let base = UnicodeScalar("A").value
            guard value >= base, value <= UnicodeScalar("Z").value else { return nil }
            result = result * 26 + Int(value - base + 1)
        }
        return result - 1
    }

    static func columnName(for index: Int) -> String {
        var value = index + 1
        var name = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            let scalar = UnicodeScalar(Int(UnicodeScalar("A").value) + remainder)!
            name = String(Character(scalar)) + name
            value = (value - 1) / 26
        }
        return name
    }
}

private enum SpreadsheetText {
    static let commonTokens = Set(["the", "and", "for", "from", "with", "this", "that", "row", "rows", "column", "columns"])

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func significantTokens(in value: String) -> [String] {
        normalized(value)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !commonTokens.contains($0) }
    }

    static func containsTokenPhrase(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return text == phrase
            || text.hasPrefix("\(phrase) ")
            || text.hasSuffix(" \(phrase)")
            || text.contains(" \(phrase) ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
