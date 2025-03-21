import 'package:collection/collection.dart' show IterableExtension;
import 'package:ngast/ngast.dart' as ast;
import 'package:ngcompiler/v1/cli.dart';
import 'package:ngcompiler/v1/src/compiler/chars.dart';
import 'package:ngcompiler/v1/src/compiler/compile_metadata.dart';
import 'package:ngcompiler/v1/src/compiler/expression_parser/ast.dart';
import 'package:ngcompiler/v1/src/compiler/expression_parser/parser.dart';
import 'package:ngcompiler/v1/src/compiler/html_tags.dart';
import 'package:ngcompiler/v1/src/compiler/i18n.dart';
import 'package:ngcompiler/v1/src/compiler/i18n/property_visitor.dart';
import 'package:ngcompiler/v1/src/compiler/identifiers.dart';
import 'package:ngcompiler/v1/src/compiler/parse_util.dart';
import 'package:ngcompiler/v1/src/compiler/provider_parser.dart';
import 'package:ngcompiler/v1/src/compiler/schema/element_schema_registry.dart';
import 'package:ngcompiler/v1/src/compiler/selector.dart';
import 'package:ngcompiler/v1/src/compiler/style_url_resolver.dart';
import 'package:ngcompiler/v1/src/compiler/template_ast.dart' as ng;
import 'package:ngcompiler/v1/src/compiler/template_optimize.dart';
import 'package:ngcompiler/v1/src/compiler/template_parser.dart';
import 'package:ngcompiler/v2/context.dart';
import 'package:source_span/source_span.dart';

import 'missing_directives_validator.dart';
import 'recursive_template_visitor.dart';

const _ngContentSelectAttr = 'select';
const _ngContentElement = 'ng-content';
const _linkElement = 'link';
const _linkStyleHrefAttr = 'href';
const _styleElement = 'style';
const _scriptElement = 'script';
const _templateElement = 'template';
final _textCssSelector = CssSelector.parse('*')[0];

/// A [TemplateParser] which uses the `ngast` package to parse angular
/// templates.
class AstTemplateParser {
  final CompilerFlags _flags;
  final ElementSchemaRegistry _schemaRegistry;
  final ExpressionParser _parser;

  AstTemplateParser(
    this._schemaRegistry,
    this._parser,
    this._flags,
  );

  /// Parses the template into a structured tree of [ng.TemplateAst] nodes.
  ///
  /// This parsing is done in multiple phases:
  /// 1. Parse the raw template using `ngast` package.
  /// 2. Post-process the raw [ast.TemplateAst] nodes.
  /// 3. Bind any matching Directives and Providers, converting into
  ///    [ng.TemplateAst] nodes.
  /// 4. Post-process the bound [ng.TemplateAst] nodes.
  ///
  /// We will collect parse errors for each phase, and only continue to the next
  /// phase if no errors have occurred.
  List<ng.TemplateAst> parse(
    CompileDirectiveMetadata compMeta,
    String template,
    List<CompileDirectiveMetadata?> directives,
    List<CompilePipeMetadata?> pipes,
    String name,
    String templateSourceUrl,
  ) {
    // This is a specific error handler that we pass to ngast that in turn
    // uses mechanics similar to CompileContext; it is intentionally separate in
    // order ot avoid a dependency on ngcompiler from ngast.
    final exceptionHandler = AstExceptionHandler(
      template,
      templateSourceUrl,
      name,
    );
    final parsedAst = ast.parse(
      template,
      exceptionHandler: exceptionHandler,
      sourceUrl: templateSourceUrl,
    );
    exceptionHandler.throwErrorsIfAny();
    if (parsedAst.isEmpty) return const [];

    final filteredAst = _processRawTemplateNodes(
      parsedAst,
      template: template,
      name: name,
      preserveWhitespace: compMeta.template!.preserveWhitespace ?? false,
    );
    CompileContext.current.throwRecoverableErrors();

    // TODO(b/155416570): Should it be filteredAst.first.sourceSpan?
    final providedAsts = _bindDirectivesAndProviders(
      directives,
      compMeta,
      filteredAst,
      parsedAst.first.sourceSpan,
    );
    CompileContext.current.throwRecoverableErrors();

    final processedAsts = _processBoundTemplateNodes(
      compMeta,
      providedAsts,
      pipes,
    );
    CompileContext.current.throwRecoverableErrors();

    return processedAsts;
  }

  List<ast.TemplateAst> _processRawTemplateNodes(
    List<ast.TemplateAst> parsedAst, {
    String? template,
    String? name,
    bool preserveWhitespace = false,
  }) {
    if (_flags.forceMinifyWhitespace) {
      logWarning('FORCING MINIFICATION');
      preserveWhitespace = false;
    }
    final implicNamespace = _applyImplicitNamespace(parsedAst);
    var filterElements = _filterElements(implicNamespace, preserveWhitespace);
    _validateTemplate(filterElements);
    return filterElements;
  }

  List<ng.TemplateAst> _bindDirectivesAndProviders(
    List<CompileDirectiveMetadata?> directives,
    CompileDirectiveMetadata compMeta,
    List<ast.TemplateAst> filteredAst,
    SourceSpan span,
  ) {
    final boundAsts = _bindDirectives(
      List<CompileDirectiveMetadata>.from(directives),
      compMeta,
      filteredAst,
    );
    _validateBoundDirectives(
      boundAsts,
      compMeta,
    );
    return _bindProviders(compMeta, boundAsts, span);
  }

  List<ng.TemplateAst> _processBoundTemplateNodes(
    CompileDirectiveMetadata compMeta,
    List<ng.TemplateAst> providedAsts,
    List<CompilePipeMetadata?> pipes,
  ) {
    final optimizedAsts = _optimize(compMeta, providedAsts);
    final sortedAsts = _sortInputs(optimizedAsts);
    _validatePipeNames(sortedAsts, pipes);
    return sortedAsts;
  }

  List<ast.TemplateAst> _filterElements(
      List<ast.TemplateAst?> parsedAst, bool preserveWhitespace) {
    var filteredElements = _ElementFilter().visitAll<ast.StandaloneTemplateAst>(
        parsedAst.cast<ast.StandaloneTemplateAst>());
    // New preserveWhitespace: false semantics (and preserveWhitespace: false).
    if (!preserveWhitespace) {
      return ast.MinimizeWhitespaceVisitor().visitAllRoot(filteredElements!);
    }
    return _PreserveWhitespaceVisitor().visitAll(filteredElements!);
  }

  List<ng.TemplateAst> _bindDirectives(
    List<CompileDirectiveMetadata> directives,
    CompileDirectiveMetadata compMeta,
    List<ast.TemplateAst> filteredAst,
  ) {
    final visitor = _BindDirectivesVisitor();
    final templateContext = TemplateContext(
      parser: _parser,
      schemaRegistry: _schemaRegistry,
      component: compMeta,
      directives: removeDuplicates(directives),
    );
    final context = _ParseContext.forRoot(templateContext);
    return visitor._visitAll(filteredAst, context);
  }

