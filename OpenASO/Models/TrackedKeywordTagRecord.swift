import Foundation
import SwiftData

/// Independently persisted free-form tag list per tracked keyword.
///
/// `TrackedAppKeyword` is frozen in the V1 schema, so tags live in a side
/// record keyed by the track identity, following `TrackedKeywordRefreshStatus`:
/// each write inserts a fresh record and compacts older ones, concurrent
/// contexts may temporarily leave contenders, and readers deterministically
/// choose the newest record for the track's current `createdAt` generation so
/// a re-added keyword never resurrects tags from a deleted predecessor.
@Model
final class TrackedKeywordTagRecord {
    #Index<TrackedKeywordTagRecord>(
        [\.trackIdentityKey],
        [\.appStoreID]
    )

    @Attribute(.unique) var tagKey: String
    var trackIdentityKey: String
    var trackCreatedAt: Date
    var appStoreID: Int64
    var tags: [String]
    var updatedAt: Date

    init(
        trackIdentityKey: String,
        trackCreatedAt: Date,
        appStoreID: Int64,
        tags: [String],
        updatedAt: Date
    ) {
        self.tagKey = Self.makeTagKey(trackIdentityKey: trackIdentityKey)
        self.trackIdentityKey = trackIdentityKey
        self.trackCreatedAt = trackCreatedAt
        self.appStoreID = appStoreID
        self.tags = tags
        self.updatedAt = updatedAt
    }

    static func makeTagKey(trackIdentityKey: String) -> String {
        [
            trackIdentityKey,
            "tags",
            UUID().uuidString.lowercased()
        ].joined(separator: "::")
    }
}

/// Single source of tag normalization shared by the editor UI, CSV
/// import/export, and the MCP tool surface.
enum KeywordTagNormalization {
    static let maxTagsPerKeyword = 20
    static let maxTagLength = 60

    /// Characters that can never appear inside a tag: they are the CSV list
    /// separators, so a tag containing them could not round-trip.
    static func containsDisallowedCharacters(_ raw: String) -> Bool {
        raw.contains(",") || raw.contains(";") || raw.contains(where: \.isNewline)
    }

    /// Trims and collapses interior whitespace runs; empty results become nil.
    static func normalizedTag(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Lenient list normalization: normalizes each tag, drops empties,
    /// separator-carrying, and overlong tags, dedupes case-insensitively with
    /// the first occurrence's casing winning, preserves order, and caps the
    /// list length. Surfaces that should reject bad input instead of dropping
    /// it (MCP) validate the raw values before calling this.
    static func normalized(_ raw: [String]) -> [String] {
        var seenLowercased = Set<String>()
        var result: [String] = []
        for rawTag in raw {
            guard result.count < maxTagsPerKeyword else { break }
            guard let tag = normalizedTag(rawTag),
                  tag.count <= maxTagLength,
                  !containsDisallowedCharacters(tag),
                  seenLowercased.insert(tag.lowercased()).inserted
            else { continue }
            result.append(tag)
        }
        return result
    }

    /// Canonical CSV export form; semicolons need no quoting in this CSV
    /// dialect and match Astro's list convention.
    static func joinCSVField(_ tags: [String]) -> String {
        tags.joined(separator: ";")
    }

    /// Lenient CSV import: accepts either semicolon- or comma-separated lists.
    static func splitCSVField(_ field: String) -> [String] {
        field.split { $0 == ";" || $0 == "," }.map(String.init)
    }
}

enum TrackedKeywordTagStore {
    static func tags(
        for track: TrackedAppKeyword,
        in modelContext: ModelContext
    ) throws -> [String] {
        try tagsByIdentityKey(for: [track], in: modelContext)[track.identityKey] ?? []
    }

    static func tagsByIdentityKey(
        for tracks: [TrackedAppKeyword],
        in modelContext: ModelContext
    ) throws -> [String: [String]] {
        let identityKeys = Array(Set(tracks.map(\.identityKey)))
        guard !identityKeys.isEmpty else { return [:] }

        let descriptor = FetchDescriptor<TrackedKeywordTagRecord>(
            predicate: #Predicate { record in
                identityKeys.contains(record.trackIdentityKey)
            }
        )
        return tagsByIdentityKey(from: try modelContext.fetch(descriptor), for: tracks)
    }

