# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Dev environment

All Flutter/Rust/Android tooling lives **only inside the `origilink-dev` Docker container**, not on the host. The host has no `flutter`, `adb`, or Android SDK. Always run commands via:

```bash
docker exec -w /workspace origilink-dev bash -lc "<command>"
```

The container is started via `docker-compose.yml` (`network_mode: host`, so the container's `adb` can reach an Android emulator running on the host). If it isn't running, start it with `docker compose up -d` (or open the `.devcontainer`). `/workspace` inside the container is a bind mount of the repo root.

**Ownership gotcha**: the container runs as `root`, so files it creates (build artifacts, generated code, `flutter pub get` output) appear root-owned on the host bind mount and become uneditable by the host user. After the container writes new files/dirs, fix ownership from the host:

```bash
docker exec origilink-dev bash -lc "chown -R 1000:1000 /workspace/<path>"
```

**Never write debug screenshots/dumps into the repo**: `adb pull`/`uiautomator dump` output (screenshots, XML view dumps, etc. used while manually reproducing a bug) must never be pulled to a path under the repo root (`/workspace/...` inside the container, which is bind-mounted to the host repo) — anything left there risks being `git add`ed and pushed to GitHub. Pull to a container-local path (e.g. `/tmp/...`) and, if it needs to be viewed from the host (e.g. via the Read tool), `docker cp` it out to the host-side scratchpad directory instead, never into the project folder.

**Platform scope**: only Android (and eventually iOS) is actively developed/tested. Web/Windows/Linux desktop builds exist as scaffolding but are not maintained or verified — don't assume they work.

## Commands

```bash
# Install Dart deps (also triggers ARB -> AppLocalizations codegen via `generate: true`)
flutter pub get

# Static analysis
flutter analyze lib/

# Run on a device (list devices first with `flutter devices`)
flutter run -d emulator-5554 --debug

# Widget/unit tests
flutter test

# Integration test
flutter test integration_test/simple_test.dart

# Regenerate Dart<->Rust bindings after changing anything under rust/src/api/
flutter_rust_bridge_codegen generate

# Regenerate launcher icons after changing assets/branding/app_icon.png
dart run flutter_launcher_icons
```

Rust itself is never built with `cargo build` directly — `flutter run`/`flutter build` invoke it through the Native Assets build hook (`hook/build.dart`), which drives `flutter_rust_bridge_hooks` against `rust/` (no `cargokit`). To just typecheck Rust changes without a full Flutter rebuild, `cargo check --lib` from `rust/` works and is much faster.

## Git workflow

Commit in focused, single-purpose commits rather than bundling unrelated changes — split by nature of change (new feature / rename-refactor / visual tweak / bug fix) so `git log` and `git blame` stay useful. Don't let unrelated changes pile up into one large commit.

## Architecture

**Split**: Flutter (`lib/`) owns UI only — screen layout, input, calling into Rust, displaying results. Rust (`rust/src/api/`) owns all key management, protocol logic, and storage/DB operations. Don't put persistence or crypto logic in Dart. `rust/src/api/simple.rs` still has the `greet()` template function left over from scaffolding — unused, safe to remove whenever it's next touched.

**Exception — OS secure storage**: platform Keystore/Keychain (accessed via `flutter_secure_storage`) has no filesystem path Dart can hand to Rust the way it does for `path_provider` directories — it's only reachable through the Flutter plugin's platform channel. For secrets backed by secure storage, Dart is allowed to perform the raw read/write/delete calls against `flutter_secure_storage` directly, but all decision logic (generating, validating, deriving, encrypting) must still live in Rust and be called through the bridge — Dart's role there is limited to "pass the opaque string to/from the OS," never business logic. Two independent secrets live here: the account seed phrase (`seedStorageKey`, `lib/screens/logout.dart`) and the per-device forward-secrecy key (`ratchetKeyStorageKey`, `lib/services/ratchet_key.dart`) — see below for why they're deliberately never stored together or synced the same way.

**Flutter <-> Rust bridge**: `flutter_rust_bridge` (pinned to `2.13.0-beta.4`, exact-pinned in both `pubspec.yaml` and `rust/Cargo.toml` — bump both together). Config is `flutter_rust_bridge.yaml` (`rust_input: crate::api`, `dart_output: lib/src/rust`). Every `pub` function/struct under `rust/src/api/**` becomes a generated Dart file under `lib/src/rust/api/`. After adding or changing a Rust API function, run `flutter_rust_bridge_codegen generate` — the generated Dart files (`lib/src/rust/**`) are committed source, not build output. A function/struct field can be excluded from the generated bindings with `#[flutter_rust_bridge::frb(ignore)]` (used throughout `ratchet.rs`/`group_ratchet.rs` for internal session-storage types that must never cross the bridge).

**Localization**: standard `flutter_localizations` + ARB setup (`l10n.yaml`). `lib/l10n/app_en.arb` is the template/source-of-truth locale; `app_ja.arb` mirrors its keys. `generate: true` in `pubspec.yaml` means `flutter pub get` regenerates `lib/l10n/app_localizations*.dart` automatically. `MaterialApp.locale` in `lib/main.dart` (`_OrigilinkAppState._locale`) is `null` by default (follow device locale) and gets overridden by the language picker. **To add a language**: add `lib/l10n/app_<code>.arb` with the same keys, then add a display-name entry to the shared `languageNames` map in `lib/languages.dart` — both the auth-choice screen's language selector and Settings' language picker read from it automatically.

**Release signing**: `android/app/build.gradle.kts` loads `android/key.properties` (gitignored) + `android/keystore/origilink-release.jks` (gitignored) when present to sign release builds with the project's real release key; falls back to the debug keystore when absent, so `flutter build apk --release` still produces an installable (if not properly signed) APK on a fresh checkout without those files.

**Screens flow**: `lib/main.dart` (`OrigilinkApp`, stateful — owns locale state, and the top-level navigation callbacks: `_logout`, `_handleContinue`, `_handleRestore`) is the root. First launch (no persisted `Account`) shows `lib/screens/auth_choice.dart` (`AuthChoiceScreen`): choose "Sign up" (goes to `lib/screens/login.dart`'s `ProfileSetupScreen` to collect display name/status/avatar) or "Log in" (a seed-phrase restore flow, fully wired: `_handleRestore` in `main.dart` validates the phrase via NIP-06, fetches this account's relay-hosted backup — see "Account backup/sync" below — and if found recreates the local profile/avatar/relays/friends from it). Signing up flows: profile setup -> `lib/screens/relay_settings.dart` (relay list, seeded with defaults) -> `lib/screens/setup_complete.dart` (animated confirmation) -> `lib/screens/home.dart` (`HomeScreen`, bottom-nav shell: Profile & Friends / Talk / Public Chat tabs). Logging out wipes local Account/relay/seed data and returns to `AuthChoiceScreen`.

**Home tab contents**: `lib/screens/account_friends.dart` (`AccountFriendsTab`) shows the local account card (avatar/name/status, edit button -> `lib/screens/edit_profile.dart`) plus the real friends list (favorite/block/delete, tap through to `lib/screens/friend_profile.dart`). Adding a friend (`lib/screens/add_friend.dart`) is QR-code based: "My QR" mints a revocable per-relationship invite (`rust/src/api/invites.rs`) and encodes it (`sync::build_invite_qr_payload`) for someone to scan; "Scan" (or pasting the code) sends a friend request (`sync::send_friend_request`) that shows up for the invite's owner in `lib/screens/friend_requests.dart` to accept/reject. `lib/screens/public_chat_list.dart` backs the third tab and is still an unimplemented placeholder.

**Talk tab / 1:1 chat**: `lib/screens/chat_list.dart` lists friends with a started/in-progress chat (`chat::list_active_chat_pubkeys`) plus groups; `lib/screens/chat_thread.dart` is the actual message view — supports reply, edit, unsend/hide, image/file attachments, and inline link-preview cards for pasted URLs. Two message transports are merged for display (`chat_thread.dart`'s `_mergeWithRatchetHistory`, `chat_list.dart`'s preview loading):
- `rust/src/api/chat.rs` — the always-available baseline: NIP-17-style gift-wrapped direct messages (NIP-59: `Seal` inside a `Gift Wrap`), persisted in `nostr-lmdb`.
- `rust/src/api/ratchet.rs` — an Olm (vodozemac, Matrix's audited Signal-Protocol-style implementation) session layered on top for forward + backward secrecy, keyed by a random per-device identity (never derived from the mnemonic, so it can't collide across a user's devices) announced to friends over the baseline channel. History lives client-side only, encrypted at rest under the device-local `ratchetKeyStorageKey` (`ratchet_messages.enc`) — deliberately excluded from account backup/restore and cross-device sync, since sharing this key across devices is exactly what would break the ratchet.

**Attachments**: `rust/src/api/attachment.rs` — NIP-44 caps plaintext at ~64KB, too small for files, so the body is encrypted separately with a random per-attachment XChaCha20-Poly1305 key and uploaded to a Blossom (BUD-01/BUD-02) server; only that small key is NIP-44-encrypted to the recipient through the normal chat rumor. Upload servers are configurable (`lib/screens/attachment_server_settings.dart`), same shape as relay management.

**Group chat**: `rust/src/api/groups.rs` (roster/membership, fallback delivery over each member's existing 1:1 relationship) + `rust/src/api/group_ratchet.rs` (the preferred path once available: every account mints one dedicated Nostr identity *per group*, shared via the roster, letting members reach each other directly — including members not otherwise 1:1 friends — over pairwise Olm sessions reusing `ratchet.rs`'s session store). `lib/screens/create_group.dart` and `lib/screens/group_thread.dart` are the UI.

**Friend requests, invites, and live updates**: incoming friend requests/acceptances/messages/group invites/profile updates all arrive over one live relay subscription per account (`sync::subscribe_friend_events`, opened by `home.dart`'s `_subscribeFriendEvents`). That subscription is rebuilt often (new invite, accepted friend, app resume, ...) — Rust guards against a superseded rebuild's task still mutating state after a newer one has taken over (`sync.rs`'s `subscription_generation`), and the exposed Dart `Stream` is backed by a single long-lived `StreamController` in `home.dart` whose identity never changes, so screens pushed via `Navigator` (which capture the stream once at construction time and are never rebuilt) don't silently go stale mid-visit.

**Notification/unread badges**: computed in `home.dart` itself (`_pendingRequestCount`, `_unreadCounts`/`_talkUnreadTotal`), not inside the individual tab widgets — `BottomNavigationBar` only mounts whichever tab is currently selected, so anything computed inside e.g. `ChatListTab` would stop updating the instant another tab is showing. `ChatListTab` reads `home.dart`'s already-fetched `unreadCounts` map for its own per-row badges instead of fetching a second copy.

**Account backup/sync across devices**: `rust/src/api/sync.rs`'s `publish_account_*_backup`/`fetch_account_*_backup` functions (profile, avatar, relays, friends, blocked list, invites, read-state, config, chat-started) self-publish to the account's own relays as self-addressed Nostr events, so a second device — or a device restored from the seed phrase alone (see "Screens flow" above) — can pull the full picture down. An `account_synced` `FriendEvent` fires when another device's fresher backup is applied locally, so `home.dart` can refresh what's shown without the user doing anything.

**Link previews**: `rust/src/api/link_preview.rs` fetches a pasted URL's page and extracts Open Graph (falling back to plain `<title>`) metadata for `chat_thread.dart`'s `_LinkPreviewCard` — a small regex/string-based HTML scan rather than a full parser dependency, since only `<meta>`/`<title>` tags are needed.

**Account (display identity) persistence**: `rust/src/api/account.rs` (`save_account`/`load_account`) serializes an `Account { display_name, status_message, avatar_path }` struct to `account.json` via `serde`/`serde_json`, inside a storage directory Dart resolves with `path_provider`'s `getApplicationDocumentsDirectory()` and passes in as a plain string.

**Relay list persistence**: `rust/src/api/relay.rs` — `save_relay_list`/`load_relay_list` persist to `relays.json` the same way; `check_relay_statuses` opens short-lived WebSocket connections (via `tokio-tungstenite`) to report per-relay reachability. A `rustls` crypto provider is installed once at startup in `rust/src/api/simple.rs`'s `#[frb(init)] init_app()` — required before any `wss://` connection works.

**Account seed / key material**: `rust/src/api/keys.rs` has pure, I/O-free crypto logic — `generate_mnemonic()` (12-word BIP-39 phrase), `validate_mnemonic()` (checks it's a valid BIP-39 phrase AND can derive Nostr keys per NIP-06), and per-relationship key derivation (`derive_contact_keys`) — every friendship, group, and invite gets its own unlinkable key derived from a sequential account index, never the account's own identity key directly. Persistence of the seed phrase happens in Dart via `flutter_secure_storage` (see the architecture exception above), keyed by `seedStorageKey`. There is no fixed, network-visible account key: the seed is purely local-device material today, restorable on a new device via the relay-hosted backup (see "Screens flow"/"Account backup/sync" above) as long as the seed phrase itself is re-entered by the user. Longer-term direction (not yet implemented): NIP-49-style passphrase encryption of the seed for relay-based cross-device *sync of the seed itself*, distinct from today's "re-type the seed, then pull the backup" restore flow.

**Stale generated boilerplate**: `test/widget_test.dart` and `integration_test/simple_test.dart` still reference the original `flutter create` template (a `MyApp` counter widget, and a `greet("Tom")` smoke test) that no longer matches the current app. They will fail as-is — update or replace them rather than assuming they pass. Automated Rust tests exist only for `rust/src/api/ratchet.rs` (`#[cfg(test)] mod tests` at the bottom of the file, run via `cargo test --lib` from `rust/`) — no other module has test coverage yet.
