import Foundation
import URLSessionWrapper
#if os(Linux)
import FoundationNetworking
#endif

public enum VoeExtractionError: Error {
    case fileNotFound
    case htmlDecodingError
    case unknown
}

public struct VoeExtractionResult {
    public let videoURL: URL
    public let title: String?
}

public class VoeExtractor {

    let urlSession: URLSessionWrapper

    #if !os(Linux)
    public static let `default` = VoeExtractor(urlSession: .default)
    #endif

    public init(urlSession: URLSessionWrapper) {
        self.urlSession = urlSession
    }

    /// extracts direct video url or streaming manifest from raw html of embedded voe page
    /// - parameter html: HTML of video page on voe embedded frame
    /// - throws: VoeExtractionError
    /// - returns: video url when found
    public func extract(fromHTML html: String) throws -> URL {
        try extractResult(fromHTML: html).videoURL
    }

    /// extracts video metadata from raw html of embedded voe page
    /// - parameter html: HTML of video page on voe embedded frame
    /// - throws: VoeExtractionError
    /// - returns: video URL and best available metadata when found
    public func extractResult(fromHTML html: String) throws -> VoeExtractionResult {
        if let result = try extractObfuscatedConfig(fromHTML: html) {
            return result
        }

        // Updated pattern to match base64 encoded HLS URL in 'sources' variable
        let pattern = #"sources\s*=\s*\{.*?('|")hls\1\s*:\s*(["'])(?<base64>[^"']+)\2"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])

        guard let match = regex?.firstMatch(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) else {
            throw extractError(forHTML: html)
        }

        let matchRange = match.range(withName: "base64")
        guard let base64Range = Range(matchRange, in: html) else {
            throw extractError(forHTML: html)
        }

        let base64String = String(html[base64Range])

        // Decode the base64 string to get the video URL
        if let data = Data(base64Encoded: base64String), let videoURLString = String(data: data, encoding: .utf8), let videoURL = URL(string: videoURLString) {
            return VoeExtractionResult(videoURL: videoURL, title: nil)
        } else {
            throw VoeExtractionError.unknown
        }
    }

    /// Extracts direct video URL or streaming manifest from a standard VOE URL
    /// - parameter url: VOE URL (e.g., https://voe.sx/e/8vi96tm5uufc)
    /// - parameter completion: called when result is found. Returns video URL
    public func extract(fromURL url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        Task {
            do {
                let videoURL = try await extract(fromURL: url)
                completion(.success(videoURL))
            } catch let error {
                completion(.failure(error))
            }
        }
    }

    /// Extracts video metadata from a standard VOE URL
    /// - parameter url: VOE URL (e.g., https://voe.sx/e/8vi96tm5uufc)
    /// - parameter completion: called when result is found. Returns video metadata
    public func extractResult(fromURL url: URL, completion: @escaping (Result<VoeExtractionResult, Error>) -> Void) {
        Task {
            do {
                let result = try await extractResult(fromURL: url)
                completion(.success(result))
            } catch let error {
                completion(.failure(error))
            }
        }
    }

    private func loadPageHTML(fromURL url: URL) async throws -> String {

        let request = URLSessionWrapper.Request(url: url)
        let response = try await urlSession.handleRequest(request)

        if response.statusCode == 404 {
            throw VoeExtractionError.fileNotFound
        }

        //print(response.statusCode)
        guard let htmlContent = String(data: response.data, encoding: .utf8) else {
            throw VoeExtractionError.htmlDecodingError
        }

        return htmlContent
    }

    /// Find javascript `window.location.href`-style redirect
    /// - returns: nil if not found
    private func findRedirectURL(html: String) -> URL? {

        let pattern = #"window\.location(?:\.href)?\s*=\s*('|")(?<url>https?://[^'"]+)('|")"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        guard let match = regex?.firstMatch(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) else { return nil }

        let matchRange = match.range(withName: "url")
        guard let range = Range(matchRange, in: html) else { return nil }

        if let redirectURL = URL(string: String(html[range])) {
            return redirectURL
        } else {
            return nil
        }
    }

    #if swift(>=5.5)

    /// extracts direct video url or streaming manifest from standard voe url
    /// - parameter url: voe url (e.g.: https://voe.sx/e/8vi96tm5uufc)
    /// - returns: video url, if found (else: nil)
    @available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public func extract(fromURL url: URL) async throws -> URL {
        try await extractResult(fromURL: url).videoURL
    }

    /// extracts video metadata from standard voe url
    /// - parameter url: voe url (e.g.: https://voe.sx/e/8vi96tm5uufc)
    /// - returns: video URL and best available metadata
    @available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public func extractResult(fromURL url: URL) async throws -> VoeExtractionResult {
        var currentURL = url
        var lastExtractionError: Error?

        for _ in 0..<4 {
            let htmlContent = try await loadPageHTML(fromURL: currentURL)

            do {
                return try extractResult(fromHTML: htmlContent)
            } catch let error {
                lastExtractionError = error

                if let redirectURL = findRedirectURL(html: htmlContent) {
                    currentURL = redirectURL
                    continue
                }

                throw error
            }
        }

        throw lastExtractionError ?? VoeExtractionError.unknown
    }

    #endif

}

private extension VoeExtractor {

    func extractError(forHTML html: String) -> VoeExtractionError {
        let lowercasedHTML = html.lowercased()
        if lowercasedHTML.contains("file not found") || lowercasedHTML.contains("404 - not found") {
            return .fileNotFound
        }
        return .unknown
    }

    func extractObfuscatedConfig(fromHTML html: String) throws -> VoeExtractionResult? {
        let scriptPattern = #"<script\b(?=[^>]*\btype\s*=\s*["']application/json["'])[^>]*>(?<json>.*?)</script>"#
        let regex = try NSRegularExpression(pattern: scriptPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count))

        for match in matches {
            let jsonRange = match.range(withName: "json")
            guard let range = Range(jsonRange, in: html) else { continue }

            let scriptJSON = String(html[range])
            guard let data = scriptJSON.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                continue
            }

            for value in array {
                guard let encodedConfig = value as? String,
                      let decodedConfig = decodeObfuscatedConfig(encodedConfig),
                      let source = decodedConfig["source"] as? String,
                      let url = URL(string: source) else {
                    continue
                }

                return VoeExtractionResult(videoURL: url, title: decodedConfig["title"] as? String)
            }
        }

        return nil
    }

    func decodeObfuscatedConfig(_ encodedConfig: String) -> [String: Any]? {
        var decoded = rot13(encodedConfig)
        for marker in ["@$", "^^", "~@", "%?", "*~", "!!", "#&"] {
            decoded = decoded.replacingOccurrences(of: marker, with: "")
        }

        guard let firstDecodedData = Data(base64Encoded: decoded) else {
            return nil
        }

        var shiftedBytes = [UInt8]()
        shiftedBytes.reserveCapacity(firstDecodedData.count)

        for byte in firstDecodedData {
            guard byte >= 3 else { return nil }
            shiftedBytes.append(byte - 3)
        }

        let reversedBase64 = String(decoding: shiftedBytes.reversed(), as: UTF8.self)
        guard let jsonData = Data(base64Encoded: reversedBase64),
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    func rot13(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.map { scalar in
            let value = scalar.value
            switch value {
            case 65...90:
                return UnicodeScalar(((value - 65 + 13) % 26) + 65)!
            case 97...122:
                return UnicodeScalar(((value - 97 + 13) % 26) + 97)!
            default:
                return scalar
            }
        }))
    }

}
