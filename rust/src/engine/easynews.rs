//! Easynews web arama API'si — NNTP motorundan ayrı kod yolu (roadmap #4).
//!
//! `members.easynews.com` üzerindeki (resmî olmayan, toplulukça
//! doğrulanmış) 2.0 arama ucu JSON döner:
//! `GET /2.0/search/solr-search/advanced?gps=…&pno=…&pby=…` — HTTP Basic
//! kimlik doğrulaması NNTP hesabıyla aynıdır. NZB üretimi ise yalnız POST
//! kabul eden `POST /2.0/api/dl-nzb` ucudur (`autoNZB=1` + `0&sig=…` form
//! alanı, değer Easynews "value token"ı `hash|b64(fn):b64(ext)`); sonuç
//! bellidir ve oynatma mevcut NNTP akışıyla sürer.
//!
//! Modül tamamen ağsızdır (newznab modülüyle aynı disiplin): URL kurulumu,
//! JSON çözümlemesi, token oluşturma ve NZB doğrulaması fixture'lerle
//! birim test edilir; taşıyıcı [`super::http`], ağ çağrıları [`crate::api`].
//!
//! Gizlilik kuralı: kullanıcı adı/parola hiçbir hata türüne veya `Debug`
//! çıktısına girmez; yanıt boyutları üstten sınırlıdır.

use serde_json::Value;

use super::nzb;

/// Hesap varsayılanı; ayarlardan boş URL gelirse bu kullanılır.
pub const DEFAULT_BASE_URL: &str = "https://members.easynews.com";

const SEARCH_PATH: &str = "/2.0/search/solr-search/advanced";
const NZB_POST_PATH: &str = "/2.0/api/dl-nzb";

