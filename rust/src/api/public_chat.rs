//! Public Chat: NIP-28 channels — open rooms anyone on the same relays can
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

use crate::api::keys::derive_keys;
use crate::api::sync::{publish_to_relays, runtime};
use futures_util::future::join_all;
use nostr::event::{Event, EventBuilder, Kind, Tag, TagKind};
use nostr::Filter;
use serde::{Deserialize, Serialize};
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
pub struct PublicChannel {
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
pub struct PublicChannelMessage {
    pub id: String,
    pub channel_id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: i64,
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

fn channel_from_creation_event(event: &Event) -> Option<PublicChannel> {
    let content: ChannelMetadataContent = serde_json::from_str(&event.content).ok()?;
    Some(PublicChannel {
        id: event.id.to_hex(),
        name: content.name,
        about: content.about,
        creator_pubkey: event.pubkey.to_hex(),
        created_at: event.created_at.as_secs() as i64,
        is_origilink: has_origilink_client_tag(event),
    })
}

/// Creates a new public channel (NIP-28 kind 40), signed with this
/// account's core identity (the same one used for the relay-hosted account
/// backup — see `keys::derive_keys`), since a channel is public by nature
/// and doesn't need a per-relationship unlinkable key. Tagged as an
/// Origilink channel (see module doc). Returns the new channel's id.
pub fn create_channel(
    mnemonic: String,
    relay_urls: Vec<String>,
    name: String,
    about: String,
) -> Result<String, String> {
    runtime().block_on(async {
        let keys = derive_keys(&mnemonic)?;
        let content = serde_json::to_string(&ChannelMetadataContent {
            name,
            about,
            picture: String::new(),
        })
        .map_err(|e| e.to_string())?;
        let event = EventBuilder::new(Kind::ChannelCreation, content)
            .tag(client_tag())
            .sign_with_keys(&keys)
            .map_err(|e| e.to_string())?;
        let id = event.id.to_hex();
        publish_to_relays(&relay_urls, &event).await?;
        Ok(id)
    })
}

/// Lists public channels visible on `relay_urls`. When `origilink_only` is
/// true (the default list view), only channels tagged by this app are
/// returned; otherwise every NIP-28 channel on those relays is included —
/// see module doc for why this is a UI filter, not a protocol boundary.
pub fn list_channels(relay_urls: Vec<String>, origilink_only: bool) -> Vec<PublicChannel> {
    runtime().block_on(async {
        let filter = Filter::new().kind(Kind::ChannelCreation).limit(200);
        let tasks = relay_urls.iter().map(|url| crate::relay_pool::request(url, &filter, REQUEST_TIMEOUT));
        let results = join_all(tasks).await;

        let mut channels: Vec<PublicChannel> = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        for event in results.into_iter().flatten() {
            if !seen_ids.insert(event.id) {
                continue;
            }
            if let Some(channel) = channel_from_creation_event(&event) {
                if !origilink_only || channel.is_origilink {
                    channels.push(channel);
                }
            }
        }
        channels.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        channels
    })
}

/// Loads the most recent messages in `channel_id`, across `relay_urls`.
pub fn load_channel_messages(relay_urls: Vec<String>, channel_id: String) -> Vec<PublicChannelMessage> {
    runtime().block_on(async {
        let filter = Filter::new().kind(Kind::ChannelMessage).event(match nostr::EventId::from_hex(&channel_id) {
            Ok(id) => id,
            Err(_) => return Vec::new(),
        }).limit(200);
        let tasks = relay_urls.iter().map(|url| crate::relay_pool::request(url, &filter, REQUEST_TIMEOUT));
        let results = join_all(tasks).await;

        let mut messages: Vec<PublicChannelMessage> = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        for event in results.into_iter().flatten() {
            if !seen_ids.insert(event.id) {
                continue;
            }
            messages.push(PublicChannelMessage {
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

/// Posts `content` to `channel_id`, signed with this account's core
/// identity (same reasoning as [create_channel]).
pub fn send_channel_message(
    mnemonic: String,
    relay_urls: Vec<String>,
    channel_id: String,
    content: String,
) -> Result<(), String> {
    runtime().block_on(async {
        let keys = derive_keys(&mnemonic)?;
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

/// Dart-callable accessor for this account's public identity pubkey (used
/// to tell "my own message" apart from others' in the channel timeline —
/// mirrors how `account`/`chat` expose the account's own identity).
pub fn public_chat_identity_pubkey(mnemonic: String) -> Result<String, String> {
    Ok(derive_keys(&mnemonic)?.public_key().to_hex())
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn public_chat_identity_matches_core_account_identity() {
        assert_eq!(
            public_chat_identity_pubkey(TEST_MNEMONIC.to_string()).unwrap(),
            derive_keys(TEST_MNEMONIC).unwrap().public_key().to_hex()
        );
    }
}
