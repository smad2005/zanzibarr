//! Newznab indexer arama API'si (flutter_rust_bridge).
//!
//! Dart, güvenli depodan okuduğu indexer adresini ve API anahtarını verir;
//! Rust caps keşfi, metin araması ve NZB indirme işlerini yürütür. İndirilen
//! NZB geçici dizine yazılır ve yolu döndürülür — oynatma mevcut
//! [`crate::api::streaming`] akışıyla devam eder.
//!
//! Gizlilik kuralı: API anahtarı ve anahtar taşıyan URL'ler yalnızca bellek
//! içinde akar; hiçbir DTO `Debug` türetmez, hata metinleri URL/gövde
//! içermez.

use std::time::Duration;

use crate::engine::http::{self, HttpError};
use crate::engine::newznab::{self, MediaKind};

use super::streaming::RUNTIME;

const SEARCH_TIMEOUT: Duration = Duration::from_secs(20);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_SEARCH_BYTES: usize = 8 * 1024 * 1024;
const MAX_NZB_BYTES: usize = 64 * 1024 * 1024;

/// Dart'tan gelen indexer yapılandırması.
pub struct IndexerConfigDto {
    /// Ör. `https://miatrix.example` (sonunda `/api` olabilir ya da olmayabilir).
    pub base_url: String,
    pub api_key: String,
}

/// `?t=caps` özeti; UI hangi arama türlerinin açık olduğunu buna göre gösterir.
pub struct IndexerCapsDto {
    pub server_title: Option<String>,
    pub search_available: bool,
    pub tv_search_available: bool,
    pub movie_search_available: bool,
}

/// Tek arama sonucu. `nzb_url` API anahtarı içerebilir; loglanmamalıdır.
pub struct SearchItemDto {
    pub title: String,
    pub nzb_url: String,
    pub info_url: Option<String>,
    pub size_bytes: Option<u64>,
    pub published_epoch_secs: Option<i64>,
    /// Rust tarafında hazırlanan görüntü rozetleri: ["2160p","HEVC","DV",…].
    pub badges: Vec<String>,
    /// "movie" | "tv" | "other" — UI simgesi için.
    pub media_kind: String,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub year: Option<u32>,
    pub group: Option<String>,
    /// Sonucun geldiği kaynak: "indexer" (Newznab) | "easynews".
    pub source: String,
}

pub struct SearchPageDto {
    pub total: Option<u64>,
    pub items: Vec<SearchItemDto>,
}

fn map_http_error(error: HttpError) -> String {
    error.to_string()
}

async fn fetch_checked_async(
    url: &str,
    max_bytes: usize,
    timeout: Duration,
) -> Result<String, String> {
    let response = http::http_get(url, max_bytes, timeout)
        .await
        .map_err(map_http_error)?;
    if !(200..300).contains(&response.status) {
        return Err(format!("indexer returned HTTP {}", response.status));
    }
    String::from_utf8(response.body).map_err(|_| "indexer response is not UTF-8".to_string())
}

fn fetch_checked(url: &str, max_bytes: usize, timeout: Duration) -> Result<String, String> {
    RUNTIME.block_on(fetch_checked_async(url, max_bytes, timeout))
}

/// Bir kaynağın arama çıktısı (birleştirme için), motor öğeleriyle.
pub(crate) struct SourceOutcome {
    pub items: Vec<newznab::SearchItem>,
    pub total: Option<u64>,
}

/// Newznab aramasının ağ + ayrıştırma kısmı; hem tek kaynak API'si
/// ([`newznab_search`]) hem çok kaynak birleştirmesi
/// ([`search_sources`]) bunu çağırır.
pub(crate) async fn run_indexer_search(
    config: &IndexerConfigDto,
    query: &str,
    limit: u32,
    offset: u32,
) -> Result<SourceOutcome, String> {
    let limit = limit.clamp(1, 100).to_string();
    let offset = offset.to_string();
    let url = newznab::build_api_url(
        &config.base_url,
        &[
            ("t", "search"),
            ("q", query),
            ("apikey", &config.api_key),
            ("limit", &limit),
            ("offset", &offset),
        ],
    );
    let body = fetch_checked_async(&url, MAX_SEARCH_BYTES, SEARCH_TIMEOUT).await?;
    let page = newznab::parse_search_response(&body).map_err(|error| error.to_string())?;
    Ok(SourceOutcome {
        items: page.items,
        total: page.total,
    })
}

