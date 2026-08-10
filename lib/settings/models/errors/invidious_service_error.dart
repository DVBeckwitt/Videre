class InvidiousServiceError extends Error {
  final String message;
  final int? statusCode;
  final bool responseWasHtml;

  InvidiousServiceError(
    this.message, {
    this.statusCode,
    this.responseWasHtml = false,
  });

  bool get isAuthenticationFailure =>
      !responseWasHtml && (statusCode == 401 || statusCode == 403);

  @override
  String toString() => message;
}
