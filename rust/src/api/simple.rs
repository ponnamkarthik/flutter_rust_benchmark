use std::time::Instant;

/// Invert a large byte buffer in-place on an FRB worker thread.
pub fn process_heavy_data_rust(mut data: Vec<u8>) -> Vec<u8> {
    for byte in &mut data {
        *byte = 255 - *byte;
    }
    data
}

/// Process a Rust-owned buffer so only small metadata crosses the bridge.
pub struct RustOwnedBenchmarkResult {
    pub checksum: u32,
    pub processing_micros: u32,
}

fn process_rgba_pixel(pixel: &mut [u8]) {
    let red = pixel[0] as u32;
    let green = pixel[1] as u32;
    let blue = pixel[2] as u32;
    let luminance = (red * 77 + green * 150 + blue * 29) >> 8;

    let tone_red = 255 - ((red + luminance) >> 1);
    let tone_green = 255 - ((green + luminance) >> 1);
    let tone_blue = 255 - ((blue + luminance) >> 1);

    pixel[0] = (((tone_red * 6 + luminance * 2) >> 3) + 10).min(255) as u8;
    pixel[1] = (((tone_green * 6 + luminance * 2) >> 3) + 4).min(255) as u8;
    pixel[2] = ((tone_blue * 6 + luminance * 2) >> 3).saturating_sub(6) as u8;
    pixel[3] = 255;
}

pub fn process_heavy_data_rust_owned(byte_count: u32) -> RustOwnedBenchmarkResult {
    let mut data = vec![0u8; byte_count as usize];
    let started = Instant::now();
    let mut checksum = 0u32;

    for byte in &mut data {
        *byte = 255 - *byte;
        checksum = checksum.wrapping_add(*byte as u32);
    }

    // Keep the native writes observable without sending the 500 MB buffer over FRB.
    std::hint::black_box(&data);

    RustOwnedBenchmarkResult {
        checksum,
        processing_micros: started.elapsed().as_micros().min(u32::MAX as u128) as u32,
    }
}

/// Process a Rust-owned RGBA frame so only small metadata crosses the bridge.
pub fn process_rgba_frame_rust_owned(byte_count: u32) -> RustOwnedBenchmarkResult {
    let mut data = vec![0u8; byte_count as usize];
    let started = Instant::now();
    let mut checksum = 0u32;

    for pixel in data.chunks_exact_mut(4) {
        process_rgba_pixel(pixel);
        checksum = checksum
            .wrapping_add(pixel[0] as u32)
            .wrapping_add(pixel[1] as u32)
            .wrapping_add(pixel[2] as u32)
            .wrapping_add(pixel[3] as u32);
    }

    std::hint::black_box(&data);

    RustOwnedBenchmarkResult {
        checksum,
        processing_micros: started.elapsed().as_micros().min(u32::MAX as u128) as u32,
    }
}

/// Process decoded RGBA pixels and return the transformed image bytes.
pub fn process_rgba_image_rust(mut data: Vec<u8>) -> Vec<u8> {
    for pixel in data.chunks_exact_mut(4) {
        process_rgba_pixel(pixel);
    }
    data
}
