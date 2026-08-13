use bip39::Mnemonic;
use nostr::nips::nip06::FromMnemonic;
use nostr::Keys;
use sha2::{Digest, Sha256};

/// Reserved NIP-06 account index for deriving the stable UID (see
/// `derive_uid`). Never used for `derive_contact_keys` — friend
/// relationships use small sequential indices starting at 0, so a value
/// this large can never collide with one.
const UID_ACCOUNT_INDEX: u32 = 0x7FFF_FFFE;

/// Reserved NIP-06 account index for [derive_global_chat_keys]. Distinct
/// from both `UID_ACCOUNT_INDEX` and the sequential per-contact indices, so
/// it can never collide with either.
const GLOBAL_CHAT_ACCOUNT_INDEX: u32 = 0x7FFF_FFFD;

/// Reserved NIP-06 account index for [derive_avatar_upload_keys]. Distinct
/// from every other reserved/sequential index, so it can never collide.
const AVATAR_UPLOAD_ACCOUNT_INDEX: u32 = 0x7FFF_FFFC;

/// Generates a new 12-word BIP-39 seed phrase. The caller is responsible for
/// persisting it (e.g. via platform secure storage) — this function is pure
/// generation with no I/O.
pub fn generate_mnemonic() -> Result<String, String> {
    Mnemonic::generate(12)
        .map(|mnemonic| mnemonic.to_string())
        .map_err(|e| e.to_string())
}

/// Validates that `mnemonic` is both a proper BIP-39 phrase and one that can
/// derive Nostr keys (NIP-06).
pub fn validate_mnemonic(mnemonic: String) -> Result<(), String> {
    let phrase = mnemonic.trim();
    phrase.parse::<Mnemonic>().map_err(|e| e.to_string())?;
    Keys::from_mnemonic(phrase, None).map_err(|e| e.to_string())?;
    Ok(())
}

/// Deterministically derives this account's core identity keys from its
/// seed phrase (NIP-06 account 0). Used for the relay-hosted account
/// backup — same mnemonic always yields the same keys, so nothing needs
/// to be stored beyond the mnemonic itself.
pub(crate) fn derive_keys(mnemonic: &str) -> Result<Keys, String> {
    derive_contact_keys(mnemonic, 0)
}

/// Deterministically derives a per-contact key pair from the seed phrase,
/// using NIP-06's multi-account derivation (`m/44'/1237'/<account>'/0/0`).
/// Each invite/friend gets a distinct `account` index so that if a key
/// shared with one contact ever leaks, it can't be linked to any other
/// contact or to this device's core account identity (account 0).
pub(crate) fn derive_contact_keys(mnemonic: &str, account: u32) -> Result<Keys, String> {
    Keys::from_mnemonic_with_account(mnemonic.trim(), None, Some(account))
        .map_err(|e| e.to_string())
}

/// Derives this account's stable UID: a SHA-256 hash of a pubkey minted at
/// a reserved derivation index that's never used for any relationship.
/// Unlike a per-contact pubkey, the UID stays the same across every friend
/// — shown in the profile so a friend can recognize the same account again
/// even after it re-friends them with a brand new relationship key (e.g.
/// to evade a block). Hashing (rather than exposing the reserved pubkey
/// directly) means the UID carries no usable key material — it's purely
/// an identifier, never a way to sign or decrypt anything.
pub(crate) fn derive_uid(mnemonic: &str) -> Result<String, String> {
    let keys = derive_contact_keys(mnemonic, UID_ACCOUNT_INDEX)?;
    let digest = Sha256::digest(keys.public_key().to_hex().as_bytes());
    Ok(digest.iter().map(|b| format!("{:02x}", b)).collect())
}

/// Derives this account's dedicated Global Chat identity — a single key
/// pair reused across every channel/message, so other participants can
/// recognize the same poster across channels, but deliberately distinct
/// from `derive_keys`'s core identity (account 0). Global Chat posts are
/// broadcast in the clear to public relays, so signing them with the core
/// identity would let anyone linking that pubkey to the self-addressed
/// account-backup events (profile/relays/friends, see `sync.rs`) correlate
/// a public post with the private backup data — the same leak-containment
/// reasoning as [derive_contact_keys], just with one fixed index instead
/// of one per relationship.
pub(crate) fn derive_global_chat_keys(mnemonic: &str) -> Result<Keys, String> {
    derive_contact_keys(mnemonic, GLOBAL_CHAT_ACCOUNT_INDEX)
}

/// Dart-callable wrapper around [derive_uid] — lets the profile screen show
/// the account's own UID (e.g. for the user to compare against a friend's).
pub fn get_account_uid(mnemonic: String) -> Result<String, String> {
    derive_uid(&mnemonic)
}

