use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A contact pubkey/account-index pair this friend used before being
/// re-added under a new relationship key (see [add_friend]'s UID merge).
/// Kept only so past chat history under the old identity still shows up —
/// never used for sending, since the friend has since minted a new key for
/// this relationship.
#[derive(Serialize, Deserialize, Clone)]
pub struct PriorIdentity {
    pub pubkey: String,
    pub my_account_index: u32,
}

/// A confirmed friend: their per-relationship contact pubkey, and which of
/// *our own* NIP-06 account indices we use to talk to them (see
/// `keys::derive_contact_keys`). Every friend has a distinct pair of keys
/// on both sides, so leaking one relationship's key never exposes another.
#[derive(Serialize, Deserialize, Clone)]
pub struct Friend {
    /// The friend's contact pubkey (hex) — distinct from their account's
    /// core identity, minted specifically for this relationship.
    pub pubkey: String,
    /// The friend's stable account UID (see `keys::derive_uid`) — constant
    /// across every relationship they have, unlike `pubkey`. Used to
    /// recognize them again if they re-friend us with a new relationship
    /// key after being blocked.
    #[serde(default)]
    pub uid: String,
    /// Which of our own `account` indices we use to talk to this friend.
    pub my_account_index: u32,
    pub display_name: String,
    pub status_message: String,
    /// The friend's relays as of the last time we heard from them — where
    /// we publish future profile updates to.
    #[serde(default)]
    pub relays: Vec<String>,
    /// Local file path to the friend's avatar image, as last received —
    /// downloaded and cached on this device, not a remote URL.
    #[serde(default)]
    pub avatar_path: Option<String>,
    pub added_at: i64,
    /// User-set flag to pin this friend near the top of the friends list.
    #[serde(default)]
    pub is_favorite: bool,
    /// `updated_at` of the last-applied profile-update event from this
    /// friend — lets [update_friend_profile] reject a stale/reordered
    /// event instead of overwriting newer info with older.
    #[serde(default)]
    pub profile_updated_at: i64,
    /// Whether this friend's contact pubkey is currently on the blocked
    /// list. Derived from `blocked.json` at load time, not stored in
    /// `friends.json` itself — [block_pubkey]/[unblock_pubkey] are the
    /// source of truth, this is just a convenience for the UI.
    #[serde(default, skip_serializing)]
    pub is_blocked: bool,
    /// Earlier contact pubkeys this same account (by UID) used with us,
    /// preserved by [add_friend] when it merges a re-friend under a new
    /// relationship key — so past chat history isn't orphaned.
    #[serde(default)]
    pub prior_identities: Vec<PriorIdentity>,
}

/// Whether `uid` (a non-empty account UID) already belongs to a friend —
/// used at QR-scan time, before any request/accept round-trip, so the
/// scanner can be told "you already have this account as a friend" right
/// away (the scanned invite's own pubkey is a fresh per-invite key, so it
/// can't be matched directly).
pub fn is_known_uid(storage_dir: String, uid: String) -> bool {
    !uid.is_empty() && load_friends(storage_dir).iter().any(|f| f.uid == uid)
}

