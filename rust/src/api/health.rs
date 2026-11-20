//! NZB sağlık ön kontrolü API'si (flutter_rust_bridge).
//!
//! Dart arama ekranı, bir sonucun NZB'sini indirir ve bu çağrıyla yayın
//! oynatılabilir mi rozeti üretir. İki katman yürütülür:
//! 1. NZB ayrıştırılıp yapısal analiz (cilt sürekliliği, listing eksiği,
//!    PAR2 kapasitesi) ağsız hesaplanır.
//! 2. Planlanan segment örneklemleri sunucuya `STAT` ile sorulur — article
//!    gövdeleri asla indirilmez (tembel akış kuralı, §AGENTS 4.3).
//!
//! Eşzamanlı bağlantı bütçesi kasıtlı olarak küçüktür: arama listesinde
//! çok NZB peş peşe denetlenir; sağlayıcıya aynı anda en fazla
//! [HEALTH_POOL_CONNECTIONS] bağlantı açılır.

use std::time::Duration;

use tokio::time::Instant;

use crate::engine::health::{
    classify_health, drain_stat_plan, plan_health_samples, HealthReport,
};
use crate::engine::nntp::{ProviderConfig, TlsNntpConnector};

use super::streaming::{read_nzb, ProviderConfigDto, RUNTIME};

/// Ön kontrolün sağlayıcıya açacağı en fazla eşzamanlı bağlantı sayısı.
const HEALTH_POOL_CONNECTIONS: usize = 3;
/// Tek bir STAT sorgusunun üst sınırı.
const STAT_TIMEOUT: Duration = Duration::from_secs(15);
/// Tüm örneklemlerin (plan + ağ) toplam tavanı; arama listesinde denetim
/// sonsuz beklemeye dönüşmemeli.
const HEALTH_DEADLINE: Duration = Duration::from_secs(30);

/// Ön kontrol rozeti: `good` | `repairable` | `risky` | `missing`.
pub struct NzbHealthDto {
    pub status: String,
    /// Yanıt alan (mevcut + eksik) segment örneği sayısı.
    pub sampled_articles: u32,
    /// Örneklemde sunucuda bulunamayan segment sayısı.
    pub missing_articles: u32,
    /// Ağ/protokol hatası veren, karara katılmayan örnek sayısı.
    pub errored_samples: u32,
    /// Yapısal eksikler + dışlanan sunucu eksiği toplam tahmini (article).
    pub estimated_missing_articles: u64,
    /// Denetlenen hedef dosyaların listelenen segment sayısı.
    pub target_article_count: u64,
    pub target_file_count: u32,
    /// RAR/7z/obfuske cilt sayısı (doğrudan videoda 0).
    pub archive_volumes: u32,
    /// NZB listesinde eksik cilt sayısı.
    pub volume_gaps: u32,
    /// Birincil hedefin ilk segmenti sunucuda yok.
    pub head_missing: bool,
    pub par2_present: bool,
    /// `volN+M` adlarından toplanan onarım bloğu toplamı.
    pub par2_recovery_blocks: u32,
}

impl From<HealthReport> for NzbHealthDto {
    fn from(report: HealthReport) -> Self {
        NzbHealthDto {
            status: report.status.as_str().to_string(),
            sampled_articles: report.sampled_articles,
            missing_articles: report.missing_articles,
            errored_samples: report.errored_samples,
            estimated_missing_articles: report.estimated_missing_articles,
            target_article_count: report.target_article_count,
            target_file_count: report.target_file_count,
            archive_volumes: report.archive_volumes,
            volume_gaps: report.volume_gaps,
            head_missing: report.head_missing,
            par2_present: report.par2_present,
            par2_recovery_blocks: report.par2_recovery_blocks,
        }
    }
}

