import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../core/utils.dart';
import '../core/exceptions.dart';
import '../models/video_data.dart';
import 'package:parsejs_null_safety/jsparser.dart';
import 'base.dart';

class YouTubeExtractor extends BaseExtractor with JsonScraper {
  static final RegExp _ytRegex = RegExp(
    r'^https?:\/\/(?:www\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|v\/)|youtu\.be\/)([\w-]{11})',
    caseSensitive: false,
  );

  // Regex to capture the definition of the transformation function
  // e.g. var a={...} or a={...}
  // This is highly heuristic and depends on common minification patterns.

  @override
  bool canHandle(String url) {
    return _ytRegex.hasMatch(url);
  }

  @override
  @override
  Future<VideoData> extract(
    String url, {
    Function(double progress)? onProgress,
  }) async {
    final userAgent = UserAgentManager.random;
    onProgress?.call(0.1);
    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': userAgent, // Use real UA
      },
    );

    if (response.statusCode != 200) {
      throw SiteChangeException(
        'Failed to load YouTube page: ${response.statusCode}',
      );
    }
    final body = response.body;

    // Extract Cookies
    String cookieHeader = '';
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      // Simple parser: take everything before first semicolon of each cookie?
      // 'http' joins multiple Set-Cookie headers with comma.
      // But dates also have commas. This is messy.
      // Heuristic: generic regex for "name=value"
      final cookieMatches = RegExp(
        r'([a-zA-Z0-9_-]+)=([^;,\s]+)',
      ).allMatches(setCookie);
      final validCookies = <String>[];
      final attributes = {
        'path',
        'domain',
        'expires',
        'max-age',
        'secure',
        'httponly',
        'samesite',
        'priority',
      };

      for (final m in cookieMatches) {
        final key = m.group(1)!;
        final value = m.group(2)!;
        if (!attributes.contains(key.toLowerCase())) {
          validCookies.add('$key=$value');
        }
      }
      cookieHeader = validCookies.toSet().join('; ');
    }

    if (cookieHeader.isNotEmpty) {
      print('      [Debug] Extracted Cookies: ${cookieHeader.length} chars');
    }

    // Extract Video ID from URL first
    final id = _ytRegex.firstMatch(url)?.group(1) ?? 'unknown';

    // 1. Extract Player Response (ytInitialPlayerResponse)
    onProgress?.call(0.2);
    var playerResponse = await _extractPlayerResponse(body);

    // Check for availability
    if (playerResponse['playabilityStatus']?['status'] == 'ERROR' ||
        playerResponse['playabilityStatus']?['status'] == 'LOGIN_REQUIRED') {
      print(
        '      [Debug] Initial extraction unplayable. Trying Android client fallback...',
      );
      // Attempt to fetch player response using Android Client API
      final androidResponse = await _fetchAndroidPlayerResponse(id, userAgent);
      if (androidResponse.isNotEmpty) {
        playerResponse = androidResponse;
      }
    }

    // Debug keys
    print(
      '      [Debug] playerResponse keys: ${playerResponse.keys.join(', ')}',
    );

    final videoDetails = playerResponse['videoDetails'];
    if (videoDetails == null) {
      if (playerResponse.containsKey('playabilityStatus')) {
        final status = playerResponse['playabilityStatus']?['status'];
        final reason = playerResponse['playabilityStatus']?['reason'];
        print('      [Debug] Playability Status: $status, Reason: $reason');
      }
      throw ExtractionException(
        'Could not parse video details (Playability Error)',
      );
    }

    final title = videoDetails['title'] ?? 'Unknown Title';
    final durationStr = videoDetails['lengthSeconds'];
    final duration = durationStr != null
        ? Duration(seconds: int.parse(durationStr))
        : null;
    final thumb = videoDetails['thumbnail']?['thumbnails']?.last?['url'];

    // 3. Extract Streams & Deduplicate itags
    onProgress?.call(0.3);
    var streamingData = playerResponse['streamingData'];

    // Use a Map to deduplicate itags
    final uniqueFormats = <int, Map<String, dynamic>>{};

    void addFormats(List? list) {
      if (list == null) return;
      for (var f in list) {
        if (f is Map && f.containsKey('itag')) {
          uniqueFormats[f['itag']] = Map<String, dynamic>.from(f);
        }
      }
    }

    addFormats(streamingData?['formats']);
    addFormats(streamingData?['adaptiveFormats']);

    if (uniqueFormats.isEmpty ||
        !uniqueFormats.values.any(
          (f) =>
              f['qualityLabel'] != null &&
              (f['qualityLabel'] as String).contains('720p'),
        )) {
      print(
        '      [Debug] Insufficient formats in initial response. Fetching Android fallback...',
      );
      final androidResponse = await _fetchAndroidPlayerResponse(id, userAgent);
      if (androidResponse.isNotEmpty &&
          androidResponse['streamingData'] != null) {
        final androidStreamingData = androidResponse['streamingData'];
        addFormats(androidStreamingData['formats']);
        addFormats(androidStreamingData['adaptiveFormats']);
      }
    }

    final formats = uniqueFormats.values.toList();

    if (formats.isEmpty) throw ExtractionException('No streaming data found');

    if (formats.isNotEmpty) {
      for (var f in formats) {
        final hasUrl = f['url'] != null;
        final hasCipher = f['signatureCipher'] != null || f['cipher'] != null;
        if (!hasUrl && !hasCipher) {
          // print('      [Debug] Missing URL/Cipher: itag ${f['itag']}, keys: ${f.keys.join(', ')}');
        }
      }

      final first = formats.first;
      final targetUrl =
          first['url'] ??
          (first['baseUrl'] ?? (first['signatureCipher'] ?? first['cipher']));
      if (targetUrl != null) {
        final targetStr = targetUrl.toString();
        final uri = Uri.parse(
          targetStr.contains('url=')
              ? Uri.splitQueryString(targetStr)['url']!
              : targetStr,
        );
        if (uri.queryParameters.containsKey('n')) {
          print(
            '      [Debug] Found "n" parameter in URL: ${uri.queryParameters['n']}',
          );
        } else {
          print('      [Debug] No "n" parameter found in URL query.');
        }
      }
    }

    // 3. Resolve Cipher & N-Parameter (if needed)
    final playerUrl = _extractPlayerUrl(body);
    String? playerJsBody;
    print('      [Debug] Player URL candidate: $playerUrl');

    if (playerUrl != null) {
      try {
        final playerJsResponse = await http.get(
          Uri.parse(playerUrl),
          headers: {
            'User-Agent': userAgent,
            'Referer': 'https://www.youtube.com/',
          },
        );
        playerJsBody = playerJsResponse.body;
        // DEBUG: Dump JS to file for inspection
        try {
          File('debug_player.js').writeAsStringSync(playerJsBody);
          print('      [Debug] Dumped player JS to debug_player.js');
        } catch (_) {}
        print(
          '      [Debug] Successfully fetched player JS: ${playerJsBody.length} bytes',
        );
      } catch (e) {
        print('      [Debug] Failed to fetch player JS: $e');
      }
    } else {
      print('      [Debug] Player URL extraction FAILED (No patterns matched)');
    }

    onProgress?.call(0.4);
    if (playerJsBody != null) {
      final cipherOps = _parseCipherOperations(playerJsBody);
      final decipherFuncName = _parseDecipherFunctionName(playerJsBody);
      final nFuncName = _findNFunctionName(playerJsBody);

      print(
        '      [Debug] Cipher Status: Ops: ${cipherOps.length}, DecipherFunc: $decipherFuncName, N-Func: $nFuncName',
      );

      for (var f in formats) {
        String? targetUrl = f['url'] ?? f['baseUrl'] ?? f['base_url'];
        String sigParamName = 'sig';

        // Signature Cipher
        if (f['signatureCipher'] != null || f['cipher'] != null) {
          final cipher = f['signatureCipher'] ?? f['cipher'];
          final params = Uri.splitQueryString(cipher);
          final sig = params['s'] ?? params['sig'];
          sigParamName = params['sp'] ?? 'sig';
          final urlBase = params['url'];

          if (sig != null && urlBase != null && decipherFuncName != null) {
            String decryptedSig;
            if (cipherOps.isNotEmpty) {
              decryptedSig = _applyCipher(
                sig,
                cipherOps,
                decipherFuncName,
                playerJsBody,
              );
            } else {
              decryptedSig = _decipherSignatureWithJsEngine(
                sig,
                decipherFuncName,
                playerJsBody,
              );
            }
            targetUrl = '$urlBase&$sigParamName=$decryptedSig';
          } else {
            print(
              '      [Debug] Cipher failed for itag ${f['itag']}: sig=$sig, urlBase=$urlBase, ops=${cipherOps.length}, func=$decipherFuncName',
            );
          }
        }

        // N-Parameter Deciphering
        if (targetUrl != null && nFuncName != null) {
          final uri = Uri.parse(targetUrl);
          final n = uri.queryParameters['n'];
          if (n != null) {
            final decipheredN = _decipherN(n, nFuncName, playerJsBody);
            if (decipheredN != n) {
              final newParams = Map<String, String>.from(uri.queryParameters);
              newParams['n'] = decipheredN;
              targetUrl = uri.replace(queryParameters: newParams).toString();
            }
          }
        }
        f['url'] = targetUrl;
      }
    }

    // 4. Build VideoData
    onProgress?.call(0.8);
    final streams = <StreamInfo>[];
    final videoOnly = <StreamInfo>[];
    final audioOnly = <StreamInfo>[];

    print('      [Debug] Total Formats to process: ${formats.length}');
    final itags = formats.map((f) => f['itag']).toList();
    print('      [Debug] Found itags: $itags');

    for (var f in formats) {
      final itag = f['itag'];
      if (f['url'] == null) {
        print(
          '      [Debug] SKIPPING itag $itag: URL is null (Keys: ${f.keys.join(', ')})',
        );
        continue;
      }

      final mime = f['mimeType'] ?? '';
      final width = f['width'];
      final height = f['height'];
      final qualityLabel = f['qualityLabel'] ?? (f['quality'] ?? 'unknown');
      final url = f['url'];

      final stream = StreamInfo(
        url: url,
        quality: qualityLabel,
        format: mime.split(';').first,
        width: width is int
            ? width
            : (width != null ? int.tryParse(width.toString()) : null),
        height: height is int
            ? height
            : (height != null ? int.tryParse(height.toString()) : null),
      );

      streams.add(stream);

      // Improved Adaptive Check
      final isAudioOnly = mime.startsWith('audio/');
      final isVideoOnly =
          mime.startsWith('video/') &&
          (f['audioQuality'] == null || f['audioSampleRate'] == null);
      final isCombined = mime.startsWith('video/') && !isVideoOnly;

      if (isCombined) {
        // Combined streams (usually 720p/360p)
      } else if (isVideoOnly) {
        videoOnly.add(stream);
      } else if (isAudioOnly) {
        audioOnly.add(stream);
      } else {
        print(
          '      [Debug] itag $itag ($qualityLabel) classification unknown: $mime',
        );
      }
    }

    print(
      '      [Debug] Final: ${videoOnly.length} Video-Only, ${audioOnly.length} Audio-Only',
    );

    return VideoData(
      title: title,
      id: id,
      originalUrl: url,
      streams: streams,
      videoOnlyStreams: videoOnly,
      audioOnlyStreams: audioOnly,
      metadata: {'duration': duration?.inSeconds, 'thumbnail': thumb},
      httpHeaders: {
        'User-Agent': userAgent,
        'Referer': 'https://www.youtube.com/',
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      },
    );
  }

  // --- Helpers ---

  // --- Helpers ---

  Future<Map<String, dynamic>> _extractPlayerResponse(String html) async {
    // 1. Standard var assignment
    var regex = RegExp(
      r'var\s+ytInitialPlayerResponse\s*=\s*(\{.+?\});',
      multiLine: true,
    );
    var match = regex.firstMatch(html);
    if (match != null) return extractJson(match.group(1)!);

    // 2. Window assignment
    regex = RegExp(r'window\["ytInitialPlayerResponse"\]\s*=\s*(\{.+?\});');
    match = regex.firstMatch(html);
    if (match != null) return extractJson(match.group(1)!);

    // 3. Fallback: ytInitialPlayerResponse = (no var)
    regex = RegExp(r'(?:^|;)ytInitialPlayerResponse\s*=\s*(\{.+?\});');
    match = regex.firstMatch(html);
    if (match != null) return extractJson(match.group(1)!);

    // 4. ytInitialPlayerResponse in ytcfg.set
    regex = RegExp(r'ytcfg\.set\(\{.*?"player_response":\s*(\{.+?\})\}\);');
    match = regex.firstMatch(html);
    if (match != null) return extractJson(match.group(1)!);

    // Debug: Log snippet if failed
    print(
      '      [Debug] Player Response extraction failed. HTML length: ${html.length}',
    );
    if (html.contains('playerResponse')) {
      print('      [Debug] Found "playerResponse" keyword but regex failed.');
    }

    throw ExtractionException('Could not locate player response');
  }

  String? _extractPlayerUrl(String html) {
    // Attempt multiple patterns to find the player JS URL
    final patterns = [
      r'<script\s+src="([^"]+/base\.js)"',
      r'"jsUrl":"([^"]+)"',
      r'assets/player/([^"/]+/base\.js)',
      r'href="([^"]+base\.js)"',
    ];

    for (var p in patterns) {
      final match = RegExp(p).firstMatch(html);
      if (match != null) {
        var url = match.group(1)!;
        if (!url.startsWith('http')) {
          url =
              'https://www.youtube.com' +
              (url.startsWith('/') ? '' : '/') +
              url;
        }
        print('      [Debug] Found Player URL: $url (pattern: $p)');
        return url;
      }
    }

    return null;
  }

  // --- Cipher Logic ---

  String? _parseDecipherFunctionName(String js) {
    // New Robust Logic (2026-01-31):
    // 1. Find the helper object by its unique signature (splice method with 0 as first arg).
    // Pattern: method:function(a,b){a.splice(0,b)} or via constant array a[c](0,b)
    final spliceRegex = RegExp(
      r'([a-zA-Z0-9$]+):function\(\w+,\w+\)\{\w+\[.*?\]\(0,\w+\)\}',
    );
    final spliceMatch = spliceRegex.firstMatch(js);

    if (spliceMatch == null) {
      print('      [Debug] Helper object splice method not found.');
      return null;
    }

    // Find the object definition "var NAME={" before this match
    final matchIndex = spliceMatch.start;
    final searchContext = js.substring(
      (matchIndex - 500 < 0) ? 0 : matchIndex - 500,
      matchIndex,
    );
    final objectDefRegex = RegExp(r'var\s+([a-zA-Z0-9$]+)=\{');
    final objectMatches = objectDefRegex.allMatches(searchContext);

    if (objectMatches.isEmpty) {
      print('      [Debug] Helper object definition not found.');
      return null;
    }

    final helperName = objectMatches.last.group(1)!;
    print('      [Debug] Found Helper Object: $helperName');

    // 2. Find the function that uses this helper
    // Search for "helperName["
    final usageRegex = RegExp(RegExp.escape(helperName) + r'\[');
    final usageMatch = usageRegex.firstMatch(js);

    if (usageMatch == null) {
      print('      [Debug] Helper usage not found.');
      return null;
    }

    // Search backwards for "functionName=function"
    final usageIndex = usageMatch.start;
    final funcContext = js.substring(
      (usageIndex - 500 < 0) ? 0 : usageIndex - 500,
      usageIndex,
    );

    final funcDefRegex = RegExp(r'([a-zA-Z0-9$]+)=function\(');
    final funcMatches = funcDefRegex.allMatches(funcContext);

    if (funcMatches.isEmpty) {
      print('      [Debug] Decipher function definition not found.');
      return null;
    }

    final funcName = funcMatches.last.group(1);
    print('      [Debug] Found Decipher Function: $funcName');
    return funcName;
  }

  List<Function(List<String>)> _parseCipherOperations(String js) {
    final decipherFuncBody = _extractDecipherFuncBody(js);
    if (decipherFuncBody == null) return [];

    // Find called object name: "B.C(a,3)"
    final calledObjectName = RegExp(
      r'([a-zA-Z0-9$]+)\.[a-zA-Z0-9$]+\(',
    ).firstMatch(decipherFuncBody)?.group(1);
    if (calledObjectName == null) return [];

    // Extract helper object definition
    // Matches: var B={...};  OR  B={...};
    // Note: The "var" might be missing or separated.
    final helperObjRegex = RegExp(
      // Capture group 1: Body of the object
      // Allow optional 'var ', logic name, equals, brace
      '(?:var\\s+)?$calledObjectName\\s*=\\s*\\{(.*?)\\};',
      multiLine: true,
      dotAll: true,
    );

    final helperObjMatch = helperObjRegex.firstMatch(js);
    if (helperObjMatch == null) return [];

    final helperBody = helperObjMatch.group(1)!;

    // Parse methods - Robust regexes handling whitespace
    final reverseRegex = RegExp(
      r'([a-zA-Z0-9$]+)\s*:\s*function\(\w+\)\{\w+\.reverse\(\)\}',
    );
    final sliceRegex = RegExp(
      r'([a-zA-Z0-9$]+)\s*:\s*function\(\w+,(\w+)\)\{\w+\.splice\(0,\2\)\}',
    );
    final swapRegex = RegExp(
      r'([a-zA-Z0-9$]+)\s*:\s*function\(\w+,(\w+)\)\{var\s+\w+=\w+\[0\];\w+\[0\]=\w+\[\2%[\w+\.]*length\];\w+\[\2%[\w+\.]*length\]=\w+\}',
    );

    final reverseMethod = reverseRegex.firstMatch(helperBody)?.group(1);
    final sliceMethod = sliceRegex.firstMatch(helperBody)?.group(1);
    final swapMethod = swapRegex.firstMatch(helperBody)?.group(1);

    final operations = <Function(List<String>)>[];

    // Parse the calls in order from decipher body
    final callRegex = RegExp(
      // Escape object name
      '${RegExp.escape(calledObjectName)}\\.([a-zA-Z0-9\$]+)\\(a,(\\d+)\\)',
    );
    final matches = callRegex.allMatches(decipherFuncBody);

    for (var m in matches) {
      final method = m.group(1);
      final param = int.parse(m.group(2)!);

      if (method == reverseMethod) {
        operations.add((list) {
          final reversed = list.reversed.toList();
          list.clear();
          list.addAll(reversed);
        });
      } else if (method == sliceMethod) {
        operations.add((list) => list.removeRange(0, param));
      } else if (method == swapMethod) {
        operations.add((list) {
          final c = list[0];
          final index = param % list.length;
          list[0] = list[index];
          list[index] = c;
        });
      }
    }

    return operations;
  }

  String? _extractDecipherFuncBody(String js) {
    // Find the main function that splits, joins, and has intermediate calls
    final regex = RegExp(
      r'''[a-zA-Z0-9$]+=function\((\w+)\)\{(?:var\s+)?\1=\1\.split\(['"]['"]\)(?:;|,)(.+?)(?:;|,)?return \1\.join\(['"]['"]\)\}''',
    );
    return regex
        .firstMatch(js)
        ?.group(2); // Group 2 is the body calls "B.C(a,3)..."
  }

  Future<Map<String, dynamic>> _fetchAndroidPlayerResponse(
    String videoId,
    String userAgent,
  ) async {
    // TVHTML5 client is often the most permissive for adaptive streams
    final url =
        'https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlS9W6Sg6o5_6o5_6o5_6o5_6o5';
    final payload = {
      'context': {
        'client': {
          'clientName': 'TVHTML5',
          'clientVersion': '7.20230405.08.01',
          'hl': 'en',
          'gl': 'US',
        },
      },
      'videoId': videoId,
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': userAgent,
          'Referer': 'https://www.youtube.com/',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('      [Debug] TVHTML5 Innertube fallback failed: $e');
    }
    return {};
  }

  String? _findNFunctionName(String js) {
    // Attempt multiple patterns for the 'n' parameter solver function
    final patterns = [
      r'(?:var\s+)?([a-zA-Z0-9$]+)=function\((\w+)\)\{return [a-zA-Z0-9$]+\[[a-zA-Z0-9$]+\[\d+\]\]\(this,\d+,\2\)\}', // Wrapper pattern
      r'\.set\("n",([a-zA-Z0-9$]+)\(',
      r'\.get\("n"\)\)&&\(b=b\.get\("n"\),c=([a-zA-Z0-9$]+)\[0\]\(b\)',
      r'([a-zA-Z0-9$]+)=function\(a\)\{var b=a\.split\(""\),c=\[',
      r'([a-zA-Z0-9$]+)=function\(a\)\{var b=a\.split\(""\),c=\1\.split',
      r'(?:var\s+)?fUr\s*=\s*\[([a-zA-Z0-9$]+)\]',
    ];

    for (var p in patterns) {
      final match = RegExp(p).firstMatch(js);
      if (match != null) {
        final name = match.group(1);
        print('      [Debug] Found candidate N-function: $name (pattern: $p)');
        return name;
      }
    }
    return null;
  }

  String _decipherN(String n, String funcName, String js) {
    print('      [Debug] N-Parameter deciphering for func: $funcName');

    try {
      final definitions = <String, String>{};
      final queue = <String>[funcName];
      final visited = <String>{funcName};

      // Special: Find 'z' array if used (common in new player)
      if (js.contains('var z="') || js.contains('var z = "')) {
        final zRegex = RegExp(r'(?:var\s+)?z\s*=\s*"[^"]+"\s*\.split\(";"\)');
        final zMatch = zRegex.firstMatch(js);
        if (zMatch != null) {
          definitions['z'] = zMatch.group(0)! + ';';
        }
      }

      int safety = 0;
      while (queue.isNotEmpty && safety++ < 100) {
        final current = queue.removeAt(0);

        final def = _extractDefinition(js, current);
        if (def != null) {
          definitions[current] = def;

          // Find dependencies in the definition
          // Only look for potential identifiers that are not keywords
          // Must start with letter/underscore/$
          final idRegex = RegExp(r'\b[a-zA-Z_$][a-zA-Z0-9_$]*\b');
          final matches = idRegex.allMatches(def);
          for (var m in matches) {
            final id = m.group(0)!;
            if (!visited.contains(id) &&
                ![
                  'var',
                  'function',
                  'return',
                  'if',
                  'else',
                  'for',
                  'while',
                  'switch',
                  'case',
                  'break',
                  'default',
                  'this',
                  'null',
                  'true',
                  'false',
                  'typeof',
                  'void',
                  'new',
                  'try',
                  'catch',
                  'throw',
                ].contains(id)) {
              if (_hasDefinition(js, id)) {
                visited.add(id);
                queue.add(id);
              }
            }
          }
        }
      }

      final script = StringBuffer();
      // Ensure 'z' or helper objects are included
      // We iterate recursively to find definitions
      if (definitions.containsKey('z')) {
        script.writeln(definitions['z']);
        definitions.remove('z');
      }
      for (var def in definitions.values) {
        script.writeln(def);
      }
      script.writeln('$funcName("$n");');

      final fullScript = script.toString();
      print('      [Debug] Script content:\n$fullScript');

      final ast = parsejs(fullScript);
      final interpreter = _MiniJSInterpreter();
      final result = interpreter.evaluate(ast);

      if (result is String) {
        print(
          '      [Debug] N-Parameter solved successfully: ${result.substring(0, 5)}...',
        );
        return result;
      }
    } catch (e) {
      print('      [Debug] JS Execution failed for N ($funcName): $e');
    }
    return n;
  }

  String _decipherSignatureWithJsEngine(
    String sig,
    String funcName,
    String js,
  ) {
    print(
      '      [Debug] Signature deciphering via JS Engine for func: $funcName',
    );

    try {
      final definitions = <String, String>{};
      final queue = <String>[funcName];
      final visited = <String>{funcName};

      // Define recursive discovery limit
      int iterations = 0;
      while (queue.isNotEmpty && iterations < 100) {
        final id = queue.removeAt(0);
        iterations++;

        // Extract definition
        final def = _extractDefinition(js, id);
        if (def != null) {
          // print(
          //     '      [Debug] Extracted $id: ${def.length > 50 ? def.substring(0, 50) + "..." : def}');
          definitions[id] = def;
          // Parse body for dependencies
          final body = def.substring(def.indexOf('=') + 1);

          // Regex to find identifiers: simple heuristic
          // We look for any word that is NOT a keyword
          final words = RegExp(r'[a-zA-Z_$][a-zA-Z0-9_$]*').allMatches(body);
          for (var m in words) {
            final word = m.group(0)!;
            if (word.length < 2)
              continue; // Skip single chars if needed, but 'z' is short
            // Check keywords
            if ([
              'var',
              'function',
              'return',
              'if',
              'else',
              'for',
              'while',
              'switch',
              'case',
              'break',
              'try',
              'catch',
              'finally',
              'throw',
              'new',
              'void',
              'delete',
              'null',
              'true',
              'false',
              'typeof',
              'undefined',
              'NaN',
              'Infinity',
              'this',
              'arguments',
              'window',
              'document',
              'console',
              'Math',
              'Date',
              'JSON',
              'RegExp',
              'String',
              'Number',
              'Boolean',
              'Array',
              'Object',
              'Error',
              'Promise',
              'Map',
              'Set',
              'Symbol',
              'constructor', // Critical
              'prototype',
              'length',
              'call',
              'apply',
              'bind',
              'toString',
              'valueOf',
              'indexOf',
              'substring',
              'split',
              'join',
              'slice',
              'push',
              'pop',
              'shift',
              'unshift',
              'splice',
              'includes',
              'forEach',
              'map',
              'filter',
              'reduce',
              'keys',
              'values',
              'entries',
            ].contains(word))
              continue;

            if (!visited.contains(word)) {
              // Check if it has a global definition we can extract
              if (_hasDefinition(js, word)) {
                visited.add(word);
                queue.add(word);
              }
            }
          }
        }
      }

      final script = StringBuffer();
      // Heuristic: put 'z' or helpers first?
      // Map iteration order is unpredictable, but usually definition order matters less for vars
      // BUT 'z' array must be defined before usage.
      // We simply dump all definitions.
      for (var def in definitions.values) {
        script.writeln(def);
      }
      script.writeln('$funcName("$sig");');

      final fullScript = script.toString();
      // print('      [Debug] Signature Script size: ${fullScript.length}');

      final ast = parsejs(fullScript);
      final interpreter = _MiniJSInterpreter();
      final result = interpreter.evaluate(ast);

      return result.toString();
    } catch (e) {
      print('      [Debug] JS Execution failed for Signature ($funcName): $e');
      return sig; // Fallback to original
    }
  }

  bool _hasDefinition(String js, String name) {
    return js.contains('var $name=') ||
        js.contains('var $name =') ||
        js.contains('$name=function') ||
        js.contains('$name = function') ||
        js.contains('function $name');
  }

  String? _extractDefinition(String js, String name) {
    // 1. Function definition: Name = function... or function Name...
    final funcRegex = RegExp(
      r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=\s*function\s*\(',
    );
    var match = funcRegex.firstMatch(js);
    if (match != null) {
      final funcStart = js.lastIndexOf('function', match.end);
      final bodyStart = js.indexOf('{', funcStart);
      if (bodyStart != -1) {
        final bodyEnd = _findMatchingBrace(js, bodyStart);
        if (bodyEnd != -1) {
          final def =
              'var $name = ' + js.substring(funcStart, bodyEnd + 1) + ';';
          return def.replaceAll('function*', 'function');
        }
      }
    }

    // Pattern B: function Name(...)
    final funcDeclRegex = RegExp(
      r'function\s+' + RegExp.escape(name) + r'\s*\(',
    );
    match = funcDeclRegex.firstMatch(js);
    if (match != null) {
      final bodyStart = js.indexOf('{', match.end);
      if (bodyStart != -1) {
        final bodyEnd = _findMatchingBrace(js, bodyStart);
        if (bodyEnd != -1) {
          final def = js.substring(match.start, bodyEnd + 1);
          return def.replaceAll('function*', 'function');
        }
      }
    }

    // Pattern C: Variable assignment (Array/Object/String)
    // var Name = [...]; or var Name = "..."
    // Ensure we don't match == or ===
    final varRegex = RegExp(
      r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=(?!=)\s*',
    );
    match = varRegex.firstMatch(js);
    if (match != null) {
      final start = match.start;
      final startOfValue = match.end;

      if (startOfValue < js.length) {
        // Heuristic: Read until the next semicolon, respecting quotes/braces
        int i = startOfValue;
        bool inQuote = false;
        String? quoteChar;
        int braceDepth = 0;
        int bracketDepth = 0;

        while (i < js.length) {
          final char = js[i];
          final prev = (i > 0) ? js[i - 1] : '';

          if (inQuote) {
            if (char == quoteChar && prev != '\\') {
              inQuote = false;
            }
          } else {
            if (char == '"' || char == "'") {
              inQuote = true;
              quoteChar = char;
            } else if (char == '{') {
              braceDepth++;
            } else if (char == '}') {
              braceDepth--;
            } else if (char == '[') {
              bracketDepth++;
            } else if (char == ']') {
              bracketDepth--;
            } else if (char == ';' && braceDepth == 0 && bracketDepth == 0) {
              // Found end of statement
              return js.substring(start, i + 1);
            }
          }
          i++;
        }
        // If we hit EOF, just return what we have (e.g. minified last statement)
        var def = js.substring(start, i) + (js.endsWith(';') ? '' : ';');
        // Sanitize: Modern YouTube uses generator functions (function*) which our parser doesn't like.
        // Since signature logic doesn't actually use generator features (yield), we can safely convert to standard functions.
        return def.replaceAll('function*', 'function');
      }
    }

    return null;
  }

  String _applyCipher(
    String sig,
    List<Function(List<String>)> ops,
    String funcName,
    String js,
  ) {
    var chars = sig.split('');
    for (var op in ops) {
      op(chars);
    }
    return chars.join('');
  }

  Map<String, dynamic> extractJson(String raw) {
    try {
      final cleaned = raw.trim();
      return jsonDecode(cleaned);
    } catch (e) {
      return {};
    }
  }

  int _findMatchingBrace(
    String js,
    int start, {
    String open = '{',
    String close = '}',
  }) {
    int count = 0;
    bool inQuote = false;
    String? quoteChar;

    for (int i = start; i < js.length; i++) {
      final char = js[i];
      final prev = (i > 0) ? js[i - 1] : '';

      if (inQuote) {
        if (char == quoteChar && prev != '\\') {
          inQuote = false;
        }
      } else {
        if (char == '"' || char == "'") {
          inQuote = true;
          quoteChar = char;
        } else if (char == open) {
          count++;
        } else if (char == close) {
          count--;
          if (count == 0) return i;
        }
      }
    }
    return -1;
  }

  // Diagnostic Helpers
  String? findNFunctionNameForTest(String js) => _findNFunctionName(js);
  String? parseDecipherFunctionNameForTest(String js) =>
      _parseDecipherFunctionName(js);

  String getDecipherNScriptForTest(String n, String funcName, String js) {
    // Rebuild the script logic from _decipherN but just return the script string
    final definitions = <String, String>{};
    final queue = <String>[funcName];
    final visited = <String>{funcName};

    if (js.contains('var z="') || js.contains('var z = "')) {
      final zRegex = RegExp(r'(?:var\s+)?z\s*=\s*"[^"]+"\s*\.split\(";"\)');
      final zMatch = zRegex.firstMatch(js);
      if (zMatch != null) {
        definitions['z'] = zMatch.group(0)! + ';';
      }
    }

    int safety = 0;
    while (queue.isNotEmpty && safety++ < 100) {
      final current = queue.removeAt(0);
      final def = _extractDefinition(js, current);
      if (def != null) {
        definitions[current] = def;
        final idRegex = RegExp(r'\b[a-zA-Z_$][a-zA-Z0-9_$]*\b');
        final matches = idRegex.allMatches(def);
        for (var m in matches) {
          final id = m.group(0)!;
          if (!visited.contains(id) &&
              ![
                'var',
                'function',
                'return',
                'if',
                'else',
                'for',
                'while',
                'switch',
                'case',
                'break',
                'default',
                'this',
                'null',
                'true',
                'false',
                'typeof',
                'void',
                'new',
                'try',
                'catch',
                'throw',
              ].contains(id)) {
            if (_hasDefinition(js, id)) {
              visited.add(id);
              queue.add(id);
            }
          }
        }
      }
    }

    final script = StringBuffer();
    if (definitions.containsKey('z')) {
      script.writeln(definitions['z']);
      definitions.remove('z');
    }
    for (var def in definitions.values) {
      script.writeln(def);
    }
    script.writeln('$funcName("$n");');
    return script.toString();
  }

  String getSignatureScriptForTest(String sig, String funcName, String js) {
    // Rebuild the script logic from _decipherSignatureWithJsEngine but just return script
    final definitions = <String, String>{};
    final queue = <String>[funcName];
    final visited = <String>{funcName};

    int iterations = 0;
    while (queue.isNotEmpty && iterations++ < 100) {
      final id = queue.removeAt(0);
      final def = _extractDefinition(js, id);
      if (def != null) {
        definitions[id] = def;
        final body = def.substring(def.indexOf('=') + 1);
        final words = RegExp(r'[a-zA-Z_$][a-zA-Z0-9_$]*').allMatches(body);
        for (var m in words) {
          final word = m.group(0)!;
          if (word.length < 2) continue;
          if ([
            'var',
            'function',
            'return',
            'if',
            'else',
            'for',
            'while',
            'switch',
            'case',
            'break',
            'try',
            'catch',
            'finally',
            'throw',
            'new',
            'void',
            'delete',
            'null',
            'true',
            'false',
            'typeof',
            'undefined',
            'NaN',
            'Infinity',
            'this',
            'arguments',
            'window',
            'document',
            'console',
            'Math',
            'Date',
            'JSON',
            'RegExp',
            'String',
            'Number',
            'Boolean',
            'Array',
            'Object',
            'Error',
            'Promise',
            'Map',
            'Set',
            'Symbol',
            'constructor',
            'prototype',
            'length',
            'call',
            'apply',
            'bind',
            'toString',
            'valueOf',
            'indexOf',
            'substring',
            'split',
            'join',
            'slice',
            'push',
            'pop',
            'shift',
            'unshift',
            'splice',
            'includes',
            'forEach',
            'map',
            'filter',
            'reduce',
            'keys',
            'values',
            'entries',
          ].contains(word))
            continue;

          if (!visited.contains(word)) {
            if (_hasDefinition(js, word)) {
              visited.add(word);
              queue.add(word);
            }
          }
        }
      }
    }

    final script = StringBuffer();
    for (var def in definitions.values) {
      script.writeln(def);
    }
    script.writeln('$funcName("$sig");');
    return script.toString();
  }
}

