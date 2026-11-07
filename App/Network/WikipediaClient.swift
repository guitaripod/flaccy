import FlaccyCore
import Foundation

/// Reads Wikipedia's API for the Meaning sheet: a search of English Wikipedia
/// for a song's article, and an article's plain text from the Wikipedia in the
/// person's language. A 10 second request timeout and Flaccy's `User-Agent`,
/// which Wikimedia asks every client to send.
nonisolated struct WikipediaClient: Sendable {

    /// A search result, with its title on the Wikipedia `linkedLanguage` named
    /// when that Wikipedia has the article too.
    struct Page: Sendable {
        let candidate: MeaningArticleCandidate
        let linkedTitle: String?
    }

    struct Article: Sendable {
        let title: String
        let url: String
        let extract: String
    }

    /// Why Wikipedia gave no answer, as opposed to answering that it has no
    /// article about the song.
    enum Failure: Error, Sendable, Equatable {
        case unreachable
        case timedOut
        case server(Int)
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "flaccy/\(version) (https://github.com/guitaripod/flaccy)"
    }

    /// English Wikipedia's results for `terms`, in its own ranking.
    func search(_ terms: String, linkedLanguage: String?) async throws(Failure) -> [Page] {
        var parameters = [
            ("generator", "search"),
            ("gsrsearch", terms),
            ("gsrlimit", String(MeaningWikipedia.searchLimit)),
            ("gsrnamespace", "0"),
            ("prop", linkedLanguage == nil ? "description" : "description|langlinks"),
        ]
        if let linkedLanguage {
            parameters.append(("lllang", linkedLanguage))
            parameters.append(("lllimit", "max"))
        }
        let reply: SearchReply = try await query(language: "en", variant: nil, parameters)
        return (reply.query?.pages ?? [])
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
            .map { page in
                Page(
                    candidate: MeaningArticleCandidate(title: page.title, description: page.description ?? ""),
                    linkedTitle: page.langlinks?.first?.title
                )
            }
    }

    /// An article's plain text with its `== Headings ==`, or with `introOnly`
    /// only the part before the first heading; `nil` when the page is gone.
    func article(_ title: String, wiki: MeaningWiki, introOnly: Bool) async throws(Failure) -> Article? {
        var parameters = [
            ("prop", "extracts|info"),
            ("inprop", "url"),
            ("explaintext", "1"),
            ("exsectionformat", "wiki"),
            ("redirects", "1"),
            ("titles", title),
        ]
        if introOnly { parameters.append(("exintro", "1")) }
        let reply: ArticleReply = try await query(language: wiki.language, variant: wiki.variant, parameters)
        guard let page = reply.query?.pages.first, page.missing != true, let extract = page.extract else { return nil }
        let url = page.fullurl ?? "https://\(wiki.language).wikipedia.org/wiki/\(page.title.replacingOccurrences(of: " ", with: "_"))"
        return Article(title: page.title, url: url, extract: extract)
    }

    private func query<Reply: Decodable>(
        language: String, variant: String?, _ parameters: [(String, String)]
    ) async throws(Failure) -> Reply {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(language).wikipedia.org"
        components.path = "/w/api.php"
        var items = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        if let variant { items.append(URLQueryItem(name: "variant", value: variant)) }
        items += parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.queryItems = items
        guard let url = components.url else { throw .unreachable }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timedOut
        } catch {
            throw .unreachable
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw .server(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw .unreachable
        }
    }

    private struct SearchReply: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [Page] }
        struct Page: Decodable {
            let title: String
            let index: Int?
            let description: String?
            let langlinks: [LanguageLink]?
        }
        struct LanguageLink: Decodable { let title: String }
    }

    private struct ArticleReply: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [Page] }
        struct Page: Decodable {
            let title: String
            let extract: String?
            let fullurl: String?
            let missing: Bool?
        }
    }
}
