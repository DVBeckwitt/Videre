class InvidiousServiceError extends Error {
  final String message;
  final int? statusCode;
  final bool responseWasHtml;
  final Duration? retryAfter;
  final bool retryAfterIsInvalid;
  final String? errorCode;
  final bool isGatewayResponse;

  InvidiousServiceError(
    this.message, {
    this.statusCode,
    this.responseWasHtml = false,
    this.retryAfter,
    this.retryAfterIsInvalid = false,
    this.errorCode,
    this.isGatewayResponse = false,
  });

  bool get isRateLimited => statusCode == 429;

  bool get isGatewayAccessFailure =>
      isGatewayResponse &&
      const {
        'credentials_required',
        'invalid_credentials',
        'not_yet_eligible',
        'access_disabled',
        'access_denied',
        'rate_limited',
        'unavailable',
      }.contains(errorCode);

  bool get isAuthenticationFailure =>
      !responseWasHtml &&
      !isGatewayAccessFailure &&
      errorCode != 'Invalid scope' &&
      (statusCode == 401 || statusCode == 403);

  @override
  String toString() => message;
}