/// A lightweight, recursive AST visitor to evaluate JS logic used in YouTube's n-parameter.
/// Pure Dart (No Flutter dependency).
class _MiniJSInterpreter extends RecursiveVisitor<dynamic> {
  final Map<String, dynamic> _context = {};
  dynamic _lastResult;

  dynamic evaluate(Program program) {
    try {
      visit(program);
    } on _ReturnException catch (e) {
      return e.value;
    }
    return _lastResult;
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    _lastResult = visit(node.expression);
  }

  @override
  void visitVariableDeclarator(VariableDeclarator node) {
    final name = (node.name as dynamic).value;
    final value = node.init != null ? visit(node.init!) : null;
    _context[name] = value;
  }

  @override
  dynamic visitAssignment(AssignmentExpression node) {
    final value = visit(node.right);
    final left = node.left;
    if (left is NameExpression) {
      _context[left.name.value] = value;
    } else if (left is IndexExpression) {
      final obj = visit(left.object);
      final prop = visit(left.property);
      if (obj is List) {
        obj[prop] = value;
      } else if (obj is Map) {
        obj[prop] = value;
      }
    } else if (left is MemberExpression) {
      final obj = visit(left.object);
      final prop = left.property.value;
      if (prop == 'constructor') return null; // Blacklist

      if (obj is Map) {
        obj[prop] = value;
      }
    }
    return value;
  }

