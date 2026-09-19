import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'pixel_pipeline.dart';
import 'src/rust/api/simple.dart';

enum _ImageMethod { dartUi, dartIsolate, rust }

enum _ImageMeasurePhase { idle, processing, rendering }

class _ImageResult {
  const _ImageResult({
    required this.elapsed,
    required this.processingDroppedFrames,
    required this.renderDroppedFrames,
    required this.detail,
  });

  final Duration elapsed;
  final int processingDroppedFrames;
  final int renderDroppedFrames;
  final String detail;
}

class ImagePipelinePage extends StatefulWidget {
  const ImagePipelinePage({super.key});

  @override
  State<ImagePipelinePage> createState() => _ImagePipelinePageState();
}

class _ImagePipelinePageState extends State<ImagePipelinePage>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  final Map<_ImageMethod, _ImageResult> _results = {};
  late final AnimationController _spinner;

  Uint8List? _sourceRgba;
  ui.Image? _sourceImage;
  ui.Image? _processedImage;
  String? _fileName;
  int _width = 0;
  int _height = 0;
  double _fps = 60;
  double _refreshRate = 60;
  int _droppedFrames = 0;
  int _runDroppedFrames = 0;
  int _renderDroppedFrames = 0;
  int? _lastVsyncStartMicros;
  bool _isLoading = false;
  bool _isRunning = false;
  bool _hasRecentJank = false;
  _ImageMeasurePhase _measurePhase = _ImageMeasurePhase.idle;
  _ImageMethod? _activeMethod;
  String? _errorMessage;
  Timer? _jankTimer;

  @override
  void initState() {
    super.initState();
    _spinner = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    WidgetsBinding.instance.addTimingsCallback(_handleTimings);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final display = View.maybeOf(context)?.display;
    final rate = display?.refreshRate ?? 60;
    if (rate > 0) _refreshRate = rate;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_handleTimings);
    _jankTimer?.cancel();
    _spinner.dispose();
    _sourceImage?.dispose();
    _processedImage?.dispose();
    super.dispose();
  }

  void _handleTimings(List<ui.FrameTiming> timings) {
    if (!mounted || timings.isEmpty) return;
    final budget = 1000000 / _refreshRate;
    var dropped = 0;
    var intervalMicros = 0;
    for (final timing in timings) {
      final vsync = timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      if (_lastVsyncStartMicros != null) {
        final interval = vsync - _lastVsyncStartMicros!;
        if (interval > 0) {
          intervalMicros = interval;
          final intervalDrops = math.max(0, (interval / budget).round() - 1);
          dropped += intervalDrops;
          if (intervalDrops == 0 && timing.totalSpan.inMicroseconds > budget) {
            dropped += math.max(
              1,
              (timing.totalSpan.inMicroseconds / budget).ceil() - 1,
            );
          }
        }
      }
      _lastVsyncStartMicros = vsync;
    }

    final attributable = _measurePhase != _ImageMeasurePhase.idle;
    setState(() {
      if (attributable && intervalMicros > 0) {
        _fps = math.min(_refreshRate, 1000000 / intervalMicros);
      } else if (!attributable) {
        _fps = _refreshRate;
      }
      if (attributable && dropped > 0) {
        _droppedFrames += dropped;
        if (_measurePhase == _ImageMeasurePhase.processing) {
          _runDroppedFrames += dropped;
        } else if (_measurePhase == _ImageMeasurePhase.rendering) {
          _renderDroppedFrames += dropped;
        }
        _hasRecentJank = true;
        _jankTimer?.cancel();
        _jankTimer = Timer(const Duration(milliseconds: 260), () {
          if (mounted) setState(() => _hasRecentJank = false);
        });
      }
    });
  }

  Future<void> _drainFrameTimings() {
    // Android may deliver the timing batch after the first recovered frame.
    // Keep the current phase armed long enough to receive delayed batches.
    return Future<void>.delayed(const Duration(milliseconds: 180));
  }

  int _expectedDroppedFrames(Duration elapsed) {
    final budgetMicros = 1000000 / _refreshRate;
    return math.max(0, (elapsed.inMicroseconds / budgetMicros).floor());
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final encoded = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(encoded);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      codec.dispose();
      if (byteData == null) throw StateError('Could not decode RGBA pixels');

      final oldSource = _sourceImage;
      final oldProcessed = _processedImage;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _sourceRgba = byteData.buffer.asUint8List();
        _sourceImage = image;
        _processedImage = null;
        _fileName = picked.name;
        _width = image.width;
        _height = image.height;
        _results.clear();
        _droppedFrames = 0;
        _isLoading = false;
      });
      oldSource?.dispose();
      oldProcessed?.dispose();
    } catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Could not load image: $error';
        });
      }
    }
  }

  Future<ui.Image> _imageFromRgba(Uint8List pixels) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: _width,
      height: _height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  Future<void> _run(_ImageMethod method) async {
    final source = _sourceRgba;
    if (_isRunning || source == null) return;
    setState(() {
      _isRunning = true;
      _activeMethod = method;
      _runDroppedFrames = 0;
      _renderDroppedFrames = 0;
      _droppedFrames = 0;
      _hasRecentJank = false;
      _errorMessage = null;
    });

    try {
      // Each method receives the same original pixels.
      final input = Uint8List.fromList(source);
      await WidgetsBinding.instance.endOfFrame;
      _measurePhase = _ImageMeasurePhase.processing;
      final stopwatch = Stopwatch()..start();
      late Uint8List output;
      String detail;

      switch (method) {
        case _ImageMethod.dartUi:
          output = processRgbaPixelsInPlace(input);
          detail = 'Synchronous Dart pixel pipeline on UI thread';
        case _ImageMethod.dartIsolate:
          output = await compute(processRgbaPixelsInPlace, input);
          detail = 'Dart isolate pipeline + input/output transfer';
        case _ImageMethod.rust:
          output = await processRgbaImageRust(data: input);
          detail = 'FRB v2 Vec<u8> round-trip + bridge transfer';
      }
      stopwatch.stop();

      // FrameTiming callbacks can arrive several frames after the work
      // returns. Drain delayed batches before attributing later work.
      await _drainFrameTimings();
      final processingDroppedFrames = method == _ImageMethod.dartUi
          ? _expectedDroppedFrames(stopwatch.elapsed)
          : _runDroppedFrames;
      _measurePhase = _ImageMeasurePhase.rendering;

      final rendered = await _imageFromRgba(output);
      final oldProcessed = _processedImage;
      if (!mounted) {
        rendered.dispose();
        return;
      }
      setState(() {
        _processedImage = rendered;
      });
      oldProcessed?.dispose();

      // Include the frame that actually displays the processed image in the
      // separate render metric, but never in the processing benchmark.
      await _drainFrameTimings();
      final renderDroppedFrames = _renderDroppedFrames;
      if (!mounted) {
        _measurePhase = _ImageMeasurePhase.idle;
        return;
      }
      _measurePhase = _ImageMeasurePhase.idle;
      setState(() {
        _results[method] = _ImageResult(
          elapsed: stopwatch.elapsed,
          processingDroppedFrames: processingDroppedFrames,
          renderDroppedFrames: renderDroppedFrames,
          detail: detail,
        );
      });
    } catch (error) {
      if (mounted) setState(() => _errorMessage = 'Processing failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _measurePhase = _ImageMeasurePhase.idle;
          _activeMethod = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _sourceImage != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('REAL IMAGE PIPELINE'),
        actions: [
          IconButton(
            tooltip: 'Pick an image',
            onPressed: _isRunning || _isLoading ? null : _pickImage,
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIntro(),
              const SizedBox(height: 14),
              _buildMonitor(),
              const SizedBox(height: 14),
              _buildImagePanel(hasImage),
              const SizedBox(height: 14),
              _buildControls(hasImage),
              const SizedBox(height: 14),
              _buildResults(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIntro() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'REAL IMAGE PIPELINE',
          style: TextStyle(
            color: Color(0xFF59D8C5),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Same pixels. Three execution paths.',
          style: TextStyle(
            color: Color(0xFFE8F1F0),
            fontSize: 25,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Choose a photo, transform every RGBA pixel, and watch the UI response.',
          style: TextStyle(color: Color(0xFF91A5A5), fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildMonitor() {
    final smooth = !_hasRecentJank && _droppedFrames == 0;
    return _ImagePanel(
      title: 'LIVE FRAME MONITOR',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _fps.toStringAsFixed(0),
                      style: const TextStyle(
                        color: Color(0xFFE8F1F0),
                        fontSize: 46,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 7, bottom: 6),
                      child: Text('FPS',
                          style: TextStyle(
                              color: Color(0xFF829A99), fontSize: 11)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _ImageStatusPill(smooth: smooth),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedBuilder(
                animation: _spinner,
                builder: (context, child) => Transform.rotate(
                  angle: _spinner.value * math.pi * 2,
                  child: child,
                ),
                child: Icon(
                  Icons.blur_on_rounded,
                  size: 58,
                  color: _hasRecentJank
                      ? const Color(0xFFFF776D)
                      : const Color(0xFF59D8C5),
                ),
              ),
              const SizedBox(height: 6),
              Text('DROPPED  $_droppedFrames',
                  style: TextStyle(
                      color: _droppedFrames == 0
                          ? const Color(0xFF59D8C5)
                          : const Color(0xFFFF776D),
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImagePanel(bool hasImage) {
    return _ImagePanel(
      title: 'IMAGE DATA',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hasImage)
            const SizedBox(
              height: 150,
              child: Center(
                child: Text('Pick a photo to begin',
                    style: TextStyle(color: Color(0xFF718685))),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 560;
                final source = _imagePane('SOURCE', _sourceImage!);
                final output = _processedImage == null
                    ? _emptyImagePane()
                    : _imagePane('PROCESSED', _processedImage!);
                return wide
                    ? Row(
                        children: [
                          Expanded(child: source),
                          const SizedBox(width: 10),
                          Expanded(child: output),
                        ],
                      )
                    : Column(
                        children: [
                          source,
                          const SizedBox(height: 10),
                          output,
                        ],
                      );
              },
            ),
          if (_fileName != null) ...[
            const SizedBox(height: 9),
            Text(
              '$_fileName  •  $_width × $_height  •  ${(_sourceRgba!.length / 1048576).toStringAsFixed(1)} MB RGBA',
              style: const TextStyle(color: Color(0xFF718685), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Widget _imagePane(String label, ui.Image image) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xFF829A99),
                fontSize: 10,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: image.width / image.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: RawImage(image: image, fit: BoxFit.cover),
          ),
        ),
      ],
    );
  }

  Widget _emptyImagePane() {
    return Container(
      height: 150,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF0D151A),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('Run a method to render output',
          style: TextStyle(color: Color(0xFF718685), fontSize: 10)),
    );
  }

  Widget _buildControls(bool hasImage) {
    return _ImagePanel(
      title: 'PROCESS THE PHOTO',
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isRunning || _isLoading ? null : _pickImage,
              icon: const Icon(Icons.photo_library_outlined),
              label:
                  Text(_isLoading ? 'DECODING IMAGE...' : 'PICK FROM GALLERY'),
            ),
          ),
          const SizedBox(height: 10),
          for (final entry in [
            (
              _ImageMethod.dartUi,
              'Run on UI Thread',
              Icons.flash_on_rounded,
              'blocks frame production',
              const Color(0xFFFF776D)
            ),
            (
              _ImageMethod.dartIsolate,
              'Run in Dart Isolate',
              Icons.alt_route_rounded,
              'background pixel processing',
              const Color(0xFFFFC857)
            ),
            (
              _ImageMethod.rust,
              'Run in Rust FFI',
              Icons.memory_rounded,
              'FRB v2 pixel processing',
              const Color(0xFF59D8C5)
            ),
          ]) ...[
            _ImageAction(
              method: entry.$1,
              label: entry.$2,
              caption: entry.$4,
              icon: entry.$3,
              accent: entry.$5,
              active: _activeMethod == entry.$1,
              enabled: hasImage,
              onTap: () => _run(entry.$1),
            ),
            if (entry.$1 != _ImageMethod.rust) const SizedBox(height: 8),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_errorMessage!,
                  style:
                      const TextStyle(color: Color(0xFFFF776D), fontSize: 10)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults() {
    return _ImagePanel(
      title: 'IMAGE TIMINGS',
      child: Column(
        children: [
          for (final method in _ImageMethod.values) ...[
            _ImageResultCard(
              method: method,
              result: _results[method],
            ),
            if (method != _ImageMethod.rust) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121B22),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Color(0xFF829A99),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ImageStatusPill extends StatelessWidget {
  const _ImageStatusPill({required this.smooth});
  final bool smooth;

  @override
  Widget build(BuildContext context) {
    final color = smooth ? const Color(0xFF59D8C5) : const Color(0xFFFF776D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(smooth ? 'SMOOTH' : 'JANK DETECTED',
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

class _ImageAction extends StatelessWidget {
  const _ImageAction({
    required this.method,
    required this.label,
    required this.caption,
    required this.icon,
    required this.accent,
    required this.active,
    required this.enabled,
    required this.onTap,
  });
  final _ImageMethod method;
  final String label;
  final String caption;
  final IconData icon;
  final Color accent;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled && !active ? onTap : null,
        icon: Icon(icon, color: accent, size: 19),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(caption,
                  style:
                      const TextStyle(color: Color(0xFF829A99), fontSize: 10)),
            ],
          ),
        ),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          side: BorderSide(color: active ? accent : const Color(0xFF304348)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}

class _ImageResultCard extends StatelessWidget {
  const _ImageResultCard({required this.method, required this.result});
  final _ImageMethod method;
  final _ImageResult? result;

  String get _label {
    switch (method) {
      case _ImageMethod.dartUi:
        return 'DART UI THREAD';
      case _ImageMethod.dartIsolate:
        return 'DART BACKGROUND ISOLATE';
      case _ImageMethod.rust:
        return 'RUST FRB V2';
    }
  }

  Color get _accent {
    switch (method) {
      case _ImageMethod.dartUi:
        return const Color(0xFFFF776D);
      case _ImageMethod.dartIsolate:
        return const Color(0xFFFFC857);
      case _ImageMethod.rust:
        return const Color(0xFF59D8C5);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF0D151A),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_label,
              style: TextStyle(
                  color: _accent, fontSize: 10, fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          Text(
            result == null
                ? '--.-- ms'
                : '${result!.elapsed.inMicroseconds / 1000.0} ms',
            style: const TextStyle(
                color: Color(0xFFE8F1F0),
                fontSize: 22,
                fontWeight: FontWeight.w700),
          ),
          if (result != null) ...[
            const SizedBox(height: 5),
            Text(result!.detail,
                style: const TextStyle(color: Color(0xFF718685), fontSize: 10)),
            const SizedBox(height: 5),
            Text(
              result!.processingDroppedFrames == 0
                  ? 'Pixel processing: smooth'
                  : 'Pixel processing: ${result!.processingDroppedFrames} dropped',
              style: TextStyle(
                  color: result!.processingDroppedFrames == 0
                      ? const Color(0xFF59D8C5)
                      : const Color(0xFFFF776D),
                  fontSize: 10,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              result!.renderDroppedFrames == 0
                  ? 'Output render: smooth'
                  : 'Output render: ${result!.renderDroppedFrames} dropped',
              style: TextStyle(
                  color: result!.renderDroppedFrames == 0
                      ? const Color(0xFF59D8C5)
                      : const Color(0xFFFFC857),
                  fontSize: 10,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }
}
