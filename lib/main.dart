import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const int _defaultPayloadSize = 50 * 1024 * 1024;
const int _stressPayloadSize = 500 * 1024 * 1024;
const double _defaultRefreshRate = 60;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const BenchmarkApp());
}

Uint8List _invertInIsolate(Uint8List data) {
  for (var index = 0; index < data.length; index++) {
    data[index] = 255 - data[index];
  }
  return data;
}

Uint8List _processRgbaFrameInIsolate(Uint8List data) {
  for (var offset = 0; offset + 3 < data.length; offset += 4) {
    final red = data[offset];
    final green = data[offset + 1];
    final blue = data[offset + 2];
    final luminance = (red * 77 + green * 150 + blue * 29) >> 8;

    data[offset] = 255 - ((red + luminance) ~/ 2);
    data[offset + 1] = 255 - ((green + luminance) ~/ 2);
    data[offset + 2] = 255 - ((blue + luminance) ~/ 2);
    data[offset + 3] = 255;
  }
  return data;
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Frame / FFI Lab',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1117),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF59D8C5),
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF121B22),
          onSurface: const Color(0xFFE8F1F0),
        ),
        fontFamily: 'monospace',
        useMaterial3: true,
      ),
      home: const BenchmarkPage(),
    );
  }
}

enum _BenchmarkMethod { dartUi, dartIsolate, rust }

enum _Workload { byteInvert, rgbaFrame }

class _Result {
  const _Result({
    required this.elapsed,
    required this.detail,
    required this.droppedFrames,
    this.secondary,
  });
  final Duration elapsed;
  final String detail;
  final int droppedFrames;
  final String? secondary;

