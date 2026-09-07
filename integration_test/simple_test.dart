import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_benchmark/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Can call rust function', (WidgetTester tester) async {
    await tester.pumpWidget(const BenchmarkApp());
    expect(find.text('FRAME / FFI LAB'), findsOneWidget);
    expect(find.text('Run in Rust FFI'), findsOneWidget);
  });
}
