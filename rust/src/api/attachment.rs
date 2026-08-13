//! Image/file sharing in chat. NIP-44 (used for message text, see
//! `chat.rs`) caps plaintext at ~64KB, too small for most files, so the
//! file body is encrypted separately with a random per-attachment
//! XChaCha20-Poly1305 key (no practical size limit) and *that* ciphertext
//! is uploaded to a Blossom (BUD-01/BUD-02) server. Only the small key
//! itself (a few dozen bytes) is NIP-44-encrypted to the friend and sent
//! through the rumor. The server only ever sees opaque encrypted bytes;
//! only the two parties who can derive the NIP-44 shared secret (via
//! [derive_contact_keys]) can recover the key and decrypt the blob.

use crate::api::chat::{self, ChatAttachmentPayload, CHAT_ATTACHMENT_KIND};
use crate::api::friends;
use crate::api::keys::derive_contact_keys;
use crate::api::sync::runtime;
use crate::frb_generated::StreamSink;
use chacha20poly1305::aead::rand_core::{OsRng, RngCore};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{KeyInit, XChaCha20Poly1305};
use nostr::event::{Event, EventBuilder, Tag, TagKind};
use nostr::nips::nip44;
use nostr::{JsonUtil, Kind, PublicKey};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// Progress/outcome events for [send_chat_attachment], streamed back so the
/// UI can show a real upload progress ring instead of a spinner. A plain
/// struct (rather than a Rust enum) so flutter_rust_bridge doesn't need the
/// `freezed` codegen package just for this one stream — Dart checks `done`/
/// `error` to distinguish a terminal event from a progress tick.
#[derive(Clone)]
pub struct AttachmentUploadEvent {
    /// Share of the (encrypted) body written so far, `0.0..=1.0`.
    pub fraction: f64,
    pub done: bool,
    pub error: Option<String>,
}

pub(crate) const UPLOAD_TIMEOUT: Duration = Duration::from_secs(60);
/// Blossom auth events (kind 24242) are short-lived authorizations for a
/// single upload/download, not identity material — a few minutes is plenty
/// and limits how long a captured auth event stays replayable.
const AUTH_EXPIRY_SECS: i64 = 300;

/// reqwest's `rustls` feature verifies certificates via
/// `rustls-platform-verifier`, which on Android needs a Kotlin/JNI hook this
/// app doesn't wire up — so every HTTPS request silently fails TLS
/// verification on-device even though the server is reachable. We sidestep
/// that by building our own rustls `ClientConfig` from the bundled Mozilla
/// root store (the same `webpki-roots` set already used for relay `wss://`
/// connections via tokio-tungstenite) and handing it to reqwest directly.
pub(crate) fn http_client() -> reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let tls_config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            reqwest::Client::builder()
                .use_preconfigured_tls(tls_config)
                .build()
                .expect("failed to build reqwest client")
        })
        .clone()
}

fn upload_server_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("upload_server.json")
}

fn upload_servers_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("upload_servers.json")
}

/// Legacy single-URL config, from before servers became a list — kept only
/// so [load_upload_servers] can seed the new list from an already-configured
/// server on upgrade instead of silently forgetting it.
#[derive(serde::Serialize, serde::Deserialize)]
struct UploadServerConfig {
    url: String,
}

/// The set of configured Blossom-compatible upload servers, mirroring
/// [relay::RelayList]'s shape. `default_url` is the one actually used by
/// [send_chat_attachment]/[download_chat_attachment] unless a specific
/// server is passed in (e.g. after a user picks a fallback from the
/// switch-server dialog) — always kept a member of `urls`.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct UploadServerList {
    pub urls: Vec<String>,
    pub default_url: String,
}

/// Public Blossom servers used as the out-of-the-box default list so
/// image/file sending works without the user having to find and configure
/// their own server first — same reasoning as [relay::default_relays].
///
/// Not `blossom.primal.net`: it content-sniffs uploaded bytes and rejects
/// anything that isn't a recognized media format (HTTP 415), which is
/// incompatible with uploading NIP-44/XChaCha20-encrypted — and therefore
/// opaque — blobs. The three below all accept arbitrary
/// `application/octet-stream` blobs; verified with round-trip
/// upload/download tests during development.
fn default_upload_server_urls() -> Vec<String> {
    vec![
        "https://nostr.download".to_string(),
        "https://cdn.hzrd149.com".to_string(),
        "https://files.sovbit.host".to_string(),
    ]
}

/// Dart-callable accessor for [default_upload_server_urls] — lets the
/// settings screen offer a "reset to defaults" action.
pub fn default_upload_servers() -> Vec<String> {
    default_upload_server_urls()
}