  void _validateBoundDirectives(
    List<ng.TemplateAst> boundAsts,
    CompileDirectiveMetadata componentMetadata,
  ) {
    if (componentMetadata.isOnPush) {
      _OnPushValidator().visitAll(boundAsts);
    }
  }

  List<ng.TemplateAst> _bindProviders(
    CompileDirectiveMetadata compMeta,
    List<ng.TemplateAst> visitedAsts,
    SourceSpan sourceSpan,
  ) {
    var providerViewContext = ProviderViewContext(compMeta, sourceSpan);
    final providerVisitor = _ProviderVisitor(providerViewContext);
    final providerContext = ProviderElementContext(
      providerViewContext,
      null,
      false,
      [],
      [],
      [],
      null,
    );
    final providedAsts = providerVisitor.visitAll(visitedAsts, providerContext);
    if (CompileContext.current.validateMissingDirectives) {
      MissingDirectiveValidator(_schemaRegistry).visitAll(providedAsts);
    }
    return providedAsts;
  }

  List<ng.TemplateAst> _optimize(
    CompileDirectiveMetadata compMeta,
    List<ng.TemplateAst> asts,
  ) =>
      OptimizeTemplateAstVisitor().visitAll(asts, compMeta);

  List<ng.TemplateAst> _sortInputs(List<ng.TemplateAst> asts) =>
      _SortInputsVisitor().visitAll(asts);

  List<ast.TemplateAst?> _applyImplicitNamespace(
    List<ast.TemplateAst> parsedAst,
  ) =>
      parsedAst.map((asNode) => asNode.accept(_NamespaceVisitor())).toList();

  void _validatePipeNames(
    List<ng.TemplateAst> parsedAsts,
    List<CompilePipeMetadata?> pipes,
  ) {
    var pipeValidator = _PipeValidator(removeDuplicates(pipes));
    for (final ast in parsedAsts) {
      ast.visit(pipeValidator, null);
    }
  }

  static void _validateTemplate(
    List<ast.TemplateAst> parsedAst,
  ) {
    for (final ast in parsedAst) {
      ast.accept(_TemplateValidator());
    }
  }
}

