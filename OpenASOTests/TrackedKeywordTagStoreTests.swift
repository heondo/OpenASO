import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct TrackedKeywordTagStoreTests {
    @Test
    func normalizationTrimsCollapsesDedupesAndPreservesOrder() {
        #expect(KeywordTagNormalization.normalized([
            "  v2.0.2 ",
            "brand\tterm",
            "",
            "   ",
            "V2.0.2",
            "v3.0-3.1"
        ]) == ["v2.0.2", "brand term", "v3.0-3.1"])
    }

    @Test
    func normalizationDropsSeparatorCarryingAndOverlongTags() {
        let overlong = String(repeating: "x", count: KeywordTagNormalization.maxTagLength + 1)
        let atLimit = String(repeating: "y", count: KeywordTagNormalization.maxTagLength)
        // Newlines are whitespace, so "a\nb" collapses to a legal "a b";
        // comma/semicolon tags cannot round-trip through CSV and are dropped.
        #expect(KeywordTagNormalization.normalized([
            "a,b",
            "a;b",
            "a\nb",
            overlong,
            atLimit
        ]) == ["a b", atLimit])
    }

    @Test
    func normalizationCapsListLength() {
        let raw = (1...30).map { "tag-\($0)" }
        let normalized = KeywordTagNormalization.normalized(raw)
        #expect(normalized.count == KeywordTagNormalization.maxTagsPerKeyword)
        #expect(normalized.first == "tag-1")
        #expect(normalized.last == "tag-\(KeywordTagNormalization.maxTagsPerKeyword)")
    }

    @Test
    func csvFieldRoundTripsAndSplitsBothDialects() {
        let tags = ["v2.0.2", "brand", "v3.0-3.1"]
        let joined = KeywordTagNormalization.joinCSVField(tags)
        #expect(joined == "v2.0.2;brand;v3.0-3.1")
        #expect(KeywordTagNormalization.normalized(
            KeywordTagNormalization.splitCSVField(joined)
        ) == tags)
        #expect(KeywordTagNormalization.splitCSVField("a, b;c ,,;") == ["a", " b", "c ", ""].filter { !$0.isEmpty })
        #expect(KeywordTagNormalization.normalized(
            KeywordTagNormalization.splitCSVField("v2.0.2, brand , V2.0.2")
        ) == ["v2.0.2", "brand"])
    }

    @Test
    func setTagsInsertsReplacesAndClearRemovesRecord() throws {
        let fixture = try makeFixture()

        let applied = try TrackedKeywordTagStore.setTags(
            [" v2.0.2 ", "brand"],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            in: fixture.modelContext
        )
        #expect(applied == ["v2.0.2", "brand"])
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ) == ["v2.0.2", "brand"])

        let replaced = try TrackedKeywordTagStore.setTags(
            ["v3.0-3.1"],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            in: fixture.modelContext
        )
        #expect(replaced == ["v3.0-3.1"])
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ) == ["v3.0-3.1"])
        #expect(try fixture.modelContext.fetch(
            FetchDescriptor<TrackedKeywordTagRecord>()
        ).count == 1)

        let cleared = try TrackedKeywordTagStore.setTags(
            [],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            in: fixture.modelContext
        )
        #expect(cleared.isEmpty)
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ).isEmpty)
        #expect(try fixture.modelContext.fetch(
            FetchDescriptor<TrackedKeywordTagRecord>()
        ).isEmpty)
    }

    @Test
    func olderWriteCannotReplaceNewerTags() throws {
        let fixture = try makeFixture()
        _ = try TrackedKeywordTagStore.setTags(
            ["newer"],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 5_000),
            in: fixture.modelContext
        )

        let applied = try TrackedKeywordTagStore.setTags(
            ["older"],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 4_000),
            in: fixture.modelContext
        )
        #expect(applied == ["newer"])
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ) == ["newer"])
    }

    @Test
    func staleGenerationRecordIsIgnoredAndOverwritten() throws {
        let fixture = try makeFixture()
        fixture.modelContext.insert(TrackedKeywordTagRecord(
            trackIdentityKey: fixture.track.identityKey,
            trackCreatedAt: fixture.track.createdAt.addingTimeInterval(-1_000),
            appStoreID: fixture.track.appStoreID,
            tags: ["stale-generation"],
            updatedAt: Date(timeIntervalSince1970: 9_000)
        ))
        try fixture.modelContext.save()

        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ).isEmpty)

        // The stale record's newer timestamp must not block the current
        // generation's write, and the write compacts it away.
        let applied = try TrackedKeywordTagStore.setTags(
            ["fresh"],
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            in: fixture.modelContext
        )
        #expect(applied == ["fresh"])
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ) == ["fresh"])
        let records = try fixture.modelContext.fetch(
            FetchDescriptor<TrackedKeywordTagRecord>()
        )
        #expect(records.count == 1)
        #expect(records.first?.tags == ["fresh"])
    }

    @Test
    func concurrentContextContendersResolveToNewestRecord() throws {
        let fixture = try makeFixture()
        let identityKey = fixture.track.identityKey
        let createdAt = fixture.track.createdAt

        for (timestamp, tags) in [(1_000, ["first"]), (2_000, ["second"])] {
            fixture.modelContext.insert(TrackedKeywordTagRecord(
                trackIdentityKey: identityKey,
                trackCreatedAt: createdAt,
                appStoreID: fixture.track.appStoreID,
                tags: tags,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
            ))
        }
        try fixture.modelContext.save()

        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ) == ["second"])
    }

    @Test
    func bulkMapCoversOnlyTaggedTracks() throws {
        let fixture = try makeFixture()
        let secondTrack = try makeTrack(
            term: "second keyword",
            trackedApp: fixture.trackedApp,
            in: fixture.modelContext
        )
        let thirdTrack = try makeTrack(
            term: "third keyword",
            trackedApp: fixture.trackedApp,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["v2.0.2"],
            for: fixture.track,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["brand"],
            for: secondTrack,
            in: fixture.modelContext
        )

        let map = try TrackedKeywordTagStore.tagsByIdentityKey(
            for: [fixture.track, secondTrack, thirdTrack],
            in: fixture.modelContext
        )
        #expect(map == [
            fixture.track.identityKey: ["v2.0.2"],
            secondTrack.identityKey: ["brand"]
        ])
    }

    @Test
    func distinctTagsDedupesCaseInsensitivelyAndSorts() throws {
        let fixture = try makeFixture()
        let secondTrack = try makeTrack(
            term: "second keyword",
            trackedApp: fixture.trackedApp,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["v2.0.2", "Brand"],
            for: fixture.track,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["brand", "alpha"],
            for: secondTrack,
            in: fixture.modelContext
        )

        let distinct = try TrackedKeywordTagStore.distinctTags(
            forAppStoreID: fixture.trackedApp.appStoreID,
            in: fixture.modelContext
        )
        #expect(distinct.count == 3)
        #expect(distinct.map { $0.lowercased() } == ["alpha", "brand", "v2.0.2"])
        #expect(try TrackedKeywordTagStore.distinctTags(
            forAppStoreID: 999_999,
            in: fixture.modelContext
        ).isEmpty)
    }

    @Test
    func deleteTagsRemovesAllRecordsForIdentityKeys() throws {
        let fixture = try makeFixture()
        let secondTrack = try makeTrack(
            term: "second keyword",
            trackedApp: fixture.trackedApp,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["v2.0.2"],
            for: fixture.track,
            in: fixture.modelContext
        )
        _ = try TrackedKeywordTagStore.setTags(
            ["brand"],
            for: secondTrack,
            in: fixture.modelContext
        )

        try TrackedKeywordTagStore.deleteTags(
            for: [fixture.track.identityKey],
            in: fixture.modelContext
        )
        #expect(try TrackedKeywordTagStore.tags(
            for: fixture.track,
            in: fixture.modelContext
        ).isEmpty)
        #expect(try TrackedKeywordTagStore.tags(
            for: secondTrack,
            in: fixture.modelContext
        ) == ["brand"])
    }

    @Test
    func persistentRoundTripSurvivesReopen() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-TagStore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let modelContext = ModelContext(container)
            let trackedApp = TrackedApp(
                appStoreID: 123,
                bundleID: "com.example.app",
                name: "Example",
                sellerName: "Example",
                defaultPlatform: .iphone
            )
            modelContext.insert(trackedApp)
            let track = try makeTrack(
                term: "focus app",
                trackedApp: trackedApp,
                in: modelContext
            )
            _ = try TrackedKeywordTagStore.setTags(
                ["v2.0.2", "brand"],
                for: track,
                in: modelContext
            )
            try modelContext.save()
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let modelContext = ModelContext(container)
            let track = try #require(modelContext.fetch(
                FetchDescriptor<TrackedAppKeyword>()
            ).first)
            #expect(try TrackedKeywordTagStore.tags(
                for: track,
                in: modelContext
            ) == ["v2.0.2", "brand"])
        }
    }

    private struct TagFixture {
        let container: ModelContainer
        let modelContext: ModelContext
        let trackedApp: TrackedApp
        let track: TrackedAppKeyword
    }

    private func makeFixture() throws -> TagFixture {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 123,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        modelContext.insert(trackedApp)
        let track = try makeTrack(
            term: "focus app",
            trackedApp: trackedApp,
            in: modelContext
        )
        return TagFixture(
            container: container,
            modelContext: modelContext,
            trackedApp: trackedApp,
            track: track
        )
    }

    private func makeTrack(
        term: String,
        trackedApp: TrackedApp,
        in modelContext: ModelContext
    ) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(
            term: term,
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: term,
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        try modelContext.save()
        return track
    }
}