/// Motor arama öğesini DTO'ya çevirir (rozetler ve tür burada üretilir).
fn item_to_dto(item: newznab::SearchItem) -> SearchItemDto {
    let kind = item.release.media_kind(&item.categories, item.season);
    let badges = item.release.badges();
    let year = item.release.year;
    let group = item.release.group.clone();
    let (season, episode) = (item.season, item.episode);
    SearchItemDto {
        title: item.title,
        nzb_url: item.nzb_url,
        info_url: item.info_url,
        size_bytes: item.size_bytes,
        published_epoch_secs: item.published_epoch_secs,
        badges,
        media_kind: match kind {
            MediaKind::Movie => "movie",
            MediaKind::Tv => "tv",
            MediaKind::Other => "other",
        }
        .to_string(),
        season,
        episode,
        year,
        group,
        source: item.source,
    }
}

/// Indexer'ın yeteneklerini sorgular (`?t=caps`). Bağlantı ve API anahtarı
/// doğrulaması için de kullanılır.
pub fn newznab_check_caps(config: IndexerConfigDto) -> Result<IndexerCapsDto, String> {
    let url = newznab::build_api_url(
        &config.base_url,
        &[("t", "caps"), ("apikey", &config.api_key)],
    );
    let body = fetch_checked(&url, MAX_SEARCH_BYTES, SEARCH_TIMEOUT)?;
    let caps = newznab::parse_caps(&body).map_err(|error| error.to_string())?;
    Ok(IndexerCapsDto {
        server_title: caps.server_title,
        search_available: caps.search.as_ref().is_some_and(|s| s.available),
        tv_search_available: caps.tv_search.as_ref().is_some_and(|s| s.available),
        movie_search_available: caps.movie_search.as_ref().is_some_and(|s| s.available),
    })
}

/// Metin araması yapar (`?t=search&q=…`). Sonuçlar release rozetleriyle
/// birlikte döner; liste sırası indexer'ın sırasıdır.
pub fn newznab_search(
    config: IndexerConfigDto,
    query: String,
    limit: u32,
    offset: u32,
) -> Result<SearchPageDto, String> {
    let outcome = RUNTIME.block_on(run_indexer_search(&config, &query, limit, offset))?;
    Ok(SearchPageDto {
        total: outcome.total,
        items: outcome.items.into_iter().map(item_to_dto).collect(),
    })
}

