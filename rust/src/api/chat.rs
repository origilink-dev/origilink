//! One-to-one chat, built on NIP-17-style gift-wrapped direct messages
//! (NIP-59): each message is wrapped in a `Seal` (kind 13, signed by the
//! sender's per-contact key, so authenticity is provable) which is itself
//! wrapped in a `Gift Wrap` (kind 1059, signed by a single-use random key
//! and NIP-44-encrypted to the recipient) before publishing. The Gift Wrap
//! layer is discarded after unwrapping — only the `Seal` (a normal signed
//! event, still content-encrypted) is persisted locally, so data at rest
//! never contains plaintext.
//!
//! Local storage uses `nostr-lmdb` (unlike the rest of `api`, which uses
//! plain JSON files) because chat history is genuinely a log of Nostr
//! events that benefits from being queried by kind/author/time — the same
//! store this module uses today for one-to-one Seals will hold group and
//! public-room events later.

use crate::api::friends;
use crate::api::keys::derive_contact_keys;
use crate::api::relay;
use crate::api::sync::{publish_to_relays, runtime};
use crate::relay_pool;
use futures_util::future::join_all;
use nostr::event::{Event, EventBuilder, UnsignedEvent};
use nostr::nips::nip44;
use nostr::{Filter, JsonUtil, Keys, Kind, PublicKey, Timestamp};
use nostr_database::NostrDatabase;
use nostr_lmdb::NostrLMDB;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

fn db_cell() -> &'static Mutex<Option<Arc<NostrLMDB>>> {
    static CELL: OnceLock<Mutex<Option<Arc<NostrLMDB>>>> = OnceLock::new();
    CELL.get_or_init(|| Mutex::new(None))
}

pub(crate) fn db(storage_dir: &str) -> Arc<NostrLMDB> {
    let mut slot = db_cell().lock().expect("chat db lock poisoned");
    if let Some(db) = slot.as_ref() {
        return db.clone();
    }
    let path = Path::new(storage_dir).join("chat.lmdb");
    let db = Arc::new(NostrLMDB::open(path).expect("failed to open chat database"));
    *slot = Some(db.clone());
    db
}

/// Drops the cached chat database handle so the next access reopens it from
/// disk. Every account shares the same on-device storage directory, so
/// logging out (which deletes `chat.lmdb`) would otherwise leave this
/// process holding a handle into files that no longer exist — call this
/// right after wiping local storage, before a different account can log in
/// within the same app run.
pub fn reset_chat_db() {
    *db_cell().lock().expect("chat db lock poisoned") = None;
}

/// A single decrypted message, ready to show in the UI.
#[derive(Clone)]
pub struct ChatMessage {
    pub id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: i64,
    pub is_mine: bool,
    /// Whether [edit_chat_message] has been applied to this message —
    /// `content` already reflects the latest edit; this just controls
    /// whether the UI shows an "(edited)" hint.
    pub is_edited: bool,
    /// Whether [delete_chat_message] has been applied — `content` is
    /// cleared to empty; the UI should show a "message deleted" placeholder
    /// instead of the (now-empty) content.
    pub is_deleted: bool,
    /// The `id` of the message this one is replying to, if any — carried as
    /// a standard NIP-10 `e` tag on the rumor, so it survives independent
    /// of our own overlay mechanisms (unlike edit/delete/hide/clear, a
    /// reply reference is just ordinary message metadata, not an
    /// instruction). The UI resolves it against its own already-loaded
    /// history to render a quoted preview.
    pub reply_to: Option<String>,
    /// Set instead of meaningful `content` (which holds just the original
    /// filename as a fallback label) when this message is an image/file
    /// share — see `attachment.rs`.
    pub attachment: Option<ChatAttachment>,
}

/// Custom rumor kinds wrapped the same way as a normal chat message (Seal +
/// Gift Wrap, addressed to the friend and self-echoed) but carrying an
/// edit/delete instruction instead of new message content. Kept as regular
/// rumors — not a separate relay-visible event kind — since a stranger
/// reading relay traffic can't even tell a Gift Wrap is a chat message, let
/// alone that it's an edit; there's no metadata leak to trade off here.
const CHAT_EDIT_KIND: Kind = Kind::Custom(30115);
const CHAT_DELETE_KIND: Kind = Kind::Custom(30116);
/// Unlike edit/delete, never published to the friend (see [hide_message])
/// — but sealed and shaped the same way, so it rides the same relay-backed
/// event log rather than a locally-growing state file that has to be
/// serialized whole into a single sync event every time it changes.
const CHAT_HIDE_KIND: Kind = Kind::Custom(30117);
/// Like [CHAT_HIDE_KIND], self-only — clearing a thread never notifies the
/// friend. Carries no payload: the rumor's own `created_at` *is* the cutoff
/// (see [DecodedSeal::Clear]), so there's nothing else to serialize.
const CHAT_CLEAR_KIND: Kind = Kind::Custom(30118);
/// An image/file share (see `attachment.rs`) — notified to the friend like
/// a normal message (unlike Edit/Delete/Hide/Clear), but decoded into a
/// [ChatMessage] with `attachment` populated instead of `content`.
pub(crate) const CHAT_ATTACHMENT_KIND: Kind = Kind::Custom(30119);
/// Announces this device's forward-secrecy ratchet identity public key to a
/// friend — see `ratchet.rs`'s module doc. Carried over this same
/// Seal/Gift-Wrap channel (so it benefits from the same sender
/// authentication) but ignored by [decode_seal]/[load_chat_history]; only
/// `ratchet.rs`'s own decoder acts on it.
pub(crate) const DEVICE_ANNOUNCE_KIND: Kind = Kind::Custom(30140);
/// A message encrypted with `ratchet.rs`'s Double Ratchet session, nested
/// inside this same outer Seal/Gift-Wrap transport. Also ignored by
/// [decode_seal] — `ratchet.rs` decodes and decrypts it separately, since
/// (unlike every other message kind here) it can only be decrypted once,
/// at receive time, not re-derived from the mnemonic on a later
/// [load_chat_history] call.
pub(crate) const RATCHET_MESSAGE_KIND: Kind = Kind::Custom(30141);
/// A group-chat membership/message rumor — see `groups.rs`'s module doc.
/// Also ignored by [decode_seal] for the same reason as the ratchet kinds
/// above: `groups.rs` has its own decoder, and without this exclusion an
/// unrecognized kind falls through to the plain-message case below and
/// gets shown as a garbled text message instead of being handled as a
/// group event.
pub(crate) const GROUP_INVITE_KIND: Kind = Kind::Custom(30150);
pub(crate) const GROUP_MESSAGE_KIND: Kind = Kind::Custom(30151);
/// A group-chat image/file attachment pointer — see `groups.rs`'s
/// `GroupAttachmentPayload`. Also ignored by [decode_seal] for the same
/// reason as the other group kinds above.
pub(crate) const GROUP_ATTACHMENT_KIND: Kind = Kind::Custom(30152);

