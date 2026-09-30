import 'package:meta/meta.dart';

/// A success/failure envelope.
///
/// The engine never throws across integration boundaries: an adapter that
/// cannot deliver returns `Failure` with a reason that the UI can display
/// verbatim. This is what makes "honest status reporting" (spec §40)
/// enforceable rather than aspirational.
@immutable
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T? get valueOrNull => switch (this) {
        Success<T>(:final T value) => value,
        Failure<T>() => null,
      };

  String? get errorOrNull => switch (this) {
        Success<T>() => null,
        Failure<T>(:final String reason) => reason,
      };

  R fold<R>(R Function(T value) onSuccess, R Function(String reason, String? code) onFailure) =>
      switch (this) {
        Success<T>(:final T value) => onSuccess(value),
        Failure<T>(:final String reason, :final String? code) => onFailure(reason, code),
      };

  static Success<T> ok<T>(T value) => Success<T>(value);
  static Failure<T> fail<T>(String reason, {String? code}) =>
      Failure<T>(reason: reason, code: code);
}

@immutable
final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;
}

@immutable
final class Failure<T> extends Result<T> {
  const Failure({required this.reason, this.code, this.retriable = false});

  /// Human readable, safe to show to the user.
  final String reason;

  /// Stable machine code, e.g. `whatsapp.not_connected`.
  final String? code;

  /// Whether the retry policy is allowed to try again.
  final bool retriable;
}
