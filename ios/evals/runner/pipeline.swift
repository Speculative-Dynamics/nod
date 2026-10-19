// pipeline.swift — plays a conversation the way ConversationStore does:
// verbatim recent turns, chapter notes when older turns age out, recall
// of the user's past messages, then a streamed reply. Shared by the
// listening and memory suites.

import Foundation

struct PipelineConversation {
    // Same thresholds as ConversationStore.CompressionPolicy.roomy.
    static let highWaterMark = 20
    static let batchSize = 12

    let listeningPrompt: String
    let chapterPrompt: String
    let personalization: String
    /// Optional context a case starts from (a chapter note, past messages).
    let seedChapter: String
    let seedPastMessages: [String]

    var history: [Message] = []
    var memory = ConversationMemory()
    var modelCalls = 0
    /// Simulated time: each turn happens a few hours after the last, so
    /// recalled messages carry realistic "yesterday" / "3 days ago" labels.
    var clock = Date().addingTimeInterval(-7 * 24 * 3600)
    let step: TimeInterval = 3 * 3600

    struct Turn {
        let raw: String
        let shown: String
        let error: String?
        let seconds: Double
        let memoryContext: String
    }

    init(listeningPrompt: String, chapterPrompt: String, personalization: String = "",
         seedChapter: String = "", seedPastMessages: [String] = []) {
        self.listeningPrompt = listeningPrompt
        self.chapterPrompt = chapterPrompt
        self.personalization = personalization
        self.seedChapter = seedChapter
        self.seedPastMessages = seedPastMessages
    }

    mutating func send(_ userText: String, maxTokens: Int = 300, temperature: Double?) async -> Turn {
        await compressIfNeeded()

        var context = memory.context(
            for: userText,
            personalization: personalization,
            verbatimSince: history.first?.createdAt,
            now: clock
        )
        if memory.chapters.isEmpty, !seedChapter.isEmpty || !seedPastMessages.isEmpty {
            context = ListeningTurns.contextBlock(
                personalization: personalization,
                latestChapter: seedChapter,
                olderChapters: [],
                pastMessages: seedPastMessages
            )
        }

        let start = Date()
        var raw = ""
        var errorText: String?
        do {
            for try await snapshot in replyStream(
                prompt: listeningPrompt, context: context, history: history,
                userMessage: userText, maxTokens: maxTokens, temperature: temperature,
                samplingMode: samplingMode
            ) { raw = snapshot }
        } catch {
            errorText = String(describing: error)
        }
        modelCalls += 1
        let shown = ReplyGuard.clean(raw, phrases: bannedPhrases, keepIfEmpty: true)

        let user = Message(role: .user, text: userText, createdAt: clock)
        history.append(user)
        memory.addUserMessage(id: user.id, text: userText, date: clock)
        history.append(Message(
            role: .assistant,
            text: errorText == nil ? shown : "Nod couldn't reply this time.",
            isError: errorText != nil,
            createdAt: clock.addingTimeInterval(5)
        ))
        clock = clock.addingTimeInterval(step)

        let memoryOnly = context.replacingOccurrences(of: personalization, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Turn(raw: raw, shown: shown, error: errorText,
                    seconds: Date().timeIntervalSince(start), memoryContext: memoryOnly)
    }

    private mutating func compressIfNeeded() async {
        guard history.count >= Self.highWaterMark else { return }
        let oldest = Array(history.prefix(Self.batchSize))
        let conversational = oldest.filter { !$0.isError }
        modelCalls += 1
        if let note = try? await writeChapterNote(prompt: chapterPrompt, messages: conversational),
           let chapter = ConversationMemory.makeChapter(note: note, covering: conversational, now: clock) {
            memory.addChapter(chapter)
        }
        history.removeFirst(Self.batchSize)
    }
}
