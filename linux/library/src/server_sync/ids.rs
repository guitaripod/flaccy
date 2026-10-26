const VARIANT: u8 = 0x80;

/// A fresh UUIDv7: 48 bits of Unix milliseconds, then random bits.
pub(crate) fn new_uuid_v7() -> String {
    let millis = crate::db::now_ms().max(0) as u64;
    let mut bytes: [u8; 16] = rand::random();
    bytes[..6].copy_from_slice(&millis.to_be_bytes()[2..]);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | VARIANT;
    format_uuid(&bytes)
}

fn format_uuid(bytes: &[u8; 16]) -> String {
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_ids_are_unique_version_seven_uuids() {
        let first = new_uuid_v7();
        assert_ne!(first, new_uuid_v7());
        assert_eq!(&first[14..15], "7");
    }
}