/// A visitor which binds directives to element nodes.
///
/// This visitor also converts from the pkg:ngast types to the angular
/// compiler types, which includes transformation of internationalized nodes.
class _BindDirectivesVisitor
    implements ast.TemplateAstVisitor<ng.TemplateAst?, _ParseContext> {
  /// A count of how many `<ng-content>` elements have been seen so far.
  ///
  /// This is necessary so that we can assign a unique index to each one as we
  /// visit it.
  int ngContentCount = 0;

  @override
  ng.TemplateAst visitElement(ast.ElementAst astNode,
      [_ParseContext? parentContext]) {
    final elementContext = _ParseContext.forElement(astNode, parentContext!);

    String? skipSchemaValidationForSelector = '';
    var skipOnPushValidation = false;
    for (final annotation in astNode.annotations) {
      switch (annotation.name) {
        case 'skipOnPushValidation':
          _validateSkipOnPushValidation(annotation, elementContext);
          skipOnPushValidation = true;
          break;
        case 'skipSchemaValidationFor':
          skipSchemaValidationForSelector = annotation.value;
          break;
      }
    }

    // Note: We rely on the fact that attributes are visited before properties
    // in order to ensure that properties take precedence over attributes with
    // the same name.
    return ng.ElementAst(
      astNode.name,
      _visitAll(astNode.attributes, elementContext),
      _visitProperties(astNode.properties, astNode.attributes, elementContext),
      _visitEvents(
        astNode.events,
        elementContext.boundHostListeners,
        elementContext,
      ),
      _visitAll(astNode.references, elementContext),
      elementContext.boundDirectives,
      [] /* providers */,
      null /* elementProviderUsage */,
      _visitChildren(astNode, elementContext),
      _findNgContentIndexForElement(astNode, parentContext),
      astNode.sourceSpan,
      parentContext.matchedNgContentSelectors,
      skipOnPushValidation: skipOnPushValidation,
      skipSchemaValidationForSelector: skipSchemaValidationForSelector!,
    );
  }

  /// Validates that a `@skipOnPushValidation` is used in the correct context.
  void _validateSkipOnPushValidation(
    ast.AnnotationAst annotation,
    _ParseContext context,
  ) {
    if (!context.templateContext.component.isOnPush) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        annotation.sourceSpan,
        'Can only be used in the template of a component using '
        '"ChangeDetectionStrategy.onPush"',
      ));
    }
    var componentAst = _ParseContext._firstComponent(context.boundDirectives);
    if (componentAst == null) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        annotation.sourceSpan,
        'Can only be applied to a component element',
      ));
    } else if (componentAst.directive.isOnPush) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        annotation.sourceSpan,
        'Can only be applied to a component using '
        '"ChangeDetectionStrategy.checkAlways"',
      ));
    }
  }

  List<ng.BoundElementPropertyAst> _visitProperties(
      List<ast.PropertyAst> properties,
      List<ast.AttributeAst> attributes,
      _ParseContext elementContext) {
    var visitedProperties =
        _visitAll<ng.BoundElementPropertyAst>(properties, elementContext);
    for (var attribute in attributes) {
      if (attribute.mustaches?.isNotEmpty ?? false) {
        var boundElementPropertyAst =
            _createPropertyForAttribute(attribute, elementContext);
        if (boundElementPropertyAst != null) {
          visitedProperties.add(boundElementPropertyAst);
        }
      }
    }
    return visitedProperties;
  }

  ng.BoundElementPropertyAst? _createPropertyForAttribute(
      ast.AttributeAst attribute, _ParseContext elementContext) {
    try {
      var parsedInterpolation = elementContext.templateContext.parser
          .parseInterpolation(attribute.value!, _location(attribute),
              elementContext.templateContext.exports);
      var boundValue = elementContext.createBoundValue(
          attribute.name, parsedInterpolation, attribute.sourceSpan);
      // May be null if the binding produced a recoverable error.
      if (boundValue == null) {
        return null;
      }
      if (elementContext.bindInterpolationToDirective(attribute, boundValue)) {
        return null;
      }
      return createElementPropertyAst(
        elementContext.elementName,
        attribute.name,
        boundValue,
        attribute.sourceSpan,
        elementContext.templateContext.schemaRegistry,
      );
    } on ParseException catch (e) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        attribute.sourceSpan,
        e.toString(),
      ));
      return null;
    }
  }

  /// Visit all events on an element.
  ///
  /// This includes both [events] bound in the template and
  /// [boundHostListerners] that bubble up from Directives that match the
  /// element.
  ///
  /// Any events that match a directive @Output are filtered out of the list,
  /// so only "DOM" events are returned. The matched events are "bound" to the
  /// [ng.DirectiveAst] as [ng.BoundDirectiveEventAst]s.
  List<ng.BoundEventAst> _visitEvents(
    List<ast.EventAst> events,
    List<_BoundHostListener> boundHostListeners,
    _ParseContext elementContext,
  ) =>
      [
        ..._visitAll(events, elementContext),
        ..._visitHostListeners(boundHostListeners, elementContext),
      ];

  static int? _findNgContentIndexForElement(
    ast.ElementAst astNode,
    _ParseContext context,
  ) {
    return context.findNgContentIndex(_elementSelector(astNode));
  }

  @override
  ng.TemplateAst visitContainer(ast.ContainerAst astNode,
      [_ParseContext? parentContext]) {
    final containerContext =
        _ParseContext.forContainer(astNode, parentContext!);
    return ng.NgContainerAst(
      _visitChildren(astNode, containerContext),
      astNode.sourceSpan,
    );
  }

  @override
  ng.TemplateAst visitEmbeddedTemplate(ast.EmbeddedTemplateAst astNode,
      [_ParseContext? parentContext]) {
    final embeddedContext = _ParseContext.forTemplate(astNode, parentContext!);
    _visitProperties(astNode.properties, astNode.attributes, embeddedContext);
    // <template> elements don't emit DOM events, so the return value can be
    // ignored.
    _visitEvents(
      astNode.events,
      embeddedContext.boundHostListeners,
      embeddedContext,
    );
    return ng.EmbeddedTemplateAst(
      _visitAll(astNode.attributes, embeddedContext),
      _visitAll(astNode.references, embeddedContext),
      _visitAll(astNode.letBindings, embeddedContext),
      embeddedContext.boundDirectives,
      [] /* providers */,
      null /* elementProviderUsage */,
      _visitChildren(astNode, embeddedContext),
      _findNgContentIndexForTemplate(astNode, parentContext),
      astNode.sourceSpan,
      parentContext.matchedNgContentSelectors,
    );
  }

  static int? _findNgContentIndexForTemplate(
    ast.EmbeddedTemplateAst astNode,
    _ParseContext? context,
  ) {
    if (_singleChildTemplate(astNode)) {
      final childNode = astNode.childNodes.single;
      if (childNode is ast.ElementAst) {
        return _findNgContentIndexForElement(childNode, context!);
      }
    }
    return context!.findNgContentIndex(_templateSelector(astNode));
  }

  /// Returns whether [astNode] is a synthetic single-child `<template>` node.
  ///
  /// Some examples include the use of a `*directive`.
  static bool _singleChildTemplate(ast.EmbeddedTemplateAst astNode) {
    final Object upcast = astNode;
    if (upcast is ast.SyntheticTemplateAst) {
      final origin = upcast.origin;
      if (origin is ast.StarAst) {
        return true;
      }
      return origin is ast.EmbeddedTemplateAst && _singleChildTemplate(origin);
    }
    return false;
  }

  @override
  ng.TemplateAst visitEmbeddedContent(ast.EmbeddedContentAst astNode,
      [_ParseContext? parentContext]) {
    final context = _ParseContext.forNgContent(astNode, parentContext!);
    return ng.NgContentAst(
        ngContentCount++,
        _findNgContentIndexForEmbeddedContent(context, astNode),
        astNode.sourceSpan,
        astNode.reference?.accept(this, context) as ng.ReferenceAst?);
  }

  int? _findNgContentIndexForEmbeddedContent(
          _ParseContext context, ast.EmbeddedContentAst astNode) =>
      context.findNgContentIndex(_embeddedContentSelector(astNode));

  CssSelector _embeddedContentSelector(ast.EmbeddedContentAst astNode) =>
      astNode.ngProjectAs != null
          ? CssSelector.parse(astNode.ngProjectAs!)[0]
          : createElementCssSelector(_ngContentElement, [
              [_ngContentSelectAttr, astNode.selector]
            ]);

  @override
  ng.TemplateAst? visitEvent(ast.EventAst astNode, [_ParseContext? context]) {
    try {
      var value = context!.templateContext.parser.parseAction(
          astNode.value, _location(astNode), context.templateContext.exports);
      var handler = ng.EventHandler(value);
      if (context.bindEventToDirective(
        astNode.name,
        astNode.sourceSpan,
        handler,
      )) {
        return null;
      }
      return ng.BoundEventAst(
          _getEventName(astNode), handler, astNode.sourceSpan);
    } on ParseException catch (e) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        e.toString(),
      ));
      return null;
    }
  }

  List<ng.BoundEventAst> _visitHostListeners(
      List<_BoundHostListener> hostListeners, _ParseContext context) {
    var events = <ng.BoundEventAst>[];
    for (var hostListener in hostListeners) {
      var event = _visitHostListener(hostListener, context);
      if (event != null) {
        events.add(event);
      }
    }
    return events;
  }

  ng.BoundEventAst? _visitHostListener(
      _BoundHostListener hostListener, _ParseContext context) {
    try {
      var value = context.templateContext.parser
          .parseAction(hostListener.value, '', context.templateContext.exports);
      var handler = ng.EventHandler(value, hostListener.directive);
      if (context.bindEventToDirective(
          hostListener.eventName, hostListener.sourceSpan, handler)) {
        return null;
      }
      return ng.BoundEventAst(
        hostListener.eventName,
        handler,
        hostListener.sourceSpan,
      );
    } on ParseException catch (e) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        hostListener.sourceSpan,
        e.toString(),
      ));
      return null;
    }
  }

  @override
  ng.TemplateAst? visitAttribute(ast.AttributeAst astNode,
      [_ParseContext? context]) {
    // If there is interpolation, then we will handle this node elsewhere.
    if (astNode.mustaches?.isNotEmpty ?? false) return null;
    context!.bindLiteralToDirective(astNode);
    final value = _createAttributeValue(astNode, context);
    return ng.AttrAst(astNode.name, value, astNode.sourceSpan);
  }

  ng.AttributeValue<Object> _createAttributeValue(
      ast.AttributeAst astNode, _ParseContext context) {
    if (context.isInternationalized(astNode.name)) {
      final metadata = context.i18nMetadata!.forAttributes[astNode.name]!;
      final message = I18nMessage(astNode.value!, metadata);
      return ng.I18nAttributeValue(message);
    } else {
      return ng.LiteralAttributeValue(astNode.value ?? '');
    }
  }

  @override
  ng.TemplateAst? visitProperty(ast.PropertyAst astNode,
      [_ParseContext? context]) {
    try {
      var parsedValue = context!.templateContext.parser.parseBinding(
          astNode.value ?? '',
          _location(astNode),
          context.templateContext.exports);
      var boundValue = context.createBoundValue(
          astNode.name, parsedValue, astNode.sourceSpan);
      // May return null if this binding produced a recoverable error.
      if (boundValue == null) {
        return null;
      }
      // Attempt binding to a directive input.
      if (context.bindPropertyToDirective(astNode, boundValue)) return null;

      // Properties on a <template> must be bound to directive inputs since
      // <template> is not an HTML element.
      if (context.isTemplate) {
        final name = astNode.name;
        var message = "Can't bind to '$name' since it isn't an input of any "
            'bound directive. Please check that the spelling is correct, and '
            "that the intended directive is included in the host component's "
            'list of directives.';
        if (name == 'ngForIn') {
          message = '$message\n\nThis is a common mistake when using *ngFor; '
              "did you mean to write 'of' instead of 'in'?";
        }
        CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
          astNode.sourceSpan,
          message,
        ));
        return null;
      }
      // Attempt binding to an HTML element property.
      return createElementPropertyAst(
        context.elementName,
        _getPropertyName(astNode),
        boundValue,
        astNode.sourceSpan,
        context.templateContext.schemaRegistry,
      );
    } on ParseException catch (e) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        e.toString(),
      ));
      return null;
    }
  }

  @override
  ng.TemplateAst visitLetBinding(ast.LetBindingAst astNode,
          [_ParseContext? _]) =>
      ng.VariableAst(astNode.name, astNode.value, astNode.sourceSpan);

  @override
  ng.TemplateAst visitReference(ast.ReferenceAst astNode,
          [_ParseContext? context]) =>
      ng.ReferenceAst(
          astNode.variable,
          context!.identifierForReference(astNode.identifier),
          astNode.sourceSpan);

  @override
  ng.TemplateAst visitText(ast.TextAst astNode, [_ParseContext? context]) =>
      ng.TextAst(astNode.value, context!.findNgContentIndex(_textCssSelector),
          astNode.sourceSpan);

  @override
  ng.TemplateAst? visitInterpolation(ast.InterpolationAst astNode,
      [_ParseContext? context]) {
    try {
      var element = context!.templateContext.parser.parseInterpolation(
          '{{${astNode.value}}}',
          _location(astNode),
          context.templateContext.exports)!;
      return ng.BoundTextAst(element,
          context.findNgContentIndex(_textCssSelector), astNode.sourceSpan);
    } on ParseException catch (e) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        e.toString(),
      ));
      return null;
    }
  }

  @override
  ng.TemplateAst visitBanana(ast.BananaAst astNode, [_ParseContext? _]) =>
      throw UnimplementedError('Don\'t know how to handle bananas');

  @override
  ng.TemplateAst visitCloseElement(ast.CloseElementAst astNode,
          [_ParseContext? _]) =>
      throw UnimplementedError('Don\'t know how to handle close elements');

  @override
  ng.TemplateAst? visitComment(ast.CommentAst astNode, [_ParseContext? _]) =>
      null;

  @override
  ng.TemplateAst visitStar(ast.StarAst astNode, [_ParseContext? _]) =>
      throw UnimplementedError('Don\'t know how to handle stars.');

  @override
  ng.TemplateAst visitAnnotation(ast.AnnotationAst astNode,
      [_ParseContext? context]) {
    throw UnimplementedError('Don\'t know how to handle annotations.');
  }

  List<T> _visitAll<T extends ng.TemplateAst?>(
      List<ast.TemplateAst> astNodes, _ParseContext context) {
    final results = <T>[];
    for (final astNode in astNodes) {
      var value = astNode.accept(this, context) as T?;
      if (value != null) {
        results.add(value);
      }
    }
    return results;
  }

  /// Visits [children], converting them for internationalization if necessary.
  List<ng.TemplateAst> _visitChildren(
    ast.StandaloneTemplateAst parent,
    _ParseContext context,
  ) {
    if (context.i18nMetadata!.forChildren != null) {
      return internationalize(
        parent,
        context.i18nMetadata!.forChildren!,
        context.findNgContentIndex(_textCssSelector),
      );
    }
    return _visitAll(parent.childNodes, context);
  }
}

