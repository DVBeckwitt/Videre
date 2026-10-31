import 'dart:convert';

import '../../utils/request_cookies.dart';
import 'db/server.dart';

class BackendOption {
  final String value;
  final String label;

  const BackendOption(this.value, this.label);

  Map<String, dynamic> toJson() => {'value': value, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is BackendOption && value == other.value && label == other.label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// Per-instance routing configuration. The selection itself stays in Cookie so
/// API requests, media and background jobs share the existing header transport.
class BackendSelector {
  final String cookieName;
  final List<BackendOption> options;
  final bool automaticFallback;
  final String? preferenceField;

  static final _cookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static final _cookieValue =
      RegExp(r'^[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]+$');
  static final _controlCharacter = RegExp(r'[\x00-\x1F\x7F]');

  factory BackendSelector(String cookieName, List<BackendOption> options,
      {bool automaticFallback = true, String? preferenceField}) {
    final preferences = preferenceField != null;
    if (cookieName.length > 256 ||
        !_cookieName.hasMatch(cookieName) ||
        _controlCharacter.hasMatch(cookieName) ||
        cookieName.toLowerCase() == 'sid' ||
        (preferences &&
            (cookieName != 'PREFS' ||
                preferenceField != 'current_companion')) ||
        (!preferences && cookieName == 'PREFS') ||
        options.isEmpty ||
        options.length > 64) {
      throw ArgumentError('Invalid backend selector configuration');
    }
    final values = <String>{};
    for (final option in options) {
      final numeric = preferences ? int.tryParse(option.value) : null;
      if (option.value.length > 256 ||
          !_cookieValue.hasMatch(option.value) ||
          _controlCharacter.hasMatch(option.value) ||
          option.label.trim().isEmpty ||
          option.label.length > 256 ||
          _controlCharacter.hasMatch(option.label) ||
          !values.add(option.value) ||
          (preferences &&
              (numeric == null ||
                  numeric < 0 ||
                  numeric > 2147483647 ||
                  numeric.toString() != option.value))) {
        throw ArgumentError('Invalid backend selector option');
      }
    }
    return BackendSelector._(cookieName, List.unmodifiable(options),
        automaticFallback, preferenceField);
  }

  const BackendSelector._(this.cookieName, this.options, this.automaticFallback,
      this.preferenceField);

  BackendSelector copyWith({bool? automaticFallback}) => BackendSelector._(
      cookieName,
      options,
      automaticFallback ?? this.automaticFallback,
      preferenceField);

  String? labelFor(String? value) {
    for (final option in options) {
      if (option.value == value) return option.label;
    }
    return null;
  }

  String? selectedValue(Server server) {
    final cookie = requestCookieValue(server.customHeaders, cookieName);
    if (cookie == null || preferenceField == null) return cookie;
    try {
      final value = _readPreferences(cookie)[preferenceField];
      return value is int ? value.toString() : null;
    } on FormatException {
      return null;
    }
  }

  /// Updates only the routing cookie or the verified PREFS field. Invalid
  /// existing preferences are left untouched rather than silently discarded.
  Server withSelection(Server server, String? value) {
    if (value != null && labelFor(value) == null) {
      throw ArgumentError('Unknown backend selection');
    }
    String? cookie = value;
    if (preferenceField != null) {
      final existing = requestCookieValue(server.customHeaders, cookieName);
      if (existing != null || value != null) {
        final preferences =
            existing == null ? <String, dynamic>{} : _readPreferences(existing);
        if (value == null) {
          preferences.remove(preferenceField);
        } else {
          preferences[preferenceField!] = int.parse(value);
        }
        // Invidious uses URI.encode_www_form / decode_www_form for PREFS.
        cookie = Uri.encodeQueryComponent(jsonEncode(preferences));
      }
    }
    return server.copyWith(
      customHeaders:
          withRequestCookie(server.customHeaders, cookieName, cookie),
      backendSelector: this,
    );
  }

  static Map<String, dynamic> _readPreferences(String value) {
    try {
      final decoded = jsonDecode(Uri.decodeQueryComponent(value));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // The error must not contain the preferences cookie or its contents.
    } on ArgumentError {
      // Invalid URI escapes are also malformed preferences.
    }
    throw const FormatException('The saved preferences cookie is invalid.');
  }

  factory BackendSelector.fromJson(Map<String, dynamic> json) {
    final cookieName = json['cookieName'];
    final entries = json['options'];
    final automaticFallback = json['automaticFallback'] ?? true;
    final preferenceField = json['preferenceField'];
    if (cookieName is! String ||
        entries is! List ||
        entries.isEmpty ||
        entries.length > 64 ||
        automaticFallback is! bool ||
        (preferenceField != null && preferenceField is! String)) {
      throw const FormatException('Invalid backend selector configuration');
    }
    final options = <BackendOption>[];
    for (final entry in entries) {
      if (entry is! Map ||
          entry['value'] is! String ||
          entry['label'] is! String) {
        throw const FormatException('Invalid backend selector option');
      }
      options.add(
          BackendOption(entry['value'] as String, entry['label'] as String));
    }
    try {
      return BackendSelector(cookieName, options,
          automaticFallback: automaticFallback,
          preferenceField: preferenceField as String?);
    } on ArgumentError {
      throw const FormatException('Invalid backend selector configuration');
    }
  }

  /// Older servers have no configuration. A malformed optional configuration
  /// must not prevent loading the instance or its existing credentials.
  static BackendSelector? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      return BackendSelector.fromJson(Map<String, dynamic>.from(value));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Map<String, dynamic>? optionalToJson(BackendSelector? value) =>
      value?.toJson();

  Map<String, dynamic> toJson() => {
        'cookieName': cookieName,
        'options': options.map((option) => option.toJson()).toList(),
        'automaticFallback': automaticFallback,
        if (preferenceField != null) 'preferenceField': preferenceField,
      };

  @override
  bool operator ==(Object other) {
    if (other is! BackendSelector ||
        cookieName != other.cookieName ||
        automaticFallback != other.automaticFallback ||
        preferenceField != other.preferenceField ||
        options.length != other.options.length) {
      return false;
    }
    for (var i = 0; i < options.length; i++) {
      if (options[i] != other.options[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
      cookieName, Object.hashAll(options), automaticFallback, preferenceField);
}
