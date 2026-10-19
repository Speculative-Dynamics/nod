// PastMessageRecall.swift
// How Nod remembers specifics: by searching what the user actually said.
//
// When the user writes, we look through their older messages (the ones
// no longer in the verbatim history the model sees) for ones about the
// same thing, and show the model the best few in the user's own words,
// newest first. Nothing is paraphrased, so nothing can be invented, and
// a later correction outranks what it corrects.
//
// Matching is deliberately simple and predictable:
//   - content words (nouns, names, verbs, adjectives), lemmatized, with
//     rarer words counting more — "work" alone doesn't drag up every
//     work message, "Leila" does
//   - relationship words count as the same term ("boss" finds "my
//     manager Priya"), since that's most of how people refer to someone
//     without a name
// Evals showed sentence embeddings added nothing here, so there are none.
//
// Also used to pick which older chapter notes are relevant.
// Foundation + NaturalLanguage only, so the eval runner can compile it.

import Foundation
import NaturalLanguage

struct PastMessageRecall {

    struct Entry: Sendable {
        let id: UUID
        let text: String
        let date: Date
        /// Position in the conversation; higher is newer.
        let order: Int
        fileprivate let terms: Set<String>
    }

    static let topK = 3

    /// A shared term must be at least this distinctive (inverse document
    /// frequency) to count.
    static let minTermWeight = 1.0

    private(set) var entries: [Entry] = []
    private var documentFrequency: [String: Int] = [:]

    mutating func add(id: UUID = UUID(), text: String, date: Date, order: Int) {
        let terms = Self.terms(text)
        entries.append(Entry(id: id, text: text, date: date, order: order, terms: terms))
        for term in terms { documentFrequency[term, default: 0] += 1 }
    }

    mutating func remove(ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        for entry in removed {
            for term in entry.terms { documentFrequency[term, default: 1] -= 1 }
        }
    }

    /// Entries relevant to `message`, considering only those with
    /// `order < limit` (older than what the model already sees verbatim).
    /// Best matches first by relevance, then returned newest first.
    func recall(for message: String, before limit: Int, topK: Int = Self.topK) -> [Entry] {
        let query = Self.terms(message)
        guard !query.isEmpty else { return [] }
        let n = Double(entries.count)
        func weight(_ term: String) -> Double {
            log((n + 1) / (Double(documentFrequency[term] ?? 0) + 0.5))
        }
        var scored: [(Entry, Double)] = []
        for entry in entries where entry.order < limit {
            let score = query.intersection(entry.terms)
                .map(weight)
                .filter { $0 > Self.minTermWeight }
                .reduce(0, +)
            if score > 0 { scored.append((entry, score)) }
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.order > $1.0.order }
            .prefix(topK)
            .map(\.0)
            .sorted { $0.order > $1.order }
    }

    // MARK: - Terms

    private static let stopwords: Set<String> = [
        "be", "have", "do", "get", "go", "know", "think", "feel", "say", "tell", "make",
        "want", "need", "thing", "kind", "lot", "way", "time", "day", "today", "now",
        "random", "test", "really", "just", "still", "again", "like", "okay", "ok", "lol",
        "yeah", "good", "bad", "fine", "great", "much", "many", "one", "something",
        "anything", "everything", "nothing", "name",
    ]

    /// Lemmatized, lowercased content words, plus `rel:<key>` for each
    /// relationship word.
    static func terms(_ text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text
        let content: Set<NLTag> = [.noun, .verb, .adjective, .otherWord, .number]
        var out = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard let tag, content.contains(tag) else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let word = (lemma ?? String(text[range])).lowercased()
            // Skip contraction fragments ("'s", "n't") the tagger
            // returns as words.
            guard word.count > 1, word.first?.isLetter == true, !word.contains("'"),
                  !word.contains("\u{2019}"), !stopwords.contains(word) else { return true }
            out.insert(word)
            return true
        }
        for key in relationshipWords(in: text) { out.insert("rel:" + key) }
        return out
    }

    // MARK: - Relationship words

    /// Words people use interchangeably for the same relationship. Each
    /// word maps to its group's first entry.
    private static let relationshipGroups: [[String]] = [
        ["manager", "boss", "supervisor", "lead"],
        ["partner", "girlfriend", "gf", "boyfriend", "bf", "husband", "wife", "spouse", "fiance", "fiancee"],
        ["mother", "mom", "mum", "mama", "mommy"],
        ["father", "dad", "papa", "daddy"],
        ["sister", "sis"],
        ["brother", "bro"],
        ["grandmother", "grandma", "nana", "granny"],
        ["grandfather", "grandpa"],
        ["friend", "bestie", "bff"],
        ["coworker", "colleague", "teammate"],
        ["roommate", "flatmate", "housemate"],
        ["landlord", "landlady"],
        ["dog", "pup", "puppy", "doggo"],
        ["cat", "kitty", "kitten"],
        ["therapist", "counselor", "counsellor"],
        ["doctor", "doc"],
        ["teacher", "professor", "prof"],
    ]

    private static let relationshipKey: [String: String] = {
        var map: [String: String] = [:]
        for group in relationshipGroups {
            for word in group { map[word] = group[0] }
        }
        return map
    }()

    /// Relationship keys mentioned in `text` ("my boss's" → "manager").
    static func relationshipWords(in text: String) -> Set<String> {
        var keys = Set<String>()
        let strip = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        for raw in text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" }) {
            var word = String(raw).trimmingCharacters(in: strip)
            if word.hasSuffix("'s") || word.hasSuffix("\u{2019}s") { word = String(word.dropLast(2)) }
            if let key = relationshipKey[word] {
                keys.insert(key)
            } else if word.hasSuffix("s"), let key = relationshipKey[String(word.dropLast())] {
                keys.insert(key)
            }
        }
        return keys
    }
}
