//! Chat-side link previews (like Discord/WhatsApp's "unfurl a pasted URL"
//! card). Fetches the target page's HTML and pulls out Open Graph / plain
//! `<title>` metadata so the chat thread can show a small title/description/
//! thumbnail card under a message that contains a bare URL, without the user
//! having to leave the app to see what it links to.
//!
//! This is a UI-support feature, not protocol/storage logic, but it still
//! lives in Rust (not Dart) per the project's architecture split: it reuses
//! [attachment::http_client] (the TLS setup that makes HTTPS actually work
//! on Android) and needs real HTML parsing, which is much less error-prone
//! done once here than duplicated in Dart.

use crate::api::attachment::http_client;
use crate::api::sync::runtime;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const FETCH_TIMEOUT: Duration = Duration::from_secs(8);
/// Previews only need the `<head>`; capping how much body we read protects
/// against being handed a multi-gigabyte response by a malicious/misbehaving
/// server.
const MAX_BODY_BYTES: usize = 512 * 1024;

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct LinkPreview {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub image_url: Option<String>,
    pub site_name: Option<String>,
}

fn cache_path(storage_dir: &str) -> std::path::PathBuf {
    Path::new(storage_dir).join("link_preview_cache.json")
}

/// Process-lifetime cache so repeat fetches of the same URL within one app
/// run (e.g. re-scrolling a thread) never hit the network twice, on top of
/// the on-disk cache below (which survives app restarts).
static MEMORY_CACHE: OnceLock<Mutex<HashMap<String, LinkPreview>>> = OnceLock::new();

fn memory_cache() -> &'static Mutex<HashMap<String, LinkPreview>> {
    MEMORY_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn load_disk_cache(storage_dir: &str) -> HashMap<String, LinkPreview> {
    std::fs::read_to_string(cache_path(storage_dir))
        .ok()
        .and_then(|contents| serde_json::from_str(&contents).ok())
        .unwrap_or_default()
}

fn save_disk_cache(storage_dir: &str, cache: &HashMap<String, LinkPreview>) {
    if let Ok(json) = serde_json::to_string(cache) {
        let _ = std::fs::write(cache_path(storage_dir), json);
    }
}

/// Fetches `url` and extracts Open Graph (falling back to plain HTML) page
/// metadata for an inline preview card, going out to the network only on a
/// cache miss — a successful result is always kept in memory for the rest
/// of this run, and additionally persisted to `link_preview_cache.json`
/// under `storage_dir` when [persist] is true, so it's instant the next
/// time this chat is opened too, not just for the rest of this session.
/// Failures (network error, no usable metadata) are never cached to disk,
/// so a page that's temporarily unreachable gets retried on the next view
/// rather than being permanently remembered as failed.
///
/// [persist] should be false for public-channel messages: unlike a friend
/// list, a channel's senders are an unbounded set of strangers, so writing
/// every link anyone ever posts there to disk would grow the cache file
/// without bound. The in-memory cache still applies either way, so a link
/// re-fetched while scrolling the same channel session is still free.
pub fn fetch_link_preview(storage_dir: String, url: String, persist: bool) -> Result<LinkPreview, String> {
    if let Some(preview) = memory_cache().lock().unwrap().get(&url) {
        return Ok(preview.clone());
    }
    let disk_cache = load_disk_cache(&storage_dir);
    if let Some(preview) = disk_cache.get(&url) {
        memory_cache().lock().unwrap().insert(url, preview.clone());
        return Ok(preview.clone());
    }

    let preview = runtime().block_on(fetch_link_preview_async(url.clone()))?;
    memory_cache().lock().unwrap().insert(url.clone(), preview.clone());
    if persist {
        let mut disk_cache = disk_cache;
        disk_cache.insert(url, preview.clone());
        save_disk_cache(&storage_dir, &disk_cache);
    }
    Ok(preview)
}