/// Persists the full set of configured upload servers plus which one is the
/// default. `default_url` must be one of `urls`.
pub fn save_upload_servers(
    storage_dir: String,
    urls: Vec<String>,
    default_url: String,
) -> Result<(), String> {
    let list = UploadServerList { urls, default_url };
    let content = serde_json::to_string_pretty(&list).map_err(|e| e.to_string())?;
    std::fs::write(upload_servers_path(&storage_dir), content).map_err(|e| e.to_string())
}

/// The saved server list, or the built-in defaults if none has been saved
/// yet. Falls back to migrating a legacy single-URL `upload_server.json`
/// (from before servers became a list) so an already-configured server
/// isn't silently forgotten on upgrade.
pub fn load_upload_servers(storage_dir: String) -> UploadServerList {
    if let Some(list) = std::fs::read_to_string(upload_servers_path(&storage_dir))
        .ok()
        .and_then(|c| serde_json::from_str::<UploadServerList>(&c).ok())
    {
        return list;
    }
    if let Some(legacy_url) = std::fs::read_to_string(upload_server_path(&storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str::<UploadServerConfig>(&s).ok())
        .map(|c| c.url)
        .filter(|u| !u.is_empty())
    {
        let mut urls = vec![legacy_url.clone()];
        urls.extend(default_upload_server_urls().into_iter().filter(|u| *u != legacy_url));
        return UploadServerList { urls, default_url: legacy_url };
    }
    let urls = default_upload_server_urls();
    UploadServerList { default_url: urls[0].clone(), urls }
}

/// Blob descriptor returned by the Blossom server after a successful
/// upload — see BUD-02.
#[derive(serde::Deserialize)]
struct BlobDescriptor {
    url: String,
}

const STATUS_CHECK_TIMEOUT: Duration = Duration::from_secs(5);

/// Checks whether `url` currently responds, for the settings screen's
/// online/offline indicator — mirrors [relay::check_relay_statuses], but
/// over plain HTTP(S) rather than a WebSocket handshake since Blossom
/// servers speak HTTP.
pub fn check_upload_server_status(url: String) -> bool {
    if url.is_empty() {
        return false;
    }
    runtime().block_on(async {
        let request = http_client().head(&url).send();
        matches!(
            tokio::time::timeout(STATUS_CHECK_TIMEOUT, request).await,
            Ok(Ok(_))
        )
    })
}

async fn blossom_auth_event(
    keys: &nostr::Keys,
    verb: &str,
    sha256_hex: &str,
) -> Result<Event, String> {
    let expiration = (nostr::Timestamp::now().as_secs() as i64 + AUTH_EXPIRY_SECS).to_string();
    EventBuilder::new(Kind::Custom(24242), format!("{verb} chat attachment"))
        .tag(Tag::custom(TagKind::custom("t"), [verb.to_string()]))
        .tag(Tag::custom(TagKind::custom("x"), [sha256_hex.to_string()]))
        .tag(Tag::custom(TagKind::custom("expiration"), [expiration]))
        .sign(keys)
        .await
        .map_err(|e| e.to_string())
}

/// Encrypts `plaintext` with a fresh random XChaCha20-Poly1305 key+nonce —
/// shared by [upload_and_send] (1:1) and `group::send_group_attachment`, so
/// both encrypt file bodies the same way (see this module's doc comment for
/// why NIP-44 alone isn't used). Returns the 56-byte key+nonce (to be
/// NIP-44-encrypted separately, per recipient) and the ciphertext.
pub(crate) fn encrypt_attachment_bytes(plaintext: &[u8]) -> ([u8; 32 + 24], Vec<u8>) {
    let mut key_and_nonce = [0u8; 32 + 24];
    OsRng.fill_bytes(&mut key_and_nonce);
    let (key_bytes, nonce_bytes) = key_and_nonce.split_at(32);
    let cipher = XChaCha20Poly1305::new(key_bytes.into());
    let ciphertext = cipher
        .encrypt(nonce_bytes.into(), plaintext)
        .expect("XChaCha20-Poly1305 encryption of an in-memory buffer cannot fail");
    (key_and_nonce, ciphertext)
}

/// Inverse of [encrypt_attachment_bytes] — decrypts `ciphertext` given the
/// 56-byte key+nonce recovered from a NIP-44-decrypted `enc_key`.
pub(crate) fn decrypt_attachment_bytes(
    key_and_nonce: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>, String> {
    if key_and_nonce.len() != 32 + 24 {
        return Err("invalid attachment key".to_string());
    }
    let (key_bytes, nonce_bytes) = key_and_nonce.split_at(32);
    let cipher = XChaCha20Poly1305::new(key_bytes.into());
    cipher.decrypt(nonce_bytes.into(), ciphertext).map_err(|e| e.to_string())
}

/// Uploads already-encrypted `ciphertext` to `server` (BUD-02 `PUT /upload`,
/// authorized via a `blossom_auth_event`), streaming simulated progress
/// events to `sink` while the request is in flight (see [upload_and_send]'s
/// doc comment on why this is simulated rather than byte-exact) — shared by
/// 1:1 and group attachment sending, since the upload step itself (unlike
/// the per-recipient NIP-44 key wrapping) is identical either way and only
/// needs to happen once regardless of how many recipients there are.
/// Returns the server-assigned URL.
pub(crate) async fn upload_ciphertext(
    server: &str,
    mime_type: &str,
    ciphertext: Vec<u8>,
    sha256_hex: &str,
    keys: &nostr::Keys,
    sink: &StreamSink<AttachmentUploadEvent>,
) -> Result<String, String> {
    let auth = blossom_auth_event(keys, "upload", sha256_hex).await?;
    use base64::Engine as _;
    let auth_header = format!(
        "Nostr {}",
        base64::engine::general_purpose::STANDARD.encode(auth.as_json())
    );

    let progress_sink = sink.clone();
    let ticker_done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ticker_done_clone = ticker_done.clone();
    let ticker = tokio::spawn(async move {
        let mut fraction = 0.0f64;
        while !ticker_done_clone.load(Ordering::Relaxed) && fraction < 0.92 {
            tokio::time::sleep(Duration::from_millis(120)).await;
            fraction = (fraction + 0.08).min(0.92);
            let _ = progress_sink.add(AttachmentUploadEvent { fraction, done: false, error: None });
        }
    });

    let response = http_client()
        .put(format!("{}/upload", server.trim_end_matches('/')))
        .header("Authorization", auth_header)
        .header("Content-Type", mime_type)
        .timeout(UPLOAD_TIMEOUT)
        .body(ciphertext)
        .send()
        .await;
    ticker_done.store(true, Ordering::Relaxed);
    let _ = ticker.await;
    let response = response.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("upload failed: HTTP {}", response.status()));
    }
    let descriptor: BlobDescriptor = response.json().await.map_err(|e| e.to_string())?;
    Ok(descriptor.url)
}

