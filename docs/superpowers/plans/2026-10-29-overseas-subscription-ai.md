# Overseas subscription and assistant Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for primary implementation; one bounded child audits/reviews server/payment work. Preserve the user's one-child and whole-machine heavy-work limits.

**Goal:** Deliver the authorized draggable orb, continuous breathing,300-second actual proactive speech, initial English and real subscription access.

**Architecture:** Keep UIKit/SnapKit and the existing offline renderer. Separate scene layout and speech scheduling from rendering; use StoreKit2 and Apple's official server library for payments, with a server business-access gate rather than a local Boolean.

**Tech Stack:** Swift/UIKit/SnapKit/SPM, AVFoundation, StoreKit2; Spring Boot/Security/MyBatis/Flyway/Java21; existing Three/esbuild offline bundle.

**Spec:** `../../design-rag/contracts/overseas-subscription-r1.md` and the workspace product change document it cites.

## Global Constraints

- iOS15.0 minimum; ten existing languages; preserve stored language and scoped data.
- Only the requested assistant and same-grade monthly/yearly subscription scope; no unverified model/points/UGC/OCR restoration.
- First ordinary speech no earlier than300 seconds; cancel stale account/language/access work and do not build missed-speech queues.
- No heavy work while sustained yellow pressure or another heavy owner is active. Targeted checks only; never repeat D06/G17/G24 audits or full suites.
- Confirmed: USD9.99/month, USD99.99/year, USD base; excludeCN/HK/MO/TW and target every other currently supported storefront. Actual products/price points/agreements/formal service/review identity remain separate external facts.
- No deployment, DNS, certificate mutation, review submission or publication is inferred.

## Review Focus

- A drag ending over the button must not trigger chat; an edge/window/keyboard change must not strand the orb or clip the bubble.
- Playback/lifecycle resets must not bypass300 seconds or play a stale account/language utterance.
- Animation wrap/pause must not jump visible values or velocity, including the diffusion ring.
- Unknown entitlement/network failure must not become an unsolicited new purchase, a global TEST grant or an unbounded offline pass.
- Original Apple transaction chains and appAccountToken must prevent cross-account binding; rights/legal/restore routes must remain usable without business access.

## Task1: Initial English without overwriting preferences

Files: `QiafanYoupu/Features/Profile/QFSettingsView.swift`, current app/session language consumers, `QiafanYoupuTests/QFInitialLanguageTests.swift`.

- [ ] Write isolated UserDefaults cases for no value, every saved supported language, scoped isolation and unchanged stored bytes.
- [ ] Run only that selected test class after the resource gate; record actual RED.
- [ ] Change only missing-preference defaults to en and preserve valid saved values.
- [ ] Verify the selected cases and affected language contracts; commit separately.

## Task2: Native orb placement and tap/drag separation

Files: `QiafanYoupu/Features/Assistant/QFAssistantOrbLayout.swift` (new), `QFDigitalAssistant.swift`, `QiafanYoupuTests/QFAssistantOrbLayoutTests.swift` (new).

Interfaces: `QFAssistantOrbLayout` owns bounded center/normalized-position and bubble frame decisions; the overlay applies those decisions using SnapKit. No server position state.

- [ ] Add boundary cases at320/390 widths, asymmetric safe insets, keyboard/window shrink, left/right bubble and restored relative position; add native tap/pan arbitration cases.
- [ ] Record selected RED when runnable; implement native UIPanGestureRecognizer, layout-change callback and bounded bubble placement.
- [ ] Verify passthrough, gesture cancellation, access-keyboard-scene cleanup and the new RAG baseline; commit separately.

## Task3: Continuous authored orb and synchronized offline runtime

Files: `Packages/QFOrbRenderer/WebSource/orb.js`, a focused pure breathing helper if needed, existing `scripts/build_assistant_orb.py`, authored/bundle/runtime manifests and a Node behavioral test.

- [ ] Add numerical wrap checks at0/3.4 and both sides of the wrap, first derivatives, ring visibility/opacity and paused/resumed phase.
- [ ] Observe a behavioral RED against the old cycle, then replace wrap-discontinuous formulas with periodic/smooth visible contributions.
- [ ] Rebuild with the existing verified esbuild0.28.2 only when the heavy gate permits; verify input/output hashes and selected tests; commit authored source and runtime together.

## Task4: Actual proactive speech and cancellation

Files: assistant scheduling/speech component (new), `QFDigitalAssistant.swift`, settings row/ten-language resources, related tests and app scene wiring.

Interfaces: a clock-injectable300-second scheduling policy; an AVSpeechSynthesizer owner bound to account/language/access/scene; overlay receives the exact spoken text.

