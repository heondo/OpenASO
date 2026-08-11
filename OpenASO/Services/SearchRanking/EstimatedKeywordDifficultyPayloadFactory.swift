import Foundation

/// Item 20c: adapts `KeywordDifficultyEstimator` output and ranking-provider
/// context into the branch-independent persistence payload.
enum EstimatedKeywordDifficultyPayloadFactory {
    static func makePayload(
        estimation: KeywordDifficultyEstimation,
        queryKey: String,
        keyword: String,
        storefront: String,
        platform: AppPlatform,
        requestedResultLimit: Int,
        providerResultCount: Int,
        rankingSource: RankingSource,
        rankingFetchedAt: Date,
        computedAt: Date,
        fallbackContext: SearchRankingFailureContext?
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let result: EstimatedKeywordDifficultyPersistenceResult
        let algorithmIdentifier: String
        let algorithmVersion: Int
        let evidence: KeywordDifficultyEvidence
        let notes: [String]
        switch estimation {
        case .estimated(let estimated):
            result = .estimated(
                score: estimated.score,
                confidenceScore: estimated.confidenceScore,
                confidence: confidence(estimated.confidence)
            )
            algorithmIdentifier = estimated.algorithmIdentifier
            algorithmVersion = estimated.algorithmVersion
            evidence = estimated.evidence
            notes = estimated.notes
        case .unavailable(let unavailable):
            result = .unavailable(reason: unavailableReason(unavailable.reason))
            algorithmIdentifier = unavailable.algorithmIdentifier
            algorithmVersion = unavailable.algorithmVersion
            evidence = unavailable.evidence
            notes = unavailable.notes
        }

        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: queryKey,
            keyword: keyword,
            storefront: storefront,
            platform: platform,
            result: result,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            requestedResultLimit: requestedResultLimit,
            providerResultCount: providerResultCount,
            evidence: persistenceEvidence(evidence),
            rankingSource: rankingSource,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: computedAt,
            fallback: fallbackProvenance(rankingSource: rankingSource, context: fallbackContext),
            notes: notes
        )
    }

    /// The store forbids fallback provenance unless the page came from the
    /// iTunes fallback, and requires it when it did. A fallback page without a
    /// context (bare provider in tests or synthetic pages) gets a synthesized
    /// `.other` provenance instead of failing validation.
    static func fallbackProvenance(
        rankingSource: RankingSource,
        context: SearchRankingFailureContext?
    ) -> EstimatedKeywordDifficultyFallbackProvenance? {
        guard rankingSource == .iTunesFallback else { return nil }
        guard let context else {
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .other
            )
        }

        switch context.category {
        case .transport(let code):
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .transport,
                transportCode: code
            )
        case .httpStatus(let status):
            guard (100 ... 599).contains(status) else {
                return EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .other
                )
            }
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .httpStatus,
                httpStatus: status
            )
        case .response(let failure):
            guard let mappedFailure = responseFailure(failure) else {
                return EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .provider
                )
            }
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .response,
                responseFailure: mappedFailure
            )
        case .provider:
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .provider
            )
        case .other:
            return EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .other
            )
        }
    }

    private static func confidence(
        _ value: EstimatedKeywordDifficulty.Confidence
    ) -> EstimatedKeywordDifficultyConfidence {
        switch value {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    private static func unavailableReason(
        _ value: KeywordDifficultyUnavailable.Reason
    ) -> EstimatedKeywordDifficultyUnavailableReason {
        switch value {
        case .emptyKeyword: return .emptyKeyword
        case .insufficientResults: return .insufficientResults
        case .insufficientRatingEvidence: return .insufficientRatingEvidence
        }
    }

    private static func persistenceEvidence(
        _ evidence: KeywordDifficultyEvidence
    ) -> EstimatedKeywordDifficultyEvidence {
        EstimatedKeywordDifficultyEvidence(
            consideredResultCount: evidence.consideredResultCount,
            ratedResultCount: evidence.ratedResultCount,
            weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage,
            maximumRatingCount: evidence.maximumRatingCount,
            medianRatingCount: evidence.medianRatingCount,
            ratingAuthorityScore: evidence.ratingAuthorityScore,
            metadataSaturationScore: evidence.metadataSaturationScore,
            resultEvidence: evidence.resultEvidence.map(persistenceResultEvidence)
        )
    }

    private static func persistenceResultEvidence(
        _ result: KeywordDifficultyResultEvidence
    ) -> EstimatedKeywordDifficultyResultEvidence {
        EstimatedKeywordDifficultyResultEvidence(
            position: result.position,
            appStoreID: result.appStoreID,
            title: result.title,
            subtitle: result.subtitle,
            ratingCount: result.ratingCount,
            ratingAuthorityScore: result.ratingAuthorityScore,
            titleTokenCoveragePercentage: result.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: result.combinedTokenCoveragePercentage,
            metadataMatchScore: result.metadataMatchScore,
            exactTitlePhraseMatch: result.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: result.exactSubtitlePhraseMatch
        )
    }

    /// The persistence enum intentionally omits `lookupHydrationIncomplete`;
    /// callers map an unmappable failure to the `.provider` category.
    private static func responseFailure(
        _ failure: SearchRankingResponseFailure
    ) -> EstimatedKeywordDifficultyFallbackResponseFailure? {
        switch failure {
        case .serializedServerDataMissing: return .serializedServerDataMissing
        case .decodingFailed: return .decodingFailed
        case .nonHTTPResponse: return .nonHTTPResponse
        case .requestIntentMissing: return .requestIntentMissing
        case .requestIntentAmbiguous: return .requestIntentAmbiguous
        case .pageShapeChanged: return .pageShapeChanged
        case .authoritativeShelfMissing: return .authoritativeShelfMissing
        case .authoritativeShelfAmbiguous: return .authoritativeShelfAmbiguous
        case .malformedSearchResult: return .malformedSearchResult
        case .truncatedResults: return .truncatedResults
        case .lookupHydrationIncomplete: return nil
        }
    }
}