#[derive(Debug, thiserror::Error)]
pub enum EasynewsError {
    #[error("malformed Easynews response: {0}")]
    Parse(&'static str),
}

/// Arama sonucunda oynatılabilir tek dosya. `sig` NZB üretimi için zorunlu;
/// `filename` görünen ad ve release çözümlemesinin kaynağıdır.
pub struct EasynewsFile {
    pub hash: String,
    /// `fn` + uzantı (nokta dahil).
    pub filename: String,
    pub size_bytes: Option<u64>,
    pub published_epoch_secs: Option<i64>,
    /// Konu satırı (Easynews'te genelde fazladan bilgi/şifrelikoşu).
    pub subject: String,
    /// İlk newsgroup (yoksa None).
    pub group: Option<String>,
    /// Dosya başına imza; `dl-nzb` bunu zorunlu kılar (sigsiz istek boş
    /// NZB iskeletine düşer).
    pub sig: String,
}

pub struct EasynewsPage {
    pub total: Option<u64>,
    pub files: Vec<EasynewsFile>,
}

/// `easynews:` şemalı getiri referansının ayrıştırılmış hali.
pub struct EasynewsNzbRequest {
    pub hash: String,
    /// Uzantısız dosya adı.
    pub stem: String,
    /// Uzantı, noktasız ("mkv").
    pub ext: String,
    pub sig: String,
}

// ---------------------------------------------------------------------------
// Yardımcı kodlayıcılar
// ---------------------------------------------------------------------------

const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// RFC 4648 standart Base64 (dolgulu). Kimlik başlığı ve dl-nzb value
/// token'ı için gereklidir; hazır crate yerine ~20 satırlık doğrulanmış
/// uygulama tercih edilir (bağımlılık disiplini).
pub fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(BASE64_ALPHABET[(triple >> 18 & 63) as usize] as char);
        out.push(BASE64_ALPHABET[(triple >> 12 & 63) as usize] as char);
        if chunk.len() > 1 {
            out.push(BASE64_ALPHABET[(triple >> 6 & 63) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(BASE64_ALPHABET[(triple & 63) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

/// Yüzde kodlanmış baytı çözer; geçersiz dizilim/UTF-8'de None.
pub fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let hi = (hex[0] as char).to_digit(16)?;
            let lo = (hex[1] as char).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `Authorization: Basic …` başlık değeri. Kimlik değeri yalnız burada
/// birleştirilir; hiçbir hata/`Debug` çıktısına taşınmaz.
pub fn authorization_basic(username: &str, password: &str) -> String {
    let credentials = format!("{username}:{password}");
    format!("Basic {}", base64_encode(credentials.as_bytes()))
}

// ---------------------------------------------------------------------------
// Arama
// ---------------------------------------------------------------------------

fn normalize_base_url(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        DEFAULT_BASE_URL.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Gelişmiş arama URL'si. Parametre adları alfabetik sıradadır; `gps`
/// sorguyu, `pby` sayfa boyunu, `pno` 1-tabanlı sayfa numarasını taşır.
/// `st=adv` gelişmiş kip, `sS=0` JSON yanıt, `spamf=1` sunucu tarafı spam
/// filtresi, `fty[]=VIDEO` yalnız video türü demektir.
pub fn build_search_url(base_url: &str, gps: &str, per_page: u32, page: u32) -> String {
    let per_page = per_page.clamp(1, 100);
    let page = page.max(1);
    format!(
        "{}{SEARCH_PATH}?fty%5B%5D=VIDEO&gps={}&pby={per_page}&pno={page}&sS=0&sb=1&spamf=1&st=adv",
        normalize_base_url(base_url),
        super::newznab::percent_encode(gps)
    )
}

/// JSON arama yanıtını çözer ve oynatılabilir dosyaları seçer:
/// - `type` varsa VIDEO olmalı (`fty[]` filtresiyle birlikte kemer-kuşak),
/// - parolalı/`virus` işaretli gönderiler atlanır,
/// - uzantı [`nzb::is_playable_media_filename`] listesine göre filtrelenir,
/// - `sig`'siz satırlar atlanır (NZB üretilemez),
/// - adlandırılmış alanlar (`fn`, `extension`, `hash`, `sig`…) öncelikli,
///   sayısal Easynews sütun kimlikleri (`10`, `11`, `0`…) yedek olarak okunur.
pub fn parse_search_response(body: &str) -> Result<EasynewsPage, EasynewsError> {
    let root: Value =
        serde_json::from_str(body).map_err(|_| EasynewsError::Parse("response is not JSON"))?;
    let total = root.get("results").and_then(Value::as_u64);
    let data = root
        .get("data")
        .and_then(Value::as_array)
        .ok_or(EasynewsError::Parse("response has no data array"))?;

    let mut files = Vec::new();
    for entry in data {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        // Tür filtresi: alan yoksa (gelecekteki şema değişikliği) toleranslı
        // davran; varsa yalnız VIDEO kabul edilir.
        if let Some(kind) = named_str(entry, "type") {
            if !kind.eq_ignore_ascii_case("video") {
                continue;
            }
        }
        if truthy(entry, "passwd") || truthy(entry, "password") || truthy(entry, "virus") {
            continue;
        }

        let Some(name) = named_str(entry, "fn").or_else(|| named_str(entry, "10")) else {
            continue;
        };
        let Some(extension) =
            named_str(entry, "extension").or_else(|| named_str(entry, "11").map(|e| {
                // Sütun değeri noktasız, adlandırılmış değer noktalı olabilir;
                // birleştirmede tek biçime indirgenir.
                format!(".{e}")
            }))
        else {
            continue;
        };
        // Uzantı noktayla birleştiğinde dosya adı TEK biçime iner.
        let filename = if let Some(dotted) = extension.strip_prefix('.') {
            format!("{name}.{dotted}")
        } else {
            format!("{name}{extension}")
        };
        if !nzb::is_playable_media_filename(&filename) {
            continue;
        }

        let Some(hash) = named_str(entry, "hash").or_else(|| named_str(entry, "0")) else {
            continue;
        };
        let Some(sig) = named_str(entry, "sig") else {
            // sig üretimi dl-nzb'de zorunlu; sigsiz istek boş NZB döner.
            continue;
        };
        if hash.is_empty() || sig.is_empty() || name.is_empty() {
            continue;
        }

        files.push(EasynewsFile {
            hash,
            filename,
            size_bytes: parse_u64(entry, &["size", "4"]),
            published_epoch_secs: parse_i64(entry, &["timestamp", "5", "ts"]),
            subject: named_str(entry, "subject")
                .or_else(|| named_str(entry, "6"))
                .unwrap_or_default(),
            group: first_group(entry),
            sig,
        });
    }
    Ok(EasynewsPage { total, files })
}

/// Adlandırılmış anahtarın dize değeri; sayısal değerler de dizeye çevrilir.
fn named_str(entry: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    match entry.get(key) {
        Some(Value::String(value)) => Some(value.clone()),
        Some(Value::Number(number)) => Some(number.to_string()),
        _ => None,
    }
}

/// Bayrak alanları: `true`, 1 veya "1" doğru sayılır.
fn truthy(entry: &serde_json::Map<String, Value>, key: &str) -> bool {
    match entry.get(key) {
        Some(Value::Bool(value)) => *value,
        Some(Value::Number(number)) => number.as_i64() == Some(1),
        Some(Value::String(value)) => value == "1" || value.eq_ignore_ascii_case("true"),
        _ => false,
    }
}

/// Aday anahtarlardan ilk işleyen sayıyı okur (u64/i64 toleranslı; sayı
/// olarak gelmeyen diziler de çözümlenir).
fn parse_u64(entry: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<u64> {
    for key in keys {
        match entry.get(*key) {
            Some(Value::Number(number)) => return number.as_u64(),
            Some(Value::String(value)) => {
                if let Ok(parsed) = value.trim().parse::<u64>() {
                    return Some(parsed);
                }
            }
            _ => {}
        }
    }
    None
}

fn parse_i64(entry: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<i64> {
    for key in keys {
        match entry.get(*key) {
            Some(Value::Number(number)) => {
                if let Some(value) = number.as_i64() {
                    return Some(value);
                }
                if let Some(value) = number.as_u64() {
                    return i64::try_from(value).ok();
                }
            }
            Some(Value::String(value)) => {
                if let Ok(parsed) = value.trim().parse::<i64>() {
                    return Some(parsed);
                }
            }
            _ => {}
        }
    }
    None
}

/// `groups`/`group_list` alanından ilk newsgroup'u seçer; dizi veya
/// virgülle ayrılmış dize olabilir.
fn first_group(entry: &serde_json::Map<String, Value>) -> Option<String> {
    for key in ["groups", "group_list", "9"] {
        match entry.get(key) {
            Some(Value::Array(list)) => {
                if let Some(first) = list.iter().find_map(Value::as_str) {
                    return Some(first.to_string());
                }
            }
            Some(Value::String(value)) => {
                let first = value.split(',').next().unwrap_or("").trim();
                if !first.is_empty() {
                    return Some(first.to_string());
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------------------
// NZB getiri referansı ve form gövdesi
// ---------------------------------------------------------------------------

/// Arama sonucu → `easynews:` referansı. Bileşenler yüzde kodlanır; `|`
/// ayraçları ham biçimde kalır (kodlanmış bileşenler ayrıştırıcıya göre
/// `|` üretemez).
pub fn build_nzb_url(hash: &str, filename: &str, sig: &str) -> String {
    use super::newznab::percent_encode;
    format!(
        "easynews:{}|{}|{}",
        percent_encode(hash),
        percent_encode(filename),
        percent_encode(sig)
    )
}

/// `easynews:` referansını ayrıştırır; şema dışı değerler None döner.
pub fn parse_nzb_url(url: &str) -> Option<EasynewsNzbRequest> {
    let rest = url.strip_prefix("easynews:")?;
    let (head, sig) = rest.rsplit_once('|')?;
    let (hash, filename) = head.split_once('|')?;
    let sig = percent_decode(sig)?;
    let filename = percent_decode(filename)?;
    let hash = percent_decode(hash)?;
    let (stem, ext) = filename.rsplit_once('.')?;
    if hash.is_empty() || filename.is_empty() || sig.is_empty() {
        return None;
    }
    Some(EasynewsNzbRequest {
        hash,
        stem: stem.to_string(),
        ext: ext.to_string(),
        sig,
    })
}

/// dl-nzb POST gövdesi (application/x-www-form-urlencoded): alan
/// adı `0&sig={sig}` olduğu için adın kendisi de kodlanmak zorundadır;
/// değer Easynews value token'ı `hash|b64(stem):b64(ext)`.
pub fn build_download_form(request: &EasynewsNzbRequest) -> String {
    let token = format!(
        "{}|{}:{}",
        request.hash,
        base64_encode(request.stem.as_bytes()),
        base64_encode(request.ext.as_bytes())
    );
    format!(
        "autoNZB=1&{}={}",
        super::newznab::percent_encode(&format!("0&sig={}", request.sig)),
        super::newznab::percent_encode(&token)
    )
}

/// dl-nzb yanıtının gerçekten NZB belgesi olduğunu doğrular: başta `<nzb`
/// bulunmalı ve belge en az bir `<file` girdisi taşımalıdır (sigsiz/geçersiz
/// istekler boş `<nzb/>` iskeleti döndürür).
pub fn validate_nzb_document(body: &[u8]) -> Result<(), &'static str> {
    let head: &[u8] = body.get(..body.len().min(4096)).unwrap_or(body);
    if !head.windows(4).any(|w| w == b"<nzb") {
        return Err("Easynews did not return an NZB document");
    }
    if !body.windows(5).any(|w| w == b"<file") {
        return Err("Easynews returned an empty NZB (stale search result)");
    }
    Ok(())
}

/// dl-nzb uç adresi (POST).
pub fn nzb_post_url(base_url: &str) -> String {
    format!("{}{NZB_POST_PATH}", normalize_base_url(base_url))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_rfc4648_vektorleri() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        // Kullanıcı adı uzayımında: ASCII olmayan baytlar da kodlanmalı.
        assert_eq!(
            base64_encode("kullanıcı:parola".as_bytes()),
            "a3VsbGFuxLFjxLE6cGFyb2xh"
        );
    }

    #[test]
    fn basic_kimlik_basligi() {
        assert_eq!(authorization_basic("a", "b"), "Basic YTpi");
        // iki nokta dahil parolalar Token'dan bağımsız çözülür.
        assert_eq!(authorization_basic("u", "p:x!"), "Basic dTpwOngh");
    }

    #[test]
    fn yüzde_kod_cozumu() {
        assert_eq!(percent_decode("abc%20d"), Some("abc d".to_string()));
        assert_eq!(percent_decode("abc+def"), Some("abc+def".to_string()));
        assert_eq!(percent_decode("%C3%A7"), Some("ç".to_string()));
        assert_eq!(percent_decode("%zz"), None);
        assert_eq!(percent_decode("%C3"), None);
    }

    #[test]
    fn arama_url_kurulumu() {
        assert_eq!(
            build_search_url("", "film adı", 50, 1),
            "https://members.easynews.com/2.0/search/solr-search/advanced\
             ?fty%5B%5D=VIDEO&gps=film%20ad%C4%B1&pby=50&pno=1&sS=0&sb=1&spamf=1&st=adv"
        );
        // Varsayılanlar: taşan sayfa boyu kırpılır, sayfa 1'den küçük olamaz.
        assert!(build_search_url("https://mirror.example/", "x", 500, 0).contains("pby=100"));
        assert!(build_search_url("https://mirror.example/", "x", 100, 0).contains("pno=1"));
    }

    const SEARCH_FIXTURE: &str = r#"{
        "sid": "abc123",
        "results": 84,
        "perPage": 100,
        "numPages": 1,
        "page": 1,
        "downURL": "https://members.easynews.com/dl",
        "data": [
            {
                "0": "7f9c2a1b88d34e02f1a5555d",
                "hash": "7f9c2a1b88d34e02f1a5555d",
                "10": "Movie.2024.2160p.WEB-DL.DV.HEVC-GRP",
                "fn": "Movie.2024.2160p.WEB-DL.DV.HEVC-GRP",
                "11": "mkv",
                "extension": ".mkv",
                "4": "16106127360",
                "size": 16106127360,
                "5": "1717245600",
                "timestamp": 1717245600,
                "6": "\"Movie.2024.2160p.WEB-DL.DV.HEVC-GRP.mkv\" yEnc (1/97)",
                "subject": "\"Movie.2024.2160p.WEB-DL.DV.HEVC-GRP.mkv\" yEnc (1/97)",
                "9": "alt.binaries.hdtv.x264",
                "groups": ["alt.binaries.hdtv.x264", "alt.binaries.uhd"],
                "type": "VIDEO",
                "sig": "MTY3OTk5OTk5LHByZXZp",
                "passwd": false,
                "virus": false
            },
            {
                "hash": "aa11bb22cc33dd44ee55",
                "fn": "Show.S01E05.1080p.GRP",
                "11": "mkv",
                "size": "734003200",
                "ts": 1717240000,
                "groups": "alt.binaries.tv,alt.binaries.tv2",
                "type": "VIDEO",
                "sig": "c2lnMQ=="
            },
            { "hash": "px1", "fn": "Parolali.Rip", "extension": ".rar", "type": "VIDEO", "password": true, "sig": "x" },
            { "hash": "vx2", "fn": "Viruslu.Rip", "extension": ".mkv", "type": "VIDEO", "virus": true, "sig": "x" },
            { "hash": "ax3", "fn": "Sarki.Album", "extension": ".mp3", "type": "AUDIO", "sig": "x" },
            { "hash": "ix4", "fn": "Kurulum", "extension": ".exe", "type": "OTHER", "sig": "x" },
            { "hash": "sx5", "fn": "Sig'siz Yayın", "extension": ".mkv", "type": "VIDEO" },
            { "hash": "hx6", "extension": ".mkv", "type": "VIDEO", "sig": "y" }
        ]
    }"#;

    #[test]
    fn arama_yaniti_filtreleri_uygular() {
        let page = parse_search_response(SEARCH_FIXTURE).unwrap();
        assert_eq!(page.total, Some(84));
        assert_eq!(page.files.len(), 2);

        let first = &page.files[0];
        assert_eq!(first.hash, "7f9c2a1b88d34e02f1a5555d");
        assert_eq!(first.filename, "Movie.2024.2160p.WEB-DL.DV.HEVC-GRP.mkv");
        assert_eq!(first.size_bytes, Some(16_106_127_360));
        assert_eq!(first.published_epoch_secs, Some(1_717_245_600));
        assert_eq!(first.group.as_deref(), Some("alt.binaries.hdtv.x264"));
        assert_eq!(first.sig, "MTY3OTk5OTk5LHByZXZp");

        // Sayısal sütun yedeği + noktasız uzantı + dize boyut/tarih.
        let second = &page.files[1];
        assert_eq!(second.filename, "Show.S01E05.1080p.GRP.mkv");
        assert_eq!(second.size_bytes, Some(734_003_200));
        assert_eq!(second.published_epoch_secs, Some(1_717_240_000));
        assert_eq!(second.group.as_deref(), Some("alt.binaries.tv"));
    }

    #[test]
    fn arama_yaniti_eksik_veri_hatasi() {
        assert!(matches!(
            parse_search_response("{}"),
            Err(EasynewsError::Parse(_))
        ));
        assert!(matches!(
            parse_search_response("not json"),
            Err(EasynewsError::Parse(_))
        ));
        // data dizisi boşsa geçerli boş sonuçtur.
        assert!(parse_search_response(r#"{"results": 0, "data": []}"#)
            .unwrap()
            .files
            .is_empty());
    }

    #[test]
    fn token_referansi_gidiş_dönüşü() {
        let url = build_nzb_url("hash 12", "Movie 2024.mkv", "sig=&x");
        assert_eq!(url, "easynews:hash%2012|Movie%202024.mkv|sig%3D%26x");
        let request = parse_nzb_url(&url).unwrap();
        assert_eq!(request.hash, "hash 12");
        assert_eq!(request.stem, "Movie 2024");
        assert_eq!(request.ext, "mkv");
        assert_eq!(request.sig, "sig=&x");

        // Şemasız ve bozuk değerler reddedilir.
        assert!(parse_nzb_url("https://members.example/get/1").is_none());
        assert!(parse_nzb_url("easynews:%zz|a.mkv|sig").is_none());
        assert!(parse_nzb_url("easynews:hash|noktasizad|sig").is_none());
        assert!(parse_nzb_url("easynews:hash|a.mkv|").is_none());
    }

    #[test]
    fn dl_nzb_form_govdesi() {
        let request = EasynewsNzbRequest {
            hash: "7f9c2a1b".to_string(),
            stem: "Movie 2024+".to_string(),
            ext: "mkv".to_string(),
            sig: "MTY3OTk5OTk5LHByZXZp".to_string(),
        };
        let form = build_download_form(&request);
        // Alan adı ('0&sig=…') kendisi kodlanmalı; token b64 ikilisini taşır.
        assert_eq!(
            form,
            "autoNZB=1&0%26sig%3DMTY3OTk5OTk5LHByZXZp=7f9c2a1b%7CTW92aWUgMjAyNCs%3D%3AbWt2"
        );
        // Uzantı yoksa base64'te '=' dolgusu yüzde kodlu kalır; eğilim ayırt
        // etmez — sunucu ikisini de aynı çözer.
        assert!(build_download_form(&EasynewsNzbRequest {
            hash: "h".to_string(),
            stem: "a".to_string(),
            ext: "mkv".to_string(),
            sig: "s".to_string(),
        })
        .starts_with("autoNZB=1&0%26sig%3Ds="));
    }

    #[test]
    fn dl_nzb_yanit_dogrulamasi() {
        let valid = br#"<?xml version="1.0"?><nzb xmlns="..."><file subject="x" poster="p" date="1"><groups><group>a</group></groups></file></nzb>"#;
        assert!(validate_nzb_document(valid).is_ok());
        // <file> yoksa boş iskelet: hata.
        let hollow = br#"<nzb xmlns="..."/>"#;
        assert_eq!(
            validate_nzb_document(hollow),
            Err("Easynews returned an empty NZB (stale search result)")
        );
        assert_eq!(
            validate_nzb_document(b"<html>login</html>"),
            Err("Easynews did not return an NZB document")
        );
    }

    #[test]
    fn dl_nzb_uc_adresi() {
        assert_eq!(
            nzb_post_url(""),
            "https://members.easynews.com/2.0/api/dl-nzb"
        );
        assert_eq!(
            nzb_post_url("https://mirror.example/"),
            "https://mirror.example/2.0/api/dl-nzb"
        );
    }
}
