OpenASO automatic refresh investigation and implementation plan

Investigation date: 2026-09-20. Target: Cadence, App Store ID 6761003558.

This investigation used repository source, the existing uncommitted diff, and the supplied runtime evidence. No app, refresh, build, test, or MCP server was run. Only this plan was written. All implementation steps below are future work and must preserve the existing uncommitted changes.

1. Pipeline and exact explanation of the recorded result

- `OpenASO/App/OpenASOApp.swift`, `init()` and `runBackgroundRefreshAndExit()`: `--daily-refresh-once` suppresses application UI, schedules `BackgroundRefreshRuntime.runOnce()` on the main actor, and pumps `RunLoop.main` until that task calls `exit`.
- `OpenASO/App/BackgroundRefreshRuntime.swift`, `runOnce()` / `runClaimedRefresh()`: take `daily-refresh.lock`, evaluate and persist the daily claim, open SwiftData, construct `AppServices`, prepare its background model store, run the headless refresh, and persist its summary. The lock in `OpenASO/Utilities/CrossProcessFileLock.swift`, `attempt()`, uses `LOCK_EX | LOCK_NB`; contention returns 0 without waiting.
- `OpenASO/Services/AnalyticsService.swift`, `AppSettingsStore.evaluateAndClaimAutomaticRefresh()`, and `OpenASO/Services/Persistence/DailyRefreshScheduler.swift`, `DailyRefreshDuePolicy.evaluate()`: `dailyRefresh.timeMinutes = 300` means **05:00 local time once per calendar day**, not a five-hour cadence. The claim is saved before opening the database or reading credentials. A disabled, not-yet-due, or already-claimed run exits 0 without provider work. Thus yesterday's fast exit does not prove yesterday's refresh worked.
- `OpenASO/Resources/OpenASORefreshAgent.plist.template`: launchd checks at load and at minute zero of each hour. The in-app scheduler is a fallback; `OpenASO/App/RootView.swift` does not start it when the agent reports enabled.
- `OpenASO/App/AppServices.swift`, headless dependency construction: obtain configured popularity app ID, recover the stored Apple Ads session if a transient read previously failed, snapshot App Store Connect credentials, and call `DailyRefreshPlanLoader.load(configuration:)`.
- `OpenASO/Services/Persistence/DailyRefreshPlanLoader.swift`: fetch tracked apps, validate app/keyword ownership and identities, deduplicate/order apps, and snapshot requests. Detail storefronts are tracked storefronts, otherwise the default or one fallback. Metadata includes the canonical/default storefront plus tracked storefronts. Keyword and metrics refresh default to enabled; ratings/reviews depend on the day's claim. An invalid plan would produce a planning failure, not this completed single-app partial result.
- `OpenASO/Services/AppDetail/HeadlessRefreshService.swift`, `HeadlessRefreshService.run()` and `HeadlessRefreshAppAdapter.refresh()`: process apps sequentially; for each app refresh metadata first, then detail. Ordinary metadata exceptions become `.failed`; ordinary detail exceptions become a nil detail result. Cancellation follows a separate path.
- `OpenASO/Services/Storefront/AppMetadataRefreshService.swift`: each storefront requires both iTunes lookup and App Store web fetch/validation/persistence for full success. One successful provider and one failed provider is already partial. No persisted providers means failed.
- `OpenASO/Services/AppDetail/AppDetailRefreshService.swift`, `performRefresh()`: run the keyword branch concurrently with ratings/reviews. The keyword branch refreshes/persists rankings, then stale popularity metrics; metrics have a seven-day freshness policy. Reviews use App Store Connect when credentials and bundle ID are complete; an app-not-found result falls back to public storefront reviews. `firstRefreshError()` combines keyword, metrics, rating, and review errors.

The decisive reduction is `HeadlessRefreshAppResultAdapter.map()` / `detailDisposition(for:request:)`:

| Metadata stage | Detail stage | App disposition |
| --- | --- | --- |
| Success | Success | success |
| Failure | Failure | failure |
| Any other combination, including either partial stage | | partialFailure |

Detail is successful when `firstError == nil` and requested ratings/reviews are not missing. Otherwise it is partial if any keyword/rating/review outcome has no error, and failed if none does. A cancelled detail result produces cancellation instead.