fn friends_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("friends.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Loads the saved friends list, or an empty list if none has been saved yet.
/// Each entry's `is_blocked` is filled in from `blocked.json` — a blocked
/// friend stays in this list (so the UI can still show/unblock them) but
/// their events are dropped by the live subscription (see `sync.rs`).
pub fn load_friends(storage_dir: String) -> Vec<Friend> {
    let mut friends: Vec<Friend> = fs::read_to_string(friends_path(&storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default();
    let blocked = load_blocked(&storage_dir);
    for friend in friends.iter_mut() {
        friend.is_blocked = blocked.contains(&friend.pubkey);
    }
    friends
}

fn save_friends_list(storage_dir: &str, friends: &[Friend]) -> Result<(), String> {
    let content = serde_json::to_string_pretty(friends).map_err(|e| e.to_string())?;
    fs::write(friends_path(storage_dir), content).map_err(|e| e.to_string())
}

/// Adds (or updates the info of) a friend, deduplicating by their contact
/// pubkey — and also by `uid` when it's non-empty: if an existing friend
/// entry has the same UID but a different pubkey (they re-friended us under
/// a fresh relationship key, e.g. after we deleted the old entry), that old
/// entry is folded into this one rather than creating a second friend. Its
/// pubkey/account-index are kept in `prior_identities` so old chat history
/// stays reachable, and its `is_favorite` flag carries over.
///
/// Returns `true` if this call merged into an existing UID match (so the
/// caller can tell the user "already a friend, info updated" instead of
/// "friend added").
pub fn add_friend(
    storage_dir: String,
    pubkey: String,
    uid: String,
    my_account_index: u32,
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    avatar_path: Option<String>,
) -> Result<bool, String> {
    let mut friends = load_friends(storage_dir.clone());

    let mut is_favorite = false;
    let mut prior_identities = Vec::new();
    let mut merged = false;

    if !uid.is_empty() {
        if let Some(existing) = friends.iter().find(|f| f.uid == uid && f.pubkey != pubkey) {
            merged = true;
            is_favorite = existing.is_favorite;
            prior_identities = existing.prior_identities.clone();
            prior_identities.push(PriorIdentity {
                pubkey: existing.pubkey.clone(),
                my_account_index: existing.my_account_index,
            });
            friends.retain(|f| f.uid != uid);
        }
    }
    if !merged {
        if let Some(existing) = friends.iter().find(|f| f.pubkey == pubkey) {
            is_favorite = existing.is_favorite;
            prior_identities = existing.prior_identities.clone();
        }
        friends.retain(|f| f.pubkey != pubkey);
    }

    friends.push(Friend {
        pubkey,
        uid,
        my_account_index,
        display_name,
        status_message,
        relays,
        avatar_path,
        added_at: now(),
        is_favorite,
        profile_updated_at: now(),
        is_blocked: false,
        prior_identities,
    });
    save_friends_list(&storage_dir, &friends)?;
    Ok(merged)
}

/// Sets whether a friend is pinned as a favorite. A no-op if there's no
/// friend with that pubkey.
pub fn set_favorite_friend(
    storage_dir: String,
    pubkey: String,
    is_favorite: bool,
) -> Result<(), String> {
    let mut friends = load_friends(storage_dir.clone());
    for friend in friends.iter_mut() {
        if friend.pubkey == pubkey {
            friend.is_favorite = is_favorite;
            break;
        }
    }
    save_friends_list(&storage_dir, &friends)
}

/// Updates a friend's display info (e.g. after they push a profile update),
/// including their current relay list — every friend-protocol event
/// carries the sender's up-to-date relays, so this is also how we notice a
/// friend has moved to different relays and keep publishing where they'll
/// actually see it. Leaves `my_account_index`/`added_at` untouched. A
/// no-op (returning `Ok(false)`) if there's no friend with that pubkey, or
/// if `updated_at` isn't newer than the last-applied update — relays don't
/// guarantee delivery order, so a reordered older event must never
/// overwrite newer info already applied. Returns whether it was applied.
pub(crate) fn update_friend_profile(
    storage_dir: &str,
    pubkey: &str,
    display_name: String,
    status_message: String,
    relays: Vec<String>,
    avatar_path: Option<String>,
    updated_at: i64,
) -> Result<bool, String> {
    let mut friends = load_friends(storage_dir.to_string());
    let mut applied = false;
    for friend in friends.iter_mut() {
        if friend.pubkey == pubkey {
            if updated_at <= friend.profile_updated_at {
                break;
            }
            friend.display_name = display_name;
            friend.status_message = status_message;
            if !relays.is_empty() {
                friend.relays = relays;
            }
            if avatar_path.is_some() {
                friend.avatar_path = avatar_path;
            }
            friend.profile_updated_at = updated_at;
            applied = true;
            break;
        }
    }
    if applied {
        save_friends_list(storage_dir, &friends)?;
    }
    Ok(applied)
}

/// Removes a friend by their contact pubkey (e.g. after they're blocked).
/// Also deletes their cached avatar file (`friend_avatars/<pubkey>_*`, see
/// `sync.rs`'s `save_friend_avatar_link`) — otherwise it would sit on disk
/// forever, never referenced again once the friend entry is gone.
pub fn remove_friend(storage_dir: String, pubkey: String) -> Result<(), String> {
    let mut friends = load_friends(storage_dir.clone());
    friends.retain(|f| f.pubkey != pubkey);
    remove_cached_avatar(&storage_dir, &pubkey);
    save_friends_list(&storage_dir, &friends)
}

/// Deletes any cached avatar file(s) for `pubkey` under
/// `storage_dir/friend_avatars` — best-effort, since a missing/unreadable
/// directory just means there was nothing to clean up.
fn remove_cached_avatar(storage_dir: &str, pubkey: &str) {
    let dir = Path::new(storage_dir).join("friend_avatars");
    let Ok(entries) = fs::read_dir(&dir) else {
        return;
    };
    let prefix = format!("{pubkey}_");
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with(&prefix) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn blocked_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("blocked.json")
}

/// A blocked contact: their relationship pubkey at block time, plus their
/// stable account UID so a fresh relationship key from the same account
/// can still be recognized.
#[derive(Serialize, Deserialize, Clone)]
pub(crate) struct BlockedEntry {
    pub pubkey: String,
    #[serde(default)]
    pub uid: String,
}

fn load_blocked_entries(storage_dir: &str) -> Vec<BlockedEntry> {
    fs::read_to_string(blocked_path(storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

fn save_blocked_entries(storage_dir: &str, entries: &[BlockedEntry]) -> Result<(), String> {
    let content = serde_json::to_string_pretty(entries).map_err(|e| e.to_string())?;
    fs::write(blocked_path(storage_dir), content).map_err(|e| e.to_string())
}

/// Loads the set of contact pubkeys whose friend requests should be
/// silently ignored (rejected once, never shown again).
pub(crate) fn load_blocked(storage_dir: &str) -> Vec<String> {
    load_blocked_entries(storage_dir)
        .into_iter()
        .map(|e| e.pubkey)
        .collect()
}

/// Loads the set of blocked accounts' UIDs — non-empty entries only, since
/// an empty UID (e.g. an old blocked.json predating this field) must never
/// match anything.
pub(crate) fn load_blocked_uids(storage_dir: &str) -> Vec<String> {
    load_blocked_entries(storage_dir)
        .into_iter()
        .map(|e| e.uid)
        .filter(|uid| !uid.is_empty())
        .collect()
}

/// Permanently blocks a contact pubkey — e.g. after rejecting their friend
/// request, so re-sending it (with the same leaked/reused key) has no
/// effect. Also records their account UID (looked up from `friends.json`
/// if not passed in), so a re-request from a *new* relationship key on the
/// same account is caught too.
pub fn block_pubkey(storage_dir: String, pubkey: String) -> Result<(), String> {
    let uid = load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == pubkey)
        .map(|f| f.uid)
        .unwrap_or_default();
    block_pubkey_with_uid(&storage_dir, pubkey, uid)
}

/// Same as [block_pubkey], but for callers (like rejecting a friend
/// request) that already know the UID and aren't blocking an existing
/// `friends.json` entry to look it up from.
pub(crate) fn block_pubkey_with_uid(
    storage_dir: &str,
    pubkey: String,
    uid: String,
) -> Result<(), String> {
    let mut blocked = load_blocked_entries(storage_dir);
    if !blocked.iter().any(|e| e.pubkey == pubkey) {
        blocked.push(BlockedEntry { pubkey, uid });
    }
    save_blocked_entries(storage_dir, &blocked)
}

pub(crate) fn set_blocked_snapshot(storage_dir: &str, blocked: Vec<String>) -> Result<(), String> {
    // Backup slots only carry pubkeys today (see sync.rs); preserve any
    // already-known UIDs for pubkeys that still match, drop the rest.
    let existing = load_blocked_entries(storage_dir);
    let entries: Vec<BlockedEntry> = blocked
        .into_iter()
        .map(|pubkey| {
            let uid = existing
                .iter()
                .find(|e| e.pubkey == pubkey)
                .map(|e| e.uid.clone())
                .unwrap_or_default();
            BlockedEntry { pubkey, uid }
        })
        .collect();
    save_blocked_entries(storage_dir, &entries)
}

/// Reverses [block_pubkey] — removes a contact pubkey from the blocked
/// list, e.g. to resume a friendship that's still in `friends.json`
/// (blocking no longer removes the friend entry, only silences their
/// events until unblocked).
pub fn unblock_pubkey(storage_dir: String, pubkey: String) -> Result<(), String> {
    let mut blocked = load_blocked_entries(&storage_dir);
    blocked.retain(|e| e.pubkey != pubkey);
    save_blocked_entries(&storage_dir, &blocked)
}
