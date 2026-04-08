import Testing
@testable import SwiftTrader

@Suite("ForexAPIService.APIError")
struct APIErrorTests {

    @Test("5xx status codes are retryable")
    func serverErrorsRetryable() {
        #expect(ForexAPIService.APIError.serverError(statusCode: 500).isRetryable)
        #expect(ForexAPIService.APIError.serverError(statusCode: 502).isRetryable)
        #expect(ForexAPIService.APIError.serverError(statusCode: 503).isRetryable)
    }

    @Test("Unknown status code (-1) is retryable")
    func unknownStatusRetryable() {
        #expect(ForexAPIService.APIError.serverError(statusCode: -1).isRetryable)
    }

    @Test("4xx status codes are not retryable")
    func clientErrorsNotRetryable() {
        #expect(!ForexAPIService.APIError.serverError(statusCode: 400).isRetryable)
        #expect(!ForexAPIService.APIError.serverError(statusCode: 404).isRetryable)
        #expect(!ForexAPIService.APIError.serverError(statusCode: 429).isRetryable)
    }

    @Test("Error description includes status code")
    func errorDescription() {
        let error = ForexAPIService.APIError.serverError(statusCode: 503)
        #expect(error.errorDescription?.contains("503") == true)
    }
}
