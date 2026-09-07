# Frame / FFI Lab

A Flutter benchmark that makes scheduling visible while processing a selectable 50 MB or 500 MB buffer through three execution paths. It includes two workloads:

- **RGBA frame pipeline:** treats the buffer as packed pixels and performs luminance calculation, color transformation, and alpha normalization. At 500 MB this represents about 131.1 million pixels.
- **Byte inversion:** a simple one-pass memory-bandwidth baseline.

- **Method A:** synchronous pure Dart on the UI isolate, intentionally blocking frame production.
- **Method B:** `compute()` on a background Dart isolate, including isolate transfer in the measurement.
- **Method C:** async Rust through `flutter_rust_bridge` v2, with Rust allocating and processing the selected buffer locally while only metadata crosses the bridge.

The dashboard listens to `WidgetsBinding.instance.addTimingsCallback`, calculates instantaneous FPS from vsync timestamp intervals, counts missed frame slots against the display refresh budget during the timed workload, and flashes its status indicator on jank. Buffer preparation/allocation is excluded from that measured window. Idle/background gaps are not counted as benchmark drops. Each comparison card keeps its own dropped-frame result. The spinner is an `AnimationController`-driven custom painter, so it visibly stops when Method A owns the UI isolate.

## Setup from scratch

Run these commands from the directory that contains this repository:

```bash
cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen create . \
  --integration-backend cargokit \
  --platforms android,ios,linux,macos,windows
cd flutter_rust_benchmark
```

If you are using this checked-out scaffold, the handwritten files are already present. Run the integration step only if the platform build scaffold is missing:

```bash
flutter_rust_bridge_codegen integrate --integration-backend cargokit
```

Install the Dart packages and generate the v2 bridge after editing Rust. `--full-dep` enables FRB's CST/DCO path, which is important for large `Vec<u8>` buffers:

```bash
flutter pub get
flutter_rust_bridge_codegen generate --full-dep
```

The generated files include `lib/src/rust/frb_generated.dart`, the generated Dart API under `lib/src/rust/api/`, and Rust wire glue under `rust/src/frb_generated.rs`. They are ignored by git because the generator owns them.

The dashboard lets you select the workload and 50 MB or 500 MB. It also shows a small processed sample tile so the transformation is visible while the full payload remains off-screen. The original `process_heavy_data_rust(Vec<u8>) -> Vec<u8>` API remains available for round-trip experiments. Rust-owned methods are the direct-memory benchmarks: Rust owns the selected buffer and Dart receives only checksum/timing metadata. The Dart UI and isolate paths can require substantially more transient memory than the selected size because they retain and/or transfer Dart buffers; 500 MB may exceed the memory budget on some phones.

## Run a benchmark

For a physical device or desktop target, use profile or release mode:

```bash
flutter run --profile -d macos
flutter run --profile -d <device-id>
# or
flutter run --release -d <device-id>
```

`flutter run --profile` and `flutter run --release` are not supported by the iOS simulator. For interactive simulator work, use the optimized debug build:

```bash
flutter run -d "iPhone 17"
```

To manually install a release artifact on the simulator:

```bash
flutter build ios --simulator --release
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted com.example.flutterRustBenchmark
```

The Rust crate uses `opt-level = 2` in debug so the interactive demo does not show an accidentally unoptimized native loop. Use a physical iPhone for final profile numbers. Flutter debug/JIT timings are still not directly comparable to production Dart execution.

Tap **Reset** before a run when you want a clean dropped-frame count. Run each method more than once on the same device; the first native invocation may include library warm-up.
