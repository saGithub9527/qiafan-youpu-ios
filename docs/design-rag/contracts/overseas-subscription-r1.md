# Overseas subscription and assistant overlay r1

2026-10-29. Authority: the direct human messages in product thread
`01a176a2-50a1-7370-b1f9-182e35b7e7d7`, turn
`01a18335-19d6-7cd3-84d6-09ac301b1116`, independently read by development.
The human confirmed Qiafan Youpu and actual proactive speech every five minutes.
The current product specification is
`docs/产品规划与上线/2026-10-28-海外订阅首发与AI圆球变更.md` in the workspace root.

This supersedes only the conflicting assistant/subscription/default-language/
storefront exclusions in first-release-core-r1 and the historical G24 CN+US goal.
Existing recipes, plans, ingredients and profile geometry remain authoritative.
No UGC, OCR, product lookup, model downloads, points packages or unverified
unlimited/cloud-model benefits are restored by this contract.

## Overlay and animation

Keep the existing orb, colors, chat route and 92 x 112 pt native button. First
placement retains trailing14 and bottom126 relative to the existing keyboard
guide. A native pan changes position, suppresses a tap after dragging, and is
confined to the current scene's safe/keyboard-visible bounds. Preserve a relative
position across safe-area, keyboard and window changes. Empty space passes
through. The greeting uses its own bounded placement, can change side, wraps
without clipping, and does not place an invisible full-screen hit target.
Device-local persistent position is optional; r1 keeps scene-local position.

The 3.4 second breathing cycle must have matching values and first derivatives
at its wrap for contraction, brightness and diffusion-ring presentation. A
transparent ring can reset radius only with zero visible contribution and zero
visible derivative. Pause preserves elapsed phase; resume does not reset it.
Keep reduce-motion and native fallback behavior. Bundle and both manifests must
match authored inputs before this component is declared complete.

## Proactive speech

Use AVSpeechSynthesizer, not Debug text rotation. The first ordinary utterance
waits at least300 seconds after business access becomes available. Re-entry,
tab changes and foreground transitions cannot reset/bypass the interval. Do not
queue missed greetings. Only speak in the active scene with business access,
the findable proactive-speech preference enabled, an available same-language
voice/content and no conflicting recording, speech, chat, form, purchase or
audio interruption. Cancel old work and audio on account/language/access/scene
changes. Preserve real meal reminder timing; do not invent plan/stock facts or
call a paid model for an ordinary greeting. Bubble text matches the utterance.

## Language, subscription and review

With no saved preference, use en; retain every existing valid saved preference
and all ten supported languages/Accept-Language behavior. Do not silently speak
an old/different language if the current voice or content is unavailable.

After consent/login, resolve same-account server-authoritative subscription
access. Unknown/unreachable is not unsubscribed and must offer verification
retry without implying another purchase. Restore/manage, legal/support,
account switching and data/deletion rights remain reachable. Do not remove
history/drafts when access expires. Same-grade monthly/yearly products expose
only delivered core/cloud/household/orb-speech capabilities. The human confirmed
USD9.99/month and USD99.99/year, with USD as base currency. Show Apple's actual
localized prices elsewhere, with no invented trial/discount or product IDs.
Implement StoreKit purchase/restore/update and server Apple
verification, account binding, original-chain idempotency and revocation.
Keep TEST grants separate from verified Apple subscription access.

Use a disclosed usable review identity where the existing login system permits
one; otherwise record that limitation. Preserve normal sandbox purchase review.
No public arbitrary skip, reviewer-IP/device/date switch or hidden paywall.
No assertion that Apple has approved an embedded demo mode.

The human confirmed exclusions CN/HK/MO/TW; all other currently supported
storefronts are targets. These facts were independently read in product turn
`01a18344-43f8-7271-94e5-789ff71bd165`. Prices/territories are no longer a missing
human answer; actual products/price points/agreements remain separately verified
facts. App download may remain Free. App and product territories must match. Future
expansion stays off, Mac/Vision stay off and manual final release stays on.

Source/static checks are not actual audible playback, native Duo acceptance,
Apple sandbox transactions, store configuration, production eligibility or
final release evidence. Record those separately.


## Implementation boundary recorded on 2026-10-29

The existing Release target excludes the legacy chat/model file. Extract only
the native orb/meal-reminder/system-speech overlay into
QFAssistantOrbOverlay.swift and restore its renderer/meal snapshot direct
sources. Keep the legacy cloud chat/model/download files excluded. Debug keeps
its existing conversation route. The formal assistant entry explains the
currently delivered cooking/speech scope and offers the same proactive-speech
switch; it must not promise cloud chat as a paid benefit.

The entry gate covers an existing navigation/form stack when access expires,
preserving that stack in memory. No deep link or notification may route through
a denied business gate. Account logout can clear its old scene as before.

Transaction sync keeps the flat original/V2 membership fields and adds
acceptedTransaction only after a committed same-account transaction is
confirmed. Its id/original id/bundle/verified Apple environment must match the
local verified StoreKit transaction before finish. Aggregate Apple environment
can differ from the accepted transaction when the same account has multiple
chains. UNKNOWN/NONE/missing receipt, verification error or account change do
not finish. A chain revision is not an account-wide ordering counter; serialize
requests and fence account/access generations instead.
