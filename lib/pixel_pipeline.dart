import 'dart:typed_data';

int _clampChannel(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return value;
}

/// A deliberately multi-stage per-pixel filter used by the image benchmark.
Uint8List processRgbaPixelsInPlace(Uint8List data) {
  for (var offset = 0; offset + 3 < data.length; offset += 4) {
    final red = data[offset];
    final green = data[offset + 1];
    final blue = data[offset + 2];
    final luminance = (red * 77 + green * 150 + blue * 29) >> 8;

    final toneRed = 255 - ((red + luminance) >> 1);
    final toneGreen = 255 - ((green + luminance) >> 1);
    final toneBlue = 255 - ((blue + luminance) >> 1);

    data[offset] = _clampChannel(((toneRed * 6 + luminance * 2) >> 3) + 10);
    data[offset + 1] =
        _clampChannel(((toneGreen * 6 + luminance * 2) >> 3) + 4);
    data[offset + 2] = _clampChannel(((toneBlue * 6 + luminance * 2) >> 3) - 6);
    data[offset + 3] = 255;
  }
  return data;
}
