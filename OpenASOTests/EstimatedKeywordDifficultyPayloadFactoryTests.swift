import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyPayloadFactoryTests {
    @Test
    func estimatedBranchMapsFieldForField() throws {
        let items = ratedItems(count: 5, ratingCount: 12_000)
        let estimation = KeywordDifficultyEstimator.estimate(
            keyword: "habit tracker",
            searchResults: items
        )
        guard case .estimated(let estimate) = estimation else {
            throw FactoryTestError.expectedEstimate
        }

        let payload = makePayload(estimation: estimation, keyword: "habit tracker")

        #expect(payload.result == .estimated(
            score: estimate.score,
            confidenceScore: estimate.confidenceScore,
            confidence: mappedConfidence(estimate.confidence)
        ))
        #expect(payload.algorithmIdentifier == KeywordDifficultyEstimator.algorithmIdentifier)
        #expect(payload.algorithmVersion == KeywordDifficultyEstimator.algorithmVersion)
        #expect(payload.notes == estimate.notes)
        #expect(payload.estimationSource == .topResultsHeuristic)
        #expect(payload.evidence.consideredResultCount == estimate.evidence.consideredResultCount)
        #expect(payload.evidence.ratedResultCount == estimate.evidence.ratedResultCount)
        #expect(
            payload.evidence.weightedRatingCoveragePercentage
                == estimate.evidence.weightedRatingCoveragePercentage
        )
        #expect(payload.evidence.maximumRatingCount == estimate.evidence.maximumRatingCount)
        #expect(payload.evidence.medianRatingCount == estimate.evidence.medianRatingCount)
        #expect(payload.evidence.ratingAuthorityScore == estimate.evidence.ratingAuthorityScore)
        #expect(
            payload.evidence.metadataSaturationScore == estimate.evidence.metadataSaturationScore
        )
        #expect(payload.evidence.resultEvidence.count == estimate.evidence.resultEvidence.count)
        for (mapped, source) in zip(
            payload.evidence.resultEvidence,
            estimate.evidence.resultEvidence
        ) {
            #expect(mapped.position == source.position)
            #expect(mapped.appStoreID == source.appStoreID)
            #expect(mapped.title == source.title)
            #expect(mapped.subtitle == source.subtitle)
            #expect(mapped.ratingCount == source.ratingCount)
            #expect(mapped.ratingAuthorityScore == source.ratingAuthorityScore)
            #expect(mapped.titleTokenCoveragePercentage == source.titleTokenCoveragePercentage)
            #expect(
                mapped.combinedTokenCoveragePercentage == source.combinedTokenCoveragePercentage
            )
            #expect(mapped.metadataMatchScore == source.metadataMatchScore)
            #expect(mapped.exactTitlePhraseMatch == source.exactTitlePhraseMatch)
            #expect(mapped.exactSubtitlePhraseMatch == source.exactSubtitlePhraseMatch)
        }
    }

    @Test(arguments: [
        (2, KeywordDifficultyUnavailable.Reason.insufficientResults),
        (5, KeywordDifficultyUnavailable.Reason.insufficientRatingEvidence)
    ])
    func unavailableBranchMapsReason(
        resultCount: Int,
        expectedReason: KeywordDifficultyUnavailable.Reason
    ) throws {
        let items = (1 ... resultCount).map { position in
            item(position: position, ratingCount: expectedReason == .insufficientResults ? 10 : nil)
        }
        let estimation = KeywordDifficultyEstimator.estimate(
            keyword: "habit tracker",
            searchResults: items
        )
        guard case .unavailable(let unavailable) = estimation else {
            throw FactoryTestError.expectedUnavailable
        }
        #expect(unavailable.reason == expectedReason)

        let payload = makePayload(estimation: estimation, keyword: "habit tracker")
        #expect(payload.result == .unavailable(reason: mappedReason(expectedReason)))
        #expect(payload.notes == unavailable.notes)
    }

    @Test
    func emptyKeywordMapsToEmptyKeywordReason() throws {
        let estimation = KeywordDifficultyEstimator.estimate(
            keyword: "  ",
            searchResults: ratedItems(count: 4, ratingCount: 50)
        )
        let payload = makePayload(estimation: estimation, keyword: "")
        #expect(payload.result == .unavailable(reason: .emptyKeyword))
    }

    @Test
    func primarySourceDropsFallbackContext() {
        let provenance = EstimatedKeywordDifficultyPayloadFactory.fallbackProvenance(
            rankingSource: .appStoreWeb,
            context: SearchRankingFailureContext(provider: .appStoreWeb, category: .other)
        )
        #expect(provenance == nil)
    }

    @Test
    func fallbackSourceWithoutContextSynthesizesOtherProvenance() {
        let provenance = EstimatedKeywordDifficultyPayloadFactory.fallbackProvenance(
            rankingSource: .iTunesFallback,
            context: nil
        )
        #expect(provenance == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .other
        ))
    }

    @Test
    func fallbackCategoryMapping() {
        func provenance(
            _ category: SearchRankingFailureCategory
        ) -> EstimatedKeywordDifficultyFallbackProvenance? {
            EstimatedKeywordDifficultyPayloadFactory.fallbackProvenance(
                rankingSource: .iTunesFallback,
                context: SearchRankingFailureContext(provider: .appStoreWeb, category: category)
            )
        }

        #expect(provenance(.transport(code: -1_001)) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .transport,
            transportCode: -1_001
        ))
        #expect(provenance(.transport(code: nil)) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .transport
        ))
        #expect(provenance(.httpStatus(503)) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .httpStatus,
            httpStatus: 503
        ))
        #expect(provenance(.httpStatus(0)) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .other
        ))
        #expect(provenance(.provider) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .provider
        ))
        #expect(provenance(.other) == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .other
        ))
    }

    @Test
    func responseFailuresMapOneToOneExceptLookupHydration() {
        let mappings: [(SearchRankingResponseFailure, EstimatedKeywordDifficultyFallbackResponseFailure)] = [
            (.serializedServerDataMissing, .serializedServerDataMissing),
            (.decodingFailed, .decodingFailed),
            (.nonHTTPResponse, .nonHTTPResponse),
            (.requestIntentMissing, .requestIntentMissing),
            (.requestIntentAmbiguous, .requestIntentAmbiguous),
            (.pageShapeChanged, .pageShapeChanged),
            (.authoritativeShelfMissing, .authoritativeShelfMissing),
            (.authoritativeShelfAmbiguous, .authoritativeShelfAmbiguous),
            (.malformedSearchResult, .malformedSearchResult),
            (.truncatedResults, .truncatedResults)
        ]
        for (source, expected) in mappings {
            let provenance = EstimatedKeywordDifficultyPayloadFactory.fallbackProvenance(
                rankingSource: .iTunesFallback,
                context: SearchRankingFailureContext(
                    provider: .appStoreWeb,
                    category: .response(source)
                )
            )
            #expect(provenance == EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .response,
                responseFailure: expected
            ))
        }

        let hydration = EstimatedKeywordDifficultyPayloadFactory.fallbackProvenance(
            rankingSource: .iTunesFallback,
            context: SearchRankingFailureContext(
                provider: .appStoreWeb,
                category: .response(.lookupHydrationIncomplete)
            )
        )
        #expect(hydration == EstimatedKeywordDifficultyFallbackProvenance(
            provider: .appStoreWeb,
            category: .provider
        ))
    }

    /// Every factory-produced payload must pass the store's validation; this
    /// pins the factory against validation drift in either branch.
    @Test(arguments: [
        FactoryRoundTripCase.estimated,
        FactoryRoundTripCase.insufficientResults,
        FactoryRoundTripCase.insufficientRatingEvidence,
        FactoryRoundTripCase.fallbackWithContext,
        FactoryRoundTripCase.fallbackWithoutContext
    ])
    func factoryPayloadsPassStoreValidation(_ roundTripCase: FactoryRoundTripCase) throws {
        let items: [SearchRankingItem]
        let rankingSource: RankingSource
        let fallbackContext: SearchRankingFailureContext?
        switch roundTripCase {
        case .estimated:
            items = ratedItems(count: 6, ratingCount: 4_500)
            rankingSource = .appStoreWeb
            fallbackContext = nil
        case .insufficientResults:
            items = ratedItems(count: 2, ratingCount: 10)
            rankingSource = .appStoreWeb
            fallbackContext = nil
        case .insufficientRatingEvidence:
            items = (1 ... 5).map { item(position: $0, ratingCount: nil) }
            rankingSource = .appStoreWeb
            fallbackContext = nil
        case .fallbackWithContext:
            items = ratedItems(count: 6, ratingCount: 900)
            rankingSource = .iTunesFallback
            fallbackContext = SearchRankingFailureContext(
                provider: .appStoreWeb,
                category: .httpStatus(429)
            )
        case .fallbackWithoutContext:
            items = ratedItems(count: 6, ratingCount: 900)
            rankingSource = .iTunesFallback
            fallbackContext = nil
        }

        let payload = makePayload(
            estimation: KeywordDifficultyEstimator.estimate(
                keyword: "habit tracker",
                searchResults: items
            ),
            keyword: "habit tracker",
            providerResultCount: items.count,
            rankingSource: rankingSource,
            fallbackContext: fallbackContext
        )

        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let outcome = try EstimatedKeywordDifficultyStore.upsert(payload, in: context)
        #expect(outcome == .inserted)
    }
}