/// Derives a key used only to sign the Blossom upload authorization (kind
/// 24242) when the account's own (encrypted) avatar is uploaded — never
/// shared with a friend, another device, or embedded in any event content,
/// so it never leaves this device except inside that one HTTP request's
/// `Authorization` header. Deliberately not the core identity (account 0)
/// or a per-contact key: those get shared (backup events, friend requests),
/// which would let anyone who ends up with the pubkey associate every past
/// and future avatar upload signed with it — a stable-but-never-disclosed
/// key means only the Blossom server operator itself could ever notice
/// "the same anonymous key re-uploaded a blob," and only if they already
/// watch that specific pubkey.
pub(crate) fn derive_avatar_upload_keys(mnemonic: &str) -> Result<Keys, String> {
    derive_contact_keys(mnemonic, AVATAR_UPLOAD_ACCOUNT_INDEX)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn generate_mnemonic_produces_a_valid_phrase() {
        let phrase = generate_mnemonic().expect("generation should succeed");
        assert!(validate_mnemonic(phrase).is_ok());
    }

    #[test]
    fn generate_mnemonic_is_not_deterministic() {
        let a = generate_mnemonic().unwrap();
        let b = generate_mnemonic().unwrap();
        assert_ne!(a, b, "two generated phrases should not collide");
    }

    #[test]
    fn validate_mnemonic_rejects_garbage() {
        assert!(validate_mnemonic("not a valid seed phrase at all".to_string()).is_err());
    }

    #[test]
    fn validate_mnemonic_accepts_surrounding_whitespace() {
        assert!(validate_mnemonic(format!("  {TEST_MNEMONIC}  ")).is_ok());
    }

    #[test]
    fn derive_contact_keys_is_deterministic() {
        let a = derive_contact_keys(TEST_MNEMONIC, 3).unwrap();
        let b = derive_contact_keys(TEST_MNEMONIC, 3).unwrap();
        assert_eq!(a.public_key(), b.public_key());
    }

    #[test]
    fn derive_contact_keys_differ_across_accounts() {
        let a = derive_contact_keys(TEST_MNEMONIC, 0).unwrap();
        let b = derive_contact_keys(TEST_MNEMONIC, 1).unwrap();
        assert_ne!(
            a.public_key(),
            b.public_key(),
            "each relationship must get an unlinkable key"
        );
    }

    #[test]
    fn derive_contact_keys_differ_across_mnemonics() {
        let other_mnemonic = generate_mnemonic().unwrap();
        let a = derive_contact_keys(TEST_MNEMONIC, 0).unwrap();
        let b = derive_contact_keys(&other_mnemonic, 0).unwrap();
        assert_ne!(a.public_key(), b.public_key());
    }

    #[test]
    fn derive_keys_matches_account_zero() {
        let a = derive_keys(TEST_MNEMONIC).unwrap();
        let b = derive_contact_keys(TEST_MNEMONIC, 0).unwrap();
        assert_eq!(a.public_key(), b.public_key());
    }

    #[test]
    fn derive_global_chat_keys_is_deterministic() {
        let a = derive_global_chat_keys(TEST_MNEMONIC).unwrap();
        let b = derive_global_chat_keys(TEST_MNEMONIC).unwrap();
        assert_eq!(a.public_key(), b.public_key());
    }

    #[test]
    fn derive_global_chat_keys_differ_from_core_and_contact_keys() {
        let global_chat = derive_global_chat_keys(TEST_MNEMONIC).unwrap();
        let core = derive_keys(TEST_MNEMONIC).unwrap();
        let contact = derive_contact_keys(TEST_MNEMONIC, 0).unwrap();
        assert_ne!(global_chat.public_key(), core.public_key());
        assert_ne!(global_chat.public_key(), contact.public_key());
    }

    #[test]
    fn derive_uid_is_deterministic_and_stable_across_relationships() {
        let uid_a = derive_uid(TEST_MNEMONIC).unwrap();
        let uid_b = derive_uid(TEST_MNEMONIC).unwrap();
        assert_eq!(uid_a, uid_b);

        // The UID must never collide with (or be derivable from) any
        // ordinary relationship-index pubkey, since it's shown to every
        // friend regardless of which relationship key they were added
        // under.
        let contact_key_hex = derive_contact_keys(TEST_MNEMONIC, 0)
            .unwrap()
            .public_key()
            .to_hex();
        assert_ne!(uid_a, contact_key_hex);
    }

    #[test]
    fn derive_uid_differs_across_mnemonics() {
        let other_mnemonic = generate_mnemonic().unwrap();
        let uid_a = derive_uid(TEST_MNEMONIC).unwrap();
        let uid_b = derive_uid(&other_mnemonic).unwrap();
        assert_ne!(uid_a, uid_b);
    }

    #[test]
    fn get_account_uid_matches_derive_uid() {
        assert_eq!(
            get_account_uid(TEST_MNEMONIC.to_string()).unwrap(),
            derive_uid(TEST_MNEMONIC).unwrap()
        );
    }
}
