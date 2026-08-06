# HANDOFF — Swiftgram iOS port

_Last updated: 2026-08-06_

Porting features from AyuGram Desktop (Windows/C++/Qt) to iOS, shipped as a self-signed IPA.
Research findings live in **FINDINGS.md**. Approved plan: `C:\Users\Dream\.claude\plans\concurrent-skipping-goblet.md`.

## Cold-start facts

- **Base fork:** `github.com/Swiftgram/Telegram-iOS` → user's fork **`FlyWheel998/Telegram-iOS`** (public).
- **Local Windows clone (read/write, NOT buildable):** `C:\Users\Dream\Documents\Software\swiftgram-ios`
  Shallow (`--depth 1`), `--filter=blob:none`, sparse checkout of: `Swiftgram`, `.github`,
  `submodules/{TranslateUI,TelegramUI,ChatListUI,Display,AccountContext,TelegramCore,TextFormat}`,
  `Telegram/NotificationService`, `build-system`. ~106 MB.
  Remotes: `origin` = Swiftgram upstream (for rebases), `fork` = FlyWheel998.
- **Swift 6.3.2 IS installed on Windows.** `swiftc` works; the interpreter (`swift file.swift`) does
  **not** — it cannot JIT-link Foundation. Always compile to an `.exe`. See FINDINGS F-013.
- Telegram-iOS pins **Xcode 26.2 / macOS 26 / Bazel 8.4.2** (`versions.json`). Cannot be built on
  Windows. Cannot be built by Expo/EAS.
- Two known-bad files fail to check out on Windows (path length); `core.longpaths true` is set.
  **Never `git add -A`** — it would stage them as deletions.

## Scope (user-set, 2026-08-06)

| Order | Block | Days | Status |
|---|---|---|---|
| 1 | Environment + settings/strings scaffolding | 3.0 | blocked on user |
| 2 | **Text removal** ("remove highlighted text from posts") | 3.0 | **core + store done, 42/42 tests** |
| 3 | **Minimal UI** — reactions / comments / emoji | 2.0 | not started |
| 4 | Translation everywhere | 8.0 | not started |
| 5 | Keyword highlighting | 3.0 | not started |
| — | Notification translation | 3–5 | **backlogged by user** |

Two core features (blocks 2 + 3) land at ~8 days.

## Build strategy — cost-driven

User is cost-sensitive. Agreed approach:
1. **Windows** — write everything; genuinely compile + unit-test anything that imports only Foundation.
2. **GitHub Actions** — free Macs, per-minute. Compile-error loop happens here, not on a rented Mac.
3. **Rented Mac** — only for visual verification. Scaleway M2 Pro €0.21/h, **24 h minimum lease
   (Apple's SLA, universal — AWS has it too)**. Deleting destroys the disk; back state up to Object
   Storage with Restic between bursts.
4. Free fallback for visual checks: GitHub builds → TestFlight → user's own phone.

`.github/workflows/build.yml` was reworked: `macos-13`→`macos-26`, `checkout@v2`→`v4`, archived
`create-release`/`upload-release-asset` replaced with `upload-artifact@v4`, and a new **`logic-tests`
job** that typechecks and runs the module tests in ~2 min without Bazel. Full IPA build is now
opt-in via `workflow_dispatch` input, since it costs 1–2 h.

## DONE

**Block 2 core — `Swiftgram/SGTextRemoval/`** (3 commits: `df98422`, `1358e1e`, `c1e46b1`)

- `Sources/SGTextRemoval.swift` — matching + stripping. Diacritic- and whitespace-tolerant,
  case-insensitive, maps matches back to **original** UTF-16 offsets so message entities
  (links/bold/mentions) survive the cut. Entities shift, clip, or drop correctly.
- `Sources/SGRemovalRuleStore.swift` — thread-safe cached store behind a storage protocol.
  Rejects empty and 1-char selections, trims selection whitespace, treats case/spacing/vowel-point
  variants as duplicates.
- `Tests/main.swift` — 42 cases. All passing, clean under `-warnings-as-errors`.
- `BUILD` — Bazel target, no deps.

**Two real bugs were caught by these tests before reaching a device:**
1. `.folding(options: .diacriticInsensitive)` does **not** strip Hebrew niqqud or Arabic tashkeel
   (FINDINGS F-014). The obvious idiom silently fails on the user's primary use case.
2. The offset map was built per-*character*, but emoji occupy two UTF-16 units — desynchronising
   every offset after an emoji. Silent: no crash, no log, footers just stop matching.

## Design decisions worth not re-litigating

- **Rules are strictly per-channel.** No global scope, deliberately — a short phrase removed
  everywhere would silently eat text in unrelated chats with no way to notice. User confirmed.
- **Delete the text, keep the post.** Hiding whole posts is the deferred F4 hide action.
- **Keep a delete/undo path** (settings list, swipe to delete). A removal rule with no way to
  review or reverse it is a footgun. ~0.5 d of the 3.0.
- Strip at **consumption points**, not by mutating messages — Postbox `Message` is immutable.
  This deletes three desktop bug classes (no re-strip-on-reload gap, no cache invalidation,
  un-strip on rule removal is automatic) but requires enumerating every consumption point.

## NEXT (all writeable offline; none compile-verifiable without a Mac/CI)

1. Bind the store to `SGSimpleSettings` (`Keys` enum + `@UserDefault`, see FINDINGS F-001).
2. Settings list UI with swipe-to-delete — `SGSettingsUI` + `SGItemListUI`.
3. Text-selection context-menu action — follow the `ChatControllerOpen*ContextMenu.swift` family.
4. Three consumption hooks:
   - message body → `ChatMessageTextBubbleContentNode`
   - chat-list preview → `chatListItemStrings` (`ChatListItemStrings.swift:80`)
   - **pre-translation** → `translateMessagesViaText` accepts arbitrary per-message text
     (FINDINGS F-011), so stripping before translation is a parameter, not the `MsgId(0)` hack
     desktop needed.
5. Block 3 (minimal UI): `hideReactions` already exists in Swiftgram — verify only.
   Comments button → `ChatMessageCommentFooterContentNode`. Animated emoji → build on
   Telegram-iOS power-saving controls.

## BLOCKED ON USER

1. **Push access.** 3 commits sit on local branch `sg-custom-features`, unpushed. A PAT was
   supplied but the safety classifier blocks commands containing it verbatim. Resolve with
   `gh auth login` or a stored credential helper when the user is at their machine.
   **The supplied token must be revoked** — it was pasted in plaintext in conversation.
2. **`api_id` / `api_hash`** from my.telegram.org. Build produces no working app without them.
3. Apple signing certificates — not needed until there is something to install.