/// Cok kaynakli arama (roadmap #4/#5): Newznab indexer VE Easynews web
/// aramasi ayni sorguyla, paralel sorgulanir; sonuclar tekillestirilip
/// birlestirilir.
///
/// Kaynak kurallari:
/// - `indexer` yalniz URL + anahtar doluysa sorgulanir; `easynews` yalniz
///   kullanici adi + parola doluysa. `None` veya eksik yapilandirma o
///   kaynagi aramaya katmaz.
/// - Iki kaynak da devre disiysa hata doner (UI "kaynak yok" gorunumu).
/// - Kaynaklardan biri hata verirse digerinin sonuclari donebilir (sessiz
///   kismi basari); hicbiri basarili degilse ilk hata tasinir.
/// - Ayni release iki kaynakta da varsa `dedup_items` ilk (indexer)
///   kopyasini tutar; `source` alani tutulan kopyanin kokenini soyler.
/// - "Toplam" sayisi yalniz tek kaynagin sonuclari anlamlysa doner; karma
///   listede `None`dir (UI gizler).
pub fn search_sources(
    indexer: Option<IndexerConfigDto>,
    easynews: Option<crate::api::easynews::EasynewsConfigDto>,
    query: String,
    limit: u32,
    offset: u32,
) -> Result<SearchPageDto, String> {
    let indexer = indexer.filter(|config| {
        !config.base_url.trim().is_empty() && !config.api_key.trim().is_empty()
    });
    let easynews = easynews.filter(|config| {
        !config.username.trim().is_empty() && !config.password.is_empty()
    });
    if indexer.is_none() && easynews.is_none() {
        return Err("no search source configured".to_string());
    }

    RUNTIME.block_on(async {
        // Iki kaynak paralel sorgulanir; tek birinin ag gecikmesi tum
        // aramayi bloklamaz.
        let (indexer_result, easynews_result) = tokio::join!(
            async {
                match indexer.as_ref() {
                    Some(config) => Some(
                        run_indexer_search(config, &query, limit, offset).await,
                    ),
                    None => None,
                }
            },
            async {
                match easynews.as_ref() {
                    Some(config) => Some(
                        crate::api::easynews::run_search(config, &query, limit, offset).await,
                    ),
                    None => None,
                }
            }
        );

        // Indexer ogeleri once: tekillestirme "ilk tutulur" kuraliyla indexer
        // kopyasini tercih eder (onn kontrol + NZB akisi zaten indexer uzerinden
        // kanitlanmistir).
        let mut items: Vec<newznab::SearchItem> = Vec::new();
        let mut indexer_total: Option<u64> = None;
        let mut easynews_total: Option<u64> = None;
        let mut sources_ok = 0usize;
        let mut first_error: Option<String> = None;

        // "Toplam" sayısı tek-kaynak sayfa semantiği taşır: tek indexer
        // açıkken (easynews başarısız/devre dışı) onun toplamı, tek
        // easynews kaynaklıyken onun toplamı, karma listede ise gizlenir.
        // (indexer_result'a değer taşımadan ÖNCE bakılır.)
        let indexer_attempted = indexer_result.is_some();
        let easynews_ok = matches!(easynews_result, Some(Ok(_)));
        match indexer_result {
            Some(Ok(outcome)) => {
                sources_ok += 1;
                indexer_total = outcome.total;
                items.extend(outcome.items);
            }
            Some(Err(error)) => {
                first_error.get_or_insert(error);
            }
            None => {}
        }
        match easynews_result {
            Some(Ok(outcome)) => {
                sources_ok += 1;
                easynews_total = outcome.total;
                items.extend(outcome.items);
            }
            Some(Err(error)) => {
                first_error.get_or_insert(error);
            }
            None => {}
        }

        if sources_ok == 0 {
            return Err(first_error.unwrap_or_else(|| "search failed".to_string()));
        }

        let total = match (indexer_attempted, easynews_ok) {
            (true, false) => indexer_total,
            (true, true) => None,
            (false, _) => easynews_total,
        };
        let kept = newznab::dedup_items(items);
        Ok(SearchPageDto {
            total,
            items: kept.into_iter().map(item_to_dto).collect(),
        })
    })
}

/// Arama sonucunun NZB'sini geçici dizine indirir ve dosya yolunu döndürür.
/// Yanıtın gerçekten NZB olduğu kök öğe kokusuyla doğrulanır; HTML hata
/// sayfaları oynatıcıya kadar ilerleyemez.
///
/// `download_dir`: Dart tarafının `path_provider` ile verdiği uygulama önbellek
/// dizini. Android'de `std::env::temp_dir()` kullanılamaz (`TMPDIR` yok, `/tmp`
/// yazılamaz — Android TV raporu); None/boş ise masaüstünde çalışan eski
/// davranışa (sistem temp + `zanzibarr-nzb`) düşülür.
pub fn newznab_download_nzb(
    config: IndexerConfigDto,
    nzb_url: String,
    suggested_name: String,
    download_dir: Option<String>,
) -> Result<String, String> {
    // Bazı indexer'lar feed'deki bağlantıya anahtarı gömmez.
    let url = if nzb_url.contains("apikey=") || config.api_key.is_empty() {
        nzb_url
    } else {
        let separator = if nzb_url.contains('?') { '&' } else { '?' };
        format!(
            "{nzb_url}{separator}apikey={}",
            newznab::percent_encode(&config.api_key)
        )
    };

    let body = fetch_checked(&url, MAX_NZB_BYTES, DOWNLOAD_TIMEOUT)?;
    let looks_nzb = body
        .get(..4096)
        .is_some_and(|head| head.contains("<nzb") || head.contains("<!DOCTYPE nzb"));
    if !looks_nzb {
        return Err("downloaded content is not an NZB".to_string());
    }

    let dir = download_dir_path(download_dir);
    std::fs::create_dir_all(&dir).map_err(|error| format!("could not create temp directory: {error}"))?;
    let filename = format!(
        "{}-{}.nzb",
        sanitize_filename(&suggested_name),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );
    let path = dir.join(filename);
    std::fs::write(&path, body).map_err(|error| format!("could not write NZB: {error}"))?;
    Ok(path.to_string_lossy().into_owned())
}

