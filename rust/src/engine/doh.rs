use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::engine::http;

const CACHE_TTL: Duration = Duration::from_secs(24 * 3600);
const NEGATIVE_TTL: Duration = Duration::from_secs(6 * 3600);
const CIRCUIT_OPEN: Duration = Duration::from_secs(60);
const FAILURE_THRESHOLD: u32 = 5;
const DOH_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_RESPONSE: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DohError {
    NoSuchHost,
    Unavailable,
}

static ENDPOINT: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn endpoint_slot() -> &'static Mutex<Option<String>> {
    ENDPOINT.get_or_init(|| Mutex::new(None))
}

pub fn configure(endpoint: String) {
    let value = endpoint.trim().to_string();
    *endpoint_slot().lock().expect("doh lock") = if value.is_empty() {
        None
    } else {
        Some(value)
    };
}

pub fn endpoint() -> Option<String> {
    endpoint_slot().lock().expect("doh lock").clone()
}

struct CacheEntry {
    addresses: Vec<IpAddr>,
    at: Instant,
}

struct State {
    cache: HashMap<String, CacheEntry>,
    negative: HashMap<String, Instant>,
    failures: HashMap<String, u32>,
    circuit: HashMap<String, Instant>,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        Mutex::new(State {
            cache: HashMap::new(),
            negative: HashMap::new(),
            failures: HashMap::new(),
            circuit: HashMap::new(),
        })
    })
}

fn record_failure(endpoint: &str) {
    let mut state = state().lock().expect("doh state");
    let failures = state.failures.entry(endpoint.to_string()).or_insert(0);
    *failures += 1;
    if *failures >= FAILURE_THRESHOLD {
        state.circuit.insert(endpoint.to_string(), Instant::now() + CIRCUIT_OPEN);
        state.failures.remove(endpoint);
    }
}

fn record_success(endpoint: &str) {
    let mut state = state().lock().expect("doh state");
    state.failures.remove(endpoint);
    state.circuit.remove(endpoint);
}

fn circuit_open(endpoint: &str) -> bool {
    let mut state = state().lock().expect("doh state");
    match state.circuit.get(endpoint) {
        Some(until) if Instant::now() < *until => true,
        Some(_) => {
            state.circuit.remove(endpoint);
            state.failures.remove(endpoint);
            false
        }
        None => false,
    }
}

fn numeric_host(host: &str) -> Option<IpAddr> {
    host.parse::<IpAddr>().ok()
}

fn base64url(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((data.len() * 4).div_ceil(3));
    let mut i = 0;
    while i + 3 <= data.len() {
        let value = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | data[i + 2] as u32;
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        out.push(TABLE[((value >> 6) & 63) as usize] as char);
        out.push(TABLE[(value & 63) as usize] as char);
        i += 3;
    }
    let remaining = &data[i..];
    if remaining.len() == 1 {
        let value = (remaining[0] as u32) << 16;
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
    } else if remaining.len() == 2 {
        let value = ((remaining[0] as u32) << 16) | ((remaining[1] as u32) << 8);
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        out.push(TABLE[((value >> 6) & 63) as usize] as char);
    }
    out
}

static QUERY_ID: AtomicU16 = AtomicU16::new(1);

pub fn build_query(host: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(host.len() + 17);
    let id = QUERY_ID.fetch_add(1, Ordering::Relaxed);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&[0x01, 0x00]);
    out.extend_from_slice(&[0x00, 0x01]);
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            continue;
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]);
    out
}

fn skip_name(data: &[u8], mut offset: usize) -> Option<usize> {
    while offset < data.len() {
        let len = data[offset] as usize;
        if len == 0 {
            return Some(offset + 1);
        }
        if len & 0xC0 == 0xC0 {
            return Some(offset + 2);
        }
        offset = offset.checked_add(1 + len)?;
    }
    None
}

pub fn parse_response(data: &[u8]) -> Result<Vec<IpAddr>, DohError> {
    if data.len() < 12 {
        return Err(DohError::Unavailable);
    }
    let rcode = data[3] & 0x0F;
    if rcode == 3 {
        return Err(DohError::NoSuchHost);
    }
    if rcode != 0 {
        return Err(DohError::Unavailable);
    }
    let question_count = u16::from_be_bytes([data[4], data[5]]) as usize;
    let answer_count = u16::from_be_bytes([data[6], data[7]]) as usize;
    let mut offset = 12;
    for _ in 0..question_count {
        offset = skip_name(data, offset)
            .ok_or(DohError::Unavailable)?
            .checked_add(4)
            .ok_or(DohError::Unavailable)?;
    }
    let mut addresses = Vec::new();
    for _ in 0..answer_count {
        offset = skip_name(data, offset).ok_or(DohError::Unavailable)?;
        if offset + 10 > data.len() {
            return Err(DohError::Unavailable);
        }
        let kind = u16::from_be_bytes([data[offset], data[offset + 1]]);
        let rd_length = u16::from_be_bytes([data[offset + 8], data[offset + 9]]) as usize;
        let rdata = offset + 10;
        if kind == 1 && rd_length == 4 && rdata + 4 <= data.len() {
            addresses.push(IpAddr::from([
                data[rdata],
                data[rdata + 1],
                data[rdata + 2],
                data[rdata + 3],
            ]));
        }
        offset = rdata.checked_add(rd_length).ok_or(DohError::Unavailable)?;
    }
    if addresses.is_empty() {
        Err(DohError::NoSuchHost)
    } else {
        Ok(addresses)
    }
}