`HeadlessRefreshService.finish()` counts returned app results, not successful stages. One `.partialFailure` result therefore gives exactly planned=1, completed=1, successful=0, partial=1, failed=0. `completedDisposition()` returns run-level partial failure whenever there is a partial result, unless every app fully failed. `HeadlessRefreshIssue(kind: .appRefreshFailed)` supplies the exact generic message in the evidence. `BackgroundRefreshRunRecord` persists those facts; `DailyRefreshRunStatusPresentation` displays them without recalculating success.

The counters are consistent. The confirmed diagnostic defect is loss of the reason: the adapter drops detailed metadata outcomes and caught errors, and the persisted record keeps only the generic issue. The existing record cannot identify which Cadence provider/storefront failed. The same record can also be written by the GUI fallback through `AppServices.recordHeadlessRefreshCompletion()`; its key name does not establish that launchd produced it.

2. Most likely causes, with confidence limits

**Partial refresh: Apple Ads session expiry or stale cookie state is the leading hypothesis, not a proven incident diagnosis.** In the HEAD implementation preceding the uncommitted edits, `KeywordMetricsService.refreshMetricsBatch()` records `.appleAdsSessionExpired` in `batchErrors`, and `AppDetailRefreshService.refreshKeywords()` uses `failureCount` / `firstErrorMessage`. Successful rankings plus that metrics error produce partial detail, then a partial app even when metadata succeeds. A previously marked reconnect requirement can reproduce it without another Apple Ads HTTP request.

`AppleAdsCMPopularityClient.keywordPopularitiesBatch()` and `appleAdsWebJSONResponse()` in `AppleAdsWebSession.swift` also explain why HTTP 200 is insufficient: sign-in HTML/final sign-in URLs are treated as session expiry; JSON error/status fields and decoding can fail after transport succeeds. Other providers can likewise fail parsing or persistence after HTTP 200. `ObservedHTTPClient` in `RefreshObservability.swift` records transport success before provider parsing and does not establish refresh success.

The older source replays a flat stored Cookie/XSRF snapshot without the new explicit rotation handling. The working tree already contains a shared `AppleAdsCookieJar`, response-cookie ingestion/persistence, modern `app-ads.sid` support, and persistent WebKit login storage. It also already changes detail refresh to `operationalFailureCount` / `firstOperationalErrorMessage`, treating session expiry as advisory. These edits must not be recreated or reversed. With these edits active, expiry alone should no longer generate this partial result; metadata, another metrics error, rankings, ratings, reviews, or persistence must also fail to do so.

The GUI started before the stated on-disk binary build time. The live GUI, installed binary, HEAD, and working tree cannot be assumed equivalent. The build's precise source revision is not established. Treat the older expiry behavior as a source-supported explanation pending stage diagnostics, not proof that this exact binary contains it.

**Silent one-shot wait: a due invocation entering work with no overall deadline is the strongest explanation supported by source.** `runClaimedRefresh()` awaits setup and the entire refresh indefinitely; `runBackgroundRefreshAndExit()` exits only after it returns. Normal/skipped/partial runs print nothing to stdout, and ordinary stage errors do not go through `writeError`. Silence therefore does not distinguish active work from a blocked operation.

The leading blocking candidates are:

- Synchronous database open or Keychain access during setup. `AppServices.init()` eagerly creates credential stores; `SystemKeychainService.readData()` calls `SecItemCopyMatching`, may migrate a legacy item through synchronous writes, and supplies no explicit noninteractive policy. A locked Keychain or changed executable access requirement can wait despite the items existing. This is a candidate, not evidence that credentials are absent. The supplied `keychain.containsItem.*` keys are presence markers, not measurements of a successful read by this particular process.
- A slow provider/persistence stage once work starts. `ProviderRequestGate.perform()` / `dispatch()` bound retries but do not impose a wall-clock deadline on `base.data(for:)` or the initial pacing wait. Individual request timeouts do not bound all storefronts, batches, writes, and concurrent branches. SwiftData transactions are synchronous. Repeated 200s may reflect continuing work; the supplied logs do not identify a blocked phase or even tie every response to this invocation.

There is no automatic call to `AppleAdsWebSessionManager.refreshSession()` or `AppleAdsWebLoginController.captureSession()` in this pipeline; the refreshSession caller is Settings. Do not blame its five-minute interactive login wait or add background browser login as the fix. No source evidence proves a main-run-loop deadlock. Lock contention is not an indefinite wait. App Store Connect review pagination already stops on no new review IDs, so repeated identical pages alone are not evidence of an infinite pagination loop.

