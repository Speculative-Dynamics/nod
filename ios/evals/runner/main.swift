// main.swift — Nod listening-mode eval runner (macOS).
//
// Plays each scripted conversation in ios/evals/listening-mode/cases
// through Apple's on-device model, using the app's own turn assembly
// (ListeningTurns), AFM session builder (AFMListening) and reply guard
// (ReplyGuard) — compiled straight from ios/Nod by run.sh, so the eval
// exercises the code the app ships.
//
// Writes results.json and report.md: every reply, plus automatic flags
// (banned phrases, advice, length, sympathy openers). Judging warmth and
// specificity is left to a human (or a model) reading report.md against
// each case's "expect" note.
//
// Usage: run.sh [--suite listening|memory] [--prompt path] [--label name]
//               [--case id1,id2] [--temperature n|default]

import Foundation
import FoundationModels

// MARK: - Case format

struct EvalCase: Decodable {
    struct Context: Decodable {
        var personalization: String?
        /// A chapter note the case starts from, as if from earlier.
        var chapter: String?
        /// Past user messages recalled into context, as the app formats
        /// them: (when) "their words".
        var pastMessages: [String]?
    }
    let id: String
    let category: String
    let context: Context?
    let turns: [String]
    let expect: String
    /// Response length in tokens, matching the app's response styles
    /// (brief 200, conversational 300, deeper 400). Default 300.
    let maxTokens: Int?
}

struct TurnResult: Encodable {
    let user: String
    let raw: String
    let shown: String
    let seconds: Double
    let error: String?
    let flags: [String]
}

struct CaseResult: Encodable {
    let id: String
    let category: String
    let expect: String
    let turns: [TurnResult]
    /// Chapter notes written during the case (empty if never compressed).
    let chapters: [String]
    var flagCount: Int { turns.reduce(0) { $0 + $1.flags.count } }
}

// MARK: - Args

var promptPath = "prompts/listening_mode.md"
var label = "run"
var caseFilter: String?
var temperature: Double? = AFMListening.listeningTemperature
var suite = "listening"
/// MLX prefill step size override (tokens per step).
var prefillSpec: Int?
/// AFM sampling mode: "nucleus:0.9", "topk:40", or nil for the default.
var samplingSpec: String?
var samplingMode: GenerationOptions.SamplingMode? {
    guard let spec = samplingSpec else { return nil }
    let parts = spec.split(separator: ":")
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "nucleus": return Double(parts[1]).map { .random(probabilityThreshold: $0) }
    case "topk": return Int(parts[1]).map { .random(top: $0) }
    default: return nil
    }
}
/// Memory design for recall cases: entities (the app today), episodic, or both.
var memoryStrategy = "entities"
var repoRoot = FileManager.default.currentDirectoryPath
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--prompt": promptPath = args.next() ?? promptPath
        case "--label": label = args.next() ?? label
        case "--case": caseFilter = args.next()
        case "--engine": engineSpec = args.next() ?? engineSpec
        case "--prefill": prefillSpec = args.next().flatMap(Int.init)
        case "--suite": suite = args.next() ?? suite
        case "--sampling": samplingSpec = args.next()
        case "--memory": memoryStrategy = args.next() ?? memoryStrategy
        case "--temperature":
            // A number, or "default" for the model's own default.
            temperature = args.next().flatMap(Double.init)
        case "--repo": repoRoot = args.next() ?? repoRoot
        default:
            FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
            exit(2)
        }
    }
}

func url(_ relative: String) -> URL {
    relative.hasPrefix("/")
        ? URL(fileURLWithPath: relative)
        : URL(fileURLWithPath: repoRoot).appendingPathComponent(relative)
}

// MARK: - Checks

let bannedPhrases = ReplyGuard.parsePhrases(
    (try? String(contentsOf: url("prompts/banned_phrases.txt"), encoding: .utf8)) ?? ""
)

/// Not banned outright, but usually a sign of fixing or cheerleading.
let softMarkers = [
    "have you tried", "you should", "you might want to", "you could try",
    "it might help to", "consider ", "make sure to", "remember to",
    "you've got this", "proud of you", "it's great that", "self-care",
]

func flags(for reply: String, guarded: String) -> [String] {
    var out: [String] = []
    for phrase in ReplyGuard.matches(in: reply, phrases: bannedPhrases) {
        out.append("banned: \(phrase)")
    }
    let lower = guarded.lowercased()
    for marker in softMarkers where lower.contains(marker) {
        out.append("advice/cheer: \(marker.trimmingCharacters(in: .whitespaces))")
    }
    let sentences = guarded.split(whereSeparator: { ".!?".contains($0) })
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if sentences.count > 5 { out.append("long: \(sentences.count) sentences") }
    let questions = guarded.filter { $0 == "?" }.count
    if questions > 1 { out.append("questions: \(questions)") }
    if lower.hasPrefix("i'm sorry") || lower.hasPrefix("i am sorry") || lower.hasPrefix("i’m sorry") {
        out.append("sympathy opener")
    }
    if guarded.contains("**") || guarded.contains("\n- ") || guarded.contains("\n1.") {
        out.append("markdown/list")
    }
    if guarded.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
        out.append("emoji")
    }
    return out
}

