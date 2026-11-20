//! NZB sağlık ön kontrolü: oynatma TUŞUNA BASMADAN yayın kalitesini göster.
//!
//! İki katmanlı çalışır:
//! 1. **Yapısal analiz (ağsız):** ayrıştırılmış NZB'den arşiv cilt
//!    sürekliliği, subjectte ilan edilen segment sayısıyla listenin
//!    uyuşmazlığı ve PAR2 onarım bloğu kapasitesi çıkarılır.
//! 2. **STAT örnekleme (ağ):** hedef dosyaların başından, ortasından ve
//!    sonundan segmentlere `STAT` sorguları atılır — article gövdeleri
//!    HIÇ indirilmez, sunucudan yalnız tek durum satırı döner (tembel
//!    akış kuralı ve bant genişliği korunur).
//!
//! Sonuç bir [`HealthStatus`] rozetidir: her şey yerinde → *Good*; eksikler
//! var ama PAR2 kapasitesi karşılıyorsa → *Repairable*; eksikler var,
//! onarım gücü belirsiz/yetersiz → *Risky*; yayın kesin oynatılamaz
//! (cilt boşluğu, baş segmenti yok) → *Missing*.
//!
//! Örnekleme olasılıksaldır: segment varlığındaki eksik oranı tüm hedef
//! article sayısına dışlanarak bir tahmin üretilir; kesin bir
//! sayım değildir; arama sonuçlarında ön eleme içindir.

use std::collections::{HashMap, HashSet};
use std::future::Future;

use tokio::task::JoinSet;
use tokio::time::Instant;

use super::nzb::{self, Nzb, NzbFile};

/// Tek planlı `STAT` örneği ve önceliği.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthSample {
    pub message_id: String,
    pub kind: HealthSampleKind,
}

/// Örneğin türü: oran hesabında ve baş/PAR2 çıkarımında kullanılır.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthSampleKind {
    /// Birincil hedefin ilk segmenti (yayının "baş" değer).
    Head,
    /// Hedef dosyalara ait örnek (oran bu gruptan hesaplanır).
    Target,
    /// PAR2 dosyasının ilk segmenti (onarım verisinin kendisi sağlam mı).
    Par2,
}

/// Sağlık rozetinin seviyesi. Dart'a `as_str` ile dizgi olarak taşınır.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthStatus {
    /// Örneklem ve yapı tamamen temiz.
    Good,
    /// Eksikler var; PAR2 onarım kapasitesi tahmini eksikleri karşılıyor.
    Repairable,
    /// Eksikler var; onarım gücü yok/yetersiz ama yayın kesin ölü değil.
    Risky,
    /// Oynatma kesin başarısız: cilt boşluğu, baş segmenti eksik, tüm örneklemler
    /// eksik ya da NZB'de oynatılabilir hedef yok.
    Missing,
}

impl HealthStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            HealthStatus::Good => "good",
            HealthStatus::Repairable => "repairable",
            HealthStatus::Risky => "risky",
            HealthStatus::Missing => "missing",
        }
    }
}

/// Yapısal analiz + örnekleme planı. Tamamen ağsız üretilir.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthPlan {
    pub samples: Vec<HealthSample>,
    /// Hedef dosyalarda listelenen toplam article sayısı (oran paydası).
    pub target_article_count: u64,
    pub target_file_count: u32,
    /// Arşiv (RAR/7z/obfuske) ciltlerinin toplamı; doğrudan videoda 0.
    pub archive_volumes: u32,
    /// NZB listesinde eksik cilt numaralarının sayısı.
    pub volume_gaps: u32,
    /// Segment numaralama boşlukları + "subject ilan > liste" farkları toplamı.
    pub listing_missing_articles: u64,
    pub par2_present: bool,
    /// Dosya adlarından toplanan `volN+M` onarım bloğu toplamı.
    pub par2_recovery_blocks: u32,
}

/// STAT sonuçlarıyla birleştirilmiş nihai rapor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthReport {
    pub status: HealthStatus,
    /// Yanıt alan (mevcut + eksik) hedef örneği sayısı.
    pub sampled_articles: u32,
    /// Örneklemde sunucuda bulunamayan segment sayısı.
    pub missing_articles: u32,
    /// Ağ/protokol hatası veren, karara katılmayan örnek sayısı.
    pub errored_samples: u32,
    /// Yapısal eksikler + dışlanan sunucu eksiği toplam tahmini (article).
    pub estimated_missing_articles: u64,
    pub target_article_count: u64,
    pub target_file_count: u32,
    pub archive_volumes: u32,
    pub volume_gaps: u32,
    /// Birincil hedefin ilk segmenti sunucuda yok.
    pub head_missing: bool,
    pub par2_present: bool,
    pub par2_recovery_blocks: u32,
    /// PAR2 varsa ve örneklenen baş segmentleri sapasağlam.
    pub par2_intact: bool,
}

/// Toplam örnek sayısının tavanı: her arama sonucu için yanlışlıkla
/// yüzlerce STAT yağdırmamak için (listede çok NZB denetlenir).
const MAX_SAMPLES: usize = 96;
/// PAR2 dosyalarından en fazla bu kadarının baş segmenti örneklenir.
const MAX_PAR2_SAMPLES: usize = 4;

