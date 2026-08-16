import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:origilink/l10n/app_localizations.dart';
import 'package:origilink/screens/auth_choice.dart';
import 'package:origilink/screens/home.dart';
import 'package:origilink/screens/login.dart';
import 'package:origilink/screens/logout.dart' show seedStorageKey;
import 'package:origilink/screens/relay_settings.dart';
import 'package:origilink/screens/seed_backup.dart';
import 'package:origilink/screens/setup_complete.dart';
import 'package:origilink/services/account_sync.dart';
import 'package:origilink/src/rust/api/account.dart' as account_api;
import 'package:origilink/src/rust/api/chat.dart' as chat_api;
import 'package:origilink/src/rust/api/config.dart' as config_api;
import 'package:origilink/src/rust/api/keys.dart' as keys_api;
import 'package:origilink/src/rust/api/relay.dart' as relay_api;
import 'package:origilink/src/rust/api/sync.dart' as sync_api;
import 'package:origilink/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const OrigilinkApp());
}

class OrigilinkApp extends StatefulWidget {
  const OrigilinkApp({super.key});

  @override
  State<OrigilinkApp> createState() => _OrigilinkAppState();
}

class _OrigilinkAppState extends State<OrigilinkApp> {
  // Null means "follow the device locale". Set explicitly when the user
  // picks a language from the language selector, or loaded from a
  // previously-saved (and possibly cross-device-synced) choice at startup.
  Locale? _locale;

  late final Future<account_api.Account?> _profileFuture = _loadProfile();

