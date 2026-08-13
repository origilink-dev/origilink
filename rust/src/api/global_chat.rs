//! Global Chat: NIP-28 channels — open rooms anyone on the same relays can
//! browse and post to, no friendship or invite required. Unlike 1:1/group
//! chat, nothing here is encrypted: channel creation (kind 40) and messages
//! (kind 42) are ordinary public Nostr events, readable by any client.
//!
//! Channels created by this app are tagged `["client", "origilink"]` — a
//! common, non-proprietary Nostr convention (many clients tag their own
//! events this way) purely for filtering, not a separate protocol. The
//! channel list defaults to showing only Origilink-tagged channels (a
//! curated, spam-light view) but [list_channels]'s `origilink_only: false`
//! path shows every NIP-28 channel on the configured relays — anything
//! created here is equally visible/joinable from Damus, Amethyst, or any
//! other NIP-28 client, and vice versa.

use crate::api::attachment::{delete_blossom_blob, load_upload_servers, upload_plain_bytes};
use crate::api::keys::derive_global_chat_keys;
use crate::api::sync::{publish_to_relays, runtime};
use crate::frb_generated::StreamSink;
use futures_util::future::join_all;
use nostr::event::{Event, EventBuilder, Kind, Tag, TagKind};
use nostr::{Filter, Timestamp};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Duration;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const CLIENT_TAG_VALUE: &str = "origilink";

#[derive(Serialize, Deserialize)]
struct ChannelMetadataContent {
    name: String,
    about: String,
    #[serde(default)]
    picture: String,
}

/// A NIP-28 channel, as shown in the channel list.
#[derive(Clone, Serialize, Deserialize)]
pub struct GlobalChannel {
    /// The channel's creation event id — its stable identifier.
    pub id: String,
    pub name: String,
    pub about: String,
    pub creator_pubkey: String,
    pub created_at: i64,
    /// Whether the creation event carried Origilink's `client` tag.
    pub is_origilink: bool,
}

/// A single message in a channel's timeline.
#[derive(Clone)]
pub struct GlobalChannelMessage {
    pub id: String,
    pub channel_id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: i64,
}

/// A sender's NIP-01 profile (kind 0), as shown next to their messages —
/// display name and avatar picture, when they've published one. Unlike
/// friends (whose display name/avatar come from this app's own backup
/// protocol), channel senders are often not friends at all, so the only
/// identity info available is whatever they've published to Nostr itself.
#[derive(Deserialize)]
struct ProfileMetadataContent {
    #[serde(default)]
    name: String,
    #[serde(default)]
    picture: String,
}

pub struct GlobalChatProfile {
    pub pubkey: String,
    pub name: Option<String>,
    pub picture: Option<String>,
}

fn profile_from_metadata_event(event: &Event) -> Option<GlobalChatProfile> {
    let content: ProfileMetadataContent = serde_json::from_str(&event.content).ok()?;
    Some(GlobalChatProfile {
        pubkey: event.pubkey.to_hex(),
        name: (!content.name.is_empty()).then_some(content.name),
        picture: (!content.picture.is_empty()).then_some(content.picture),
    })
}

fn client_tag() -> Tag {
    Tag::custom(TagKind::Client, [CLIENT_TAG_VALUE.to_string()])
}

fn has_origilink_client_tag(event: &Event) -> bool {
    event
        .tags
        .iter()
        .any(|tag| tag.kind() == TagKind::Client && tag.content() == Some(CLIENT_TAG_VALUE))
}

fn channel_from_creation_event(event: &Event) -> Option<GlobalChannel> {
    let content: ChannelMetadataContent = serde_json::from_str(&event.content).ok()?;
    Some(GlobalChannel {
        id: event.id.to_hex(),
        name: content.name,
        about: content.about,
        creator_pubkey: event.pubkey.to_hex(),
        created_at: event.created_at.as_secs() as i64,
        is_origilink: has_origilink_client_tag(event),
    })
}

