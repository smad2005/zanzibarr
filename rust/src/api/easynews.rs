//! Easynews web arama API yüzeyi (flutter_rust_bridge) — NNTP motorundan
//! ayrı kod yolu (roadmap #4).
//!
//! Dart, sağlayıcı (NNTP) ayarlarından türettiği Easynews hesap bilgilerini
//! her çağrıda geçici olarak verir; Rust bunları bellek dışına yazmaz.
//! Arama `GET /2.0/search/solr-search/advanced` (JSON, Basic kimlik) ile
//! yapılır; NZB üretimi `POST /2.0/api/dl-nzb` (form gövdesi) ile. İkisinin
//! de saf katmanı [`crate::engine::easynews`]'tadır ve fixture'lerle
//! test edilir; buradaki testler yerel TCP sunucularıyla uçtan uca çalışır.
//!
//! Gizlilik kuralı: `EasynewsConfigDto` `Debug` türetmez; kullanıcı
//! adı/parola hiçbir hata metnine veya log satırına girmez.

use std::time::Duration;

use crate::engine::easynews;
use crate::engine::http;
use crate::engine::newznab;

use super::search::{download_dir_path, sanitize_filename};
use super::streaming::RUNTIME;

/// Dart'ın (sağlayıcı ayarlarından türettiği) Easynews hesap bilgileri.
/// NNTP girişiyle aynıdır: members.easynews.com da bu kimliğe bakar.
#[derive(Clone)]
pub struct EasynewsConfigDto {
    /// Boşsa motor varsayılanı kullanılır (`members.easynews.com`).
    pub base_url: String,
    pub username: String,
    pub password: String,
}

const SEARCH_TIMEOUT: Duration = Duration::from_secs(20);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_SEARCH_BYTES: usize = 8 * 1024 * 1024;
const MAX_NZB_BYTES: usize = 64 * 1024 * 1024;

/// Bir kaynağın arama çıktısı (birleştirme için), motor öğeleriyle.
pub(crate) struct EasynewsOutcome {
    pub items: Vec<newznab::SearchItem>,
    pub total: Option<u64>,
}

/// Motor dosya kaydını genel arama öğesine çevirir: başlık = uzantısız dosya
/// adı (Easynews konu satırları genelde şifreli/uzundur; indexer release
/// adları da uzantısızdır — çapraz kaynak tekilleştirmesi bu yüzden
/// uzantısız karşılaştırır), `nzb_url` = `easynews:` getiri referansı (tam
/// adı taşır), rozetler başlıktan çözümlenir.
fn file_to_search_item(file: easynews::EasynewsFile) -> newznab::SearchItem {
    let display_title = file
        .filename
        .rsplit_once('.')
        .map(|(stem, _)| stem.to_string())
        .unwrap_or_else(|| file.filename.clone());
    let release = newznab::ReleaseInfo::parse(&display_title);
    newznab::SearchItem {
        title: display_title,
        nzb_url: easynews::build_nzb_url(&file.hash, &file.filename, &file.sig),
        info_url: None,
        size_bytes: file.size_bytes,
        published_epoch_secs: file.published_epoch_secs,
        categories: Vec::new(),
        imdb_id: None,
        season: release.season,
        episode: release.episode,
        release,
        source: "easynews".to_string(),
        source_id: String::new(),
    }
}

fn map_http_error(error: http::HttpError) -> String {
    error.to_string()
}

/// Easynews arama: JSON yanıtını ayrıştırıp oynatılabilir dosyaları
/// motor öğelerine çevirir. Uygulama dışı ağ testleri yerel sunucularla
/// yapılır (`api/search.rs::search_sources` testleri üzerinden de kullanılır).
pub(crate) async fn run_search(
    config: &EasynewsConfigDto,
    query: &str,
    limit: u32,
    offset: u32,
) -> Result<EasynewsOutcome, String> {
    let per_page = limit.clamp(1, 100);
    // Uygulama tek sayfa araması yapar; sayfa numarası ofsetten türetilir.
    let page_no = offset / per_page + 1;
    let url = easynews::build_search_url(&config.base_url, query, per_page, page_no);
    let authorization = easynews::authorization_basic(&config.username, &config.password);
    let response = http::http_request(
        "GET",
        &url,
        &[("Authorization", authorization.as_str())],
        &[],
        MAX_SEARCH_BYTES,
        SEARCH_TIMEOUT,
    )
    .await
    .map_err(map_http_error)?;
    check_status(response.status)?;
    let body = String::from_utf8(response.body)
        .map_err(|_| "Easynews response is not UTF-8".to_string())?;
    let page = easynews::parse_search_response(&body).map_err(|error| error.to_string())?;
    Ok(EasynewsOutcome {
        total: page.total,
        items: page.files.into_iter().map(file_to_search_item).collect(),
    })
}

