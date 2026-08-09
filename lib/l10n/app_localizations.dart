import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'OrigiLink'**
  String get appTitle;

  /// No description provided for @authChoiceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a new account or restore an existing one'**
  String get authChoiceSubtitle;

  /// No description provided for @signUpButton.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get signUpButton;

  /// No description provided for @logInButton.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get logInButton;

  /// No description provided for @seedPhraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Seed phrase'**
  String get seedPhraseLabel;

  /// No description provided for @seedPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your seed phrase to restore your account'**
  String get seedPhraseHint;

  /// No description provided for @restoreInvalidSeed.
  ///
  /// In en, this message translates to:
  /// **'This doesn\'t look like a valid seed phrase.'**
  String get restoreInvalidSeed;

  /// No description provided for @restoreNoBackupFound.
  ///
  /// In en, this message translates to:
  /// **'No backup was found for this seed phrase. Make sure you\'ve completed setup with relay sync on another device first.'**
  String get restoreNoBackupFound;

  /// No description provided for @restoreNetworkError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach any relay. Check your connection and try again.'**
  String get restoreNetworkError;

  /// No description provided for @profileSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set up your profile'**
  String get profileSetupSubtitle;

  /// No description provided for @displayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayNameLabel;

  /// No description provided for @displayNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a display name'**
  String get displayNameRequired;

  /// No description provided for @statusMessageLabel.
  ///
  /// In en, this message translates to:
  /// **'Status message (optional)'**
  String get statusMessageLabel;

  /// No description provided for @continueButton.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueButton;

  /// No description provided for @confirmButton.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirmButton;

  /// No description provided for @setupCompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'All set!'**
  String get setupCompleteTitle;

  /// No description provided for @setupCompleteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to OrigiLink, {displayName}'**
  String setupCompleteSubtitle(String displayName);

  /// No description provided for @chatListWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome, {displayName}'**
  String chatListWelcome(String displayName);

  /// No description provided for @navProfileFriends.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navProfileFriends;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @addFriendByQr.
  ///
  /// In en, this message translates to:
  /// **'Add friend with QR code'**
  String get addFriendByQr;

  /// No description provided for @addFriendTitle.
  ///
  /// In en, this message translates to:
  /// **'Add friend'**
  String get addFriendTitle;

  /// No description provided for @myQrTab.
  ///
  /// In en, this message translates to:
  /// **'My QR'**
  String get myQrTab;

  /// No description provided for @scanTab.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get scanTab;

  /// No description provided for @maxUsesLabel.
  ///
  /// In en, this message translates to:
  /// **'Max uses'**
  String get maxUsesLabel;

  /// No description provided for @unlimitedLabel.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get unlimitedLabel;

  /// No description provided for @customLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get customLabel;

  /// No description provided for @validForLabel.
  ///
  /// In en, this message translates to:
  /// **'Valid for (days)'**
  String get validForLabel;

  /// No description provided for @generateQrButton.
  ///
  /// In en, this message translates to:
  /// **'Generate QR code'**
  String get generateQrButton;

  /// No description provided for @regenerateQrButton.
  ///
  /// In en, this message translates to:
  /// **'Generate new code'**
  String get regenerateQrButton;

  /// No description provided for @saveQrToDeviceButton.
  ///
  /// In en, this message translates to:
  /// **'Save to device'**
  String get saveQrToDeviceButton;

  /// No description provided for @qrSavedToDeviceMessage.
  ///
  /// In en, this message translates to:
  /// **'QR code saved to your photos'**
  String get qrSavedToDeviceMessage;

  /// No description provided for @qrSaveFailedMessage.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the QR code'**
  String get qrSaveFailedMessage;

  /// No description provided for @copyCodeButton.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get copyCodeButton;

  /// No description provided for @codeCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'Code copied to clipboard'**
  String get codeCopiedMessage;

  /// No description provided for @pasteCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Or paste a code'**
  String get pasteCodeLabel;

  /// No description provided for @pasteCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Paste invite code here'**
  String get pasteCodeHint;

  /// No description provided for @pasteCodeButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get pasteCodeButton;

  /// No description provided for @activeInvitesTitle.
  ///
  /// In en, this message translates to:
  /// **'Active invite codes'**
  String get activeInvitesTitle;

  /// No description provided for @noActiveInvites.
  ///
  /// In en, this message translates to:
  /// **'No active invite codes'**
  String get noActiveInvites;

  /// No description provided for @invitesUsesUsed.
  ///
  /// In en, this message translates to:
  /// **'Used {used} of {max}'**
  String invitesUsesUsed(int used, int max);

  /// No description provided for @invitesUsesUsedUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Used {used} (unlimited)'**
  String invitesUsesUsedUnlimited(int used);

  /// No description provided for @invitesExpiresIn.
  ///
  /// In en, this message translates to:
  /// **'Expires in {days}d'**
  String invitesExpiresIn(int days);

  /// No description provided for @revokeInvite.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get revokeInvite;

  /// No description provided for @scanPrompt.
  ///
  /// In en, this message translates to:
  /// **'Point your camera at an OrigiLink QR code'**
  String get scanPrompt;

  /// No description provided for @pickFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Pick from gallery'**
  String get pickFromGallery;

  /// No description provided for @scanInvalidQr.
  ///
  /// In en, this message translates to:
  /// **'This isn\'t a valid OrigiLink invite code'**
  String get scanInvalidQr;

  /// No description provided for @sendRequestConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Send friend request?'**
  String get sendRequestConfirmTitle;

  /// No description provided for @sendRequestConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Send your profile to {name} and request to add them?'**
  String sendRequestConfirmBody(String name);

  /// No description provided for @sendRequestButton.
  ///
  /// In en, this message translates to:
  /// **'Send request'**
  String get sendRequestButton;

  /// No description provided for @requestSentMessage.
  ///
  /// In en, this message translates to:
  /// **'Friend request sent'**
  String get requestSentMessage;

  /// No description provided for @friendRequestsTitle.
  ///
  /// In en, this message translates to:
  /// **'Friend requests'**
  String get friendRequestsTitle;

  /// No description provided for @noFriendRequests.
  ///
  /// In en, this message translates to:
  /// **'No pending requests'**
  String get noFriendRequests;

  /// No description provided for @acceptButton.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get acceptButton;

  /// No description provided for @rejectButton.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get rejectButton;

  /// No description provided for @friendAddedMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} added as a friend'**
  String friendAddedMessage(String name);

  /// No description provided for @friendsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Friends'**
  String get friendsSectionTitle;

  /// No description provided for @favoritesSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favoritesSectionTitle;

  /// No description provided for @noFriendsYet.
  ///
  /// In en, this message translates to:
  /// **'No friends yet'**
  String get noFriendsYet;

  /// No description provided for @noFriendsHint.
  ///
  /// In en, this message translates to:
  /// **'Add a friend to start chatting'**
  String get noFriendsHint;

  /// No description provided for @noStatusMessage.
  ///
  /// In en, this message translates to:
  /// **'No status message'**
  String get noStatusMessage;

  /// No description provided for @startChat.
  ///
  /// In en, this message translates to:
  /// **'Talk'**
  String get startChat;

  /// No description provided for @addToFavorites.
  ///
  /// In en, this message translates to:
  /// **'Add to Favorites'**
  String get addToFavorites;

  /// No description provided for @removeFromFavorites.
  ///
  /// In en, this message translates to:
  /// **'Remove from Favorites'**
  String get removeFromFavorites;

  /// No description provided for @blockFriend.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockFriend;

  /// No description provided for @blockFriendConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Block {name}?'**
  String blockFriendConfirmTitle(String name);

  /// No description provided for @blockFriendConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ll stop receiving their messages and profile updates. They stay in your friends list so you can unblock them later.'**
  String get blockFriendConfirmBody;

  /// No description provided for @unblockFriend.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblockFriend;

  /// No description provided for @deleteFriend.
  ///
  /// In en, this message translates to:
  /// **'Delete friend'**
  String get deleteFriend;

  /// No description provided for @deleteFriendConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String deleteFriendConfirmTitle(String name);

  /// No description provided for @deleteFriendConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently removes them from your friends list. They can send you a new friend request later.'**
  String get deleteFriendConfirmBody;

  /// No description provided for @noChatsYet.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noChatsYet;

  /// No description provided for @noChatsHint.
  ///
  /// In en, this message translates to:
  /// **'Messages with your friends will show up here'**
  String get noChatsHint;

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet — say hi!'**
  String get noMessagesYet;

  /// No description provided for @typeMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get typeMessageHint;

  /// No description provided for @navTalk.
  ///
  /// In en, this message translates to:
  /// **'Talk'**
  String get navTalk;

  /// No description provided for @navTimeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get navTimeline;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @privateModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get privateModeLabel;

  /// No description provided for @globalModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get globalModeLabel;

  /// No description provided for @globalProfileSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Global Profile'**
  String get globalProfileSetupTitle;

  /// No description provided for @globalProfileSetupBody.
  ///
  /// In en, this message translates to:
  /// **'Global Chat is open to anyone on the network — this identity is separate from your private, friends-only account, so a Global post can never be linked back to it.'**
  String get globalProfileSetupBody;

  /// No description provided for @globalProfileSetupSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get globalProfileSetupSkip;

  /// No description provided for @globalProfileSetupCreate.
  ///
  /// In en, this message translates to:
  /// **'Create Global Profile'**
  String get globalProfileSetupCreate;

  /// No description provided for @globalProfileRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Global Profile required'**
  String get globalProfileRequiredTitle;

  /// No description provided for @globalProfileRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'Set up a Global Profile first to use Global Chat.'**
  String get globalProfileRequiredBody;

  /// No description provided for @newChannelTitle.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get newChannelTitle;

  /// No description provided for @channelNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Channel name'**
  String get channelNameLabel;

  /// No description provided for @channelAboutLabel.
  ///
  /// In en, this message translates to:
  /// **'About (optional)'**
  String get channelAboutLabel;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// No description provided for @createButton.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get createButton;

  /// No description provided for @showAllChannelsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show all Nostr channels'**
  String get showAllChannelsTooltip;

  /// No description provided for @showOrigilinkChannelsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show OrigiLink channels only'**
  String get showOrigilinkChannelsTooltip;

  /// No description provided for @origilinkChannelsTitle.
  ///
  /// In en, this message translates to:
  /// **'OrigiLink channels'**
  String get origilinkChannelsTitle;

  /// No description provided for @allChannelsTitle.
  ///
  /// In en, this message translates to:
  /// **'All channels'**
  String get allChannelsTitle;

  /// No description provided for @noChannelsYet.
  ///
  /// In en, this message translates to:
  /// **'No channels yet — create one to get started'**
  String get noChannelsYet;

  /// No description provided for @untitledChannel.
  ///
  /// In en, this message translates to:
  /// **'Untitled channel'**
  String get untitledChannel;

  /// No description provided for @typeChannelMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message this channel'**
  String get typeChannelMessageHint;

  /// No description provided for @noChannelMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet — be the first to say something'**
  String get noChannelMessagesYet;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsProfile;

  /// No description provided for @settingsRelay.
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get settingsRelay;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// No description provided for @settingsAttachmentServer.
  ///
  /// In en, this message translates to:
  /// **'File upload server'**
  String get settingsAttachmentServer;

  /// No description provided for @settingsLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open source licenses'**
  String get settingsLicenses;

  /// No description provided for @attachmentServerDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'File upload server'**
  String get attachmentServerDialogTitle;

  /// No description provided for @attachmentServerHint.
  ///
  /// In en, this message translates to:
  /// **'https://your-blossom-server.example'**
  String get attachmentServerHint;

  /// No description provided for @attachmentServerNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not set — set a server to send images/files'**
  String get attachmentServerNotConfigured;

  /// No description provided for @attachmentUploadFailedLabel.
  ///
  /// In en, this message translates to:
  /// **'Attachment failed'**
  String get attachmentUploadFailedLabel;

  /// No description provided for @attachmentServerSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'File upload servers'**
  String get attachmentServerSettingsTitle;

  /// No description provided for @attachmentServerDefaultBadge.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get attachmentServerDefaultBadge;

  /// No description provided for @setAsDefaultServer.
  ///
  /// In en, this message translates to:
  /// **'Set as default'**
  String get setAsDefaultServer;

  /// No description provided for @addAttachmentServer.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addAttachmentServer;

  /// No description provided for @attachmentServerUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get attachmentServerUrlLabel;

  /// No description provided for @invalidAttachmentServerUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL must start with https:// or http://'**
  String get invalidAttachmentServerUrl;

  /// No description provided for @noAttachmentServersYet.
  ///
  /// In en, this message translates to:
  /// **'No servers configured'**
  String get noAttachmentServersYet;

  /// No description provided for @removeAttachmentServerConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove server?'**
  String get removeAttachmentServerConfirmTitle;

  /// No description provided for @removeAttachmentServerConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Remove {url} from your server list?'**
  String removeAttachmentServerConfirmBody(String url);

  /// No description provided for @cannotRemoveOnlyServer.
  ///
  /// In en, this message translates to:
  /// **'You can\'t remove your only server'**
  String get cannotRemoveOnlyServer;

  /// No description provided for @resetAttachmentServers.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetAttachmentServers;

  /// No description provided for @resetAttachmentServersConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset servers?'**
  String get resetAttachmentServersConfirmTitle;

  /// No description provided for @resetAttachmentServersConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This replaces your server list with the default servers.'**
  String get resetAttachmentServersConfirmBody;

  /// No description provided for @attachmentServerSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch upload server?'**
  String get attachmentServerSwitchTitle;

  /// No description provided for @attachmentServerSwitchBody.
  ///
  /// In en, this message translates to:
  /// **'Sending failed. Try {url} instead?'**
  String attachmentServerSwitchBody(String url);

  /// No description provided for @attachmentServerSetDefaultCheckbox.
  ///
  /// In en, this message translates to:
  /// **'Make this the default server'**
  String get attachmentServerSetDefaultCheckbox;

  /// No description provided for @attachmentServerSwitchButton.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get attachmentServerSwitchButton;

  /// No description provided for @accountSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountSettingsTitle;

  /// No description provided for @myUid.
  ///
  /// In en, this message translates to:
  /// **'My UID'**
  String get myUid;

  /// No description provided for @uidLabel.
  ///
  /// In en, this message translates to:
  /// **'UID'**
  String get uidLabel;

  /// No description provided for @uidCopiedMessage.
  ///
  /// In en, this message translates to:
  /// **'UID copied to clipboard'**
  String get uidCopiedMessage;

  /// No description provided for @seedBackupButton.
  ///
  /// In en, this message translates to:
  /// **'Backup seed phrase'**
  String get seedBackupButton;

  /// No description provided for @seedBackupWarning.
  ///
  /// In en, this message translates to:
  /// **'Write down these words in order and keep them somewhere safe. Anyone with this phrase can restore your account.'**
  String get seedBackupWarning;

  /// No description provided for @seedBackupOnboardingNote.
  ///
  /// In en, this message translates to:
  /// **'You can review this phrase again anytime from Settings > Account.'**
  String get seedBackupOnboardingNote;

  /// No description provided for @seedBackupNoDefaultRelayTitle.
  ///
  /// In en, this message translates to:
  /// **'Also save your relay URLs'**
  String get seedBackupNoDefaultRelayTitle;

  /// No description provided for @seedBackupNoDefaultRelayBody.
  ///
  /// In en, this message translates to:
  /// **'None of your relays are on the default list. Restoring elsewhere requires selecting the same relays this account publishes to, so write those relay URLs down too — not just this phrase.'**
  String get seedBackupNoDefaultRelayBody;

  /// No description provided for @logoutButton.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logoutButton;

  /// No description provided for @logoutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Logout?'**
  String get logoutConfirmTitle;

  /// No description provided for @logoutConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Your account will be deleted from this device, and if you haven\'t saved your seed phrase, it can never be recovered.'**
  String get logoutConfirmBody;

  /// No description provided for @deleteAccountButton.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccountButton;

  /// No description provided for @deleteAccountConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get deleteAccountConfirmTitle;

  /// No description provided for @deleteAccountConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently erases your account, including your seed phrase, from this device and from relays. It can never be recovered.'**
  String get deleteAccountConfirmBody;

  /// No description provided for @relaySettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Relay settings'**
  String get relaySettingsTitle;

  /// No description provided for @relayUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Relay URL'**
  String get relayUrlLabel;

  /// No description provided for @addRelay.
  ///
  /// In en, this message translates to:
  /// **'Add relay'**
  String get addRelay;

  /// No description provided for @removeRelay.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeRelay;

  /// No description provided for @editRelay.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editRelay;

  /// No description provided for @resetRelays.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetRelays;

  /// No description provided for @resetRelaysConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset relays?'**
  String get resetRelaysConfirmTitle;

  /// No description provided for @resetRelaysConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This replaces your relay list with the default relays.'**
  String get resetRelaysConfirmBody;

  /// No description provided for @resetButton.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetButton;

  /// No description provided for @removeRelayConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove relay?'**
  String get removeRelayConfirmTitle;

  /// No description provided for @removeRelayConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Remove {url} from your relay list?'**
  String removeRelayConfirmBody(String url);

  /// No description provided for @noRelaysYet.
  ///
  /// In en, this message translates to:
  /// **'No relays configured'**
  String get noRelaysYet;

  /// No description provided for @invalidRelayUrl.
  ///
  /// In en, this message translates to:
  /// **'Relay URL must start with wss:// or ws://'**
  String get invalidRelayUrl;

  /// No description provided for @relayCountHint.
  ///
  /// In en, this message translates to:
  /// **'Recommended: 3-5 relays'**
  String get relayCountHint;

  /// No description provided for @clearChatButton.
  ///
  /// In en, this message translates to:
  /// **'Clear chat'**
  String get clearChatButton;

  /// No description provided for @clearChatConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear this chat?'**
  String get clearChatConfirmTitle;

  /// No description provided for @clearChatConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This deletes the message history with {name} from this device only. They can still message you and the chat will start fresh.'**
  String clearChatConfirmBody(String name);

  /// No description provided for @blockedSendConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'This friend is blocked'**
  String get blockedSendConfirmTitle;

  /// No description provided for @blockedSendConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'You can\'t send messages while they\'re blocked. Unblock them now?'**
  String get blockedSendConfirmBody;

  /// No description provided for @friendAlreadyAddedMessage.
  ///
  /// In en, this message translates to:
  /// **'This friend is already added. Their info has been updated.'**
  String get friendAlreadyAddedMessage;

  /// No description provided for @createTalkRoom.
  ///
  /// In en, this message translates to:
  /// **'Create talk room'**
  String get createTalkRoom;

  /// No description provided for @createGroup.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get createGroup;

  /// No description provided for @groupNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameLabel;

  /// No description provided for @selectMembersLabel.
  ///
  /// In en, this message translates to:
  /// **'Select members'**
  String get selectMembersLabel;

  /// No description provided for @groupMembersCount.
  ///
  /// In en, this message translates to:
  /// **'{count} members'**
  String groupMembersCount(int count);

  /// No description provided for @noGroupsYet.
  ///
  /// In en, this message translates to:
  /// **'No groups yet'**
  String get noGroupsYet;

  /// No description provided for @searchByNameHint.
  ///
  /// In en, this message translates to:
  /// **'Search by name'**
  String get searchByNameHint;

  /// No description provided for @noSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No matches found'**
  String get noSearchResults;

  /// No description provided for @editMessage.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editMessage;

  /// No description provided for @unsendMessage.
  ///
  /// In en, this message translates to:
  /// **'Unsend'**
  String get unsendMessage;

  /// No description provided for @editMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get editMessageTitle;

  /// No description provided for @unsendMessageConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Unsend this message?'**
  String get unsendMessageConfirmTitle;

  /// No description provided for @unsendMessageConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This message will be removed for both you and {name}.'**
  String unsendMessageConfirmBody(String name);

  /// No description provided for @messageEditedLabel.
  ///
  /// In en, this message translates to:
  /// **'(edited)'**
  String get messageEditedLabel;

  /// No description provided for @messageUnsentLabel.
  ///
  /// In en, this message translates to:
  /// **'This message was unsent'**
  String get messageUnsentLabel;

  /// No description provided for @hideMessage.
  ///
  /// In en, this message translates to:
  /// **'Hide for me'**
  String get hideMessage;

  /// No description provided for @hideMessageConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Hide this message?'**
  String get hideMessageConfirmTitle;

  /// No description provided for @hideMessageConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This hides it for you only (across all your devices) — it stays visible to {name}.'**
  String hideMessageConfirmBody(String name);

  /// No description provided for @replyToMessage.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get replyToMessage;

  /// No description provided for @replyingToLabel.
  ///
  /// In en, this message translates to:
  /// **'Replying to {name}'**
  String replyingToLabel(String name);

  /// No description provided for @originalMessageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Original message unavailable'**
  String get originalMessageUnavailable;

  /// No description provided for @youLabel.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get youLabel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
