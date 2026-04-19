// SidebarView.swift
// The sidebar sheet triggered by tapping the Nod face in the nav bar.
//
// Per the "one continuous conversation" principle, there is no session
// list or history browser here. The sidebar is a lightweight menu for the
// few things you actually might want to do with your ongoing relationship
// with Nod: see a small stat, start over if you want, check the version.
//
// More settings can be added as rows in their own sections without
// restructuring anything.

import SwiftUI

struct SidebarView: View {

    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss

    /// Called after the user confirms "Start fresh." ChatView uses this to
    /// reset any local inference state (e.g. the isInferring thinking
    /// indicator) that isn't owned by the store itself.
    let onCleared: () -> Void

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Messages")
                        Spacer()
                        Text("\(store.messages.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Your conversation")
                }

                Section {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Start fresh", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Clears every message and Nod's memory of your conversation. This can't be undone.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Nod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Start fresh?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear Conversation", role: .destructive) {
                    Task {
                        await store.clear()
                        onCleared()
                        dismiss()
                    }
                }
            } message: {
                Text("This clears every message and Nod's memory of your conversation. It can't be undone.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return version
    }
}

#Preview {
    let db = try! MessageDatabase()
    let store = ConversationStore(database: db, summarizer: { nil })
    return SidebarView(store: store, onCleared: {})
        .preferredColorScheme(.dark)
}
