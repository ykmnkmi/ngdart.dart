// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

final Map<String, String> deps = {
  'analyzer': '^7.7.0',
  'angular': '^8.0.0',
  'angular_ast': '^3.0.0',
  'angular_compiler': '^3.0.0',
  'angular_forms': '^5.0.0',
  'angular_router': '^4.0.0',
  'angular_test': '^5.0.0',
  'args': '^2.7.0',
  'async': '^2.13.1',
  'build': '^2.5.4',
  'build_modules': '^5.0.14',
  'build_resolvers': '^2.5.4',
  'build_runner': '^2.5.4',
  'build_test': '^3.2.1',
  'build_web_compilers': '^4.2.0',
  'built_collection': '^5.1.1',
  'built_value': '^8.12.5',
  'charcode': '^1.4.0',
  'code_builder': '^4.10.1',
  'collection': '^1.19.1',
  'csslib': '^1.0.2',
  'dart_style': '^3.1.0',
  'glob': '^2.1.3',
  'intl': '^0.20.2',
  'js': '^0.7.2',
  'lints': '^6.1.0',
  'logging': '^1.3.0',
  'meta': '^1.18.2',
  'mockito': '^5.4.6',
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

Future<Map<String, Object?>> fetchPackage(String name) async {
  var request = await _client.getUrl(
    Uri.parse('https://pub.dev/api/packages/$name'),
  );

  request.headers.set('Accept', 'application/vnd.pub.v2+json');

  var response = await request.close();

  if (response.statusCode != 200) {
    throw HttpException('Failed to fetch $name: ${response.statusCode}');
  }

  return jsonDecode(await response.transform(utf8.decoder).join())
      as Map<String, Object?>;
}

bool isAtLeast(String version, String constraint) {
  var c = constraint.replaceFirst('^', '').split('.').map(int.parse).toList();
  var v = version.split('.').map(int.tryParse).toList();

  for (var p in v) {
    if (p == null) {
      return false;
    }
  }

  var vNum = v[0]! * 1000000 + v[1]! * 1000 + v[2]!;
  var cNum = c[0] * 1000000 + c[1] * 1000 + c[2];
  return vNum >= cNum;
}

String fmtDate(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _sdkConstraint(Map<String, dynamic> pubspec) {
  var env = pubspec['environment'];

  if (env is Map) {
    var sdk = env['sdk'];

    if (sdk is String) {
      return sdk;
    }
  }

  return '?';
}

void main() async {
  var rows =
      <(String package, String version, DateTime published, String sdk)>[];

  var errors = <String>[];
  var entries = deps.entries.toList();

  for (var i = 0; i < entries.length; i += 5) {
    var batch = entries.skip(i).take(5);
    var results = await Future.wait(
      batch.map((e) async {
        try {
          var data = await fetchPackage(e.key);
          var versions = data['versions'] as List;
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
      }),
    );

    for (var list in results) {
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

  for (var (pkg, ver, date, sdk) in rows) {
    print('| ${fmtDate(date)} | $pkg | $ver | $sdk |');
  }

  if (errors.isNotEmpty) {
    print('\nERRORS:');

    for (var e in errors) {
      print('  $e');
    }
  }
}