  _Result copyWith({int? droppedFrames}) => _Result(
        elapsed: elapsed,
        detail: detail,
        droppedFrames: droppedFrames ?? this.droppedFrames,
        secondary: secondary,
      );
}

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});
  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motionController;
  final Map<_BenchmarkMethod, _Result> _results = {};
  Uint8List? _payload;
  int _payloadSize = _defaultPayloadSize;
  _Workload _workload = _Workload.rgbaFrame;
  double _fps = _defaultRefreshRate;
  double _refreshRate = _defaultRefreshRate;
  int _droppedFrames = 0;
  bool _isRunning = false;
  bool _isMeasuring = false;
  bool _isPreparing = false;
  bool _hasRecentJank = false;
  bool _hasProcessedSample = false;
  _BenchmarkMethod? _activeMethod;
  _BenchmarkMethod? _lastCompletedMethod;
  int _currentRunDroppedFrames = 0;
  int? _lastVsyncStartMicros;
  String? _errorMessage;
  Timer? _jankResetTimer;
  @override
  void initState() {
    super.initState();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    WidgetsBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final display = View.maybeOf(context)?.display;
    final refreshRate = display?.refreshRate ?? _defaultRefreshRate;
    if (refreshRate > 0) _refreshRate = refreshRate;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_handleFrameTimings);
    _jankResetTimer?.cancel();
    _motionController.dispose();
    super.dispose();
  }

  Uint8List _makePayload() {
    // Uint8List is already zero-initialized; the benchmark transforms every byte.
    return Uint8List(_payloadSize);
  }

  Future<Uint8List> _ensurePayload() async {
    final current = _payload;
    if (current != null && current.length == _payloadSize) return current;

    setState(() => _isPreparing = true);
    // Let the preparation state render before a large allocation.
    await Future<void>.delayed(Duration.zero);
    final data = _makePayload();
    if (mounted) {
      setState(() {
        _payload = data;
        _isPreparing = false;
      });
    }
    return data;
  }

  void _selectPayloadSize(int size) {
    if (_isRunning || _isPreparing || size == _payloadSize) return;
    setState(() {
      _payloadSize = size;
      _payload = null;
      _results.clear();
      _errorMessage = null;
      _hasProcessedSample = false;
    });
  }

  void _selectWorkload(_Workload workload) {
    if (_isRunning || _isPreparing || workload == _workload) return;
    setState(() {
      _workload = workload;
      _payload = null;
      _results.clear();
      _errorMessage = null;
      _hasProcessedSample = false;
    });
  }

  void _handleFrameTimings(List<ui.FrameTiming> timings) {
    if (!mounted || timings.isEmpty) return;
    final budgetMicros = 1000000 / _refreshRate;
    var dropped = 0;
    var lastIntervalMicros = 0;
    for (final timing in timings) {
      final vsyncStart =
          timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      if (_lastVsyncStartMicros != null) {
        final interval = vsyncStart - _lastVsyncStartMicros!;
        if (interval > 0) {
          lastIntervalMicros = interval;
          final intervalDrops = math.max(
            0,
            (interval / budgetMicros).round() - 1,
          );
          dropped += intervalDrops;
          if (intervalDrops == 0 &&
              timing.totalSpan.inMicroseconds > budgetMicros) {
            dropped += math.max(
              1,
              (timing.totalSpan.inMicroseconds / budgetMicros).ceil() - 1,
            );
          }
        }
      }
      _lastVsyncStartMicros = vsyncStart;
    }

    final methodWithLateTiming = _isRunning ? null : _lastCompletedMethod;
    final hasRunAttribution = _isMeasuring || methodWithLateTiming != null;
    setState(() {
      if (lastIntervalMicros > 0 && hasRunAttribution) {
        _fps = math.min(_refreshRate, 1000000 / lastIntervalMicros);
      } else if (!hasRunAttribution) {
        _fps = _refreshRate;
      }
      if (dropped > 0 && hasRunAttribution) {
        _droppedFrames += dropped;
        if (_isMeasuring) _currentRunDroppedFrames += dropped;
        if (methodWithLateTiming != null &&
            _results[methodWithLateTiming] != null) {
          final result = _results[methodWithLateTiming]!;
          _results[methodWithLateTiming] =
              result.copyWith(droppedFrames: result.droppedFrames + dropped);
        }
        _hasRecentJank = true;
        _jankResetTimer?.cancel();
        _jankResetTimer = Timer(const Duration(milliseconds: 260), () {
          if (mounted) setState(() => _hasRecentJank = false);
        });
      }
      // Attribute only the first timing batch after a run to that run.
      if (!_isRunning && methodWithLateTiming != null) {
        _lastCompletedMethod = null;
      }
    });
  }

  void _resetDroppedFrames() {
    setState(() {
      _droppedFrames = 0;
      _hasRecentJank = false;
    });
  }

  Future<void> _run(_BenchmarkMethod method) async {
    if (_isRunning) return;
    _resetDroppedFrames();
    setState(() {
      _isRunning = true;
      _isMeasuring = false;
      _activeMethod = method;
      _lastCompletedMethod = null;
      _currentRunDroppedFrames = 0;
      _errorMessage = null;
    });
    try {
      Uint8List? output;
      Uint8List? input;
      if (method != _BenchmarkMethod.rust) {
        input = await _ensurePayload();
      } else if (_payload != null) {
        // Do not retain a large Dart allocation while Rust owns its buffer.
        setState(() => _payload = null);
        await Future<void>.delayed(Duration.zero);
      }

      // Preparation/allocation is intentionally excluded from the measured run.
      _resetDroppedFrames();
      _currentRunDroppedFrames = 0;
      await WidgetsBinding.instance.endOfFrame;
      _isMeasuring = true;

      final stopwatch = Stopwatch()..start();
      var detail = '';
      String? secondary;
      switch (method) {
        case _BenchmarkMethod.dartUi:
          output = _processDartPayload(input!);
          detail = 'Synchronous on UI isolate • $_workloadLabel';
        case _BenchmarkMethod.dartIsolate:
          output = await _processDartPayloadInIsolate(input!);
          detail = 'Includes isolate transfer • $_workloadLabel';
        case _BenchmarkMethod.rust:
          final rustResult = _workload == _Workload.rgbaFrame
              ? await processRgbaFrameRustOwned(byteCount: _payloadSize)
              : await processHeavyDataRustOwned(byteCount: _payloadSize);
          detail = 'Rust-owned $_payloadMegabytes MB buffer • $_workloadLabel';
          secondary =
              'Native loop: ${(rustResult.processingMicros / 1000).toStringAsFixed(3)} ms';
      }
      stopwatch.stop();
      if (output != null && output.isNotEmpty && output[0] == 999) {
        debugPrint('unreachable sentinel: ${output.length}');
      }
      if (output != null && method != _BenchmarkMethod.dartUi) {
        _payload = output;
      }
      if (!mounted) return;
      setState(() {
        _results[method] = _Result(
          elapsed: stopwatch.elapsed,
          detail: detail,
          droppedFrames: _currentRunDroppedFrames,
          secondary: secondary,
        );
        _hasProcessedSample = true;
        _lastCompletedMethod = method;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Could not allocate or process $_payloadMegabytes MB: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _isMeasuring = false;
          _activeMethod = null;
          _isPreparing = false;
        });
      }
    }
  }

  int get _payloadMegabytes => _payloadSize ~/ (1024 * 1024);

  String get _workloadLabel => _workload == _Workload.rgbaFrame
      ? 'RGBA frame pipeline'
      : 'byte inversion';

  String get _workloadSummary => _workload == _Workload.rgbaFrame
      ? '$_pixelCountLabel pixels • luminance + color transform + alpha normalization'
      : '$_payloadMegabytes MB • one-pass memory bandwidth baseline';

  String get _pixelCountLabel =>
      '${(_payloadSize / 4 / 1000000).toStringAsFixed(1)}M';

  Uint8List _processDartPayload(Uint8List data) =>
      _workload == _Workload.rgbaFrame
          ? _processRgbaFrameInIsolate(data)
          : _invertInIsolate(data);

  Future<Uint8List> _processDartPayloadInIsolate(Uint8List data) =>
      _workload == _Workload.rgbaFrame
          ? compute(_processRgbaFrameInIsolate, data)
          : compute(_invertInIsolate, data);

  String _methodLabel(_BenchmarkMethod method) {
    switch (method) {
      case _BenchmarkMethod.dartUi:
        return 'Method A  /  UI isolate';
      case _BenchmarkMethod.dartIsolate:
        return 'Method B  /  compute()';
      case _BenchmarkMethod.rust:
        return 'Method C  /  Rust FFI';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: wide ? _buildWideLayout() : _buildNarrowLayout(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 4, child: _buildMonitorPanel()),
            const SizedBox(width: 16),
            Expanded(flex: 6, child: _buildBenchmarkPanel()),
          ],
        ),
        const SizedBox(height: 16),
        _buildResultsPanel(),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const SizedBox(height: 18),
        _buildMonitorPanel(),
        const SizedBox(height: 14),
        _buildBenchmarkPanel(),
        const SizedBox(height: 14),
        _buildResultsPanel(),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 10,
          height: 48,
          margin: const EdgeInsets.only(right: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF59D8C5),
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FRAME / FFI LAB',
                style: TextStyle(
                  color: Color(0xFF59D8C5),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Does the UI keep breathing?',
                style: TextStyle(
                  color: Color(0xFFE8F1F0),
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'A $_payloadMegabytes MB $_workloadLabel benchmark for Dart scheduling and Rust offload.',
                style: TextStyle(color: Color(0xFF91A5A5), fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _buildPayloadBadge(),
            const SizedBox(height: 7),
            _buildBuildModeBadge(),
          ],
        ),
      ],
    );
  }

  Widget _buildPayloadBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF172329),
        border: Border.all(color: const Color(0xFF2B4548)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('PAYLOAD',
              style: TextStyle(color: Color(0xFF829A99), fontSize: 9)),
          SizedBox(height: 3),
          Text('$_payloadMegabytes MB',
              style: TextStyle(
                  color: Color(0xFFE8F1F0),
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildBuildModeBadge() {
    final mode = kReleaseMode
        ? 'RELEASE'
        : kProfileMode
            ? 'PROFILE'
            : 'DEBUG';
    final color =
        kDebugMode ? const Color(0xFFFFC857) : const Color(0xFF59D8C5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        'BUILD: $mode',
        style:
            TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildMonitorPanel() {
    return _Panel(
      title: 'LIVE FRAME MONITOR',
      trailing: IconButton(
        tooltip: 'Reset dropped frames',
        onPressed: _isRunning ? null : _resetDroppedFrames,
        icon: const Icon(Icons.refresh_rounded, size: 18),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildFpsReadout()),
              const SizedBox(width: 12),
              _buildPulseSpinner(),
            ],
          ),
          const SizedBox(height: 18),
          _buildFrameSample(),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  label: 'DROPPED FRAMES',
                  value: '$_droppedFrames',
                  valueColor: _droppedFrames == 0
                      ? const Color(0xFF59D8C5)
                      : const Color(0xFFFF776D),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(
                  label: 'TARGET',
                  value: '${_refreshRate.toStringAsFixed(0)} Hz',
                  valueColor: const Color(0xFFE8F1F0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Jank threshold: ${(1000 / _refreshRate).toStringAsFixed(1)} ms per frame',
              style: const TextStyle(color: Color(0xFF718685), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFrameSample() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D151A),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          CustomPaint(
            size: const Size(108, 62),
            painter: _FrameSamplePainter(
              processed: _hasProcessedSample,
              workload: _workload,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hasProcessedSample ? 'PROCESSED SAMPLE' : 'INPUT SAMPLE',
                  style: TextStyle(
                    color: _hasProcessedSample
                        ? const Color(0xFF59D8C5)
                        : const Color(0xFF829A99),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _workload == _Workload.rgbaFrame
                      ? 'RGBA / $_pixelCountLabel pixels'
                      : 'Byte stream / $_payloadMegabytes MB',
                  style:
                      const TextStyle(color: Color(0xFF718685), fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFpsReadout() {
    final smooth = !_hasRecentJank && _droppedFrames == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _fps.toStringAsFixed(0),
              style: const TextStyle(
                color: Color(0xFFE8F1F0),
                fontSize: 52,
                fontWeight: FontWeight.w700,
                height: 0.95,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 8, bottom: 5),
              child: Text('FPS',
                  style: TextStyle(color: Color(0xFF829A99), fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _StatusPill(smooth: smooth),
      ],
    );
  }

  Widget _buildPulseSpinner() {
    return AnimatedBuilder(
      animation: _motionController,
      builder: (context, child) {
        return SizedBox(
          width: 92,
          height: 92,
          child: CustomPaint(
            painter: _SpinnerPainter(
              progress: _motionController.value,
              color: _hasRecentJank
                  ? const Color(0xFFFF776D)
                  : const Color(0xFF59D8C5),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBenchmarkPanel() {
    return _Panel(
      title: 'RUN A CONTROLLED SAMPLE',
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'WORKLOAD',
              style: const TextStyle(
                color: Color(0xFF829A99),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Workload>(
              segments: const [
                ButtonSegment<_Workload>(
                  value: _Workload.rgbaFrame,
                  label: Text('RGBA FRAME PIPELINE'),
                ),
                ButtonSegment<_Workload>(
                  value: _Workload.byteInvert,
                  label: Text('BYTE INVERSION'),
                ),
              ],
              selected: {_workload},
              onSelectionChanged: (selection) =>
                  _selectWorkload(selection.first),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _workloadSummary,
              style: const TextStyle(color: Color(0xFF718685), fontSize: 10),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'PAYLOAD SIZE',
              style: const TextStyle(
                color: Color(0xFF829A99),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(
                    value: _defaultPayloadSize, label: Text('50 MB')),
                ButtonSegment<int>(
                    value: _stressPayloadSize, label: Text('500 MB')),
              ],
              selected: {_payloadSize},
              onSelectionChanged: (selection) =>
                  _selectPayloadSize(selection.first),
            ),
          ),
          const SizedBox(height: 9),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              kDebugMode
                  ? 'DEBUG build: use --release for comparable benchmark numbers; Rust dev code is optimized for the demo.'
                  : _payloadSize == _stressPayloadSize
                      ? '500 MB stress mode may require more than 1 GB transient memory on Dart paths.'
                      : 'Dart buffer is allocated only when a Dart method starts.',
              style: TextStyle(
                color: kDebugMode
                    ? const Color(0xFFFFC857)
                    : _payloadSize == _stressPayloadSize
                        ? const Color(0xFFFFC857)
                        : const Color(0xFF718685),
                fontSize: 10,
              ),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 9),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Color(0xFFFF776D), fontSize: 10),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _BenchmarkButton(
            accent: const Color(0xFFFF776D),
            icon: Icons.flash_on_rounded,
            label: 'Run on UI Thread',
            caption: 'Pure Dart • blocks frame production',
            isActive: _activeMethod == _BenchmarkMethod.dartUi,
            onPressed: () => _run(_BenchmarkMethod.dartUi),
          ),
          const SizedBox(height: 9),
          _BenchmarkButton(
            accent: const Color(0xFFFFC857),
            icon: Icons.alt_route_rounded,
            label: 'Run in Dart Isolate',
            caption: 'compute() • measures memory transit',
            isActive: _activeMethod == _BenchmarkMethod.dartIsolate,
            onPressed: () => _run(_BenchmarkMethod.dartIsolate),
          ),
          const SizedBox(height: 9),
          _BenchmarkButton(
            accent: const Color(0xFF59D8C5),
            icon: Icons.memory_rounded,
            label: 'Run in Rust FFI',
            caption: 'FRB v2 • Rust-owned buffer, metadata only',
            isActive: _activeMethod == _BenchmarkMethod.rust,
            onPressed: () => _run(_BenchmarkMethod.rust),
          ),
          if (_isRunning || _isPreparing) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFF59D8C5),
              backgroundColor: Color(0xFF243338),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultsPanel() {
    return _Panel(
      title: 'COMPARISON',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final cards = [
            _ResultCard(
              label: _methodLabel(_BenchmarkMethod.dartUi),
              result: _results[_BenchmarkMethod.dartUi],
              accent: const Color(0xFFFF776D),
            ),
            _ResultCard(
              label: _methodLabel(_BenchmarkMethod.dartIsolate),
              result: _results[_BenchmarkMethod.dartIsolate],
              accent: const Color(0xFFFFC857),
            ),
            _ResultCard(
              label: _methodLabel(_BenchmarkMethod.rust),
              result: _results[_BenchmarkMethod.rust],
              accent: const Color(0xFF59D8C5),
            ),
          ];
          if (compact) {
            return Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 9),
                  cards[i],
                ],
              ],
            );
          }
          return Row(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: cards[i]),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF121B22),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF829A99),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile(
      {required this.label, required this.value, required this.valueColor});
  final String label;
  final String value;
  final Color valueColor;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D151A),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF718685), fontSize: 9)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.smooth});
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(
            smooth ? 'SMOOTH' : 'JANK DETECTED',
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _BenchmarkButton extends StatelessWidget {
  const _BenchmarkButton({
    required this.accent,
    required this.icon,
    required this.label,
    required this.caption,
    required this.isActive,
    required this.onPressed,
  });
  final Color accent;
  final IconData icon;
  final String label;
  final String caption;
  final bool isActive;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isActive ? null : onPressed,
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
          side: BorderSide(color: isActive ? accent : const Color(0xFF304348)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard(
      {required this.label, required this.result, required this.accent});
  final String label;
  final _Result? result;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D151A),
        border: Border.all(color: const Color(0xFF26383D)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: accent, fontSize: 10, fontWeight: FontWeight.w700)),
          const SizedBox(height: 11),
          Text(
            result == null
                ? '--.-- ms'
                : '${result!.elapsed.inMicroseconds / 1000.0} ms',
            style: const TextStyle(
                color: Color(0xFFE8F1F0),
                fontSize: 23,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(result?.detail ?? 'Run this method to record a sample',
              style: const TextStyle(color: Color(0xFF718685), fontSize: 10)),
          if (result != null) ...[
            const SizedBox(height: 7),
            Text(
              result!.droppedFrames == 0
                  ? 'Frame impact: smooth'
                  : 'Frame impact: ${result!.droppedFrames} dropped',
              style: TextStyle(
                color: result!.droppedFrames == 0
                    ? const Color(0xFF59D8C5)
                    : const Color(0xFFFF776D),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (result?.secondary != null) ...[
            const SizedBox(height: 5),
            Text(result!.secondary!,
                style: TextStyle(color: accent, fontSize: 10)),
          ],
        ],
      ),
    );
  }
}

class _FrameSamplePainter extends CustomPainter {
  const _FrameSamplePainter({required this.processed, required this.workload});
  final bool processed;
  final _Workload workload;

  @override
  void paint(Canvas canvas, Size size) {
    const columns = 8;
    const rows = 4;
    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    final paint = Paint();

    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final red = (x * 37 + y * 61 + 32) & 0xFF;
        final green = (x * 19 + y * 47 + 88) & 0xFF;
        final blue = (x * 53 + y * 23 + 144) & 0xFF;
        var outputRed = red;
        var outputGreen = green;
        var outputBlue = blue;

        if (processed && workload == _Workload.byteInvert) {
          outputRed = 255 - red;
          outputGreen = 255 - green;
          outputBlue = 255 - blue;
        } else if (processed) {
          final luminance = (red * 77 + green * 150 + blue * 29) >> 8;
          outputRed = 255 - ((red + luminance) ~/ 2);
          outputGreen = 255 - ((green + luminance) ~/ 2);
          outputBlue = 255 - ((blue + luminance) ~/ 2);
        }

        paint.color = Color.fromARGB(255, outputRed, outputGreen, outputBlue);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x * cellWidth + 1,
            y * cellHeight + 1,
            cellWidth - 2,
            cellHeight - 2,
          ),
          const Radius.circular(2),
        );
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FrameSamplePainter oldDelegate) =>
      oldDelegate.processed != processed || oldDelegate.workload != workload;
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter({required this.progress, required this.color});
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.35;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final angle = progress * math.pi * 2 + i * math.pi / 6;
      final opacity = 0.2 + ((i + (progress * 12).floor()) % 12) / 12 * 0.8;
      paint
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = i.isEven ? 4 : 2.5;
      final start = Offset(
        center.dx + math.cos(angle) * radius * 0.56,
        center.dy + math.sin(angle) * radius * 0.56,
      );
      final end = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      canvas.drawLine(start, end, paint);
    }
    paint
      ..color = color.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.36, paint);
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