/// Kolayca ayırt edilebilen HTTP durum hataları.
fn check_status(status: u16) -> Result<(), String> {
    if (200..300).contains(&status) {
        return Ok(());
    }
    match status {
        401 => Err("Easynews rejected the credentials (HTTP 401)".to_string()),
        403 => Err("Easynews rejected the request (HTTP 403)".to_string()),
        code => Err(format!("Easynews returned HTTP {code}")),
    }
}

/// Arama sonucunun NZB'sini `dl-nzb` ucundan üretip `download_dir` altına
/// yazar; dosya YOLU döner. `nzb_url`, arama sonucundaki `easynews:` getiri
/// referansıdır (hash + dosya adı + sig bütünü).
///
/// Boş `download_dir`'de sistem temp'i altına düşülür — Android'de Dart
/// uygulama önbellek dizinini verir (issue #3 ile aynı gerekçe).
pub fn easynews_download_nzb(
    config: EasynewsConfigDto,
    nzb_url: String,
    suggested_name: String,
    download_dir: Option<String>,
) -> Result<String, String> {
    let request = easynews::parse_nzb_url(&nzb_url)
        .ok_or("invalid Easynews NZB reference".to_string())?;
    RUNTIME.block_on(async {
        let form = easynews::build_download_form(&request);
        let authorization = easynews::authorization_basic(&config.username, &config.password);
        let url = easynews::nzb_post_url(&config.base_url);
        let response = http::http_request(
            "POST",
            &url,
            &[
                ("Authorization", authorization.as_str()),
                ("Content-Type", "application/x-www-form-urlencoded"),
            ],
            form.as_bytes(),
            MAX_NZB_BYTES,
            DOWNLOAD_TIMEOUT,
        )
        .await
        .map_err(map_http_error)?;
        check_status(response.status)?;
        easynews::validate_nzb_document(&response.body)?;

        let dir = download_dir_path(download_dir);
        std::fs::create_dir_all(&dir)
            .map_err(|error| format!("could not create temp directory: {error}"))?;
        let filename = format!(
            "{}-{}.nzb",
            sanitize_filename(&suggested_name),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0)
        );
        let path = dir.join(filename);
        std::fs::write(&path, response.body)
            .map_err(|error| format!("could not write NZB: {error}"))?;
        Ok(path.to_string_lossy().into_owned())
    })
}

// ---------------------------------------------------------------------------
// Ağsız uçtan uca testler: std TcpListener + hazır yanıtlar
// ---------------------------------------------------------------------------

#[cfg(test)]
pub(crate) mod test_utils {
    use std::io::{Read, Write};
    use std::sync::{Arc, Mutex};

