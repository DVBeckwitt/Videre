class InvidiousServiceError extends Error {
  final String message;
  final int? statusCode;
  final bool responseWasHtml;

  InvidiousServiceError(
    this.message, {
    this.statusCode,
    this.responseWasHtml = false,
  });

  @override
  String toString() => message;
}
