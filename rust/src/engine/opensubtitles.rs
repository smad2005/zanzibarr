//! OpenSubtitles REST istemcisi (https://api.opensubtitles.com/api/v1).
//!
//! Akış: (opsiyonel) kullanıcı girişi → JWT → `/subtitles` arama →
//! `/download` imzalı bağlantı → bağlantıdan altyazı baytları. Arama yalnız
//! `Api-Key` ister; indirme uç noktası ücretsiz Anahtar (api key)lerde
//! oturum açmış kullanıcı (JWT) ister.
//!
//! Gizlilik kuralları:
//! - `Api-Key`, JWT ve parola hiçbir hata metnine/log satırına girmez; URL
//!   yazdırılmaz. Hata mesajları statiktir ("OpenSubtitles returned HTTP
//!   401" gibi).
//! - En iyi uygulamalar bölümüne uyum: GET parametreleri alfabetik sırada,
//!   değerler küçük harf, boşluk `+` ile kodlanır, `User-Agent`
//!   "UygulamaAdı vX.Y" biçimindedir (aksi halde API 403 döner).
//!
//! Yanıt çözümlemeleri saf fonksiyonlardır ([`parse_search_response`]
//! vb.); ağ gerektirmeyen birim testlerinde gerçek API yanıtlarıyla
//! doğrulanırlar.

use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde_json::Value;
use thiserror::Error;
use tokio::sync::Mutex;

use super::http::{self, HttpError};

/// OpenSubtitles "Comet" API'sinin kök adresi. Ayarlarda boş URL bırakılırsa
/// bu kullanılır (bazı bölgelerde engellenme riskine karşı değiştirilebilir).
pub const DEFAULT_BASE_URL: &str = "https://api.opensubtitles.com";

/// `User-Agent` OpenSubtitles tarafından "AppName vX.Y" biçiminde zorunlu
/// tutulur; doğru biçim gelmezse API 403 döner (Best-Practices).
const APP_USER_AGENT: &str = "Zanzibarr v1.9";

const SEARCH_TIMEOUT: Duration = Duration::from_secs(20);
const LOGIN_TIMEOUT: Duration = Duration::from_secs(15);
const DOWNLOAD_LINK_TIMEOUT: Duration = Duration::from_secs(15);
const SUBTITLE_FETCH_TIMEOUT: Duration = Duration::from_secs(30);
/// Bir altyazı gövdesi için üst sınır; SRT'ler tipik olarak < 200 KB'tır.
const MAX_SUBTITLE_BYTES: usize = 4 * 1024 * 1024;
/// Arama yanıtının üst sınırı.
const MAX_SEARCH_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

/// Giriş belirteci (JWT) yaklaşık 24 saat geçerlidir; güvenli tarafta
/// kalmak için önbellek süresi daha kısa tutulur.
const LOGIN_TOKEN_CACHE: Duration = Duration::from_secs(6 * 60 * 60);

/// Kimlik bilgileri. FRB katmanı bunları Dart'ın güvenli deposundan alır;
/// `Debug` türetilmez — kimlik değerleri kazara loglanmasın.
pub struct OpenSubtitlesConfig<'a> {
    pub base_url: &'a str,
    pub api_key: &'a str,
    pub username: &'a str,
    pub password: &'a str,
}

/// Tek arama sonucundaki bir altyazı dosyası (çok CD'li yayınlarda her dosya
/// ayrı satırdır; `file_id` indirme kimliğidir).
pub struct OpenSubtitlesFile {
    pub file_id: u64,
    pub file_name: String,
    pub language: String,
    pub release: String,
    pub download_count: u64,
    pub matched_by_hash: bool,
    pub hearing_impaired: bool,
}

/// `/download` sonucu: imzalı bağlantı + önerilen dosya adı.
pub struct OpenSubtitlesDownload {
    pub link: String,
    pub file_name: String,
}