  Future<account_api.Account?> _loadProfile() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final config = await config_api.loadConfig(storageDir: storageDir.path);
    final language = config.language;
    if (language != null && mounted) {
      setState(() => _locale = Locale(language));
    }
    final profile = await account_api.loadAccount(storageDir: storageDir.path);
    if (profile == null) return null;
    return reconcileAccountBackup(profile);
  }

  Future<void> _selectLocale(Locale locale) async {
    setState(() => _locale = locale);
    final storageDir = await getApplicationDocumentsDirectory();
    await config_api.saveConfig(
      storageDir: storageDir.path,
      config: config_api.AppConfig(language: locale.languageCode),
    );
    unawaited(publishAccountConfigBackup());
  }

  /// Applies a language change that arrived via sync from another device
  /// — display-only, since that device already persisted and published it.
  void _applySyncedLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  Future<void> _logout(BuildContext context) async {
    final storageDir = await getApplicationDocumentsDirectory();
    // Every top-level file any `rust/src/api/*.rs` module writes under the
    // storage dir — kept in sync with those `.join("...")` call sites by
    // hand, since there's no single registry of them. Previously missed
    // the Global Chat identity (`global_profile.json`,
    // `global_profile_configured`, `joined_channels.json`) and group/
    // ratchet/attachment-cache state entirely, so deleting an account
    // could still show that identity/its joined channels afterward —
    // everything account-scoped needs to go, not just the private-chat
    // half.
    const jsonFiles = {
      'account.json',
      'relays.json',
      'friends.json',
      'blocked.json',
      'outgoing_requests.json',
      'incoming_requests.json',
      'invites.json',
      'chat_read_state.json',
      'chat_started.json',
      // Tracks *this device's* last-applied backup timestamps per slot —
      // must be wiped on logout, or a different account logging in on
      // this device could have its genuinely-newer events rejected as
      // "not newer" against the previous account's stale watermarks.
      'account_sync_state.json',
      'config.json',
      'chat_history_complete.json',
      'friend_devices.json',
      'global_profile.json',
      'global_profile_configured',
      'joined_channels.json',
      'group_identity_accounts.json',
      'group_messages.enc',
      'group_processed_ids.json',
      'group_ratchet_sessions.enc',
      'groups.json',
      'held_messages.json',
      'link_preview_cache.json',
      'ratchet_account.enc',
      'ratchet_messages.enc',
      'ratchet_processed_ids.json',
      'ratchet_sessions.enc',
      'upload_server.json',
      'upload_servers.json',
    };
    const directories = {
      'chat.lmdb',
      'attachments',
      'friend_avatars',
      'group_attachments',
    };
    for (final entity in storageDir.listSync()) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is File &&
          (jsonFiles.contains(name) ||
              name.startsWith('avatar.') ||
              name == 'avatar_synced' ||
              name.startsWith('account_avatar_') ||
              name.startsWith('global_avatar_'))) {
        await entity.delete();
      } else if (entity is Directory && directories.contains(name)) {
        await entity.delete(recursive: true);
      }
    }
    // The chat database handle is cached for the lifetime of the process
    // (every account shares the same on-device storage directory) — drop it
    // now that chat.lmdb is gone, so a different account logging in within
    // this same app run reopens a fresh one instead of reusing a handle
    // into deleted files.
    chat_api.resetChatDb();
    const secureStorage = FlutterSecureStorage();
    await secureStorage.delete(key: seedStorageKey);
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => Builder(builder: _buildAuthChoice)),
      (route) => false,
    );
  }

  Widget _buildAuthChoice(BuildContext context) {
    return AuthChoiceScreen(
      onSelectLanguage: _selectLocale,
      onSignUp: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProfileSetupScreen(
              onContinue: (displayName, statusMessage, avatarPath) =>
                  _handleContinue(context, displayName, statusMessage, avatarPath),
            ),
          ),
        );
      },
      onRestore: (mnemonic) => _handleRestore(context, mnemonic),
    );
  }

  /// Validates the given seed phrase, looks up its relay-hosted account
  /// backup (NIP-06 derived identity), and if found recreates the local
  /// account from it and navigates to Home. Returns a user-facing error
  /// message on failure, or `null` on success.
  Future<String?> _handleRestore(BuildContext context, String mnemonic) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await keys_api.validateMnemonic(mnemonic: mnemonic);
    } catch (_) {
      return l10n.restoreInvalidSeed;
    }

    // The relay-selection step (shown right before this screen) already
    // persisted the user's chosen search relays to relays.json.
    final storageDir = await getApplicationDocumentsDirectory();
    final relayUrls = (await relay_api.loadRelayList(storageDir: storageDir.path)).urls;
    sync_api.RemoteAccount? remote;
    try {
      remote = await sync_api.fetchAccountBackup(mnemonic: mnemonic, relayUrls: relayUrls);
    } catch (_) {
      return l10n.restoreNetworkError;
    }
    if (remote == null) return l10n.restoreNoBackupFound;

    // Best-effort: pull the avatar/relays/friends backup slots too, so a
    // restored device picks up everything, not just display name/status.
    // None of these block the restore if they fail or are simply unset.
    String? avatarPath;
    String? avatarLink;
    try {
      final remoteAvatar = await sync_api.fetchAccountAvatarBackup(
        mnemonic: mnemonic,
        relayUrls: relayUrls,
      );
      if (remoteAvatar != null) {
        avatarLink = remoteAvatar.avatarLink;
        avatarPath = await account_api.saveAccountAvatarLink(
          storageDir: storageDir.path,
          avatarLink: avatarLink,
        );
      }
    } catch (_) {
      // No avatar backup, or relays unreachable — proceed without one.
    }

    try {
      final remoteRelays = await sync_api.fetchAccountRelaysBackup(
        mnemonic: mnemonic,
        relayUrls: relayUrls,
      );
      if (remoteRelays != null && remoteRelays.relays.isNotEmpty) {
        await relay_api.saveRelayList(storageDir: storageDir.path, urls: remoteRelays.relays);
      }
    } catch (_) {
      // No relays backup, or relays unreachable — keep the manually-chosen ones.
    }

    // Friends (and blocked/invites/pending-requests/read-state/config) are
    // deliberately NOT fetched here — HomeScreen doesn't need them to
    // render, and opening the live subscription there delivers each
    // slot's current snapshot within moments anyway (Nostr replays the
    // latest stored event per d-tag to a fresh subscription), the same
    // path ongoing cross-device sync already uses. Account text/avatar
    // and relays stay eager above: HomeScreen can't even be reached
    // without account.json existing, and relays must be known before any
    // subscription can open at all.

    await account_api.saveAccountWithTimestamp(
      storageDir: storageDir.path,
      displayName: remote.displayName,
      statusMessage: remote.statusMessage,
      avatarPath: avatarPath,
      avatarLink: avatarLink,
      updatedAt: remote.updatedAt,
    );
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: seedStorageKey, value: mnemonic);

    final profile = (await account_api.loadAccount(storageDir: storageDir.path))!;
    if (!context.mounted) return null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => Builder(
          builder: (context) => HomeScreen(
            profile: profile,
            onSelectLanguage: _selectLocale,
            onLocaleSynced: _applySyncedLocale,
            onLogout: () => _logout(context),
          ),
        ),
      ),
      (route) => false,
    );
    return null;
  }

  Future<void> _handleContinue(
    BuildContext context,
    String displayName,
    String statusMessage,
    String? avatarPath,
  ) async {
    final storageDir = await getApplicationDocumentsDirectory();
    String? persistedAvatarPath;
    if (avatarPath != null) {
      persistedAvatarPath = await account_api.saveAccountAvatar(
        storageDir: storageDir.path,
        pickedPath: avatarPath,
      );
    }
    await account_api.saveAccount(
      storageDir: storageDir.path,
      displayName: displayName,
      statusMessage: statusMessage,
      avatarPath: persistedAvatarPath,
    );
    final profile = (await account_api.loadAccount(storageDir: storageDir.path))!;
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RelaySettingsScreen(
          onContinue: () async {
            const secureStorage = FlutterSecureStorage();
            final mnemonic = await keys_api.generateMnemonic();
            await secureStorage.write(key: seedStorageKey, value: mnemonic);
            unawaited(publishAccountBackup(profile));
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SeedBackupScreen(
                  mnemonic: mnemonic,
                  onContinue: () {
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (_, _, _) => SetupCompleteScreen(
                          displayName: profile.displayName,
                          onDone: () {
                            Navigator.of(context).pushAndRemoveUntil(
                              MaterialPageRoute(
                                builder: (_) => Builder(
                                  builder: (context) => HomeScreen(
                                    profile: profile,
                                    onSelectLanguage: _selectLocale,
                                    onLocaleSynced: _applySyncedLocale,
                                    onLogout: () => _logout(context),
                                  ),
                                ),
                              ),
                              (route) => false,
                            );
                          },
                        ),
                        transitionsBuilder: (_, animation, _, child) =>
                            FadeTransition(opacity: animation, child: child),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OrigiLink',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: OrigilinkColors.primary),
        scaffoldBackgroundColor: OrigilinkColors.background,
        useMaterial3: true,
      ),
      locale: _locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: FutureBuilder<account_api.Account?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: OrigilinkColors.background,
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final existingProfile = snapshot.data;
          if (existingProfile != null) {
            return Builder(
              builder: (context) => HomeScreen(
                profile: existingProfile,
                onSelectLanguage: _selectLocale,
                onLocaleSynced: _applySyncedLocale,
                onLogout: () => _logout(context),
              ),
            );
          }
          return Builder(builder: _buildAuthChoice);
        },
      ),
    );
  }
}
