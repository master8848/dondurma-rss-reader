> ## Fork note / Attribution
>
> This is a **fork** of the original **Dondurma RSS Reader** by
> **[DevOpen-io](https://github.com/DevOpen-io/dondurma-rss-reader)** —
> upstream: <https://github.com/DevOpen-io/dondurma-rss-reader>.
> Original work © 2026 DevOpen, released under the [MIT License](LICENSE);
> all app code in `lib/` and the platform folders is still upstream code
> (no rewrite claimed).
>
> What this fork adds: Prompt RSS prompt-management layers on top of the
> upstream reader — local prompt library (`library/` Markdown + YAML front
> matter), subscribed-item mirror (`subscriptions/<feed>/`), feed registry
> (`.promptlib/feeds.yaml`), Git versioning/sync via system-`git` shell-out,
> global hotkeys + clipboard/selected-text capture, and one-tap prompt
> expansion. All app code in `lib/` and the platform folders outside
> `lib/promptlib/`, `lib/screens/library_screen.dart`,
> `lib/screens/prompt_detail_screen.dart`, `lib/screens/add_prompt_screen.dart`,
> and `lib/router/app_router.dart` library routes is still upstream code
> (no rewrite claimed).
>
> **Rebrand notice:** a rebrand to a prompt-management app (working name
> *promptlib*, final name TBD) is planned. The package/app rename happens
> later — this branch only prepares attribution for it. Upstream link and
> license are preserved.
>
> ---
>
> <p align="center"><img src="assets/Logo.png" width="160" alt="Dondurma RSS Reader logo" /></p>

# Prompt RSS

Personal prompt-management app, forked from Dondurma RSS Reader by
[DevOpen-io](https://github.com/DevOpen-io/dondurma-rss-reader).
Fast, private, local-first: your prompts live as plain Markdown files you own
(`library/`), versioned with Git and synced via Git push/pull. The Dondurma
RSS/Atom reader underneath (Material 3, offline cache, background sync)
powers feed subscriptions for prompts and articles alike.

## Scope

- **In scope:** local prompt library browsing/editing, Git auto-commit +
  push/pull sync + history/revert + conflict resolution (keep-mine /
  keep-theirs / keep-both), feed subscriptions materialized as Markdown,
  global hotkeys, highlight-to-add (selection capture with clipboard
  fallback), one-tap prompt expansion with `{{variable}}` substitution.
- **Out of scope (descoped): no RSS publishing.** The app does not generate
  or serve RSS feeds; distribution/sync is Git push/pull + Git management
  only (see `DECISIONS.md` D12 in `/Volumes/hdd/saurav/code/promptlib/`).
  Mobile builds (Android/iOS) are also out of scope for v1 — desktop
  (Windows/macOS/Linux) only.

## Branches

| Branch | Workstream |
|---|---|
| `promptlib/wp1-core` | Core library: PromptDoc, front matter, PromptStore, GitService, feed config |
| `promptlib/wp2-feed` | Feed engine: type-aware fetch/parse + Markdown materializer |
| `promptlib/wp5-git` | Git push/manage flow: sync, history, conflict resolution |
| `promptlib/wp4-ui` | UI shell: Library / Prompt detail / Add-prompt screens |
| `promptlib/wp6-keys` | Shortcuts: hotkeys, selection capture, clipboard fallback |
| `promptlib/wp7-expand` | Quick expand: ExpandBridge variable substitution + clipboard |
| `promptlib/integration` | Integration of all workstreams (this branch) |

## Dondurma RSS Reader (upstream baseline)

[English](#english) · [Türkçe](#türkçe)

## English

[App Store](https://apps.apple.com/tr/app/dondurma-rss-reader/id6782334224?l=tr) · [Google Play](https://play.google.com/store/apps/details?id=io.devopen.dondurma)

### Features

- RSS 2.0/Atom, feed discovery, custom folders/icons/order, OPML import/export
- Global/per-feed keyword exclusion, search history, date sections, 50-item pagination
- Swipe read/bookmark actions; PageView navigation, progress, reading time, image carousel
- Global and per-feed full-text extraction with isolate processing
- Built-in WebView, EasyList/AdGuard, DarkReader, external browser modes
- Offline article/image cache; foreground and Workmanager background sync
- Local notifications, per-feed controls, quiet hours, digest selection
- Latest-news and category home-screen widgets
- 10 FlexColorScheme palettes; system/light/dark; reading typography controls
- Responsive widths, semantic controls, EN/TR/ES localization
- Modal-aware global toast feedback respecting reduced-motion settings

### Architecture

```text
lib/
├── main.dart       # startup, Hive migration, providers, OS integrations
├── models/         # FeedItem, FeedSubscription
├── providers/      # settings, subscriptions, bookmarks, feeds, article state
├── services/       # feed, full text, notification, OPML, background, widget
├── screens/        # onboarding, home tabs, article, settings, legal, debug
├── widgets/        # reusable article, folder, home, settings UI
├── router/         # GoRouter routes and onboarding redirect
├── theme/          # Material 3 themes
├── utils/          # global toast
└── l10n/           # EN/TR/ES localization
```

Five `ChangeNotifier` providers power UI state. `FeedProvider` receives subscription, settings, and bookmark state through `ChangeNotifierProxyProvider3`. Hive CE uses `settings`, `feeds`, and `bookmarks` boxes.

### Development

Requires Flutter compatible with Dart `^3.11.0`. A Flutter SDK is required;
this environment ships only the Dart SDK (no `flutter` binary), so
`flutter pub get` / `flutter test` / `flutter run` must be run on a machine
with Flutter installed.

```bash
git clone https://github.com/DevOpen-io/Dondurma-Rss-Reader.git
cd Dondurma-Rss-Reader
flutter pub get
flutter test
flutter run
```

Release: `flutter build apk|ios|web|windows|macos|linux --release`.

Details: [developer guide](DEVELOPER.md) · [product guide](PRODUCT.md)

## Türkçe

[App Store](https://apps.apple.com/tr/app/dondurma-rss-reader/id6782334224?l=tr) · [Google Play](https://play.google.com/store/apps/details?id=io.devopen.dondurma)

### Özellikler

- RSS 2.0/Atom, akış keşfi, özel klasör/simge/sıralama, OPML içe/dışa aktarma
- Genel/akış bazlı kelime filtresi, arama geçmişi, tarih bölümleri, 50 öğelik sayfalama
- Kaydırarak okundu/yer imi; PageView, okuma ilerlemesi/süresi, görsel galerisi
- Genel ve akış bazlı tam metin çıkarma; isolate tabanlı işleme
- Yerleşik WebView, EasyList/AdGuard, DarkReader, harici tarayıcı modları
- Çevrimdışı makale/görsel önbelleği; ön plan ve Workmanager senkronizasyonu
- Yerel bildirimler, akış kontrolleri, sessiz saatler, özet seçimi
- Son haberler ve kategori ana ekran widget'ları
- 10 renk şeması; sistem/açık/koyu; okuma tipografisi ayarları
- Duyarlı genişlik, semantik kontroller, EN/TR/ES
- Azaltılmış hareket ayarına uyan, modal farkındalıklı global toast

### Geliştirme

```bash
flutter pub get
flutter test
flutter run
```

Ayrıntılar: [geliştirici rehberi](DEVELOPER.md) · [ürün rehberi](PRODUCT.md)

## Privacy and license

[English privacy policy](docs/privacy-policy.en.md) · [Türkçe gizlilik politikası](docs/privacy-policy.tr.md) · [MIT License](LICENSE)
