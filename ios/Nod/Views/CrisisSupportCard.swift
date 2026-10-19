// CrisisSupportCard.swift
// A fixed card that appears under a message that clearly signals crisis
// (wanting to die, self-harm). The listening prompt also tells the model
// to point toward real help, but a small model can miss or fumble that;
// this card doesn't depend on the model.
//
// Detection is a plain on-device phrase match — nothing is sent anywhere.
// It's deliberately broad: an occasional card after "this commute makes
// me want to die" costs little; missing a real one costs a lot.

import SwiftUI

enum CrisisSupport {

    /// Phrases matched case-insensitively (curly apostrophes normalized).
    private static let phrases = [
        "kill myself", "killing myself", "end my life", "ending my life",
        "take my own life", "taking my own life", "suicide", "suicidal",
        "want to die", "wanna die", "want to be dead",
        "don't want to be alive", "dont want to be alive",
        "don't want to live", "dont want to live", "no reason to live",
        "better off without me", "better off dead",
        "hurt myself", "hurting myself", "self harm", "self-harm",
        "cut myself", "cutting myself", "overdose",
    ]

    static func isCrisis(_ text: String) -> Bool {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return phrases.contains { normalized.contains($0) }
    }

    struct Resource {
        let name: String
        let call: String?
        let text: String?
    }

    /// A free, confidential line for the user's region, if we know one.
    static func resource(for region: String?) -> Resource? {
        switch region {
        case "US": return Resource(name: "988 Suicide & Crisis Lifeline", call: "988", text: "988")
        case "CA": return Resource(name: "9-8-8 Suicide Crisis Helpline", call: "988", text: "988")
        case "GB", "IE": return Resource(name: "Samaritans", call: "116123", text: nil)
        case "AU": return Resource(name: "Lifeline", call: "131114", text: nil)
        case "NZ": return Resource(name: "Need to Talk? 1737", call: "1737", text: "1737")
        case "IN": return Resource(name: "Tele-MANAS", call: "14416", text: nil)
        default: return nil
        }
    }

    static let directoryURL = URL(string: "https://findahelpline.com")!
}

struct CrisisSupportCard: View {
    @Environment(\.openURL) private var openURL
    private let resource = CrisisSupport.resource(for: Locale.current.region?.identifier)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("If you're thinking about ending your life or hurting yourself, please talk to someone now.")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let resource {
                Text("\(resource.name) is free and confidential, any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let number = resource.call, let url = URL(string: "tel:\(number)") {
                        Button("Call \(number)") { openURL(url) }
                            .buttonStyle(.borderedProminent)
                            // Black on NodAccent, like every other
                            // filled orange button (white is ~3:1).
                            .foregroundStyle(.black)
                    }
                    if let number = resource.text, let url = URL(string: "sms:\(number)") {
                        Button("Text \(number)") { openURL(url) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Button(resource == nil ? "Find a helpline near you" : "Other helplines") {
                openURL(CrisisSupport.directoryURL)
            }
            .font(.subheadline)
        }
        .tint(Color("NodAccent"))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    CrisisSupportCard().padding()
}
