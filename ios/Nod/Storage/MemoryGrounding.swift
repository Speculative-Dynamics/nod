// MemoryGrounding.swift
// Keeps model-written memory honest. Apple's on-device model, asked to
// write a note about a stretch of conversation, sometimes invents names
// ("ALEX", "LUCY and MIKE") or mangles real ones into initials ("L.").
// Evals caught this repeatedly. This removes any sentence that names a
// person, place or organization that never appears in the source
// messages. Cheap, on-device, no model call.
//
// Foundation + NaturalLanguage only, so the eval runner can compile it.

import Foundation
import NaturalLanguage

enum MemoryGrounding {

    /// Capitalized words that are never names.
    private static let notNames: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "nod", "they", "they're", "they've", "their",
        "mr", "mrs", "ms", "dr",
    ]

    /// `note` with every sentence that names something absent from
    /// `source` removed. Returns "" if nothing grounded is left.
    static func clean(_ note: String, source: String) -> String {
        let sourceWords = words(in: source)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = note
        var kept = ""
        tokenizer.enumerateTokens(in: note.startIndex..<note.endIndex) { range, _ in
            let sentence = String(note[range])
            if ungroundedNames(in: sentence, sourceWords: sourceWords).isEmpty {
                kept += sentence
            }
            return true
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names in `sentence` that don't occur in the source.
    static func ungroundedNames(in sentence: String, source: String) -> [String] {
        ungroundedNames(in: sentence, sourceWords: words(in: source))
    }

    private static func ungroundedNames(in sentence: String, sourceWords: Set<String>) -> [String] {
        var candidates: [String] = []

        // Named entities per Apple's tagger.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, nameTags.contains(tag) { candidates.append(String(sentence[range])) }
            return true
        }

        // Plus any capitalized word that isn't the first word of the
        // sentence: the tagger misses all-caps inventions and initials.
        let tokens = sentence.split(whereSeparator: { $0.isWhitespace })
        for (i, raw) in tokens.enumerated() where i > 0 {
            let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
            guard let first = word.first, first.isUppercase else { continue }
            candidates.append(word)
        }

        return candidates.filter { candidate in
            let parts = words(in: candidate)
            guard !parts.isEmpty else { return false }
            return parts.contains { !sourceWords.contains($0) && !notNames.contains($0) }
        }
    }

    /// Lowercased words with possessives stripped.
    private static func words(in text: String) -> Set<String> {
        var out = Set<String>()
        let strip = CharacterSet.punctuationCharacters
        for raw in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" }) {
            var word = String(raw).trimmingCharacters(in: strip)
            if word.hasSuffix("'s") { word = String(word.dropLast(2)) }
            if !word.isEmpty { out.insert(word) }
        }
        return out
    }
}
