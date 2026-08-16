// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'OrigiLink';

  @override
  String get authChoiceSubtitle => '新規アカウントを作成するか、既存のアカウントを復元してください';

  @override
  String get signUpButton => '新規登録';

  @override
  String get logInButton => 'ログイン';

  @override
  String get seedPhraseLabel => 'シードフレーズ';

  @override
  String get seedPhraseHint => 'シードフレーズを入力してアカウントを復元してください';

  @override
  String get restoreInvalidSeed => '正しいシードフレーズではないようです。';

  @override
  String get restoreNoBackupFound =>
      'このシードフレーズのバックアップが見つかりませんでした。別の端末でリレー同期まで設定を完了しているか確認してください。';

  @override
  String get restoreNetworkError => 'リレーに接続できませんでした。通信状況を確認してもう一度お試しください。';

  @override
  String get profileSetupSubtitle => 'プロフィールを設定してください';

  @override
  String get displayNameLabel => '表示名';

  @override
  String get displayNameRequired => '表示名を入力してください';

  @override
  String get statusMessageLabel => 'ステータスメッセージ (任意)';

  @override
  String get continueButton => '次へ';

  @override
  String get confirmButton => '決定';

  @override
  String get setupCompleteTitle => '準備完了!';

  @override
  String setupCompleteSubtitle(String displayName) {
    return 'ようこそ、$displayName さん';
  }

  @override
  String chatListWelcome(String displayName) {
    return 'ようこそ、$displayName さん';
  }

  @override
  String get navProfileFriends => 'ホーム';

  @override
  String get editProfile => 'プロフィールを編集';

  @override
  String get addFriendByQr => 'QRコードで友達追加';

  @override
  String get addFriendTitle => '友達を追加';

  @override
  String get myQrTab => 'コード・QR';

  @override
  String get scanTab => 'コード・QRで追加';

  @override
  String get maxUsesLabel => '使用回数上限';

  @override
  String get unlimitedLabel => '無制限';

  @override
  String get customLabel => '自分で決める';

  @override
  String get validForLabel => '有効期間(日数)';

  @override
  String get generateQrButton => '生成';

  @override
  String get regenerateQrButton => '新しいコードを生成';

  @override
  String get saveQrToDeviceButton => '端末に保存';

  @override
  String get qrSavedToDeviceMessage => 'QRコードを写真に保存しました';

  @override
  String get qrSaveFailedMessage => 'QRコードを保存できませんでした';

  @override
  String get copyCodeButton => 'コードをコピー';

  @override
  String get codeCopiedMessage => 'コードをコピーしました';

  @override
  String get pasteCodeLabel => 'またはコードを貼り付け';

  @override
  String get pasteCodeHint => '招待コードをここに貼り付け';

  @override
  String get pasteCodeButton => '追加';

  @override
  String get activeInvitesTitle => '有効な招待コード';

  @override
  String get noActiveInvites => '有効な招待コードはありません';

  @override
  String invitesUsesUsed(int used, int max) {
    return '$used/$max 回使用済み';
  }

  @override
  String invitesUsesUsedUnlimited(int used) {
    return '$used回使用済み(無制限)';
  }

  @override
  String invitesExpiresIn(int days) {
    return 'あと$days日で失効';
  }

  @override
  String get revokeInvite => '無効化';

  @override
  String get scanPrompt => 'OrigiLinkのQRコードにカメラを向けてください';

  @override
  String get pickFromGallery => 'ギャラリーから選択';

  @override
  String get scanInvalidQr => 'OrigiLinkの招待コードとして読み取れませんでした';

  @override
  String get cannotAddSelfMessage => '自分自身をフレンドに追加することはできません';

  @override
  String get sendRequestConfirmTitle => 'フレンド申請を送りますか?';

  @override
  String sendRequestConfirmBody(String name) {
    return '$nameさんに自分のプロフィールを送って、追加を申請しますか?';
  }

  @override
  String get sendRequestButton => '申請を送る';

  @override
  String get requestSentMessage => 'フレンド申請を送信しました';

  @override
  String get channelAddedMessage => 'チャンネルを追加しました';

  @override
  String get friendRequestsTitle => 'フレンド申請';

  @override
  String get noFriendRequests => '保留中の申請はありません';

  @override
  String get acceptButton => '承認';

  @override
  String get rejectButton => '拒否';

  @override
  String friendAddedMessage(String name) {
    return '$nameさんをフレンドに追加しました';
  }

  @override
  String get friendsSectionTitle => '友達';

  @override
  String get favoritesSectionTitle => 'お気に入り';

  @override
  String get noFriendsYet => 'まだ友達がいません';

  @override
  String get noFriendsHint => '友達を追加してチャットを始めましょう';

  @override
  String get noStatusMessage => 'ステータスメッセージ未設定';

  @override
  String get startChat => 'トーク';

  @override
  String get joinChannelButton => '追加';

  @override
  String get addToFavorites => 'お気に入りに追加';

  @override
  String get removeFromFavorites => 'お気に入りから削除';

  @override
  String get blockFriend => 'ブロック';

  @override
  String blockFriendConfirmTitle(String name) {
    return '$nameさんをブロックしますか?';
  }

  @override
  String get blockFriendConfirmBody =>
      '友達リストから削除され、相手は新たにフレンド申請を送ることができなくなります。設定 > ブロックしたアカウントから後で元に戻せます。';

  @override
  String get unblockFriend => 'ブロック解除';

  @override
  String get noChatsYet => 'まだ会話がありません';

  @override
  String get noChatsHint => '友達とのメッセージがここに表示されます';

  @override
  String get noMessagesYet => 'まだメッセージがありません。挨拶してみましょう！';

  @override
  String get typeMessageHint => 'メッセージ';

  @override
  String get navTalk => 'トーク';

  @override
  String get navTimeline => 'タイムライン';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get privateModeLabel => 'プライベート';

  @override
  String get globalModeLabel => 'グローバル';

  @override
  String get globalProfileSetupTitle => 'グローバルプロフィール';

  @override
  String get globalProfileSetupBody =>
      'グローバルチャットはネットワーク上の誰でも見られる場所です。友達限定のプライベートなアカウントとは別のアイデンティティなので、グローバルへの投稿がプライベート側と結び付けられることはありません。';

  @override
  String get globalProfileSetupSkip => '後で設定する';

  @override
  String get globalProfileSetupCreate => 'グローバルプロフィールを作成';

  @override
  String get globalProfileRequiredTitle => 'グローバルプロフィールが必要です';

  @override
  String get globalProfileRequiredBody =>
      'グローバルチャットを使うには、先にグローバルプロフィールを作成してください。';

  @override
  String get avatarCropFailed => '画像を切り抜けませんでした。別の画像でお試しください。';

  @override
  String get talkAddSearchGlobalChannel => 'グローバルチャンネルを検索';

  @override
  String get talkAddCreateGlobalChannel => 'グローバルチャンネルを作成';

  @override
  String get globalChannelBadge => 'グローバル';

  @override
  String get todayLabel => '今日';

  @override
  String get yesterdayLabel => '昨日';

  @override
  String daysAgoLabel(int count) {
    return '$count日前';
  }

  @override
  String get searchChannelsTitle => 'チャンネルを検索';

  @override
  String get createChannelMenuTitle => 'チャンネルを作成';

  @override
  String get noJoinedChannelsYet => 'まだチャンネルがありません';

  @override
  String get noJoinedChannelsHint => '検索して参加するか、新しく作成してください';

  @override
  String get leaveChannelButton => '退出';

  @override
  String get leaveChannelConfirmTitle => 'チャンネルを退出しますか？';

  @override
  String leaveChannelConfirmBody(Object channelName) {
    return '$channelName がトークに表示されなくなります。検索から後で再参加できます。';
  }

  @override
  String get joinedChannelsSectionTitle => 'チャンネル';

  @override
  String get noChannelAbout => '説明なし';

  @override
  String get newChannelTitle => '新しいチャンネル';

  @override
  String get channelNameLabel => 'チャンネル名';

  @override
  String get channelAboutLabel => '説明(任意)';

  @override
  String get cancelButton => 'キャンセル';

  @override
  String get createButton => '作成';

  @override
  String get showAllChannelsTooltip => '全てのNostrチャンネルを表示';

  @override
  String get showOrigilinkChannelsTooltip => 'OrigiLinkのチャンネルのみ表示';

  @override
  String get channelFilterOrigilink => 'OrigiLink';

  @override
  String get channelFilterAll => 'すべて';

  @override
  String get origilinkChannelsTitle => 'OrigiLinkチャンネル';

  @override
  String get allChannelsTitle => '全てのチャンネル';

  @override
  String get noChannelsYet => 'まだチャンネルがありません。作成してみましょう';

  @override
  String get untitledChannel => '無題のチャンネル';

  @override
  String get typeChannelMessageHint => 'このチャンネルにメッセージを送る';

  @override
  String get noChannelMessagesYet => 'まだメッセージがありません。最初の投稿をしてみましょう';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsProfile => 'プロフィール';

  @override
  String get settingsRelay => 'リレー';

  @override
  String get settingsLanguage => '言語';

  @override
  String get settingsAccount => 'アカウント';

  @override
  String get settingsAttachmentServer => 'ファイル送信サーバー';

  @override
  String get settingsLicenses => 'オープンソースライセンス';

  @override
  String get settingsBlockedAccounts => 'ブロックしたアカウント';

  @override
  String get blockedAccountsEmpty => 'ブロックしたアカウントはありません';

  @override
  String get unblockConfirmTitle => 'ブロックを解除しますか?';

  @override
  String get unblockConfirmBody => 'フレンド一覧に戻り、再びチャットできるようになります。';

  @override
  String get attachmentServerDialogTitle => 'ファイル送信サーバー';

  @override
  String get attachmentServerHint => 'https://your-blossom-server.example';

  @override
  String get attachmentServerNotConfigured => '未設定 — 画像・ファイルを送るにはサーバーを設定してください';

  @override
  String get attachmentUploadFailedLabel => '送信に失敗しました';

  @override
  String get attachmentServerSettingsTitle => 'ファイル送信サーバー';

  @override
  String get attachmentServerDefaultBadge => 'デフォルト';

  @override
  String get setAsDefaultServer => 'デフォルトにする';

  @override
  String get addAttachmentServer => '追加';

  @override
  String get attachmentServerUrlLabel => 'サーバーURL';

  @override
  String get invalidAttachmentServerUrl =>
      'サーバーURLはhttps://またはhttp://で始まる必要があります';

  @override
  String get noAttachmentServersYet => 'サーバーが設定されていません';

  @override
  String get removeAttachmentServerConfirmTitle => 'サーバーを削除しますか?';

  @override
  String removeAttachmentServerConfirmBody(String url) {
    return '$url をサーバー一覧から削除しますか?';
  }

  @override
  String get cannotRemoveOnlyServer => '唯一のサーバーは削除できません';

  @override
  String get resetAttachmentServers => '初期値に戻す';

  @override
  String get resetAttachmentServersConfirmTitle => 'サーバーをリセットしますか?';

  @override
  String get resetAttachmentServersConfirmBody => '現在のサーバー一覧が初期値に置き換わります。';

  @override
  String get attachmentServerSwitchTitle => 'アップロードサーバーを切り替えますか?';

  @override
  String attachmentServerSwitchBody(String url) {
    return '送信に失敗しました。$url で試しますか?';
  }

  @override
  String get attachmentServerSetDefaultCheckbox => 'このサーバーをデフォルトサーバーにしますか?';

  @override
  String get attachmentServerSwitchButton => '切り替える';

  @override
  String get accountSettingsTitle => 'アカウント';

  @override
  String get myUid => '自分のUID';

  @override
  String get uidLabel => 'UID';

  @override
  String get uidCopiedMessage => 'UIDをコピーしました';

  @override
  String get seedBackupButton => 'シードフレーズをバックアップ';

  @override
  String get seedBackupWarning =>
      'この単語を順番通りに書き留め、安全な場所に保管してください。このフレーズを知っている人は誰でもアカウントを復元できます。';

  @override
  String get seedBackupOnboardingNote => 'このフレーズは、いつでも設定 > アカウントから確認できます。';

  @override
  String get seedBackupNoDefaultRelayTitle => 'リレーのURLも保存してください';

  @override
  String get seedBackupNoDefaultRelayBody =>
      '現在のリレーはデフォルトのものを一つも含んでいません。別の端末で復元する際はこのアカウントが公開しているリレーと同じものを選ぶ必要があるため、このフレーズだけでなくリレーのURLも書き留めておいてください。';

  @override
  String get logoutButton => 'ログアウト';

  @override
  String get logoutConfirmTitle => 'ログアウトしますか?';

  @override
  String get logoutConfirmBody =>
      'アカウントはこの端末から削除され、シードフレーズを保存していない場合、二度と復元できなくなります。';

  @override
  String get deleteAccountButton => 'アカウントを削除';

  @override
  String get deleteAccountConfirmTitle => 'アカウントを削除しますか?';

  @override
  String get deleteAccountConfirmBody =>
      'シードフレーズを含め、アカウントがこの端末とリレーの両方から完全に削除され、二度と復元できなくなります。';

  @override
  String get relaySettingsTitle => 'リレー設定';

  @override
  String get relayUrlLabel => 'リレーURL';

  @override
  String get addRelay => 'リレーを追加';

  @override
  String get removeRelay => '削除';

  @override
  String get editRelay => '編集';

  @override
  String get resetRelays => '初期値に戻す';

  @override
  String get resetRelaysConfirmTitle => 'リレーをリセットしますか?';

  @override
  String get resetRelaysConfirmBody => '現在のリレー一覧が初期値に置き換わります。';

  @override
  String get resetButton => 'リセット';

  @override
  String get removeRelayConfirmTitle => 'リレーを削除しますか?';

  @override
  String removeRelayConfirmBody(String url) {
    return '$url をリレー一覧から削除しますか?';
  }

  @override
  String get noRelaysYet => 'リレーが設定されていません';

  @override
  String get invalidRelayUrl => 'リレーURLはwss://またはws://で始まる必要があります';

  @override
  String get relayCountHint => '推奨: 3〜5個程度';

  @override
  String get clearChatButton => 'トークを削除';

  @override
  String get clearChatConfirmTitle => 'このトークを削除しますか?';

  @override
  String clearChatConfirmBody(String name) {
    return '$nameさんとのメッセージ履歴がこの端末からのみ削除されます。相手からは引き続きメッセージを送ることができ、トークは新しく始まります。';
  }

  @override
  String get blockedSendConfirmTitle => '現在ブロック中です';

  @override
  String get blockedSendConfirmBody => 'ブロック中はメッセージを送信できません。ブロックを解除しますか?';

  @override
  String get friendAlreadyAddedMessage => 'このフレンドは追加済みです。相手のユーザー情報を更新しました。';

  @override
  String get createTalkRoom => 'トークルームを作成';

  @override
  String get createGroup => 'グループを作成';

  @override
  String get groupNameLabel => 'グループ名';

  @override
  String get selectMembersLabel => 'メンバーを選択';

  @override
  String groupMembersCount(int count) {
    return 'メンバー$count人';
  }

  @override
  String get noGroupsYet => 'まだグループがありません';

  @override
  String get searchByNameHint => '名前で検索';

  @override
  String get noSearchResults => '該当する友達が見つかりません';

  @override
  String get editMessage => '編集';

  @override
  String get unsendMessage => '送信取り消し';

  @override
  String get editMessageTitle => 'メッセージを編集';

  @override
  String get unsendMessageConfirmTitle => '送信を取り消しますか?';

  @override
  String unsendMessageConfirmBody(String name) {
    return 'このメッセージは$nameさんの画面からも削除されます。';
  }

  @override
  String get messageEditedLabel => '(編集済み)';

  @override
  String get messageUnsentLabel => 'このメッセージは送信取り消しされました';

  @override
  String get hideMessage => '自分の画面から非表示';

  @override
  String get hideMessageConfirmTitle => 'このメッセージを非表示にしますか?';

  @override
  String hideMessageConfirmBody(String name) {
    return '自分のみ非表示になります。$nameさんやトークルーム内の他のユーザーには引き続き表示されます。';
  }

  @override
  String get replyToMessage => '返信';

  @override
  String replyingToLabel(String name) {
    return '$nameさんに返信';
  }

  @override
  String get originalMessageUnavailable => '元のメッセージは表示できません';

  @override
  String get youLabel => '自分';
}
