use crate::api::account;
use crate::api::chat;
use crate::api::config;
use crate::api::friends;
use crate::api::group_ratchet;
use crate::api::groups;
use crate::api::invites;
use crate::api::keys::{derive_contact_keys, derive_keys, derive_uid};
use crate::api::ratchet;
use crate::api::relay;
use crate::api::requests;
use crate::frb_generated::StreamSink;
use crate::relay_pool;
use base64::Engine;
use futures_util::future::join_all;
use nostr::event::{Event, EventBuilder, Kind, Tag};
use nostr::nips::nip09::EventDeletionRequest;
use nostr::nips::nip44;
use nostr::types::Timestamp;
use nostr::{Filter, PublicKey};
use sha2::{Digest, Sha256};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::runtime::Runtime;

pub(crate) fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

/// Bumped every time [subscribe_friend_events] is called (each Dart-side
/// resubscribe, e.g. on every app-lifecycle resume — including trivial
/// pause/resume cycles like a permission dialog or the photo picker, not
/// just real backgrounding). The Dart side cancels its old `StreamSubscription`
/// immediately, but that only stops *new* items from being delivered to
/// Dart — it does nothing to stop the old Rust task, which keeps its relay
/// websocket open and keeps watching the same pubkeys until it happens to
/// receive another matching event and finds out (via `sink.add(..).is_err()`)
/// that nobody's listening anymore.
///
/// Without this guard, that stale task would still fully process any event
/// it receives in the meantime — mutating `friends.json` etc. — before
/// discovering it should stop, so the Dart side never learns the state
/// changed (a friend-accept event could be silently applied to disk with no
/// live UI update, only surfacing after the next cold start or resume).
/// Each spawned task captures the generation it started with and checks it
/// on every event; once superseded, it drops the event and breaks instead of
/// mutating anything, so the newer subscription (which the relay will
/// happily replay the same event to — the filters carry no `since`) is the
/// only one that can ever win.
fn subscription_generation() -> &'static std::sync::atomic::AtomicU64 {
    static GEN: OnceLock<std::sync::atomic::AtomicU64> = OnceLock::new();
    GEN.get_or_init(|| std::sync::atomic::AtomicU64::new(0))
}

/// Records that a friend-event `EventId` has been processed, returning
/// `true` the first time (caller should process it) and `false` on every
/// later call for the same id (caller should skip it). The same event
/// reaches [listen_for_friend_events] once per relay it matched on — every
/// relay in the account's list races to deliver it — plus again on every
/// periodic resubscribe, since these filters carry no `since`. Without this,
/// each redundant delivery independently re-ran the full
/// mutate-local-storage-then-publish-a-backup-of-it flow, and those
/// concurrent publishes (and their self-echoes) could race and clobber one
/// another's write. A capped ring keeps this from growing unbounded over a
/// long-lived session — old entries fall off, but by the time that matters
/// the relay's own dedup (or a periodic resubscribe replay) would have long
/// since made the point moot anyway.
fn mark_event_seen(id: nostr::EventId) -> bool {
    const CAP: usize = 4096;
    struct Seen {
        set: std::collections::HashSet<nostr::EventId>,
        order: std::collections::VecDeque<nostr::EventId>,
    }
    static SEEN: OnceLock<Mutex<Seen>> = OnceLock::new();
    let mutex = SEEN.get_or_init(|| {
        Mutex::new(Seen { set: std::collections::HashSet::new(), order: std::collections::VecDeque::new() })
    });
    let mut seen = mutex.lock().unwrap();
    if !seen.set.insert(id) {
        return false;
    }
    seen.order.push_back(id);
    if seen.order.len() > CAP {
        if let Some(oldest) = seen.order.pop_front() {
            seen.set.remove(&oldest);
        }
    }
    true
}