**Exit 78 is separate.** `BackgroundRefreshRuntime` returns only 0 or 1; partial failure returns 0. Launchd's 78 cannot be attributed to this summary or interpreted here as a missing-credential code. A stale registration, bundle/executable configuration, launch rejection, or another installed executable remains possible. `BackgroundRefreshAgentController.reconcile()` only compares version/build when already enabled, and the GUI fallback only checks that enabled status. Registration health and successful execution are different facts.

3. Required implementation changes

Implement against the current working tree, keeping its existing Apple Ads behavior. The priorities are retaining the actual cause, completing session handling, and making the one-shot process bounded and observable.

**A. Preserve stage failures and advisory outcomes through persistence.**

- In `OpenASO/Services/AppDetail/HeadlessRefreshService.swift`, introduce a bounded, Codable diagnostic value carrying appStoreID, stage, provider, optional storefront, severity, and a stable reason code. Use safe fixed messages; do not persist request bodies, cookie/header values, tokens, credentials, raw HTML, or arbitrary provider error text.
- Change `HeadlessRefreshAppAdapter.refresh()` and `HeadlessRefreshAppResultAdapter.map()` to retain full metadata outcomes and normalized thrown-stage errors. Carry diagnostics through `HeadlessRefreshAppExecutionResult` and `HeadlessRefreshRunSummary`. Preserve the existing disposition matrix and counter meanings.
- In `OpenASO/Services/AppDetail/AppDetailRefreshService.swift`, extend `AppDetailRefreshResult` with explicit metrics diagnostics instead of losing everything except `firstError`. In `refreshKeywords()`, preserve the existing operational-error projection and carry `.appleAdsSessionExpired` separately as a reconnect advisory with skipped counts. Preserve real provider/decoding/persistence failures as failures. Ensure advisory-only expiry cannot mask an independent failure.
- In `OpenASO/Services/AnalyticsService.swift`, extend `BackgroundRefreshRunRecord` with optional runID, execution origin (GUI/one-shot), build identity, and bounded diagnostics. Decode old records with missing new fields. Keep old generic `issueMessage` as a fallback.
- In `OpenASO/Features/Settings/DailyRefreshRunStatusView.swift`, show the failed stage/provider/storefront and a separate reconnect/skipped-popularity advisory when applicable. A success under the existing operational policy must not imply skipped popularity was fetched. Keep the app counts unchanged.
- In `OpenASO/Services/Networking/RefreshObservability.swift` and `OpenASO/Services/AppDetail/HeadlessRefreshObservationRecorder.swift`, correlate detail observations with the parent headless run and app. Log metadata outcomes as well as detail stages; metadata currently executes outside the detail observation scope. Keep transport results distinct from semantic provider/stage results. Give plan/app start/finish events useful redacted output; they currently return nil from `HeadlessRefreshEvent.redactedLogMessage`.

**B. Complete and validate the session work already present.**

- Retain the current changes in `AppleAdsWebSession.swift`, `AppleAdsWebLoginController.swift`, `AppleAdsPastedSession.swift`, `KeywordMetricsService.swift`, and the new `AppleAdsCookieJar.swift`, including matching tests. Do not add interactive reconnect to automatic refresh or discard cached popularity on expiry.
- In `AppleAdsCookieJar.swift`, `URLRequest.applyAppleAdsSession(_:jar:)`, remove fallback to the old session header when an initialized jar has become empty because of expiry/deletion. Resolve the XSRF header from an unexpired cookie applicable to the request URL; clear it when absent instead of resurrecting `session.xsrfToken`. Legacy sessions are already seeded through `jarCookies` at store load/save. An authoritative jar must remain authoritative after deletions.
- In `AppleAdsWebSession.swift`, `AppleAdsWebSession.refreshed(with:)`, allow an empty snapshot to clear cookies/header/token; the current early return preserves deleted credentials. Clear XSRF when its cookie is removed. Preserve connection identity and the reconnect flag during rotation persistence.
- In `KeywordMetricsService.fetchPopularityMetrics()` and `refreshMetricsBatch()`, flush rotated/deleted cookies on error and cancellation as well as success. Use explicit async cleanup on every exit after provider work; preserve the original error/cancellation. The present trailing flush can be skipped by a throw. Keep UI/keychain interactions bounded by the background policy below.
- These close concrete gaps in the existing diff; they do not prove cookie deletion caused the September 19 incident. Persistent WebKit storage and rotation also cannot guarantee that Apple will never expire a session.