/// Dosya başına listing eksiği: numaradaki boşluklar (1,2,5 → 2) ve
/// subjectin "`(n/m)`" ilanındaki m ile listedeki en büyük numara
/// arasındaki fark (kuyruk kopuksa) toplanır. m listedekinden küçükse
/// (fazla article ileri sürülmüş) sorun sayılmaz.
fn listing_missing_articles(file: &NzbFile) -> u64 {
    if file.segments.is_empty() {
        // Hiç segmenti listelenmemiş dosya: tamamen eksik kabul edilir.
        return 1;
    }
    let mut missing = 0u64;
    let mut expected = 1u32;
    for segment in &file.segments {
        if segment.number > expected {
            missing = missing.saturating_add((segment.number - expected) as u64);
        }
        expected = segment.number.saturating_add(1);
    }
    let last_number = file.segments.last().map_or(0, |segment| segment.number);
    if let Some(declared) = file.declared_segment_count() {
        if declared > last_number {
            missing = missing.saturating_add((declared - last_number) as u64);
        }
    }
    missing
}

/// PAR2 dosya adından onarım bloğu sayısını çıkarır:
/// `show.vol005+03.par2` → 3, `SHOW.VOL15+10.PAR2` → 10.
/// İndeks dosyaları (`show.par2`) ve tanınmayan adlar `None` döner
/// (kapasite "bilinmiyor" anlamında sıfır işlenir).
pub(crate) fn par2_recovery_blocks(filename: &str) -> Option<u32> {
    let lower = filename.to_ascii_lowercase();
    if !lower.ends_with(".par2") {
        return None;
    }
    let stem = &lower[..lower.len() - 5];
    let plus = stem.rfind('+')?;
    let right = &stem[plus + 1..];
    if right.is_empty() || !right.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let vol_pos = stem[..plus].rfind("vol")?;
    let digits = &stem[vol_pos + 3..plus];
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    right.parse::<u32>().ok()
}

/// Dosyanın PAR2 olup olmadığı (uzantı karşılaştırması, BÜYÜK/küçük duyarsız).
fn is_par2_filename(filename: &str) -> bool {
    filename
        .rsplit_once('.')
        .is_some_and(|(_, extension)| extension.eq_ignore_ascii_case("par2"))
}

/// Set türleri: örnek planı, cilt boşluğu kuralı ve birincilik sırası
/// bunu izler (`select_stream`'in tercih düzeni: direct > 7z > rar > obfuske).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SetKind {
    Direct,
    Rar,
    SevenZip,
    Numbered,
}

/// Bir set içindeki eksik cilt numaraları. RAR/7z setleri 1'den başlamak
/// zorundadır (baş cilt listede yoksa bu bir boşluktur); obfuske sayısal
/// setlerde başlangıç serbesttir, yalnız iç boşluklar sayılır.
fn volume_gap_count(kind: SetKind, numbers: &[u32]) -> u64 {
    if numbers.is_empty() {
        return 0;
    }
    let start = match kind {
            SetKind::Numbered => numbers[0],
            _ => 1,
        };
    let mut gaps = 0u64;
    let mut expected = start;
    for &number in numbers {
        if number < expected {
            continue; // yinelenen cilt: yeni boşluk saymaz
        }
        if number > expected {
            gaps = gaps.saturating_add((number - expected) as u64);
        }
        expected = number.saturating_add(1);
    }
    gaps
}

/// Örnekleme hedefi tek dosya: listing eksiğiyle birlikte.
struct PlannedFile<'a> {
    file: &'a NzbFile,
    listing_missing: u64,
}

/// Doğal oynatma diziliminde bir hedef grubu (doğrudan videolar ya da bir
/// arşiv seti). Dosyalar cilt sırasına (direct: kodlu boyuta göre azalan)
/// dizilir; grubun ilk üyesi "baş" örnekleminin kaynağıdır.
struct PlannedSet<'a> {
    kind: SetKind,
    files: Vec<PlannedFile<'a>>,
    volume_gaps: u64,
    encoded_bytes: u64,
}

impl PlannedSet<'_> {
    /// Head örnekleminin dosyası: grubun ilk dosyası (direct: en büyük
    /// video; arşiv: ilk cilt).
    fn head_file(&self) -> Option<&NzbFile> {
        self.files.first().map(|planned| planned.file)
    }
}

/// Örnek konumlarını öncelik etiketiyle üretir.
///
/// - İlk segment → 1 (varlık kontrolü, her cilt/direct dosyada).
/// - Orta ve son segment → 2 (yalnız ilk/son ciltte ve direct dosyalarda).
///
/// Öncelik 0 birincil hedefin başına çağırıcıda ayrılır.
fn sample_positions(file: &NzbFile, include_tail: bool) -> Vec<(usize, u8)> {
    let count = file.segments.len();
    if count == 0 {
        return Vec::new();
    }
    let mut positions = vec![(0, 1u8)];
    if !include_tail || count < 2 {
        return positions;
    }
    let last = count - 1;
    let mid = count / 2;
    if mid != 0 && mid != last {
        positions.push((mid, 2));
    }
    if last != 0 {
        positions.push((last, 2));
    }
    positions
}