/// Uploads plain (unencrypted) bytes to a Blossom server and returns the
/// resulting URL — unlike [upload_ciphertext] (1:1/group attachments, always
/// encrypted, streams progress), this is for content that's meant to be
/// publicly fetchable as-is, e.g. a Global Chat profile picture referenced
/// by URL from a NIP-01 kind-0 event. No progress reporting since these
/// uploads are small (avatar-sized) and synchronous from the caller's
/// perspective.
pub(crate) async fn upload_plain_bytes(
    server: &str,
    mime_type: &str,
    bytes: Vec<u8>,
    keys: &nostr::Keys,
) -> Result<String, String> {
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let sha256_hex = hex::encode(hasher.finalize());

    let auth = blossom_auth_event(keys, "upload", &sha256_hex).await?;
    use base64::Engine as _;
    let auth_header = format!(
        "Nostr {}",
        base64::engine::general_purpose::STANDARD.encode(auth.as_json())
    );

    let response = http_client()
        .put(format!("{}/upload", server.trim_end_matches('/')))
        .header("Authorization", auth_header)
        .header("Content-Type", mime_type)
        .timeout(UPLOAD_TIMEOUT)
        .body(bytes)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("upload failed: HTTP {}", response.status()));
    }
    let descriptor: BlobDescriptor = response.json().await.map_err(|e| e.to_string())?;
    Ok(descriptor.url)
}

/// Encrypts `plaintext` and uploads the ciphertext to `server`, returning a
/// single self-contained link (`<blossom-url>#<hex key+nonce>`) — the URL
/// fragment never leaves the device in an HTTP request (only the path is
/// sent to the server), so this one string is everything a recipient needs
/// to fetch and decrypt, with nothing else to transmit separately. Signed
/// with `keys`, which the caller should pick to control what the Blossom
/// server's `/list/<pubkey>` endpoint (if it has one) can link together —
/// see `keys::derive_avatar_upload_keys`'s doc for why a dedicated
/// never-shared key is used for account avatars rather than a per-relationship one.
pub(crate) async fn upload_encrypted_link(
    server: &str,
    plaintext: &[u8],
    keys: &nostr::Keys,
) -> Result<String, String> {
    let (key_and_nonce, ciphertext) = encrypt_attachment_bytes(plaintext);
    let url = upload_plain_bytes(server, "application/octet-stream", ciphertext, keys).await?;
    Ok(format!("{url}#{}", hex::encode(key_and_nonce)))
}

