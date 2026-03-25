import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';

const angular = 'package:angular/angular.dart';

/// A custom package resolver for Angular sources.
///
/// This is needed to resolve sources that import Angular.
final packageConfigFuture = loadPackageConfigUri(
  Platform.environment['ANGULAR_PACKAGE_CONFIG_PATH'] != null
      ? Uri.base.resolve(Platform.environment['ANGULAR_PACKAGE_CONFIG_PATH']!)
      : Isolate.packageConfigSync!,
);

/// Resolves [source] code as-if it is implemented with an AngularDart import.
///
/// Returns the resolved library as `package:test_lib/test_lib.dart`.
Future<LibraryElement> resolveLibrary(String source) async {
  final packageConfig = await packageConfigFuture;
  return resolveSource(
    '''
      library _test;
      import '$angular';\n\n$source
    ''',
    (resolver) async {
      var library = await resolver.findLibraryByName('_test');
      return library!;
    },
    inputId: AssetId('test_lib', 'lib/test_lib.dart'),
    packageConfig: packageConfig,
  );
}

/// Resolves [source] code as-if it is implemented with an AngularDart import.
///
/// Returns first `class` in the file, or by [name] if given.
Future<ClassElement?> resolveClass(String source, [String? name]) async {
  final library = await resolveLibrary(source);
  return name != null
      ? library.getClass(name)
      : library.definingCompilationUnit.classes.first;
}
