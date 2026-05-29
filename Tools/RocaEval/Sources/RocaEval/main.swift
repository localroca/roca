import Foundation
import RocaEvalSupport

@main
struct RocaEvalCommand {
    static func main() async {
        do {
            let options = try CommandOptions.parse(CommandLine.arguments)
            switch options.command {
            case .help:
                print(Self.usage)
            case .run(let configuration):
                let suite = try EvalSuite.load(from: configuration.suiteURL)
                let runID = EvalRunConfiguration.defaultRunID()
                let outputDirectory = configuration.outputURL ?? Self.defaultOutputDirectory(runID: runID)
                let runner = EvalRunner(
                    client: OllamaEvalBrainClient(baseURL: configuration.baseURL)
                )
                let output = try await runner.run(
                    EvalRunConfiguration(
                        suite: suite,
                        models: configuration.models,
                        filter: EvalScenarioFilter(
                            scenarioIDs: configuration.scenarioIDs,
                            includeTags: configuration.includeTags,
                            excludeTags: configuration.excludeTags
                        ),
                        repeats: configuration.repeats,
                        baseURL: configuration.baseURL,
                        outputDirectory: outputDirectory,
                        runID: runID
                    )
                )
                try EvalResultWriter.write(output)
                print("RocaEval wrote results to \(output.outputDirectory.path)")
                print("Judge packet: \(output.outputDirectory.appendingPathComponent("judge_packet.md").path)")
            }
        } catch {
            fputs("RocaEval error: \(error.localizedDescription)\n\n\(Self.usage)\n", stderr)
            exit(1)
        }
    }

    private static func defaultOutputDirectory(runID: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    private static let usage = """
    Usage:
      swift run RocaEval run [options]

    Options:
      --suite PATH          Eval suite JSON. Default: evals/suites/assistant_quality_v1.json
      --models LIST         Comma-separated Ollama model names, or "all". Default: all
      --scenarios LIST      Comma-separated scenario IDs to run.
      --include-tags LIST   Run scenarios with any of these comma-separated tags.
      --exclude-tags LIST   Skip scenarios with any of these comma-separated tags.
      --repeats N           Repeat count. Default: suite default, usually 3
      --base-url URL        Ollama base URL. Default: http://127.0.0.1:11434
      --out PATH            Output directory. Default: evals/results/<run-id>
    """
}

private enum EvalCommand {
    case run(RunCommandConfiguration)
    case help
}

private struct RunCommandConfiguration {
    var suiteURL = URL(fileURLWithPath: "evals/suites/assistant_quality_v1.json")
    var models: EvalModelSelection = .all
    var scenarioIDs: Set<String>?
    var includeTags: Set<String> = []
    var excludeTags: Set<String> = []
    var repeats: Int?
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    var outputURL: URL?
}

private struct CommandOptions {
    var command: EvalCommand

    static func parse(_ arguments: [String]) throws -> CommandOptions {
        var arguments = Array(arguments.dropFirst())
        guard let command = arguments.first else {
            return CommandOptions(command: .help)
        }
        arguments.removeFirst()

        switch command {
        case "help", "--help", "-h":
            return CommandOptions(command: .help)
        case "run":
            return CommandOptions(command: .run(try parseRun(arguments)))
        default:
            throw EvalError.invalidArguments("Unknown command: \(command)")
        }
    }

    private static func parseRun(_ arguments: [String]) throws -> RunCommandConfiguration {
        var configuration = RunCommandConfiguration()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw EvalError.invalidArguments("Missing value for \(option).")
                }
                index += 1
                return arguments[index]
            }

            switch option {
            case "--suite":
                configuration.suiteURL = URL(fileURLWithPath: try value())
            case "--models":
                configuration.models = EvalModelSelection.parse(try value())
            case "--scenarios":
                configuration.scenarioIDs = set(from: try value())
            case "--include-tags":
                configuration.includeTags = set(from: try value()) ?? []
            case "--exclude-tags":
                configuration.excludeTags = set(from: try value()) ?? []
            case "--repeats":
                guard let repeats = Int(try value()), repeats > 0 else {
                    throw EvalError.invalidArguments("--repeats must be a positive integer.")
                }
                configuration.repeats = repeats
            case "--base-url":
                guard let url = URL(string: try value()) else {
                    throw EvalError.invalidArguments("--base-url must be a valid URL.")
                }
                configuration.baseURL = url
            case "--out":
                configuration.outputURL = URL(fileURLWithPath: try value(), isDirectory: true)
            default:
                throw EvalError.invalidArguments("Unknown option: \(option)")
            }
            index += 1
        }
        return configuration
    }

    private static func set(from rawValue: String) -> Set<String>? {
        let values = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : Set(values)
    }
}
