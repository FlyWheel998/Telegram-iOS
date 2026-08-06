# FINDINGS — Swiftgram iOS port

Distilled, evidence-backed findings. Superseded entries are marked, not deleted.
Local read/write clone (Windows, non-buildable): `C:\Users\Dream\Documents\Software\swiftgram-ios` — sparse checkout of `Swiftgram/`, `submodules/{TranslateUI,TelegramUI,ChatListUI,Display,AccountContext,TelegramCore,TextFormat}`, `Telegram/NotificationService`, `build-system`.

---

## F-001 — Swiftgram already provides an AyuGram-equivalent settings layer
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift` (665 lines, read locally)

Keys are a `enum Keys: String, CaseIterable`; values are `@UserDefault` property-wrapped, defaults registered via `setDefaultValues()` into two dictionaries (`defaultValues`, `groupDefaultValues`). Group-scoped settings use `UserDefaults(suiteName: APP_GROUP_IDENTIFIER)`.

**Implication:** direct analog of `ayu_settings.h`. Settings for the Notification Service Extension **must** be group-backed — the NSE is a separate process.

**Caveat (verified absence):** there is no change-observation mechanism — no `rpl::variable` equivalent, no KVO, no `@Published`. Desktop's `...Changes()` live-refresh streams have no free counterpart. `Swiftgram/SGChatListSimpleSettingsSignal` is the precedent for bridging a setting into a `SwiftSignalKit` signal.

---

## F-002 — Per-peer translation state already exists upstream; ~⅓ of F1 needs no porting
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `submodules/TranslateUI/Sources/ChatTranslation.swift` (411 lines)

`ChatTranslationState` carries `baseLang`, `fromLang`, `timestamp`, `toLang`, `isEnabled`, persisted in the engine item cache under `ApplicationSpecificItemCacheCollectionId.translationState`, keyed by peer ID (+ optional thread ID) as an `EngineDataBuffer`. Read via `chatTranslationState(context:peerId:threadId:)`; written via `updateChatTranslationState` / `updateChatTranslationStateInteractively`. Detection samples up to **16** messages through `NLLanguageRecognizer`, strips entities, requires ≥10 chars, takes the modal result; cache valid **1 hour**; checks an `ignoredLanguages` set.

**Implication:** the desktop `translation_peer_settings.json` store and the Always/Never/Default peer menu **do not need porting**. Extend the offer-decision branch; do not rebuild the store.

---

## F-003 — Translation backend is free and already force-enabled; no Premium needed
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `submodules/TranslateUI/Sources/Translate.swift` (549 lines)

Implements a Google endpoint (`translate.googleapis.com`) **and** Apple's on-device `TranslationSession` (iOS 18+). Two `// MARK: Swiftgram` overrides bypass Telegram's server gating: `chatTranslationAvailable || true` and `translateButtonAvailable = true`.

**Implication:** the desktop `messages.translateText` FLOOD_WAIT failure mode is gone, and Telegram Premium is not required.

---

## F-004 — Apple on-device translation does NOT cover Hebrew until iOS 27
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** Apple Translate supported-language list; 9to5Mac/Cult of Mac reporting on iOS 27's nine added languages (Hebrew among them)

Arabic and Russian are supported on iOS 26; Hebrew is not.

**Implication:** the user's primary use case (Hebrew news channels) must route through the Google endpoint, which has its own IP-based rate limiting. **The desktop throttling work still has to be ported** — visible-messages-first drain, ~350 ms inter-batch spacing (`kEagerRequestDelay`), queue cap of 300 (`kEagerQueueCap`) — just aimed at a different rate limiter. Revisit if/when the user is on iOS 27.

---

## F-005 — The message funnel is a single clean loop; messages are immutable
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `submodules/TelegramUI/Sources/ChatHistoryEntriesForView.swift` (855 lines)

One `loop: for entry in view.entries` with established `continue loop` skip conditions (pending-removed, forum `topicCreated`, `historyCleared`, view-once media). Postbox `Message` values are immutable.

**Implication:** better than AyuGram's `isMessageHidden` funnel. The footer stripper becomes a **pure function applied at consumption points**, not a mutation — which deletes three desktop bug classes for free (no re-strip-on-reload gap, no `FiltersCacheController::fireUpdate` invalidation, un-strip on pattern removal works automatically). The cost: every consumption point must be enumerated, since there is no single `setText` chokepoint.

---

## F-006 — Multi-range text highlighting already exists on iOS. No text-engine change needed. ⭐
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `submodules/Display/Source/TextNode.swift`, `submodules/Display/Source/LinkHighlightingNode.swift` (429 lines), `ChatMessageTextBubbleContentNode.swift:94-108, 1375-1384`