pub async fn resolve(host: &str, endpoint: &str) -> Result<Vec<IpAddr>, DohError> {
    if let Some(ip) = numeric_host(host) {
        return Ok(vec![ip]);
    }
    let key = format!("{endpoint}|{host}");
    {
        let mut state = state().lock().expect("doh state");
        if let Some(entry) = state.cache.get(&key) {
            if entry.at.elapsed() < CACHE_TTL {
                return Ok(entry.addresses.clone());
            }
            state.cache.remove(&key);
        }
        if state
            .negative
            .get(&key)
            .is_some_and(|at| at.elapsed() < NEGATIVE_TTL)
        {
            return Err(DohError::NoSuchHost);
        }
        state.negative.remove(&key);
    }
    if circuit_open(endpoint) {
        return Err(DohError::Unavailable);
    }

    if host.is_empty()
        || host
            .split('.')
            .any(|label| label.is_empty() || label.len() > 63)
    {
        return Err(DohError::Unavailable);
    }
    let wire = build_query(host);
    let url = format!("{endpoint}?dns={}", base64url(&wire));
    let mut response = None;
    for attempt in 0..3 {
        let current = http::http_request_system(
            "GET",
            &url,
            &[("Accept", "application/dns-message")],
            &[],
            MAX_RESPONSE,
            DOH_TIMEOUT,
        )
        .await
        .map_err(|_| DohError::Unavailable)?;
        if current.status != 429 && current.status != 503 {
            response = Some(current);
            break;
        }
        if attempt == 2 {
            record_failure(endpoint);
            return Err(DohError::Unavailable);
        }
        let jitter = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            % 250) as u64;
        tokio::time::sleep(Duration::from_millis(250 * (attempt as u64 + 1) + jitter)).await;
    }
    let response = response.ok_or(DohError::Unavailable)?;
    if !(200..300).contains(&response.status) {
        record_failure(endpoint);
        return Err(DohError::Unavailable);
    }
    let addresses = match parse_response(&response.body) {
        Ok(addresses) => addresses,
        Err(DohError::NoSuchHost) => {
            let mut state = state().lock().expect("doh state");
            state.negative.insert(key, Instant::now());
            drop(state);
            record_success(endpoint);
            return Err(DohError::NoSuchHost);
        }
        Err(error) => {
            record_failure(endpoint);
            return Err(error);
        }
    };
    let mut state = state().lock().expect("doh state");
    state.cache.insert(
        key,
        CacheEntry {
            addresses: addresses.clone(),
            at: Instant::now(),
        },
    );
    state.negative.remove(&format!("{endpoint}|{host}"));
    drop(state);
    record_success(endpoint);
    Ok(addresses)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_has_a_record_question() {
        let wire = build_query("idx.example");
        assert_eq!(&wire[2..4], &[0x01, 0x00]);
        assert_eq!(&wire[4..6], &[0x00, 0x01]);
        assert_eq!(&wire[12..16], &[3, b'i', b'd', b'x']);
        assert_eq!(&wire[wire.len() - 4..], &[0x00, 0x01, 0x00, 0x01]);
    }

    #[test]
    fn base64url_has_no_padding() {
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
        assert!(!base64url(&[1, 2, 3]).contains('='));
    }

    #[test]
    fn parses_a_records() {
        let mut response = vec![0, 1, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0];
        response.extend_from_slice(&[3, b'i', b'd', b'x', 0, 0, 1, 0, 1]);
        response.extend_from_slice(&[0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]);
        assert_eq!(
            parse_response(&response).unwrap(),
            vec![IpAddr::from([1, 2, 3, 4])]
        );
    }

    #[test]
    fn nxdomain_is_not_unavailable() {
        let response = [0, 1, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(parse_response(&response), Err(DohError::NoSuchHost));
    }

    #[test]
    fn literal_ip_is_returned_without_a_query() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let result = runtime.block_on(resolve("127.0.0.1", "https://doh.example/dns-query"));
        assert_eq!(result.unwrap(), vec![IpAddr::from([127, 0, 0, 1])]);
    }
}