#[derive(serde::Serialize, serde::Deserialize)]
struct ChatEditPayload {
    message_id: String,
    content: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct ChatDeletePayload {
    message_id: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct ChatHidePayload {
    message_id: String,
}

/// Pointer to an encrypted blob on a Blossom-compatible server — see
/// `attachment.rs`'s module doc for the encryption scheme. Carried as the
/// rumor's `content` (JSON), the same way a text message carries plain
/// text.
#[derive(serde::Serialize, serde::Deserialize)]
pub(crate) struct ChatAttachmentPayload {
    pub url: String,
    pub sha256: String,
    pub size: u32,
    pub mime_type: String,
    pub filename: String,
    /// The file's random per-attachment XChaCha20-Poly1305 key+nonce,
    /// itself NIP-44-encrypted to the friend — see `attachment.rs`'s module
    /// doc. NIP-44 has a ~64KB plaintext cap, too small for most files, so
    /// the file body is encrypted with this separate key instead; only the
    /// (tiny) key needs to fit through NIP-44.
    pub enc_key: String,
    /// Optional caption typed alongside the file, shown under the
    /// image/file chip like a normal chat bubble.
    pub caption: Option<String>,
}

/// An image/file attachment resolved from a [ChatAttachmentPayload] —
/// exposed on [ChatMessage] so the UI can render a thumbnail/file chip
/// instead of (or alongside) the placeholder text in `content`.
#[derive(Clone)]
pub struct ChatAttachment {
    pub url: String,
    pub sha256: String,
    pub size: u32,
    pub mime_type: String,
    pub filename: String,
    pub enc_key: String,
    pub caption: Option<String>,
}

/// Message length cap (characters), enforced by [send_chat_message] — a
/// generous limit for a chat bubble, mainly there to stop a single event
/// from ballooning (NIP-44 encryption inflates size further) rather than
/// to constrain normal conversation.
pub const MAX_MESSAGE_CHARS: usize = 4000;

/// Dart-callable accessor for [MAX_MESSAGE_CHARS] — lets the composer
/// enforce the same limit client-side instead of only finding out via a
/// failed [send_chat_message] call.
pub fn max_message_chars() -> u32 {
    MAX_MESSAGE_CHARS as u32
}

/// Builds a Gift Wrap for `message` addressed to `friend_pubkey`, persists
/// our own copy of the `Seal` locally (so our own sent messages show up in
/// [load_chat_history] immediately, even offline or if publishing fails),
/// and publishes it to the friend's relays.
///
/// Also wraps the same `Seal` a second time for ourselves and publishes it
/// to our own relays — the friend's relays have no reason to keep an event
/// we sent *them*, but this self-addressed copy means our own subscription
/// (which watches our own relays) can refetch our sent messages after a
/// reinstall or on another device, instead of them existing only in this
/// one local database. Best-effort: a failure to publish this copy doesn't
/// fail the send, since the message already reached the friend either way.
pub fn send_chat_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message: String,
    reply_to: Option<String>,
) -> Result<(), String> {
    if message.chars().count() > MAX_MESSAGE_CHARS {
        return Err("message too long".to_string());
    }
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    if friends::load_blocked(&storage_dir).contains(&friend_pubkey) {
        return Err("friend is blocked".to_string());
    }
    let keys = derive_contact_keys(&mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(&friend_pubkey).map_err(|e| e.to_string())?;
    let my_relays = relay::load_relay_list(storage_dir.clone()).urls;
    // A malformed/unknown id just silently drops the reply reference rather
    // than failing the send — the message itself is still valid without it.
    let reply_tag = reply_to
        .as_deref()
        .and_then(|id| nostr::EventId::from_hex(id).ok())
        .map(nostr::Tag::event);

    runtime().block_on(async {
        let rumor: UnsignedEvent = EventBuilder::private_msg_rumor(friend_pk, message)
            .tag_maybe(reply_tag)
            .build(keys.public_key());
        let seal: Event = EventBuilder::seal(&keys, &friend_pk, rumor)
            .await
            .map_err(|e| e.to_string())?
            .sign(&keys)
            .await
            .map_err(|e| e.to_string())?;
        let wrap_to_friend: Event = EventBuilder::gift_wrap_from_seal(&friend_pk, &seal, [])
            .map_err(|e| e.to_string())?;
        let wrap_to_self: Event =
            EventBuilder::gift_wrap_from_seal(&keys.public_key(), &seal, [])
                .map_err(|e| e.to_string())?;

        db(&storage_dir)
            .save_event(&seal)
            .await
            .map_err(|e| e.to_string())?;
        publish_to_relays(&friend.relays, &wrap_to_friend).await?;
        let _ = publish_to_relays(&my_relays, &wrap_to_self).await;
        Ok(())
    })
}

/// Publishes an edit instruction for a message this account previously
/// sent to `friend_pubkey`, identified by `message_id` (the original
/// `ChatMessage.id`, i.e. the shared Seal id). Wrapped and published the
/// same way as [send_chat_message] (to the friend, plus a self-addressed
/// copy). [load_chat_history] only applies the edit if `message_id`'s
/// original Seal was signed by the same key as this edit instruction — so
/// only the original sender can edit their own message, even though the
/// edit instruction itself carries no other proof of ownership.
pub fn edit_chat_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message_id: String,
    content: String,
) -> Result<(), String> {
    if content.chars().count() > MAX_MESSAGE_CHARS {
        return Err("message too long".to_string());
    }
    send_control_rumor(
        &mnemonic,
        &storage_dir,
        &friend_pubkey,
        CHAT_EDIT_KIND,
        serde_json::to_string(&ChatEditPayload { message_id, content }).map_err(|e| e.to_string())?,
        true,
        None,
    )
}

/// Publishes a delete instruction for a message this account previously
/// sent to `friend_pubkey` — see [edit_chat_message] for the delivery and
/// authorization details, which are identical.
pub fn delete_chat_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message_id: String,
) -> Result<(), String> {
    send_control_rumor(
        &mnemonic,
        &storage_dir,
        &friend_pubkey,
        CHAT_DELETE_KIND,
        serde_json::to_string(&ChatDeletePayload { message_id }).map_err(|e| e.to_string())?,
        true,
        None,
    )
}

