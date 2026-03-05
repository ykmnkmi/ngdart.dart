// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

final Map<String, String> deps = {
  'analyzer': '^6.11.0',
  'angular': '^8.0.0',
  'angular_ast': '^3.0.0',
  'angular_compiler': '^3.0.0',
  'angular_forms': '^5.0.0',
  'angular_router': '^4.0.0',
  'angular_test': '^5.0.0',
  'args': '^2.7.0',
  'async': '^2.13.0',
  'build': '^2.4.2',
  'build_resolvers': '^2.4.4',
  'build_runner': '^2.4.15',
  'build_test': '^2.2.3',
  'build_web_compilers': '^4.1.1',
  'built_collection': '^5.1.1',
  'built_value': '^8.12.4',
  'charcode': '^1.4.0',
  'code_builder': '^4.10.1',
  'collection': '^1.19.1',
  'csslib': '^1.0.2',
  'dart_style': '^3.0.1',
  'glob': '^2.1.3',
  'intl': '^0.20.2',
  'js': '^0.7.1',
  'lints': '^5.1.1',
  'logging': '^1.3.0',
  'meta': '^1.18.1',
  'mockito': '^5.4.5',
  'package_config': '^2.2.0',
  'path': '^1.9.1',
  'pub_semver': '^2.2.0',
  'source_gen': '^2.0.0',
  'source_span': '^1.10.2',
  'stream_transform': '^2.1.1',
  'string_scanner': '^1.4.1',
  'term_glyph': '^1.2.2',
  'test': '^1.26.3',
};

final _client = HttpClient();

Future<Map<String, dynamic>> fetchPackage(String name) async {
  final request = await _client.getUrl(
    Uri.parse('https://pub.dev/api/packages/$name'),
  );
  request.headers.set('Accept', 'application/vnd.pub.v2+json');
  final response = await request.close();
  if (response.statusCode != 200) {
    throw HttpException('Failed to fetch $name: ${response.statusCode}');
  }
  return jsonDecode(await response.transform(utf8.decoder).join())
      as Map<String, dynamic>;
}

bool isAtLeast(String version, String constraint) {
  final c = constraint.replaceFirst('^', '').split('.').map(int.parse).toList();
  final v = version.split('.').map(int.tryParse).toList();
  if (v.any((p) => p == null)) return false;

  final vNum = v[0]! * 1000000 + v[1]! * 1000 + v[2]!;
  final cNum = c[0] * 1000000 + c[1] * 1000 + c[2];
  return vNum >= cNum;
}

String fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _sdkConstraint(Map<String, dynamic> pubspec) {
  final env = pubspec['environment'];
  if (env is Map) {
    final sdk = env['sdk'];
    if (sdk is String) return sdk;
  }
  return '?';
}

void main() async {
  final rows =
      <(String package, String version, DateTime published, String sdk)>[];
  final errors = <String>[];
  final entries = deps.entries.toList();

  for (var i = 0; i < entries.length; i += 5) {
    final batch = entries.skip(i).take(5);
    final results = await Future.wait(batch.map((e) async {
      try {
        final data = await fetchPackage(e.key);
        final versions = data['versions'] as List;
        return [
          for (final entry in versions.cast<Map<String, dynamic>>())
            if (!(entry['pubspec']['version'] as String).contains('-') &&
                entry['retracted'] != true &&
                entry['published'] != null &&
                isAtLeast(entry['pubspec']['version'] as String, e.value))
              (
                e.key,
                entry['pubspec']['version'] as String,
                DateTime.parse(entry['published'] as String),
                _sdkConstraint(entry['pubspec']),
              ),
        ];
      } catch (err) {
        errors.add('${e.key}: $err');
        return <(String, String, DateTime, String)>[];
      }
    }));

    for (final list in results) {
      rows.addAll(list);
    }

    if (i + 5 < entries.length) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  _client.close();
  rows.sort((a, b) => a.$3.compareTo(b.$3));

  print('| Date | Package | Version | SDK |');
  print('| ---- | ------- | ------- | --- |');
  for (final (pkg, ver, date, sdk) in rows) {
    print('| ${fmtDate(date)} | $pkg | $ver | $sdk |');
  }

  if (errors.isNotEmpty) {
    print('\nERRORS:');
    for (final e in errors) {
      print('  $e');
    }
  }
}