    /// Pure join for callers that already hold queried records (`@Query`).
    /// Records from another `createdAt` generation are treated as absent.
    static func tagsByIdentityKey(
        from records: [TrackedKeywordTagRecord],
        for tracks: [TrackedAppKeyword]
    ) -> [String: [String]] {
        tagsByIdentityKey(
            from: records,
            generations: tracks.map { (identityKey: $0.identityKey, createdAt: $0.createdAt) }
        )
    }

    static func tagsByIdentityKey(
        from records: [TrackedKeywordTagRecord],
        generations: [(identityKey: String, createdAt: Date)]
    ) -> [String: [String]] {
        let grouped = Dictionary(grouping: records, by: \.trackIdentityKey)
        var result: [String: [String]] = [:]
        for generation in generations {
            guard let record = latestRecord(
                in: grouped[generation.identityKey] ?? [],
                trackCreatedAt: generation.createdAt
            ) else { continue }
            let tags = KeywordTagNormalization.normalized(record.tags)
            guard !tags.isEmpty else { continue }
            result[generation.identityKey] = tags
        }
        return result
    }

    /// All tags used across an app's keywords, deduped case-insensitively and
    /// sorted for suggestion and filter UI. No generation guard: suggestions
    /// are cosmetic and stale records disappear on the next write or delete.
    static func distinctTags(
        forAppStoreID appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> [String] {
        let descriptor = FetchDescriptor<TrackedKeywordTagRecord>(
            predicate: #Predicate { record in
                record.appStoreID == appStoreID
            }
        )
        let latestByIdentityKey = Dictionary(
            grouping: try modelContext.fetch(descriptor),
            by: \.trackIdentityKey
        ).compactMapValues { records in
            latestRecord(in: records, trackCreatedAt: nil)
        }
        var seenLowercased = Set<String>()
        return latestByIdentityKey.values
            .flatMap { KeywordTagNormalization.normalized($0.tags) }
            .sorted { $0.lowercased() < $1.lowercased() }
            .filter { seenLowercased.insert($0.lowercased()).inserted }
    }

    /// Replace-set write: the given list becomes the track's complete tag list
    /// after normalization; an empty result deletes the record. Returns the
    /// applied list (the existing newer list when a newer write already won).
    @discardableResult
    static func setTags(
        _ tags: [String],
        for track: TrackedAppKeyword,
        updatedAt: Date = .now,
        in modelContext: ModelContext
    ) throws -> [String] {
        let normalizedTags = KeywordTagNormalization.normalized(tags)
        let trackIdentityKey = track.identityKey
        let descriptor = FetchDescriptor<TrackedKeywordTagRecord>(
            predicate: #Predicate { record in
                record.trackIdentityKey == trackIdentityKey
            }
        )
        let existingRecords = try modelContext.fetch(descriptor)
        if let latest = latestRecord(in: existingRecords, trackCreatedAt: track.createdAt),
           latest.updatedAt > updatedAt {
            return KeywordTagNormalization.normalized(latest.tags)
        }

        if !normalizedTags.isEmpty {
            modelContext.insert(TrackedKeywordTagRecord(
                trackIdentityKey: track.identityKey,
                trackCreatedAt: track.createdAt,
                appStoreID: track.appStoreID,
                tags: normalizedTags,
                updatedAt: updatedAt
            ))
        }
        for existing in existingRecords
        where existing.trackCreatedAt != track.createdAt || existing.updatedAt <= updatedAt {
            modelContext.delete(existing)
        }
        return normalizedTags
    }

    static func deleteTags(
        for trackIdentityKeys: [String],
        in modelContext: ModelContext
    ) throws {
        let identityKeys = Array(Set(trackIdentityKeys))
        guard !identityKeys.isEmpty else { return }

        let descriptor = FetchDescriptor<TrackedKeywordTagRecord>(
            predicate: #Predicate { record in
                identityKeys.contains(record.trackIdentityKey)
            }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
    }

    private static func latestRecord(
        in records: [TrackedKeywordTagRecord],
        trackCreatedAt: Date?
    ) -> TrackedKeywordTagRecord? {
        records
            .filter { record in
                trackCreatedAt.map { record.trackCreatedAt == $0 } ?? true
            }
            .max { left, right in
                if left.updatedAt != right.updatedAt {
                    return left.updatedAt < right.updatedAt
                }
                return left.tagKey < right.tagKey
            }
    }
}
