import Foundation
import SwiftUI
import VeraDataCore

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var updateURL: URL?

    private struct Tag: Decodable {
        let name: String
    }

    func monitor() async {
        guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        while !Task.isCancelled {
            var request = URLRequest(url: AppUpdate.tagsURL, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let tags = try? JSONDecoder().decode([Tag].self, from: data), !Task.isCancelled {
                updateURL = AppUpdate.newerVersionURL(installed: installed, tags: tags.map(\.name))
            }
            do { try await Task.sleep(for: .seconds(4 * 60 * 60)) }
            catch { return }
        }
    }
}