**C. Add a testable background service factory and noninteractive Keychain policy.**

- In `OpenASO/App/AppServices.swift`, add `backgroundRefresh(...)` accepting defaults, namespace, keychain, HTTP client, and model container. In `BackgroundRefreshRuntime.runClaimedRefresh()`, use it instead of `appLaunch(modelContainer:)`. The current factory silently drops the runtime's injected defaults/namespace; its XCTest branch also substitutes unrelated preview defaults, hiding this mismatch in runtime tests.
- In `OpenASO/Services/Credentials/KeychainService.swift`, add an explicit interaction policy. The background factory must use a noninteractive policy for protected and legacy reads and writes, including migration and cookie persistence. Apply the platform-supported fail-without-authentication-UI query/context option and return typed OSStatus failures; preserve items and presence markers on transient failures. Keep interactive GUI behavior unchanged. Inject Security operations so tests never use the real login Keychain.
- In `OpenASO/App/OpenASOApp.swift` and `OpenASO/Services/Updates/SparkleUpdaterController.swift`, defer updater startup until graphical execution mode is selected. The eager state initializer currently starts Sparkle before command-line routing. This removes unrelated startup work; it is not a claim that Sparkle caused the observed hang.

**D. Bound the one-shot lifetime and expose where it waits.**

- In `BackgroundRefreshRuntime.swift`, add injectable diagnostic sink, service/setup operations, and clock/deadline policy. Emit a redacted start record before claim/setup and paired phase records around database open, service/credential initialization, model-store preparation, planning, and app stages. Include run ID, origin/build, counts and durations. Emit explicit `notDue`, `alreadyClaimed`, `lockUnavailable`, terminal disposition, and exit code. Mirror these to stderr for one-shot execution and unified logging for launchd.
- Add a configurable one-shot budget, initially 15 minutes, with cooperative cancellation at deadline and a 10-second cleanup grace period. Cancel the owning refresh task, preserve already committed stage work, record a timeout diagnostic when the runtime can still finish, and exit nonzero. Keep timeout distinct from user cancellation in diagnostics. Retain the existing 0/1 mapping for normal dispositions, including partial failure, unless a separate product decision changes it.
- In `OpenASOApp.runBackgroundRefreshAndExit()`, install a process-level watchdog on an independent dispatch queue before starting the main-actor runtime. After budget plus grace, write the last safe phase and terminate nonzero even if Keychain/SwiftData or an async dependency ignores cancellation. Inject timer/termination behavior for tests. The watchdog is only for the one-shot process, never the GUI. Do not implement the sole timeout as a throwing task-group race: group scope still waits for an uncooperative child.
- Persist a small active-attempt record after acquiring the lock, with run ID, claim and last phase, separate from the last completed summary. Clear it on normal completion. On a later lock acquisition, recognize a leftover attempt as interrupted without fabricating successful/completed app counts. Preserve the daily claim to avoid uncontrolled repeated retries; do not reset defaults to force another run. The watchdog must not depend on the blocked main actor or database to terminate.
- Keep nonblocking file-lock behavior. Ensure cancellation releases the detail queue permit, and process termination releases the OS file lock. Retain the existing run loop until a deterministic test demonstrates a dispatch problem; changing it speculatively does not fix blocked dependencies.

**E. Separate launch-agent validation from refresh correctness.**

- Keep the template's bundle-relative `BundleProgram` and hourly check unless installed-artifact inspection finds a mismatch. Extend validation associated with `script/generate_refresh_agent_plist.sh` to check the expanded label, executable path existence/executability, and exactly one `--daily-refresh-once` argument, in addition to plist syntax.
- In `BackgroundRefreshAgentController.reconcile()`, add redacted registration diagnostics including app location and version/build. Keep its existing update re-registration behavior; do not introduce automatic unregister/register loops based on a refresh partial result.
- For eventual deployment, increment the build and restart the GUI from the same installed bundle used by the agent. Read launchd's recorded executable/configuration and launch-error logs to identify the 78 before changing registration logic. A process reporting version/build/origin in every run will make future mismatches visible. These are later deployment checks, not actions performed during this investigation.

4. Tests to add or update

