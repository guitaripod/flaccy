//! Position keys: fractional strings over `0-9A-Za-z` that order playlist entries.

const DIGITS: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const BASE: usize = 62;

/// The length past which a playlist's keys are rewritten evenly.
pub const MAX_POS_LEN: usize = 64;

/// Which way the neighbours push the new digit.
#[derive(Clone, Copy)]
enum Bias {
    AfterEverything,
    BeforeEverything,
    Between,
}

fn digit_value(digit: u8) -> usize {
    DIGITS.iter().position(|&d| d == digit).unwrap_or(0)
}

/// True for a well formed key: non-empty, in the alphabet, not ending in `0`.
pub fn is_valid(pos: &str) -> bool {
    pos.bytes().all(|b| b.is_ascii_alphanumeric()) && !pos.is_empty() && !pos.ends_with('0')
}

/// True when a key is long enough to trigger the playlist rewrite.
pub fn needs_rebalance(pos: &str) -> bool {
    pos.len() > MAX_POS_LEN
}

/// A key strictly between `a` and `b`; either may be absent for an open end.
///
/// With an open end the digit next to the bound is taken instead of the
/// midpoint, so appending or prepending costs one character per ~30 keys. When
/// `a >= b` (equal keys left by a reseed) the result is just after `a`.
pub fn between(a: Option<&str>, b: Option<&str>) -> String {
    match (a, b) {
        (None, None) => "V".to_owned(),
        (Some(a), Some(b)) if a >= b => between(Some(a), None),
        _ => {
            let bias = match (a, b) {
                (_, None) => Bias::AfterEverything,
                (None, _) => Bias::BeforeEverything,
                _ => Bias::Between,
            };
            let key = midpoint(a.unwrap_or("").as_bytes(), b.map(str::as_bytes), bias);
            key.into_iter().map(char::from).collect()
        }
    }
}

fn shared_prefix(a: &[u8], b: &[u8]) -> usize {
    (0..b.len())
        .take_while(|&i| a.get(i).copied().unwrap_or(b'0') == b[i])
        .count()
}

fn midpoint(a: &[u8], b: Option<&[u8]>, bias: Bias) -> Vec<u8> {
    if let Some(b) = b {
        let shared = shared_prefix(a, b);
        if shared > 0 {
            let mut key = b[..shared].to_vec();
            let rest = a.get(shared..).unwrap_or_default();
            key.extend(midpoint(rest, Some(&b[shared..]), bias));
            return key;
        }
    }
    let low = a.first().map_or(0, |&d| digit_value(d));
    let high = b.and_then(<[u8]>::first).map_or(BASE, |&d| digit_value(d));
    if high > low + 1 {
        return vec![DIGITS[open_digit(low, high, bias)]];
    }
    if let Some(b) = b.filter(|b| b.len() > 1) {
        return vec![b[0]];
    }
    let rest_bias = if b.is_none() { bias } else { Bias::Between };
    let mut key = vec![DIGITS[low]];
    key.extend(midpoint(a.get(1..).unwrap_or_default(), None, rest_bias));
    key
}

fn open_digit(low: usize, high: usize, bias: Bias) -> usize {
    match bias {
        Bias::AfterEverything => low + 1,
        Bias::BeforeEverything => high - 1,
        Bias::Between => (low + high).div_ceil(2),
    }
}

/// `count` evenly spaced, strictly increasing keys with room between every pair.
pub fn rebalance(count: usize) -> Vec<String> {
    let base = BASE as u128;
    let slots = count as u128 + 1;
    let mut width = 1;
    let mut space = base;
    while space < slots * base {
        space *= base;
        width += 1;
    }
    let step = space / slots;
    (1..=count as u128)
        .map(|index| encode(index * step, width))
        .collect()
}

fn encode(mut value: u128, width: usize) -> String {
    let base = BASE as u128;
    let mut digits = vec![b'0'; width];
    for slot in digits.iter_mut().rev() {
        *slot = DIGITS[(value % base) as usize];
        value /= base;
    }
    while digits.last() == Some(&b'0') {
        digits.pop();
    }
    digits.into_iter().map(char::from).collect()
}
