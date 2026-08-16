use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A single-use-or-limited-use invite: a dedicated NIP-06 `account` index
/// (see `keys::derive_contact_keys`) shown as a QR code, that a scanning
/// friend sends their friend request to. Kept separate from the account's
/// core identity so a leaked invite only exposes itself, never other
/// friends or the account backup identity (account 0).
#[derive(Serialize, Deserialize, Clone)]
pub struct Invite {
    pub account_index: u32,
    pub created_at: i64,
    /// `None` means no expiry.
    pub expires_at: Option<i64>,
    /// `None` means unlimited uses.
    pub max_uses: Option<u32>,
    pub use_count: u32,
    pub revoked: bool,
}

impl Invite {
    pub fn is_active(&self, now: i64) -> bool {
        if self.revoked {
            return false;
        }
        if let Some(expires_at) = self.expires_at {
            if now >= expires_at {
                return false;
            }
        }
        if let Some(max_uses) = self.max_uses {
            if self.use_count >= max_uses {
                return false;
            }
        }
        true
    }
}

#[derive(Serialize, Deserialize, Default)]
#[flutter_rust_bridge::frb(ignore)]
struct InvitesFile {
    next_account_index: u32,
    invites: Vec<Invite>,
}

fn invites_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("invites.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn load_file(storage_dir: &str) -> InvitesFile {
    fs::read_to_string(invites_path(storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_else(|| InvitesFile {
            // Account indices 0..=0 are reserved for the core account
            // identity; contacts/invites start from 1.
            next_account_index: 1,
            invites: Vec::new(),
        })
}

fn save_file(storage_dir: &str, file: &InvitesFile) -> Result<(), String> {
    let content = serde_json::to_string_pretty(file).map_err(|e| e.to_string())?;
    fs::write(invites_path(storage_dir), content).map_err(|e| e.to_string())
}

/// Creates a new invite with a freshly-allocated `account` index, never
/// reused even if this invite is later revoked or expires.
///
/// `ttl_seconds`: `None` for no expiry. `max_uses`: `None` for unlimited.
pub fn create_invite(
    storage_dir: String,
    ttl_seconds: Option<i64>,
    max_uses: Option<u32>,
) -> Result<Invite, String> {
    let mut file = load_file(&storage_dir);
    let account_index = file.next_account_index;
    file.next_account_index += 1;

    let created_at = now();
    let invite = Invite {
        account_index,
        created_at,
        expires_at: ttl_seconds.map(|ttl| created_at + ttl),
        max_uses,
        use_count: 0,
        revoked: false,
    };
    file.invites.push(invite.clone());
    save_file(&storage_dir, &file)?;
    Ok(invite)
}

/// Allocates a fresh `account` index without creating an [Invite] record —
/// used when accepting a friend request, where the relationship's key is
/// minted on the spot rather than shown as a QR beforehand.
pub(crate) fn allocate_account_index(storage_dir: &str) -> Result<u32, String> {
    let mut file = load_file(storage_dir);
    let index = file.next_account_index;
    file.next_account_index += 1;
    save_file(storage_dir, &file)?;
    Ok(index)
}

/// Lists all invites (active and inactive) this device has created.
pub fn list_invites(storage_dir: String) -> Vec<Invite> {
    load_file(&storage_dir).invites
}

pub(crate) fn next_account_index(storage_dir: &str) -> u32 {
    load_file(storage_dir).next_account_index
}

/// Replaces the invite list from a newer backup and fast-forwards the
/// index counter to at least `next_account_index` — never moves it
/// backward, since indices already allocated locally (for invites,
/// accepted friends, or outgoing requests) must never be reused.
pub(crate) fn set_invites_snapshot(
    storage_dir: &str,
    next_account_index: u32,
    invites: Vec<Invite>,
) -> Result<(), String> {
    let mut file = load_file(storage_dir);
    file.next_account_index = file.next_account_index.max(next_account_index);
    file.invites = invites;
    save_file(storage_dir, &file)
}

/// Lists only currently-usable invites (not revoked, not expired, not
/// over their use limit) — the ones that should be polled for incoming
/// friend requests.
pub fn list_active_invites(storage_dir: String) -> Vec<Invite> {
    let now = now();
    load_file(&storage_dir)
        .invites
        .into_iter()
        .filter(|invite| invite.is_active(now))
        .collect()
}

/// Marks an invite as revoked so it's no longer polled for requests, even
/// if not expired or used up yet.
pub fn revoke_invite(storage_dir: String, account_index: u32) -> Result<(), String> {
    let mut file = load_file(&storage_dir);
    for invite in file.invites.iter_mut() {
        if invite.account_index == account_index {
            invite.revoked = true;
        }
    }
    save_file(&storage_dir, &file)
}

/// Records that an invite was used — a friend request from a new
/// requester arrived against it — incrementing its use count. Called as
/// soon as the request is received (see `sync.rs`'s `Watch::Invite`
/// handler), not when it's later accepted, so `max_uses` caps how many
/// strangers can even queue up a request against a leaked invite, not just
/// how many get accepted.
pub fn record_invite_use(storage_dir: String, account_index: u32) -> Result<(), String> {
    let mut file = load_file(&storage_dir);
    for invite in file.invites.iter_mut() {
        if invite.account_index == account_index {
            invite.use_count += 1;
        }
    }
    save_file(&storage_dir, &file)
}