- [ ] Test299.999/300/300.001 boundaries, tab/foreground re-entry, cancellation, interruption and no missed-greeting queue.
- [ ] Add real same-language speech, an accessible local opt-out, current audio/form/chat/purchase exclusion and lifecycle cancellation.
- [ ] Remove Debug five-second rotation from the formal path. Connect Release overlay only behind actual business access from Task5; no unguarded temporary Release bypass.
- [ ] Run selected policy/integration checks; separately record actual audible/native-Duo checks, never infer them from mocks; commit the component.

## Task5: Real StoreKit and authoritative business access

Files: current membership/session/root controllers and API models; new StoreKit coordinator; server membership verification/access/notification components and migrations; explicit Security business authorization policy and focused tests.

- [ ] Finalize audited endpoint/DTO/migration signatures in the ledger before either side implements them. Keep existing dirty server files/preimages isolated.
- [ ] Implement server-issued purchase context/appAccountToken, official signed-data verification, original-chain account binding, idempotent sync/notifications and refund/expiry/grace handling; expose only the configured real monthly/yearly product IDs.
- [ ] Implement StoreKit product-localized price/period, verified purchase/restore/currentEntitlements/updates and finish-after-server-acceptance; pending/cancelled/failed/unavailable are explicit states.
- [ ] Implement access states unknown/active/none/expired/revoked; a same-account verified snapshot may allow at most15 minutes in the same process, never beyond expiry/known revocation. A new process without a verified snapshot requires a clear verification path, not another purchase prompt.
- [ ] Gate protected business APIs and App/deep-link routing. Keep legal/support, purchase/restore/manage, login switching and lawful data/deletion access reachable.
- [ ] Targeted RED/GREEN with isolated fixtures, followed by actual Apple sandbox evidence only when real products/configuration exist. No TEST benefit is a purchase proof.

## Task6: Store/review configuration after exact human facts

- [ ] Incorporate exact excluded territories, overseas prices/base currency and real product identifiers; match App and product lists and read back full counts/lists on existing6827145246.
- [ ] Prepare truthful same-grade benefits, English store/legal/support text and usable disclosed review-access instructions. Do not fabricate credentials or assume Apple demo approval.
- [ ] Retain download Free, future-expansionoff, Mac/Visionoff, manual release and pending submission. No review/publication action.

## Execution ledger

Ruling: preserve the existing feature checkout and the user's continuous autonomous execution. The approved change delegates routine implementation choices to development; no duplicate design-approval round is inserted. Final user acceptance remains required.

Ruling: use platform UIPanGestureRecognizer/AVSpeechSynthesizer/StoreKit mechanisms with thin business adaptation; do not add a floating-widget or speech SDK. Official UIKit/AVFoundation documents were actually searched on2026-10-29; Apple payment SDK audit is separate.

Ruling: optional orb position persistence is deferred; preserve relative position within each live scene, avoiding cross-scene/account storage collisions. Cost: restarting a scene returns the orb to the established default position.

Ruling:15-minute same-process offline access is a conservative implementation choice, not a user-provided number; server gating remains authoritative online. Cost: a refunded offline session can retain cached/local access for that bounded interval; a fresh process may require connectivity.

2026-10-29: initial iOS checkout clean at8d5d7c8. Original human change independently verified. No source implementation or new tests have been declared complete. Memory pressure2 and a peer's sustained-yellow report prohibit new heavy work; lightweight source/test preparation continues. No new browser/simulator/service has been created.

2026-10-29 light progress: S01 source+5tests andS02 source+10tests prepared, native runs deferred. S03 actual boundedNode RED3fail/1pass thenGREEN4/4; runtime sync pending. S04 actualsystem-synth/controller+11policy/preferences/content tests prepared, business-root integration still pending. Locale check initially failed64 orphaned entries, exact retiredDebug keys removed, thenPASS1503strings/8localizations. No native/voice/Duo/payment proof inferred.

Ruling: user requireslight implementation while sustainedyellow prohibitsheavy checks. Swift tests are written beforeimplementation but nativeRED/GREEN hasnotrun; allsuchcode remainsunverifiedWIP, notcompleted. Only boundedNode numerical execution(~50ms,32MiBheap,noGPU/build) andscopedPythonchecks run. Registration/bundle/native/servervalidation coalescesafterresource recovery; nofullsuite override ofuserlimits.

2026-10-29 payment interface frozen: retainGETme/membership withV2fields; POSTapple/purchase-context returnsList<String>productIds/String?group/UUIDtoken; POSTapple/transactions acceptsJWS; exactPOSTstore/apple/notifications acceptsAppleV2JWS. Required40303,conflict40904,unavailable50300(nofinish). Scope/source/env andsigneddates preserveAppleSandbox/Production distinction. Serverpreimages saved; V64 addsdirectmembership/erasure migrationtestscope, notoldproofrelabeling.