Use mocks, isolated defaults/namespaces, in-memory SwiftData, fake clocks, and fake Keychain operations. Never invoke the installed binary or production refresh from these regression tests.

| Test file | Required assertions |
| --- | --- |
| `OpenASOTests/HeadlessRefreshServiceTests.swift` | Add a single-app Cadence fixture reproducing exactly 1/1/0/1/0 for metadata success plus operational metrics failure. Test metadata partial plus successful detail; both stages failing; both succeeding. Extend `appAdapterReducesEveryMetadataAndDetailStatusCombination` and ordinary-throw tests to verify diagnostic retention without changing dispositions. |
| `OpenASOTests/RefreshObservabilityTests.swift` | Extend `appDetailMetricsExpiryIsNotAnOperationalFailureAndKeepsRankingOutcomes` through the headless adapter: expiry only yields operational success plus an advisory; adding a metadata/review failure still yields partial. Verify parent run correlation and that HTTP 200 HTML/JSON failures have semantic diagnostics despite transport success. |
| `OpenASOTests/KeywordMetricsServiceTests.swift` | Retain expiry/cache-preservation tests and `expiredSessionIsAnAdvisoryForInteractiveRefreshAndAnErrorForMCP`. Add response rotation followed by a later batch error/cancellation; persistence must occur without swallowing the original error. Test 200 JSON error, malformed JSON, missing keyword popularity, and reconnect short-circuit separately. |
| `OpenASOTests/AppleAdsCookieJarTests.swift` | Add deletion of the last auth cookie and XSRF cookie, expired/path-inapplicable XSRF, empty-jar serialization/reload, and no fallback to the original Cookie header. Retain next-request rotation and restart tests. |
| `OpenASOTests/BackgroundRefreshInfrastructureTests.swift` | Replace reliance on the preview factory in `oneShotRuntimeClaimsRunsAndCoalescesTheDay` with injected dependencies. Test disabled/not-due/already-claimed/lock-busy without service construction, and no-work after loading an empty plan. Verify correct defaults/namespace propagation, terminal logging and exact exit mapping, noninteractive Keychain query policy, and transient failure preserving stored items. Fake deadline tests must cover cooperative cancellation and an uncooperative dependency triggering the independent watchdog exactly once; release test continuations afterward. Test active-attempt recovery and claim preservation. |
| `OpenASOTests/HeadlessRefreshObservationTests.swift` | Assert live and persisted stage messages/advisories, bounded/redacted log output, and unchanged counter text. |
| `OpenASOTests/AnalyticsServiceTests.swift` | Decode the old persisted record with no new fields, round-trip new diagnostics/provenance, and keep active/interrupted attempts separate from completed results. |
| `OpenASOTests/DailyRefreshSchedulerTests.swift` | Retain once-per-day and DST coverage; explicitly verify 300 means 05:00 and an already-claimed day performs no provider work. |
| `OpenASOTests/AppServicesDependencyTests.swift` | Verify the background factory uses supplied dependencies, never starts interactive Apple Ads login, and does not substitute production or preview defaults. |

After implementation, run the following command; it was **not run** during this investigation:

```sh
xcodebuild test \
  -project OpenASO.xcodeproj \
  -scheme OpenASO \
  -destination 'platform=macOS' \
  -only-testing:OpenASOTests/HeadlessRefreshServiceTests \
  -only-testing:OpenASOTests/RefreshObservabilityTests \
  -only-testing:OpenASOTests/KeywordMetricsServiceTests \
  -only-testing:OpenASOTests/AppleAdsCookieJarTests \
  -only-testing:OpenASOTests/AppleAdsPastedSessionTests \
  -only-testing:OpenASOTests/BackgroundRefreshInfrastructureTests \
  -only-testing:OpenASOTests/HeadlessRefreshObservationTests \
  -only-testing:OpenASOTests/AnalyticsServiceTests \
  -only-testing:OpenASOTests/DailyRefreshSchedulerTests \
  -only-testing:OpenASOTests/AppServicesDependencyTests
```

Acceptance requires truthful stage diagnostics for the exact partial-count fixture, preserved cached data and visible reconnect advice on expiry, a bounded one-shot exit even when a dependency stalls, and no source/test changes lost from the pre-existing working tree. The actual September 19 failing stage and the current blocked stack remain unproven by the supplied aggregate evidence; this plan deliberately does not present either hypothesis as an observed fact.
