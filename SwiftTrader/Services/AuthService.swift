import Foundation

actor AuthService {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    struct AuthStatus: Codable, Sendable {
        let state: String
        let liveMode: Bool
    }

    func fetchStatus() async throws -> AuthStatus {
        let url = baseURL.appendingPathComponent("/api/v1/auth/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        return try JSONDecoder().decode(AuthStatus.self, from: data)
    }

    func fetchCaptchaImage() async throws -> Data {
        let url = baseURL.appendingPathComponent("/api/v1/auth/captcha")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        return data
    }

    func submitPin(_ pin: String) async throws {
        let url = baseURL.appendingPathComponent("/api/v1/auth/pin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
    }

    enum APIError: Error, LocalizedError {
        case serverError

        var errorDescription: String? {
            switch self {
            case .serverError: return "Server returned an error"
            }
        }
    }
}
