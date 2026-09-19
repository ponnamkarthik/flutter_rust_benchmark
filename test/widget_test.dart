import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:flutter_rust_benchmark/main.dart';
import 'package:flutter_rust_benchmark/image_pipeline_page.dart';

void main() {
  testWidgets('renders the benchmark dashboard', (tester) async {
    await tester.pumpWidget(const BenchmarkApp());

    expect(find.text('FRAME / FFI LAB'), findsOneWidget);
    expect(find.text('LIVE FRAME MONITOR'), findsOneWidget);
    expect(find.text('Run in Rust FFI'), findsOneWidget);
  });

  testWidgets('renders the real image pipeline page', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ImagePipelinePage()),
    );

    expect(find.text('REAL IMAGE PIPELINE'), findsNWidgets(2));
    expect(find.text('PICK FROM GALLERY'), findsOneWidget);
    expect(find.text('Run in Rust FFI'), findsOneWidget);
  });
}
