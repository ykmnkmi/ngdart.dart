part 'lexeme.dart';
part 'token_types.dart';

abstract class NgBaseToken<T> {
  int get offset;
  int get end;
  int get length;
  String get lexeme;
  T get type;
}

/// Represents string tokens that are of interest to the parser.
///
/// Clients should not extend, implement, or mix-in this class.
class NgSimpleToken implements NgBaseToken<NgSimpleTokenType> {
  factory NgSimpleToken.atSign(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.atSign, offset);
  }

  factory NgSimpleToken.backSlash(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.backSlash, offset);
  }

  factory NgSimpleToken.bang(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.bang, offset);
  }

  factory NgSimpleToken.closeBanana(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.closeBanana, offset);
  }

  factory NgSimpleToken.closeBracket(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.closeBracket, offset);
  }

  factory NgSimpleToken.closeParen(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.closeParen, offset);
  }

  factory NgSimpleToken.closeTagStart(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.closeTagStart, offset);
  }

  factory NgSimpleToken.commentBegin(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.commentBegin, offset);
  }

  factory NgSimpleToken.commentEnd(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.commentEnd, offset);
  }

  factory NgSimpleToken.dash(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.dash, offset);
  }

  factory NgSimpleToken.openTagStart(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.openTagStart, offset);
  }

  factory NgSimpleToken.tagEnd(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.tagEnd, offset);
  }

  factory NgSimpleToken.eof(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.eof, offset);
  }

  factory NgSimpleToken.equalSign(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.equalSign, offset);
  }

  factory NgSimpleToken.forwardSlash(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.forwardSlash, offset);
  }

  factory NgSimpleToken.hash(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.hash, offset);
  }

  factory NgSimpleToken.identifier(int offset, String lexeme) {
    return _LexemeNgSimpleToken(
        offset, lexeme, lexeme.length, NgSimpleTokenType.identifier);
  }

  factory NgSimpleToken.mustacheBegin(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.mustacheBegin, offset);
  }

  factory NgSimpleToken.mustacheEnd(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.mustacheEnd, offset);
  }

  factory NgSimpleToken.openBanana(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.openBanana, offset);
  }

  factory NgSimpleToken.openBracket(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.openBracket, offset);
  }

  factory NgSimpleToken.openParen(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.openParen, offset);
  }

  factory NgSimpleToken.percent(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.percent, offset);
  }

  factory NgSimpleToken.period(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.period, offset);
  }

  factory NgSimpleToken.star(int offset) {
    return NgSimpleToken._(NgSimpleTokenType.star, offset);
  }

  factory NgSimpleToken.text(int offset, String lexeme) {
    return _LexemeNgSimpleToken(
        offset, lexeme, lexeme.length, NgSimpleTokenType.text);
  }

  factory NgSimpleToken.decodedText(
      int offset, String lexeme, int originalLength) {
    return _LexemeNgSimpleToken(
        offset, lexeme, originalLength, NgSimpleTokenType.text);
  }

  factory NgSimpleToken.unexpectedChar(int offset, String lexeme) {
    return _LexemeNgSimpleToken(
        offset, lexeme, lexeme.length, NgSimpleTokenType.unexpectedChar);
  }

  factory NgSimpleToken.voidCloseTag(int offset) {
    return NgSimpleToken(NgSimpleTokenType.voidCloseTag, offset);
  }

  factory NgSimpleToken.whitespace(int offset, String lexeme) {
    return _LexemeNgSimpleToken(
        offset, lexeme, lexeme.length, NgSimpleTokenType.whitespace);
  }

  const NgSimpleToken._(
    this.type,
    this.offset, {
    bool errorSynthetic = false,
  });

  NgSimpleToken(
    this.type,
    this.offset,
  );

  @override
  bool operator ==(Object other) {
    return other is NgSimpleToken &&
        other.offset == offset &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(offset, type);
  @override
  int get end => offset + length;
  @override
  int get length => lexeme.length;

  @override
  final int offset;
  @override
  final NgSimpleTokenType type;
  @override
  String get lexeme => type.symbols;

  @override
  String toString() => '#$NgSimpleToken($type) {$offset:$lexeme}';
}

class NgSimpleQuoteToken extends _LexemeNgSimpleToken {
  factory NgSimpleQuoteToken.doubleQuotedText(
    int offset,
    String lexeme,
    bool isClosed,
  ) {
    return NgSimpleQuoteToken(
        NgSimpleTokenType.doubleQuote, offset, lexeme, isClosed);
  }