class _ParseContext {
  final TemplateContext templateContext;
  final String elementName;
  final List<ng.DirectiveAst> boundDirectives;
  final List<_BoundHostListener> boundHostListeners;
  final I18nMetadataBundle? i18nMetadata;
  final bool isTemplate;
  final SelectorMatcher<int>? _ngContentIndexMatcher;
  final int? _wildcardNgContentIndex;
  final bool hasReferenceInNgContent;
  final List<CssSelector> matchedNgContentSelectors;

  _ParseContext._(
      this.templateContext,
      this.elementName,
      this.boundDirectives,
      this.boundHostListeners,
      this.i18nMetadata,
      this.isTemplate,
      this._ngContentIndexMatcher,
      this._wildcardNgContentIndex,
      this.matchedNgContentSelectors,
      {this.hasReferenceInNgContent = false});

  _ParseContext.forRoot(this.templateContext)
      : elementName = '',
        boundDirectives = const [],
        boundHostListeners = const [],
        i18nMetadata = null,
        isTemplate = false,
        _ngContentIndexMatcher = null,
        _wildcardNgContentIndex = null,
        matchedNgContentSelectors = [],
        hasReferenceInNgContent = false;

  factory _ParseContext.forContainer(
      ast.ContainerAst element, _ParseContext parent) {
    var templateContext = parent.templateContext;
    var i18nMetadata = parseI18nMetadata(element.annotations);
    _reportMissingI18nAttributesOrProperties(i18nMetadata, templateContext);
    return _ParseContext._(
      templateContext,
      '',
      const [],
      const [],
      i18nMetadata,
      false,
      parent._ngContentIndexMatcher,
      parent._wildcardNgContentIndex,
      parent.matchedNgContentSelectors,
    );
  }

  factory _ParseContext.forNgContent(
          ast.EmbeddedContentAst element, _ParseContext parent) =>
      _ParseContext._(
        parent.templateContext,
        'ng-content',
        [],
        [],
        null,
        false,
        parent._ngContentIndexMatcher,
        parent._wildcardNgContentIndex,
        parent.matchedNgContentSelectors,
        hasReferenceInNgContent: element.reference != null,
      );

  factory _ParseContext.forElement(
      ast.ElementAst element, _ParseContext parent) {
    var templateContext = parent.templateContext;
    var boundDirectives = _toAst(
        _matchElementDirectives(templateContext.directives, element),
        element.sourceSpan,
        element.name,
        _location(element),
        templateContext);
    var firstComponent = _firstComponent(boundDirectives);
    var i18nMetadata = parseI18nMetadata(element.annotations);
    _reportMissingI18nAttributesOrProperties(
      i18nMetadata,
      templateContext,
      attributes: element.attributes,
      properties: element.properties,
    );
    var hostListeners = _collectHostListeners(
      boundDirectives,
      element.sourceSpan,
      element.name,
      _location(element),
      templateContext,
    );
    return _ParseContext._(
        templateContext,
        element.name,
        boundDirectives,
        hostListeners,
        i18nMetadata,
        false,
        _createSelector(firstComponent),
        _findWildcardIndex(firstComponent),
        parent.matchedNgContentSelectors);
  }

  factory _ParseContext.forTemplate(
      ast.EmbeddedTemplateAst template, _ParseContext parent) {
    var templateContext = parent.templateContext;
    var boundDirectives = _toAst(
        _matchTemplateDirectives(templateContext.directives, template),
        template.sourceSpan,
        _templateElement,
        _location(template),
        templateContext);
    var firstComponent = _firstComponent(boundDirectives);
    var i18nMetadata = parseI18nMetadata(template.annotations);
    _reportMissingI18nAttributesOrProperties(
      i18nMetadata,
      templateContext,
      attributes: template.attributes,
      properties: template.properties,
    );

    var hostListeners = _collectHostListeners(
      boundDirectives,
      template.sourceSpan,
      _templateElement,
      _location(template),
      templateContext,
    );
    return _ParseContext._(
        templateContext,
        _templateElement,
        boundDirectives,
        hostListeners,
        i18nMetadata,
        true,
        _createSelector(firstComponent),
        _findWildcardIndex(firstComponent),
        parent.matchedNgContentSelectors);
  }