async fn fetch_link_preview_async(url: String) -> Result<LinkPreview, String> {
    let parsed = url::Url::parse(&url).map_err(|e| e.to_string())?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err("unsupported URL scheme".to_string());
    }

    let response = tokio::time::timeout(
        FETCH_TIMEOUT,
        http_client()
            .get(parsed.clone())
            // A self-identifying bot UA (e.g. "OrigilinkBot/1.0") gets
            // blocked by sites that only allowlist known crawlers (Discord,
            // Twitter, ...) and don't recognize this app — a generic desktop
            // browser UA gets the same HTML a real visitor would see.
            .header(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            )
            .send(),
    )
    .await
    .map_err(|_| "timed out".to_string())?
    .map_err(|e| e.to_string())?;

    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let is_html = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .is_none_or(|ct| ct.contains("html"));
    if !is_html {
        return Err("not an HTML page".to_string());
    }

    let mut body = String::new();
    let mut stream = response;
    while let Some(chunk) = stream.chunk().await.map_err(|e| e.to_string())? {
        body.push_str(&String::from_utf8_lossy(&chunk));
        if body.len() >= MAX_BODY_BYTES {
            break;
        }
        // The metadata we care about is always in `<head>`; once we've seen
        // it close there's no need to keep downloading the rest of the page.
        if body.to_ascii_lowercase().contains("</head>") {
            break;
        }
    }

    let preview = parse_meta(&body, &parsed);
    if preview.title.is_none() && preview.description.is_none() && preview.image_url.is_none() {
        return Err("no preview metadata found".to_string());
    }
    Ok(preview)
}

fn parse_meta(html: &str, base: &url::Url) -> LinkPreview {
    let mut preview = LinkPreview {
        url: base.to_string(),
        ..Default::default()
    };
    let mut plain_title: Option<String> = None;

    // `<title>...</title>` — extracted separately since it's not a
    // self-closing/attribute-only tag like the `<meta>` ones below.
    if let Some(start) = html.to_ascii_lowercase().find("<title") {
        if let Some(open_end) = html[start..].find('>') {
            let content_start = start + open_end + 1;
            if let Some(close) = html[content_start..].to_ascii_lowercase().find("</title>") {
                plain_title = Some(decode_entities(html[content_start..content_start + close].trim()));
            }
        }
    }

    for tag in html_tags(html) {
        if !tag.to_ascii_lowercase().starts_with("<meta") {
            continue;
        }
        let property = attr(tag, "property").or_else(|| attr(tag, "name"));
        let Some(property) = property else { continue };
        let Some(content) = attr(tag, "content") else { continue };
        let content = decode_entities(&content);
        match property.as_str() {
            "og:title" => preview.title = Some(content),
            "og:description" | "description" if preview.description.is_none() => {
                preview.description = Some(content)
            }
            "og:image" | "og:image:url" => {
                preview.image_url = Some(resolve_url(base, &content));
            }
            "og:site_name" => preview.site_name = Some(content),
            _ => {}
        }
    }

    if preview.title.is_none() {
        preview.title = plain_title;
    }
    if preview.site_name.is_none() {
        preview.site_name = base.host_str().map(|h| h.to_string());
    }
    preview
}

/// Splits HTML into individual `<...>` tags — good enough for pulling
/// attributes out of `<meta>`/`<title>` tags in real-world pages without
/// pulling in a full HTML parser dependency just for this.
fn html_tags(html: &str) -> impl Iterator<Item = &str> {
    let mut rest = html;
    std::iter::from_fn(move || {
        let start = rest.find('<')?;
        let end = rest[start..].find('>')? + start;
        let tag = &rest[start..=end];
        rest = &rest[end + 1..];
        Some(tag)
    })
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let needle = format!("{name}=");
    let idx = lower.find(&needle)?;
    let after = &tag[idx + needle.len()..];
    let quote = after.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let close = after[1..].find(quote)?;
    Some(after[1..1 + close].to_string())
}

fn resolve_url(base: &url::Url, maybe_relative: &str) -> String {
    base.join(maybe_relative)
        .map(|u| u.to_string())
        .unwrap_or_else(|_| maybe_relative.to_string())
}

fn decode_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}

/// First `http(s)://` URL found in free-form message text, or `None` — used
/// by the chat thread to decide whether to show a preview card at all.
pub fn extract_first_url(text: String) -> Option<String> {
    extract_urls(text).into_iter().next()
}

/// Every distinct `http(s)://` URL found in free-form message text, in the
/// order they first appear — used by the chat thread to show one preview
/// card per link when a message contains more than one, instead of only
/// unfurling the first.
pub fn extract_urls(text: String) -> Vec<String> {
    let mut urls = Vec::new();
    for word in text.split_whitespace() {
        let candidate = word.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '/' && c != '%');
        if candidate.starts_with("http://") || candidate.starts_with("https://") {
            if url::Url::parse(candidate).is_ok() && !urls.iter().any(|u| u == candidate) {
                urls.push(candidate.to_string());
            }
        }
    }
    urls
}