/// Identifier tags for the account backup's parameterized-replaceable
/// events (NIP-33 / kind 30078). Split into independent slots — rather
/// than one big payload — so a small, frequent change (e.g. editing the
/// status message) never has to re-publish the much larger avatar or
/// friends-list payloads: each slot is only republished when its own data
/// actually changes, and a relay always keeps the newest event per slot.
const ACCOUNT_BACKUP_KIND: Kind = Kind::Custom(30078);
const ACCOUNT_TEXT_D_TAG: &str = "origilink-account-text";
const ACCOUNT_AVATAR_D_TAG: &str = "origilink-account-avatar";
const ACCOUNT_RELAYS_D_TAG: &str = "origilink-account-relays";
const ACCOUNT_FRIENDS_D_TAG: &str = "origilink-account-friends";
/// Blocked pubkeys, invites, pending outgoing/incoming friend requests, and
/// chat read-state are all synced the same way as the four slots above —
/// deliberately excluding `account_sync_state.json` itself, which tracks
/// *this device's* progress applying these backups and would be
/// meaningless (or actively harmful — see [SyncState]) to sync.
const ACCOUNT_BLOCKED_D_TAG: &str = "origilink-account-blocked";
const ACCOUNT_INVITES_D_TAG: &str = "origilink-account-invites";
const ACCOUNT_OUTGOING_D_TAG: &str = "origilink-account-outgoing";
const ACCOUNT_INCOMING_D_TAG: &str = "origilink-account-incoming";
const ACCOUNT_READSTATE_D_TAG: &str = "origilink-account-readstate";
/// Personal app preferences (e.g. language) — deliberately kept out of
/// `FriendPayload`/every friend-facing event; this slot is the *only*
/// place this data is ever sent, and only self-encrypted.
const ACCOUNT_CONFIG_D_TAG: &str = "origilink-account-config";
const ACCOUNT_CHATSTARTED_D_TAG: &str = "origilink-account-chatstarted";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Serialize, Deserialize)]
struct TextBackupPayload {
    display_name: String,
    status_message: String,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct AvatarBackupPayload {
    avatar_base64: String,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct RelaysBackupPayload {
    relays: Vec<String>,
    updated_at: i64,
}

/// One friend as carried in the friends-list backup — enough for another
/// device to derive the same per-relationship key (`my_account_index`) and
/// resume talking to (and pulling chat history for) this friend on its
/// own. Deliberately excludes the avatar (each device re-caches it from
/// the friend directly, the same way it originally arrived).
#[derive(Serialize, Deserialize, Clone)]
pub struct FriendBackupEntry {
    pub pubkey: String,
    #[serde(default)]
    pub uid: String,
    pub my_account_index: u32,
    pub display_name: String,
    pub status_message: String,
    pub relays: Vec<String>,
    #[serde(default)]
    pub is_favorite: bool,
}

#[derive(Serialize, Deserialize)]
struct FriendsBackupPayload {
    friends: Vec<FriendBackupEntry>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct BlockedBackupPayload {
    blocked: Vec<String>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct InvitesBackupPayload {
    next_account_index: u32,
    invites: Vec<invites::Invite>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct OutgoingBackupPayload {
    requests: Vec<requests::OutgoingRequest>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct IncomingBackupPayload {
    requests: Vec<requests::IncomingRequest>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct ReadStateBackupPayload {
    state: std::collections::HashMap<String, i64>,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct ConfigBackupPayload {
    config: config::AppConfig,
    updated_at: i64,
}

#[derive(Serialize, Deserialize)]
struct ChatStartedBackupPayload {
    started: Vec<String>,
    updated_at: i64,
}

/// Account text (display name / status) decrypted from a relay-hosted backup.
pub struct RemoteAccount {
    pub display_name: String,
    pub status_message: String,
    pub updated_at: i64,
}

pub struct RemoteAvatar {
    pub avatar_base64: String,
    pub updated_at: i64,
}

pub struct RemoteRelays {
    pub relays: Vec<String>,
    pub updated_at: i64,
}

pub struct RemoteFriends {
    pub friends: Vec<FriendBackupEntry>,
    pub updated_at: i64,
}

fn encrypt_self(keys: &nostr::Keys, plaintext: String) -> Result<String, String> {
    nip44::encrypt(keys.secret_key(), &keys.public_key(), plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())
}

fn publish_backup_event(
    keys: &nostr::Keys,
    relay_urls: &[String],
    d_tag: &str,
    plaintext: String,
    updated_at: i64,
) -> Result<(), String> {
    // Only safe to call from a plain (non-async, not-already-on-`runtime()`)
    // context — e.g. the `pub fn`s Dart calls directly. `block_on` here
    // starts a *nested* entry into the same shared runtime; Tokio panics
    // immediately ("Cannot start a runtime from within a runtime") if this
    // is ever called from a task already running on it, such as
    // `listen_for_friend_events`. That panic is silent (no crash, nothing
    // in logcat — it just ends the task), which is exactly what made the
    // friend-request/chat listener for a relay quietly stop processing any
    // further events the moment it replayed a backlog request. Async
    // call sites must use [publish_backup_event_async] instead.
    runtime().block_on(publish_backup_event_async(keys, relay_urls, d_tag, plaintext, updated_at))
}

async fn publish_backup_event_async(
    keys: &nostr::Keys,
    relay_urls: &[String],
    d_tag: &str,
    plaintext: String,
    updated_at: i64,
) -> Result<(), String> {
    let encrypted = encrypt_self(keys, plaintext)?;
    let event = EventBuilder::new(ACCOUNT_BACKUP_KIND, encrypted)
        .tag(Tag::identifier(d_tag))
        .custom_created_at(Timestamp::from(updated_at.max(0) as u64))
        .sign_with_keys(keys)
        .map_err(|e| e.to_string())?;
    publish_to_relays(relay_urls, &event).await
}

/// Encrypts the given account text (NIP-44, to self) and publishes it as a
/// kind-30078 parameterized-replaceable event, signed with the Nostr keys
/// derived from `mnemonic` (NIP-06). The seed phrase itself is never
/// transmitted — only the deterministically-derived public identity and
/// the encrypted payload.
pub fn publish_account_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
    display_name: String,
    status_message: String,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let payload = TextBackupPayload { display_name, status_message, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_TEXT_D_TAG, plaintext, updated_at)
}

/// Fetches and decrypts the newest account text backup for `mnemonic`'s
/// derived identity across `relay_urls`. Returns `None` if no relay has
/// one yet.
pub fn fetch_account_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
) -> Result<Option<RemoteAccount>, String> {
    let keys = derive_keys(&mnemonic)?;
    let event = runtime()
        .block_on(fetch_latest_backup_event(&relay_urls, &keys.public_key(), ACCOUNT_TEXT_D_TAG))?;
    let Some(event) = event else {
        return Ok(None);
    };
    let decrypted = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        .map_err(|e| e.to_string())?;
    let payload: TextBackupPayload = serde_json::from_str(&decrypted).map_err(|e| e.to_string())?;
    Ok(Some(RemoteAccount {
        display_name: payload.display_name,
        status_message: payload.status_message,
        updated_at: payload.updated_at,
    }))
}

/// Publishes the account avatar as its own backup slot — call only when
/// the avatar actually changed, so it isn't re-sent alongside every text
/// edit.
pub fn publish_account_avatar_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
    avatar_path: String,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let avatar_base64 =
        read_avatar_base64(&Some(avatar_path)).ok_or("failed to read avatar file")?;
    let payload = AvatarBackupPayload { avatar_base64, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_AVATAR_D_TAG, plaintext, updated_at)
}

pub fn fetch_account_avatar_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
) -> Result<Option<RemoteAvatar>, String> {
    let keys = derive_keys(&mnemonic)?;
    let event = runtime()
        .block_on(fetch_latest_backup_event(&relay_urls, &keys.public_key(), ACCOUNT_AVATAR_D_TAG))?;
    let Some(event) = event else {
        return Ok(None);
    };
    let decrypted = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        .map_err(|e| e.to_string())?;
    let payload: AvatarBackupPayload = serde_json::from_str(&decrypted).map_err(|e| e.to_string())?;
    Ok(Some(RemoteAvatar { avatar_base64: payload.avatar_base64, updated_at: payload.updated_at }))
}

/// Publishes the account's relay list as its own backup slot — so
/// restoring on another device can pick up the full relay list instead of
/// requiring it to be re-entered by hand.
pub fn publish_account_relays_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
    relays: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let payload = RelaysBackupPayload { relays, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_RELAYS_D_TAG, plaintext, updated_at)
}

pub fn fetch_account_relays_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
) -> Result<Option<RemoteRelays>, String> {
    let keys = derive_keys(&mnemonic)?;
    let event = runtime()
        .block_on(fetch_latest_backup_event(&relay_urls, &keys.public_key(), ACCOUNT_RELAYS_D_TAG))?;
    let Some(event) = event else {
        return Ok(None);
    };
    let decrypted = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        .map_err(|e| e.to_string())?;
    let payload: RelaysBackupPayload = serde_json::from_str(&decrypted).map_err(|e| e.to_string())?;
    Ok(Some(RemoteRelays { relays: payload.relays, updated_at: payload.updated_at }))
}

/// Publishes the local friends list (pubkey/account-index/display info,
/// no avatars) as its own backup slot. Call after any change to the
/// friends list (add, accept, favorite, block, delete) so another device
/// can reconstruct the same per-relationship keys and — since chat history
/// is just each device independently pulling and unwrapping the Gift Wraps
/// addressed to those keys — pick up existing conversations too.
pub fn publish_account_friends_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let friends = friends::load_friends(storage_dir)
        .into_iter()
        .map(|f| FriendBackupEntry {
            pubkey: f.pubkey,
            uid: f.uid,
            my_account_index: f.my_account_index,
            display_name: f.display_name,
            status_message: f.status_message,
            relays: f.relays,
            is_favorite: f.is_favorite,
        })
        .collect();
    let payload = FriendsBackupPayload { friends, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_FRIENDS_D_TAG, plaintext, updated_at)
}

pub fn fetch_account_friends_backup(
    mnemonic: String,
    relay_urls: Vec<String>,
) -> Result<Option<RemoteFriends>, String> {
    let keys = derive_keys(&mnemonic)?;
    let event = runtime()
        .block_on(fetch_latest_backup_event(&relay_urls, &keys.public_key(), ACCOUNT_FRIENDS_D_TAG))?;
    let Some(event) = event else {
        return Ok(None);
    };
    let decrypted = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        .map_err(|e| e.to_string())?;
    let payload: FriendsBackupPayload = serde_json::from_str(&decrypted).map_err(|e| e.to_string())?;
    Ok(Some(RemoteFriends { friends: payload.friends, updated_at: payload.updated_at }))
}

/// Publishes the blocked-pubkey list as its own backup slot — call after
/// [friends::block_pubkey]/[friends::unblock_pubkey] so a block (or
/// unblock) takes effect on every device signed into this account, not
/// just the one it was done on.
pub fn publish_account_blocked_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let blocked = friends::load_blocked(&storage_dir);
    let payload = BlockedBackupPayload { blocked, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let result = publish_backup_event(&keys, &relay_urls, ACCOUNT_BLOCKED_D_TAG, plaintext, updated_at);
    // See the comment on `bump_local_watermark`.
    bump_local_watermark(&storage_dir, updated_at, |s| &mut s.blocked_updated_at);
    result
}

/// Publishes the invite list (and the shared `account` index counter) as
/// its own backup slot — call after creating/revoking an invite, so a QR
/// code shown from any device is recognized (and correctly tracks
/// use-count/revocation) from every device.
pub fn publish_account_invites_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let next_account_index = invites::next_account_index(&storage_dir);
    let invites = invites::list_invites(storage_dir.clone());
    let payload = InvitesBackupPayload { next_account_index, invites, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let result = publish_backup_event(&keys, &relay_urls, ACCOUNT_INVITES_D_TAG, plaintext, updated_at);
    // See the comment on `bump_local_watermark` — without this, a
    // just-created invite can vanish locally moments after being created
    // (a same-second self-echo of a stale variant silently overwriting
    // invites.json), dropping it from the live subscription's watch list.
    bump_local_watermark(&storage_dir, updated_at, |s| &mut s.invites_updated_at);
    result
}

/// Internal counterpart of the two functions above for the outgoing/
/// incoming friend-request lists, called directly by this module right
/// after each mutation (it already has `mnemonic`/`storage_dir`/relays in
/// scope there, unlike blocked/invites which are mutated from Dart).
fn publish_account_outgoing_backup(mnemonic: &str, storage_dir: &str, relay_urls: &[String]) {
    runtime().block_on(publish_account_outgoing_backup_async(mnemonic, storage_dir, relay_urls));
}

/// Async counterpart of [publish_account_outgoing_backup] — call this one
/// (with `.await`) from code already running on `runtime()`, such as
/// `listen_for_friend_events`. See the comment on `publish_backup_event`
/// for why the sync/`block_on` version must never be called from there.
async fn publish_account_outgoing_backup_async(mnemonic: &str, storage_dir: &str, relay_urls: &[String]) {
    let Ok(keys) = derive_keys(mnemonic) else { return };
    let requests = requests::load(storage_dir);
    let updated_at = now();
    let payload = OutgoingBackupPayload { requests, updated_at };
    if let Ok(plaintext) = serde_json::to_string(&payload) {
        let _ =
            publish_backup_event_async(&keys, relay_urls, ACCOUNT_OUTGOING_D_TAG, plaintext, updated_at)
                .await;
    }
    // See the matching comment in `publish_account_invites_backup`: bump
    // the local watermark immediately so a same-second self-echo (e.g. from
    // this same event being received redundantly on multiple relays, each
    // independently republishing this backup) can't overwrite a write this
    // call — or a concurrent one — just made.
    bump_local_watermark(storage_dir, updated_at, |s| &mut s.outgoing_updated_at);
}

fn publish_account_incoming_backup(mnemonic: &str, storage_dir: &str, relay_urls: &[String]) {
    runtime().block_on(publish_account_incoming_backup_async(mnemonic, storage_dir, relay_urls));
}

/// Async counterpart of [publish_account_incoming_backup] — see
/// [publish_account_outgoing_backup_async]'s doc comment.
async fn publish_account_incoming_backup_async(mnemonic: &str, storage_dir: &str, relay_urls: &[String]) {
    let Ok(keys) = derive_keys(mnemonic) else { return };
    let requests = requests::load_incoming(storage_dir);
    let updated_at = now();
    let payload = IncomingBackupPayload { requests, updated_at };
    if let Ok(plaintext) = serde_json::to_string(&payload) {
        let _ =
            publish_backup_event_async(&keys, relay_urls, ACCOUNT_INCOMING_D_TAG, plaintext, updated_at)
                .await;
    }
    bump_local_watermark(storage_dir, updated_at, |s| &mut s.incoming_updated_at);
}

/// Bumps a `SyncState` timestamp field to `updated_at` if it isn't already
/// at least that new, and saves. See the comment in
/// `publish_account_invites_backup` for why every local
/// publish-a-backup-of-my-own-mutation call needs this: `created_at` has
/// whole-second resolution, so a same-second self-echo of *any* content
/// variant for that backup slot would otherwise be free to silently
/// overwrite the local write this call just made.
fn bump_local_watermark(storage_dir: &str, updated_at: i64, field: impl FnOnce(&mut SyncState) -> &mut i64) {
    let mut state = load_sync_state(storage_dir);
    let slot = field(&mut state);
    if updated_at > *slot {
        *slot = updated_at;
        save_sync_state(storage_dir, &state);
    }
}

/// Publishes the chat read-state map (friend pubkey -> last-read
/// timestamp) as its own backup slot — call after [chat::mark_thread_read]
/// so unread counts stay consistent across devices instead of a thread
/// read on one device still showing unread on another.
pub fn publish_account_readstate_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let state = chat::read_state_snapshot(&storage_dir);
    let payload = ReadStateBackupPayload { state, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_READSTATE_D_TAG, plaintext, updated_at)
}