  CompileTokenMetadata? identifierForReference(String? identifier) {
    for (var directive in boundDirectives) {
      if ((identifier == null && directive.directive.isComponent) ||
          identifier != null && identifier == directive.directive.exportAs) {
        return identifierToken(directive.directive.type);
      }
    }
    if (isTemplate) {
      return Identifiers.templateRefToken;
    } else if (hasReferenceInNgContent) {
      return Identifiers.ngContentRefToken;
    } else {
      return null;
    }
  }

  void bindLiteralToDirective(ast.AttributeAst astNode) {
    final parsedValue = astNode.value == null
        ? ASTWithSource.missingSource(EmptyExpr())
        : ASTWithSource(
            LiteralPrimitive(astNode.value),
            astNode.value,
            _location(astNode),
          );
    // [boundValue] may be null if it is an invalid i18n literal.
    final boundValue =
        createBoundValue(astNode.name, parsedValue, astNode.sourceSpan);
    if (boundValue != null) {
      _bindToDirective(
          boundDirectives, astNode.name, boundValue, astNode.sourceSpan);
    }
  }

  bool bindPropertyToDirective(ast.PropertyAst astNode, ng.BoundValue value) =>
      _bindToDirective(boundDirectives, _getPropertyName(astNode), value,
          astNode.sourceSpan);

  bool bindInterpolationToDirective(
          ast.AttributeAst astNode, ng.BoundValue value) =>
      _bindToDirective(
          boundDirectives, astNode.name, value, astNode.sourceSpan);

  bool _bindToDirective(List<ng.DirectiveAst> directives, String name,
      ng.BoundValue value, SourceSpan sourceSpan) {
    var foundMatch = false;
    directive:
    for (var directive in directives) {
      for (var directiveName in directive.directive.inputs.keys) {
        var templateName = directive.directive.inputs[directiveName];
        if (templateName == name) {
          _removeExisting(directive.inputs, templateName);
          directive.inputs.add(ng.BoundDirectivePropertyAst(
              directiveName, templateName!, value, sourceSpan));
          foundMatch = true;
          continue directive;
        }
      }
    }
    return foundMatch;
  }

  /// Binds an event handler to all Directives that have a corresponding
  /// @Output.
  ///
  /// As such, we must visit every single Directive, even if we have already
  /// found a match.
  ///
  /// Returns [true] if one or more matches are found.
  bool bindEventToDirective(
      String name, SourceSpan sourceSpan, ng.EventHandler handler) {
    var foundMatch = false;
    directive:
    for (var directive in boundDirectives) {
      for (var directiveName in directive.directive.outputs.keys) {
        var templateName = directive.directive.outputs[directiveName];
        if (templateName == name) {
          directive.outputs.add(ng.BoundDirectiveEventAst(
            directiveName,
            templateName!,
            handler,
            sourceSpan,
          ));
          foundMatch = true;
          continue directive;
        }
      }
    }
    return foundMatch;
  }

  /// May return null if the value is internationalized but not a literal.
  ng.BoundValue? createBoundValue(
    String name,
    ASTWithSource? value,
    SourceSpan sourceSpan,
  ) {
    if (i18nMetadata!.forAttributes.containsKey(name)) {
      final metadata = i18nMetadata!.forAttributes[name]!;
      final message = i18nMessageFromPropertyBinding(
        value!,
        metadata,
        sourceSpan,
      );
      return message != null ? ng.BoundI18nMessage(message) : null;
    } else {
      return ng.BoundExpression(value!);
    }
  }

  void _removeExisting(
      List<ng.BoundDirectivePropertyAst> inputs, String? templateName) {
    var input =
        inputs.firstWhereOrNull((input) => input.templateName == templateName);
    if (input != null) {
      inputs.remove(input);
    }
  }

  bool isInternationalized(String attributeName) =>
      i18nMetadata!.forAttributes.containsKey(attributeName);

  int? findNgContentIndex(CssSelector selector) {
    if (_ngContentIndexMatcher == null) return _wildcardNgContentIndex;
    var ngContentIndices = <int>[];
    _ngContentIndexMatcher.match(selector, (selector, ngContentIndex) {
      matchedNgContentSelectors.add(selector);
      ngContentIndices.add(ngContentIndex);
    });
    ngContentIndices.sort();
    return ngContentIndices.isNotEmpty
        ? ngContentIndices.first
        : _wildcardNgContentIndex;
  }

  static List<ng.DirectiveAst> _toAst(
          Iterable<CompileDirectiveMetadata> directiveMetas,
          SourceSpan sourceSpan,
          String elementName,
          String location,
          TemplateContext templateContext) =>
      directiveMetas
          .map((directive) => ng.DirectiveAst(
                directive,
                inputs: [],
                outputs: [],
                sourceSpan: sourceSpan,
              ))
          .toList();

  static List<CompileDirectiveMetadata> _matchElementDirectives(
      List<CompileDirectiveMetadata> directives, ast.ElementAst astNode) {
    final matched = _matchDirectives(directives, _elementSelector(astNode));
    final filtered = _filterExcessComponents(matched);
    return filtered.toList();
  }

  static List<CompileDirectiveMetadata> _matchTemplateDirectives(
      List<CompileDirectiveMetadata> directives,
      ast.EmbeddedTemplateAst astNode) {
    final matched = _matchDirectives(directives, _templateSelector(astNode));
    // TODO(b/143898376): this shouldn't be necessary, since components
    // probably shouldn't be allowed here, but we'll add it just in case until
    // this bug is resolved.
    final filtered = _filterExcessComponents(matched);
    return filtered.toList();
  }

  static Iterable<CompileDirectiveMetadata> _matchDirectives(
      List<CompileDirectiveMetadata> directives,
      CssSelector elementCssSelector) {
    var matchedDirectives = <CompileDirectiveMetadata>{};
    _selectorMatcher(directives).match(elementCssSelector,
        (selector, directive) {
      matchedDirectives.add(directive);
    });
    // We return the directives in the same order that they are present in the
    // Component, not the order that they match in the html.
    return directives.where(matchedDirectives.contains);
  }

  static SelectorMatcher<CompileDirectiveMetadata> _selectorMatcher(
      List<CompileDirectiveMetadata> directives) {
    final selectorMatcher = SelectorMatcher<CompileDirectiveMetadata>();
    for (var directive in directives) {
      var selector = CssSelector.parse(directive.selector!);
      selectorMatcher.addSelectables(selector, directive);
    }
    return selectorMatcher;
  }

  /// Filters all but the first component in [directives].
  ///
  /// Only the first matching component is instantiated and used to configure
  /// providers. All subsequent components are dropped and have no effect on the
  /// view.
  static Iterable<CompileDirectiveMetadata> _filterExcessComponents(
      Iterable<CompileDirectiveMetadata> directives) {
    var hasComponent = false;
    return directives.where((directive) {
      if (directive.isComponent) {
        // Only the first component is retained.
        if (hasComponent) {
          // All subsequent components are dropped.
          return false;
        }
        hasComponent = true;
      }
      // All matching directives are retained.
      return true;
    });
  }