  @override
  dynamic visitBinary(BinaryExpression node) {
    if (node.operator == '&&') {
      final left = visit(node.left);
      if (!_isTruthy(left)) return left;
      return visit(node.right);
    }
    if (node.operator == '||') {
      final left = visit(node.left);
      if (_isTruthy(left)) return left;
      return visit(node.right);
    }

    final left = visit(node.left);
    final right = visit(node.right);

    switch (node.operator) {
      case '+':
        return left + right;
      case '-':
        return left - right;
      case '*':
        return left * right;
      case '/':
        return left / right;
      case '%':
        return left % right;
      case '==':
      case '===':
        return left == right;
      case '!=':
      case '!==':
        return left != right;
      case '<':
        return left < right;
      case '>':
        return left > right;
      case '<=':
        return left <= right;
      case '>=':
        return left >= right;
      case '&':
        return left & right;
      case '|':
        return left | right;
      case '^':
        return left ^ right;
      case '<<':
        return left << right;
      case '>>':
        return left >> right;
      case '>>>':
        return left >>> right;
      default:
        return null;
    }
  }

  @override
  dynamic visitConditional(ConditionalExpression node) {
    return _isTruthy(visit(node.condition))
        ? visit(node.then)
        : visit(node.otherwise);
  }

  bool _isTruthy(dynamic val) {
    if (val == null) return false;
    if (val is bool) return val;
    if (val is int) return val != 0;
    if (val is double) return val != 0.0 && !val.isNaN;
    if (val is String) return val.isNotEmpty;
    return true;
  }