/// Hides `message_id` (either side's) for this account only — never sent
/// to the friend, only self-addressed and published to our own relays, so
/// it propagates to this account's *other devices* the same way a sent
/// message does, without a separate locally-growing state file (compare
/// the old `hidden_messages.json` approach: every hide had to rewrite and
/// re-sync the *entire* list, which would eventually hit relay event-size
/// limits). [load_chat_history] applies it — dropping the message
/// entirely, unlike edit/delete which leave a visible trace — whenever the
/// hide instruction's signer matches our own key for this relationship;
/// nothing else needs to check who hid what, since a hide is never
/// visible to anyone but the account that made it.
pub fn hide_message(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    message_id: String,
) -> Result<(), String> {
    send_control_rumor(
        &mnemonic,
        &storage_dir,
        &friend_pubkey,
        CHAT_HIDE_KIND,
        serde_json::to_string(&ChatHidePayload { message_id }).map_err(|e| e.to_string())?,
        false,
        None,
    )
}

/// Shared plumbing for [edit_chat_message]/[delete_chat_message]/
/// [hide_message]/[clear_chat_history]/`attachment::send_chat_attachment`:
/// wraps `content` (already-serialized JSON) as a rumor of `kind`, seals it
/// to the friend's contact pubkey (so [decode_seal] can always decrypt it
/// the same way regardless of whether the friend ever actually receives a
/// copy — NIP-44 encryption is symmetric to however it was derived, not
/// tied to delivery), and publishes a self-addressed copy to our own
/// relays. When `notify_friend` is true (edit/delete/attachment), also
/// gift-wraps and publishes a friend-addressed copy to their relays; a
/// hide/clear never does. Saves the Seal locally either way, so the effect
/// is visible in [load_chat_history] immediately rather than waiting on the
/// self-addressed copy to round-trip back through the live subscription.
pub(crate) fn send_control_rumor(
    mnemonic: &str,
    storage_dir: &str,
    friend_pubkey: &str,
    kind: Kind,
    content: String,
    notify_friend: bool,
    reply_to: Option<String>,
) -> Result<(), String> {
    runtime().block_on(send_control_rumor_async(
        mnemonic,
        storage_dir,
        friend_pubkey,
        kind,
        content,
        notify_friend,
        reply_to,
    ))
}

/// Async core of [send_control_rumor] — callable with `.await` from code
/// that's already running on [runtime] (e.g. `attachment::upload_and_send`,
/// spawned via `runtime().spawn`), where calling the sync wrapper would
/// nest a second `block_on` on the same runtime and panic.
pub(crate) async fn send_control_rumor_async(
    mnemonic: &str,
    storage_dir: &str,
    friend_pubkey: &str,
    kind: Kind,
    content: String,
    notify_friend: bool,
    reply_to: Option<String>,
) -> Result<(), String> {
    let friend = friends::load_friends(storage_dir.to_string())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;
    if notify_friend && friends::load_blocked(storage_dir).contains(&friend_pubkey.to_string()) {
        return Err("friend is blocked".to_string());
    }
    let keys = derive_contact_keys(mnemonic, friend.my_account_index)?;
    let friend_pk = PublicKey::from_hex(friend_pubkey).map_err(|e| e.to_string())?;
    let my_relays = relay::load_relay_list(storage_dir.to_string()).urls;
    let reply_tag = reply_to
        .as_deref()
        .and_then(|id| nostr::EventId::from_hex(id).ok())
        .map(nostr::Tag::event);

    let rumor: UnsignedEvent = EventBuilder::new(kind, content)
        .tag_maybe(reply_tag)
        .build(keys.public_key());
    let seal: Event = EventBuilder::seal(&keys, &friend_pk, rumor)
        .await
        .map_err(|e| e.to_string())?
        .sign(&keys)
        .await
        .map_err(|e| e.to_string())?;
    let wrap_to_self: Event = EventBuilder::gift_wrap_from_seal(&keys.public_key(), &seal, [])
        .map_err(|e| e.to_string())?;

    db(storage_dir)
        .save_event(&seal)
        .await
        .map_err(|e| e.to_string())?;

    if notify_friend {
        let wrap_to_friend: Event = EventBuilder::gift_wrap_from_seal(&friend_pk, &seal, [])
            .map_err(|e| e.to_string())?;
        publish_to_relays(&friend.relays, &wrap_to_friend).await?;
    }
    let _ = publish_to_relays(&my_relays, &wrap_to_self).await;
    Ok(())
}

const HISTORY_FETCH_TIMEOUT: Duration = Duration::from_secs(5);

