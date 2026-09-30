# PromptLib Vision (delta over Dondurma RSS Reader)

> Attribution: forked from the original Dondurma RSS Reader by
> [DevOpen-io](https://github.com/DevOpen-io/dondurma-rss-reader)
> (MIT License (c) 2026 DevOpen); all `lib/` and platform code below is upstream work.

## 1. Goal

PromptLib is a personal prompt-management desktop app (Flutter, Windows/macOS/Linux) forked from the Dondurma RSS reader: the user's prompt library is a folder of Markdown files with YAML front matter (`library/`), versioned with Git, synced via a Git remote, and distributed via per-feed RSS — so prompts are plain files the user owns, while the app provides library browsing, Git versioning/sync, RSS subscriptions, one-tap prompt expansion, and publishing.

## 2. What Dondurma already gives us

Dondurma is a local-first Flutter RSS/Atom reader (Material 3 + FlexColorScheme, EN/TR/ES) that already solves feed reading end-to-end; PromptLib reuses it as the baseline and changes as little as possible:

- Feed fetching + parsing — `lib/services/feed_service.dart` (HTTP with etag/last-modified + conditional 304, `dart_rss` parsing, isolate-based `parseFeedBody`)
- Feed state + filtering + pagination — `lib/providers/feed_provider.dart` (50-item date-sectioned pages, global/per-feed keyword exclusion, coalesced `refreshAll()`, 5-way fetch semaphore, `filterInputsChanged` cache gate, `_hasLoadedOnce` notification gate)
- Subscriptions + categories — `lib/providers/subscription_provider.dart`, `lib/models/feed_subscription.dart` (custom categories with icons/order)
- Article model — `lib/models/feed_item.dart` (JSON serialization, copyWith)
- Saved items — `lib/providers/bookmark_provider.dart` (Hive `bookmarks` box, JSON + ID set)
- Settings — `lib/providers/settings_provider.dart` (Hive `settings` box: theme/locale/cache/sync/notifications/reading/filters/browser)
- Persistence — Hive CE boxes `settings` / `feeds` / `bookmarks`, one-time `_migrateHiveBoxes()` in `lib/main.dart`
- Routing — GoRouter in `lib/router/app_router.dart` + `lib/router/onboarding_state.dart` (`/onboarding`, `/`, `/article`, `/debug`)
- Screens — `lib/screens/home_screen.dart` (Feeds/Folders/Bookmarks/Settings tabs), `lib/screens/article_screen.dart` (PageView swipe navigation), `lib/screens/onboarding_screen.dart`, `lib/screens/settings_screen.dart`, `lib/screens/bookmarks_screen.dart`, `lib/screens/categories_screen.dart`, `lib/screens/debug_screen.dart`
- Background sync — `lib/services/background_fetch_service.dart` (Workmanager, 15-min minimum, baseline-diffed notifications) + foreground timer in `FeedProvider`
- Notifications — `lib/services/notification_service.dart` (quiet hours, digest modes, launch payload → article navigation) + `lib/services/observed_article_store.dart` (14-day feed+epoch scoped dedup, lock-file serialized foreground/isolate claims)
- OPML import/export — `lib/services/opml_service.dart`
- Offline cache — `lib/services/feed_cache_policy.dart`, `lib/services/image_cache_service.dart`, offline banner
- Reader extras — `lib/services/full_text_extraction_service.dart` (isolate heuristic extraction, tri-state per-feed `fullTextEnabled`), built-in WebView with ad-blocking/DarkReader (`adblocker_webview`, `webview_flutter`), share via `share_plus`, search history (MRU 10), global modal-aware toast (`lib/utils/`)
- Theming/i18n — `lib/theme/`, `lib/l10n/` (EN/TR/ES, Outfit via `google_fonts`)

## 3. What must change

1. **Per-feed type (`prompt` / `article` / `other`)** — extend `FeedSubscription` (or a parallel registry) with a `type` field defaulting to `other` (backward-compatible with existing feeds); prompt feeds get expand/copy-first UI, article feeds keep the current reader UI, `other` keeps generic behavior. Filtering, notifications, and full-text defaults may vary by type.
2. **Local library: `library/` (Markdown + YAML front matter)** — the user's own prompts live as plain `.md` files under `library/` (e.g. `library/<slug>.md`), each with YAML front matter (title, version, tags, description, variables, updated) plus Markdown body. `PromptStore` watches/parses this folder; Hive remains a read cache/index, never the source of truth for prompt content.
3. **Subscriptions cache: `subscriptions/<feed>/`** — subscribed prompt/article feeds are materialized as local Markdown files under `subscriptions/<feed-slug>/<item-slug>.md` (same front-matter convention), so subscribed prompts are usable offline and expandable exactly like local ones; entry point is the existing `FeedService`/`FeedProvider` pipeline plus a feed→Markdown materializer.
4. **Feed registry: `.promptlib/feeds.yaml`** — per-feed metadata (url, name, type, update policy, enabled flags) moves out of the Hive `feeds` box into a human-editable `.promptlib/feeds.yaml` file at the library root, checked into Git alongside the prompts; Hive keeps only fetch caches/validators/read IDs. Must support migration from existing Hive subscriptions.
5. **Git versioning via shell-out (`GitService`)** — every `library/` edit auto-commits (debounced) with a conventional message; push/pull syncs to the user's Git remote; history view and revert/restore come from `git log`/`git show`; resolve conflicts by keeping both / ours-theirs choice, never silent overwrite. Shell out to the system `git` binary (no libgit2 dependency); detect absence and degrade to local-only with a clear message.
6. **RSS publisher from `library/` (`Publisher`)** — each local feed defined in `.promptlib/feeds.yaml` renders as a static RSS 2.0 XML file generated from `library/` contents (title/description/version → item fields), so others can subscribe to a user's prompt feed with any RSS reader; publishing = regenerate XML + commit (+ push on demand). Reuses `dart_rss`-compatible output conventions and the existing `OpmlService` patterns for feed metadata.
7. **Global hotkeys (`HotkeyService`)** — desktop-only global hotkey (e.g. summon library search window) on Windows/macOS/Linux; brings the app forward from background/tray, fuzzy-filters `library/` + `subscriptions/`, Enter copies/expands. No mobile equivalent in v1.
8. **Quick-expand (`ExpandBridge`)** — one-tap/keystroke path from a selected prompt to the active consumer: copy rendered prompt to clipboard with `{{variables}}` substituted (prompted inline for missing values), plus paste-assist where the OS allows; full-text/WebView stack is irrelevant here — expansion output is plain text. Version stamp included in expanded footer for traceability.
9. **Highlight-to-add (per-OS selected-text capture, macOS first; clipboard fallback)** — highlight text in any OS app, hit the add hotkey, and the selected text immediately appears in the Add-Prompt editor. Capture is per-OS native: macOS first via Accessibility `AXUIElement` selected-text (`kAXSelectedTextAttribute`, needs AX-trusted permission); Windows (UI Automation `TextPattern.GetSelection`) and Linux (X11 `PRIMARY` selection) later based on feasibility; Wayland is clipboard-only. The clipboard is the universal fallback — when native capture returns nothing, the add flow reads clipboard text instead. See `SelectionCaptureService` in `ARCHITECTURE.md` and D9 in `DECISIONS.md`.

## 4. Non-goals for v1

- **Mobile (Android/iOS) is out of scope** — v1 targets Windows/macOS/Linux desktop only; no mobile builds, no home-screen widgets (`home_widget`, `WidgetUpdateService`), no Workmanager background sync on mobile (desktop uses foreground timer + OS-appropriate scheduling), no share-sheet/push-notification mobile flows.
- No hosted backend, accounts, analytics, ads, or algorithmic discovery (inherits Dondurma's promise).
- No collaborative/real-time editing — sync conflicts resolved file-wise via Git, no CRDT/merge UI beyond keep-both/ours-theirs.
- No prompt marketplace, ratings, comments, or monetization.
- No new mobile-only dependencies; no Dart/Flutter SDK or dependency upgrades as part of the vision change (reuse `provider`, Hive CE, GoRouter, `dart_rss`, `http`, `xml`).
- No rich-text prompt editor beyond Markdown source + preview (reuse reader typography controls); no TTS/statistics/tags backlog items promoted into v1.

## Source / sync / distribution summary

| Concern | Mechanism |
|---|---|
| Source of truth (own prompts) | `library/*.md` Markdown + YAML front matter |
| Source of truth (feed registry) | `.promptlib/feeds.yaml` (url, name, type `prompt`/`article`/`other`, policy) |
| Subscribed content cache | `subscriptions/<feed>/<item>.md` (same front-matter convention) |
| Versioning | Git via shell-out, auto-commit per edit |
| Sync | Git push/pull to user's remote |
| Distribution | Static per-feed RSS XML generated from `library/` |
| Consumption | Existing Dondurma feed pipeline + prompt expand/copy |