This was the plan's most expensive open risk (Risk #2). It is retired in the cheap direction.

- `TextNode.rangeRects(in range: NSRange) -> (rects: [CGRect], start:, end:)` is **public** (TextNode.swift:1293) — arbitrary character range → drawing rects.
- `LinkHighlightingNode` draws rounded-rect highlights from a rect array: `updateRects(_ rects: [CGRect], color: UIColor? = nil)`, backed by `generateRectsImage(color:rects:inset:outerRadius:innerRadius:stroke:strokeWidth:useModernPathCalculation:)`.
- `ChatMessageTextBubbleContentNode` **already holds `private var textHighlightingNodes: [LinkHighlightingNode] = []`** — plural, an existing multi-range highlight mechanism — alongside `linkHighlightingNode`, `linkPreviewHighlightingNodes`, `quoteHighlightingNode`.
- The established four-line pattern (line 1375-1384): create/reuse node → `insertSubnode(node, belowSubnode: self.textNode.textNode)` → set `frame` → `updateRects(rects)`. Inserting *below* the text node yields exactly the highlighter-background look specified on desktop.
- Precedent for range→rects→overlay: `TextLoadingEffect.swift:146` uses `textNode.textRangeRects(in: range)?.rects`.

**Implication:** on desktop, keyword highlighting required an additive change to the `lib_ui` text engine (`PaintContext.highlightRanges`, `ExtraHighlight`, per-line rect collection, `fillRectsFromRanges`, outPath composition). **On iOS it requires no engine change at all.** Phase 4 drops from "1 day *or* 5+, unknown" to roughly 1 day. Risk #2 is closed.

---

## F-007 — All four previously-unverified render paths located
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** local clone, `find`/`grep`

| Purpose | Verified path |
|---|---|
| Chat-list preview snippet (`PreviewTranslator` + preview footer-strip hook) | `submodules/ChatListUI/Sources/Node/ChatListItemStrings.swift:80` — `public func chatListItemStrings(...)` |
| Chat title (`NameTranslator` hook) | `submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleView.swift` |
| Message body text (footer strip + highlight hook) | `submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift` |
| Translate bar (hide-translate-bar setting) | `submodules/TelegramUI/Components/TranslateHeaderPanelComponent/Sources/ChatTranslationPanelNode.swift` |

`chatListItemStrings` is a **single public function** returning `(peer:, hideAuthor:, messageText: String, messageEntities: [MessageTextEntity], spoilers:, customEmojiRanges:, richTextPreview: NSAttributedString?)`.

**Implication:** one hook covers *both* preview translation and preview footer-stripping — on desktop these were two separate mechanisms. Risk #5 is closed.

---

## F-008 — `chatListItemStrings` has exactly 4 call sites; one is NOT the chat list
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `grep -rn "chatListItemStrings(" --include=*.swift` over the local clone — 4 call sites, exhaustive

| Call site | Purpose | Destructures |
|---|---|---|
| `ChatListUI/Sources/Node/ChatListItem.swift:1553` | chat list | `messageText` only |
| `ChatListUI/Sources/Node/ChatListItem.swift:1587` | chat list | `messageText` only |
| `ChatListUI/Sources/Node/ChatListItem.swift:2611` | chat list — the main render path | full tuple incl. `messageEntities`, `richTextPreview` |
| `TelegramUI/Components/Chat/ChatMessageItemView/Sources/ChatMessageItemView.swift:115` | **VoiceOver accessibility labels** (inside `dataForMessage`, feeding `VoiceOver_Chat_Photo*` strings) | `messageText` only |

**Resolves A-3 — confirmed sole producer, with a caveat.** Hooking inside `chatListItemStrings` covers every preview-text consumer in one place (better than desktop, which needed separate preview and strip mechanisms). But the blast radius extends beyond the chat list into VoiceOver accessibility text. That is arguably *correct* — a user reading translated, footer-stripped text should hear the same — but it is a behaviour change that must be stated, not discovered.

Note also that 3 of 4 sites discard entities entirely, so entity-offset correctness only matters at `ChatListItem.swift:2611`.

---

## F-009 — Scaleway tier specs (CORRECTS an earlier error)
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** scaleway.com/en/pricing/apple-silicon/ (fetched directly)

