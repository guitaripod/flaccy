pub fn fnv1a_64(seed: &str) -> u64 {
    let mut hash: u64 = 1_469_598_103_934_665_603;
    for byte in seed.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    hash
}

/// Deterministic two-stop placeholder gradient identical to iOS/watchOS:
/// FNV-1a of the seed → hue=(hash%360)/360, stop one HSB(hue, .45, .55),
/// stop two HSB(hue+.08 mod 1, .5, .35).
pub fn placeholder_colors(seed: &str) -> ((u8, u8, u8), (u8, u8, u8)) {
    let hash = fnv1a_64(seed);
    let hue = (hash % 360) as f64 / 360.0;
    let first = hsb_to_rgb(hue, 0.45, 0.55);
    let second = hsb_to_rgb((hue + 0.08) % 1.0, 0.5, 0.35);
    (first, second)
}

pub fn hsb_to_rgb(hue: f64, saturation: f64, brightness: f64) -> (u8, u8, u8) {
    let h = (hue.fract() + 1.0).fract() * 6.0;
    let sector = h.floor() as i32 % 6;
    let f = h - h.floor();
    let p = brightness * (1.0 - saturation);
    let q = brightness * (1.0 - saturation * f);
    let t = brightness * (1.0 - saturation * (1.0 - f));
    let (r, g, b) = match sector {
        0 => (brightness, t, p),
        1 => (q, brightness, p),
        2 => (p, brightness, t),
        3 => (p, q, brightness),
        4 => (t, p, brightness),
        _ => (brightness, p, q),
    };
    (
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8,
    )
}

/// Diagonal top-leading → bottom-trailing gradient pixels for a placeholder tile.
pub fn placeholder_rgba(seed: &str, size: u32) -> Vec<u8> {
    let ((r1, g1, b1), (r2, g2, b2)) = placeholder_colors(seed);
    let mut data = Vec::with_capacity((size * size * 4) as usize);
    let span = (2 * (size.max(2) - 1)) as f64;
    for y in 0..size {
        for x in 0..size {
            let t = (x + y) as f64 / span;
            data.push(lerp(r1, r2, t));
            data.push(lerp(g1, g2, t));
            data.push(lerp(b1, b2, t));
            data.push(255);
        }
    }
    data
}

fn lerp(a: u8, b: u8, t: f64) -> u8 {
    (a as f64 + (b as f64 - a as f64) * t).round() as u8
}

/// k-means-lite dominant color mirroring ArtworkPalette: 24x24 downsample,
/// k=4, exactly 6 iterations, returns the centroid of the largest cluster.
pub fn dominant_color(rgba: &[u8], width: u32, height: u32) -> (u8, u8, u8) {
    let mut pixels: Vec<[f64; 3]> = Vec::new();
    if width == 0 || height == 0 {
        return (72, 72, 96);
    }
    for y in 0..24u32 {
        for x in 0..24u32 {
            let sx = x * width / 24;
            let sy = y * height / 24;
            let idx = ((sy * width + sx) * 4) as usize;
            if idx + 2 < rgba.len() {
                pixels.push([
                    rgba[idx] as f64,
                    rgba[idx + 1] as f64,
                    rgba[idx + 2] as f64,
                ]);
            }
        }
    }
    if pixels.is_empty() {
        return (72, 72, 96);
    }
    let k = 4usize.min(pixels.len());
    let mut centroids: Vec<[f64; 3]> = (0..k)
        .map(|i| pixels[i * pixels.len() / k])
        .collect();
    let mut assignments = vec![0usize; pixels.len()];
    for _ in 0..6 {
        for (pi, pixel) in pixels.iter().enumerate() {
            let mut best = 0;
            let mut best_dist = f64::MAX;
            for (ci, centroid) in centroids.iter().enumerate() {
                let dist = (0..3).map(|c| (pixel[c] - centroid[c]).powi(2)).sum();
                if dist < best_dist {
                    best_dist = dist;
                    best = ci;
                }
            }
            assignments[pi] = best;
        }
        for (ci, centroid) in centroids.iter_mut().enumerate() {
            let members: Vec<&[f64; 3]> = pixels
                .iter()
                .zip(&assignments)
                .filter(|(_, a)| **a == ci)
                .map(|(p, _)| p)
                .collect();
            if members.is_empty() {
                continue;
            }
            for c in 0..3 {
                centroid[c] = members.iter().map(|m| m[c]).sum::<f64>() / members.len() as f64;
            }
        }
    }
    let mut counts = vec![0usize; k];
    for a in &assignments {
        counts[*a] += 1;
    }
    let winner = counts
        .iter()
        .enumerate()
        .max_by_key(|(_, c)| **c)
        .map(|(i, _)| i)
        .unwrap_or(0);
    (
        centroids[winner][0].round() as u8,
        centroids[winner][1].round() as u8,
        centroids[winner][2].round() as u8,
    )
}