  @override
  dynamic visitUnary(UnaryExpression node) {
    final arg = visit(node.argument);
    switch (node.operator) {
      case '-':
        return -arg;
      case '!':
        return !_isTruthy(arg);
      case '~':
        return ~arg;
      case 'typeof':
        return arg.runtimeType.toString().toLowerCase();
      default:
        return arg;
    }
  }

  @override
  dynamic visitLiteral(LiteralExpression node) {
    return node.value;
  }

  @override
  dynamic visitNameExpression(NameExpression node) {
    return _context[node.name.value];
  }

  @override
  dynamic visitCall(CallExpression node) {
    dynamic func;
    if (node.callee is NameExpression) {
      final name = (node.callee as NameExpression).name.value;
      func = _context[name];
    } else {
      func = visit(node.callee);
    }

    if (func is _JSFunc) {
      final args = node.arguments.map(visit).toList();
      return func.call(this, args);
    }
    return null;
  }

  @override
  _JSFunc visitFunctionExpression(FunctionExpression node) {
    return _JSFunc(node.function);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final name = node.function.name!.value;
    _context[name] = _JSFunc(node.function);
  }

  @override
  dynamic visitIndex(IndexExpression node, {bool computeAsPattern = false}) {
    final obj = visit(node.object);
    final property = visit(node.property);
    if (property == 'constructor') return null; // Blacklist

    if (obj is List) return obj[property];
    if (obj is Map) return obj[property];
    if (obj is String) return obj[property];
    return null;
  }

