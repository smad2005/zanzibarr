//! OpenSubtitles API yüzeyi (flutter_rust_bridge).
//!
//! Dart, güvenli depodan okuduğu API anahtarını/hesap bilgilerini her
//! çağrıda geçici olarak verir; Rust bunları bellek dışına yazmaz.
//! Arama: dosya adı + (varsa) oynatılan akışın moviehash'i. İndirme:
//! `file_id` → platform-güvenli dosya adıyla `download_dir` altına yazılır;
//! yol döner.
//!
//! Gizlilik kuralı: `OpenSubtitlesConfigDto` `Debug` türetmez; hata
//! metinleri anahtar/parola URL veya gövde içermez (motor tarafı bunu
//! sağlar, bkz. `engine/opensubtitles.rs`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::engine::opensubtitles::{
    fetch_subtitle, request_download, search_subtitles, OpenSubtitlesConfig,
    OpenSubtitlesError, SubtitleQuery,
};

use super::streaming::RUNTIME;

/// Dart'ın güvenli deposundan gelen OpenSubtitles kimlik bilgileri.
pub struct OpenSubtitlesConfigDto {
    /// Boşsa motor varsayılanı kullanılır (`DEFAULT_BASE_URL`).
    pub base_url: String,
    pub api_key: String,
    /// Boş bırakılabilir: indirme o zaman anahtarın anonim kotasıyla denenir.
    pub username: String,
    pub password: String,
}

/// Tek altyazı sonucu (`file_id` indirme kimliğidir).
pub struct SubtitleDto {
    pub file_id: u64,
    pub file_name: String,
    /// ISO dil kodu ("tr", "en", "ar", …).
    pub language: String,
    pub release: String,
    pub download_count: u64,
    /// moviehash + boyut gönderildiyse: dosya-bazı eşleşme.
    pub matched_by_hash: bool,
    pub hearing_impaired: bool,
}

const SEARCH_TIMEOUT: Duration = Duration::from_secs(25);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(45);
/// Tek aramada istenen en fazla dil (garbage listeleri engellemek için).
const MAX_LANGUAGES: usize = 10;

fn map_error(error: OpenSubtitlesError) -> String {
    error.to_string()
}

/// Dil kodlarını güvenli kılar: küçük harf, harf-sayı yalnız, tekrarsız,
/// en çok [`MAX_LANGUAGES`] girdi; sıra kullanıcının tercih sırasıdır.
fn sanitize_languages(languages: &[String]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for language in languages {
        let code = language.trim().to_lowercase();
        if code.is_empty()
            || !code.chars().all(|c| c.is_ascii_alphanumeric())
            || code.len() > 6
        {
            continue;
        }
        if !seen.contains(&code) {
            seen.push(code);
        }
        if seen.len() >= MAX_LANGUAGES {
            break;
        }
    }
    seen
}

fn ensure_api_key(config: &OpenSubtitlesConfigDto) -> Result<(), String> {
    if config.api_key.trim().is_empty() {
        return Err("missing OpenSubtitles API key".to_string());
    }
    Ok(())
}

/// Yayın adıyla (ve varsa moviehash + boyutla) altyazı arar.
///
/// Ağ akışı: GET /subtitles — arama article/altyazı gövdesi indirmez.
/// `movie_hash` onaltılık, `movie_bytesize` bayt cinsindendir; ikisi birlikte
/// gönderilir (moviehash yalnız boyutla anlamlı olduğundan boyut yoksa
/// hash de atılır).
pub fn search_opensubtitles(
    config: OpenSubtitlesConfigDto,
    query: String,
    languages: Vec<String>,
    movie_hash: Option<String>,
    movie_bytesize: Option<u64>,
) -> Result<Vec<SubtitleDto>, String> {
    ensure_api_key(&config)?;
    let languages = sanitize_languages(&languages);
    if languages.is_empty() {
        return Err("no subtitle languages selected".to_string());
    }
    let movie_hash = movie_hash
        .as_deref()
        .map(str::trim)
        .filter(|hash| !hash.is_empty())
        .map(str::to_lowercase);

    RUNTIME.block_on(async move {
        let use_hash = movie_hash.is_some() && movie_bytesize.is_some();
        let search_query = SubtitleQuery {
            release_name: &query,
            languages: &languages,
            movie_hash: if use_hash {
                movie_hash.as_deref()
            } else {
                None
            },
            movie_bytesize,
        };
        let engine_config = OpenSubtitlesConfig {
            base_url: &config.base_url,
            api_key: &config.api_key,
            username: &config.username,
            password: &config.password,
        };
        let files = match tokio::time::timeout(
            SEARCH_TIMEOUT,
            search_subtitles(&engine_config, &search_query),
        )
        .await
        {
            Ok(result) => result.map_err(map_error)?,
            Err(_) => return Err("OpenSubtitles search timed out".to_string()),
        };
        Ok(files
            .into_iter()
            .map(|file| SubtitleDto {
                file_id: file.file_id,
                file_name: file.file_name,
                language: file.language,
                release: file.release,
                download_count: file.download_count,
                matched_by_hash: file.matched_by_hash,
                hearing_impaired: file.hearing_impaired,
            })
            .collect())
    })
}