/// Fetches up to `limit` of the newest Seals (older than `before`, a Unix
/// timestamp, if given) with `friend_pubkey` directly from relays — via
/// [relay_pool::request], a one-shot query that waits for each relay's
/// `EOSE` (or `HISTORY_FETCH_TIMEOUT`) before returning, unlike the
/// long-running live subscription which streams historical backlog
/// interleaved with real-time events with no such boundary. Saves
/// everything fetched into `chat.lmdb`, then returns via
/// [load_chat_history] — so by the time a caller (e.g. opening a thread
/// for the first time, or scrolling up for an older page) sees anything,
/// any edit/delete that was published in the same batch as its target has
/// already been applied, instead of the original content flashing on
/// screen first.
///
/// Queries the union of the friend's relays and our own — a message and
/// any later edit/delete for it are always published to that same set (see
/// [send_chat_message]/`send_control_rumor`), so this doesn't need to
/// track relay lists per-identity.
pub fn fetch_chat_history_page(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
    before: Option<i64>,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;

    let identities: Vec<(String, u32)> = std::iter::once((friend.pubkey.clone(), friend.my_account_index))
        .chain(friend.prior_identities.iter().map(|p| (p.pubkey.clone(), p.my_account_index)))
        .collect();

    let mut relay_urls: std::collections::HashSet<String> =
        relay::load_relay_list(storage_dir.clone()).urls.into_iter().collect();
    relay_urls.extend(friend.relays.iter().cloned());

    runtime().block_on(async {
        for (contact_pubkey, account_index) in &identities {
            let Ok(keys) = derive_contact_keys(&mnemonic, *account_index) else {
                continue;
            };
            let Ok(friend_pk) = PublicKey::from_hex(contact_pubkey) else {
                continue;
            };
            let mut filter = Filter::new()
                .kind(Kind::Seal)
                .authors([keys.public_key(), friend_pk])
                .limit(limit as usize);
            if let Some(before) = before {
                // `-1`: `.until()` is inclusive, and `before` is always the
                // createdAt of the oldest message already loaded (see
                // [_loadOlderMessages]'s doc comment) — without this, that
                // message counts against `limit` again on every subsequent
                // page, wasting one slot of the page each time.
                filter = filter.until(Timestamp::from((before.max(1) as u64).saturating_sub(1)));
            }
            let results = join_all(
                relay_urls.iter().map(|url| relay_pool::request(url, &filter, HISTORY_FETCH_TIMEOUT)),
            )
            .await;
            for events in results {
                for event in events {
                    let _ = db(&storage_dir).save_event(&event).await;
                }
            }
        }
    });

    let result = load_chat_history(mnemonic, storage_dir.clone(), friend_pubkey.clone())?;

    // Only a `before`-bounded page (i.e. [_loadOlderMessages] scrolling up
    // for more, not the initial reconcile fetch) can tell us anything about
    // running out of history. Checking the *filtered* result's oldest
    // message against `before` — not just whether relays returned
    // anything — matters because a relay can still legitimately have
    // real Seals older than a [clear_chat_history] cutoff; those get
    // fetched and saved same as any other, but [load_chat_history] hides
    // them, so from the caller's perspective nothing new became visible
    // either way. Recording that here lets [has_more_chat_history] skip
    // the relay round-trip entirely next time this thread is reopened,
    // instead of re-discovering "no more" via a wasted EOSE wait on every
    // single reopen and every scroll back to the top.
    if let Some(before) = before {
        let got_older = result.first().is_some_and(|m| m.created_at < before);
        if !got_older {
            mark_history_complete(&storage_dir, &friend_pubkey);
        }
    }

    Ok(result)
}

fn history_complete_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_history_complete.json")
}