/// Publishes personal app preferences (e.g. language) as their own backup
/// slot — call after changing them, so the choice follows this account to
/// every device instead of resetting to "follow device locale" on each
/// one. Never included in any friend-facing payload.
pub fn publish_account_config_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let config = config::load_config(storage_dir);
    let payload = ConfigBackupPayload { config, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_CONFIG_D_TAG, plaintext, updated_at)
}

/// Publishes the set of friends whose chat thread has been explicitly
/// started as its own backup slot — call after [chat::mark_chat_started],
/// so a thread started on one device shows up in the Talk tab on every
/// device signed into this account.
pub fn publish_account_chatstarted_backup(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    updated_at: i64,
) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    let started = chat::started_snapshot(&storage_dir);
    let payload = ChatStartedBackupPayload { started, updated_at };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    publish_backup_event(&keys, &relay_urls, ACCOUNT_CHATSTARTED_D_TAG, plaintext, updated_at)
}

/// Requests relays to erase every one of this account's backup slots
/// (NIP-09 deletion request). A no-op per-slot if that slot was never
/// published.
pub fn delete_account_backup(mnemonic: String, relay_urls: Vec<String>) -> Result<(), String> {
    let keys = derive_keys(&mnemonic)?;
    runtime().block_on(async {
        for d_tag in [
            ACCOUNT_TEXT_D_TAG,
            ACCOUNT_AVATAR_D_TAG,
            ACCOUNT_RELAYS_D_TAG,
            ACCOUNT_FRIENDS_D_TAG,
            ACCOUNT_BLOCKED_D_TAG,
            ACCOUNT_INVITES_D_TAG,
            ACCOUNT_OUTGOING_D_TAG,
            ACCOUNT_INCOMING_D_TAG,
            ACCOUNT_READSTATE_D_TAG,
            ACCOUNT_CONFIG_D_TAG,
            ACCOUNT_CHATSTARTED_D_TAG,
        ] {
            let Some(event) = fetch_latest_backup_event(&relay_urls, &keys.public_key(), d_tag).await?
            else {
                continue;
            };
            let deletion = EventBuilder::delete(EventDeletionRequest::new().id(event.id))
                .sign_with_keys(&keys)
                .map_err(|e| e.to_string())?;
            publish_to_relays(&relay_urls, &deletion).await?;
        }
        Ok(())
    })
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

const FRIEND_REQUEST_KIND: Kind = Kind::Custom(30110);
const FRIEND_ACCEPT_KIND: Kind = Kind::Custom(30111);
const FRIEND_PROFILE_UPDATE_KIND: Kind = Kind::Custom(30112);
const FRIEND_D_TAG: &str = "origilink-friend";

#[derive(Serialize, Deserialize)]
struct FriendPayload {
    /// The sender's stable account UID (see `keys::derive_uid`) — constant
    /// across every relationship, unlike the event's signing pubkey.
    #[serde(default)]
    uid: String,
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    /// The sender's avatar image, base64-encoded, if they have one set.
    /// Sent as raw bytes (not a URL) since there's no shared hosting —
    /// each side caches its own local copy on receipt.
    #[serde(default)]
    avatar_base64: Option<String>,
    /// When this payload was built — lets the recipient reject a
    /// reordered older event instead of overwriting newer info with it.
    #[serde(default)]
    updated_at: i64,
}

/// Reads `avatar_path` (if set) and base64-encodes its bytes for inclusion
/// in a [FriendPayload]. Silently omitted if the file can't be read.
fn read_avatar_base64(avatar_path: &Option<String>) -> Option<String> {
    let path = avatar_path.as_ref()?;
    let bytes = std::fs::read(path).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// Decodes a base64 avatar payload and caches it to disk under
/// `storage_dir/friend_avatars/<pubkey>_<content-hash>`, returning the local
/// path. The hash suffix (rather than a fixed `<pubkey>` path) matters: the
/// Flutter side displays this via `FileImage(File(path))`, which Flutter's
/// `ImageCache` keys purely by path string — reusing the same path on every
/// update meant a changed avatar never actually got redrawn, since Flutter
/// kept serving the previously-decoded bitmap for that path. Stale
/// differently-hashed files for the same friend are cleaned up so this
/// doesn't grow unbounded. Silently returns `None` on any failure — avatar
/// sync is best-effort.
fn save_friend_avatar(storage_dir: &str, pubkey: &str, avatar_base64: &Option<String>) -> Option<String> {
    let encoded = avatar_base64.as_ref()?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).ok()?;
    let dir = Path::new(storage_dir).join("friend_avatars");
    std::fs::create_dir_all(&dir).ok()?;
    let hash = hex::encode(Sha256::digest(&bytes));
    let file_name = format!("{pubkey}_{hash}");
    let path = dir.join(&file_name);
    std::fs::write(&path, bytes).ok()?;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let prefix = format!("{pubkey}_");
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with(&prefix) && name != file_name {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    Some(path.to_string_lossy().to_string())
}


/// A pending incoming friend request, decrypted and ready to show the user.
pub struct PendingFriendRequest {
    /// Which of our invites this request was sent to.
    pub invite_account_index: u32,
    /// The requester's contact pubkey (hex) — distinct per relationship.
    pub pubkey: String,
    /// The requester's stable account UID (see `keys::derive_uid`).
    pub uid: String,
    pub display_name: String,
    pub status_message: String,
    pub relays: Vec<String>,
    /// Base64-encoded avatar image, if the requester has one — passed
    /// through unchanged so `accept_friend_request` can cache it.
    pub avatar_base64: Option<String>,
}

/// The data a "my QR" screen encodes: enough for a scanner to send a
/// friend request without any prior relay round-trip. Shown in person, so
/// including the display name/status here isn't a public disclosure the
/// way publishing them to a relay would be.
#[derive(Serialize, Deserialize)]
pub struct InviteQrPayload {
    pub pubkey: String,
    pub relays: Vec<String>,
    pub display_name: String,
    pub status_message: String,
    /// The inviter's stable account UID (see `keys::derive_uid`). Lets a
    /// scanner recognize "I already have this account as a friend" right
    /// at scan time — before sending a request and waiting for an accept
    /// round-trip — even though `pubkey` above is a fresh per-invite key
    /// that won't match any existing friend entry.
    #[serde(default)]
    pub uid: String,
}

/// Builds the QR payload (as JSON) for the given invite's account index.
pub fn build_invite_qr_payload(
    mnemonic: String,
    storage_dir: String,
    account_index: u32,
) -> Result<String, String> {
    let keys = derive_contact_keys(&mnemonic, account_index)?;
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let relays = relay::load_relay_list(storage_dir).urls;
    let payload = InviteQrPayload {
        pubkey: keys.public_key().to_hex(),
        relays,
        display_name: my_account.display_name,
        status_message: my_account.status_message,
        uid: derive_uid(&mnemonic)?,
    };
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

/// Parses a scanned QR's JSON payload back into its fields.
pub fn parse_invite_qr_payload(data: String) -> Result<InviteQrPayload, String> {
    serde_json::from_str(&data).map_err(|e| e.to_string())
}

/// Sends a friend request to whichever invite `invite_pubkey`/`invite_relays`
/// (scanned from someone's QR code) describe. Mints a fresh per-relationship
/// key for this contact — distinct from our account identity and every
/// other friend's key — and remembers where to look for their acceptance.
pub fn send_friend_request(
    mnemonic: String,
    storage_dir: String,
    invite_pubkey: String,
    invite_relays: Vec<String>,
) -> Result<(), String> {
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;

    let index = invites::allocate_account_index(&storage_dir)?;
    let keys = derive_contact_keys(&mnemonic, index)?;
    let target_pubkey = PublicKey::from_hex(&invite_pubkey).map_err(|e| e.to_string())?;

    let payload = FriendPayload {
        uid: derive_uid(&mnemonic)?,
        display_name: my_account.display_name,
        status_message: my_account.status_message,
        relays: my_relays.clone(),
        avatar_base64: read_avatar_base64(&my_account.avatar_path),
        updated_at: now(),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(keys.secret_key(), &target_pubkey, plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())?;

    let event = EventBuilder::new(FRIEND_REQUEST_KIND, encrypted)
        .tag(Tag::identifier(FRIEND_D_TAG))
        .tag(Tag::public_key(target_pubkey))
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    runtime().block_on(publish_to_relays(&invite_relays, &event))?;

    requests::add(&storage_dir, index, invite_pubkey, invite_relays)?;
    publish_account_outgoing_backup(&mnemonic, &storage_dir, &my_relays);
    Ok(())
}

/// Reads pending incoming friend requests from local storage — persisted
/// as they arrive over the live subscription (see `listen_for_friend_events`),
/// so this never needs to touch a relay. Already-known friends and blocked
/// pubkeys are filtered out (in case a request lingered from before a
/// block/add happened elsewhere).
pub fn load_pending_friend_requests(storage_dir: String) -> Vec<PendingFriendRequest> {
    let known: std::collections::HashSet<String> = friends::load_friends(storage_dir.clone())
        .into_iter()
        .map(|f| f.pubkey)
        .chain(friends::load_blocked(&storage_dir))
        .collect();

    requests::load_incoming(&storage_dir)
        .into_iter()
        .filter(|r| !known.contains(&r.pubkey))
        .map(|r| PendingFriendRequest {
            invite_account_index: r.invite_account_index,
            pubkey: r.pubkey,
            uid: r.uid,
            display_name: r.display_name,
            status_message: r.status_message,
            relays: r.relays,
            avatar_base64: r.avatar_base64,
        })
        .collect()
}

/// Accepts a pending friend request: mints a fresh per-relationship key,
/// tells the requester about it (encrypted to their contact pubkey,
/// published to their relays), and saves them locally as a friend.
///
/// Returns `true` if the requester's UID matched an existing friend (they
/// re-friended us under a new relationship key) — that old entry was
/// merged into this one rather than creating a duplicate, so the caller
/// can tell the user "already a friend, info updated".
pub fn accept_friend_request(
    mnemonic: String,
    storage_dir: String,
    invite_account_index: u32,
    requester_pubkey: String,
    requester_uid: String,
    requester_display_name: String,
    requester_status_message: String,
    requester_relays: Vec<String>,
    requester_avatar_base64: Option<String>,
) -> Result<bool, String> {
    let my_account = account::load_account(storage_dir.clone()).ok_or("no local account")?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;

    let index = invites::allocate_account_index(&storage_dir)?;
    let keys = derive_contact_keys(&mnemonic, index)?;
    let requester = PublicKey::from_hex(&requester_pubkey).map_err(|e| e.to_string())?;

    let payload = FriendPayload {
        uid: derive_uid(&mnemonic)?,
        display_name: my_account.display_name,
        status_message: my_account.status_message,
        relays: my_relays.clone(),
        avatar_base64: read_avatar_base64(&my_account.avatar_path),
        updated_at: now(),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let encrypted = nip44::encrypt(keys.secret_key(), &requester, plaintext, nip44::Version::V2)
        .map_err(|e| e.to_string())?;

    let event = EventBuilder::new(FRIEND_ACCEPT_KIND, encrypted)
        .tag(Tag::identifier(FRIEND_D_TAG))
        .tag(Tag::public_key(requester))
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    runtime().block_on(publish_to_relays(&requester_relays, &event))?;

    invites::record_invite_use(storage_dir.clone(), invite_account_index)?;
    let avatar_path = save_friend_avatar(&storage_dir, &requester_pubkey, &requester_avatar_base64);
    requests::remove_incoming(&storage_dir, &requester_pubkey)?;
    let merged = friends::add_friend(
        storage_dir.clone(),
        requester_pubkey,
        requester_uid,
        index,
        requester_display_name,
        requester_status_message,
        requester_relays,
        avatar_path,
    )?;
    publish_account_invites_backup(mnemonic.clone(), storage_dir.clone(), my_relays.clone(), now())
        .ok();
    publish_account_incoming_backup(&mnemonic, &storage_dir, &my_relays);
    Ok(merged)
}

/// Permanently blocks a requester's contact pubkey so their (rejected)
/// friend request stops showing up, even if resent.
pub fn reject_friend_request(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    requester_pubkey: String,
) -> Result<(), String> {
    let uid = requests::load_incoming(&storage_dir)
        .into_iter()
        .find(|r| r.pubkey == requester_pubkey)
        .map(|r| r.uid)
        .unwrap_or_default();
    requests::remove_incoming(&storage_dir, &requester_pubkey)?;
    friends::block_pubkey_with_uid(&storage_dir, requester_pubkey, uid)?;
    publish_account_incoming_backup(&mnemonic, &storage_dir, &relay_urls);
    publish_account_blocked_backup(mnemonic, storage_dir, relay_urls, now()).ok();
    Ok(())
}

/// Publishes the given profile info to every existing friend, each using
/// the per-relationship key already established for them, encrypted to
/// their contact pubkey, and sent to their last-known relays. Every such
/// event carries our current relay list too, so friends always pick up
/// our latest relays as a side effect of any update reaching them — no
/// separate relay-discovery mechanism needed. `avatar_path` should be
/// `None` when only the text fields changed, to avoid re-sending the
/// (much larger) avatar payload on every edit.
pub fn publish_profile_update_to_friends(
    mnemonic: String,
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    let payload = FriendPayload {
        uid: derive_uid(&mnemonic)?,
        display_name,
        status_message,
        relays: my_relays,
        avatar_base64: read_avatar_base64(&avatar_path),
        updated_at: now(),
    };
    let plaintext = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    runtime().block_on(async {
        for friend in friends::load_friends(storage_dir.clone()) {
            let Ok(keys) = derive_contact_keys(&mnemonic, friend.my_account_index) else {
                continue;
            };
            let Ok(friend_pubkey) = PublicKey::from_hex(&friend.pubkey) else {
                continue;
            };
            let Ok(encrypted) = nip44::encrypt(
                keys.secret_key(),
                &friend_pubkey,
                plaintext.clone(),
                nip44::Version::V2,
            ) else {
                continue;
            };
            let Ok(event) = EventBuilder::new(FRIEND_PROFILE_UPDATE_KIND, encrypted)
                .tag(Tag::identifier(FRIEND_D_TAG))
                .tag(Tag::public_key(friend_pubkey))
                .sign_with_keys(&keys)
            else {
                continue;
            };
            let _ = publish_to_relays(&friend.relays, &event).await;
        }
        Ok(())
    })
}

/// A live update about a friend request or acceptance, delivered while
/// this device stays connected to its relays. Cheaper than re-polling: the
/// connection just sits idle (a few bytes of keepalive) until a relay
/// actually has something to send.
#[derive(Clone)]
pub struct FriendEvent {
    /// `"request"`, `"accepted"`, `"profile_updated"`, `"message"`, or
    /// `"account_synced"` (a newer copy of our own text/avatar/relays/
    /// friends backup arrived from another device and was applied locally).
    /// `"reconnecting"` is also sent (and safely ignorable) each time a
    /// relay connection drops and this subscription is about to retry it.
    pub kind: String,
    pub pubkey: String,
    pub display_name: String,
    pub status_message: String,
    /// Only set for `"request"` — which invite it arrived on, needed to
    /// accept it.
    pub invite_account_index: Option<u32>,
    /// Only set for `"request"` — the requester's relays, needed to accept it.
    pub relays: Vec<String>,
    /// Only set for `"message"` — the decrypted chat message text.
    pub content: Option<String>,
}

/// Passed through to [ratchet::receive_ratchet_gift_wrap] instead of
/// making [FriendEvent]/[Watch] carry it — an `Option` because forward
/// secrecy is opt-in-by-existence (a caller with no ratchet local key yet
/// just never decrypts ratchet traffic, same as a fresh install before
/// `ratchet::generate_local_storage_key` has ever run).
type RatchetKey = Option<String>;

#[derive(Clone)]
enum Watch {
    Invite(u32),
    Outgoing(u32),
    /// An existing friend, watched for profile updates. Carries their
    /// pubkey (to know which `friends.json` entry to update).
    Friend(u32, String),
    /// One of this device's own per-group Nostr routing identities (see
    /// `group_ratchet.rs`'s module doc) — carries the group id, so an
    /// event matched via this entry's pubkey is known to be group-routed
    /// without needing to decrypt anything first.
    Group(String),
}

/// Opens a connection to this account's relays (plus any outstanding
/// outgoing requests' relays) and streams friend-request / friend-accept
/// events as they arrive, for as long as the returned Dart stream is
/// listened to. Reflects the set of invites/requests that existed at the
/// moment this was called — call again (the Dart side cancels the old
/// subscription first) after creating a new invite or sending a request.
pub fn subscribe_friend_events(
    mnemonic: String,
    storage_dir: String,
    ratchet_key: Option<String>,
    sink: StreamSink<FriendEvent>,
) {
    let generation =
        subscription_generation().fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    runtime().spawn(run_friend_event_subscription(
        mnemonic,
        storage_dir,
        ratchet_key,
        sink,
        generation,
    ));
}

async fn run_friend_event_subscription(
    mnemonic: String,
    storage_dir: String,
    ratchet_key: RatchetKey,
    sink: StreamSink<FriendEvent>,
    generation: u64,
) {
    let invite_list = invites::list_active_invites(storage_dir.clone());
    let outgoing_list = requests::load(&storage_dir);
    let friend_list = friends::load_friends(storage_dir.clone());

    let mut watch: Vec<(PublicKey, Watch)> = Vec::new();
    for invite in &invite_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, invite.account_index) {
            watch.push((keys.public_key(), Watch::Invite(invite.account_index)));
        }
    }
    for outgoing in &outgoing_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, outgoing.my_account_index) {
            watch.push((keys.public_key(), Watch::Outgoing(outgoing.my_account_index)));
        }
    }
    for friend in &friend_list {
        if let Ok(keys) = derive_contact_keys(&mnemonic, friend.my_account_index) {
            watch.push((
                keys.public_key(),
                Watch::Friend(friend.my_account_index, friend.pubkey.clone()),
            ));
        }
    }
    for (pubkey, group_id) in group_ratchet::own_group_identities(&mnemonic, &storage_dir) {
        watch.push((pubkey, Watch::Group(group_id)));
    }

    // Also watch for our own account-backup slots changing on another
    // device (self-authored, so matched by author rather than a `p` tag —
    // a separate filter/subscription from the friend-events one below).
    // Computed before the emptiness check below: an account with zero
    // friends/invites/requests still needs this subscription running, or a
    // fresh second device could never pick up a profile/relay/friends
    // backup published from elsewhere.
    let self_keys = derive_keys(&mnemonic).ok();
    let account_filter = self_keys
        .as_ref()
        .map(|keys| Filter::new().kind(ACCOUNT_BACKUP_KIND).author(keys.public_key()));

    if watch.is_empty() && account_filter.is_none() {
        return;
    }

    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    let mut relay_set: std::collections::HashSet<String> = my_relays.into_iter().collect();
    for outgoing in &outgoing_list {
        relay_set.extend(outgoing.invite_relays.iter().cloned());
    }

    // Anchoring on the persisted watermark (rather than no bound at all)
    // means a fresh subscription — app relaunch or a mid-session reconnect —
    // only asks relays to redeliver what's newer than the last event this
    // device actually finished processing, instead of the account's entire
    // history every time. A brand new account has no watermark yet (0),
    // which is `since` the Unix epoch — equivalent to no bound, as it should
    // be on first run.
    //
    // GiftWrap needs extra slack: per NIP-59, its outer `created_at` is
    // deliberately randomized up to `nostr::nips::nip59::RANGE_RANDOM_TIMESTAMP_TWEAK`
    // (2 days) *into the past*, as a privacy measure against send-time
    // correlation. A message sent this instant can therefore legitimately
    // carry a `created_at` up to 2 days old — a plain `since = watermark`
    // bound would silently and permanently drop it the moment the
    // watermark (advanced by other, non-backdated traffic) passes that
    // point, since nothing ever resubscribes without a bound again. Padding
    // `since` back by that same 2-day window covers the worst case; the
    // other kinds in this filter aren't gift-wrapped and use real
    // timestamps, so the only cost is a slightly wider (still bounded, still
    // far cheaper than unbounded) redelivery window for them too.
    let since = Timestamp::from(
        (load_sync_state(&storage_dir).friend_events_since.max(0) as u64)
            .saturating_sub(nostr::nips::nip59::RANGE_RANDOM_TIMESTAMP_TWEAK.end),
    );
    let filter = if watch.is_empty() {
        None
    } else {
        let pubkeys: Vec<PublicKey> = watch.iter().map(|(pk, _)| *pk).collect();
        Some(
            Filter::new()
                .kinds([FRIEND_REQUEST_KIND, FRIEND_ACCEPT_KIND, FRIEND_PROFILE_UPDATE_KIND, Kind::GiftWrap])
                .pubkeys(pubkeys)
                .since(since),
        )
    };

    let watch_snapshot: Vec<(PublicKey, Watch)> = watch;

    let tasks = relay_set.into_iter().map(|url| {
        let filter = filter.clone();
        let mnemonic = mnemonic.clone();
        let storage_dir = storage_dir.clone();
        let sink = sink.clone();
        let watch_snapshot = watch_snapshot.clone();
        let account_filter = account_filter.clone();
        let ratchet_key = ratchet_key.clone();
        async move {
            if filter.is_none() && account_filter.is_none() {
                return;
            }
            // `listen_for_friend_events`/`listen_for_account_sync` return as
            // soon as the pooled connection drops (network blip, relay
            // restart, or the OS freezing the process's sockets while
            // backgrounded) — previously that silently ended this relay's
            // subscription for good, with nothing to bring it back except
            // the app happening to pass through a Flutter `resumed`
            // lifecycle event, which isn't guaranteed to fire for every way
            // a connection can die. Retry with backoff instead, for as long
            // as the sink is still wanted.
            let mut backoff = Duration::from_secs(1);
            loop {
                match (&filter, &account_filter) {
                    (Some(filter), Some(account_filter)) => {
                        let friend_events = listen_for_friend_events(
                            &url,
                            filter,
                            &watch_snapshot,
                            &mnemonic,
                            &storage_dir,
                            &ratchet_key,
                            &sink,
                            generation,
                        );
                        let account_sync = listen_for_account_sync(
                            &url,
                            account_filter,
                            &mnemonic,
                            &storage_dir,
                            &sink,
                            generation,
                        );
                        tokio::join!(friend_events, account_sync);
                    }
                    (Some(filter), None) => {
                        listen_for_friend_events(
                            &url,
                            filter,
                            &watch_snapshot,
                            &mnemonic,
                            &storage_dir,
                            &ratchet_key,
                            &sink,
                            generation,
                        )
                        .await;
                    }
                    (None, Some(account_filter)) => {
                        listen_for_account_sync(
                            &url,
                            account_filter,
                            &mnemonic,
                            &storage_dir,
                            &sink,
                            generation,
                        )
                        .await;
                    }
                    (None, None) => unreachable!(),
                }
                if subscription_generation().load(std::sync::atomic::Ordering::SeqCst) != generation
                {
                    // Superseded by a newer subscription while we were
                    // connected — stop retrying this stale one.
                    return;
                }
                if sink.add(FriendEvent {
                    kind: "reconnecting".to_string(),
                    pubkey: String::new(),
                    display_name: String::new(),
                    status_message: String::new(),
                    invite_account_index: None,
                    relays: Vec::new(),
                    content: None,
                })
                .is_err()
                {
                    // The Dart side cancelled this subscription (e.g. it
                    // resubscribed elsewhere) — stop retrying rather than
                    // reconnecting a socket nothing will ever read from.
                    return;
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
    });
    join_all(tasks).await;
}

/// Tracks the `updated_at` of the last-applied avatar/relays/friends backup
/// per storage dir, so [listen_for_account_sync] can reject stale or
/// duplicate events by timestamp rather than by content — content-equality
/// alone isn't enough: an older event arriving after a newer one (relays
/// don't guarantee delivery order across each other, and this filter has no
/// `since` so a fresh subscription replays whatever each individual relay
/// currently has) would otherwise overwrite the newer local state right
/// back to the older content. The text backup already tracks this via
/// `Account.updated_at`; this covers the other three slots, which have no
/// existing local timestamp field of their own to compare against.
#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct SyncState {
    #[serde(default)]
    pub avatar_updated_at: i64,
    #[serde(default)]
    pub relays_updated_at: i64,
    #[serde(default)]
    pub friends_updated_at: i64,
    #[serde(default)]
    pub blocked_updated_at: i64,
    #[serde(default)]
    pub invites_updated_at: i64,
    #[serde(default)]
    pub outgoing_updated_at: i64,
    #[serde(default)]
    pub incoming_updated_at: i64,
    #[serde(default)]
    pub readstate_updated_at: i64,
    #[serde(default)]
    pub config_updated_at: i64,
    #[serde(default)]
    pub chatstarted_updated_at: i64,
    /// `created_at` of the newest friend-protocol/chat event this device has
    /// successfully processed, across every relay — used as `since` when
    /// (re)subscribing in [run_friend_event_subscription] so a reconnect (app
    /// relaunch, network drop) only asks relays to redeliver what's newer
    /// than this, instead of replaying the account's entire history every
    /// time. Only advanced on confirmed-successful processing (see call
    /// sites in [listen_for_friend_events]), never on a bare decode attempt,
    /// so a transient failure (e.g. a friend's key material not loaded into
    /// `watch` yet) stays eligible for redelivery on the next resubscribe.
    #[serde(default)]
    pub friend_events_since: i64,
}

fn sync_state_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("account_sync_state.json")
}

fn load_sync_state(storage_dir: &str) -> SyncState {
    std::fs::read_to_string(sync_state_path(storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

fn save_sync_state(storage_dir: &str, state: &SyncState) {
    if let Ok(content) = serde_json::to_string(state) {
        let _ = std::fs::write(sync_state_path(storage_dir), content);
    }
}

/// Subscribes on `url` for this account's own backup events (text,
/// avatar, relays, friends) and applies any that are newer than what's
/// stored locally — the live-sync counterpart to the one-shot
/// `fetch_account_*_backup` calls used at cold start / restore.
async fn listen_for_account_sync(
    url: &str,
    filter: &Filter,
    mnemonic: &str,
    storage_dir: &str,
    sink: &StreamSink<FriendEvent>,
    generation: u64,
) {
    let Ok(keys) = derive_keys(mnemonic) else {
        return;
    };
    // No periodic resubscribe here (unlike a plain `since`-based fix, that
    // wouldn't even be safe: these are addressable/replaceable events, so a
    // relay only ever holds the current snapshot per slot, not a growing
    // history — an unmodified-but-not-yet-applied snapshot could permanently
    // fail to match a `since` bound). Relying on cold-start's one-shot
    // `fetch_account_*_backup` plus this live subscription (rebuilt by the
    // caller's backoff retry loop on any real disconnect) means the only
    // cost of *not* periodically re-polling is a delay — until the next
    // reconnect or app relaunch — in picking up another device's update if
    // a relay hits the silent-delivery-stall bug described in
    // `listen_for_friend_events`, not any lost or corrupted state.
    let Some((sub_id, mut events)) = relay_pool::subscribe(url, filter).await else {
        return;
    };

    loop {
        let Some(pool_event) = events.recv().await else {
            break;
        };
        if subscription_generation().load(std::sync::atomic::Ordering::SeqCst) != generation {
            // A newer subscription has superseded this one — drop the event
            // without applying it, rather than silently mutating local
            // storage from a task nothing is listening to anymore.
            break;
        }
        let relay_pool::PoolEvent::Event(event) = pool_event else {
            continue;
        };
        if !mark_event_seen(event.id) {
            // See the matching comment in `listen_for_friend_events`.
            continue;
        }
        let Some(d_tag) = event.tags.identifier() else {
            continue;
        };
        let Ok(decrypted) = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content)
        else {
            continue;
        };

        let applied = match d_tag {
            ACCOUNT_TEXT_D_TAG => {
                let Ok(payload) = serde_json::from_str::<TextBackupPayload>(&decrypted) else {
                    continue;
                };
                let current = account::load_account(storage_dir.to_string());
                let is_newer = current.as_ref().is_none_or(|a| payload.updated_at > a.updated_at);
                if is_newer {
                    let avatar_path = current.and_then(|a| a.avatar_path);
                    let _ = account::save_account_with_timestamp(
                        storage_dir.to_string(),
                        payload.display_name,
                        payload.status_message,
                        avatar_path,
                        payload.updated_at,
                    );
                }
                is_newer
            }
            ACCOUNT_AVATAR_D_TAG => {
                let Ok(payload) = serde_json::from_str::<AvatarBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.avatar_updated_at {
                    // Stale or duplicate (including our own publish echoing
                    // back through this same subscription) — never applied.
                    false
                } else {
                    let Some(path) =
                        account::save_account_avatar_base64(storage_dir.to_string(), payload.avatar_base64)
                    else {
                        continue;
                    };
                    if let Some(account) = account::load_account(storage_dir.to_string()) {
                        let _ = account::save_account_with_timestamp(
                            storage_dir.to_string(),
                            account.display_name,
                            account.status_message,
                            Some(path),
                            account.updated_at,
                        );
                    }
                    state.avatar_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_RELAYS_D_TAG => {
                let Ok(payload) = serde_json::from_str::<RelaysBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.relays_updated_at {
                    false
                } else {
                    let _ = relay::save_relay_list(storage_dir.to_string(), payload.relays);
                    state.relays_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_FRIENDS_D_TAG => {
                let Ok(payload) = serde_json::from_str::<FriendsBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.friends_updated_at {
                    false
                } else {
                    for entry in payload.friends {
                        let is_favorite = entry.is_favorite;
                        let _ = friends::add_friend(
                            storage_dir.to_string(),
                            entry.pubkey.clone(),
                            entry.uid,
                            entry.my_account_index,
                            entry.display_name,
                            entry.status_message,
                            entry.relays,
                            None,
                        );
                        if is_favorite {
                            let _ = friends::set_favorite_friend(
                                storage_dir.to_string(),
                                entry.pubkey,
                                true,
                            );
                        }
                    }
                    state.friends_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_BLOCKED_D_TAG => {
                let Ok(payload) = serde_json::from_str::<BlockedBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.blocked_updated_at {
                    false
                } else {
                    let _ = friends::set_blocked_snapshot(storage_dir, payload.blocked);
                    state.blocked_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_INVITES_D_TAG => {
                let Ok(payload) = serde_json::from_str::<InvitesBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.invites_updated_at {
                    false
                } else {
                    let _ = invites::set_invites_snapshot(
                        storage_dir,
                        payload.next_account_index,
                        payload.invites,
                    );
                    state.invites_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_OUTGOING_D_TAG => {
                let Ok(payload) = serde_json::from_str::<OutgoingBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.outgoing_updated_at {
                    false
                } else {
                    let _ = requests::set_outgoing_snapshot(storage_dir, payload.requests);
                    state.outgoing_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_INCOMING_D_TAG => {
                let Ok(payload) = serde_json::from_str::<IncomingBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.incoming_updated_at {
                    false
                } else {
                    let _ = requests::set_incoming_snapshot(storage_dir, payload.requests);
                    state.incoming_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_READSTATE_D_TAG => {
                let Ok(payload) = serde_json::from_str::<ReadStateBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.readstate_updated_at {
                    false
                } else {
                    let _ = chat::set_read_state_snapshot(storage_dir, payload.state);
                    state.readstate_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_CONFIG_D_TAG => {
                let Ok(payload) = serde_json::from_str::<ConfigBackupPayload>(&decrypted) else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.config_updated_at {
                    false
                } else {
                    let _ = config::save_config(storage_dir.to_string(), payload.config);
                    state.config_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            ACCOUNT_CHATSTARTED_D_TAG => {
                let Ok(payload) = serde_json::from_str::<ChatStartedBackupPayload>(&decrypted)
                else {
                    continue;
                };
                let mut state = load_sync_state(storage_dir);
                if payload.updated_at <= state.chatstarted_updated_at {
                    false
                } else {
                    let _ = chat::set_started_snapshot(storage_dir, payload.started);
                    state.chatstarted_updated_at = payload.updated_at;
                    save_sync_state(storage_dir, &state);
                    true
                }
            }
            _ => false,
        };

        if applied
            && sink
                .add(FriendEvent {
                    kind: "account_synced".to_string(),
                    pubkey: String::new(),
                    display_name: String::new(),
                    status_message: String::new(),
                    invite_account_index: None,
                    relays: Vec::new(),
                    content: None,
                })
                .is_err()
        {
            // The Dart side cancelled this subscription (e.g. the app
            // switched accounts) — stop applying this account's backup
            // events instead of continuing to write them into what is now
            // a different account's local storage.
            break;
        }
    }
    relay_pool::unsubscribe(url, sub_id);
}

/// Subscribes on `url`'s pooled connection (reusing it if already open —
/// e.g. from a recent publish or fetch to the same relay) and pushes
/// decrypted friend events to `sink` as they arrive (persisting accepted
/// friends along the way). Returns once the connection drops.
async fn listen_for_friend_events(
    url: &str,
    filter: &Filter,
    watch: &[(PublicKey, Watch)],
    mnemonic: &str,
    storage_dir: &str,
    ratchet_key: &RatchetKey,
    sink: &StreamSink<FriendEvent>,
    generation: u64,
) {
    // Reconnection (the pooled connection dropping, e.g. a network blip or
    // the OS freezing sockets while backgrounded) is handled by the retry
    // loop one level up in `run_friend_event_subscription`'s caller — this
    // function simply returns once `events.recv()` yields nothing more, and
    // the fresh subscription that follows carries `since` (see that
    // function's `since` — anchored on the persisted watermark, not "no
    // bound"), so a reconnect only asks for what's new since the last
    // successfully processed event instead of replaying all of history.
    let Some((sub_id, mut events)) = relay_pool::subscribe(url, filter).await else {
        return;
    };
    let my_relays = relay::load_relay_list(storage_dir.to_string()).urls;

    loop {
        let Some(pool_event) = events.recv().await else {
            break;
        };
        if subscription_generation().load(std::sync::atomic::Ordering::SeqCst) != generation {
            // A newer subscription (from a fresh Dart-side resubscribe) has
            // superseded this one — stop before mutating friends.json /
            // requests / etc. from an event nothing will be notified about.
            break;
        }
        let relay_pool::PoolEvent::Event(event) = pool_event else {
            continue;
        };
        let Some((_, matched)) = watch
            .iter()
            .find(|(pk, _)| event.tags.public_keys().any(|tagged| tagged == pk))
        else {
            // Not (yet) in this task's watch list — do NOT mark it seen: a
            // friend added moments ago may not be in `watch` until the next
            // resubscribe picks up the fresh list. Since `friend_events_since`
            // only advances on confirmed-successful processing (see the
            // watermark bumps below), this event's `created_at` is still
            // ahead of that watermark and a future resubscribe will see it
            // again. Marking it seen here would permanently blacklist it,
            // since `mark_event_seen`'s dedup set lives for the whole
            // process lifetime, not just this subscription generation.
            continue;
        };
        // GiftWrap decoding can genuinely fail transiently (e.g. a friend
        // whose relationship key material raced with this event, or a
        // wrong-guess decode attempt against a kind that turns out to
        // belong to a different friend) — unlike the other kinds here,
        // which reliably decrypt with a single nip44 call once matched.
        // Marking a GiftWrap "seen" before knowing it actually decoded would
        // permanently blacklist it with no way to retry (the dedup set lives
        // for the process lifetime, and the watermark below only advances on
        // confirmed success, so a resubscribe's `since` would still be
        // behind this event) — so for GiftWrap the dedup mark is applied
        // per-success-path below instead, right before each `sink.add`, not
        // here.
        if event.kind != Kind::GiftWrap {
            if !mark_event_seen(event.id) {
                // The same event arrives once per relay it matched on (3
                // relay tasks all racing to process it), and possibly again
                // after a reconnect if it hadn't been fully processed yet —
                // each redundant delivery used to independently re-run
                // `add_incoming`/`publish_account_incoming_backup` (etc), and
                // those concurrent publishes' self-echoes could race each
                // other and clobber one another's local write. Processing
                // each
                // event id once closes that whole class of race at the
                // source.
                continue;
            }
            bump_local_watermark(storage_dir, event.created_at.as_secs() as i64, |s| {
                &mut s.friend_events_since
            });
        }
        if let Watch::Group(group_id) = matched {
            let group_id = group_id.clone();
            if event.kind != Kind::GiftWrap {
                continue;
            }
            let Some(key) = ratchet_key else { continue };
            let Ok(my_group_keys) = group_ratchet::own_group_keys(mnemonic, storage_dir, &group_id) else {
                continue;
            };
            let Some(received) =
                group_ratchet::receive_gift_wrap(storage_dir, key, &group_id, &my_group_keys, &event).await
            else {
                continue;
            };
            let applied = groups::apply_group_ratchet_received(
                mnemonic,
                storage_dir,
                Some(key.as_str()),
                &group_id,
                &received,
            )
            .await;
            if let Some(kind) = applied {
                if !mark_event_seen(event.id) {
                    continue;
                }
                bump_local_watermark(storage_dir, event.created_at.as_secs() as i64, |s| {
                    &mut s.friend_events_since
                });
                if sink
                    .add(FriendEvent {
                        kind,
                        pubkey: group_id,
                        display_name: String::new(),
                        status_message: String::new(),
                        invite_account_index: None,
                        relays: Vec::new(),
                        content: None,
                    })
                    .is_err()
                {
                    break;
                }
            }
            continue;
        }
        let account_index = match matched {
            Watch::Invite(idx) | Watch::Outgoing(idx) | Watch::Friend(idx, _) => *idx,
            Watch::Group(_) => unreachable!("handled above"),
        };
        // A blocked friend stays in `friends.json` (so the UI can still
        // show/unblock them) and their friend-protocol events (profile
        // updates, etc.) are silenced while blocked. Chat messages are the
        // exception: still store them so nothing is lost — after an
        // unblock, the conversation should look complete rather than
        // having a gap for whatever arrived while blocked.
        if let Watch::Friend(_, friend_pubkey) = matched {
            if event.kind != Kind::GiftWrap && friends::load_blocked(storage_dir).contains(friend_pubkey) {
                continue;
            }
        }
        let Ok(my_keys) = derive_contact_keys(mnemonic, account_index) else {
            continue;
        };

        if event.kind == Kind::GiftWrap {
            let Watch::Friend(_, friend_pubkey) = matched else {
                continue;
            };
            let Ok(friend_pk) = PublicKey::from_hex(friend_pubkey) else {
                continue;
            };
            let Some(received) = chat::receive_gift_wrap(storage_dir, &my_keys, &friend_pk, &event).await
            else {
                // Not a `chat.rs`-recognized kind (edit/delete/hide/clear/
                // attachment/message) — try the forward-secrecy device
                // announce / ratchet message decoder instead. Two
                // independent decode attempts on the same event is
                // harmless: each ignores whatever it doesn't recognize.
                if let Some(key) = ratchet_key {
                    if let Some(received) =
                        ratchet::receive_ratchet_gift_wrap(storage_dir, key, &my_keys, &friend_pk, &event)
                            .await
                    {
                        let kind = match received {
                            ratchet::RatchetReceived::DeviceAnnounced => "ratchet_device_announced",
                            ratchet::RatchetReceived::Message => "ratchet_message",
                        };
                        if !mark_event_seen(event.id) {
                            continue;
                        }
                        bump_local_watermark(storage_dir, event.created_at.as_secs() as i64, |s| {
                            &mut s.friend_events_since
                        });
                        // Same reasoning as the non-ratchet message path
                        // below: persist the thread's active flag before
                        // Dart re-queries the Talk-tab list.
                        if kind == "ratchet_message" {
                            let _ = chat::mark_chat_started(
                                storage_dir.to_string(),
                                friend_pubkey.clone(),
                            );
                        }
                        if sink
                            .add(FriendEvent {
                                kind: kind.to_string(),
                                pubkey: friend_pubkey.clone(),
                                display_name: String::new(),
                                status_message: String::new(),
                                invite_account_index: None,
                                relays: Vec::new(),
                                content: None,
                            })
                            .is_err()
                        {
                            break;
                        }
                        continue;
                    }
                }
                // Not a 1:1 or ratchet kind either — try the group-chat
                // 1:1-fallback decoder (see `groups.rs`'s module doc; the
                // direct per-group channel is handled separately above, via
                // `Watch::Group`, since it isn't addressed to a friend
                // pubkey at all).
                if let Some(received) = groups::receive_group_gift_wrap(
                    mnemonic,
                    storage_dir,
                    ratchet_key.as_deref(),
                    &my_keys,
                    &friend_pk,
                    &event,
                )
                .await
                {
                    let (kind, group_id) = match received {
                        groups::GroupReceived::Invite(id) => ("group_invite", id),
                        groups::GroupReceived::Message(id) => ("group_message", id),
                    };
                    if !mark_event_seen(event.id) {
                        continue;
                    }
                    bump_local_watermark(storage_dir, event.created_at.as_secs() as i64, |s| {
                        &mut s.friend_events_since
                    });
                    if sink
                        .add(FriendEvent {
                            kind: kind.to_string(),
                            pubkey: group_id,
                            display_name: String::new(),
                            status_message: String::new(),
                            invite_account_index: None,
                            relays: Vec::new(),
                            content: None,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
                continue;
            };
            // A real message carries its decrypted text in `content`; an
            // edit/delete instruction has none — the Dart side treats both
            // the same either way (just a signal to reload the thread from
            // local storage, where [chat::load_chat_history] has already
            // applied the edit/delete), so `content` being empty for those
            // is harmless.
            let (seal_id, content) = match &received {
                chat::Received::Message(m) => (m.id.clone(), Some(m.content.clone())),
                chat::Received::Edit(id)
                | chat::Received::Delete(id)
                | chat::Received::Hide(id)
                | chat::Received::Clear(id) => (id.clone(), None),
            };
            if !mark_event_seen(event.id) {
                continue;
            }
            bump_local_watermark(storage_dir, event.created_at.as_secs() as i64, |s| {
                &mut s.friend_events_since
            });
            // Still blocked: the message is now saved to local history (so
            // it's there once unblocked) but held — [chat::load_chat_history]
            // and [chat::has_chat_history] filter out held messages while
            // the friend is blocked, so the Talk tab, previews, and unread
            // counts all stay silent too, not just this live notification.
            if friends::load_blocked(storage_dir).contains(friend_pubkey) {
                chat::hold_message(storage_dir, &seal_id);
                continue;
            }
            // A real incoming message (not an edit/delete/hide/clear signal,
            // which all have `content == None`) makes this thread active in
            // the Talk tab. Persist that via the same durable started-flag
            // the "Talk" button uses, *before* notifying Dart: the Dart side
            // reacts by re-querying `list_active_chat_pubkeys`, and the
            // just-saved Seal isn't reliably visible to an immediate LMDB
            // read — without this flag the recomputed list wouldn't include
            // this friend yet, wiping the brand-new thread right back off
            // the list until something else forced another reload.
            if content.is_some() {
                let _ = chat::mark_chat_started(storage_dir.to_string(), friend_pubkey.clone());
            }
            if sink
                .add(FriendEvent {
                    kind: "message".to_string(),
                    pubkey: friend_pubkey.clone(),
                    display_name: String::new(),
                    status_message: String::new(),
                    invite_account_index: None,
                    relays: Vec::new(),
                    content,
                })
                .is_err()
            {
                break;
            }
            continue;
        }

        let Ok(decrypted) = nip44::decrypt(my_keys.secret_key(), &event.pubkey, &event.content)
        else {
            continue;
        };
        let Ok(payload) = serde_json::from_str::<FriendPayload>(&decrypted) else {
            continue;
        };

        let friend_event = match matched {
            Watch::Invite(idx) if event.kind == FRIEND_REQUEST_KIND => {
                if !payload.uid.is_empty()
                    && friends::load_blocked_uids(storage_dir).contains(&payload.uid)
                {
                    // Same account as someone we've already blocked,
                    // re-requesting under a fresh relationship key — drop
                    // it silently, same as a request from a blocked
                    // pubkey directly.
                    continue;
                }
                let pubkey = event.pubkey.to_hex();
                let _ = requests::add_incoming(
                    storage_dir,
                    *idx,
                    pubkey.clone(),
                    payload.uid.clone(),
                    payload.display_name.clone(),
                    payload.status_message.clone(),
                    payload.relays.clone(),
                    payload.avatar_base64.clone(),
                );
                publish_account_incoming_backup_async(mnemonic, storage_dir, &my_relays).await;
                FriendEvent {
                    kind: "request".to_string(),
                    pubkey,
                    display_name: payload.display_name,
                    status_message: payload.status_message,
                    invite_account_index: Some(*idx),
                    relays: payload.relays,
                    content: None,
                }
            }
            Watch::Outgoing(idx) if event.kind == FRIEND_ACCEPT_KIND => {
                let pubkey = event.pubkey.to_hex();
                let avatar_path = save_friend_avatar(storage_dir, &pubkey, &payload.avatar_base64);
                let merged = friends::add_friend(
                    storage_dir.to_string(),
                    pubkey.clone(),
                    payload.uid.clone(),
                    *idx,
                    payload.display_name.clone(),
                    payload.status_message.clone(),
                    payload.relays.clone(),
                    avatar_path,
                )
                .unwrap_or(false);
                let _ = requests::remove(storage_dir, *idx);
                publish_account_outgoing_backup_async(mnemonic, storage_dir, &my_relays).await;
                FriendEvent {
                    kind: if merged { "already_friend" } else { "accepted" }.to_string(),
                    pubkey,
                    display_name: payload.display_name,
                    status_message: payload.status_message,
                    invite_account_index: None,
                    relays: Vec::new(),
                    content: None,
                }
            }
            Watch::Friend(_, friend_pubkey) if event.kind == FRIEND_PROFILE_UPDATE_KIND => {
                let avatar_path =
                    save_friend_avatar(storage_dir, friend_pubkey, &payload.avatar_base64);
                let applied = friends::update_friend_profile(
                    storage_dir,
                    friend_pubkey,
                    payload.display_name.clone(),
                    payload.status_message.clone(),
                    payload.relays.clone(),
                    avatar_path,
                    payload.updated_at,
                )
                .unwrap_or(false);
                if !applied {
                    // Stale/reordered event — a newer update was already
                    // applied, so this one is dropped rather than
                    // overwriting it with older info.
                    continue;
                }
                FriendEvent {
                    kind: "profile_updated".to_string(),
                    pubkey: friend_pubkey.clone(),
                    display_name: payload.display_name,
                    status_message: payload.status_message,
                    invite_account_index: None,
                    relays: Vec::new(),
                    content: None,
                }
            }
            _ => continue,
        };
        if sink.add(friend_event).is_err() {
            // The Dart side cancelled this subscription — stop applying
            // further friend-protocol events under the mnemonic/storage
            // this task was started with (e.g. after a logout/account
            // switch, so a stale task never writes into a new account's
            // local storage).
            break;
        }
    }
    relay_pool::unsubscribe(url, sub_id);
}

/// Publishes `event` to every relay in `urls` over each relay's pooled
/// connection (reused if one's already open, e.g. from the live
/// subscription — never a fresh dial per publish). Fire-and-forget per
/// relay; only fails if every relay's queue is already gone.
pub(crate) async fn publish_to_relays(urls: &[String], event: &Event) -> Result<(), String> {
    let tasks = urls.iter().map(|url| relay_pool::publish(url, event));
    let results = join_all(tasks).await;
    if results.iter().any(Result::is_ok) {
        Ok(())
    } else {
        Err("failed to publish to any relay".to_string())
    }
}

async fn fetch_latest_backup_event(
    urls: &[String],
    pubkey: &PublicKey,
    d_tag: &str,
) -> Result<Option<Event>, String> {
    let filter = Filter::new()
        .author(*pubkey)
        .kind(ACCOUNT_BACKUP_KIND)
        .identifier(d_tag)
        .limit(1);
    let tasks = urls
        .iter()
        .map(|url| relay_pool::request(url, &filter, REQUEST_TIMEOUT));
    let results = join_all(tasks).await;
    let mut latest: Option<Event> = None;
    for event in results.into_iter().flatten() {
        if latest.as_ref().is_none_or(|current| event.created_at > current.created_at) {
            latest = Some(event);
        }
    }
    Ok(latest)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    fn temp_storage_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "origilink-sync-test-{tag}-{}",
            nostr::Keys::generate().public_key().to_hex()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn invite_qr_payload_round_trips() {
        let dir = temp_storage_dir("qr-round-trip");
        let dir_str = dir.to_string_lossy().to_string();
        account::save_account(
            dir_str.clone(),
            "Alice".to_string(),
            "hi".to_string(),
            None,
        )
        .unwrap();

        let json = build_invite_qr_payload(TEST_MNEMONIC.to_string(), dir_str, 7).unwrap();
        let payload = parse_invite_qr_payload(json).unwrap();

        assert_eq!(payload.display_name, "Alice");
        assert_eq!(payload.status_message, "hi");
        assert_eq!(
            payload.pubkey,
            derive_contact_keys(TEST_MNEMONIC, 7).unwrap().public_key().to_hex()
        );
        assert_eq!(payload.uid, derive_uid(TEST_MNEMONIC).unwrap());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn invite_qr_payload_differs_per_account_index() {
        let dir = temp_storage_dir("qr-per-index");
        let dir_str = dir.to_string_lossy().to_string();
        account::save_account(dir_str.clone(), "Bob".to_string(), String::new(), None).unwrap();

        let a = parse_invite_qr_payload(
            build_invite_qr_payload(TEST_MNEMONIC.to_string(), dir_str.clone(), 0).unwrap(),
        )
        .unwrap();
        let b = parse_invite_qr_payload(
            build_invite_qr_payload(TEST_MNEMONIC.to_string(), dir_str, 1).unwrap(),
        )
        .unwrap();

        assert_ne!(a.pubkey, b.pubkey, "each invite must use an unlinkable relationship key");
        assert_eq!(a.uid, b.uid, "the stable UID must not vary by invite");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn parse_invite_qr_payload_rejects_malformed_json() {
        assert!(parse_invite_qr_payload("not json".to_string()).is_err());
    }

    #[test]
    fn build_invite_qr_payload_fails_without_a_local_account() {
        let dir = temp_storage_dir("no-account");
        let result = build_invite_qr_payload(
            TEST_MNEMONIC.to_string(),
            dir.to_string_lossy().to_string(),
            0,
        );
        assert!(result.is_err());
        std::fs::remove_dir_all(&dir).ok();
    }
}

