import 'dart:io';

// Helper to extract definitions (Simulated)
String? extractDefinition(String js, String name) {
  final funcRegex =
      RegExp(r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=\s*function\s*\(');
  var match = funcRegex.firstMatch(js);
  if (match != null) {
    final funcStart = js.lastIndexOf('function', match.end);
    final bodyStart = js.indexOf('{', funcStart);
    if (bodyStart != -1) {
      final bodyEnd = findMatchingBrace(js, bodyStart);
      if (bodyEnd != -1) {
        // Check if it was "var Name =" or just "Name ="
        // We always normalize to "var Name =" for safety in isolation
        return 'var $name = ' + js.substring(funcStart, bodyEnd + 1) + ';';
      }
    }
  }

  final funcDeclRegex = RegExp(r'function\s+' + RegExp.escape(name) + r'\s*\(');
  match = funcDeclRegex.firstMatch(js);
  if (match != null) {
    final bodyStart = js.indexOf('{', match.end);
    if (bodyStart != -1) {
      final bodyEnd = findMatchingBrace(js, bodyStart);
      if (bodyEnd != -1) return js.substring(match.start, bodyEnd + 1);
    }
  }

  // Pattern C with fix
  final varRegex =
      RegExp(r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=(?!=)\s*');
  match = varRegex.firstMatch(js);
  if (match != null) {
    final start = match.start;
    final startOfValue = match.end;

    if (startOfValue < js.length) {
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
            return js.substring(start, i + 1);
          }
        }
        i++;
      }
      return js.substring(start, i) + (js.endsWith(';') ? '' : ';');
    }
  }

  return null;
}

int findMatchingBrace(String js, int start,
    {String open = '{', String close = '}'}) {
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

bool hasDefinition(String js, String name) {
  // Simplified check
  // Use regex to avoid Yop=== false positive
  final p1 = RegExp(r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=\s*function');
  final p2 = RegExp(r'function\s+' + RegExp.escape(name) + r'\s*\(');
  final p3 = RegExp(r'(?:var\s+)?' + RegExp.escape(name) + r'\s*=(?!=)');

  return p1.hasMatch(js) || p2.hasMatch(js) || p3.hasMatch(js);
}

void main() {
  final content = File('debug_player.js').readAsStringSync();
  final funcName = 'jV';

  final definitions = <String, String>{};
  final queue = <String>[funcName];
  final visited = <String>{funcName};

  int iterations = 0;
  while (queue.isNotEmpty && iterations < 100) {
    final id = queue.removeAt(0);
    iterations++;

    // Skip if already in definitions map (visited doesn't guarantee definition presence if recursive loop)
    // Actually visited guarantees we queued it.

    final def = extractDefinition(content, id);
    if (def != null) {
      if (definitions.containsKey(id)) continue;
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
          'null',
          'true',
          'false',
          'typeof'
        ].contains(word)) continue;

        if (!visited.contains(word)) {
          if (hasDefinition(content, word)) {
            visited.add(word);
            queue.add(word);
          }
        }
      }
    }
  }

  print('--- GENERATED SCRIPT START ---');
  int line = 1;
  for (var def in definitions.values) {
    print('$line: $def');
    line++;
  }
  print('$line: $funcName("test");');
  print('--- GENERATED SCRIPT END ---');
}
