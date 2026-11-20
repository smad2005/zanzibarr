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
    /// Profil kimliği (çoklu indexer ayarlarından): arama sonuçları
    /// `source_id` olarak bunu geri taşır; Dart NZB indirmede ve caps
    /// sınamasında doğru hesabı bu id'den bulur.
    pub id: String,
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
    /// Indexer kaynaklarında sonucun geldiği profil kimliği
    /// ([`IndexerConfigDto::id`]); Easynews öğelerinde boş dizedir. Dart,
    /// NZB'yi doğru indexer hesabından indirir.
    pub source_id: String,
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
    let mut page = newznab::parse_search_response(&body).map_err(|error| error.to_string())?;
    // Sonuçlar bu hesabın (profil) kimliğiyle etiketlenir: çoklu indexer
    // desteğinde Dart indirme yolunu bu kimlikle seçer.
    for item in &mut page.items {
        item.source_id = config.id.clone();
    }
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
        source_id: item.source_id,
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

/// Çok kaynaklı arama (roadmap #4/#5 + çoklu indexer): birden fazla Newznab
/// hesabı VE Easynews web araması aynı sorguyla, paralel sorgulanır;
/// sonuçlar tekilleştirilip birleştirilir.
///
/// Prowlarr (`http://host:9696/prowlarr/{indexerId}/api`) ve NZBHydra2
/// (`http://host/api`) newznab-uyumlu uç sağladıklarından ayrı bir kod yolu
/// gerekmez: her biri normal bir "indexer" hesabı olarak eklenir; tekilleştirme
/// aynı yayının kopyalarını eler.
///
/// Kaynak kuralları:
/// - `indexers` listesindeki tam yapılandırmalı (URL + anahtar dolu) hesaplar
///   ve kimliği doluysa `easynews` paralel sorgulanır. Hiç kaynak kalmadıysa
///   hata döner (UI "kaynak yok" görünümü).
/// - Kaynakların bazıları hata verirse kalanların sonuçları döner (sessiz
///   kısmi başarı); hiçbiri başarılı değilse ilk hata taşınır.
/// - Aynı release birden fazla kaynakta varsa `dedup_items` ilk kopyayı tutar:
///   indexer hesapları çağrıldıkları sıradadır, Easynews en sonda katılır —
///   listenin başındaki hesap öncelik kabul edilir. Tutulan kopyanın
///   `source`/`source_id` alanları kökenini söyler.
/// - "Toplam" sayısı yalnız tek-kaynak sayfa semantiği taşıdığı durumda döner
///   (tek indexer başarılı + Easynews yok); karmakarışık listelerde gizlenir.
pub fn search_sources(
    indexers: Option<Vec<IndexerConfigDto>>,
    easynews: Option<crate::api::easynews::EasynewsConfigDto>,
    query: String,
    limit: u32,
    offset: u32,
) -> Result<SearchPageDto, String> {
    let mut indexers = indexers.unwrap_or_default();
    indexers.retain(|config| {
        !config.base_url.trim().is_empty() && !config.api_key.trim().is_empty()
    });
    let easynews = easynews.filter(|config| {
        !config.username.trim().is_empty() && !config.password.is_empty()
    });
    if indexers.is_empty() && easynews.is_none() {
        return Err("no search source configured".to_string());
    }

    RUNTIME.block_on(async {
        // Kaynak "yuvaları": indexerlar çağrıldıkları sırada, Easynews en
        // sonda — bu yuva sırası birleştirmede gözetilir (tekilleştirme
        // "ilk tutulur" kuralıyla listenin başındaki hesabı tercih eder).
        let indexer_count = indexers.len();
        let slot_count = indexer_count + usize::from(easynews.is_some());
        let mut outcomes: Vec<Option<Result<SourceOutcome, String>>> = (0..slot_count)
            .map(|_| Option::<Result<SourceOutcome, String>>::None)
            .collect();

        // Eşzamanlı sorgu: her kaynak kendi görevinde koşar; tek birinin ağ
        // gecikmesi toplamayı bloklamaz. JoinSet tamamlanma sırasını
        // denetlemeden döndürür — yuva indeksleri sabitlendiğinden anlam
        // kaybı yok, birleştirme GÖZETİLEN sırayla yapılır.
        let mut set = tokio::task::JoinSet::new();
        for (slot, config) in indexers.into_iter().enumerate() {
            let query = query.clone();
            set.spawn(async move {
                (
                    slot,
                    run_indexer_search(&config, &query, limit, offset).await,
                )
            });
        }
        // Spawn edilen görev 'static olmalı: yapılandırma sahiplenilerek
        // (kopya: üç String) göreve taşınır, dışarıdan ödünç alınmaz.
        if let Some(config) = easynews.clone() {
            let query = query.clone();
            let slot = indexer_count;
            // JoinSet tek çıktı türü ister: Easynews çıktısı burada genel
            // kaynak çıktısına (aynı alanlar) çevrilir.
            set.spawn(async move {
                let outcome =
                    crate::api::easynews::run_search(&config, &query, limit, offset).await;
                (
                    slot,
                    outcome.map(|easynews_outcome| SourceOutcome {
                        items: easynews_outcome.items,
                        total: easynews_outcome.total,
                    }),
                )
            });
        }

        let mut first_error: Option<String> = None;
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok((slot, result)) => outcomes[slot] = Some(result),
                Err(error) => {
                    first_error.get_or_insert(format!("search task failed: {error}"));
                }
            }
        }

        let mut items: Vec<newznab::SearchItem> = Vec::new();
        let mut indexer_ok = 0usize;
        let mut easynews_ok = false;
        let mut easynews_total: Option<u64> = None;
        let mut single_indexer_total: Option<u64> = None;
        for (slot, outcome) in outcomes.into_iter().enumerate() {
            match outcome {
                Some(Ok(outcome)) => {
                    if slot < indexer_count {
                        indexer_ok += 1;
                        single_indexer_total = outcome.total;
                    } else {
                        easynews_ok = true;
                        easynews_total = outcome.total;
                    }
                    items.extend(outcome.items);
                }
                Some(Err(error)) => {
                    first_error.get_or_insert(error);
                }
                None => {}
            }
        }

        if indexer_ok == 0 && !easynews_ok {
            return Err(first_error.unwrap_or_else(|| "search failed".to_string()));
        }

        // "Toplam" yalnız tek-kaynak sayfa semantiğinde anlam taşır: tek
        // indexer (Easynews yok) onun toplamı; yalnız Easynews başarılıysa
        // onun toplamı; karma veya çoklu indexer listelerinde gizlenir.
        let total = match (indexer_ok, easynews_ok) {
            (0, true) => easynews_total,
            (1, false) => single_indexer_total,
            _ => None,
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
            id: format!("idx{port}").to_string(),
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

        /// İkinci indexer yanıtı: aynı release kopyası + benzersiz bir sonuç.
    /// Çoklu indexer dedup'ı iki durumda birlikte sınar.
    const MERGE_RSS2: &str = r#"<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Idx2</title>
    <newznab:response offset="0" total="7" xmlns:newznab="http://x"/>
    <item>
      <title>Movie.2024.2160p.WEB-DL.HEVC-GRP</title>
      <link>http://127.0.0.1/api?t=get&amp;id=dup</link>
      <newznab:attr name="size" value="16106127360" xmlns:newznab="http://x"/>
    </item>
    <item>
      <title>Dizi.S01E01.1080p.WEB-DL-GRP</title>
      <link>http://127.0.0.1/api?t=get&amp;id=d2</link>
      <newznab:attr name="size" value="734003200" xmlns:newznab="http://x"/>
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
            Some(vec![local_indexer_config(indexer_port)]),
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
            Some(vec![IndexerConfigDto {
                id: "bos".to_string(),
                base_url: "http://127.0.0.1:1".to_string(),
                api_key: String::new(),
            }]),
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
            Some(vec![local_indexer_config(indexer_port)]),
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
            Some(vec![local_indexer_config(dead_indexer)]),
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

    #[test]
    fn search_sources_coklu_indexer_etiketleriyle_birlestirir() {
        let (first_port, _c1) = spawn_responder(http_wrap(MERGE_RSS));
        let (second_port, _c2) = spawn_responder(http_wrap(MERGE_RSS2));

        let page = search_sources(
            Some(vec![
                local_indexer_config(first_port),
                local_indexer_config(second_port),
            ]),
            None,
            "movie".to_string(),
            50,
            0,
        )
        .unwrap();

        // Aynı release iki hesapta da var: listede önce gelen (ilk hesap)
        // kopyası tutulur; benzersiz sonuç birleşir. Her öğe kendi hesabının
        // profil kimliğini (`source_id`) taşır.
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "Movie.2024.2160p.WEB-DL.HEVC-GRP");
        assert_eq!(page.items[0].source_id, format!("idx{first_port}"));
        assert_eq!(page.items[1].title, "Dizi.S01E01.1080p.WEB-DL-GRP");
        assert_eq!(page.items[1].source_id, format!("idx{second_port}"));
        // Çoklu indexerda "toplam" sayfa semantiği taşımaz: gizlenir.
        assert_eq!(page.total, None);
    }

    #[test]
    fn search_sources_indexerlerden_biri_duserse_kalan_doner() {
        let (dead_port, _c1) =
            spawn_responder("HTTP/1.1 500 Broken\r\nContent-Length: 0\r\n\r\n");
        let (alive_port, _c2) = spawn_responder(http_wrap(MERGE_RSS));

        let page = search_sources(
            Some(vec![
                local_indexer_config(dead_port),
                local_indexer_config(alive_port),
            ]),
            None,
            "movie".to_string(),
            50,
            0,
        )
        .unwrap();

        // Düşen hesap sessizce atlanır; ayakta kalanın sonuçları döner.
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].source_id, format!("idx{alive_port}"));
        // Tek indexer ayakta kaldı: onun "toplam"ı sayfa semantiği taşır.
        assert_eq!(page.total, Some(1));
    }
}
