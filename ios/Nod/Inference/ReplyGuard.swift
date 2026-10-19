// ReplyGuard.swift
// Last line of defense for the phrases the listening prompt bans
// ("You're not alone.", "I'm sorry to hear that…"). Small models slip
// into them under pressure; when one does, we drop the sentence that
// contains it rather than show it.
//
// The phrase list lives in prompts/banned_phrases.txt so the app and the
// eval runner (ios/evals/runner) share it. Foundation + NaturalLanguage
// only, so the runner can compile this file on macOS.

import Foundation
import NaturalLanguage

enum ReplyGuard {

    /// Parse banned_phrases.txt: one phrase per line, `#` comments.
    static func parsePhrases(_ fileText: String) -> [String] {
        fileText
            .split(whereSeparator: \.isNewline)
            .map { normalize(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The banned phrases bundled with the app (empty if missing).
    static let bundledPhrases: [String] = {
        guard let url = Bundle.main.url(
                forResource: "banned_phrases",
                withExtension: "txt",
                subdirectory: "prompts"
              ),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parsePhrases(text)
    }()

    /// Banned phrases that appear anywhere in `reply`.
    static func matches(in reply: String, phrases: [String]) -> [String] {
        let haystack = normalize(reply)
        return phrases.filter { haystack.contains($0) }
    }

    /// `reply` with every sentence that contains a banned phrase removed.
    ///
    /// While streaming, pass `keepIfEmpty: false` so a reply that so far
    /// is only a banned sentence shows nothing yet (typing dots stay up).
    /// For the final text pass `true`: if every sentence was banned, the
    /// original is better than an empty bubble.
    static func clean(_ reply: String, phrases: [String], keepIfEmpty: Bool) -> String {
        guard !phrases.isEmpty, !matches(in: reply, phrases: phrases).isEmpty else {
            return reply
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = reply
        var kept = ""
        tokenizer.enumerateTokens(in: reply.startIndex..<reply.endIndex) { range, _ in
            let sentence = String(reply[range])
            if matches(in: sentence, phrases: phrases).isEmpty {
                kept += sentence
            }
            return true
        }
        let trimmed = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && keepIfEmpty { return reply }
        return trimmed
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }
}