  /// Extracts all of the HostListeners from the bound directives for an
  /// element.
  ///
  /// These [_BoundHostListeners] will later be merged with any event handlers
  /// defined on the element in the template to create a full view of all
  /// handlers for an element's events.
  static List<_BoundHostListener> _collectHostListeners(
    List<ng.DirectiveAst> boundDirectives,
    SourceSpan sourceSpan,
    String elementName,
    String location,
    TemplateContext templateContext,
  ) {
    var result = <_BoundHostListener>[];
    for (var boundDirective in boundDirectives) {
      final directive = boundDirective.directive;
      // Don't collect component host event listeners because they're registered
      // by the component implementation.
      if (directive.isComponent) {
        continue;
      }
      for (var eventName in directive.hostListeners.keys) {
        var expression = directive.hostListeners[eventName];
        result.add(_BoundHostListener(
          eventName,
          expression,
          directive,
          sourceSpan, // TODO(alorenzen): Add sourceSpan to CompileDirectiveMetadata.
        ));
      }
    }
    return result;
  }

  static SelectorMatcher<int>? _createSelector(ng.DirectiveAst? component) {
    if (component == null) return null;
    var matcher = SelectorMatcher<int>();
    var ngContextSelectors = component.directive.template!.ngContentSelectors;
    for (var i = 0; i < ngContextSelectors.length; i++) {
      var selector = ngContextSelectors[i];
      if (selector != '*') {
        matcher.addSelectables(CssSelector.parse(selector), i);
      }
    }
    return matcher;
  }

  static int? _findWildcardIndex(ng.DirectiveAst? component) {
    if (component == null) return null;
    var ngContextSelectors = component.directive.template!.ngContentSelectors;
    for (var i = 0; i < ngContextSelectors.length; i++) {
      if (ngContextSelectors[i] == '*') return i;
    }
    return null;
  }

  static ng.DirectiveAst? _firstComponent(List<ng.DirectiveAst> directiveAsts) {
    var component = directiveAsts
        .firstWhereOrNull((directive) => directive.directive.isComponent);
    return component;
  }

  static void _reportMissingI18nAttributesOrProperties(
    I18nMetadataBundle i18nMetadata,
    TemplateContext templateContext, {
    Iterable<ast.AttributeAst> attributes = const [],
    Iterable<ast.PropertyAst> properties = const [],
  }) {
    final unmatched = i18nMetadata.forAttributes.keys.toSet()
      ..removeAll(attributes.map((a) => a.name))
      ..removeAll(properties.map((p) => p.name));
    for (final name in unmatched) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        i18nMetadata.forAttributes[name]!.origin,
        'Attempted to internationalize "$name", but no matching attribute or '
        'property found',
      ));
    }
  }
}

CssSelector _elementSelector(ast.ElementAst astNode) => _selector(
    astNode.name, astNode.attributes, astNode.properties, astNode.events);

CssSelector _templateSelector(ast.EmbeddedTemplateAst astNode) => _selector(
    _templateElement, astNode.attributes, astNode.properties, astNode.events);

CssSelector _selector(String elementName, List<ast.AttributeAst> attributes,
    List<ast.PropertyAst> properties, List<ast.EventAst> events) {
  final matchableAttributes = <List<String?>>[];
  for (var attr in attributes) {
    matchableAttributes.add([attr.name, attr.value]);
  }
  for (var property in properties) {
    matchableAttributes.add([_getPropertyName(property), property.value]);
  }
  for (var event in events) {
    matchableAttributes.add([_getEventName(event), event.value]);
  }
  return createElementCssSelector(elementName, matchableAttributes);
}

String _location(ast.TemplateAst? astNode) {
  if (astNode == null) {
    return '';
  }
  if (astNode.isSynthetic) {
    return _location((astNode as ast.SyntheticTemplateAst).origin);
  }
  return astNode.sourceSpan.sourceUrl.toString();
}

String _getPropertyName(ast.PropertyAst astNode) {
  if (astNode.unit != null) {
    return '${astNode.name}.${astNode.postfix}.${astNode.unit}';
  }
  if (astNode.postfix != null) {
    return '${astNode.name}.${astNode.postfix}';
  }
  return astNode.name;
}

String _getEventName(ast.EventAst event) =>
    ([event.name, ...event.reductions]).join('.');

/// Visitor which filters elements that are not supported in angular templates.
class _ElementFilter extends ast.RecursiveTemplateAstVisitor<void> {
  static const _securityUrl =
      'https://webdev.dartlang.org/angular/guide/security';

  @override
  ast.ElementAst? visitElement(ast.ElementAst astNode, [_]) {
    if (_filterElement(astNode)) {
      // TODO: Add a flag to upgrade this to an error.
      final warning = astNode.sourceSpan.message(
        ''
        'Ignoring <${astNode.name}>, as this element is unsafe to bind in '
        'a template without proper sanitization. This may become an error '
        'in future versions of AngularDart. See $_securityUrl for details.',
      );
      logWarning(warning);
      return null;
    }
    return super.visitElement(astNode) as ast.ElementAst;
  }

  static bool _filterElement(ast.ElementAst astNode) =>
      _filterScripts(astNode) ||
      _filterStyles(astNode) ||
      _filterStyleSheets(astNode);

  static bool _filterStyles(ast.ElementAst astNode) =>
      astNode.name.toLowerCase() == _styleElement;

  static bool _filterScripts(ast.ElementAst astNode) =>
      astNode.name.toLowerCase() == _scriptElement;

  static bool _filterStyleSheets(ast.ElementAst astNode) {
    if (astNode.name != _linkElement) return false;
    var href = _findHref(astNode.attributes);
    return isStyleUrlResolvable(href?.value);
  }

  static ast.AttributeAst? _findHref(List<ast.AttributeAst> attributes) {
    for (var attr in attributes) {
      if (attr.name.toLowerCase() == _linkStyleHrefAttr) return attr;
    }
    return null;
  }
}

/// Validates that all bound components use `ChangeDetectionStrategy.onPush`.
class _OnPushValidator extends InPlaceRecursiveTemplateVisitor<void> {
  @override
  void visitElement(ng.ElementAst ast, [_]) {
    if (!ast.skipOnPushValidation) {
      final componentAst = _ParseContext._firstComponent(ast.directives);
      if (componentAst != null && !componentAst.directive.isOnPush) {
        final name = componentAst.directive.type.name;
        logWarning(componentAst.sourceSpan.message(
          messages.warningForOnPushCompatibility(name),
        ));
      }
    }
    super.visitElement(ast, null);
  }
}