  @override
  dynamic visitMember(MemberExpression node) {
    final obj = visit(node.object);
    final property = node.property.value;

    // Blacklist 'constructor' to avoid security/escaping issues as requested
    if (property == 'constructor') {
      return null;
    }

    if (obj is Map) return obj[property];
    // String length etc.
    if (obj is String && property == 'length') return obj.length;
    if (obj is List && property == 'length') return obj.length;

    return null;
  }

  @override
  List<dynamic> visitArray(ArrayExpression node) {
    return node.expressions.map((e) => e != null ? visit(e) : null).toList();
  }

  @override
  Map<dynamic, dynamic> visitObject(ObjectExpression node) {
    final map = <dynamic, dynamic>{};
    for (var prop in node.properties) {
      final key = (prop.key as Name).value;
      map[key] = visit(prop.value);
    }
    return map;
  }

  @override
  void visitReturn(ReturnStatement node) {
    throw _ReturnException(
      node.argument != null ? visit(node.argument!) : null,
    );
  }

  @override
  dynamic visitBlock(BlockStatement node) {
    dynamic result;
    for (var stmt in node.body) {
      result = visit(stmt);
    }
    return result;
  }

  @override
  dynamic visitIf(IfStatement node) {
    if (_isTruthy(visit(node.condition))) {
      return visit(node.then);
    } else if (node.otherwise != null) {
      return visit(node.otherwise!);
    }
  }

