import 'dart:io';

final packageEntryRe = RegExp('^  (\\w+): (.+)', multiLine: true);
final versionEntryRe = RegExp('^(\\w+): ([^#]+)?', multiLine: true);

void main() {
  var versionsUri = Uri(path: 'tool/package_versions.yaml');
  var resolvedVersionsUri = Directory.current.uri.resolveUri(versionsUri);
  var versionsFile = File.fromUri(resolvedVersionsUri);

  var versions = <String, String>{};

  for (var version in versionsFile.readAsLinesSync()) {
    if (version.isEmpty) {
      continue;
    }

    var match = versionEntryRe.firstMatch(version);

    if (match != null) {
      versions[match[1]!] = match[2]!.trim();
    }
  }

  // Repository root.
  var entities = Directory.current.listSync(recursive: true);

  late Directory directory;

  String replace(Match match) {
    var name = match[1]!;
    var version = versions[name];

    if (version == null) {
      throw UnsupportedError('Package $name in ${directory.path}');
    }

    return '  $name: $version';
  }

  for (var entity in entities) {
    if (entity is! Directory) {
      continue;
    }

    if (entity.path.startsWith('.')) {
      continue;
    }

    directory = entity;

    var pubspecFile = File.fromUri(directory.uri.resolve('pubspec.yaml'));

    if (pubspecFile.existsSync()) {
      var oldPubspec = pubspecFile.readAsStringSync();
      var newContent = oldPubspec.replaceAllMapped(packageEntryRe, replace);
      pubspecFile.writeAsStringSync(newContent);
    }
  }
}