/// Downloads and decrypts a link produced by [upload_encrypted_link].
pub(crate) async fn download_encrypted_link(link: &str) -> Result<Vec<u8>, String> {
    let (url, key_hex) = link.split_once('#').ok_or("malformed encrypted link")?;
    let key_and_nonce = hex::decode(key_hex).map_err(|e| e.to_string())?;
    let ciphertext = download_ciphertext(url).await?;
    decrypt_attachment_bytes(&key_and_nonce, &ciphertext)
}

/// Downloads the ciphertext bytes at `url` — shared by 1:1 and group
/// attachment downloads.
pub(crate) async fn download_ciphertext(url: &str) -> Result<Vec<u8>, String> {
    let response = http_client()
        .get(url)
        .timeout(UPLOAD_TIMEOUT)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("download failed: HTTP {}", response.status()));
    }
    response.bytes().await.map(|b| b.to_vec()).map_err(|e| e.to_string())
}

/// Encrypts `file_path`'s bytes to `friend_pubkey` (same per-contact key as
/// [chat::send_chat_message]) and uploads the ciphertext to the configured
/// Blossom server — streaming progress events (`done: false`) as the body
/// is sent — then sends a small JSON pointer (URL + hash + optional
/// caption + original filename/mime type) as a chat message the same way a
/// text message is sent — sealed, gift-wrapped to the friend, and
/// self-echoed to our own relays so it shows up on our other devices too.
/// Terminates the stream with one `done: true` event (`error` set on
/// failure) — fire-and-forget from Dart's side, like
/// [crate::api::sync::subscribe_friend_events].
pub fn send_chat_attachment(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    file_path: String,
    mime_type: String,
    caption: Option<String>,
    reply_to: Option<String>,
    // Overrides the configured default server for this one send — used to
    // retry against a fallback the user picked from the switch-server
    // dialog after a failed upload, without changing their saved default.
    server_override: Option<String>,
    sink: StreamSink<AttachmentUploadEvent>,
) {
    runtime().spawn(async move {
        let result = upload_and_send(
            &mnemonic,
            &storage_dir,
            &friend_pubkey,
            &file_path,
            &mime_type,
            caption,
            reply_to,
            server_override,
            &sink,
        )
        .await;
        let _ = sink.add(AttachmentUploadEvent {
            fraction: 1.0,
            done: true,
            error: result.err(),
        });
    });
}