    /// İsteği (başlık + gövde) kaydeden, `response` ile yanıt veren tek
    /// dizilik test sunucusu. Ardıl bağlantıları da kabul eder.
    pub fn spawn_responder(response: &'static str) -> (u16, Arc<Mutex<Vec<u8>>>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let captured: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&captured);
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                let Ok(mut stream) = connection else { break };
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 4096];
                // Başlık sonuna dek oku.
                loop {
                    let n = match stream.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(_) => break,
                    };
                    buffer.extend_from_slice(&chunk[..n]);
                    if buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buffer).to_string();
                        if let Some(length) = content_length(&head) {
                            let body_start = buffer
                                .windows(4)
                                .position(|w| w == b"\r\n\r\n")
                                .unwrap_or_default();
                            if buffer.len() >= body_start + 4 + length {
                                break;
                            }
                            // Gövde eksik: okumaya devam.
                            continue;
                        }
                        break;
                    }
                }
                sink.lock().unwrap().extend_from_slice(&buffer);
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        });
        (port, captured)
    }

    fn content_length(head: &str) -> Option<usize> {
        for line in head.split("\r\n") {
            if let Some((name, value)) = line.split_once(':') {
                if name.trim().eq_ignore_ascii_case("content-length") {
                    return value.trim().parse().ok();
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::test_utils::spawn_responder;

    const GOOD_NZB: &str = "<?xml version=\"1.0\"?><nzb><file subject=\"s\" poster=\"p\" date=\"1\">\
        <groups><group>alt.test</group></groups></file></nzb>";
    const HOLLOW_NZB: &str = "<?xml version=\"1.0\"?><nzb/>";

    fn easynews_config(port: u16) -> EasynewsConfigDto {
        EasynewsConfigDto {
            base_url: format!("http://127.0.0.1:{port}"),
            username: "kullanici".to_string(),
            password: "TESTPASS123".to_string(),
        }
    }

    #[test]
    fn dl_nzb_form_ve_kimlik_baslagini_gonderir() {
        let response: &'static str = Box::leak(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{GOOD_NZB}",
                GOOD_NZB.len()
            )
            .into_boxed_str(),
        );
        let (port, captured) = spawn_responder(response);
        let url = easynews::build_nzb_url("hash11", "Movie 2024.mkv", "sigsig");

        let dir = std::env::temp_dir().join(format!(
            "zanzibarr-easynews-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let config = easynews_config(port);
        let path = easynews_download_nzb(
            config,
            url,
            "Movie 2024".to_string(),
            Some(dir.to_string_lossy().into_owned()),
        )
        .unwrap();

        // Dosya yazıldı ve önerilen adı taşıyor.
        assert!(path.ends_with(".nzb"), "{path}");
        assert!(path.starts_with(dir.to_string_lossy().as_ref()), "{path}");
        let written = std::fs::read(&path).unwrap();
        assert!(written.windows(4).any(|w| w == b"<nzb"));
        let _ = std::fs::remove_dir_all(&dir);

        // İstek: POST, doğru yol, Basic kimlik ve kodlanmış form alanı.
        let request = String::from_utf8_lossy(&captured.lock().unwrap()).to_string();
        assert!(
            request.starts_with("POST /2.0/api/dl-nzb HTTP/1.1\r\n"),
            "{request}"
        );
        assert!(request.contains("Content-Type: application/x-www-form-urlencoded"));
        // Basic base64("kullanici:TESTPASS123") — bağımsız üretildi.
        let expected = easynews::authorization_basic("kullanici", "TESTPASS123");
        assert!(request.contains(&format!("Authorization: {expected}")));
        assert!(request.contains("autoNZB=1&0%26sig%3Dsigsig=hash11%7C"));
        // b64("Movie 2024") + b64("mkv") ikilisi.
        assert!(request.contains("TW92aWUgMjAyNA%3D%3D%3AbWt2"));
    }

    #[test]
    fn dl_nzb_bos_iskelet_hata_verir() {
        let response: &'static str = Box::leak(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{HOLLOW_NZB}",
                HOLLOW_NZB.len()
            )
            .into_boxed_str(),
        );
        let (port, _captured) = spawn_responder(response);
        let url = easynews::build_nzb_url("h", "a.mkv", "s");
        let error = easynews_download_nzb(
            easynews_config(port),
            url,
            "a".to_string(),
            None,
        )
        .unwrap_err();
        assert_eq!(
            error,
            "Easynews returned an empty NZB (stale search result)"
        );
    }

    #[test]
    fn dl_nzb_gecersiz_referans_hata_verir() {
        let error = easynews_download_nzb(
            easynews_config(1),
            "https://members.example/get/1".to_string(),
            "a".to_string(),
            None,
        )
        .unwrap_err();
        assert_eq!(error, "invalid Easynews NZB reference");
    }

    #[test]
    fn dl_nzb_kimlik_hatasi_ozel_metinle_tasinir() {
        let (port, _captured) = spawn_responder("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
        let url = easynews::build_nzb_url("h", "a.mkv", "s");
        let error = easynews_download_nzb(
            easynews_config(port),
            url,
            "a".to_string(),
            None,
        )
        .unwrap_err();
        assert_eq!(error, "Easynews rejected the credentials (HTTP 401)");
    }

    #[test]
    fn arama_json_yanitindan_oge_uretir() {
        let json = r#"{"results": 3, "data": [
            {"hash": "h1", "fn": "Movie.2024.2160p.WEB-DL.HEVC-GRP", "extension": ".mkv",
             "size": 16106127360, "timestamp": 1717245600, "type": "VIDEO", "sig": "s1"},
            {"hash": "h2", "fn": "Viruslu.Rip", "extension": ".mkv", "type": "VIDEO",
             "virus": true, "sig": "s"}
        ]}"#;
        let response: &'static str = Box::leak(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                json.len(),
                json
            )
            .into_boxed_str(),
        );
        let (port, _captured) = spawn_responder(response);

        let outcome = RUNTIME
            .block_on(async { run_search(&easynews_config(port), "movie", 50, 0).await })
            .unwrap();
        assert_eq!(outcome.total, Some(3));
        // virus işaretli satır elenir; tek oynatılabilir sonuç kalır.
        assert_eq!(outcome.items.len(), 1);
        let item = &outcome.items[0];
        assert_eq!(item.source, "easynews");
        // Görünen ad uzantısız: indexer release adlarıyla aynı biçimde,
        // çapraz kaynak tekilleştirmesi karşılaştırabilsin diye.
        assert_eq!(item.title, "Movie.2024.2160p.WEB-DL.HEVC-GRP");
        assert!(item.nzb_url.starts_with("easynews:h1|"));
        let badges = item.release.badges();
        assert!(badges.contains(&"2160p".to_string()));
        assert!(badges.contains(&"HEVC".to_string()));
    }

    #[test]
    fn arama_kimlik_hatasi_ozel_metinle_tasinir() {
        let (port, _captured) =
            spawn_responder("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
        let result = RUNTIME
            .block_on(async { run_search(&easynews_config(port), "movie", 50, 0).await });
        let Err(error) = result else {
            panic!("401 hatası bekleniyordu");
        };
        assert_eq!(error, "Easynews rejected the credentials (HTTP 401)");
    }
}