| Tier | Chip | RAM | SSD | €/hr | €/mo |
|---|---|---|---|---|---|
| M1 | M1 8C/8C | **8 GB** | 256 GB | 0.11 | 75 |
| M2 | M2 8C/10C | **16 GB** | 256 GB | 0.17 | 115 |
| M2 Pro | M2 Pro 10C/16C | **16 GB** | **512 GB** | 0.21 | 139 |
| M4-S | M4 10C/10C | 16 GB | 256 GB | 0.22 | 149 |
| M4-M | M4 10C/10C | **32 GB** | 1.02 TB | 0.29 | 199 |
| M4 Pro | M4 Pro 14C/20C | 64 GB | 2.05 TB | 0.49 | 335 |

**CORRECTION:** I earlier implied the M2 tier was 8 GB RAM and advised against it on that basis. That was wrong — **M2 and M2 Pro both have 16 GB RAM**; the only difference between them is 256 GB vs 512 GB SSD. Only the M1 tier is RAM-constrained. Monthly rates undercut hourly-equivalent (M2 Pro €139/mo vs €151 at 24×30×€0.21). 24 h minimum lease per Scaleway docs.

**Resolves A-5** (M2 Pro = 16 GB / 512 GB confirmed) and supersedes the RAM claim in the approved plan's Phase 0.

---

## F-010 — Disk requirement is UNKNOWN; earlier figures were estimates, now retracted
**Date:** 2026-08-06 · **Confidence:** UNVERIFIED

I previously wrote "Xcode ≈40 GB, Bazel output ≈60 GB+". **Those numbers had no source and are retracted.** Searches found no authoritative figure for either Telegram-iOS's Bazel footprint or Xcode 26.2's installed size, and the repo README states no disk requirement.

What *is* sourced: Bazel's disk cache growth is unbounded (Bazel remote-caching docs; cockroachdb/bazel issue #71894), Telegram-iOS uses `--disk_cache` via `Make.py --cacheDir`, and macOS 26 itself wants 34–60 GB free.

**Implication — the decision does not depend on the exact number.** Storage cannot be added to a Scaleway Apple silicon instance after provisioning, and exhausting it kills a multi-hour build. €24/month (M2 → M2 Pro) buys 2× headroom against an unbounded-growth cache. Take M2 Pro on insurance grounds, then **measure actual usage on the instance and record it here**, replacing this entry with a fact.

---

## F-011 — `translateMessagesViaText` makes three desktop workarounds unnecessary ⭐
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** `submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift:742-747`

```swift
public func translateMessages(messageIds: [EngineMessage.Id], fromLang: String?, toLang: String,
                              enableLocalIfPossible: Bool, tone: TranslationTone = .neutral)
    -> Signal<Never, TranslationError>

public func translateMessagesViaText(messagesDict: [EngineMessage.Id: String], fromLang: String?, toLang: String,
                                     generateEntitiesFunction: @escaping (String) -> [MessageTextEntity],
                                     enableLocalIfPossible: Bool)
    -> Signal<Never, TranslationError>
```

Four consequences, each of which was hand-built work on desktop:

1. **`messagesDict: [Id: String]` accepts arbitrary text per message.** The desktop's hardest-won fix — strip the footer from the *original* before translating, because translation is non-deterministic and literal patterns can't track wording variance — required defeating the server-side-translate-by-id path by passing `MsgId(0)` (`history_view_translate_tracker.cpp`). Here, feeding stripped text is the API's normal parameter. **Footer-strip-before-translate becomes near-free.**
2. **`generateEntitiesFunction` is a parameter.** Desktop hit a bug where translated text arrived with no entities, so hashtags/mentions/links weren't clickable, fixed by adding `TextUtilities::ParseEntities` inside `translationDone()`. On iOS this is a constructor argument. **Cost: zero.**
3. **Batch API takes `[EngineMessage.Id]`.** Eager backlog translation is one batched call, not N queued singles — materially better rate-limit behaviour than the desktop per-message queue, which is what caused the ~10 s FLOOD_WAIT latency bug.
4. **`enableLocalIfPossible`** routes to Apple's on-device translator when available. Combined with F-004 (no Hebrew until iOS 27), Arabic/Russian can go on-device and free while Hebrew falls back to remote — as a flag, not as a custom provider abstraction.

Results persist as `TranslationMessageAttribute` (a Postbox `MessageAttribute`, registered in `AccountManager.swift:222`), so translations **survive restart**. Desktop's preview and notification translations were in-memory and lost on relaunch.

---

## F-012 — Remaining hooks located
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** local clone `find`/`grep`

| Purpose | Path |
|---|---|
| Forwarded-from header (translate) | `submodules/TelegramUI/Components/Chat/ChatMessageForwardInfoNode` |
| Reply sender + snippet (translate) | `submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode` |
| Context-menu family (quick-add actions) | `submodules/TelegramUI/Sources/Chat/ChatControllerOpen*ContextMenu.swift` — incl. `...OpenHashtagContextMenu.swift` |