/// Pubkeys of friends whose full message history is already known to be
/// fully synced from relays — see [fetch_chat_history_page]'s `before.is_some()`
/// branch, the only place this gets set.
fn load_history_complete(storage_dir: &str) -> Vec<String> {
    std::fs::read_to_string(history_complete_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn mark_history_complete(storage_dir: &str, friend_pubkey: &str) {
    let mut complete = load_history_complete(storage_dir);
    if !complete.iter().any(|p| p == friend_pubkey) {
        complete.push(friend_pubkey.to_string());
        let _ = std::fs::write(
            history_complete_path(storage_dir),
            serde_json::to_string(&complete).unwrap_or_default(),
        );
    }
}

/// Whether [_loadOlderMessages]-style pagination should even bother asking
/// relays for more — false once [fetch_chat_history_page] has already
/// established (via an empty `before`-bounded page) that nothing older
/// exists, so the Dart side can skip straight to "no more" without a relay
/// round-trip every time the thread is reopened and scrolled to the top.
pub fn has_more_chat_history(storage_dir: String, friend_pubkey: String) -> bool {
    !load_history_complete(&storage_dir).contains(&friend_pubkey)
}

/// Loads the full decrypted message history with `friend_pubkey` from
/// local storage (no relay round-trip — the live subscription and
/// [send_chat_message] are what keep it current), oldest first.
///
/// Includes messages under any of the friend's `prior_identities` too —
/// each old (pubkey, my_account_index) pair this same account used before
/// being re-friended under a new relationship key (see
/// `friends::add_friend`'s UID merge) — so history from before a
/// delete-and-re-add isn't lost, even though it was encrypted with keys
/// distinct from the current relationship's.
pub fn load_chat_history(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
) -> Result<Vec<ChatMessage>, String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;

    let identities = std::iter::once((friend.pubkey.clone(), friend.my_account_index)).chain(
        friend
            .prior_identities
            .iter()
            .map(|p| (p.pubkey.clone(), p.my_account_index)),
    );

    let held = if friend.is_blocked { load_held(&storage_dir) } else { Vec::new() };

    // Carries each item's own `my_pubkey` (the identity active when it was
    // decoded) alongside it — needed to authorize [DecodedSeal::Hide],
    // which (unlike Edit/Delete, checked against the *target* message's
    // sender) is only ever valid from ourselves.
    let mut decoded: Vec<(String, PublicKey, PublicKey, DecodedSeal)> = Vec::new();
    for (contact_pubkey, account_index) in identities {
        let Ok(keys) = derive_contact_keys(&mnemonic, account_index) else {
            continue;
        };
        let Ok(friend_pk) = PublicKey::from_hex(&contact_pubkey) else {
            continue;
        };
        let my_pubkey = keys.public_key();
        let filter = Filter::new().kind(Kind::Seal).authors([my_pubkey, friend_pk]);
        let events = runtime()
            .block_on(db(&storage_dir).query(filter))
            .map_err(|e| e.to_string())?;
        for seal in events {
            let seal_id = seal.id.to_hex();
            if held.contains(&seal_id) {
                continue;
            }
            if let Some((sender, decoded_seal)) = decode_seal(&keys, &friend_pk, &seal, my_pubkey)
            {
                decoded.push((seal_id, sender, my_pubkey, decoded_seal));
            }
        }
    }

    let mut messages: HashMap<String, ChatMessage> = HashMap::new();
    for (_, _, _, item) in &decoded {
        if let DecodedSeal::Message(m) = item {
            messages.insert(m.id.clone(), m.clone());
        }
    }
    // Only a Clear rumor signed by ourselves counts — same authorization
    // rule as Hide, since clearing (like hiding) is never valid coming from
    // the friend's side of the relationship.
    let clear_cutoff = decoded
        .iter()
        .filter_map(|(_, sender, my_pubkey, item)| match item {
            DecodedSeal::Clear { at } if sender == my_pubkey => Some(*at),
            _ => None,
        })
        .max();
    for (_, sender, my_pubkey, item) in &decoded {
        match item {
            DecodedSeal::Edit { target, content } => {
                if let Some(m) = messages.get_mut(target) {
                    if m.sender_pubkey == sender.to_hex() {
                        // An attachment's caption is carried on `attachment.caption`,
                        // not `content` (which holds the fallback filename label) —
                        // editing an attachment message edits its caption instead.
                        if let Some(attachment) = m.attachment.as_mut() {
                            attachment.caption = Some(content.clone());
                        } else {
                            m.content = content.clone();
                        }
                        m.is_edited = true;
                    }
                }
            }
            DecodedSeal::Delete { target } => {
                if let Some(m) = messages.get_mut(target) {
                    if m.sender_pubkey == sender.to_hex() {
                        m.content = String::new();
                        m.is_deleted = true;
                        m.is_edited = false;
                        m.attachment = None;
                    }
                }
            }
            DecodedSeal::Hide { target } => {
                if sender == my_pubkey {
                    messages.remove(target);
                }
            }
            DecodedSeal::Message(_) | DecodedSeal::Clear { .. } => {}
        }
    }

    let mut messages: Vec<ChatMessage> = messages.into_values().collect();
    if let Some(cutoff) = clear_cutoff {
        messages.retain(|m| m.created_at > cutoff);
    }
    messages.sort_by_key(|m| m.created_at);
    Ok(messages)
}

/// What a decrypted rumor turned out to contain, once its `kind` is known.
enum DecodedSeal {
    Message(ChatMessage),
    Edit { target: String, content: String },
    Delete { target: String },
    Hide { target: String },
    /// A [clear_chat_history] instruction — `at` is the rumor's own
    /// `created_at`, used as the cutoff: any message at or before it is
    /// hidden, the same effect the old `chat_cleared_at.json` file cutoff
    /// had, but carried on the relay-backed event log instead.
    Clear { at: i64 },
}

/// Decrypts a stored/received `Seal`, returning its signer alongside what
/// kind of instruction it carries. Returns `None` on any malformed or
/// spoofed input (e.g. the rumor claiming a different author than the seal
/// actually signed with) or an edit/delete payload that fails to parse.
fn decode_seal(
    keys: &Keys,
    friend_pk: &PublicKey,
    seal: &Event,
    my_pubkey: PublicKey,
) -> Option<(PublicKey, DecodedSeal)> {
    let rumor_json = nip44::decrypt(keys.secret_key(), friend_pk, &seal.content).ok()?;
    let rumor = UnsignedEvent::from_json(rumor_json).ok()?;
    if rumor.pubkey != seal.pubkey {
        return None;
    }
    let decoded = if rumor.kind == CHAT_EDIT_KIND {
        let payload: ChatEditPayload = serde_json::from_str(&rumor.content).ok()?;
        DecodedSeal::Edit { target: payload.message_id, content: payload.content }
    } else if rumor.kind == CHAT_DELETE_KIND {
        let payload: ChatDeletePayload = serde_json::from_str(&rumor.content).ok()?;
        DecodedSeal::Delete { target: payload.message_id }
    } else if rumor.kind == CHAT_HIDE_KIND {
        let payload: ChatHidePayload = serde_json::from_str(&rumor.content).ok()?;
        DecodedSeal::Hide { target: payload.message_id }
    } else if rumor.kind == CHAT_CLEAR_KIND {
        DecodedSeal::Clear { at: rumor.created_at.as_secs() as i64 }
    } else if rumor.kind == DEVICE_ANNOUNCE_KIND
        || rumor.kind == RATCHET_MESSAGE_KIND
        || rumor.kind == GROUP_INVITE_KIND
        || rumor.kind == GROUP_MESSAGE_KIND
        || rumor.kind == GROUP_ATTACHMENT_KIND
    {
        // Handled by `ratchet.rs`/`groups.rs`'s own decoders instead — see
        // those constants' doc comments for why this module deliberately
        // ignores them rather than falling through to the plain-message
        // case below.
        return None;
    } else if rumor.kind == CHAT_ATTACHMENT_KIND {
        let payload: ChatAttachmentPayload = serde_json::from_str(&rumor.content).ok()?;
        DecodedSeal::Message(ChatMessage {
            id: seal.id.to_hex(),
            sender_pubkey: seal.pubkey.to_hex(),
            content: payload.filename.clone(),
            created_at: rumor.created_at.as_secs() as i64,
            is_mine: seal.pubkey == my_pubkey,
            is_edited: false,
            is_deleted: false,
            reply_to: rumor.tags.event_ids().next().map(|id| id.to_hex()),
            attachment: Some(ChatAttachment {
                url: payload.url,
                sha256: payload.sha256,
                size: payload.size,
                mime_type: payload.mime_type,
                filename: payload.filename,
                enc_key: payload.enc_key,
                caption: payload.caption,
            }),
        })
    } else {
        DecodedSeal::Message(ChatMessage {
            id: seal.id.to_hex(),
            sender_pubkey: seal.pubkey.to_hex(),
            content: rumor.content,
            created_at: rumor.created_at.as_secs() as i64,
            is_mine: seal.pubkey == my_pubkey,
            is_edited: false,
            is_deleted: false,
            reply_to: rumor.tags.event_ids().next().map(|id| id.to_hex()),
            attachment: None,
        })
    };
    Some((seal.pubkey, decoded))
}

/// What [receive_gift_wrap] found inside a just-unwrapped Gift Wrap — only
/// [Received::Message] should trigger a live "new message" notification;
/// edits/deletes are saved the same way but surface as a lighter-weight
/// refresh signal instead (see the `sync.rs` call site).
pub(crate) enum Received {
    Message(ChatMessage),
    /// Carries the Seal id (same id space as [ChatMessage.id]) so a caller
    /// can still call [hold_message] on it while the sender is blocked,
    /// even though there's no [ChatMessage] to hang it off of.
    Edit(String),
    Delete(String),
    Hide(String),
    Clear(String),
}

/// Unwraps an incoming Gift Wrap `event` addressed to `my_keys`, verifying
/// the `Seal` and that its sender is either `expected_sender` (the friend
/// this connection is watching for — a stranger can't forge messages that
/// appear to come from an established friend, since they don't hold that
/// friend's per-contact secret key) or ourselves (the self-addressed copy
/// [send_chat_message] publishes so our own sent messages sync back via
/// this same path). On success, persists the `Seal` locally (regardless of
/// which variant it decodes to — [load_chat_history] is what actually
/// applies an edit/delete's effect, by re-reading `chat.lmdb`) and returns
/// what kind of instruction it was.
pub(crate) async fn receive_gift_wrap(
    storage_dir: &str,
    my_keys: &Keys,
    expected_sender: &PublicKey,
    gift_wrap: &Event,
) -> Option<Received> {
    let seal_json = nip44::decrypt(my_keys.secret_key(), &gift_wrap.pubkey, &gift_wrap.content).ok()?;
    let seal = Event::from_json(seal_json).ok()?;
    let my_pubkey = my_keys.public_key();
    if seal.kind != Kind::Seal || (seal.pubkey != *expected_sender && seal.pubkey != my_pubkey) {
        return None;
    }
    seal.verify().ok()?;

    let seal_id = seal.id.to_hex();
    let (sender, decoded) = decode_seal(my_keys, expected_sender, &seal, my_pubkey)?;
    db(storage_dir).save_event(&seal).await.ok()?;
    if let DecodedSeal::Clear { at } = &decoded {
        // Same authorization rule as [load_chat_history]'s display-side
        // filter: only a Clear signed by *ourselves* (the self-echoed copy
        // this account published from another device) may trigger this —
        // otherwise a friend could forge a CHAT_CLEAR_KIND rumor over the
        // ordinary friend->self Gift Wrap path (accepted by the sender
        // check above, since it's a real message from them) and wipe our
        // local history just by sending it.
        if sender == my_pubkey {
            // The device that *ran* clear_chat_history already wiped its
            // own copy of these Seals outright; every other device only
            // learns about the clear via this event, so without this it
            // would filter the old messages out of the display forever but
            // keep decrypting and re-checking every one of them, on every
            // load, indefinitely. Purge them here too, so this device's
            // `chat.lmdb` shrinks the same way the originating device's did.
            purge_seals_before_cutoff(storage_dir, my_keys, expected_sender, my_pubkey, *at).await;
        }
    }
    Some(match decoded {
        DecodedSeal::Message(m) => Received::Message(m),
        DecodedSeal::Edit { .. } => Received::Edit(seal_id),
        DecodedSeal::Delete { .. } => Received::Delete(seal_id),
        DecodedSeal::Hide { .. } => Received::Hide(seal_id),
        DecodedSeal::Clear { .. } => Received::Clear(seal_id),
    })
}

/// Physically deletes every locally-stored Seal between `my_pubkey` and
/// `friend_pk` whose *inner rumor* timestamp (not the outer Seal's, which
/// NIP-59 deliberately randomizes) is at or before `cutoff` — except any
/// [CHAT_CLEAR_KIND] rumor itself, which must survive so that
/// [load_chat_history] can keep applying this same cutoff to messages that
/// get refetched from relays later (e.g. by [fetch_chat_history_page] or a
/// fresh backlog subscription), not just the ones already stored now.
async fn purge_seals_before_cutoff(
    storage_dir: &str,
    keys: &Keys,
    friend_pk: &PublicKey,
    my_pubkey: PublicKey,
    cutoff: i64,
) {
    let db = db(storage_dir);
    let filter = Filter::new().kind(Kind::Seal).authors([my_pubkey, *friend_pk]);
    let Ok(events) = db.query(filter).await else {
        return;
    };
    let mut ids = Vec::new();
    for seal in events {
        let Ok(rumor_json) = nip44::decrypt(keys.secret_key(), friend_pk, &seal.content) else {
            continue;
        };
        let Ok(rumor) = UnsignedEvent::from_json(rumor_json) else {
            continue;
        };
        if rumor.kind == CHAT_CLEAR_KIND {
            continue;
        }
        if rumor.created_at.as_secs() as i64 <= cutoff {
            ids.push(seal.id);
        }
    }
    if !ids.is_empty() {
        let _ = db.delete(Filter::new().ids(ids)).await;
    }
}

fn held_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("held_messages.json")
}

