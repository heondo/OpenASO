import SwiftData
import SwiftUI

struct KeywordTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let track: TrackedAppKeyword

    @State private var workingTags: [String] = []
    @State private var suggestions: [String] = []
    @State private var input = ""
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.term)
                    .font(.title3.weight(.semibold))
                Text(track.storefront.uppercased())
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                if workingTags.isEmpty {
                    Text("No tags yet. Tag keywords freely — for example with the app versions they lived through, like v2.0.2 or v3.0-3.1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    KeywordTagFlowLayout {
                        ForEach(workingTags, id: \.self) { tag in
                            KeywordTagChip(tag: tag) {
                                workingTags.removeAll { $0 == tag }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField("Add a tag and press Return", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitInput)
                    .onChange(of: input) { _, newValue in
                        // Comma and semicolon are list separators everywhere
                        // tags round-trip; typing one commits the tag instead.
                        if newValue.contains(",") || newValue.contains(";") {
                            input = newValue.filter { $0 != "," && $0 != ";" }
                            commitInput()
                        }
                    }
                    .disabled(workingTags.count >= KeywordTagNormalization.maxTagsPerKeyword)

                if workingTags.count >= KeywordTagNormalization.maxTagsPerKeyword {
                    Text("A keyword can have up to \(KeywordTagNormalization.maxTagsPerKeyword) tags.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !availableSuggestions.isEmpty {
                    Text("Suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    KeywordTagFlowLayout {
                        ForEach(availableSuggestions, id: \.self) { suggestion in
                            Button {
                                append(suggestion)
                            } label: {
                                KeywordTagChip(tag: suggestion)
                            }
                            .buttonStyle(.plain)
                            .help("Add tag \(suggestion)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    _ = try? TrackedKeywordTagStore.setTags(
                        workingTags,
                        for: track,
                        in: modelContext
                    )
                    try? modelContext.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear(perform: load)
    }

    private var availableSuggestions: [String] {
        let applied = Set(workingTags.map { $0.lowercased() })
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suggestions.filter { suggestion in
            !applied.contains(suggestion.lowercased())
                && (query.isEmpty || suggestion.lowercased().contains(query))
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        workingTags = (try? TrackedKeywordTagStore.tags(for: track, in: modelContext)) ?? []
        suggestions = (try? TrackedKeywordTagStore.distinctTags(
            forAppStoreID: track.appStoreID,
            in: modelContext
        )) ?? []
    }

    private func commitInput() {
        append(input)
        input = ""
    }

    private func append(_ raw: String) {
        workingTags = KeywordTagNormalization.normalized(workingTags + [raw])
    }
}
