import 'package:build/build.dart';
import 'package:test/test.dart';
import 'package:angular_compiler/v1/cli.dart';
import 'package:angular_compiler/v1/src/compiler/expression_parser/parser.dart';
import 'package:angular_compiler/v1/src/compiler/schema/dom_element_schema_registry.dart';
import 'package:angular_compiler/v1/src/compiler/template_ast.dart';
import 'package:angular_compiler/v1/src/compiler/template_compiler.dart';
import 'package:angular_compiler/v1/src/compiler/template_parser/ast_template_parser.dart';
import 'package:angular_compiler/v2/context.dart';

import '../resolve_util.dart';
import 'template_humanizer_util.dart';

void main() {
  CompileContext.overrideForTesting();

  final expressionParser = ExpressionParser();
  final schemaRegistry = DomElementSchemaRegistry();
  final templateParser = AstTemplateParser(
    schemaRegistry,
    expressionParser,
    CompilerFlags(),
  );

  List<Object?> getHumanizedTemplate(
    NormalizedComponentWithViewDirectives component,
  ) {
    final componentMetadata = component.component;
    final templateAsts = templateParser.parse(
      componentMetadata,
      componentMetadata.template!.template!,
      component.directives,
      [],
      '',
      componentMetadata.template!.templateUrl ?? '',
    );
    return humanizeTplAst(templateAsts);
  }

  group('variable assigned NgFor locals', () {
    final nonInputsToReadFromFilesystem = <AssetId>{
      AssetId('angular', 'lib/angular.dart'),
      AssetId('angular', 'lib/src/meta.dart'),
      AssetId('angular', 'lib/src/meta/change_detection_constants.dart'),
      AssetId('angular', 'lib/src/meta/change_detection_link.dart'),
      AssetId('angular', 'lib/src/meta/di_arguments.dart'),
      AssetId('angular', 'lib/src/meta/di_generate_injector.dart'),
      AssetId('angular', 'lib/src/meta/di_modules.dart'),
      AssetId('angular', 'lib/src/meta/di_providers.dart'),
      AssetId('angular', 'lib/src/meta/di_tokens.dart'),
      AssetId('angular', 'lib/src/meta/directives.dart'),
      AssetId('angular', 'lib/src/meta/lifecycle_hooks.dart'),
      AssetId('angular', 'lib/src/meta/typed.dart'),
      AssetId('angular', 'lib/src/meta/view.dart'),
      AssetId('angular', 'lib/src/meta/visibility.dart'),
      AssetId('angular', 'lib/src/common/directives.dart'),
      AssetId('angular', 'lib/src/common/directives/ng_for.dart'),
      AssetId(
        'angular',
        'lib/src/core/change_detection/differs/default_iterable_differ.dart',
      ),
      AssetId('angular', 'lib/src/core/linker.dart'),
      AssetId('angular', 'lib/src/core/linker/view_container_ref.dart'),
      AssetId('angular', 'lib/src/core/linker/template_ref.dart'),
    };

    test('should be typed', () async {
      final component = await resolveAndFindComponent("""
        @Component(
          selector: 'app',
          template: '<div *ngFor="let value of values; let i=index; let length=count; let isFirst=first; let isLast=last; let isEven=even; let isOdd=odd"></div>',
          directives: const [NgFor],
        )
        class AppComponent {
          List<String> values;
        }""", nonInputsToReadFromFilesystem);
      final template = getHumanizedTemplate(component);
      expect(template, [
        [EmbeddedTemplateAst],
        [AttrAst, 'ngFor', ''],
        [VariableAst, 'value', r'$implicit', 'String'],
        [VariableAst, 'i', 'index', 'int'],
        [VariableAst, 'length', 'count', 'int'],
        [VariableAst, 'isFirst', 'first', 'bool'],
        [VariableAst, 'isLast', 'last', 'bool'],
        [VariableAst, 'isEven', 'even', 'bool'],
        [VariableAst, 'isOdd', 'odd', 'bool'],
        [DirectiveAst, component.directives.first], // NgFor
        [BoundDirectivePropertyAst, 'ngForOf', 'values'],
        [ElementAst, 'div'],
      ]);
    });

    test('should be typed dynamic if bound type is private', () async {
      final component = await resolveAndFindComponent("""
        @Component(
          selector: 'app',
          template: '<div *ngFor="let value of values"></div>',
          directives: const [NgFor],
        )
        class AppComponent {
          List<_Value> values;
        }

        class _Value {}""", nonInputsToReadFromFilesystem);
      final template = getHumanizedTemplate(component);
      expect(template, [
        [EmbeddedTemplateAst],
        [AttrAst, 'ngFor', ''],
        [VariableAst, 'value', r'$implicit', 'dynamic'],
        [DirectiveAst, component.directives.first], // NgFor
        [BoundDirectivePropertyAst, 'ngForOf', 'values'],
        [ElementAst, 'div'],
      ]);
    });

    test('should be typed if bound expression has receiver', () async {
      final component = await resolveAndFindComponent("""
        @Component(
          selector: 'app',
          template: '<div *ngFor="let value of values.reversed"></div>',
          directives: const [NgFor],
        )
        class AppComponent {
          List<int> values;
        }""", nonInputsToReadFromFilesystem);
      final template = getHumanizedTemplate(component);
      expect(template, [
        [EmbeddedTemplateAst],
        [AttrAst, 'ngFor', ''],
        [VariableAst, 'value', r'$implicit', 'int'],
        [DirectiveAst, component.directives.first], // NgFor
        [BoundDirectivePropertyAst, 'ngForOf', 'values.reversed'],
        [ElementAst, 'div'],
      ]);
    });
  });
}