The text-*selection* menu specifically is not yet pinned down; the `ChatControllerOpen*ContextMenu` family is the established pattern to follow.

---

## F-013 — Swift 6.3.2 is installed on the Windows machine; pure-Foundation logic is compilable and testable offline
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** executed locally

`C:\Users\Dream\AppData\Local\Programs\Swift\Toolchains\6.3.2+Asserts\usr\bin\swiftc` — Swift 6.3.2, target `x86_64-unknown-windows-msvc`.

- **`swift file.swift` (interpreter) FAILS** — cannot JIT-link Foundation on Windows ("Symbols not found: … NSRegularExpression …").
- **`swiftc file.swift -o file.exe` WORKS**, and the binary runs with full Foundation: `NSRegularExpression`, `NSString`, `NSRange` ↔ `Range<String.Index>` bridging, `.folding`, unicode scalar properties.

**Implication:** the algorithmic core — keyword matcher, diacritic normaliser, footer-strip function, entity-offset arithmetic, highlight-range computation — can be genuinely compiled and unit-tested on Windows before any metered Mac time. Anything importing UIKit / Display / TelegramCore / Postbox / SwiftSignalKit cannot be type-checked here at all.

---

## F-014 — `.diacriticInsensitive` does NOT strip Hebrew niqqud or Arabic tashkeel ⚠️
**Date:** 2026-08-06 · **Confidence:** FACT · **Source:** compiled and executed locally (`probe.swift`, `probe2.swift`)

SPEC.md required the matcher to be diacritic-normalised specifically because it "matters for AR/HE/RU". The obvious Swift idiom for that is **wrong**:

```
FAIL  Hebrew niqqud folding   -> מִלָּה -> מִלָּה     (unchanged)
FAIL  Arabic tashkeel folding -> مُحَمَّد -> مُحَمَّد     (unchanged)
```

`String.folding(options: .diacriticInsensitive)` handles Latin diacritics only. Hebrew niqqud (U+05B0–U+05BC) and Arabic tashkeel (U+064B–U+0652) pass through untouched. A matcher built on it **silently fails on pointed Hebrew/Arabic** — the user's primary use case. Confirmed directly: `"דיווח מִיוּחָד מהשטח".contains("מיוחד")` is `false`.

**Proven fix** — canonical decomposition, then drop Unicode general category `Mn` (nonspacing mark). Script-agnostic, and a strict superset of the old behaviour:

```swift
func stripMarks(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in s.decomposedStringWithCanonicalMapping.unicodeScalars
    where scalar.properties.generalCategory != .nonspacingMark {
        out.append(scalar)
    }
    return String(out)
}
```

All 8 checks pass: Hebrew `מִלָּה→מלה`, Arabic `مُحَمَّد→محمد`, Latin/Cyrillic/emoji untouched, `café→cafe`, pointed-Hebrew keyword matches after normalising.

**⚠️ Consequence for highlighting (C2):** normalisation changes UTF-16 length — measured 20 → 17 on a real Hebrew sample. **Offsets computed on normalised text cannot be applied to the original string.** The matcher must either return offsets mapped back to the original, or maintain an index translation table. This is a design constraint on C2, not a detail — `TextNode.rangeRects(in:)` takes an `NSRange` against the *displayed* string.

---

## Open assumptions (NOT yet validated)

| # | Assumption | Confidence | Status |
|---|---|---|---|
| A-1 | Google endpoint tolerates the eager backlog pass at ~350 ms spacing without IP throttling | SPECULATIVE | Unvalidated — must be tested against real Hebrew channels; rate-limit behaviour differs from Telegram's FLOOD_WAIT |
| A-2 | Notification translation is achievable inside the NSE's time budget | SPECULATIVE | Unvalidated — separate process, cannot reach main-app caches, **cannot be simulator-tested**. The "~30 s" figure is Apple's documented NSE limit but I have not re-verified it for iOS 26 |
| A-4 | Character offsets from the matcher align with `NSRange` for custom-emoji messages | INFERRED | Desktop carried the same caveat; expect drift. Only matters at `ChatListItem.swift:2611` (see F-008) |
| ~~A-3~~ | ~~`chatListItemStrings` is the sole producer~~ | — | **RESOLVED → F-008** |
| ~~A-5~~ | ~~Scaleway M2 Pro is 16 GB / 512 GB~~ | — | **RESOLVED → F-009** |
