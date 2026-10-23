import Foundation
import ImageIO

struct AIImageSettings: Codable, Sendable {
    var address = ""
    var model = ""
    var apiKey = ""

    func endpoint() throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIImageError.message("请填写 HTTPS 服务地址，不要包含密钥或查询参数。")
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("images/generations") { components.path = "/" + path }
        else { components.path = "/" + ([path.isEmpty ? "v1" : path, "images/generations"].joined(separator: "/")) }
        guard let url = components.url else { throw AIImageError.message("服务地址无效。") }
        return url
    }

    func validate() throws {
        _ = try endpoint()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIImageError.message("请填写 CPA 的生图模型名称和 API 密钥。")
        }
    }
}

struct AIImageSettingsStore {
    private let secure: any SecureValueStore
    init(secure: any SecureValueStore = KeychainStore(service: "me.aluvien.yeziblog.ai-images")) { self.secure = secure }
    func load() -> AIImageSettings {
        guard let value = secure.value(for: "configuration"), let data = value.data(using: .utf8),
              let settings = try? JSONDecoder().decode(AIImageSettings.self, from: data) else { return AIImageSettings() }
        return settings
    }
    func save(_ settings: AIImageSettings) throws {
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        guard let value = String(data: data, encoding: .utf8), secure.set(value, for: "configuration") else {
            throw AIImageError.message("无法保存到系统钥匙串，请重试。")
        }
    }
}

enum AIImageError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

struct GeneratedAIImage: Sendable {
    let data: Data
}

private final class AIImageRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let authenticated = task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil
        completionHandler(!authenticated && request.url?.scheme == "https" ? request : nil)
    }
}

actor AIImageService {
    private let session: URLSession
    private let redirects = AIImageRedirectDelegate()
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit { session.invalidateAndCancel() }

    func generate(settings: AIImageSettings, prompt: String, size: String) async throws -> GeneratedAIImage {
        try settings.validate()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIImageError.message("先描述想要的画面。") }
        var request = URLRequest(url: try settings.endpoint())
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GenerationRequest(model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt, size: size))
        let body = try await download(request, limit: 48 * 1024 * 1024)
        let response: GenerationResponse
        do { response = try JSONDecoder().decode(GenerationResponse.self, from: body) }
        catch { throw AIImageError.message("服务没有返回 OpenAI 格式的图片结果，请检查模型是否支持生图。") }
        guard let item = response.data?.first else { throw AIImageError.message("服务没有返回图片，请修改描述或检查生图模型。") }
        let data: Data
        if let encoded = item.b64_json, !encoded.isEmpty {
            guard encoded.utf8.count <= 36 * 1024 * 1024, let decoded = Data(base64Encoded: encoded) else {
                throw AIImageError.message("返回的图片编码无效或过大。")
            }
            data = decoded
        } else if let address = item.url, let url = URL(string: address), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil {
            data = try await download(URLRequest(url: url), limit: 25 * 1024 * 1024)
        } else { throw AIImageError.message("服务返回的图片地址无效。") }
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000 else {
            throw AIImageError.message("生成结果不是可读取的图片，或图片尺寸过大。")
        }
        return GeneratedAIImage(data: data)
    }

    private func download(_ request: URLRequest, limit: Int) async throws -> Data {
        let (file, response) = try await session.download(for: request, delegate: redirects)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIImageError.message("服务响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw AIImageError.message("服务拒绝访问，请检查 CPA 密钥及模型权限。")
            case 429: throw AIImageError.message("服务额度不足或请求过于频繁，请稍后重试。")
            case 300..<400: throw AIImageError.message("服务地址发生重定向，请在设置中填写最终 HTTPS 地址。")
            default: throw AIImageError.message("生图请求失败（HTTP \(http.statusCode)），请检查服务和模型配置。")
            }
        }
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let count = values.fileSize, count <= limit else { throw AIImageError.message("返回结果过大，请选择较小的图片尺寸。") }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    private struct GenerationRequest: Encodable {
        let model: String
        let prompt: String
        let size: String
        let n = 1
    }
    private struct GenerationResponse: Decodable {
        let data: [ImageResult]?
        struct ImageResult: Decodable { let b64_json: String?; let url: String? }
    }
}
