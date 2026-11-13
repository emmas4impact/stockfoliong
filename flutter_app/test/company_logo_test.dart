import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/stock_logo_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled company logo is registered and contains PNG data', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where(
      (path) => path.startsWith('assets/company_logos/') && path.endsWith('.png'),
    );
    final bundled = paths.map((path) => path.split('/').last.replaceAll('.png', '')).toSet();
    expect(bundled, isNotEmpty);
    expect(curatedStockLogoSymbols, unorderedEquals(bundled));
    for (final symbol in bundled) {
      final bytes = await rootBundle.load(stockLogoAssetPath(symbol));
      expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 8),
          orderedEquals([137, 80, 78, 71, 13, 10, 26, 10]));
    }
  });

  testWidgets('curated logos use local assets without depending on the API', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CompanyLogo(symbol: ' gtco ', useInitials: true)),
    ));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, 'assets/company_logos/GTCO.png');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