/// Visitor which binds providers to element nodes.
///
/// These providers are provided by the bound directives on the element or by
/// parent elements.
class _ProviderVisitor
    extends RecursiveTemplateVisitor<ProviderElementContext> {
  final ProviderViewContext _rootContext;

  _ProviderVisitor(this._rootContext);

  @override
  // We intentionally don't call super.visitElement() so that we can control
  // exactly when the children are visited.
  // ignore: MUST_CALL_SUPER
  ng.ElementAst visitElement(
    ng.ElementAst ast,
    ProviderElementContext? context,
  ) {
    var elementContext = ProviderElementContext(_rootContext, context, false,
        ast.directives, ast.attrs, ast.references, ast.sourceSpan);
    var children = <ng.TemplateAst>[];
    for (var child in ast.children) {
      children.add(child.visit(this, elementContext));
    }
    elementContext.afterElement();
    return ng.ElementAst(
      ast.name,
      ast.attrs,
      ast.inputs,
      ast.outputs,
      ast.references,
      elementContext.transformedDirectiveAsts,
      elementContext.transformProviders,
      elementContext,
      children,
      ast.ngContentIndex,
      ast.sourceSpan,
      ast.matchedNgContentSelectors,
      skipOnPushValidation: ast.skipOnPushValidation,
      skipSchemaValidationForSelector: ast.skipSchemaValidationForSelector,
      attributeDeps: elementContext.attributeDeps,
    );
  }

  @override
  // We intentionally don't call super.visitElement() so that we can control
  // exactly when the children are visited.
  // ignore: MUST_CALL_SUPER
  ng.EmbeddedTemplateAst visitEmbeddedTemplate(
    ng.EmbeddedTemplateAst ast,
    ProviderElementContext? context,
  ) {
    var elementContext = ProviderElementContext(_rootContext, context, true,
        ast.directives, ast.attrs, ast.references, ast.sourceSpan);
    var children = <ng.TemplateAst>[];
    for (var child in ast.children) {
      children.add(child.visit(this, elementContext));
    }
    elementContext.afterElement();
    ast.providers.addAll(elementContext.transformProviders);
    return ng.EmbeddedTemplateAst(
      ast.attrs,
      ast.references,
      ast.variables,
      elementContext.transformedDirectiveAsts,
      elementContext.transformProviders,
      elementContext,
      children,
      ast.ngContentIndex,
      ast.sourceSpan,
      ast.matchedNgContentSelectors,
    );
  }
}

/// Visitor that applies default namespaces to elements.
// TODO(alorenzen): Refactor this into pkg:ngast.
class _NamespaceVisitor extends ast.RecursiveTemplateAstVisitor<String> {
  @override
  ast.ElementAst visitElement(ast.ElementAst element, [String? parentPrefix]) {
    var prefix = _getNamespace(element.name) ?? parentPrefix;
    var visitedElement = super.visitElement(element, prefix) as ast.ElementAst;
    return ast.ElementAst.from(
        visitedElement,
        mergeNsAndName(prefix, _getName(visitedElement.name)),
        visitedElement.closeComplement,
        annotations: visitedElement.annotations,
        attributes: visitedElement.attributes,
        childNodes: visitedElement.childNodes,
        events: visitedElement.events,
        properties: visitedElement.properties,
        references: visitedElement.references,
        bananas: visitedElement.bananas,
        stars: visitedElement.stars);
  }

  String? _getNamespace(String name) {
    return _getNsPrefix(name) ??
        getHtmlTagDefinition(name).implicitNamespacePrefix;
  }

  @override
  ast.AttributeAst visitAttribute(ast.AttributeAst astNode,
      [String? parentPrefix]) {
    astNode = super.visitAttribute(astNode, parentPrefix) as ast.AttributeAst;
    if (_getNsPrefix(astNode.name) == null) return astNode;
    var names = astNode.name.split(':');
    return ast.AttributeAst.from(astNode, mergeNsAndName(names[0], names[1]),
        astNode.value, astNode.mustaches);
  }

  String? _getNsPrefix(String name) {
    var separatorIndex = name.indexOf(':');
    if (separatorIndex == -1) return null;
    return name.substring(0, separatorIndex);
  }

  String _getName(String name) {
    var separatorIndex = name.indexOf(':');
    if (separatorIndex == -1) return name;
    return name.substring(separatorIndex + 1);
  }
}

class _TemplateValidator extends ast.RecursiveTemplateAstVisitor<void> {
  @override
  ast.TemplateAst visitElement(ast.ElementAst astNode, [_]) {
    _findDuplicateAttributes(astNode.attributes);
    _findDuplicateProperties(astNode.properties);
    _findDuplicateEvents(astNode.events);
    return super.visitElement(astNode)!;
  }

  @override
  ast.TemplateAst visitEmbeddedTemplate(ast.EmbeddedTemplateAst astNode, [_]) {
    _findDuplicateAttributes(astNode.attributes);
    _findDuplicateProperties(astNode.properties);
    _findDuplicateEvents(astNode.events);
    return super.visitEmbeddedTemplate(astNode);
  }

  @override
  ast.TemplateAst visitAnnotation(ast.AnnotationAst astNode, [_]) {
    if ((astNode.name == i18nDescription ||
            astNode.name.startsWith(i18nDescriptionPrefix)) &&
        (astNode.value == null || astNode.value!.trim().isEmpty)) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'Requires a value describing the message to help translators',
      ));
    }
    if ((astNode.name == i18nLocale ||
            astNode.name.startsWith(i18nLocalePrefix)) &&
        (astNode.value == null || astNode.value!.trim().isEmpty)) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'Requires a value to specify a locale',
      ));
    }
    if ((astNode.name == i18nMeaning ||
            astNode.name.startsWith(i18nMeaningPrefix)) &&
        (astNode.value == null || astNode.value!.trim().isEmpty)) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'While optional, when specified the meaning must be non-empty to '
        'disambiguate from other equivalent messages',
      ));
    }
    if (astNode.name == 'skipSchemaValidationFor' &&
        (astNode.value == null || astNode.value!.trim().isEmpty)) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'Requires a CSS selector value that is used to allow custom tags, '
        'attributes, and events',
      ));
    }
    if (!(i18nRegExp.matchAsPrefix(astNode.name) != null ||
        astNode.name == 'preserveWhitespace' ||
        astNode.name == 'skipOnPushValidation' ||
        astNode.name == 'skipSchemaValidationFor')) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'Invalid annotation',
      ));
    }
    return super.visitAnnotation(astNode);
  }

  @override
  ast.TemplateAst visitEvent(ast.EventAst astNode, [_]) {
    if (_getEventName(astNode).contains(':')) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        '":" is not allowed in event names: ${_getEventName(astNode)}',
      ));
    }
    if (astNode.value == null || astNode.value!.isEmpty) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        'events must have a bound expresssion: ${_getEventName(astNode)}',
      ));
    }
    return super.visitEvent(astNode);
  }

  @override
  ast.TemplateAst visitReference(ast.ReferenceAst astNode, [_]) {
    if (astNode.variable.contains('-')) {
      CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
        astNode.sourceSpan,
        '"-" is not allowed in reference names',
      ));
    }
    return super.visitReference(astNode);
  }

  void _findDuplicateAttributes(List<ast.AttributeAst> attributes) {
    final seenAttributes = <String>{};
    for (final attribute in attributes) {
      if (seenAttributes.contains(attribute.name)) {
        CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
          attribute.sourceSpan,
          'Found multiple attributes with the same name: ${attribute.name}.',
        ));
      } else {
        seenAttributes.add(attribute.name);
      }
    }
  }

  void _findDuplicateProperties(List<ast.PropertyAst> properties) {
    final seenProperties = <String>{};
    for (final property in properties) {
      final propertyName = _getPropertyName(property);
      if (seenProperties.contains(propertyName)) {
        CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
          property.sourceSpan,
          'Found multiple properties with the same name: $propertyName.',
        ));
      } else {
        seenProperties.add(propertyName);
      }
    }
  }

  void _findDuplicateEvents(List<ast.EventAst> events) {
    final seenEvents = <String>{};
    for (final event in events) {
      final eventName = _getEventName(event);
      if (seenEvents.contains(eventName)) {
        CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
          event.sourceSpan,
          'Found multiple events with the same name: $eventName. You should '
          'merge the handlers into a single statement.',
        ));
      } else {
        seenEvents.add(eventName);
      }
    }
  }
}