/// `file_id` ile altyazıyı indirip `download_dir` altına yazar; dosya yolu
/// döner. Aynı `file_id` daha önce indirildiyse ağa hiç çıkılmaz (kota
/// tasarrufu: diskteki dosya aynen döner).
///
/// Boş `download_dir`'de sistem temp'i altında `zanzibarr-subtitles`
/// kullanılır (Android'de app cache, Dart tarafından verilir — issue #3
/// ile aynı gerekçe: `TMPDIR` Android'de yazılabilir değildir).
pub fn download_opensubtitles(
    config: OpenSubtitlesConfigDto,
    file_id: u64,
    download_dir: Option<String>,
) -> Result<String, String> {
    ensure_api_key(&config)?;
    let download_dir = download_dir
        .filter(|dir| !dir.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("zanzibarr-subtitles"));

    // Önce disk: kota dostu önbellek.
    if let Some(existing) = existing_subtitle_path(&download_dir, file_id) {
        return Ok(existing.to_string_lossy().into_owned());
    }

    RUNTIME.block_on(async {
        let engine_config = OpenSubtitlesConfig {
            base_url: &config.base_url,
            api_key: &config.api_key,
            username: &config.username,
            password: &config.password,
        };
        let (bytes, file_name) = match tokio::time::timeout(DOWNLOAD_TIMEOUT, async {
            let download = request_download(&engine_config, file_id).await?;
            let bytes = fetch_subtitle(&download.link).await?;
            Ok::<_, OpenSubtitlesError>((bytes, download.file_name))
        })
        .await
        {
            Ok(result) => result.map_err(map_error)?,
            Err(_) => return Err("OpenSubtitles download timed out".to_string()),
        };
        // OS'un önerdiği ad; bilinen bir altyazı uzantısı yoksa "srt"
        // eklenir (mpv uzantıdan içerik çıkarımı yapar).
        let mut safe_name = sanitize_component(&file_name);
        let known_extension = safe_name
            .rsplit_once('.')
            .is_some_and(|(_, extension)| {
                matches!(
                    extension.to_ascii_lowercase().as_str(),
                    "srt" | "ass" | "ssa" | "vtt" | "sub" | "txt"
                )
            });
        if !known_extension {
            safe_name = format!("{safe_name}.srt");
        }
        let path = download_dir.join(format!("{file_id}-{safe_name}"));
        std::fs::create_dir_all(&download_dir)
            .map_err(|error| format!("could not create subtitle directory: {error}"))?;
        std::fs::write(&path, bytes)
            .map_err(|error| format!("could not write subtitle: {error}"))?;
        Ok(path.to_string_lossy().into_owned())
    })
}

/// Aynı dosya kimliği (file_id) için daha önce yazılmış dosyayı bulur.
fn existing_subtitle_path(dir: &Path, file_id: u64) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let prefix = format!("{file_id}-");
    let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let lossy_name = name.to_string_lossy();
        let Some(rest) = lossy_name.strip_prefix(&prefix) else {
            continue;
        };
        // Uzantı doğrulaması: önek uyuşan yabancı/eksik dosyaları elemek için.
        if rest.contains('.') {
            let modified = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            if newest.as_ref().is_none_or(|(time, _)| modified > *time) {
                newest = Some((modified, entry.path()));
            }
        }
    }
    newest.map(|(_, path)| path)
}

/// OS'un önerdiği dosya adını bileşen-güvenli biçime indirger (en çok 120
/// karakter; boşsa "subtitle" taban adı).
fn sanitize_component(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '-' | '_' | '.' | ' ' | '(' | ')' | '[' | ']') {
                c
            } else {
                '_'
            }
        })
        .take(120)
        .collect();
    let sanitized = sanitized.trim().trim_matches(['.', '_']).to_string();
    if sanitized.is_empty() {
        "subtitle".to_string()
    } else {
        sanitized
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dil_listesi_guvenli_hale_getirilir() {
        let input = vec![
            "  TR ".to_string(),
            "en".to_string(),
            "EN".to_string(),
            "ar!".to_string(),
            String::new(),
            "tooooooolong".to_string(),
            "es".to_string(),
        ];
        assert_eq!(sanitize_languages(&input), vec!["tr", "en", "es"]);
        let many: Vec<String> = (0..20).map(|i| format!("l{i}")).collect();
        assert_eq!(sanitize_languages(&many).len(), MAX_LANGUAGES);
    }

    #[test]
    fn bilesen_adi_temizligi() {
        assert_eq!(sanitize_component("a/b\\c:d.srt"), "a_b_c_d.srt");
        assert_eq!(sanitize_component("...___"), "subtitle");
        assert_eq!(sanitize_component(""), "subtitle");
        assert_eq!(
            sanitize_component("Sub Name (2024).srt"),
            "Sub Name (2024).srt"
        );
    }

    #[test]
    fn oncece_indirilmis_dosya_onbellekten_doner() {
        let dir = std::env::temp_dir().join(format!("zanzibarr-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("5274788-Movie.2024.srt");
        std::fs::write(&path, b"1\n00:00:01,000 --> 00:00:02,000\nx\n").unwrap();
        let found = existing_subtitle_path(&dir, 5274788).unwrap();
        assert_eq!(found, path);
        assert!(existing_subtitle_path(&dir, 111).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn api_anahtari_yoksa_arama_hata_verir() {
        let config = OpenSubtitlesConfigDto {
            base_url: String::new(),
            api_key: String::new(),
            username: String::new(),
            password: String::new(),
        };
        let result = search_opensubtitles(
            config,
            "movie".into(),
            vec!["tr".into()],
            None,
            None,
        );
        let Err(err) = result else {
            panic!("boş API anahtarı aramayı reddetmeliydi");
        };
        assert_eq!(err, "missing OpenSubtitles API key");
    }
}
