/// Minimal version parsing and range matching, enough for pins like
/// `20`, `v20.11.0`, `lts/*`, `^18.2.0`, `>=18 <21`, `~3.11`, `3.x`.
class Ver implements Comparable<Ver> {
  Ver(this.parts, [this.pre = '']);

  final List<int> parts;
  final String pre;

  static Ver? tryParse(String input) {
    final m = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+.]?([0-9A-Za-z.\-]+))?').firstMatch(input.trim());
    if (m == null) return null;
    final parts = [int.parse(m[1]!)];
    if (m[2] != null) parts.add(int.parse(m[2]!));
    if (m[3] != null) parts.add(int.parse(m[3]!));
    return Ver(parts, m[4] ?? '');
  }

  int part(int i) => i < parts.length ? parts[i] : 0;
  bool get isPrerelease => pre.contains(RegExp(r'pre|beta|alpha|rc|dev', caseSensitive: false));

  @override
  int compareTo(Ver other) {
    for (var i = 0; i < 3; i++) {
      final c = part(i).compareTo(other.part(i));
      if (c != 0) return c;
    }
    if (pre.isEmpty && other.pre.isNotEmpty) return 1;
    if (pre.isNotEmpty && other.pre.isEmpty) return -1;
    return pre.compareTo(other.pre);
  }

  bool operator >(Ver o) => compareTo(o) > 0;
  bool operator <(Ver o) => compareTo(o) < 0;
  bool operator >=(Ver o) => compareTo(o) >= 0;
  bool operator <=(Ver o) => compareTo(o) <= 0;

  @override
  String toString() => parts.join('.') + (pre.isEmpty ? '' : '-$pre');
}

int compareVersions(String a, String b) {
  final va = Ver.tryParse(a), vb = Ver.tryParse(b);
  if (va == null || vb == null) return a.compareTo(b);
  return va.compareTo(vb);
}

/// Whether [version] satisfies [spec]. Unknown specs return false.
bool satisfies(String version, String spec) {
  final v = Ver.tryParse(version);
  if (v == null) return false;
  spec = spec.trim();
  if (spec.isEmpty || spec == '*' || spec == 'latest') return true;
  // "a || b"
  if (spec.contains('||')) {
    return spec.split('||').any((s) => satisfies(version, s));
  }
  // "a - b"
  final hyphen = RegExp(r'^(\S+)\s+-\s+(\S+)$').firstMatch(spec);
  if (hyphen != null) {
    return satisfies(version, '>=${hyphen[1]}') && satisfies(version, '<=${hyphen[2]}');
  }
  // space separated comparators are AND-ed
  final comparators = spec.split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
  return comparators.every((c) => _single(v, c));
}

bool _single(Ver v, String c) {
  final m = RegExp(r'^(\^|~|>=|<=|>|<|=)?\s*v?(.*)$').firstMatch(c)!;
  final op = m[1] ?? '';
  final body = m[2]!.replaceAll(RegExp(r'\.[xX*]'), '');
  final target = Ver.tryParse(body);
  if (target == null) return false;
  final given = target.parts.length;
  switch (op) {
    case '>=':
      return v >= target;
    case '<=':
      return v <= target || _prefixMatch(v, target);
    case '>':
      return v > target && !_prefixMatch(v, target);
    case '<':
      return v < target;
    case '^':
      if (v < target) return false;
      if (target.part(0) != 0) return v.part(0) == target.part(0);
      if (target.part(1) != 0) return v.part(0) == 0 && v.part(1) == target.part(1);
      return v.part(0) == 0 && v.part(1) == 0 && v.part(2) == target.part(2);
    case '~':
      if (v < target) return false;
      if (given == 1) return v.part(0) == target.part(0);
      return v.part(0) == target.part(0) && v.part(1) == target.part(1);
    default:
      return _prefixMatch(v, target);
  }
}

/// `20` matches 20.x.x, `20.11` matches 20.11.x, `20.11.0` matches exactly.
bool _prefixMatch(Ver v, Ver target) {
  for (var i = 0; i < target.parts.length; i++) {
    if (v.part(i) != target.part(i)) return false;
  }
  return target.parts.length < 3 || v.pre == target.pre || target.pre.isEmpty;
}

/// Picks the highest of [versions] that satisfies [spec].
String? bestMatch(Iterable<String> versions, String spec) {
  String? best;
  for (final v in versions) {
    if (!satisfies(v, spec)) continue;
    if (best == null || compareVersions(v, best) > 0) best = v;
  }
  return best;
}
