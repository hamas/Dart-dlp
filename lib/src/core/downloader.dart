/// Developed by Hamas | dart_dlp Engine
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

class DownloadProgress {
  final double percentage; // 0.0 to 100.0
  final double speedMBps;
  final Duration eta;

  DownloadProgress(this.percentage, this.speedMBps, this.eta);
}

class HamasDownloader {
  final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progress => _progressController.stream;

  /// Downloads a file using concurrent chunk requests.
  ///
  /// [url] Source URL.
  /// [savePath] Destination file path.
  /// [chunks] Number of concurrent chunks (default: 8).
  Future<void> download(String url, String savePath,
      {int chunks = 8, Map<String, String>? headers}) async {
    final file = File(savePath);
    final raf = await file.open(mode: FileMode.write);

    // 1. Get Content Length
    int bodyLength = 0;
    try {
      final headResponse = await http.head(Uri.parse(url), headers: headers);
      if (headResponse.statusCode == 200 || headResponse.statusCode == 206) {
        bodyLength =
            int.tryParse(headResponse.headers['content-length'] ?? '') ?? 0;
      }

      if (bodyLength <= 0) {
        // Fallback to GET with Range: bytes=0-0 (some signed URLs block HEAD)
        final getResponse = await http.get(Uri.parse(url), headers: {
          ...?headers,
          'Range': 'bytes=0-0',
        });
        if (getResponse.statusCode == 206 || getResponse.statusCode == 200) {
          final contentRange = getResponse.headers['content-range'];
          if (contentRange != null && contentRange.contains('/')) {
            bodyLength = int.tryParse(contentRange.split('/').last) ?? 0;
          } else {
            bodyLength =
                int.tryParse(getResponse.headers['content-length'] ?? '') ?? 0;
          }
        }
      }
    } catch (e) {
      print('Could not get content length: $e');
    }

    if (bodyLength <= 0) {
      print('[HamasDownloader] Warning: Could not determine content length.');
      // Direct Download Fallback
      await _downloadSingle(url, raf, headers: headers);
      await raf.close();
      unawaited(_progressController.close());
      return;
    }
    print('[HamasDownloader] Starting chunked download: $bodyLength bytes');

    // 2. Calculate Chunk Sizes
    final totalLength = bodyLength;
    final chunkSize = (totalLength / chunks).ceil();
    final futures = <Future<void>>[];

    int receivedBytes = 0;
    final startTime = DateTime.now();

    for (int i = 0; i < chunks; i++) {
      final start = i * chunkSize;
      var end = (i + 1) * chunkSize - 1;
      if (end >= totalLength) end = totalLength - 1;

      futures.add(_downloadChunk(url, start, end, savePath, (bytes) {
        receivedBytes += bytes;
      }, headers: headers));
    }

    // 3. Monitor Progress
    final timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      final speed =
          elapsed > 0 ? (receivedBytes / (1024 * 1024)) / elapsed : 0.0;
      final percentage = (receivedBytes / totalLength) * 100;
      final remainingBytes = totalLength - receivedBytes;
      final etaSeconds =
          speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0;

      _progressController.add(DownloadProgress(
        percentage,
        speed,
        Duration(seconds: etaSeconds.toInt()),
      ));
    });

    try {
      await Future.wait(futures);
    } finally {
      timer.cancel();
      await raf.close();
      unawaited(_progressController.close());
    }
  }

  Future<void> _downloadChunk(
      String url, int start, int end, String savePath, Function(int) onBytes,
      {Map<String, String>? headers}) async {
    // Open a separate handle for each chunk to avoid stateful races on setPosition
    // and use FileMode.append to avoid truncation.
    final chunkFile = await File(savePath).open(mode: FileMode.append);
    try {
      final request = http.Request('GET', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);
      request.headers['Range'] = 'bytes=$start-$end';
      final response = await request.send();

      if (response.statusCode != 206 && response.statusCode != 200) {
        throw Exception('Chunk failed: ${response.statusCode}');
      }

      int currentPos = start;
      await for (final data in response.stream) {
        // Even with separate handles, some OSes might be picky,
        // but FileMode.append handle usually has its own seek pointer.
        await chunkFile.setPosition(currentPos);
        await chunkFile.writeFrom(data);
        currentPos += data.length;
        onBytes(data.length);
      }
    } finally {
      await chunkFile.close();
    }
  }

  Future<void> _downloadSingle(String url, RandomAccessFile raf,
      {Map<String, String>? headers}) async {
    print('[HamasDownloader] Initiating single-stream download...');
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    final response = await request.send();

    if (response.statusCode != 200 && response.statusCode != 206) {
      print(
          '[HamasDownloader] Error: GET failed with status ${response.statusCode}');
      return;
    }

    int total = response.contentLength ?? 0;
    int received = 0;
    final startTime = DateTime.now();

    await response.stream.listen((data) {
      raf.writeFromSync(data);
      received += data.length;
      if (total > 0) _reportProgress(received, total, startTime);
    }).asFuture();
    print(
        '[HamasDownloader] Single-stream download finished. Received $received bytes.');
  }

  void _reportProgress(int received, int total, DateTime startTime) {
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    final speed = elapsed > 0 ? (received / 1024 / 1024) / elapsed : 0.0;
    final percentage = (received / total) * 100;
    final remainingBytes = total - received;
    final etaSeconds = speed > 0 ? (remainingBytes / 1024 / 1024) / speed : 0;

    _progressController.add(DownloadProgress(
      percentage,
      speed,
      Duration(seconds: etaSeconds.toInt()),
    ));
  }
}