/// NZB'nin oynatılabilirliğini oynatmadan önce denetler.
///
/// Yapısal analiz + segment örnekleme `STAT` sonuçları birleşip bir
/// [`NzbHealthDto`] rozetine dönüşür. Article gövdeleri indirilmez;
/// sunucu ile tek satırlık durum yanıtları döner. Sağlayıcıya erişilemiyorsa
/// (tüm örneklemler ağ hatası) açık hata döner; Dart tarafı rozeti gizler.
pub fn check_nzb_health(
    config: ProviderConfigDto,
    nzb_path: String,
) -> Result<NzbHealthDto, String> {
    let provider = ProviderConfig::from(config);
    RUNTIME.block_on(async move {
        let nzb = RUNTIME
            .spawn_blocking(move || read_nzb(&nzb_path))
            .await
            .map_err(|error| format!("NZB health task failed to complete: {error}"))??;

        let plan = plan_health_samples(&nzb);
        if plan.samples.is_empty() {
            // Ağ gerekmeyen karar: hedefsiz NZB vb.
            return Ok(classify_health(&plan, &[]).into());
        }

        // Arama taraması kibar olsun: sağlayıcı limitinden bağımsız, dar
        // bir havuzla örnekleme yapılır. Aktif oynatma oturumuyla çakışsa
        // bile toplam eşzamanlılık sağlayıcı limitine takılmaz.
        let pool_config = ProviderConfig {
            max_connections: provider
                .max_connections
                .clamp(1, HEALTH_POOL_CONNECTIONS),
            ..provider
        };
        let pool = TlsNntpConnector::new(pool_config).into_pool();

        let stat = {
            let pool = std::sync::Arc::clone(&pool);
            move |message_id: String| {
                let pool = std::sync::Arc::clone(&pool);
                async move {
                    let Ok(mut conn) = pool.checkout().await else {
                        return None;
                    };
                    // Zaman aşımı/protokol hatası: örnek "bilinmiyor" kalır;
                    // eksik sayılmaz, karara katılmaz. Zaman aşımında soket
                    // yanıtın ortasında kalabilir; mark_reusable atlanır.
                    let present = match tokio::time::timeout(
                        STAT_TIMEOUT,
                        conn.stat_by_message_id(&message_id),
                    )
                    .await
                    {
                        Ok(Ok(present)) => {
                            // Tek satır yanıt eksiksiz okundu: bağlantı havuza döner.
                            conn.mark_reusable();
                            Some(present)
                        }
                        Ok(Err(_)) | Err(_) => None,
                    };
                    drop(conn);
                    present
                }
            }
        };

        let outcomes =
            drain_stat_plan(&plan.samples, stat, Instant::now() + HEALTH_DEADLINE).await;
        let report = classify_health(&plan, &outcomes);
        // Hiçbir örnek yanıt alamadıysa sağlayıcıya ulaşılamıyor demektir;
        // "her şey sağlam" gibi yanlış bir rozet üretmek yerine hata.
        if report.sampled_articles == 0 && !plan.samples.is_empty() {
            return Err("health check could not reach the news server".into());
        }
        Ok(report.into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::nzb::parse_nzb;

    /// Yapısal analiz yalnız parse edilmiş NZB ile ağsız test edilebilir
    /// (`run` katmanı canlı NNTP ister).
    #[test]
    fn dto_donusumu_alanlari_tasir() {
        let nzb = parse_nzb(
            r#"<nzb><file subject='"video.mkv" yEnc (1/2)'><segments>
                <segment bytes="10" number="1">video.mkv.1@x</segment>
                <segment bytes="10" number="2">video.mkv.2@x</segment>
            </segments></file></nzb>"#,
        )
        .unwrap();
        let plan = plan_health_samples(&nzb);
        let report = classify_health(&plan, &[Some(true), Some(true), Some(true)]);
        let dto = NzbHealthDto::from(report.clone());
        assert_eq!(dto.status, report.status.as_str());
        assert_eq!(dto.sampled_articles, report.sampled_articles);
        assert_eq!(dto.par2_recovery_blocks, report.par2_recovery_blocks);
    }
}