pub fn plan_health_samples(nzb: &Nzb) -> HealthPlan {
    // ---- PAR2 envanteri --------------------------------------------------
    let mut par2_files: Vec<&NzbFile> = Vec::new();
    // Yerel ad fonksiyonla çakışmasın diye farklı ad.
    let mut blocks_total = 0u32;
    for file in &nzb.files {
        let Some(name) = file.filename() else { continue };
        if !is_par2_filename(name) {
            continue;
        }
        if let Some(blocks) = par2_recovery_blocks(name) {
            blocks_total = blocks_total.saturating_add(blocks);
        }
        par2_files.push(file);
    }

    // ---- Hedef setler ----------------------------------------------------
    let mut sets: Vec<PlannedSet<'_>> = Vec::new();

    // 1) Doğrudan videolar tek grup: kodlu boyuta göre azalan.
    let mut direct: Vec<PlannedFile<'_>> = nzb
        .files
        .iter()
        .filter(|file| file.is_playable_media())
        .map(|file| PlannedFile {
            file,
            listing_missing: listing_missing_articles(file),
        })
        .collect();
    // Kararlı sıra: kodlu boyuta göre azalan; eş boyutlu bölümlerde
    // stable sort listenin özgün düzenini korur.
    direct.sort_by_key(|planned| std::cmp::Reverse(planned.file.encoded_bytes()));
    if !direct.is_empty() {
        let encoded_bytes = direct.iter().fold(0u64, |total, planned| {
            total.saturating_add(planned.file.encoded_bytes())
        });
        sets.push(PlannedSet {
            kind: SetKind::Direct,
            files: direct,
            volume_gaps: 0,
            encoded_bytes,
        });
    }

    // 2) RAR/7z setleri: ad çözümlemeleri motorun kendi parserlarından.
    let mut archive_bases: HashSet<String> = HashSet::new();
    for (kind, parser) in [
        (
            SetKind::SevenZip,
            nzb::split_7z_volume_name as fn(&str) -> Option<(&str, u32)>,
        ),
        (
            SetKind::Rar,
            nzb::split_rar_volume_name as fn(&str) -> Option<(&str, u32)>,
        ),
    ] {
        let mut groups: HashMap<String, Vec<(u32, &NzbFile)>> = HashMap::new();
        for file in &nzb.files {
            let Some(name) = file.filename() else { continue };
            let Some((base, number)) = parser(name) else { continue };
            groups
                .entry(base.to_ascii_lowercase())
                .or_default()
                .push((number, file));
        }
        for (base, mut members) in groups {
            members.sort_by_key(|(number, _)| *number);
            let numbers: Vec<u32> = members.iter().map(|(number, _)| *number).collect();
            let volume_gaps = volume_gap_count(kind, &numbers);
            let files: Vec<PlannedFile<'_>> = members
                .into_iter()
                .map(|(_, file)| PlannedFile {
                    file,
                    listing_missing: listing_missing_articles(file),
                })
                .collect();
            let encoded_bytes = files.iter().fold(0u64, |total, planned| {
                total.saturating_add(planned.file.encoded_bytes())
            });
            archive_bases.insert(base);
            sets.push(PlannedSet {
                kind,
                files,
                volume_gaps,
                encoded_bytes,
            });
        }
    }

    // 3) Obfuske sayısal setler: zaten arşiv olarak çözülen tabanlar atlanır
    //    (motorun kendi obfuske-eleme kuralıyla aynı).
    {
        let mut groups: HashMap<String, Vec<(u32, &NzbFile)>> = HashMap::new();
        for file in &nzb.files {
            let Some(name) = file.filename() else { continue };
            let Some((base, number)) = nzb::numbered_volume_name(name) else {
                continue;
            };
            // `film.7z.001` gibi gerçek adlar yukarıda arşiv olarak alındı.
            if archive_bases.contains(&base.to_ascii_lowercase()) {
                continue;
            }
            groups
                .entry(base.to_ascii_lowercase())
                .or_default()
                .push((number, file));
        }
        for members in groups.into_values() {
            let mut members = members;
            // Tek dosyalı "set" hedef değildir; motorun sezgiseli de yalnız
            // çok üyeli kesintisiz setleri kabul eder.
            if members.len() < 2 {
                continue;
            }
            members.sort_by_key(|(number, _)| *number);
            let numbers: Vec<u32> = members.iter().map(|(number, _)| *number).collect();
            let volume_gaps = volume_gap_count(SetKind::Numbered, &numbers);
            let files: Vec<PlannedFile<'_>> = members
                .into_iter()
                .map(|(_, file)| PlannedFile {
                    file,
                    listing_missing: listing_missing_articles(file),
                })
                .collect();
            let encoded_bytes = files.iter().fold(0u64, |total, planned| {
                total.saturating_add(planned.file.encoded_bytes())
            });
            sets.push(PlannedSet {
                kind: SetKind::Numbered,
                files,
                volume_gaps,
                encoded_bytes,
            });
        }
    }

    // ---- Sayımlar --------------------------------------------------------
    let target_article_count = sets
        .iter()
        .flat_map(|set| set.files.iter())
        .fold(0u64, |total, planned| {
            total.saturating_add(planned.file.segments.len() as u64)
        });
    let target_file_count = sets
        .iter()
        .map(|set| set.files.len() as u32)
        .sum::<u32>();
    let archive_volumes = sets
        .iter()
        .filter(|set| set.kind != SetKind::Direct)
        .map(|set| set.files.len() as u32)
        .sum::<u32>();
    let volume_gaps = sets
        .iter()
        .map(|set| set.volume_gaps as u32)
        .sum::<u32>();
    let listing_missing_articles = sets
        .iter()
        .flat_map(|set| set.files.iter())
        .fold(0u64, |total, planned| {
            total.saturating_add(planned.listing_missing)
        });

    // ---- Örnekleme planı ---------------------------------------------------
    let mut planned: Vec<(u8, HealthSample)> = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    macro_rules! push {
        ($priority:expr, $message_id:expr, $kind:expr) => {
            if seen.insert($message_id) {
                planned.push((
                    $priority,
                    HealthSample {
                        message_id: $message_id.to_string(),
                        kind: $kind,
                    },
                ));
            }
        };
    }

    let primary_index = primary_set_index(&sets);
    if let Some(index) = primary_index {
        // P0: birincil hedefin baş segmenti — yayın açılamıyorsa en kritik işaret.
        if let Some(head) = sets[index].head_file() {
            if let Some(segment) = head.segments.first() {
                push!(0, &segment.message_id, HealthSampleKind::Head);
            }
        }
    }

    for set in &sets {
        let include_tail_per_file = set.kind == SetKind::Direct;
        for (index, planned_file) in set.files.iter().enumerate() {
            // Arşiv setlerinde orta/son segmentler yalnız ilk ve son ciltten
            // alınır; varlık kontrolü her ciltin ilk segmentinden geçer ve
            // örnek tavanı şişmemesi için orta ciltlere gövde örneği verilmez.
            let include_tail = include_tail_per_file
                || index == 0
                || index == set.files.len().saturating_sub(1);
            let file = planned_file.file;
            for (position, priority) in sample_positions(file, include_tail) {
                if let Some(segment) = file.segments.get(position) {
                    push!(priority, &segment.message_id, HealthSampleKind::Target);
                }
            }
        }
    }

    // PAR2 baş segmentleri: onarım olasılığının kendisi sapasağlam mı?
    for file in par2_files.iter().take(MAX_PAR2_SAMPLES) {
        if let Some(segment) = file.segments.first() {
            push!(3, &segment.message_id, HealthSampleKind::Par2);
        }
    }

    planned.sort_by_key(|(priority, _)| *priority);
    let samples: Vec<HealthSample> = planned
        .into_iter()
        .take(MAX_SAMPLES)
        .map(|(_, sample)| sample)
        .collect();

    HealthPlan {
        samples,
        target_article_count,
        target_file_count,
        archive_volumes,
        volume_gaps,
        listing_missing_articles,
        par2_present: !par2_files.is_empty(),
        par2_recovery_blocks: blocks_total,
    }
}