/// IDs of Seal messages that arrived while their sender was blocked. Kept
/// out of [load_chat_history]/[has_chat_history] (see the `is_blocked`
/// check there) so a still-blocked friend stays fully silent — no preview,
/// no unread badge, nothing — even though the message itself was already
/// saved to `chat.lmdb` so it's not lost once unblocked.
fn load_held(storage_dir: &str) -> Vec<String> {
    std::fs::read_to_string(held_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Marks a just-received message as held (see [load_held]) — call right
/// after saving a Seal from a currently-blocked sender.
pub(crate) fn hold_message(storage_dir: &str, message_id: &str) {
    let mut held = load_held(storage_dir);
    if !held.iter().any(|id| id == message_id) {
        held.push(message_id.to_string());
        let _ = std::fs::write(
            held_path(storage_dir),
            serde_json::to_string(&held).unwrap_or_default(),
        );
    }
}

fn started_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_started.json")
}

/// Pubkeys of friends whose chat thread has been explicitly opened via the
/// "Talk" button on their profile — lets the Talk tab show only
/// conversations the user actually started, rather than every friend by
/// default. A friend who has *sent* us a message shows up regardless (see
/// [has_chat_history]), since obviously they've already started it.
fn load_started(storage_dir: &str) -> Vec<String> {
    std::fs::read_to_string(started_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub(crate) fn started_snapshot(storage_dir: &str) -> Vec<String> {
    load_started(storage_dir)
}

pub(crate) fn set_started_snapshot(storage_dir: &str, started: Vec<String>) -> Result<(), String> {
    let json = serde_json::to_string(&started).map_err(|e| e.to_string())?;
    std::fs::write(started_path(storage_dir), json).map_err(|e| e.to_string())
}

/// Marks `friend_pubkey`'s thread as started — call when the user taps
/// "Talk" on their profile, before opening the thread for the first time.
pub fn mark_chat_started(storage_dir: String, friend_pubkey: String) -> Result<(), String> {
    let mut started = load_started(&storage_dir);
    if !started.contains(&friend_pubkey) {
        started.push(friend_pubkey);
    }
    let json = serde_json::to_string(&started).map_err(|e| e.to_string())?;
    std::fs::write(started_path(&storage_dir), json).map_err(|e| e.to_string())
}

/// Whether any message has ever been exchanged with `friend_pubkey` — used
/// so a friend who messages us first shows up in the Talk tab even if we
/// never tapped "Talk" ourselves. Delegates to [load_chat_history] (rather
/// than a cheaper existence-only query) so this respects the same
/// held/cleared filtering — otherwise a blocked or just-cleared friend
/// with no *visible* messages could still count as "has history" and
/// wrongly reappear in the Talk tab.
fn has_chat_history(mnemonic: &str, storage_dir: &str, friend_pubkey: &str) -> bool {
    load_chat_history(mnemonic.to_string(), storage_dir.to_string(), friend_pubkey.to_string())
        .map(|messages| !messages.is_empty())
        .unwrap_or(false)
}

/// Pubkeys of friends who should show up in the Talk tab: either the user
/// explicitly started that thread, or a message already exists in either
/// direction.
pub fn list_active_chat_pubkeys(mnemonic: String, storage_dir: String) -> Vec<String> {
    let started = load_started(&storage_dir);
    friends::load_friends(storage_dir.clone())
        .into_iter()
        .map(|f| f.pubkey)
        .filter(|pubkey| started.contains(pubkey) || has_chat_history(&mnemonic, &storage_dir, pubkey))
        .collect()
}

fn read_state_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("chat_read_state.json")
}

/// Maps friend pubkey -> the timestamp of the last message the user has
/// seen in that thread, used to compute unread counts for the Talk list.
fn load_read_state(storage_dir: &str) -> HashMap<String, i64> {
    std::fs::read_to_string(read_state_path(storage_dir))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_read_state(storage_dir: &str, state: &HashMap<String, i64>) -> Result<(), String> {
    let json = serde_json::to_string(state).map_err(|e| e.to_string())?;
    std::fs::write(read_state_path(storage_dir), json).map_err(|e| e.to_string())
}

pub(crate) fn read_state_snapshot(storage_dir: &str) -> HashMap<String, i64> {
    load_read_state(storage_dir)
}

pub(crate) fn set_read_state_snapshot(
    storage_dir: &str,
    state: HashMap<String, i64>,
) -> Result<(), String> {
    save_read_state(storage_dir, &state)
}

/// Marks every message currently in `friend_pubkey`'s thread as read —
/// call when the user opens that thread.
pub fn mark_thread_read(storage_dir: String, friend_pubkey: String) -> Result<(), String> {
    let now = Timestamp::now().as_secs() as i64;
    let mut state = load_read_state(&storage_dir);
    state.insert(friend_pubkey, now);
    save_read_state(&storage_dir, &state)
}

/// Deletes the entire local message history with `friend_pubkey` (both
/// directions) and resets the thread back to "not started" — the friend
/// drops out of the Talk tab until either side messages again. Purely
/// local: doesn't notify the friend or affect the friendship itself, so
/// they can still message and reopen the thread later.
pub fn clear_chat_history(
    mnemonic: String,
    storage_dir: String,
    friend_pubkey: String,
) -> Result<(), String> {
    let friend = friends::load_friends(storage_dir.clone())
        .into_iter()
        .find(|f| f.pubkey == friend_pubkey)
        .ok_or("not a friend")?;

    let identities = std::iter::once((friend.pubkey.clone(), friend.my_account_index)).chain(
        friend
            .prior_identities
            .iter()
            .map(|p| (p.pubkey.clone(), p.my_account_index)),
    );
    for (contact_pubkey, account_index) in identities {
        let Ok(keys) = derive_contact_keys(&mnemonic, account_index) else {
            continue;
        };
        let Ok(friend_pk) = PublicKey::from_hex(&contact_pubkey) else {
            continue;
        };
        let filter = Filter::new().kind(Kind::Seal).authors([keys.public_key(), friend_pk]);
        runtime()
            .block_on(db(&storage_dir).delete(filter))
            .map_err(|e| e.to_string())?;
    }

    let mut started = load_started(&storage_dir);
    started.retain(|pk| pk != &friend_pubkey);
    std::fs::write(
        started_path(&storage_dir),
        serde_json::to_string(&started).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;

    let mut read_state = load_read_state(&storage_dir);
    read_state.remove(&friend_pubkey);
    save_read_state(&storage_dir, &read_state)?;

    // The friend's Gift Wraps are still sitting on relays — a fresh,
    // `since`-less subscription (e.g. after an app restart) would refetch
    // and re-save them, silently undoing the delete above. Publishing a
    // self-only CHAT_CLEAR_KIND control rumor (never sent to the friend)
    // lets [load_chat_history] keep hiding anything up to its `created_at`
    // even after that happens — and, since it's self-addressed like
    // Edit/Delete/Hide, it also propagates the clear to this account's
    // other devices via the same relay-backed event log, instead of a
    // separate wholesale backup snapshot.
    send_control_rumor(&mnemonic, &storage_dir, &friend_pubkey, CHAT_CLEAR_KIND, String::new(), false, None)
}

pub struct UnreadCount {
    pub friend_pubkey: String,
    pub count: u32,
}

/// For each of `friend_pubkeys`, counts messages from that friend received
/// after the last time [mark_thread_read] was called for them (or all of
/// their messages, if the thread has never been opened). `ratchet_local_key`
/// (see `ratchet.rs`'s module doc) is optional so callers that haven't
/// created a forward-secrecy key yet still get a count from `chat.lmdb`
/// alone — when present, forward-secret messages (which live outside
/// `chat.lmdb`, see [crate::api::ratchet::load_ratchet_history]) are folded
/// into the same count, the same way `chat_list.dart`'s preview merges both
/// sources for display.
pub fn load_unread_counts(
    mnemonic: String,
    storage_dir: String,
    friend_pubkeys: Vec<String>,
    ratchet_local_key: Option<String>,
) -> Vec<UnreadCount> {
    let state = load_read_state(&storage_dir);
    friend_pubkeys
        .into_iter()
        .map(|pubkey| {
            let last_read = state.get(&pubkey).copied().unwrap_or(0);
            let mut count = load_chat_history(mnemonic.clone(), storage_dir.clone(), pubkey.clone())
                .map(|messages| {
                    messages
                        .iter()
                        .filter(|m| !m.is_mine && m.created_at > last_read)
                        .count() as u32
                })
                .unwrap_or(0);
            if let Some(ratchet_key) = &ratchet_local_key {
                count += crate::api::ratchet::load_ratchet_history(
                    storage_dir.clone(),
                    ratchet_key.clone(),
                    pubkey.clone(),
                )
                .map(|messages| {
                    messages
                        .iter()
                        .filter(|m| !m.is_mine && m.created_at > last_read)
                        .count() as u32
                })
                .unwrap_or(0);
            }
            UnreadCount {
                friend_pubkey: pubkey,
                count,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_storage_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "origilink-chat-test-{tag}-{}",
            nostr::Keys::generate().public_key().to_hex()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn history_complete_starts_empty_and_is_idempotent() {
        let dir = temp_storage_dir("history-complete");
        let dir_str = dir.to_string_lossy().to_string();
        assert!(load_history_complete(&dir_str).is_empty());

        mark_history_complete(&dir_str, "friend-a");
        mark_history_complete(&dir_str, "friend-a");
        mark_history_complete(&dir_str, "friend-b");
        let complete = load_history_complete(&dir_str);
        assert_eq!(complete, vec!["friend-a".to_string(), "friend-b".to_string()]);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn held_messages_starts_empty_and_is_idempotent() {
        let dir = temp_storage_dir("held");
        let dir_str = dir.to_string_lossy().to_string();
        assert!(load_held(&dir_str).is_empty());

        hold_message(&dir_str, "msg-1");
        hold_message(&dir_str, "msg-1");
        let held = load_held(&dir_str);
        assert_eq!(held, vec!["msg-1".to_string()]);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn started_snapshot_round_trips() {
        let dir = temp_storage_dir("started");
        let dir_str = dir.to_string_lossy().to_string();
        assert!(started_snapshot(&dir_str).is_empty());

        set_started_snapshot(&dir_str, vec!["friend-a".to_string(), "friend-b".to_string()]).unwrap();
        assert_eq!(
            started_snapshot(&dir_str),
            vec!["friend-a".to_string(), "friend-b".to_string()]
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mark_chat_started_is_idempotent() {
        let dir = temp_storage_dir("mark-started");
        let dir_str = dir.to_string_lossy().to_string();

        mark_chat_started(dir_str.clone(), "friend-a".to_string()).unwrap();
        mark_chat_started(dir_str.clone(), "friend-a".to_string()).unwrap();
        assert_eq!(started_snapshot(&dir_str), vec!["friend-a".to_string()]);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn read_state_snapshot_round_trips() {
        let dir = temp_storage_dir("read-state");
        let dir_str = dir.to_string_lossy().to_string();
        assert!(read_state_snapshot(&dir_str).is_empty());

        let mut state = HashMap::new();
        state.insert("friend-a".to_string(), 1_700_000_000i64);
        set_read_state_snapshot(&dir_str, state.clone()).unwrap();
        assert_eq!(read_state_snapshot(&dir_str), state);

        std::fs::remove_dir_all(&dir).ok();
    }
}