/// Creates a new public channel (NIP-28 kind 40), signed with this
/// account's dedicated Global Chat identity (see `keys::derive_global_chat_keys`)
/// rather than its core identity — a channel is public by nature and posts
/// to it shouldn't be linkable to the self-addressed account-backup events
/// published under the core key. Tagged as an Origilink channel (see module
/// doc). Returns the new channel's id.
pub fn create_channel(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    name: String,
    about: String,
) -> Result<String, String> {
    runtime().block_on(async {
        let keys = derive_global_chat_keys(&mnemonic)?;
        let content = serde_json::to_string(&ChannelMetadataContent {
            name: name.clone(),
            about: about.clone(),
            picture: String::new(),
        })
        .map_err(|e| e.to_string())?;
        let event = EventBuilder::new(Kind::ChannelCreation, content)
            .tag(client_tag())
            .sign_with_keys(&keys)
            .map_err(|e| e.to_string())?;
        let id = event.id.to_hex();
        publish_to_relays(&relay_urls, &event).await?;
        // Creating a channel implies joining it — otherwise it would
        // publish successfully but vanish from this device's own Talk/
        // Global list, which only shows joined channels.
        join_channel(
            storage_dir,
            GlobalChannel {
                id: id.clone(),
                name,
                about,
                creator_pubkey: keys.public_key().to_hex(),
                created_at: event.created_at.as_secs() as i64,
                is_origilink: true,
            },
        );
        Ok(id)
    })
}

/// Lists every public channel visible on `relay_urls`, most active first —
/// each result carries `is_origilink` (see module doc) so the Dart side can
/// filter the "Origilink channels only" vs. "all channels" toggle purely
/// client-side, without a fresh relay round-trip per toggle flip: the
/// underlying query here never depended on that flag to begin with, it was
/// only ever applied to the already-fetched results.
///
/// Sorting by raw channel-creation recency alone buries every channel with
/// real conversation under a constant stream of freshly-created spam
/// channels (public relays see many of these) — a channel from months ago
/// with real traffic would never make it into the (necessarily bounded)
/// creation-event page. So this pulls a batch of *recent messages* first
/// and uses how many reference each channel as an activity signal, then
/// resolves creation events for both the newest channels and whichever
/// channels that message sample surfaced (which may be much older),
/// finally ranking by message count with recency as the tiebreak.
pub fn list_channels(relay_urls: Vec<String>) -> Vec<GlobalChannel> {
    runtime().block_on(async {
        let message_filter = Filter::new().kind(Kind::ChannelMessage).limit(500);
        let message_tasks =
            relay_urls.iter().map(|url| crate::relay_pool::request(url, &message_filter, REQUEST_TIMEOUT));
        let message_results = join_all(message_tasks).await;

        let mut message_counts: std::collections::HashMap<nostr::EventId, usize> =
            std::collections::HashMap::new();
        for event in message_results.into_iter().flatten() {
            for tag in event.tags.iter() {
                if tag.kind() != TagKind::e() {
                    continue;
                }
                if let Some(Ok(channel_id)) = tag.content().map(nostr::EventId::from_hex) {
                    *message_counts.entry(channel_id).or_insert(0) += 1;
                }
            }
        }

        let creation_filter = Filter::new().kind(Kind::ChannelCreation).limit(200);
        let creation_tasks =
            relay_urls.iter().map(|url| crate::relay_pool::request(url, &creation_filter, REQUEST_TIMEOUT));
        let mut creation_results = join_all(creation_tasks).await;

        if !message_counts.is_empty() {
            let active_ids: Vec<nostr::EventId> = message_counts.keys().copied().collect();
            let active_filter = Filter::new().kind(Kind::ChannelCreation).ids(active_ids);
            let active_tasks =
                relay_urls.iter().map(|url| crate::relay_pool::request(url, &active_filter, REQUEST_TIMEOUT));
            creation_results.extend(join_all(active_tasks).await);
        }

        let mut channels: Vec<GlobalChannel> = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        for event in creation_results.into_iter().flatten() {
            if !seen_ids.insert(event.id) {
                continue;
            }
            if let Some(channel) = channel_from_creation_event(&event) {
                channels.push(channel);
            }
        }
        channels.sort_by(|a, b| {
            let count_a = nostr::EventId::from_hex(&a.id).ok().and_then(|id| message_counts.get(&id)).copied().unwrap_or(0);
            let count_b = nostr::EventId::from_hex(&b.id).ok().and_then(|id| message_counts.get(&id)).copied().unwrap_or(0);
            count_b.cmp(&count_a).then_with(|| b.created_at.cmp(&a.created_at))
        });
        channels
    })
}