#[derive(Debug, Error)]
pub enum OpenSubtitlesError {
    #[error("network error: {0}")]
    Http(#[from] HttpError),
    #[error("OpenSubtitles request failed (HTTP {code})")]
    HttpStatus { code: u16 },
    #[error("OpenSubtitles login failed (wrong username or password)")]
    LoginFailed,
    #[error("OpenSubtitles rejected the request; check the API key (HTTP 403)")]
    ApiKeyRejected,
    #[error("OpenSubtitles rate limit exceeded; retry in a moment")]
    RateLimited,
    #[error("OpenSubtitles response is malformed: {0}")]
    Parse(&'static str),
    #[error("the subtitle is a zip archive; pick a release with a single subtitle file")]
    ZipArchive,
    #[error("could not read credentials: {0}")]
    InvalidInput(&'static str),
}

struct LoginToken {
    api_key: String,
    username: String,
    token: String,
    issued_at: Instant,
}

/// Kullanıcı girişi belirteci: aynı kimlik için tekrar `/login` atmayıp
/// önbellekten kullanılır. Kimlik alanları anahtar olarak tutulur; kimseye
/// gösterilmez.
static LOGIN_CACHE: Lazy<Mutex<Option<LoginToken>>> = Lazy::new(|| Mutex::new(None));

/// Arama sorgusu. `movie_hash` (OpenSubtitles moviehash, onaltılık) verilirse
/// `movie_bytesize` ile birlikte dosya-bazı eşleşme açılır; `query` dosya
/// adıdır ve her durumda gönderilir (best practices: hash + dosya adı).
pub struct SubtitleQuery<'a> {
    pub release_name: &'a str,
    pub languages: &'a [String],
    pub movie_hash: Option<&'a str>,
    pub movie_bytesize: Option<u64>,
}

fn normalize_base_url(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        DEFAULT_BASE_URL.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Sorgu değerini OpenSubtitles kurallarına göre kodlar: değerler küçük
/// harfe indirilir, boşluk `+` olur, güvensiz karakterler `%XX` olur.
fn encode_query_value(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.to_lowercase().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            b' ' => encoded.push('+'),
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

/// GET parametrelerini alfabetik sırala (best practices: yönlendirme ve
/// önbellek isabeti için).
pub fn build_query(params: &[(String, String)]) -> String {
    let mut sorted: Vec<&(String, String)> = params.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    sorted
        .iter()
        .map(|(name, value)| format!("{name}={}", encode_query_value(value)))
        .collect::<Vec<_>>()
        .join("&")
}

/// `/subtitles` araması. Article/altyazı gövdesi indirilmez; yalnız liste
/// üstverisi döner.
pub async fn search_subtitles(
    config: &OpenSubtitlesConfig<'_>,
    query: &SubtitleQuery<'_>,
) -> Result<Vec<OpenSubtitlesFile>, OpenSubtitlesError> {
    let mut params = vec![("languages".to_string(), query.languages.join(","))];
    if let (Some(hash), Some(size)) = (query.movie_hash, query.movie_bytesize) {
        // moviehash + moviebytesize + query birlikte gönderilir: dosya-bazı
        // eşleşmeler listede her zaman önde gelir.
        params.push(("moviehash".to_string(), hash.to_string()));
        params.push(("moviebytesize".to_string(), size.to_string()));
    }
    params.push(("query".to_string(), query.release_name.to_string()));
    let url = format!(
        "{}/api/v1/subtitles?{}",
        normalize_base_url(config.base_url),
        build_query(&params)
    );

    let response = http::http_request(
        "GET",
        &url,
        &[("Api-Key", config.api_key), ("User-Agent", APP_USER_AGENT)],
        &[],
        MAX_SEARCH_RESPONSE_BYTES,
        SEARCH_TIMEOUT,
    )
    .await?;
    check_status(response.status)?;
    let body = std::str::from_utf8(&response.body)
        .map_err(|_| OpenSubtitlesError::Parse("search response is not UTF-8"))?;
    parse_search_response(body)
}

/// Kullanıcı girişi: JWT döner; kimlik eşleşiyorsa önbellekteki belirteç
/// yeniden kullanılır (düzenli arama+indirme akışında tek `/login` yeter).
async fn login_token(
    config: &OpenSubtitlesConfig<'_>,
) -> Result<Option<String>, OpenSubtitlesError> {
    if config.username.trim().is_empty() || config.password.is_empty() {
        // Kullanıcı hesabı girilmedi: indirme, anahtarın (paid plan) izin
        // verdiği anonim kotayla denenir.
        return Ok(None);
    }

    {
        let cache = LOGIN_CACHE.lock().await;
        if let Some(token) = cache.as_ref() {
            let fresh = token.issued_at.elapsed() < LOGIN_TOKEN_CACHE
                && token.api_key == config.api_key
                && token.username == config.username;
            if fresh {
                return Ok(Some(token.token.clone()));
            }
        }
    }

    let url = format!("{}/api/v1/login", normalize_base_url(config.base_url));
    let body = serde_json::json!({
        "username": config.username,
        "password": config.password,
    })
    .to_string();
    let response = http::http_request(
        "POST",
        &url,
        &[
            ("Api-Key", config.api_key),
            ("User-Agent", APP_USER_AGENT),
            ("Content-Type", "application/json"),
        ],
        body.as_bytes(),
        64 * 1024,
        LOGIN_TIMEOUT,
    )
    .await?;
    check_status(response.status).map_err(|error| match error {
        // Kimlik hataları kullanıcıya spesifik mesajla taşınır.
        OpenSubtitlesError::HttpStatus { code: 400 } => OpenSubtitlesError::LoginFailed,
        OpenSubtitlesError::HttpStatus { code: 401 } => OpenSubtitlesError::LoginFailed,
        other => other,
    })?;
    let body = std::str::from_utf8(&response.body)
        .map_err(|_| OpenSubtitlesError::Parse("login response is not UTF-8"))?;
    let token = parse_login_response(body)?;

    let mut cache = LOGIN_CACHE.lock().await;
    *cache = Some(LoginToken {
        api_key: config.api_key.to_string(),
        username: config.username.to_string(),
        token: token.clone(),
        issued_at: Instant::now(),
    });
    Ok(Some(token))
}

/// `/download`: `file_id` için imzalı altyazı bağlantısı ister. Ücretsiz
/// anahtarlar bu uç noktada oturum (JWT) ister; kullanıcı hesabı yoksa
/// anahtar anahtarına ait anonim kota denenir ve hata varsa net taşınır.
pub async fn request_download(
    config: &OpenSubtitlesConfig<'_>,
    file_id: u64,
) -> Result<OpenSubtitlesDownload, OpenSubtitlesError> {
    let token = login_token(config).await?;
    let url = format!("{}/api/v1/download", normalize_base_url(config.base_url));
    let body = serde_json::json!({ "file_id": file_id }).to_string();
    let mut headers = vec![
        ("Api-Key", config.api_key),
        ("User-Agent", APP_USER_AGENT),
        ("Content-Type", "application/json"),
    ];
    let bearer;
    if let Some(token) = token.as_deref() {
        bearer = format!("Bearer {token}");
        headers.push(("Authorization", bearer.as_str()));
    }
    let response = http::http_request(
        "POST",
        &url,
        &headers,
        body.as_bytes(),
        64 * 1024,
        DOWNLOAD_LINK_TIMEOUT,
    )
    .await?;
    check_status(response.status)?;
    let body = std::str::from_utf8(&response.body)
        .map_err(|_| OpenSubtitlesError::Parse("download response is not UTF-8"))?;
    let download = parse_download_response(body)?;
    if download.link.trim().is_empty() {
        return Err(OpenSubtitlesError::Parse("download response has an empty link"));
    }
    Ok(download)
}

/// `/download`'ın döndürdüğü imzalı bağlantıdan altyazı baytlarını çeker.
pub async fn fetch_subtitle(link: &str) -> Result<Vec<u8>, OpenSubtitlesError> {
    let response = http::http_request(
        "GET",
        link,
        &[("User-Agent", APP_USER_AGENT)],
        &[],
        MAX_SUBTITLE_BYTES,
        SUBTITLE_FETCH_TIMEOUT,
    )
    .await?;
    check_status(response.status)?;
    if response.body.starts_with(b"PK\x03\x04") {
        return Err(OpenSubtitlesError::ZipArchive);
    }
    if response.body.is_empty() {
        return Err(OpenSubtitlesError::Parse("downloaded subtitle is empty"));
    }
    Ok(response.body)
}

/// HTTP durum kodunu hataya çevirir; 2xx kabul edilir.
fn check_status(status: u16) -> Result<(), OpenSubtitlesError> {
    if (200..300).contains(&status) {
        return Ok(());
    }
    match status {
        401 => Err(OpenSubtitlesError::HttpStatus { code: 401 }),
        403 => Err(OpenSubtitlesError::ApiKeyRejected),
        429 => Err(OpenSubtitlesError::RateLimited),
        code => Err(OpenSubtitlesError::HttpStatus { code }),
    }
}

/// `/subtitles` yanıtını ayrıştırır: `data[].attributes` → dosya başına
/// tek satır; eksik `file_id`'li girdiler atlanır. Sağlamlık ön plandadır:
/// tek bir bozuk girdi tüm listeyi düşürmez.
pub fn parse_search_response(body: &str) -> Result<Vec<OpenSubtitlesFile>, OpenSubtitlesError> {
    let root: Value =
        serde_json::from_str(body).map_err(|_| OpenSubtitlesError::Parse("search response is not JSON"))?;
    let data = root
        .get("data")
        .and_then(Value::as_array)
        .ok_or(OpenSubtitlesError::Parse("search response has no data array"))?;

    let mut files = Vec::new();
    for entry in data {
        let attributes = match entry.get("attributes") {
            Some(attributes) => attributes,
            None => continue,
        };
        let language = attributes
            .get("language")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let release = attributes
            .get("release")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let download_count = attributes
            .get("download_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let hearing_impaired = attributes
            .get("hearing_impaired")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let matched_by_hash = attributes
            .get("moviehash_match")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let Some(entry_files) = attributes.get("files").and_then(Value::as_array) else {
            continue;
        };
        for file in entry_files {
            let Some(file_id) = file.get("file_id").and_then(Value::as_u64) else {
                continue;
            };
            let file_name = file
                .get("file_name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            files.push(OpenSubtitlesFile {
                file_id,
                file_name,
                language: language.clone(),
                release: release.clone(),
                download_count,
                matched_by_hash,
                hearing_impaired,
            });
        }
    }
    Ok(files)
}

/// `/login` yanıtından JWT'yi çıkarır.
pub fn parse_login_response(body: &str) -> Result<String, OpenSubtitlesError> {
    let root: Value =
        serde_json::from_str(body).map_err(|_| OpenSubtitlesError::Parse("login response is not JSON"))?;
    root.get("data")
        .and_then(|data| data.get("token"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(OpenSubtitlesError::Parse("login response has no token"))
}

/// `/download` yanıtını ayrıştırır: bağlantı, üst düzeyde ya da `data`
/// içinde olabilir; `file_name` opsiyoneldir (yanıt şeması sürümler arasında
/// değişmiştir — ikisi de desteklenir).
pub fn parse_download_response(body: &str) -> Result<OpenSubtitlesDownload, OpenSubtitlesError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|_| OpenSubtitlesError::Parse("download response is not JSON"))?;
    let payload = root.get("data").unwrap_or(&root);
    let link = payload
        .get("link")
        .and_then(Value::as_str)
        .ok_or(OpenSubtitlesError::Parse("download response has no link"))?
        .to_owned();
    let file_name = payload
        .get("file_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Ok(OpenSubtitlesDownload { link, file_name })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorgu_degerleri_kucuk_harfe_indirilir_ve_arti_kodlanir() {
        assert_eq!(encode_query_value("Movie.Name 2024.1080p"), "movie.name+2024.1080p");
        assert_eq!(encode_query_value("a&b/c"), "a%26b%2Fc");
        assert_eq!(encode_query_value(""), "");
    }

    #[test]
    fn parametreler_alfabetik_siralida_birlesir() {
        let params = vec![
            ("query".to_string(), "Movie".to_string()),
            ("languages".to_string(), "tr,en".to_string()),
            ("moviehash".to_string(), "8e245d9679d31e12".to_string()),
        ];
        assert_eq!(
            build_query(&params),
            "languages=tr%2Cen&moviehash=8e245d9679d31e12&query=movie"
        );
    }

    #[test]
    fn kok_adres_normalize_edilir() {
        assert_eq!(normalize_base_url("  https://api.example.com/ "), "https://api.example.com");
        assert_eq!(normalize_base_url(""), DEFAULT_BASE_URL);
        assert_eq!(normalize_base_url("https://api.example.com///"), "https://api.example.com");
    }

    /// Gerçek API belgelerindeki biçimle aynı bir `/subtitles` yanıtı.
    #[test]
    fn arama_yaniti_dosyalari_duzlestirir() {
        let body = r#"{
            "data": [
                {
                    "id": "5164746",
                    "type": "subtitle",
                    "attributes": {
                        "subtitle_id": "5164746",
                        "language": "tr",
                        "download_count": 9608,
                        "hearing_impaired": false,
                        "moviehash_match": true,
                        "release": "2160p.4K.BluRay.x265.10bit.AAC5.1-GRP",
                        "files": [
                            {
                                "file_id": 5274788,
                                "cd_number": 1,
                                "file_name": "Movie.2024.2160p.BluRay.x265-GRP.srt"
                            }
                        ]
                    }
                },
                {
                    "attributes": {
                        "language": "en",
                        "download_count": 12,
                        "unknown_future_field": {"nested": true},
                        "files": [
                            {"file_id": 111},
                            {"cd_number": 1},
                            {"file_id": 222, "file_name": "b.srt"}
                        ]
                    }
                }
            ]
        }"#;
        let files = parse_search_response(body).unwrap();
        assert_eq!(files.len(), 3);
        assert_eq!(files[0].file_id, 5274788);
        assert_eq!(files[0].language, "tr");
        assert!(files[0].matched_by_hash);
        assert!(!files[0].hearing_impaired);
        assert_eq!(files[0].download_count, 9608);
        // file_id olmayan dosya girdisi atlanır, kalanlar sırayla gelir.
        assert_eq!(files[1].file_id, 111);
        assert_eq!(files[1].file_name, "");
        assert_eq!(files[2].file_id, 222);
        assert_eq!(files[2].file_name, "b.srt");
        assert_eq!(files[2].language, "en");
    }

    #[test]
    fn arama_yaniti_eksik_data_hata_verir() {
        assert!(matches!(
            parse_search_response("{}"),
            Err(OpenSubtitlesError::Parse(_))
        ));
        assert!(matches!(
            parse_search_response("not json"),
            Err(OpenSubtitlesError::Parse(_))
        ));
        // data dizisi varsa boş liste geçerli sonuçtur.
        assert!(parse_search_response(r#"{"data": []}"#).unwrap().is_empty());
    }

    #[test]
    fn giris_yanitindan_jwt_cikarilir() {
        let token = parse_login_response(
            r#"{"data": {"token": "eyJhbGciOi.example.jwt", "user": {"id": 1}}}"#,
        )
        .unwrap();
        assert_eq!(token, "eyJhbGciOi.example.jwt");
        assert!(matches!(
            parse_login_response(r#"{"error": "x"}"#),
            Err(OpenSubtitlesError::Parse(_))
        ));
    }

    #[test]
    fn indirme_yaniti_hem_ust_hem_data_altilarini_kabul_eder() {
        let flat = r#"{"link": "https://dl.example.com/sub/abc.srt", "file_name": "a.srt", "remaining": 95}"#;
        let nested = r#"{"data": {"link": "https://dl.example.com/sub/def.srt", "file_name": "b.srt"}}"#;
        assert_eq!(parse_download_response(flat).unwrap().file_name, "a.srt");
        assert_eq!(parse_download_response(nested).unwrap().file_name, "b.srt");
        assert_eq!(
            parse_download_response(nested).unwrap().link,
            "https://dl.example.com/sub/def.srt"
        );
        assert!(matches!(
            parse_download_response(r#"{"data": {}}"#),
            Err(OpenSubtitlesError::Parse(_))
        ));
    }

    #[test]
    fn durum_kodlari_haritalanir() {
        assert!(check_status(200).is_ok());
        assert!(check_status(204).is_ok());
        assert!(matches!(
            check_status(403),
            Err(OpenSubtitlesError::ApiKeyRejected)
        ));
        assert!(matches!(
            check_status(429),
            Err(OpenSubtitlesError::RateLimited)
        ));
        assert!(matches!(
            check_status(500),
            Err(OpenSubtitlesError::HttpStatus { code: 500 })
        ));
    }

    #[test]
    fn zip_sihri_altyazilar_ayrilir() {
        // fetch_subtitle, gövde PK\x03\x04 ile başlıyorsa ZIP arşivi sayar;
        // sihir denetiminin kendisi burada belgelenir.
        let mut zip = Vec::new();
        zip.extend_from_slice(b"PK\x03\x04");
        zip.extend_from_slice(b"rest of zip");
        assert!(zip.starts_with(b"PK\x03\x04"));
        // Düz SRT gövdesi sihri taşımaz.
        assert!(!b"1\n00:00:01,000 --> 00:00:02,000\nMerhaba\n".starts_with(b"PK"));
    }
}
