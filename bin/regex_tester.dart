import 'dart:io';

void main() {
  final file = File('debug_player.js');
  if (!file.existsSync()) {
    print('debug_player.js not found!');
    return;
  }
  final js = file.readAsStringSync();

  // Test 1: N-Function Patterns
  print('--- Testing N-Func Patterns ---');
  final patterns = [
    r'\.set\("n",([a-zA-Z0-9$]+)\(',
    r'\.get\("n"\)\)&&\(b=b\.get\("n"\),c=([a-zA-Z0-9$]+)\[0\]\(b\)',
    r'([a-zA-Z0-9$]+)=function\(a\)\{var b=a\.split\(""\),c=\[',
    r'([a-zA-Z0-9$]+)=function\(a\)\{var b=a\.split\(""\),c=\1\.split',
    r'(?:var\s+)?fUr\s*=\s*\[([a-zA-Z0-9$]+)\]',
    // New candidates
    r'([a-zA-Z0-9$]+)=function\((\w+)\)\{return [a-zA-Z0-9$]+\[[a-zA-Z0-9$]+\[\d+\]\]\(this,\d+,\2\)\}',
  ];

  for (var p in patterns) {
    final matches = RegExp(p).allMatches(js);
    for (var m in matches) {
      print('[MATCH] Pattern: $p');
      print('   -> Group 1: ${m.group(1)}');
      if (m.groupCount >= 2) print('   -> Group 2: ${m.group(2)}');

      // Print context
      int start = m.start - 50;
      if (start < 0) start = 0;
      int end = m.end + 50;
      if (end > js.length) end = js.length;
      print(
        '   -> Context: ...${js.substring(start, end).replaceAll('\n', ' ')}...',
      );
    }
  }

  // Test 2: Search for usages of known VM-wrapper candidates
  // whV, IUo, Onn
  print('\n--- Testing Wrapper Candidates Usage ---');
  final candidates = ['whV', 'IUo', 'Onn'];
  for (var c in candidates) {
    final p = RegExp(r'[^a-zA-Z0-9$]' + RegExp.escape(c) + r'\(');
    final matches = p.allMatches(js);
    if (matches.isNotEmpty) {
      print('Candidate $c is called ${matches.length} times.');
      // Show first call context
      final m = matches.first;
      int start = m.start - 100;
      if (start < 0) start = 0;
      int end = m.end + 100;
      if (end > js.length) end = js.length;
      print(
        '   -> Usage: ...${js.substring(start, end).replaceAll('\n', ' ')}...',
      );
    } else {
      print('Candidate $c is NOT called directly.');
    }
  }

  // Test 3: Search for Decipher Function (split/join/splice)
  print('\n--- Testing Decipher Function ---');
  // Look for function with splice usage
  final spliceMatches = RegExp(
    r'function\(\w+,(\d+)\)\{\w+\.splice\(0,\1\)\}',
  ).allMatches(js);
  for (var m in spliceMatches) {
    print('[MATCH] Splice Function: ${m.group(0)}');
  }

  // Look for reverse
  final reverseMatches = RegExp(
    r'function\(\w+\)\{\w+\.reverse\(\)\}',
  ).allMatches(js);
  for (var m in reverseMatches) {
    print('[MATCH] Reverse Function: ${m.group(0)}');
  }

  // Broader split search - find variable assignment of split
  // e.g. a=a.split("") or var b=a.split("")
  final splitMatches = RegExp(
    r'''(\w+)=\1\.split\(['""]['""]\)''',
  ).allMatches(js);
  for (var m in splitMatches) {
    print('[MATCH] Var split itself: ${m.group(0)}');
    // context
    int start = m.start - 50;
    if (start < 0) start = 0;
    int end = m.end + 150;
    if (end > js.length) end = js.length;
    print(
      '   -> Context: ...${js.substring(start, end).replaceAll('\n', ' ')}...',
    );
  }
}
