# Prompt RSS

> Personal prompt-management app, forked from Dondurma RSS Reader by DevOpen-io.

## What this is

Prompt RSS is a personal prompt-management app: your prompt library is a folder
of Markdown files with YAML front matter (`library/`), versioned with Git,
synced via a Git remote, and distributed via per-feed RSS. Plain files you own;
the app provides library browsing, Git versioning/sync, RSS subscriptions,
one-tap prompt expansion, and publishing.

- **Prompt library folders** — own prompts live as `.md` files under
  `library/` (YAML front matter + Markdown body); subscribed feeds are
  materialized under `subscriptions/<feed>/` in the same convention.
- **Git** — every `library/` edit auto-commits (debounced); push/pull syncs to
  your remote; history and revert come from `git log` / `git show`.
- **RSS** — feed registry in `.promptlib/feeds.yaml` (per-feed type
  `prompt` / `article` / `other`); local feeds render as static RSS 2.0 XML so
  others can subscribe with any RSS reader. Reader baseline (fetch, filter,
  cache, notifications) is inherited from Dondurma.

## Attribution

Forked from the original **Dondurma RSS Reader** by
**[DevOpen-io](https://github.com/DevOpen-io/dondurma-rss-reader)** —
upstream: <https://github.com/DevOpen-io/dondurma-rss-reader>.
Original work © 2026 DevOpen, released under the [MIT License](LICENSE).

All app code in `lib/` and the platform folders (`android/`, `ios/`,
`linux/`, `windows/`, `macos/`) is still upstream code; no rewrite is claimed.
The Dart package name (`ice_cream_rss_reader` in `pubspec.yaml`) is unchanged
on this branch.

## What changed so far

Vision/planning docs only — no app code has been changed:

- `PROMPTLIB_VISION.md` (repo root): goal, Dondurma baseline reuse list,
  change items, v1 non-goals.
- Planning docs in `/Volumes/hdd/saurav/code/promptlib/` (`ARCHITECTURE.md`,
  `DECISIONS.md`, `QUESTIONS.md`).

## Roadmap

See [`PROMPTLIB_VISION.md`](PROMPTLIB_VISION.md) for the full vision delta:
per-feed types, `library/` + `subscriptions/` folders, `.promptlib/feeds.yaml`,
`GitService`, RSS `Publisher`, desktop hotkeys, quick-expand, and
highlight-to-add (macOS first, clipboard fallback). Planning details live in
`/Volumes/hdd/saurav/code/promptlib/`.

## Development

Requires Flutter compatible with Dart `^3.11.0`.

> Note: `flutter` is not installed in this environment, so these commands have
> not been run here.

```bash
git clone https://github.com/master8848/dondurma-rss-reader.git
cd dondurma-rss-reader
flutter pub get
flutter test
flutter run
```

Release: `flutter build apk|ios|web|windows|macos|linux --release`.

Details: [developer guide](DEVELOPER.md) · [product guide](PRODUCT.md) ·
[vision](PROMPTLIB_VISION.md)

## Privacy and license

[English privacy policy](docs/privacy-policy.en.md) ·
[Türkçe gizlilik politikası](docs/privacy-policy.tr.md) ·
[MIT License](LICENSE) (© 2026 DevOpen)
