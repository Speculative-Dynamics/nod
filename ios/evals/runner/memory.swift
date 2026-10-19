// memory.swift — memory eval suite for the runner (`--suite memory`).
//
// Three kinds of case in ios/evals/memory/cases:
//   recall    — play a long conversation through the app's pipeline and
//               check the final reply knows (or doesn't volunteer)
//               specific facts. Uses the model.
//   search    — given past messages, check which ones each new message
//               recalls (PastMessageRecall). Deterministic, no model.
//   grounding — check that sentences naming people/places the user
//               never mentioned are removed from a note, and grounded
//               ones kept (MemoryGrounding). Deterministic, no model.

import Foundation

struct MemoryCase: Decodable {
    struct Query: Decodable { let message: String; let expect: [String]; let allow: [String]? }
    struct Note: Decodable { let note: String; let keep: [String]; let drop: [String] }

    let id: String
    let kind: String
    let expect: String?
    // recall
    let turns: [String]?
    let replyMustInclude: [String]?
    let replyMustNotInclude: [String]?
    // search
    let pastMessages: [String]?
    let queries: [Query]?
    // grounding
    let source: [String]?
    let notes: [Note]?
}

@MainActor
func runMemorySuite(listeningPrompt: String) async throws -> (report: String, json: Data) {
    let chapterPrompt = try String(contentsOf: url("prompts/chapter_note.md"), encoding: .utf8)
    let dir = url("ios/evals/memory/cases")
    let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var report = ""
    var log: [[String: String]] = []
    var totals: [String: (pass: Int, total: Int)] = [:]
    func score(_ kind: String, _ ok: Bool) {
        var t = totals[kind] ?? (0, 0)
        t.total += 1
        if ok { t.pass += 1 }
        totals[kind] = t
    }

    for file in files {
        let c: MemoryCase
        do { c = try JSONDecoder().decode(MemoryCase.self, from: Data(contentsOf: file)) } catch {
            print("✗ \(file.lastPathComponent): \(error)"); continue
        }
        if let caseFilter,
           !caseFilter.split(separator: ",").contains(where: { c.id.contains($0) }) { continue }
        print("▸ \(c.id)")
        report += "\n## \(c.id) (\(c.kind))\n\n"
        if let expect = c.expect { report += "_Expect: \(expect)_\n\n" }

        switch c.kind {
        case "recall":
            var conversation = PipelineConversation(listeningPrompt: listeningPrompt, chapterPrompt: chapterPrompt)
            var last: PipelineConversation.Turn?
            let turns = c.turns ?? []
            for (i, userText) in turns.enumerated() {
                let turn = await conversation.send(userText, temperature: temperature)
                if i == turns.count - 1, !turn.memoryContext.isEmpty {
                    report += "**Memory context for the last message:**\n\n```\n\(turn.memoryContext)\n```\n\n"
                }
                last = turn
            }
            let reply = last?.shown ?? ""
            let lower = reply.lowercased()
            let missing = (c.replyMustInclude ?? []).filter { !lower.contains($0.lowercased()) }
            let leaked = (c.replyMustNotInclude ?? []).filter { lower.contains($0.lowercased()) }
            let ok = missing.isEmpty && leaked.isEmpty && last?.error == nil
            score("recall", ok)
            report += "**Last user message:** \(turns.last ?? "")\n\n**Nod:** \(reply)\n\n"
            report += "\(ok ? "✓" : "✗")"
            if !missing.isEmpty { report += " missing: \(missing.joined(separator: ", "))" }
            if !leaked.isEmpty { report += " volunteered: \(leaked.joined(separator: ", "))" }
            if let error = last?.error { report += " error: \(error)" }
            report += " (\(conversation.modelCalls) model calls)\n\n"
            report += "**Chapter notes:**\n" + conversation.memory.chapters.enumerated()
                .map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n") + "\n"
            log.append(["id": c.id, "reply": reply, "ok": "\(ok)", "calls": "\(conversation.modelCalls)"])

        case "search":
            var recall = PastMessageRecall()
            for (i, text) in (c.pastMessages ?? []).enumerated() {
                recall.add(text: text, date: Date(timeIntervalSince1970: Double(i) * 3600), order: i)
            }
            for q in c.queries ?? [] {
                let got = recall.recall(for: q.message, before: Int.max).map(\.text)
                func matches(_ needle: String) -> Bool { got.contains { $0.contains(needle) } }
                let missing = q.expect.filter { !matches($0) }
                let extra = got.filter { text in
                    !q.expect.contains { text.contains($0) } && !(q.allow ?? []).contains { text.contains($0) }
                }
                let ok = missing.isEmpty && extra.isEmpty
                score("search", ok)
                report += "- \(ok ? "✓" : "✗") \"\(q.message)\" → \(got.isEmpty ? "nothing" : got.map { "\"\($0)\"" }.joined(separator: ", "))"
                if !missing.isEmpty { report += " missing: \(missing.joined(separator: ", "))" }
                if !extra.isEmpty { report += " unwanted: \(extra.count)" }
                report += "\n"
            }

        case "grounding":
            let source = (c.source ?? []).joined(separator: "\n")
            for n in c.notes ?? [] {
                let cleaned = MemoryGrounding.clean(n.note, source: source)
                let lostGood = n.keep.filter { !cleaned.contains($0) }
                let keptBad = n.drop.filter { cleaned.contains($0) }
                let ok = lostGood.isEmpty && keptBad.isEmpty
                score("grounding", ok)
                report += "- \(ok ? "✓" : "✗") \"\(n.note)\" → \"\(cleaned)\""
                if !lostGood.isEmpty { report += " wrongly removed: \(lostGood.joined(separator: ", "))" }
                if !keptBad.isEmpty { report += " kept invented: \(keptBad.joined(separator: ", "))" }
                report += "\n"
            }

        default:
            report += "unknown kind \(c.kind)\n"
        }
    }

    var header = "# Memory eval — \(label)\n\n"
    for kind in ["recall", "search", "grounding"] {
        if let t = totals[kind] { header += "- \(kind): \(t.pass)/\(t.total) passed\n" }
    }
    let json = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
    return (header + report, json)
}
