# ARCHITECTURE — Swiftgram custom features

_Written 2026-08-06. Every file path and API below was read in source, not inferred._
Evidence for each claim is in **FINDINGS.md**; status in **HANDOFF.md**.

## Guiding constraints

1. **Keep our code in `Swiftgram/SG*` modules.** Edits to upstream files must be minimal, marked, and few — the fork rebases onto Telegram releases and every upstream line we touch is a future merge conflict.
2. **Pure-Foundation cores.** Logic that imports only Foundation is compiled and unit-tested in ~45 s on Linux CI, and on Windows locally. Logic buried in a UI file needs the **1h21m** full build to check. Push as much as possible into testable modules.
3. **Postbox `Message` is immutable.** Nothing is rewritten in the database; every feature transforms text at its *consumption points*. That removes whole bug classes seen on desktop (stale caches, no un-strip on rule removal) at the cost of having to enumerate consumption points exhaustively.
4. **Compiling is a weak signal for UI code.** Anything not covered by a unit test is UNVERIFIED until seen on a device.

---

## Shared foundation

### Storage
`SGSimpleSettings` (`Keys` enum + `@UserDefault`) holds scalars. Collections (removal rules, highlight terms) are JSON `Data` behind a storage protocol — see `SGRemovalRuleStore`, which keeps an in-memory cache under `NSLock` because reads happen from message layout off the main thread.

**App-group backing is required** for anything the Notification Service Extension reads (`UserDefaults(suiteName: APP_GROUP_IDENTIFIER)`), since the NSE is a separate process. Only relevant if notification translation is revived from the backlog.

### Reactivity — the one real gap
`SGSimpleSettings` has **no change notification**: no KVO, no `@Published`, no equivalent of desktop's `rpl::variable`. Settings changed while a chat is open will not repaint by themselves.

Two options per setting, chosen deliberately:
- **Apply on next natural repaint** — acceptable for rarely-toggled options. Must be *documented*, not left as accidental behaviour.
- **Bridge to a signal** — follow `Swiftgram/SGChatListSimpleSettingsSignal`, the existing precedent, when a change must be visible immediately.

Adding a removal rule *must* be immediate — the user selects text, taps Remove, and expects it gone. That path therefore needs an explicit refresh, not a natural repaint.

### Settings UI
`Swiftgram/SGSettingsUI/Sources/SGSettingsController.swift` (776 lines) switches over an entry enum to build rows; `Swiftgram/SGItemListUI` supplies item types; `Swiftgram/SGStrings/LocalizationManager.swift` supplies strings.

---

## Block B — text removal  *(engine done, integration pending)*

**Done:** `Swiftgram/SGTextRemoval/` — matcher, stripper, per-channel store, 51 tests green on Linux + Darwin.

### Data flow
```
long-press selection
   -> TextSelectionNode menu action "Remove this text"
   -> SGRemovalRuleStore.add(text:peerId:)      [validates, dedupes, persists]
   -> refresh open chat
                    ...on every subsequent render...
message render -> SGTextRemover.strip(text:entityRanges:rules:peerId:) -> display
```

### Integration points

**1. Selection menu — `submodules/TextSelectionNode/Sources/TextSelectionNode.swift` (~772-808)**
Menu is a flat list of `actions.append(ContextMenuAction(content: .text(title:accessibilityLabel:), action: {...}))` — Copy, Quote, Look Up, Translate, Select All, Share. Append one more. **No change to the `TextSelectionAction` enum**, which is `Codable` with an Int32 discriminator and switched on in several places — avoided deliberately.
*Constraint:* this module must not depend on TelegramCore. Deliver the peer id and the selected string outward through the existing callback rather than reaching in.

**2. Message body — `ChatMessageTextBubbleContentNode.swift`, insert at ~line 474**
After `rawText`/`messageEntities` are finalised, before `entities` derivation (476) and `CachedChatMessageText` (522).
Why exactly there:
- Line 436 shows **translation replaces `rawText`** with `TranslationMessageAttribute.text`. Stripping *after* that covers original **and** translated text in one hook. On desktop this needed two mechanisms and still leaked footers through translations.
- `CachedChatMessageText(text: rawText, ...)` then keys on the already-stripped text, so cache correctness is free.
- `MessageTextEntity.range` is **UTF-16** (`stringWithAppliedEntities:145` converts it straight to `NSRange`), matching the engine exactly.

**3. Chat-list preview — `submodules/ChatListUI/Sources/Node/ChatListItemStrings.swift:80`**
`chatListItemStrings(...)` is the sole producer, with **4 call sites** (F-008). One is `ChatMessageItemView.swift:115`, which feeds **VoiceOver labels** — so stripping there also changes what VoiceOver reads. Intended, but must be stated.