// MARK: - Run

await prepareBackend()

let listeningPrompt: String
do {
    listeningPrompt = try String(contentsOf: url(promptPath), encoding: .utf8)
} catch {
    print("Can't read prompt at \(promptPath): \(error)")
    exit(1)
}

let chapterPrompt = (try? String(contentsOf: url("prompts/chapter_note.md"), encoding: .utf8)) ?? ""

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

if suite == "memory" {
    let (memoryReport, json) = try await runMemorySuite(listeningPrompt: listeningPrompt)
    let outDir = url("ios/evals/results/\(stamp)-memory-\(label)")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try memoryReport.write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    try json.write(to: outDir.appendingPathComponent("results.json"))
    print("\nWrote \(outDir.path)/report.md")
    print(memoryReport.split(separator: "\n").filter { $0.contains("passed") }.joined(separator: "\n"))
    exit(0)
}

let casesDir = url("ios/evals/listening-mode/cases")
let caseFiles = (try? FileManager.default.contentsOfDirectory(at: casesDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

var results: [CaseResult] = []

for file in caseFiles {
    let evalCase: EvalCase
    do {
        evalCase = try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: file))
    } catch {
        print("✗ \(file.lastPathComponent): \(error)")
        continue
    }
    if let caseFilter,
       !caseFilter.split(separator: ",").contains(where: { evalCase.id.contains($0) }) { continue }
    print("▸ \(evalCase.id)")

    var conversation = PipelineConversation(
        listeningPrompt: listeningPrompt,
        chapterPrompt: chapterPrompt,
        personalization: evalCase.context?.personalization ?? "",
        seedChapter: evalCase.context?.chapter ?? "",
        seedPastMessages: evalCase.context?.pastMessages ?? []
    )
    var turnResults: [TurnResult] = []
    for userText in evalCase.turns {
        let turn = await conversation.send(userText, maxTokens: evalCase.maxTokens ?? 300, temperature: temperature)
        let turnFlags = (turn.error.map { ["error: \($0)"] } ?? []) + flags(for: turn.raw, guarded: turn.shown)
        turnResults.append(TurnResult(user: userText, raw: turn.raw, shown: turn.shown,
                                      seconds: turn.seconds, error: turn.error, flags: turnFlags))
    }
    results.append(CaseResult(
        id: evalCase.id,
        category: evalCase.category,
        expect: evalCase.expect,
        turns: turnResults,
        chapters: conversation.memory.chapters.map(\.text)
    ))
}

// MARK: - Output

let outDir = url("ios/evals/results/\(stamp)-\(label)")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(results).write(to: outDir.appendingPathComponent("results.json"))

let totalTurns = results.reduce(0) { $0 + $1.turns.count }
let flaggedTurns = results.reduce(0) { $0 + $1.turns.filter { !$0.flags.isEmpty }.count }
let bannedTurns = results.reduce(0) { $0 + $1.turns.filter { $0.flags.contains { $0.hasPrefix("banned") } }.count }
let errorTurns = results.reduce(0) { $0 + $1.turns.filter { $0.error != nil }.count }
let avgSeconds = results.flatMap(\.turns).map(\.seconds).reduce(0, +) / Double(max(totalTurns, 1))

var report = """
# Listening eval — \(label)

- Prompt: `\(promptPath)`
- Model: \(backendDescription)\(mlxModelPath == nil ? ", temperature \(temperature.map { String($0) } ?? "default"), sampling \(samplingSpec ?? "default")" : "")
- Peak memory: \(backendPeakMemoryGB().map { String(format: "%.2f GB", $0) } ?? "n/a")
- Cases: \(results.count), turns: \(totalTurns)
- Turns with any flag: \(flaggedTurns)
- Turns with a banned phrase (before guard): \(bannedTurns)
- Errors: \(errorTurns)
- Average reply time: \(String(format: "%.2f", avgSeconds)) s

"""
for result in results {
    report += "\n## \(result.id) (\(result.category))\n\n_Expect: \(result.expect)_\n\n"
    for turn in result.turns {
        report += "**User:** \(turn.user)\n\n**Nod:** \(turn.shown.isEmpty ? "_(empty)_" : turn.shown)\n\n"
        if turn.raw != turn.shown {
            report += "> Guard removed text. Raw: \(turn.raw.replacingOccurrences(of: "\n", with: " "))\n\n"
        }
        if !turn.flags.isEmpty {
            report += "> Flags: \(turn.flags.joined(separator: "; "))\n\n"
        }
    }
    if !result.chapters.isEmpty {
        report += "**Chapter notes:**\n" + result.chapters.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n\n"
    }
}
try report.write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
print("\nWrote \(outDir.path)/report.md")
print("Flagged turns: \(flaggedTurns)/\(totalTurns), banned before guard: \(bannedTurns), errors: \(errorTurns)")