enum FactoryRoundTripCase: Sendable {
    case estimated
    case insufficientResults
    case insufficientRatingEvidence
    case fallbackWithContext
    case fallbackWithoutContext
}

private enum FactoryTestError: Error {
    case expectedEstimate
    case expectedUnavailable
}

private func makePayload(
    estimation: KeywordDifficultyEstimation,
    keyword: String,
    providerResultCount: Int = 25,
    rankingSource: RankingSource = .appStoreWeb,
    fallbackContext: SearchRankingFailureContext? = nil
) -> EstimatedKeywordDifficultyPersistencePayload {
    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    return EstimatedKeywordDifficultyPayloadFactory.makePayload(
        estimation: estimation,
        queryKey: KeywordQuery.makeQueryKey(term: keyword, storefront: "us", platform: .iphone),
        keyword: keyword,
        storefront: "us",
        platform: .iphone,
        requestedResultLimit: 200,
        providerResultCount: providerResultCount,
        rankingSource: rankingSource,
        rankingFetchedAt: fetchedAt,
        computedAt: fetchedAt.addingTimeInterval(1),
        fallbackContext: fallbackContext
    )
}

private func mappedConfidence(
    _ confidence: EstimatedKeywordDifficulty.Confidence
) -> EstimatedKeywordDifficultyConfidence {
    switch confidence {
    case .low: return .low
    case .medium: return .medium
    case .high: return .high
    }
}

private func mappedReason(
    _ reason: KeywordDifficultyUnavailable.Reason
) -> EstimatedKeywordDifficultyUnavailableReason {
    switch reason {
    case .emptyKeyword: return .emptyKeyword
    case .insufficientResults: return .insufficientResults
    case .insufficientRatingEvidence: return .insufficientRatingEvidence
    }
}

private func ratedItems(count: Int, ratingCount: Int) -> [SearchRankingItem] {
    (1 ... count).map { item(position: $0, ratingCount: ratingCount) }
}

private func item(position: Int, ratingCount: Int?) -> SearchRankingItem {
    SearchRankingItem(
        position: position,
        appStoreID: Int64(position),
        bundleID: nil,
        name: "Habit Tracker \(position)",
        subtitle: "Daily habit tracker",
        sellerName: nil,
        ratingCount: ratingCount
    )
}