  factory NgSimpleQuoteToken.singleQuotedText(
    int offset,
    String lexeme,
    bool isClosed,
  ) {
    return NgSimpleQuoteToken(
        NgSimpleTokenType.singleQuote, offset, lexeme, isClosed);
  }

  /// Offset of quote contents.
  final int contentOffset;

  /// String of just the contents
  final String contentLexeme;

  /// End of content
  int get contentEnd => contentOffset + contentLength;

  /// Offset of right quote; may be `null` to indicate unclosed.
  final int? quoteEndOffset;

  NgSimpleQuoteToken(
      NgSimpleTokenType type, int offset, String lexeme, bool isClosed,
      {bool isErrorSynthetic = false})
      : contentOffset = offset + 1,
        contentLexeme = lexeme.isEmpty
            ? lexeme
            : lexeme.substring(1, isClosed ? lexeme.length - 1 : lexeme.length),
        quoteEndOffset = isClosed ? offset + lexeme.length - 1 : null,
        super(
          offset,
          lexeme,
          lexeme.length,
          type,
        );

  @override
  bool operator ==(Object other) {
    return other is NgSimpleQuoteToken &&
        other.offset == offset &&
        other.type == type &&
        other.contentOffset == contentOffset &&
        other.quoteEndOffset == quoteEndOffset;
  }

  /// Lexeme including quotes.
  bool get isClosed => quoteEndOffset != null;
  int get contentLength => contentLexeme.length;

  @override
  int get hashCode => Object.hash(super.hashCode, lexeme, contentOffset, end);

  @override
  String toString() => '#$NgSimpleQuoteToken($type) {$offset:$lexeme}';
}

/// Represents a Angular text/token entities.
///
/// Clients should not extend, implement, or mix-in this class.
class NgToken implements NgBaseToken<NgTokenType> {
  factory NgToken.generateErrorSynthetic(int offset, NgTokenType type,
      {String lexeme = ''}) {
    if (type == NgTokenType.beforeElementDecorator ||
        type == NgTokenType.elementDecoratorValue ||
        type == NgTokenType.elementDecorator ||
        type == NgTokenType.elementIdentifier ||
        type == NgTokenType.interpolationValue ||
        type == NgTokenType.text ||
        type == NgTokenType.whitespace ||
        type == NgTokenType.commentValue) {
      return _LexemeNgToken(offset, lexeme, type, errorSynthetic: true);
    }
    return NgToken._(type, offset, errorSynthetic: true);
  }

  factory NgToken.annotationPrefix(int offset) {
    return NgToken._(NgTokenType.annotationPrefix, offset);
  }

  factory NgToken.bananaPrefix(int offset) {
    return NgToken._(NgTokenType.bananaPrefix, offset);
  }

  factory NgToken.bananaSuffix(int offset) {
    return NgToken._(NgTokenType.bananaSuffix, offset);
  }

  factory NgToken.beforeElementDecorator(int offset, String string) {
    return _LexemeNgToken(
      offset,
      string,
      NgTokenType.beforeElementDecorator,
    );
  }

  factory NgToken.beforeElementDecoratorValue(int offset) {
    return NgToken._(NgTokenType.beforeElementDecoratorValue, offset);
  }

  factory NgToken.bindPrefix(int offset) {
    return NgToken._(NgTokenType.bindPrefix, offset);
  }

  factory NgToken.closeElementEnd(int offset) {
    return NgToken._(NgTokenType.closeElementEnd, offset);
  }

  factory NgToken.closeElementStart(int offset) {
    return NgToken._(NgTokenType.closeElementStart, offset);
  }

  factory NgToken.commentEnd(int offset) {
    return NgToken._(NgTokenType.commentEnd, offset);
  }

  factory NgToken.commentStart(int offset) {
    return NgToken._(NgTokenType.commentStart, offset);
  }

