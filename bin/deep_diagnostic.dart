import 'package:http/http.dart' as http;
import 'package:dart_dlp/src/extractors/youtube_extractor.dart';
import 'package:parsejs_null_safety/jsparser.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart bin/deep_diagnostic.dart <youtube_url>');
    return;
  }

  final url = args[0];
  print('--- DEEP DIAGNOSTIC: $url ---');

  final extractor = YouTubeExtractor();
  final response = await http.get(Uri.parse(url), headers: {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
  });

  if (response.statusCode != 200) {
    print('Failed to fetch page: ${response.statusCode}');
    return;
  }

  final html = response.body;
  // We need to access private methods for diagnostics,
  // but since we are in the same project, we can just use a modified version
  // or use reflection-like approaches if needed.
  // Actually, I will just copy the extraction logic here or make it public in extractor.

  print('Extracting player URL...');
  final playerUrlMatch =
      RegExp(r'<script\s+src="([^"]+/base\.js)"').firstMatch(html);
  if (playerUrlMatch == null) {
    print('Player URL not found.');
    return;
  }

  final playerUrl = 'https://www.youtube.com' + playerUrlMatch.group(1)!;
  print('Player URL: $playerUrl');

  final playerJs = (await http.get(Uri.parse(playerUrl))).body;
  print('Player JS size: ${playerJs.length}');

  // Diagnostic for N-Parameter
  final nFunc = extractor.findNFunctionNameForTest(playerJs);
  if (nFunc != null) {
    print('\n--- N-Parameter Solver Script ---');
    final script =
        extractor.getDecipherNScriptForTest('dummy_n', nFunc, playerJs);
    print(script);

    try {
      parsejs(script);
      print('SUCCESS: Script is valid JS.');
    } catch (e) {
      print('FAILURE: Invalid JS: $e');
    }
  }

  // Diagnostic for Signature
  final sigFunc = extractor.parseDecipherFunctionNameForTest(playerJs);
  if (sigFunc != null) {
    print('\n--- Signature Solver Script ---');
    final script =
        extractor.getSignatureScriptForTest('dummy_sig', sigFunc, playerJs);
    print(script);

    try {
      parsejs(script);
      print('SUCCESS: Script is valid JS.');
    } catch (e) {
      print('FAILURE: Invalid JS: $e');
    }
  }
}

// We need to expose some methods in YouTubeExtractor for testing.
// I will add them in the next step.
