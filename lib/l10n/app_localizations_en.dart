// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'OrigiLink';

  @override
  String get authChoiceSubtitle =>
      'Create a new account or restore an existing one';

  @override
  String get signUpButton => 'Sign up';

  @override
  String get logInButton => 'Log in';

  @override
  String get seedPhraseLabel => 'Seed phrase';

  @override
  String get seedPhraseHint => 'Enter your seed phrase to restore your account';

  @override
  String get restoreInvalidSeed =>
      'This doesn\'t look like a valid seed phrase.';

  @override
  String get restoreNoBackupFound =>
      'No backup was found for this seed phrase. Make sure you\'ve completed setup with relay sync on another device first.';

  @override
  String get restoreNetworkError =>
      'Couldn\'t reach any relay. Check your connection and try again.';

  @override
  String get profileSetupSubtitle => 'Set up your profile';

  @override
  String get displayNameLabel => 'Display name';

  @override
  String get displayNameRequired => 'Please enter a display name';

  @override
  String get statusMessageLabel => 'Status message (optional)';

  @override
  String get continueButton => 'Continue';

  @override
  String get confirmButton => 'Confirm';

  @override
  String get setupCompleteTitle => 'All set!';

  @override
  String setupCompleteSubtitle(String displayName) {
    return 'Welcome to OrigiLink, $displayName';
  }

  @override
  String chatListWelcome(String displayName) {
    return 'Welcome, $displayName';
  }

  @override
  String get navProfileFriends => 'Home';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get addFriendByQr => 'Add friend with QR code';

  @override
  String get addFriendTitle => 'Add friend';

  @override
  String get myQrTab => 'My QR';

  @override
  String get scanTab => 'Scan';

  @override
  String get maxUsesLabel => 'Max uses';

  @override
  String get unlimitedLabel => 'Unlimited';

  @override
  String get customLabel => 'Custom';

  @override
  String get validForLabel => 'Valid for (days)';

  @override
  String get generateQrButton => 'Generate QR code';

  @override
  String get regenerateQrButton => 'Generate new code';

  @override
  String get saveQrToDeviceButton => 'Save to device';

  @override
  String get qrSavedToDeviceMessage => 'QR code saved to your photos';

  @override
  String get qrSaveFailedMessage => 'Couldn\'t save the QR code';

  @override
  String get copyCodeButton => 'Copy code';

  @override
  String get codeCopiedMessage => 'Code copied to clipboard';

  @override
  String get pasteCodeLabel => 'Or paste a code';

  @override
  String get pasteCodeHint => 'Paste invite code here';

  @override
  String get pasteCodeButton => 'Add';

  @override
  String get activeInvitesTitle => 'Active invite codes';

  @override
  String get noActiveInvites => 'No active invite codes';

  @override
  String invitesUsesUsed(int used, int max) {
    return 'Used $used of $max';
  }

  @override
  String invitesUsesUsedUnlimited(int used) {
    return 'Used $used (unlimited)';
  }

  @override
  String invitesExpiresIn(int days) {
    return 'Expires in ${days}d';
  }

  @override
  String get revokeInvite => 'Revoke';

  @override
  String get scanPrompt => 'Point your camera at an OrigiLink QR code';

  @override
  String get pickFromGallery => 'Pick from gallery';

  @override
  String get scanInvalidQr => 'This isn\'t a valid OrigiLink invite code';

  @override
  String get sendRequestConfirmTitle => 'Send friend request?';

  @override
  String sendRequestConfirmBody(String name) {
    return 'Send your profile to $name and request to add them?';
  }

  @override
  String get sendRequestButton => 'Send request';

  @override
  String get requestSentMessage => 'Friend request sent';

  @override
  String get friendRequestsTitle => 'Friend requests';

  @override
  String get noFriendRequests => 'No pending requests';

  @override
  String get acceptButton => 'Accept';

  @override
  String get rejectButton => 'Reject';

  @override
  String friendAddedMessage(String name) {
    return '$name added as a friend';
  }

  @override
  String get friendsSectionTitle => 'Friends';

  @override
  String get favoritesSectionTitle => 'Favorites';

  @override
  String get noFriendsYet => 'No friends yet';

  @override
  String get noFriendsHint => 'Add a friend to start chatting';

  @override
  String get noStatusMessage => 'No status message';

  @override
  String get startChat => 'Talk';

  @override
  String get addToFavorites => 'Add to Favorites';

  @override
  String get removeFromFavorites => 'Remove from Favorites';

  @override
  String get blockFriend => 'Block';

  @override
  String blockFriendConfirmTitle(String name) {
    return 'Block $name?';
  }

  @override
  String get blockFriendConfirmBody =>
      'You\'ll stop receiving their messages and profile updates. They stay in your friends list so you can unblock them later.';

  @override
  String get unblockFriend => 'Unblock';

  @override
  String get deleteFriend => 'Delete friend';

  @override
  String deleteFriendConfirmTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get deleteFriendConfirmBody =>
      'This permanently removes them from your friends list. They can send you a new friend request later.';

  @override
  String get noChatsYet => 'No conversations yet';

  @override
  String get noChatsHint => 'Messages with your friends will show up here';

  @override
  String get noMessagesYet => 'No messages yet — say hi!';

  @override
  String get typeMessageHint => 'Message';

  @override
  String get navTalk => 'Talk';

  @override
  String get navTimeline => 'Timeline';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get privateModeLabel => 'Private';

  @override
  String get globalModeLabel => 'Global';

  @override
  String get globalProfileSetupTitle => 'Global Profile';

  @override
  String get globalProfileSetupBody =>
      'Global Chat is open to anyone on the network — this identity is separate from your private, friends-only account, so a Global post can never be linked back to it.';

  @override
  String get globalProfileSetupSkip => 'Skip for now';

  @override
  String get globalProfileSetupCreate => 'Create Global Profile';

  @override
  String get globalProfileRequiredTitle => 'Global Profile required';

  @override
  String get globalProfileRequiredBody =>
      'Set up a Global Profile first to use Global Chat.';

  @override
  String get searchChannelsTitle => 'Search channels';

  @override
  String get createChannelMenuTitle => 'Create a channel';

  @override
  String get noJoinedChannelsYet =>
      'No channels yet — search to join one, or create your own';

  @override
  String get leaveChannelButton => 'Leave';

  @override
  String get leaveChannelConfirmTitle => 'Leave channel?';

  @override
  String leaveChannelConfirmBody(Object channelName) {
    return 'You\'ll stop seeing $channelName in Talk. You can rejoin it later from Search.';
  }

  @override
  String get joinedChannelsSectionTitle => 'Channels';

  @override
  String get noChannelAbout => 'No description';

  @override
  String get newChannelTitle => 'New channel';

  @override
  String get channelNameLabel => 'Channel name';

  @override
  String get channelAboutLabel => 'About (optional)';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get createButton => 'Create';

  @override
  String get showAllChannelsTooltip => 'Show all Nostr channels';

  @override
  String get showOrigilinkChannelsTooltip => 'Show OrigiLink channels only';

  @override
  String get origilinkChannelsTitle => 'OrigiLink channels';

  @override
  String get allChannelsTitle => 'All channels';

  @override
  String get noChannelsYet => 'No channels yet — create one to get started';

  @override
  String get untitledChannel => 'Untitled channel';

  @override
  String get typeChannelMessageHint => 'Message this channel';

  @override
  String get noChannelMessagesYet =>
      'No messages yet — be the first to say something';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsProfile => 'Profile';

  @override
  String get settingsRelay => 'Relay';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsAttachmentServer => 'File upload server';

  @override
  String get settingsLicenses => 'Open source licenses';

  @override
  String get attachmentServerDialogTitle => 'File upload server';

  @override
  String get attachmentServerHint => 'https://your-blossom-server.example';

  @override
  String get attachmentServerNotConfigured =>
      'Not set — set a server to send images/files';

  @override
  String get attachmentUploadFailedLabel => 'Attachment failed';

  @override
  String get attachmentServerSettingsTitle => 'File upload servers';

  @override
  String get attachmentServerDefaultBadge => 'Default';

  @override
  String get setAsDefaultServer => 'Set as default';

  @override
  String get addAttachmentServer => 'Add';

  @override
  String get attachmentServerUrlLabel => 'Server URL';

  @override
  String get invalidAttachmentServerUrl =>
      'Server URL must start with https:// or http://';

  @override
  String get noAttachmentServersYet => 'No servers configured';

  @override
  String get removeAttachmentServerConfirmTitle => 'Remove server?';

  @override
  String removeAttachmentServerConfirmBody(String url) {
    return 'Remove $url from your server list?';
  }

  @override
  String get cannotRemoveOnlyServer => 'You can\'t remove your only server';

  @override
  String get resetAttachmentServers => 'Reset to defaults';

  @override
  String get resetAttachmentServersConfirmTitle => 'Reset servers?';

  @override
  String get resetAttachmentServersConfirmBody =>
      'This replaces your server list with the default servers.';

  @override
  String get attachmentServerSwitchTitle => 'Switch upload server?';

  @override
  String attachmentServerSwitchBody(String url) {
    return 'Sending failed. Try $url instead?';
  }

  @override
  String get attachmentServerSetDefaultCheckbox =>
      'Make this the default server';

  @override
  String get attachmentServerSwitchButton => 'Switch';

  @override
  String get accountSettingsTitle => 'Account';

  @override
  String get myUid => 'My UID';

  @override
  String get uidLabel => 'UID';

  @override
  String get uidCopiedMessage => 'UID copied to clipboard';

  @override
  String get seedBackupButton => 'Backup seed phrase';

  @override
  String get seedBackupWarning =>
      'Write down these words in order and keep them somewhere safe. Anyone with this phrase can restore your account.';

  @override
  String get seedBackupOnboardingNote =>
      'You can review this phrase again anytime from Settings > Account.';

  @override
  String get seedBackupNoDefaultRelayTitle => 'Also save your relay URLs';

  @override
  String get seedBackupNoDefaultRelayBody =>
      'None of your relays are on the default list. Restoring elsewhere requires selecting the same relays this account publishes to, so write those relay URLs down too — not just this phrase.';

  @override
  String get logoutButton => 'Logout';

  @override
  String get logoutConfirmTitle => 'Logout?';

  @override
  String get logoutConfirmBody =>
      'Your account will be deleted from this device, and if you haven\'t saved your seed phrase, it can never be recovered.';

  @override
  String get deleteAccountButton => 'Delete account';

  @override
  String get deleteAccountConfirmTitle => 'Delete account?';

  @override
  String get deleteAccountConfirmBody =>
      'This permanently erases your account, including your seed phrase, from this device and from relays. It can never be recovered.';

  @override
  String get relaySettingsTitle => 'Relay settings';

  @override
  String get relayUrlLabel => 'Relay URL';

  @override
  String get addRelay => 'Add relay';

  @override
  String get removeRelay => 'Remove';

  @override
  String get editRelay => 'Edit';

  @override
  String get resetRelays => 'Reset to defaults';

  @override
  String get resetRelaysConfirmTitle => 'Reset relays?';

  @override
  String get resetRelaysConfirmBody =>
      'This replaces your relay list with the default relays.';

  @override
  String get resetButton => 'Reset';

  @override
  String get removeRelayConfirmTitle => 'Remove relay?';

  @override
  String removeRelayConfirmBody(String url) {
    return 'Remove $url from your relay list?';
  }

  @override
  String get noRelaysYet => 'No relays configured';

  @override
  String get invalidRelayUrl => 'Relay URL must start with wss:// or ws://';

  @override
  String get relayCountHint => 'Recommended: 3-5 relays';

  @override
  String get clearChatButton => 'Clear chat';

  @override
  String get clearChatConfirmTitle => 'Clear this chat?';

  @override
  String clearChatConfirmBody(String name) {
    return 'This deletes the message history with $name from this device only. They can still message you and the chat will start fresh.';
  }

  @override
  String get blockedSendConfirmTitle => 'This friend is blocked';

  @override
  String get blockedSendConfirmBody =>
      'You can\'t send messages while they\'re blocked. Unblock them now?';

  @override
  String get friendAlreadyAddedMessage =>
      'This friend is already added. Their info has been updated.';

  @override
  String get createTalkRoom => 'Create talk room';

  @override
  String get createGroup => 'Create group';

  @override
  String get groupNameLabel => 'Group name';

  @override
  String get selectMembersLabel => 'Select members';

  @override
  String groupMembersCount(int count) {
    return '$count members';
  }

  @override
  String get noGroupsYet => 'No groups yet';

  @override
  String get searchByNameHint => 'Search by name';

  @override
  String get noSearchResults => 'No matches found';

  @override
  String get editMessage => 'Edit';

  @override
  String get unsendMessage => 'Unsend';

  @override
  String get editMessageTitle => 'Edit message';

  @override
  String get unsendMessageConfirmTitle => 'Unsend this message?';

  @override
  String unsendMessageConfirmBody(String name) {
    return 'This message will be removed for both you and $name.';
  }

  @override
  String get messageEditedLabel => '(edited)';

  @override
  String get messageUnsentLabel => 'This message was unsent';

  @override
  String get hideMessage => 'Hide for me';

  @override
  String get hideMessageConfirmTitle => 'Hide this message?';

  @override
  String hideMessageConfirmBody(String name) {
    return 'This hides it for you only (across all your devices) — it stays visible to $name.';
  }

  @override
  String get replyToMessage => 'Reply';

  @override
  String replyingToLabel(String name) {
    return 'Replying to $name';
  }

  @override
  String get originalMessageUnavailable => 'Original message unavailable';

  @override
  String get youLabel => 'You';
}
