import Testing
@testable import SwiftTrader

@Suite("ForexAPIService.APIError")
struct APIErrorTests {

    @Test("5xx status codes are retryable")
    func serverErrorsRetryable() {
        #expect(ForexAPIService.APIError.serverError(statusCode: 500, retryAfterMs: nil).isRetryable)
        #expect(ForexAPIService.APIError.serverError(statusCode: 502, retryAfterMs: nil).isRetryable)
        #expect(ForexAPIService.APIError.serverError(statusCode: 503, retryAfterMs: nil).isRetryable)
    }

    @Test("Unknown status code (-1) is retryable")
    func unknownStatusRetryable() {
        #expect(ForexAPIService.APIError.serverError(statusCode: -1, retryAfterMs: nil).isRetryable)
    }

    @Test("4xx status codes are not retryable")
    func clientErrorsNotRetryable() {
        #expect(!ForexAPIService.APIError.serverError(statusCode: 400, retryAfterMs: nil).isRetryable)
        #expect(!ForexAPIService.APIError.serverError(statusCode: 404, retryAfterMs: nil).isRetryable)
        #expect(!ForexAPIService.APIError.serverError(statusCode: 429, retryAfterMs: nil).isRetryable)
    }

    @Test("Error description includes status code")
    func errorDescription() {
        let error = ForexAPIService.APIError.serverError(statusCode: 503, retryAfterMs: nil)
        #expect(error.errorDescription?.contains("503") == true)
    }
}