async fn upload_and_send(
    mnemonic: &str,
    storage_dir: &str,
    friend_pubkey: &str,
    file_path: &str,
    mime_type: &str,
    caption: Option<String>,
    reply_to: Option<String>,
    server_override: Option<String>,
    sink: &StreamSink<AttachmentUploadEvent>,
) -> Result<(), String> {
    let server = server_override.unwrap_or_else(|| load_upload_servers(storage_dir.to_string()).default_url);
    let friend = friends::load_friends(storage_dir.to_string())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    if friends::load_blocked(storage_dir).contains(&friend_pubkey.to_string()) {
        return Err("friend is blocked".to_string());
    }
    let keys = derive_contact_keys(mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(friend_pubkey).map_err(|e| e.to_string())?;

    let plaintext = std::fs::read(file_path).map_err(|e| e.to_string())?;
    let filename = Path::new(file_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());

    // NIP-44 caps plaintext at ~64KB, far too small for most files, so the
    // file body gets its own random XChaCha20-Poly1305 key (no size limit)
    // and only that key — a few dozen bytes — is sent through NIP-44.
    let (key_and_nonce, ciphertext_bytes) = encrypt_attachment_bytes(&plaintext);
    let size = ciphertext_bytes.len() as u32;
    let enc_key = nip44::encrypt(keys.secret_key(), &friend_pk, &key_and_nonce, nip44::Version::V2)
        .map_err(|e| e.to_string())?;

    let mut hasher = Sha256::new();
    hasher.update(&ciphertext_bytes);
    let sha256_hex = hex::encode(hasher.finalize());

    let url = upload_ciphertext(&server, mime_type, ciphertext_bytes, &sha256_hex, &keys, sink).await?;

    let payload = ChatAttachmentPayload {
        url,
        sha256: sha256_hex,
        size,
        mime_type: mime_type.to_string(),
        filename,
        enc_key,
        caption,
    };
    let content = serde_json::to_string(&payload).map_err(|e| e.to_string())?;

    chat::send_control_rumor_async(
        mnemonic,
        storage_dir,
        friend_pubkey,
        CHAT_ATTACHMENT_KIND,
        content,
        true,
        reply_to,
    )
    .await
}

/// Downloads and decrypts the attachment on `message_id` (a message
/// previously decoded with a non-null `attachment` field), caching the
/// plaintext bytes under `storage_dir` so repeat views (or the sender's own
/// copy) don't re-download/re-decrypt every time. Returns the local file
/// path.
pub fn download_chat_attachment(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message_id: String,
    url: String,
    enc_key: String,
) -> Result<String, String> {
    let cache_dir = Path::new(&storage_dir).join("attachments");
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;
    let cache_path = cache_dir.join(&message_id);
    if cache_path.exists() {
        return Ok(cache_path.to_string_lossy().to_string());
    }

    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    let keys = derive_contact_keys(&mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(&friend_pubkey).map_err(|e| e.to_string())?;

    let key_and_nonce = nip44::decrypt_to_bytes(keys.secret_key(), &friend_pk, enc_key)
        .map_err(|e| e.to_string())?;

    let ciphertext_bytes = runtime().block_on(download_ciphertext(&url))?;
    let plaintext = decrypt_attachment_bytes(&key_and_nonce, &ciphertext_bytes)?;

    std::fs::write(&cache_path, &plaintext).map_err(|e| e.to_string())?;
    Ok(cache_path.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_round_trips() {
        let plaintext = b"a chat attachment's file bytes".to_vec();
        let (key_and_nonce, ciphertext) = encrypt_attachment_bytes(&plaintext);
        let decrypted = decrypt_attachment_bytes(&key_and_nonce, &ciphertext).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn encrypt_decrypt_round_trips_on_empty_input() {
        let plaintext: Vec<u8> = vec![];
        let (key_and_nonce, ciphertext) = encrypt_attachment_bytes(&plaintext);
        let decrypted = decrypt_attachment_bytes(&key_and_nonce, &ciphertext).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn each_encryption_uses_a_fresh_key_and_nonce() {
        let plaintext = b"same plaintext, twice".to_vec();
        let (key_and_nonce_a, ciphertext_a) = encrypt_attachment_bytes(&plaintext);
        let (key_and_nonce_b, ciphertext_b) = encrypt_attachment_bytes(&plaintext);
        assert_ne!(key_and_nonce_a, key_and_nonce_b);
        assert_ne!(ciphertext_a, ciphertext_b);
    }

    #[test]
    fn decrypt_rejects_wrong_key() {
        let plaintext = b"secret file bytes".to_vec();
        let (_, ciphertext) = encrypt_attachment_bytes(&plaintext);
        let (wrong_key_and_nonce, _) = encrypt_attachment_bytes(b"unrelated");
        assert!(decrypt_attachment_bytes(&wrong_key_and_nonce, &ciphertext).is_err());
    }

    #[test]
    fn decrypt_rejects_tampered_ciphertext() {
        let plaintext = b"secret file bytes".to_vec();
        let (key_and_nonce, mut ciphertext) = encrypt_attachment_bytes(&plaintext);
        let last = ciphertext.len() - 1;
        ciphertext[last] ^= 0xFF;
        assert!(decrypt_attachment_bytes(&key_and_nonce, &ciphertext).is_err());
    }

    #[test]
    fn decrypt_rejects_malformed_key_length() {
        let plaintext = b"secret file bytes".to_vec();
        let (_, ciphertext) = encrypt_attachment_bytes(&plaintext);
        assert!(decrypt_attachment_bytes(&[0u8; 10], &ciphertext).is_err());
    }

    #[test]
    fn load_upload_servers_falls_back_to_defaults_when_unconfigured() {
        let dir = std::env::temp_dir().join(format!(
            "origilink-attachment-test-{}",
            nostr::Keys::generate().public_key().to_hex()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let list = load_upload_servers(dir.to_string_lossy().to_string());
        assert_eq!(list.urls, default_upload_server_urls());
        assert_eq!(list.default_url, default_upload_server_urls()[0]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn save_and_load_upload_servers_round_trips() {
        let dir = std::env::temp_dir().join(format!(
            "origilink-attachment-test-{}",
            nostr::Keys::generate().public_key().to_hex()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let dir_str = dir.to_string_lossy().to_string();
        let urls = vec!["https://a.example".to_string(), "https://b.example".to_string()];
        save_upload_servers(dir_str.clone(), urls.clone(), urls[1].clone()).unwrap();
        let list = load_upload_servers(dir_str);
        assert_eq!(list.urls, urls);
        assert_eq!(list.default_url, urls[1]);
        std::fs::remove_dir_all(&dir).ok();
    }
}