/// NZB indirme dizinini seçer: Dart'ın verdiği geçerli yol öncelikli; yoksa
/// sistem temp'i altında `zanzibarr-nzb` (masaüstü/CLI davranışı).
pub(crate) fn download_dir_path(download_dir: Option<String>) -> std::path::PathBuf {
    download_dir
        .filter(|dir| !dir.trim().is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("zanzibarr-nzb"))
}

/// Dosya adını platform-güvenli karakterlere indirger (en çok 60 karakter).
pub(crate) fn sanitize_filename(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '-' | '_' | '.') {
                c
            } else {
                '_'
            }
        })
        .take(60)
        .collect();
    let sanitized = sanitized.trim_matches(['.', '_']).to_string();
    if sanitized.is_empty() {
        "arama-sonucu".to_string()
    } else {
        sanitized
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dosya_adi_temizligi() {
        assert_eq!(sanitize_filename("Fight.Club.1999-GROUP"), "Fight.Club.1999-GROUP");
        assert_eq!(sanitize_filename("a/b\\c:d*e?f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j");
        assert_eq!(sanitize_filename("   "), "arama-sonucu");
        assert_eq!(sanitize_filename("...___"), "arama-sonucu");
        assert_eq!(sanitize_filename(&"x".repeat(200)).len(), 60);
    }

    #[test]
    fn indirme_dizini_secimi() {
        // Dart'ın verdiği dizin aynen kullanılır.
        assert_eq!(
            download_dir_path(Some("/data/user/0/app/cache".into())),
            std::path::PathBuf::from("/data/user/0/app/cache")
        );
        // Boş/boşluklu dizin ve None sistem temp'ine düşer.
        let fallback = std::env::temp_dir().join("zanzibarr-nzb");
        assert_eq!(download_dir_path(None), fallback);
        assert_eq!(download_dir_path(Some("   ".into())), fallback);
    }

    // ---- search_sources: cok kaynakli arama (yerel sunucularla) ----------

    use crate::api::easynews::test_utils::spawn_responder;

    fn http_wrap(body: &'static str) -> &'static str {
        Box::leak(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                body.len(),
                body
            )
            .into_boxed_str(),
        )
    }

    fn local_indexer_config(port: u16) -> IndexerConfigDto {
        IndexerConfigDto {
            base_url: format!("http://127.0.0.1:{port}"),
            api_key: "anahtar".to_string(),
        }
    }

    fn local_easynews_config(port: u16) -> crate::api::easynews::EasynewsConfigDto {
        crate::api::easynews::EasynewsConfigDto {
            base_url: format!("http://127.0.0.1:{port}"),
            username: "kullanici".to_string(),
            password: "TESTPASS123".to_string(),
        }
    }

    const MERGE_RSS: &str = r#"<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Idx</title>
    <newznab:response offset="0" total="1" xmlns:newznab="http://x"/>
    <item>
      <title>Movie.2024.2160p.WEB-DL.HEVC-GRP</title>
      <link>http://127.0.0.1/api?t=get&amp;id=m1</link>
      <newznab:attr name="size" value="16106127360" xmlns:newznab="http://x"/>
    </item>
  </channel>
</rss>"#;

    const MERGE_JSON: &str = r#"{"results": 2, "data": [
        {"hash": "e1", "fn": "Movie.2024.2160p.WEB-DL.HEVC-GRP", "extension": ".mkv",
         "size": 16106127360, "type": "VIDEO", "sig": "sig-bir"},
        {"hash": "e2", "fn": "Dizi.S01E01.1080p.WEB-DL-GRP", "extension": ".mkv",
         "size": 734003200, "type": "VIDEO", "sig": "sig-iki"}
    ]}"#;

    #[test]
    fn search_sources_birlestirir_ve_tekillestirir() {
        let (indexer_port, _c1) = spawn_responder(http_wrap(MERGE_RSS));
        let (easynews_port, _c2) = spawn_responder(http_wrap(MERGE_JSON));

        let page = search_sources(
            Some(local_indexer_config(indexer_port)),
            Some(local_easynews_config(easynews_port)),
            "movie".to_string(),
            50,
            0,
        )
        .unwrap();

        // Ayni release iki kaynakta da var: indexer kopyasi tutulur, easynews
        // kopyasi elenir; easynews'in benzersiz sonucu eklenir.
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "Movie.2024.2160p.WEB-DL.HEVC-GRP");
        assert_eq!(page.items[0].source, "indexer");
        assert_eq!(page.items[1].title, "Dizi.S01E01.1080p.WEB-DL-GRP");
        assert_eq!(page.items[1].source, "easynews");
        assert!(page.items[1].nzb_url.starts_with("easynews:e2|"));
        // Karma listede "toplam" gizlenir.
        assert_eq!(page.total, None);
    }

    #[test]
    fn search_sources_yalniz_easynews_donustoplam_tasir() {
        let (easynews_port, _c2) = spawn_responder(http_wrap(MERGE_JSON));
        let page = search_sources(
            None,
            Some(local_easynews_config(easynews_port)),
            "dizi".to_string(),
            50,
            0,
        )
        .unwrap();
        assert_eq!(page.items.len(), 2);
        assert!(page.items.iter().all(|item| item.source == "easynews"));
        assert_eq!(page.total, Some(2));
    }

    #[test]
    fn search_sources_eksik_yapilandirma_kaynagi_dislar() {
        let (easynews_port, _c2) = spawn_responder(http_wrap(MERGE_JSON));
        // Bos api anahtari: indexer katilmaz, yalniz easynews sorgulanir.
        let page = search_sources(
            Some(IndexerConfigDto {
                base_url: "http://127.0.0.1:1".to_string(),
                api_key: String::new(),
            }),
            Some(local_easynews_config(easynews_port)),
            "dizi".to_string(),
            50,
            0,
        )
        .unwrap();
        assert!(page.items.iter().all(|item| item.source == "easynews"));
    }

    #[test]
    fn search_sources_kismi_hata_diger_kaynaktan_doner() {
        let (indexer_port, _c1) =
            spawn_responder("HTTP/1.1 500 Broken\r\nContent-Length: 0\r\n\r\n");
        let (easynews_port, _c2) = spawn_responder(http_wrap(MERGE_JSON));
        let page = search_sources(
            Some(local_indexer_config(indexer_port)),
            Some(local_easynews_config(easynews_port)),
            "movie".to_string(),
            50,
            0,
        )
        .unwrap();
        assert!(!page.items.is_empty());
        assert!(page.items.iter().all(|item| item.source == "easynews"));
    }

    #[test]
    fn search_sources_tam_hata_veya_kaynak_yok() {
        let result = search_sources(None, None, "x".to_string(), 50, 0);
        let Err(error) = result else {
            panic!("kaynak yok hatasi bekleniyordu");
        };
        assert_eq!(error, "no search source configured");

        let (dead_indexer, _c1) =
            spawn_responder("HTTP/1.1 500 Broken\r\nContent-Length: 0\r\n\r\n");
        let (dead_easynews, _c2) =
            spawn_responder("HTTP/1.1 500 Broken\r\nContent-Length: 0\r\n\r\n");
        let result = search_sources(
            Some(local_indexer_config(dead_indexer)),
            Some(local_easynews_config(dead_easynews)),
            "x".to_string(),
            50,
            0,
        );
        let Err(error) = result else {
            panic!("durum hatasi bekleniyordu");
        };
        assert!(error.contains("500"), "beklenen durum hatasi: {error}");
    }
}