/// Visitor that verifies all pipe invocations in the template are valid.
///
/// First, we visit all [AST] values to extract the pipe invocations in the
/// template. Then we verify that each pipe is defined by a
/// [CompilePipeMetadata] entry, and invoked with the correct number of
/// arguments.
class _PipeValidator extends RecursiveTemplateVisitor<void> {
  final Map<String?, CompilePipeMetadata?> _pipesByName;

  factory _PipeValidator(
    List<CompilePipeMetadata?> pipes,
  ) {
    final pipesByName = <String?, CompilePipeMetadata?>{};
    for (var pipe in pipes) {
      pipesByName[pipe!.name] = pipe;
    }
    return _PipeValidator._(pipesByName);
  }

  _PipeValidator._(this._pipesByName);

  void _validatePipes(ASTWithSource ast, SourceSpan sourceSpan) {
    var collector = _PipeCollector();
    ast.ast.visit(collector);
    for (var pipeName in collector.pipeInvocations.keys) {
      final pipe = _pipesByName[pipeName];
      if (pipe == null) {
        CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
          sourceSpan,
          "The pipe '$pipeName' could not be found.",
        ));
      } else {
        for (var numArgs in collector.pipeInvocations[pipeName]!) {
          // Don't include the required parameter to the left of the pipe name.
          final numParams = pipe.transformType!.paramTypes.length - 1;
          if (numArgs > numParams) {
            CompileContext.current.reportAndRecover(BuildError.forSourceSpan(
              sourceSpan,
              "The pipe '$pipeName' was invoked with too many arguments: "
              '$numParams expected, but $numArgs found.',
            ));
          }
        }
      }
    }
  }

  @override
  ng.TemplateAst visitBoundText(ng.BoundTextAst ast, _) {
    _validatePipes(ast.value, ast.sourceSpan);
    return super.visitBoundText(ast, null);
  }

  @override
  ng.TemplateAst visitDirectiveProperty(ng.BoundDirectivePropertyAst ast, _) {
    final value = ast.value;
    if (value is ng.BoundExpression) {
      _validatePipes(value.expression, ast.sourceSpan);
    }
    return super.visitDirectiveProperty(ast, null);
  }

  @override
  ng.TemplateAst visitElementProperty(ng.BoundElementPropertyAst ast, _) {
    final boundValue = ast.value;
    if (boundValue is ng.BoundExpression) {
      _validatePipes(boundValue.expression, ast.sourceSpan);
    }
    return super.visitElementProperty(ast, null);
  }

  @override
  ng.TemplateAst visitEvent(ng.BoundEventAst ast, _) {
    _validatePipes(ast.handler.expression, ast.sourceSpan);
    return super.visitEvent(ast, null);
  }
}

class _PipeCollector extends RecursiveAstVisitor<void> {
  /// Records the number of arguments of each pipe invocation by name.
  ///
  /// Note this is the number of arguments specified to the right-hand side of
  /// the pipe binding. This does not include the required argument to the left-
  /// hand side of the '|'.
  final Map<String, List<int>> pipeInvocations = {};

  @override
  void visitPipe(BindingPipe ast, void context) {
    (pipeInvocations[ast.name] ??= []).add(ast.args.length);
    ast.exp.visit(this);
    visitAll(ast.args, context);
  }
}

class _PreserveWhitespaceVisitor extends ast.IdentityTemplateAstVisitor<void> {
  List<T> visitAll<T extends ast.TemplateAst>(List<T> astNodes) {
    final result = <T>[];
    for (var i = 0; i < astNodes.length; i++) {
      var node = astNodes[i];
      final visited = node is ast.TextAst
          ? _stripWhitespace(i, node, astNodes)
          : node.accept(this);
      if (visited != null) result.add(visited as T);
    }
    return result;
  }

  @override
  ast.ContainerAst visitContainer(ast.ContainerAst astNode, [void context]) {
    var children = visitAll(astNode.childNodes);
    astNode.childNodes.clear();
    astNode.childNodes.addAll(children);
    return astNode;
  }

  @override
  ast.ElementAst visitElement(ast.ElementAst astNode, [void context]) {
    var children = visitAll(astNode.childNodes);
    astNode.childNodes.clear();
    astNode.childNodes.addAll(children);
    return astNode;
  }

  @override
  ast.EmbeddedTemplateAst visitEmbeddedTemplate(
    ast.EmbeddedTemplateAst astNode, [
    void context,
  ]) {
    var children = visitAll(astNode.childNodes);
    astNode.childNodes.clear();
    astNode.childNodes.addAll(children);
    return astNode;
  }

  ast.TextAst _stripWhitespace(
    int i,
    ast.TextAst node,
    List<ast.TemplateAst> astNodes,
  ) {
    return ast.TextAst.from(node, replaceNgSpace(node.value));
  }
}

class _SortInputsVisitor extends RecursiveTemplateVisitor<void> {
  @override
  ng.DirectiveAst visitDirective(ng.DirectiveAst ast, void context) {
    ast.inputs.sort(_orderingOf(ast.directive.inputs));
    return super.visitDirective(ast, null) as ng.DirectiveAst;
  }

  Comparator<ng.BoundDirectivePropertyAst> _orderingOf(
      Map<String, String> inputs) {
    final keys = inputs.keys.toList(growable: false);
    int indexOf(ng.BoundDirectivePropertyAst input) {
      return keys.indexOf(input.memberName);
    }

    return (ng.BoundDirectivePropertyAst a, ng.BoundDirectivePropertyAst b) =>
        Comparable.compare(indexOf(a), indexOf(b));
  }
}

/// A simple wrapper on a HostListener from a Directive that was bound to an
/// element in the template.
class _BoundHostListener {
  final String eventName;
  final String? value;
  final CompileDirectiveMetadata directive;
  final SourceSpan sourceSpan;

  _BoundHostListener(
    this.eventName,
    this.value,
    this.directive,
    this.sourceSpan,
  );
}

/// Returns the matched components with this element ast in the [directives].
List<CompileDirectiveMetadata> matchElementDirectives(
  List<CompileDirectiveMetadata> directives,
  ast.ElementAst astNode,
) =>
    _ParseContext._matchElementDirectives(directives, astNode);