/// `select_stream`'in tercih sırasına göre birincil set: doğrudan video
/// varsa en büyük videonun grubu; yoksa en büyük 7z, sonra en büyük rar,
/// en son en büyük obfuske set.
fn primary_set_index(sets: &[PlannedSet<'_>]) -> Option<usize> {
    for kind in [
        SetKind::Direct,
        SetKind::SevenZip,
        SetKind::Rar,
        SetKind::Numbered,
    ] {
        let mut best: Option<usize> = None;
        for (index, set) in sets.iter().enumerate() {
            if set.kind != kind {
                continue;
            }
            if best.is_none_or(|current| {
                sets[current].encoded_bytes < set.encoded_bytes
            }) {
                best = Some(index);
            }
        }
        if best.is_some() {
            return best;
        }
    }
    None
}

/// Örnek STAT sonuçlarını sınıfa çevirir. `outcomes` dizisi plan
/// örnekleriyle hizalıdır; `None` ağ/protokol hatası demektir ve
/// karara katılmaz.
pub fn classify_health(plan: &HealthPlan, outcomes: &[Option<bool>]) -> HealthReport {
    // Hedefsiz NZB: motor zaten oynatacak bir şey bulamaz — tek dürüst
    // rozet "eksik"tir.
    if plan.target_file_count == 0 {
        return HealthReport {
            status: HealthStatus::Missing,
            sampled_articles: 0,
            missing_articles: 0,
            errored_samples: 0,
            estimated_missing_articles: 0,
            target_article_count: 0,
            target_file_count: 0,
            archive_volumes: 0,
            volume_gaps: 0,
            head_missing: false,
            par2_present: plan.par2_present,
            par2_recovery_blocks: plan.par2_recovery_blocks,
            par2_intact: false,
        };
    }

    let mut sampled = 0u32;
    let mut missing = 0u32;
    let mut errored = 0u32;
    let mut head_missing = false;
    let mut par2_broken = false;
    for (sample, outcome) in plan.samples.iter().zip(outcomes) {
        match outcome {
            None => errored += 1,
            Some(present) => match sample.kind {
                HealthSampleKind::Par2 => {
                    if !present {
                        par2_broken = true;
                    }
                }
                HealthSampleKind::Head => {
                    sampled += 1;
                    if !present {
                        missing += 1;
                        head_missing = true;
                    }
                }
                HealthSampleKind::Target => {
                    sampled += 1;
                    if !present {
                        missing += 1;
                    }
                }
            },
        }
    }

    // Sunucu tarafı eksik tahmini: örneklemlerdeki eksik oranı tüm
    // listelenmiş hedef article'larına dışlanır.
    let ratio = if sampled > 0 {
        missing as f64 / sampled as f64
    } else {
        0.0
    };
    let extrapolated = (ratio * plan.target_article_count as f64).ceil() as u64;
    // Cilt boşluklarının article'ları listede yok: her eksik cilt ortalama
    // cilt article sayısı kadar veri demektir.
    let avg_articles_per_volume = if plan.archive_volumes > 0 {
        plan.target_article_count / plan.archive_volumes as u64
    } else {
        0
    };
    let volume_gap_articles = plan.volume_gaps as u64 * avg_articles_per_volume;

    let par2_intact = plan.par2_present && !par2_broken;
    let capacity = if par2_intact {
        plan.par2_recovery_blocks as u64
    } else {
        0
    };
    let estimated =
        plan.listing_missing_articles
            .saturating_add(extrapolated)
            .saturating_add(volume_gap_articles);

    let all_missing = sampled > 0 && missing == sampled;
    let damaged = estimated > 0 || head_missing || all_missing;
    let fatal = head_missing || plan.volume_gaps > 0 || all_missing;

    let status = if !damaged {
        HealthStatus::Good
    } else if capacity >= estimated && estimated > 0 {
        HealthStatus::Repairable
    } else if fatal {
        HealthStatus::Missing
    } else {
        HealthStatus::Risky
    };

    HealthReport {
        status,
        sampled_articles: sampled,
        missing_articles: missing,
        errored_samples: errored,
        estimated_missing_articles: estimated,
        target_article_count: plan.target_article_count,
        target_file_count: plan.target_file_count,
        archive_volumes: plan.archive_volumes,
        volume_gaps: plan.volume_gaps,
        head_missing,
        par2_present: plan.par2_present,
        par2_recovery_blocks: plan.par2_recovery_blocks,
        par2_intact,
    }
}

/// Planlı örnekleri verilen `STAT` yürütücüsüyle eşzamanlı koşturur.
///
/// `stat`, her çağrıda bir message-ID alır; `Some(present)` sonucu veya ağ
/// hatasında `None` döner. Eşzamanlılık devre sınırı `stat`'ın kendi
/// bağlantı havuzundadır; burada yalnız görev yönetimi kurulur.
/// `deadline` aşılırsa kalan örnekler `None` (bilinmiyor) kalır ve akış
/// kesilir — arama listesindeki tarama sonsuz beklemeye dönmesin.
pub async fn drain_stat_plan<Stat, Fut>(
    samples: &[HealthSample],
    stat: Stat,
    deadline: Instant,
) -> Vec<Option<bool>>
where
    Stat: Fn(String) -> Fut + Send + Sync + Clone + 'static,
    Fut: Future<Output = Option<bool>> + Send,
{
    let mut set = JoinSet::new();
    for (index, sample) in samples.iter().enumerate() {
        let stat = stat.clone();
        let message_id = sample.message_id.clone();
        set.spawn(async move { (index, stat(message_id).await) });
    }

    let mut outcomes = vec![None; samples.len()];
    while !set.is_empty() {
        match tokio::time::timeout_at(deadline, set.join_next()).await {
            Ok(Some(Ok((index, present)))) => {
                if let Some(slot) = outcomes.get_mut(index) {
                    *slot = present;
                }
            }
            Ok(Some(Err(_))) => {} // panikleyen görev: sonucu bilinmez kalır
            Ok(None) => break,
            Err(_) => {
                set.abort_all();
                break;
            }
        }
    }
    outcomes
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::nzb::parse_nzb;
    use std::time::Duration;

    /// Her dosya `subject="..." (1/N)` ilanlı ve 1..N segmentli; message-ID
    /// `<ad>.<segment>@x` biçimindedir (örnek hedefleri kolay seçilir).
    fn nzb_of<S: AsRef<str>>(files: &[(S, u32)]) -> Nzb {
        let mut xml = String::from("<nzb>");
        for (subject, segments) in files {
            let subject = subject.as_ref();
            xml.push_str(&format!(
                r#"<file subject='"{subject}" yEnc (1/{segments})'><segments>"#
            ));
            for number in 1..=*segments {
                xml.push_str(&format!(
                    r#"<segment bytes="10" number="{number}">{subject}.{number}@x</segment>"#
                ));
            }
            xml.push_str("</segments></file>");
        }
        xml.push_str("</nzb>");
        parse_nzb(&xml).unwrap()
    }

    fn sample_ids(plan: &HealthPlan) -> Vec<&str> {
        plan.samples
            .iter()
            .map(|sample| sample.message_id.as_str())
            .collect()
    }

    #[test]
    fn par2_blok_sayisi_dosya_adindan_cozumlenir() {
        assert_eq!(par2_recovery_blocks("show.vol005+03.par2"), Some(3));
        assert_eq!(par2_recovery_blocks("SHOW.VOL15+10.PAR2"), Some(10));
        assert_eq!(par2_recovery_blocks("show.vol0+1.par2"), Some(1));
        // İndeks par2'si: kapasite bilinmiyor.
        assert_eq!(par2_recovery_blocks("show.par2"), None);
        // Par2 olmayan/tanınmayan adlar.
        assert_eq!(par2_recovery_blocks("show.mkv"), None);
        assert_eq!(par2_recovery_blocks("x.volA+B.par2"), None);
        assert_eq!(par2_recovery_blocks("x.vol3+.par2"), None);
        assert!(is_par2_filename("a.PAR2"));
        assert!(!is_par2_filename("a.par2x"));
    }

    #[test]
    fn dogrudan_video_bas_ornekleri_kaynagi_tanir() {
        let nzb = nzb_of(&[("video.mkv", 9)]);
        let plan = plan_health_samples(&nzb);

        assert_eq!(plan.target_file_count, 1);
        assert_eq!(plan.target_article_count, 9);
        assert_eq!(plan.archive_volumes, 0);
        assert_eq!(plan.volume_gaps, 0);
        assert_eq!(plan.listing_missing_articles, 0);
        assert!(!plan.par2_present);
        // P0 baş + orta + son; başın per-dosya "ilk segmenti" tekilleştirilir.
        assert_eq!(
            sample_ids(&plan),
            vec!["video.mkv.1@x", "video.mkv.5@x", "video.mkv.9@x"]
        );
        assert_eq!(plan.samples[0].kind, HealthSampleKind::Head);
    }

    #[test]
    fn subject_ihlanina_gore_kuyruk_eksigi_listelenir() {
        // "(1/3)" ilanına rağmen yalnız 2 segment listelenmiş: 1 article NZB'de yok.
        let xml = r#"<nzb><file subject='"video.mkv" yEnc (1/3)'><segments>
            <segment bytes="10" number="1">video.mkv.1@x</segment>
            <segment bytes="10" number="2">video.mkv.2@x</segment>
            </segments></file></nzb>"#;
        let nzb = parse_nzb(xml).unwrap();
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.target_article_count, 2);
        assert_eq!(plan.listing_missing_articles, 1);
    }

    #[test]
    fn segment_numarasi_boslugu_listing_eksigi_ekler() {
        // 1, 2, 5 numaralı segmentler: 3 ve 4 listede yok.
        let xml = r#"<nzb><file subject='"video.mkv" yEnc (1/5)'><segments>
            <segment bytes="10" number="1">video.mkv.1@x</segment>
            <segment bytes="10" number="2">video.mkv.2@x</segment>
            <segment bytes="10" number="5">video.mkv.5@x</segment>
            </segments></file></nzb>"#;
        let nzb = parse_nzb(xml).unwrap();
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.target_article_count, 3);
        assert_eq!(plan.listing_missing_articles, 2);
    }

    #[test]
    fn rar_seti_cilt_bosluklari_sayilir() {
        // part01, part03 → 2 numaralı cilt listede yok.
        let nzb = nzb_of(&[("film.part01.rar", 4), ("film.part03.rar", 4)]);
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.archive_volumes, 2);
        assert_eq!(plan.target_file_count, 2);
        assert_eq!(plan.volume_gaps, 1);
        // Her cildin ilk segmenti örnek planında olmalı.
        let ids = sample_ids(&plan);
        assert!(ids.contains(&"film.part01.rar.1@x"));
        assert!(ids.contains(&"film.part03.rar.1@x"));
        assert_eq!(plan.samples[0].kind, HealthSampleKind::Head);
        assert_eq!(plan.samples[0].message_id, "film.part01.rar.1@x");
    }

    #[test]
    fn rar_setinde_bas_cildi_yoksa_bosluk_sayilir() {
        // Eski usul: yalnız r00, r01 — baş (.rar, 1 numara) listede yok.
        let nzb = nzb_of(&[("film.r00", 4), ("film.r01", 4)]);
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.volume_gaps, 1);
    }

    #[test]
    fn yedi_z_setinde_001_zorunludur() {
        let nzb = nzb_of(&[("film.7z.002", 3), ("film.7z.003", 3)]);
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.volume_gaps, 1);
        assert_eq!(plan.archive_volumes, 2);
    }

    #[test]
    fn obfuske_sette_baslanti_serbest_ic_bosluk_sayilir() {
        // .10, .12 → .11 boşluğu; başlangıç numarası özgürdür.
        let nzb = nzb_of(&[("hash.10", 3), ("hash.12", 3)]);
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.archive_volumes, 2);
        assert_eq!(plan.target_file_count, 2);
        assert_eq!(plan.volume_gaps, 1);
    }

    #[test]
    fn par2_dosyalari_ornekleme_planina_girer() {
        let xml = r#"<nzb>
            <file subject='"video.mkv" yEnc (1/2)'><segments>
              <segment bytes="10" number="1">video.mkv.1@x</segment>
              <segment bytes="10" number="2">video.mkv.2@x</segment>
            </segments></file>
            <file subject='"show.vol005+03.par2" yEnc (1/1)'><segments>
              <segment bytes="10" number="1">show.vol005+03.par2.1@x</segment>
            </segments></file>
            </nzb>"#;
        let nzb = parse_nzb(xml).unwrap();

        let plan = plan_health_samples(&nzb);
        assert!(plan.par2_present);
        assert_eq!(plan.par2_recovery_blocks, 3);
        assert!(sample_ids(&plan).contains(&"show.vol005+03.par2.1@x"));
        // PAR2 dosyası hedef article sayımına girmez.
        assert_eq!(plan.target_article_count, 2);
        assert_eq!(plan.target_file_count, 1);
    }

    #[test]
    fn ornek_tavani_asilmaz_ve_bas_herbirne_kalir() {
        // 60 ciltlik rar seti + 60 bölümlük direct sezon paketi: planlı
        // toplam örnek tavana iner, baş örneği yine birincil hedeften
        // (direct > rar) gelir ve listede kalır.
        let mut files: Vec<(String, u32)> = Vec::new();
        for volume in 1..=60 {
            files.push((format!("film.part{volume:02}.rar"), 30));
        }
        for episode in 1..=60 {
            files.push((format!("dizi.e{episode:02}.mkv"), 30));
        }
        let nzb = nzb_of(&files);
        let plan = plan_health_samples(&nzb);
        assert!(plan.samples.len() <= MAX_SAMPLES);
        assert_eq!(plan.samples[0].kind, HealthSampleKind::Head);
        assert_eq!(plan.samples[0].message_id, "dizi.e01.mkv.1@x");
    }

    #[test]
    fn tum_ornekler_temizse_good() {
        let nzb = nzb_of(&[("video.mkv", 5)]);
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan.samples.iter().map(|_| Some(true)).collect();
        let report = classify_health(&plan, &outcomes);
        assert_eq!(report.status, HealthStatus::Good);
        assert_eq!(report.missing_articles, 0);
        assert_eq!(report.sampled_articles, 3);
        assert_eq!(report.estimated_missing_articles, 0);
    }

    #[test]
    fn bas_segmenti_eksik_ve_par2_yoksa_missing() {
        let nzb = nzb_of(&[("video.mkv", 5)]);
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan
            .samples
            .iter()
            .map(|sample| Some(sample.message_id != "video.mkv.1@x"))
            .collect();
        let report = classify_health(&plan, &outcomes);
        assert!(report.head_missing);
        assert_eq!(report.missing_articles, 1);
        assert_eq!(report.status, HealthStatus::Missing);
        assert!(report.estimated_missing_articles >= 1);
    }

    #[test]
    fn kuyruk_eksik_par2_yoksa_risky() {
        let nzb = nzb_of(&[("video.mkv", 5)]);
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan
            .samples
            .iter()
            .map(|sample| Some(sample.message_id != "video.mkv.5@x"))
            .collect();
        let report = classify_health(&plan, &outcomes);
        assert!(!report.head_missing);
        assert_eq!(report.status, HealthStatus::Risky);
    }

    #[test]
    fn eksikler_var_par2_kapasitesi_karsiliyorsa_repairable() {
        let xml = r#"<nzb>
            <file subject='"video.mkv" yEnc (1/6)'><segments>
              <segment bytes="10" number="1">video.mkv.1@x</segment>
              <segment bytes="10" number="2">video.mkv.2@x</segment>
              <segment bytes="10" number="3">video.mkv.3@x</segment>
              <segment bytes="10" number="4">video.mkv.4@x</segment>
              <segment bytes="10" number="5">video.mkv.5@x</segment>
              <segment bytes="10" number="6">video.mkv.6@x</segment>
            </segments></file>
            <file subject='"v.vol0+2.par2" yEnc (1/1)'><segments>
              <segment bytes="10" number="1">v.vol0+2.par2.1@x</segment>
            </segments></file>
            </nzb>"#;
        let nzb = parse_nzb(xml).unwrap();

        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.par2_recovery_blocks, 2);
        // Son segment eksik; PAR2 baş segmenti sapasağlam.
        let outcomes: Vec<Option<bool>> = plan
            .samples
            .iter()
            .map(|sample| Some(sample.message_id != "video.mkv.6@x"))
            .collect();
        let report = classify_health(&plan, &outcomes);
        assert_eq!(report.missing_articles, 1);
        assert!(report.par2_intact);
        // Dışlanan eksik = ceil(1/3 × 6) = 2 ≤ kapasite 2.
        assert_eq!(report.estimated_missing_articles, 2);
        assert_eq!(report.status, HealthStatus::Repairable);
    }

    #[test]
    fn par2_kendisi_eksikse_kapasite_gecersizdir() {
        let xml = r#"<nzb>
            <file subject='"video.mkv" yEnc (1/6)'><segments>
              <segment bytes="10" number="1">video.mkv.1@x</segment>
              <segment bytes="10" number="2">video.mkv.2@x</segment>
              <segment bytes="10" number="3">video.mkv.3@x</segment>
              <segment bytes="10" number="4">video.mkv.4@x</segment>
              <segment bytes="10" number="5">video.mkv.5@x</segment>
              <segment bytes="10" number="6">video.mkv.6@x</segment>
            </segments></file>
            <file subject='"v.vol0+5.par2" yEnc (1/1)'><segments>
              <segment bytes="10" number="1">v.vol0+5.par2.1@x</segment>
            </segments></file>
            </nzb>"#;
        let nzb = parse_nzb(xml).unwrap();

        let plan = plan_health_samples(&nzb);
        // Video kuyruğu ve PAR2'nin baş segmenti eksik.
        let outcomes: Vec<Option<bool>> = plan
            .samples
            .iter()
            .map(|sample| {
                Some(
                    sample.message_id != "video.mkv.6@x"
                        && sample.message_id != "v.vol0+5.par2.1@x",
                )
            })
            .collect();
        let report = classify_health(&plan, &outcomes);
        assert!(!report.par2_intact);
        assert_eq!(report.status, HealthStatus::Risky);
    }

    #[test]
    fn listing_kuyruk_eksigi_karar_verir() {
        // Subject 3 bölüm ilan ediyor, liste 2'de bitiyor: son article
        // örneklenemez bile — listing eksiği doğrudan karara girer.
        let xml = r#"<nzb><file subject='"video.mkv" yEnc (1/3)'><segments>
            <segment bytes="10" number="1">video.mkv.1@x</segment>
            <segment bytes="10" number="2">video.mkv.2@x</segment>
            </segments></file></nzb>"#;
        let nzb = parse_nzb(xml).unwrap();
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan.samples.iter().map(|_| Some(true)).collect();
        let report = classify_health(&plan, &outcomes);
        // Örneklemler sağlam ama 1 article'ın listede olmaması risk taşır.
        assert_eq!(report.status, HealthStatus::Risky);
        assert_eq!(report.estimated_missing_articles, 1);
    }

    #[test]
    fn cilt_boslu_par2_yoksa_missing() {
        let nzb = nzb_of(&[("film.part01.rar", 4), ("film.part03.rar", 4)]);
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan.samples.iter().map(|_| Some(true)).collect();
        let report = classify_health(&plan, &outcomes);
        // Tüm örneklemler sunucuda sağlam olsa bile listede cilt eksik.
        assert_eq!(report.status, HealthStatus::Missing);
        assert!(report.estimated_missing_articles > 0);
    }

    #[test]
    fn cilt_boslu_par2_yeterliyse_repairable() {
        let xml = r#"<nzb>
            <file subject='"film.part01.rar" yEnc (1/4)'><segments>
              <segment bytes="10" number="1">film.part01.rar.1@x</segment>
              <segment bytes="10" number="2">film.part01.rar.2@x</segment>
              <segment bytes="10" number="3">film.part01.rar.3@x</segment>
              <segment bytes="10" number="4">film.part01.rar.4@x</segment>
            </segments></file>
            <file subject='"film.part03.rar" yEnc (1/4)'><segments>
              <segment bytes="10" number="1">film.part03.rar.1@x</segment>
              <segment bytes="10" number="2">film.part03.rar.2@x</segment>
              <segment bytes="10" number="3">film.part03.rar.3@x</segment>
              <segment bytes="10" number="4">film.part03.rar.4@x</segment>
            </segments></file>
            <file subject='"f.vol0+8.par2" yEnc (1/1)'><segments>
              <segment bytes="10" number="1">f.vol0+8.par2.1@x</segment>
            </segments></file>
            </nzb>"#;
        let nzb = parse_nzb(xml).unwrap();

        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.volume_gaps, 1);
        // Tüm hedef ve PAR2 örneklemleri sağlam: eksik cildin verisi
        // (4 article) PAR2 kapasitesiyle (8 blok) karşılanabilir.
        let outcomes: Vec<Option<bool>> = plan.samples.iter().map(|_| Some(true)).collect();
        let report = classify_health(&plan, &outcomes);
        assert_eq!(report.status, HealthStatus::Repairable);
    }

    #[test]
    fn tum_ornekler_eksikse_missing() {
        let nzb = nzb_of(&[("video.mkv", 5)]);
        let plan = plan_health_samples(&nzb);
        let outcomes: Vec<Option<bool>> = plan.samples.iter().map(|_| Some(false)).collect();
        let report = classify_health(&plan, &outcomes);
        assert_eq!(report.status, HealthStatus::Missing);
        assert!(report.head_missing);
        assert_eq!(report.missing_articles, 3);
    }

    #[test]
    fn hedefsiz_nzb_missing_rozeti_verir() {
        // Yalnızca nfo: oynatılacak hiçbir şey yok.
        let nzb = nzb_of(&[("video.nfo", 2)]);
        let plan = plan_health_samples(&nzb);
        assert_eq!(plan.target_file_count, 0);
        assert!(plan.samples.is_empty());
        let report = classify_health(&plan, &[]);
        assert_eq!(report.status, HealthStatus::Missing);
    }

    #[test]
    fn hata_orenkleri_karara_katilmaz() {
        let nzb = nzb_of(&[("video.mkv", 5)]);
        let plan = plan_health_samples(&nzb);
        // Yalnız baş örneği yanıt aldı (geri kalanı ağ hatası).
        let outcomes: Vec<Option<bool>> = plan
            .samples
            .iter()
            .enumerate()
            .map(|(index, _)| if index == 0 { Some(true) } else { None })
            .collect();
        let report = classify_health(&plan, &outcomes);
        assert_eq!(report.sampled_articles, 1);
        assert_eq!(report.errored_samples, 2);
        assert_eq!(report.status, HealthStatus::Good);
    }

    #[tokio::test]
    async fn stat_drenaji_hatayi_bilinmeyen_birakir() {
        let samples: Vec<HealthSample> = (0..4)
            .map(|index| HealthSample {
                message_id: format!("seg{index}@x"),
                kind: HealthSampleKind::Target,
            })
            .collect();

        // "seg0" sorgusu ağ hatası verir; diğerleri sağlam döner.
        let stat = |message_id: String| async move {
            if message_id.starts_with("seg0") {
                None
            } else {
                Some(true)
            }
        };
        let outcomes =
            drain_stat_plan(&samples, stat, Instant::now() + Duration::from_secs(5)).await;
        assert_eq!(outcomes, vec![None, Some(true), Some(true), Some(true)]);
    }

    #[tokio::test]
    async fn stat_drenaji_deadline_asilinca_akis_kesilir() {
        let samples: Vec<HealthSample> = (0..3)
            .map(|index| HealthSample {
                message_id: format!("seg{index}@x"),
                kind: HealthSampleKind::Target,
            })
            .collect();

        // Hiçbir sorgu bitmez: deadline tüm sonuçları bilinmez bırakır.
        let stat = |_message_id: String| async { std::future::pending::<Option<bool>>().await };
        let outcomes = drain_stat_plan(&samples, stat, Instant::now() + Duration::from_millis(50))
            .await;
        assert!(outcomes.iter().all(|outcome| outcome.is_none()));
    }
}
