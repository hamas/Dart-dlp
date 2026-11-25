import 'dart:io';
import 'package:dart_dlp/dart_dlp.dart';

void main(List<String> args) async {
  // 1. Initialize
  final engine = DlpEngine();
  // Register Extractors manually if the CLI factory isn't used
  engine.registerExtractor(YouTubeExtractor());

  final controller = DlpController();
  final url = args.isNotEmpty
      ? args[0]
      : 'https://www.youtube.com/watch?v=LXb3EKWsInQ';

  print('================================================================');
  print('              DART_DLP ENGINE BATTLE TEST                       ');
  print('================================================================');

  try {
    print('[1] Analyzing: $url');
    final video = await engine.extract(
      url,
      onProgress: (p) =>
          stdout.write('\rExtracting... ${(p * 100).toStringAsFixed(0)}%'),
    );
    print(''); // Newline

    // Verbose Output
    print('\n[Video Info]');
    print('Title:  ${video.title}');
    print('Author: ${video.metadata['author'] ?? 'Unknown'}');
    print('Duration: ${video.metadata['duration'] ?? 'Unknown'}');

    print('\n[Detected Formats]');
    final allStreams = [...video.streams];
    // Simple sort by height/quality
    allStreams.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));

    // Distinguishing pre-merged vs split
    for (var f in allStreams) {
      String type = 'COMBINED';
      if (video.videoOnlyStreams.contains(f))
        type = 'VIDEO-ONLY';
      else if (video.audioOnlyStreams.contains(f))
        type = 'AUDIO-ONLY';

      final qualityName = f.quality ?? 'N/A';
      final dims = '${f.width ?? "?"}x${f.height ?? "?"}';

      print(
        ' - [${qualityName.padRight(5)}] ${type.padRight(12)} | ${f.format.padRight(8)} | $dims | URL_LEN: ${f.url.length}',
      );
    }

    print('\n[Signature Verification]');
    if (allStreams.isNotEmpty) {
      final testUrl = allStreams.first.url;
      print(
        'Top format URL: ${testUrl.substring(0, testUrl.length > 50 ? 50 : testUrl.length)}...',
      );
    } else {
      print('No formats found!');
    }

    // 2. Download & Mux Test
    print('\n[2] Selecting Best 4K/1080p Format...');
    print('Starting Download into ${Directory.current.path} ...');

    // Listen to state stream BEFORE starting download
    final subscription = controller.state.listen((event) {
      final status = event.status.toString().split('.').last.toUpperCase();

      final pct = event.progress != null
          ? event.progress!.percentage.toStringAsFixed(1)
          : '0.0';
      final speed = event.progress != null
          ? '${event.progress!.speedMBps.toStringAsFixed(2)} MB/s'
          : '0.0 MB/s';

      stdout.write('\r[Download] $status | $pct% | ${speed}           ');

      if (status == 'MERGING' || event.status == DlpStatus.merging) {
        print(
          '\n[!] VERIFIED: Handshake with Native Muxer initiated (Merging state active).',
        );
      }

      if (event.status == DlpStatus.completed) {
        print('\n[State] Completed.');
      }
      if (event.status == DlpStatus.error) {
        print('\n[State] Error: ${event.error}');
        if (event.error.toString().contains('403')) {
          print('Detected 403 Forbidden - Bot Detection Active.');
        }
      }
    });

    try {
      final filePath = await controller.startDownload(
        video,
        Directory.current.path,
      );
      print('\n\n[Success] File saved to: $filePath');

      final f = File(filePath);
      if (await f.exists()) {
        print(
          '[Verification] File exists on disk. Size: ${(await f.length()) / 1024 / 1024} MB',
        );
      } else {
        print('[Verification] File NOT found on disk!');
      }
    } catch (e) {
      print('\n[Download Exception] $e');
      if (e.toString().contains('403')) {
        print('Detected 403 Forbidden - Bot Detection Active.');
      }
    } finally {
      await subscription.cancel();
      controller.dispose();
    }
  } catch (e, stack) {
    print('\n[CRITICAL FAILURE] Exception caught during Engine Battle Test:');
    print(e);
    if (e.toString().contains('DlpException')) {
      print('DlpException detected.');
    }
    print(stack);
  }
}