fn joined_channels_path(storage_dir: &str) -> std::path::PathBuf {
    std::path::Path::new(storage_dir).join("joined_channels.json")
}

/// Channels this account has explicitly joined — the Global-mode
/// counterpart to `friends.json`, so Talk's Global mode can show a plain
/// list of channels the account is actually part of (styled like an
/// ordinary chat row: name + last-message preview) instead of the full
/// browse-everything list from [list_channels]. Purely local: joining
/// doesn't publish anything (NIP-28 has no membership event), it just
/// remembers the channel so this device keeps showing it.
pub fn list_joined_channels(storage_dir: String) -> Vec<GlobalChannel> {
    std::fs::read_to_string(joined_channels_path(&storage_dir))
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

fn save_joined_channels(storage_dir: &str, channels: &[GlobalChannel]) {
    if let Ok(content) = serde_json::to_string(channels) {
        let _ = std::fs::write(joined_channels_path(storage_dir), content);
    }
}

/// Adds `channel` to this device's joined-channels list (see
/// [list_joined_channels]) — a no-op if already joined.
pub fn join_channel(storage_dir: String, channel: GlobalChannel) {
    let mut channels = list_joined_channels(storage_dir.clone());
    if channels.iter().any(|c| c.id == channel.id) {
        return;
    }
    channels.push(channel);
    save_joined_channels(&storage_dir, &channels);
}

/// Removes `channel_id` from this device's joined-channels list.
pub fn leave_channel(storage_dir: String, channel_id: String) {
    let mut channels = list_joined_channels(storage_dir.clone());
    channels.retain(|c| c.id != channel_id);
    save_joined_channels(&storage_dir, &channels);
}

/// Page size for [load_channel_messages].
const CHANNEL_MESSAGE_PAGE_SIZE: usize = 200;

/// Loads up to a page of `channel_id`'s messages, across `relay_urls`.
/// `before` (when set) pages backward from that Unix timestamp instead of
/// from "now" — pass the oldest-currently-loaded message's `created_at` to
/// fetch the next page of history, mirroring `chat.rs`'s `load_older`
/// pattern so the channel timeline isn't hard-capped at one page forever.
pub fn load_channel_messages(
    relay_urls: Vec<String>,
    channel_id: String,
    before: Option<i64>,
) -> Vec<GlobalChannelMessage> {
    runtime().block_on(async {
        let mut filter = Filter::new()
            .kind(Kind::ChannelMessage)
            .event(match nostr::EventId::from_hex(&channel_id) {
                Ok(id) => id,
                Err(_) => return Vec::new(),
            })
            .limit(CHANNEL_MESSAGE_PAGE_SIZE);
        if let Some(before) = before {
            filter = filter.until(Timestamp::from(before.max(0) as u64));
        }
        let tasks = relay_urls.iter().map(|url| crate::relay_pool::request(url, &filter, REQUEST_TIMEOUT));
        let results = join_all(tasks).await;

        let mut messages: Vec<GlobalChannelMessage> = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        for event in results.into_iter().flatten() {
            if !seen_ids.insert(event.id) {
                continue;
            }
            messages.push(GlobalChannelMessage {
                id: event.id.to_hex(),
                channel_id: channel_id.clone(),
                sender_pubkey: event.pubkey.to_hex(),
                content: event.content.clone(),
                created_at: event.created_at.as_secs() as i64,
            });
        }
        messages.sort_by(|a, b| a.created_at.cmp(&b.created_at));
        messages
    })
}

/// Opens a live subscription on `channel_id` across `relay_urls`, streaming
/// new messages as they arrive for as long as the returned Dart stream is
/// listened to — mirrors `sync::subscribe_friend_events`'s "one task per
/// relay, forward into a shared sink" shape, but far simpler: no
/// resubscribe/backoff loop, since a channel subscription is cheap to just
/// re-open by calling this again (the Dart side does, via a fresh
/// `GlobalChatThreadScreen`/key). `since(now)` means this only ever
/// delivers messages newer than the moment it opened — the initial page
/// from [load_channel_messages] covers everything up to that point.
pub fn subscribe_channel_messages(
    relay_urls: Vec<String>,
    channel_id: String,
    sink: StreamSink<GlobalChannelMessage>,
) {
    let Ok(id) = nostr::EventId::from_hex(&channel_id) else { return };
    let filter = Filter::new().kind(Kind::ChannelMessage).event(id).since(Timestamp::now());
    for url in relay_urls {
        let filter = filter.clone();
        let sink = sink.clone();
        let channel_id = channel_id.clone();
        runtime().spawn(async move {
            let Some((_sub_id, mut events)) = crate::relay_pool::subscribe(&url, &filter).await else {
                return;
            };
            while let Some(pool_event) = events.recv().await {
                let crate::relay_pool::PoolEvent::Event(event) = pool_event else {
                    continue;
                };
                let message = GlobalChannelMessage {
                    id: event.id.to_hex(),
                    channel_id: channel_id.clone(),
                    sender_pubkey: event.pubkey.to_hex(),
                    content: event.content.clone(),
                    created_at: event.created_at.as_secs() as i64,
                };
                if sink.add(message).is_err() {
                    // Dart side stopped listening — stop consuming this
                    // relay's subscription too.
                    crate::relay_pool::unsubscribe(&url, _sub_id);
                    return;
                }
            }
        });
    }
}

/// Loads NIP-01 profile metadata (kind 0) for `pubkeys`, across
/// `relay_urls`. Kind 0 is a "replaceable" event — a pubkey may have many
/// old copies floating around relays — so this keeps only the newest per
/// author. Pubkeys with no metadata found (never published one, or it's on
/// a relay outside `relay_urls`) simply don't appear in the result; callers
/// fall back to showing the raw pubkey for those.
pub fn load_profiles(relay_urls: Vec<String>, pubkeys: Vec<String>) -> Vec<GlobalChatProfile> {
    runtime().block_on(async {
        let authors: Vec<nostr::PublicKey> =
            pubkeys.iter().filter_map(|pk| nostr::PublicKey::from_hex(pk).ok()).collect();
        if authors.is_empty() {
            return Vec::new();
        }
        let filter = Filter::new().kind(Kind::Metadata).authors(authors);
        let tasks = relay_urls.iter().map(|url| crate::relay_pool::request(url, &filter, REQUEST_TIMEOUT));
        let results = join_all(tasks).await;

        let mut newest: std::collections::HashMap<nostr::PublicKey, Event> = std::collections::HashMap::new();
        for event in results.into_iter().flatten() {
            match newest.get(&event.pubkey) {
                Some(existing) if existing.created_at >= event.created_at => {}
                _ => {
                    newest.insert(event.pubkey, event);
                }
            }
        }

        newest.into_values().filter_map(|event| profile_from_metadata_event(&event)).collect()
    })
}

/// Posts `content` to `channel_id`, signed with this account's dedicated
/// Global Chat identity (same reasoning as [create_channel]).
pub fn send_channel_message(
    mnemonic: String,
    relay_urls: Vec<String>,
    channel_id: String,
    content: String,
) -> Result<(), String> {
    runtime().block_on(async {
        let keys = derive_global_chat_keys(&mnemonic)?;
        let channel_event_id = nostr::EventId::from_hex(&channel_id).map_err(|e| e.to_string())?;
        let root_tag = Tag::custom(
            TagKind::e(),
            [channel_event_id.to_hex(), String::new(), "root".to_string()],
        );
        let event = EventBuilder::new(Kind::ChannelMessage, content)
            .tag(root_tag)
            .sign_with_keys(&keys)
            .map_err(|e| e.to_string())?;
        publish_to_relays(&relay_urls, &event).await
    })
}

/// Dart-callable accessor for this account's dedicated Global Chat identity
/// pubkey (used to tell "my own message" apart from others' in the channel
/// timeline — mirrors how `account`/`chat` expose the account's own
/// identity, but scoped to the Global Chat key rather than the core one).
pub fn global_chat_identity_pubkey(mnemonic: String) -> Result<String, String> {
    Ok(derive_global_chat_keys(&mnemonic)?.public_key().to_hex())
}

fn global_profile_marker_path(storage_dir: &str) -> std::path::PathBuf {
    std::path::Path::new(storage_dir).join("global_profile_configured")
}

fn global_profile_path(storage_dir: &str) -> std::path::PathBuf {
    std::path::Path::new(storage_dir).join("global_profile.json")
}

/// This device's own Global Chat profile, cached locally after publishing so
/// the app can show it (e.g. Home's Global tab) without a relay round-trip.
/// `avatar_path` is a local file cache of `picture_url`'s bytes, the same
/// path-reuse trick `account.rs`'s `Account::avatar_path` uses for instant
/// display.
#[derive(Clone, Serialize, Deserialize)]
pub struct GlobalOwnProfile {
    pub name: String,
    pub about: String,
    pub avatar_path: Option<String>,
    pub picture_url: Option<String>,
}

/// Whether this device has ever completed Global Profile setup (as opposed
/// to skipping it) — a plain local marker file rather than a relay query,
/// since the point is to gate the *local* redirect-to-setup UX, not to
/// verify a kind-0 event still exists on some relay. Deliberately not part
/// of `Account`/its backup: a fresh device restored from the seed phrase
/// should re-decide (or re-skip) Global Profile setup on its own, the same
/// way it re-decides relay settings, rather than silently inheriting
/// whatever the original device chose.
pub fn has_global_profile(storage_dir: String) -> bool {
    global_profile_marker_path(&storage_dir).exists()
}

/// The locally cached copy of this device's own Global Chat profile, if
/// Global Profile setup has ever completed (see [has_global_profile]).
pub fn load_global_profile(storage_dir: String) -> Option<GlobalOwnProfile> {
    let content = std::fs::read_to_string(global_profile_path(&storage_dir)).ok()?;
    serde_json::from_str(&content).ok()
}

/// Deletes this device's currently-published Global Profile picture from
/// the Blossom server — called on account deletion, since nothing will
/// reference it again once the local profile is wiped. Best-effort: the
/// caller should ignore failures (offline, server doesn't support delete,
/// already gone).
pub fn delete_global_profile_picture(mnemonic: String, picture_url: String) -> Result<(), String> {
    let keys = derive_global_chat_keys(&mnemonic)?;
    runtime().block_on(delete_blossom_blob(&picture_url, &keys))
}

/// Copies a freshly-picked Global Profile avatar into permanent per-device
/// storage under a content-hash-suffixed filename — mirrors
/// `account.rs::save_account_avatar`, so Flutter's path-keyed `ImageCache`
/// picks up the new bytes immediately instead of keeping the old bitmap for
/// what used to be a reused path.
pub fn save_global_profile_avatar(storage_dir: String, picked_path: String) -> Option<String> {
    let bytes = std::fs::read(&picked_path).ok()?;
    let hash = hex::encode(Sha256::digest(&bytes));
    let extension = Path::new(&picked_path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("jpg");
    let file_name = format!("global_avatar_{hash}.{extension}");
    let dir = Path::new(&storage_dir);
    let dest = dir.join(&file_name);
    std::fs::write(&dest, &bytes).ok()?;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("global_avatar_") && name != file_name {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    Some(dest.to_string_lossy().to_string())
}

/// Publishes a NIP-01 profile (kind 0) for this account's dedicated Global
/// Chat identity — the display name/bio/avatar shown next to this account's
/// channel posts (see `keys::derive_global_chat_keys` for why this is a
/// separate identity from the core account). `avatar_path` (if given) is
/// uploaded to the configured Blossom server (same servers `attachment.rs`
/// uses for chat files) so other Nostr clients can actually fetch the
/// `picture` URL, then cached locally. Marks Global Profile setup as
/// completed locally on success (see [has_global_profile]).
pub fn publish_global_profile(
    mnemonic: String,
    storage_dir: String,
    relay_urls: Vec<String>,
    name: String,
    about: String,
    avatar_path: Option<String>,
) -> Result<(), String> {
    let previous_picture_url = load_global_profile(storage_dir.clone()).and_then(|p| p.picture_url);
    runtime().block_on(async {
        let keys = derive_global_chat_keys(&mnemonic)?;

        let mut picture_url = None;
        if let Some(path) = &avatar_path {
            let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
            let mime_type = match Path::new(path).extension().and_then(|e| e.to_str()) {
                Some("png") => "image/png",
                Some("webp") => "image/webp",
                Some("gif") => "image/gif",
                _ => "image/jpeg",
            };
            let server = load_upload_servers(storage_dir.clone()).default_url;
            picture_url = Some(upload_plain_bytes(&server, mime_type, bytes, &keys).await?);
            // Best-effort: don't let a stale copy pile up on the server
            // every time the avatar is replaced.
            if let Some(previous) = &previous_picture_url {
                let _ = delete_blossom_blob(previous, &keys).await;
            }
        }

        let content = serde_json::to_string(&ChannelMetadataContent {
            name: name.clone(),
            about: about.clone(),
            picture: picture_url.clone().unwrap_or_default(),
        })
        .map_err(|e| e.to_string())?;
        let event = EventBuilder::new(Kind::Metadata, content)
            .sign_with_keys(&keys)
            .map_err(|e| e.to_string())?;
        publish_to_relays(&relay_urls, &event).await?;

        let profile = GlobalOwnProfile { name, about, avatar_path, picture_url };
        let profile_json = serde_json::to_string_pretty(&profile).map_err(|e| e.to_string())?;
        let _ = std::fs::write(global_profile_path(&storage_dir), profile_json);
        let _ = std::fs::write(global_profile_marker_path(&storage_dir), "");
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::keys::derive_keys;

    const TEST_MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn channel_from_creation_event_parses_metadata_and_client_tag() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let content = serde_json::to_string(&ChannelMetadataContent {
            name: "General".to_string(),
            about: "Chat about anything".to_string(),
            picture: String::new(),
        })
        .unwrap();
        let event = EventBuilder::new(Kind::ChannelCreation, content)
            .tag(client_tag())
            .sign_with_keys(&keys)
            .unwrap();

        let channel = channel_from_creation_event(&event).unwrap();
        assert_eq!(channel.name, "General");
        assert_eq!(channel.about, "Chat about anything");
        assert_eq!(channel.creator_pubkey, keys.public_key().to_hex());
        assert!(channel.is_origilink);
    }

    #[test]
    fn channel_from_creation_event_flags_non_origilink_channels() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let content = serde_json::to_string(&ChannelMetadataContent {
            name: "Foreign".to_string(),
            about: String::new(),
            picture: String::new(),
        })
        .unwrap();
        // No client tag at all — as a channel from some other NIP-28 client
        // would look.
        let event = EventBuilder::new(Kind::ChannelCreation, content).sign_with_keys(&keys).unwrap();

        let channel = channel_from_creation_event(&event).unwrap();
        assert!(!channel.is_origilink);
    }

    #[test]
    fn channel_from_creation_event_rejects_malformed_content() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let event = EventBuilder::new(Kind::ChannelCreation, "not json").sign_with_keys(&keys).unwrap();
        assert!(channel_from_creation_event(&event).is_none());
    }

    #[test]
    fn global_chat_identity_is_deterministic_but_distinct_from_core_account_identity() {
        let a = global_chat_identity_pubkey(TEST_MNEMONIC.to_string()).unwrap();
        let b = global_chat_identity_pubkey(TEST_MNEMONIC.to_string()).unwrap();
        assert_eq!(a, b);
        assert_ne!(a, derive_keys(TEST_MNEMONIC).unwrap().public_key().to_hex());
    }

    #[test]
    fn profile_from_metadata_event_parses_name_and_picture() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let event = EventBuilder::new(Kind::Metadata, r#"{"name":"Alice","picture":"https://example.com/a.png"}"#)
            .sign_with_keys(&keys)
            .unwrap();

        let profile = profile_from_metadata_event(&event).unwrap();
        assert_eq!(profile.pubkey, keys.public_key().to_hex());
        assert_eq!(profile.name, Some("Alice".to_string()));
        assert_eq!(profile.picture, Some("https://example.com/a.png".to_string()));
    }

    #[test]
    fn profile_from_metadata_event_treats_empty_fields_as_absent() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let event = EventBuilder::new(Kind::Metadata, r#"{"name":"","picture":""}"#)
            .sign_with_keys(&keys)
            .unwrap();

        let profile = profile_from_metadata_event(&event).unwrap();
        assert_eq!(profile.name, None);
        assert_eq!(profile.picture, None);
    }

    #[test]
    fn profile_from_metadata_event_rejects_malformed_content() {
        let keys = derive_keys(TEST_MNEMONIC).unwrap();
        let event = EventBuilder::new(Kind::Metadata, "not json").sign_with_keys(&keys).unwrap();
        assert!(profile_from_metadata_event(&event).is_none());
    }
}