  @override
  void visitFor(ForStatement node) {
    if (node.init != null) visit(node.init!);
    while (node.condition == null || _isTruthy(visit(node.condition!))) {
      try {
        visit(node.body);
      } on _ContinueException {
        // continue
      } on _BreakException {
        break;
      }
      if (node.update != null) visit(node.update!);
    }
  }

  @override
  void visitWhile(WhileStatement node) {
    while (_isTruthy(visit(node.condition))) {
      try {
        visit(node.body);
      } on _ContinueException {
        // continue
      } on _BreakException {
        break;
      }
    }
  }

  @override
  void visitDoWhile(DoWhileStatement node) {
    do {
      try {
        visit(node.body);
      } on _ContinueException {
        // continue
      } on _BreakException {
        break;
      }
    } while (_isTruthy(visit(node.condition)));
  }

  @override
  void visitSwitch(SwitchStatement node) {
    final discriminant = visit(node.argument);
    bool matchFound = false;

    for (final caseClause in node.cases) {
      if (!matchFound) {
        if (caseClause.expression == null) {
          matchFound = true; // Default
        } else {
          final test = visit(caseClause.expression!);
          if (discriminant == test) {
            matchFound = true;
          }
        }
      }

      if (matchFound) {
        try {
          for (final stmt in caseClause.body) {
            visit(stmt);
          }
        } on _BreakException {
          return; // Exit switch
        }
        // Fallthrough
      }
    }
  }

  @override
  Never visitBreak(BreakStatement node) => throw _BreakException();
  @override
  Never visitContinue(ContinueStatement node) => throw _ContinueException();
}

class _JSFunc {
  final FunctionNode node;
  _JSFunc(this.node);

  dynamic call(_MiniJSInterpreter interpreter, List<dynamic> args) {
    // Create new scope context?
    // For n-param, we often only need a simple one-level context or global
    final oldContext = Map<String, dynamic>.from(interpreter._context);
    for (int i = 0; i < node.params.length; i++) {
      interpreter._context[(node.params[i] as dynamic).value] =
          i < args.length ? args[i] : null;
    }
    try {
      interpreter.visit(node.body);
    } on _ReturnException catch (e) {
      interpreter._context.clear();
      interpreter._context.addAll(oldContext);
      return e.value;
    }
    interpreter._context.clear();
    interpreter._context.addAll(oldContext);
    return null;
  }
}

class _ReturnException {
  final dynamic value;
  _ReturnException(this.value);
}

class _BreakException {}

class _ContinueException {}