  factory NgToken.commentValue(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.commentValue);
  }

  factory NgToken.doubleQuote(int offset) {
    return NgToken._(NgTokenType.doubleQuote, offset);
  }

  factory NgToken.elementDecorator(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.elementDecorator);
  }

  factory NgToken.elementDecoratorValue(int offset, String string) {
    return _LexemeNgToken(
      offset,
      string,
      NgTokenType.elementDecoratorValue,
    );
  }

  factory NgToken.elementIdentifier(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.elementIdentifier);
  }

  factory NgToken.eventPrefix(int offset) {
    return NgToken._(NgTokenType.eventPrefix, offset);
  }

  factory NgToken.eventSuffix(int offset) {
    return NgToken._(NgTokenType.eventSuffix, offset);
  }

  factory NgToken.interpolationEnd(int offset) {
    return NgToken._(NgTokenType.interpolationEnd, offset);
  }

  factory NgToken.interpolationStart(int offset) {
    return NgToken._(NgTokenType.interpolationStart, offset);
  }

  factory NgToken.interpolationValue(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.interpolationValue);
  }

  factory NgToken.letPrefix(int offset) {
    return NgToken._(NgTokenType.letPrefix, offset);
  }

  factory NgToken.openElementEnd(int offset) {
    return NgToken._(NgTokenType.openElementEnd, offset);
  }

  factory NgToken.openElementEndVoid(int offset) {
    return NgToken._(NgTokenType.openElementEndVoid, offset);
  }

  factory NgToken.openElementStart(int offset) {
    return NgToken._(NgTokenType.openElementStart, offset);
  }

  factory NgToken.onPrefix(int offset) {
    return NgToken._(NgTokenType.onPrefix, offset);
  }

  factory NgToken.propertyPrefix(int offset) {
    return NgToken._(NgTokenType.propertyPrefix, offset);
  }

  factory NgToken.propertySuffix(int offset) {
    return NgToken._(NgTokenType.propertySuffix, offset);
  }

  factory NgToken.referencePrefix(int offset) {
    return NgToken._(NgTokenType.referencePrefix, offset);
  }

  factory NgToken.singleQuote(int offset) {
    return NgToken._(NgTokenType.singleQuote, offset);
  }

  factory NgToken.templatePrefix(int offset) {
    return NgToken._(NgTokenType.templatePrefix, offset);
  }

  factory NgToken.text(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.text);
  }

  factory NgToken.whitespace(int offset, String string) {
    return _LexemeNgToken(offset, string, NgTokenType.whitespace);
  }

  const NgToken._(
    this.type,
    this.offset, {
    this.errorSynthetic = false,
  });

  @override
  bool operator ==(Object other) {
    return other is NgToken &&
        (errorSynthetic || other.errorSynthetic
            ? other.offset == offset && other.type == type
            : other.offset == offset &&
                other.type == type &&
                other.lexeme == lexeme);
  }

  @override
  int get hashCode => Object.hash(offset, type);

  /// Indexed location where the token ends in the original source text.
  @override
  int get end => offset + length;

  /// Number of characters in this token.
  @override
  int get length => errorSynthetic ? 0 : lexeme.length;

  /// What characters were scanned and represent this token.
  @override
  String get lexeme => type.symbols;

  /// Indexed location where the token begins in the original source text.
  @override
  final int offset;

  /// Type of token scanned.
  @override
  final NgTokenType type;

  /// Indicates synthetic token generated from error.
  final bool errorSynthetic;

  @override
  String toString() => '#$NgToken($type) {$offset:$lexeme}';
}

class NgAttributeValueToken extends NgToken {
  factory NgAttributeValueToken.generate(
    NgToken leftQuote,
    NgToken? innerValue,
    NgToken rightQuote,
  ) {
    return NgAttributeValueToken._(
      leftQuote.offset,
      leftQuote,
      innerValue,
      rightQuote,
    );
  }

  final NgToken? leftQuote;
  final NgToken? innerValue;
  final NgToken? rightQuote;

  bool get containsErrorSynthetic =>
      leftQuote!.errorSynthetic ||
      innerValue!.errorSynthetic ||
      rightQuote!.errorSynthetic;

  const NgAttributeValueToken._(
    int offset,
    this.leftQuote,
    this.innerValue,
    this.rightQuote,
  ) : super._(
          NgTokenType.elementDecoratorValue,
          offset,
        );

  @override
  bool operator ==(Object other) {
    return other is NgAttributeValueToken &&
        leftQuote == other.leftQuote &&
        rightQuote == other.rightQuote &&
        innerValue == other.innerValue;
  }

  @override
  int get hashCode => Object.hash(leftQuote, innerValue, rightQuote);

  @override
  int get end => rightQuote!.end;

  @override
  int get length => leftQuote!.length + innerValue!.length + rightQuote!.length;

  @override
  String get lexeme =>
      leftQuote!.lexeme + innerValue!.lexeme + rightQuote!.lexeme;

  @override
  String toString() => '#$NgAttributeValueToken($type) {$offset:$lexeme} '
      '[\n\t$leftQuote,\n\t$innerValue,\n\t$rightQuote]';

  bool get isDoubleQuote => leftQuote?.type == NgTokenType.doubleQuote;
  bool get isSingleQuote => leftQuote?.type == NgTokenType.singleQuote;
}