**4. Pre-translation — `translateMessagesViaText(messagesDict:...)`**
Takes arbitrary per-message text, so feeding stripped text is a normal parameter, not the `MsgId(0)` hack desktop needed. Only relevant once Block A lands; point 2 already covers displayed translations.

**5. Settings list** — rows grouped by chat, swipe to delete. The undo path; non-negotiable.

### Performance
`strip` is called per message per layout. `SGRemovalRuleStore.isEmpty(forPeerId:)` is the cheap guard — most chats have no rules and must cost one dictionary lookup. `removalRanges` early-returns on empty rules or empty text.

---

## Block E — minimal UI  *(smallest block)*

| Item | Hook | Notes |
|---|---|---|
| Hide reactions | `SGSimpleSettings.hideReactions` | **Already shipped.** Verify only. |
| Hide per-post comments button | `submodules/TelegramUI/Components/Chat/ChatMessageCommentFooterContentNode` | Desktop equivalent was `paintCommentsButton`. Gate whether the node is added at all, not just hidden, so layout reflows. |
| Disable animated custom emoji | Telegram-iOS power-saving controls | Locate before estimating; do not assume a clean flag exists. |
| Master "minimal" switch | `SGSettingsController` | Aggregates the above. |

Pure settings work, no new algorithms — the block most likely to compile first try.

---

## Block A — translation coverage

Extends what exists; does not rebuild it.

| Feature | Hook | Note |
|---|---|---|
| Auto-translate foreign→EN | `submodules/TranslateUI/Sources/ChatTranslation.swift` | Detection, `ignoredLanguages`, 16-message sampling, 1 h cache all exist. Add the auto-enable branch only. |
| Per-peer Always/Never | `updateChatTranslationStateInteractively` | **Already exists.** Expose in UI. |
| Eager backlog | `translateMessages(messageIds:...)` | Batch API. Port desktop's visible-first drain, ~350 ms spacing, 300 cap — aimed at Google's rate limiter now, not FLOOD_WAIT. |
| Chat titles | `ChatTitleView.swift` + chat list item | New `NameTranslator`: persistent cache, dedup queue, skip-Latin. |
| Preview snippets | `ChatListItemStrings.swift:80` | Same hook as B-3. |
| Message headers | `ChatMessageForwardInfoNode`, `ChatMessageReplyInfoNode` | Depends on the two translators above. |
| Hide translate bar | `TranslateHeaderPanelComponent/ChatTranslationPanelNode.swift` | Desktop lesson: hide only in the *already-translated* state, never the offer state, or translation becomes unstartable. |

Backend: Swiftgram's Google endpoint (free, covers Hebrew). Apple on-device lacks Hebrew until iOS 27 (F-004), so `enableLocalIfPossible` is an optimisation for Arabic/Russian, not the primary path.

---

## Block C — keyword highlighting

Render mechanism confirmed (F-006), **no text-engine change needed** — unlike desktop, which required a `lib_ui` change.

```
terms -> ranges over the DISPLAYED string
      -> TextNode.rangeRects(in: NSRange)        [public, TextNode.swift:1293]
      -> LinkHighlightingNode.updateRects(_:color:)
      -> insertSubnode(below: textNode)          [pattern at ChatMessageTextBubbleContentNode:1375-1384]
```
`ChatMessageTextBubbleContentNode` already holds `textHighlightingNodes: [LinkHighlightingNode]` — plural, an existing multi-range mechanism.

**Design constraint (F-014):** normalisation changes UTF-16 length (measured 20→17 on Hebrew). Offsets computed on normalised text **cannot** be applied to the original. The matcher must map back — `SGTextNormalizer.Normalized.originalRange(for:)` already does exactly this and is reused here.

Works over translated text for free, since it matches whatever string is displayed.

---

## Ordering and why

1. **Block B integration** — engine already proven; highest value per unit of risk.
2. **Block E** — small, pure settings, likely to compile first try.
3. **Block A** — largest; benefits from B's plumbing being settled.
4. **Block C** — reuses B's normaliser and E's settings patterns.

Notification translation stays backlogged: separate process, cannot be simulator-tested, and the NSE budget is unvalidated (A-2).

---

## Known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | 1h21m build cycle limits integration iterations | Add Bazel caching before the integration push; batch changes rather than compiling piecemeal |
| 2 | UI code compiles but misbehaves | Treat every UI change as UNVERIFIED until seen on device; keep logic in tested modules |
| 3 | Upstream rebase conflicts | Only 3 upstream files touched for Block B; keep it that way |
| 4 | Selection menu module boundaries | `TextSelectionNode` must not gain a TelegramCore dependency |
| 5 | Installable build needs a real push-entitled provisioning profile (F-017) | User action; not on the compile path |
