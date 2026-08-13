use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Local account identity: display info persisted per-device.
#[derive(Serialize, Deserialize)]
pub struct Account {
    pub display_name: String,
    pub status_message: String,
    /// Absolute path to the avatar image file, if the user picked one.
    pub avatar_path: Option<String>,
    /// A self-contained encrypted link (`<blossom-url>#<hex key+nonce>`,
    /// see `attachment::upload_encrypted_link`) for the same image
    /// `avatar_path` points to — computed once per avatar change (via
    /// [upload_account_avatar_link]) and reused for every friend
    /// request/accept/profile-update/self-backup instead of re-uploading a
    /// fresh (undeduplicatable — each upload uses a random key) copy of the
    /// same bytes every time one of those fires.
    #[serde(default)]
    pub avatar_link: Option<String>,
    /// Unix timestamp (seconds) of the last local edit. Used to decide
    /// whether the local copy or the relay-synced backup is newer.
    #[serde(default)]
    pub updated_at: i64,
}

fn account_path(storage_dir: &str) -> PathBuf {
    Path::new(storage_dir).join("account.json")
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Writes `bytes` under a content-hash-suffixed filename in `storage_dir`
/// and deletes any previous `account_avatar_*` file. Flutter's
/// `FileImage`/`ImageCache` keys purely by path string (see `sync.rs`'s
/// `save_friend_avatar`, which fixes the same issue for friend avatars) —
/// reusing one fixed filename across edits means the new bytes land on disk
/// but every already-cached widget (e.g. the account card) keeps painting
/// the old bitmap for that unchanged path. Shared by both ways this
/// device's own avatar can change: a local edit ([save_account_avatar]) and
/// a newer copy pulled from a relay backup ([save_account_avatar_base64],
/// and `sync.rs`'s live-sync handling of the same backup slot).
pub(crate) fn write_avatar_bytes(storage_dir: &str, bytes: &[u8], extension: &str) -> Option<String> {
    let hash = hex::encode(Sha256::digest(bytes));
    let file_name = format!("account_avatar_{hash}.{extension}");
    let dir = Path::new(storage_dir);
    let dest = dir.join(&file_name);
    fs::write(&dest, bytes).ok()?;
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("account_avatar_") && name != file_name {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    Some(dest.to_string_lossy().to_string())
}

/// Copies a freshly-picked avatar image into permanent per-account storage.
/// Returns `None` if `picked_path` couldn't be read.
pub fn save_account_avatar(storage_dir: String, picked_path: String) -> Option<String> {
    let bytes = fs::read(&picked_path).ok()?;
    let extension = Path::new(&picked_path).extension().and_then(|e| e.to_str()).unwrap_or("jpg");
    write_avatar_bytes(&storage_dir, &bytes, extension)
}

/// Encrypts the avatar at `avatar_path` and uploads it to the configured
/// Blossom server, returning a self-contained encrypted link (see
/// `attachment::upload_encrypted_link`). Call once whenever the avatar
/// actually changes — the result is meant to be persisted via `save_account`
/// (`avatar_link`) and then reused as-is by every friend request/accept/
/// profile-update/self-backup, rather than re-uploading a fresh copy of the
/// same bytes on each one. Signed with a dedicated per-device key
/// (`keys::derive_avatar_upload_keys`) never shared with anyone — see that
/// function's doc for why.
/// `previous_avatar_link` (the value being replaced, if any) is best-effort
/// deleted from the Blossom server after the new upload succeeds, so
/// replacing an avatar repeatedly doesn't leave every past encrypted copy
/// sitting there forever — failures (server doesn't support delete, offline,
/// already gone) are silently ignored since cleanup isn't essential to the
/// replace itself succeeding.
pub fn upload_account_avatar_link(
    mnemonic: String,
    storage_dir: String,
    avatar_path: String,
    previous_avatar_link: Option<String>,
) -> Result<String, String> {
    let bytes = fs::read(&avatar_path).map_err(|e| e.to_string())?;
    let keys = crate::api::keys::derive_avatar_upload_keys(&mnemonic)?;
    let server = crate::api::attachment::load_upload_servers(storage_dir).default_url;
    let link = crate::api::sync::runtime()
        .block_on(crate::api::attachment::upload_encrypted_link(&server, &bytes, &keys))?;
    if let Some(previous) = previous_avatar_link {
        if let Some((previous_url, _)) = previous.split_once('#') {
            let _ = crate::api::sync::runtime()
                .block_on(crate::api::attachment::delete_blossom_blob(previous_url, &keys));
        }
    }
    Ok(link)
}

/// Deletes this account's currently-uploaded avatar blob from the Blossom
/// server — called on account deletion, since nothing will ever reference
/// it again once the local account is wiped. Best-effort: the caller should
/// ignore failures (offline, server doesn't support delete, already gone).
pub fn delete_account_avatar_blob(mnemonic: String, avatar_link: String) -> Result<(), String> {
    let (url, _) = avatar_link.split_once('#').ok_or("malformed encrypted link")?;
    let keys = crate::api::keys::derive_avatar_upload_keys(&mnemonic)?;
    crate::api::sync::runtime().block_on(crate::api::attachment::delete_blossom_blob(url, &keys))
}

/// Downloads and decrypts an encrypted avatar link (from a friend's
/// [FriendPayload]-style exchange or this account's own relay-hosted
/// backup) and caches the plaintext bytes locally, the same
/// content-hash-suffixed way as a locally-picked avatar.
pub fn save_account_avatar_link(storage_dir: String, avatar_link: String) -> Option<String> {
    let bytes = crate::api::sync::runtime()
        .block_on(crate::api::attachment::download_encrypted_link(&avatar_link))
        .ok()?;
    write_avatar_bytes(&storage_dir, &bytes, "png")
}

/// Saves the account as JSON under `storage_dir`, stamping `updated_at` with
/// the current time. `storage_dir` must already exist (e.g. the app's
/// documents directory, resolved on the Dart side via path_provider).
pub fn save_account(
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
    avatar_link: Option<String>,
) -> Result<(), String> {
    let account = Account {
        display_name,
        status_message,
        avatar_path,
        avatar_link,
        updated_at: now(),
    };
    let content = serde_json::to_string_pretty(&account).map_err(|e| e.to_string())?;
    fs::write(account_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Saves the account as JSON under `storage_dir` with an explicit
/// `updated_at`, used when overwriting the local copy with a newer backup
/// pulled from a relay (so the local timestamp matches the relay's).
pub fn save_account_with_timestamp(
    storage_dir: String,
    display_name: String,
    status_message: String,
    avatar_path: Option<String>,
    avatar_link: Option<String>,
    updated_at: i64,
) -> Result<(), String> {
    let account = Account {
        display_name,
        status_message,
        avatar_path,
        avatar_link,
        updated_at,
    };
    let content = serde_json::to_string_pretty(&account).map_err(|e| e.to_string())?;
    fs::write(account_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// Loads a previously saved account, or `None` if none has been saved yet.
pub fn load_account(storage_dir: String) -> Option<Account> {
    let content = fs::read_to_string(account_path(&storage_dir)).ok()?;
    serde_json::from_str(&content).ok()
}