2026-10-29 continuation: native StoreKit purchase/currentEntitlements/unfinished/
updates/restore, same-account queue, memory-only gate, entry cover and legal/
support/account/history paths now have uncompiled source preparation. Added
8 delivery-order/receipt-fencing cases and2 legal-link cases plus1 scoped
diagnostic persistence case; earlier33 native cases remain unrun. Existing
native models are still excluded fromRelease. Split common orb/reminder/speech
from the excluded chat file; formal assistant displays delivered scope and
speech preference. XcodeGen metadata-only registration ran in0.052s and found
all13 new source/test files; no package resolve/build/test was invoked.

Actual locale validation nowPASS1515strings/8extra localizations after retiring
old free/TEST/cloud-credit benefit copy. Payment sync refined to transaction-
specific acceptedTransaction; aggregate environment may differ and per-chain
revision must not be treated as global account order. Peer's exact source
review identified these issues before native verification; fixes remain WIP.

Only the prior boundedNode4/4 numeric result, locale validation, metadata
registration and scoped whitespace/source checks have execution evidence.
NativeAVSpeech/gesture/StoreKit, rendererbundle, Java/Maven/MySQL/serverAPI,
actualASCproducts/territories/agreements/reviewidentity/finalpackage remain
unverified. Do not commit a completion claim or label source preparation as
paid sandbox/production readiness.

2026-10-29 final light-stage snapshot:50native methods nowprepared/unrun;17newserverunit and12membershipMySQLcases prepared/unrun. ACTIVEServerleaseclamp applies toalllocal access,GRACEcounts cacheage,continuousclock includesdevice sleep,knownsame-accountrevocationinvalidatesbeforequeue. ProductcatalogrequiresAppleFamilySharingoff becauseapphouseholdsharing isdistinct; actualASCfacts stillpending. Sourcepeerreview foundnoadditionalconfirmedblocker afterreportedfixes; thisisnotcompileacceptance. NewS05/S06evidence andcheckpoint retainWIP. Persistentpressure2keepsallheavyverificationqueued.


2026-10-29 executed validation and remaining handoff:
- Orb runtime rebuilt with integrity-verified lockedesbuild0.28.2. Authored/bundle/
  runtime manifests match; runtime547903bytes. Temporarydownloadedbinaryremoved.
- Actual native52distinct methodsPASS: original50 plus only2newJavaInstant wire
  cases. iOS26.3.1arm64/Xcode27.1;0fail/0skip. FinalDebugbuild-for-testingPASS after
  making entrySignout visible. The52cases were not rerun for thatpresentation-only
  change. Actualaudio, physicalpan/VoiceOver/Duo andApplepurchase remain separate.
- Compile-only formal-sourcebranch probePASS: Debugconfig with actualRelease
  exclusions, noSwiftDEBUGflag,38definedCoreAssistant symbols. It is not actual
  Release/signing/distribution. Sourceface/pose declarations were moved back to
  legacychat excludedfromRelease. TaskprivateprobeDerivedDatadeletedafterproof;
  sharedoriginalDerivedData/SourcePackagesretained. RealReleasepreflightFAILS
  becauseformalproductionHTTPSAPIisunset; noplaceholderaddresswasused.
- Actual server60distinct scoped casesPASS:17newunit,12membershipMySQL,7erasure,
  1migration46to63to64,23existingcontracts;0fail/error/skip. PrivateMySQL8.4.11/V64
  fixturesreleased. OfficialSDK5.2.0 declaredOkHTTP4.12.0 runtime; exposing its
  types required sameversionexplicitcompile declaration. NoactualAppleJWS/OCSP/
  Sandboxpayment proofisclaimed. Originaldirtyserverbaselinepreserved; exact
  32-filepatchisreviewableinrootS05-server-delta-20261029.patch.
- ThreepublicAppleCArootsdownloadedfromofficialPKIandmetadata/validitychecked
  intasktmp. Theyarepreparedinputs,notruntimeconfigurationorprivateIAPkeys.
- S06 reachedmetadata-onlyexistingApp6827145246page inownChrome4033. DOMreads
  timedout; nativeinventoryreportedMaclocked. No productcreationornewprice/
  territorysaveattempted. Owntabclosedandabsenceverified; Filevia/ECSsharedpages
  preserved. Awaitactualmanualunlockbeforeoneboundedread-onlycontinuation.
- Source commits separate renderer from the integratedentry/assistant contract;
  nativeSPMprojectregistration and businessgate/sharedsettings requirecoherent
  entry integration. Productconfiguration, actualstorelistandoperator/legal/
  service/review/sandbox/finalcandidate facts remain incomplete.
