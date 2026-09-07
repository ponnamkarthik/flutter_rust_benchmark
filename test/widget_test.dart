import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_rust_benchmark/main.dart';

void main() {
  testWidgets('renders the benchmark dashboard', (tester) async {
    await tester.pumpWidget(const BenchmarkApp());

    expect(find.text('FRAME / FFI LAB'), findsOneWidget);
    expect(find.text('LIVE FRAME MONITOR'), findsOneWidget);
    expect(find.text('Run in Rust FFI'), findsOneWidget);
  });
}
