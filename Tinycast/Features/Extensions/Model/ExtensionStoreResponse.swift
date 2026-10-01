import Foundation

/// Someone else's endpoint, so every field an install doesn't need is optional.
enum ExtensionStoreResponse {
    /// The endpoint the store's own website searches with; unofficial, so it can change unannounced.
    static func searchURL(query: String, page: Int) -> URL? {
        var components = URLComponents(string: "https://www.raycast.com/frontend_api/extensions/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            // Case-sensitive: any other spelling returns only extensions listing no platforms.
            URLQueryItem(name: "platform", value: "macOS")
        ]
        return components?.url
    }

    private struct StorePayload: Decodable {
        let data: [StoreEntry]
    }

    private struct StoreEntry: Decodable {
        let id: String
        let name: String
        let title: String?
        let description: String?
        let author: Author?
        let icons: Icons?
        let commands: [Command]?
        let downloadCount: Int?
        let downloadURL: String?
        let status: String?

        struct Author: Decodable {
            let name: String?
            let handle: String?
        }
        struct Icons: Decodable {
            let light: String?
            let dark: String?
        }
        struct Command: Decodable {
            let name: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, name, title, description, author, icons, commands, status
            case downloadCount = "download_count"
            case downloadURL = "download_url"
        }
    }

    /// An entry without a usable download is dropped, not listed as uninstallable.
    static func parseStore(_ data: Data) throws -> [ExtensionListing] {
        let payload = try JSONDecoder().decode(StorePayload.self, from: data)
        return payload.data.compactMap { entry -> ExtensionListing? in
            // A de-listed extension is still returned by search; it can't be downloaded any more.
            guard entry.status == nil || entry.status == "active" else { return nil }
            guard let raw = entry.downloadURL, let url = URL(string: raw) else { return nil }
            return ExtensionListing(
                id: entry.id,
                name: entry.name,
                title: entry.title ?? entry.name,
                summary: entry.description ?? "",
                author: entry.author?.name ?? entry.author?.handle ?? "",
                lightIconURL: entry.icons?.light.flatMap(URL.init(string:)),
                darkIconURL: entry.icons?.dark.flatMap(URL.init(string:)),
                commandCount: entry.commands?.count ?? 0,
                downloadCount: entry.downloadCount,
                downloadURL: url)
        }
    }
}

enum ExtensionStoreError: LocalizedError {
    case malformedResponse
    case rejected(String)
    case downloadFailed(String)
    case noPackageManager
    case noNode
    case buildFailed(String)
    case notAnExtension

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "The server answered with something this version doesn't understand."
        case .rejected(let message):
            return message
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .noPackageManager:
            return
                "No package manager was found. Install pnpm, npm, Yarn or Bun, or add the folder "
                + "it lives in to Custom search paths."
        case .noNode:
            return
                "Node wasn't found. Install Node.js, add the folder it lives in to Custom search "
                + "paths, or install this extension from the Raycast Store instead."
        case .buildFailed(let output):
            return "The extension didn't build: \(output)"
        case .notAnExtension:
            return "That download didn't contain a Raycast extension."
        }
    }
}
