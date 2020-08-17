//
//  WebViewHandler.swift
//  ZShare
//
//  Created by Michal Rentka on 05/12/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation
import WebKit

import CocoaLumberjackSwift
import RxSwift

class WebViewHandler: NSObject {
    /// Actions that can be returned by this handler.
    /// - loadedItems: Items have been translated.
    /// - selectItem: Multiple items have been found on this website and the user needs to choose one.
    enum Action {
        case loadedItems([[String: Any]])
        case selectItem([String: String])
    }

    /// Handlers for communication with JS in `webView`
    enum JSHandlers: String, CaseIterable {
        /// Handler used for HTTP requests. Expects response (HTTP response).
        case request = "requestHandler"
        /// Handler used for passing translated items.
        case item = "itemResponseHandler"
        /// Handler used for item selection. Expects response (selected item).
        case itemSelection = "itemSelectionHandler"
        /// Handler used to log JS debug info.
        case log = "logHandler"
    }

    enum Error: Swift.Error {
        case cantFindBaseFile
        case jsError(String)
    }

    private let translatorsController: TranslatorsController
    private let disposeBag: DisposeBag
    let observable: PublishSubject<WebViewHandler.Action>
    private static let urlAllowedCharacters: CharacterSet = createAllowedCharacters()

    private weak var webView: WKWebView!
    private var webDidLoad: ((SingleEvent<()>) -> Void)?
    private var itemSelectionMessageId: Int?
    // Cookies from original website are stored and added to requests in `sendRequest(with:)`.
    private var cookies: String?

    private static func createAllowedCharacters() -> CharacterSet {
        var characters = CharacterSet.urlQueryAllowed
        characters.insert(charactersIn: ":/?&")
        return characters
    }

    // MARK: - Lifecycle

    init(webView: WKWebView, translatorsController: TranslatorsController) {
        self.webView = webView
        self.disposeBag = DisposeBag()
        self.translatorsController = translatorsController
        self.observable = PublishSubject()

        super.init()

        JSHandlers.allCases.forEach { handler in
            webView.configuration.userContentController.add(self, name: handler.rawValue)
        }
    }

    // MARK: - Loading translation server

    /// Runs translation server against html content with cookies. Results are then provided through observable publisher.
    /// - parameter url: Original URL of shared website.
    /// - parameter title: Title of the shared website.
    /// - parameter html: HTML content of the shared website. Equals to javascript "document.documentElement.innerHTML".
    /// - parameter cookies: Cookies string from shared website. Equals to javacsript "document.cookie".
    /// - parameter frames: HTML content of frames contained in initial HTML document.
    func translate(url: URL, title: String, html: String, cookies: String, frames: [String]) {
        guard let containerUrl = Bundle.main.url(forResource: "src/index", withExtension: "html", subdirectory: "translation"),
              let containerHtml = try? String(contentsOf: containerUrl, encoding: .utf8) else {
            self.observable.on(.error(Error.cantFindBaseFile))
            return
        }

        let encodedHtml = self.encodeForJavascript(html.data(using: .utf8))
        let jsonFramesData = try? JSONSerialization.data(withJSONObject: frames, options: .fragmentsAllowed)
        let encodedFrames = jsonFramesData.flatMap({ self.encodeForJavascript($0) }) ?? "''"
        self.cookies = cookies

        return self.loadHtml(content: containerHtml, baseUrl: containerUrl)
                   .flatMap { _ -> Single<[RawTranslator]> in
                       return self.translatorsController.translators()
                   }
                   .flatMap { translators -> Single<Any> in
                       let encodedTranslators = self.encodeJSONForJavascript(translators)
                       return self.callJavascript("translate('\(url.absoluteString)', \(encodedHtml), \(encodedFrames), \(encodedTranslators));")
                   }
                   .subscribe(onError: { [weak self] error in
                       self?.observable.on(.error(error))
                   })
                   .disposed(by: self.disposeBag)
    }

    /// Sends selected item back to `webView`.
    /// - parameter item: Selected item by the user.
    func selectItem(_ item: (String, String)) {
        guard let messageId = self.itemSelectionMessageId else { return }
        let (key, value) = item
        self.webView.evaluateJavaScript("Zotero.Messaging.receiveResponse('\(messageId)', \(self.encodeJSONForJavascript([key: value])));",
                                        completionHandler: nil)
        self.itemSelectionMessageId = nil
    }

    /// Load the translation server.
    private func loadHtml(content: String, baseUrl: URL) -> Single<()> {
        self.webView.navigationDelegate = self
        self.webView.loadHTMLString(content, baseURL: baseUrl)

        return Single.create { subscriber -> Disposable in
            self.webDidLoad = subscriber
            return Disposables.create()
        }
    }

    // MARK: - Communication with WKWebView

    /// Sends HTTP request based on options. Sends back response with HTTP response to `webView`.
    /// - parameter options: Options for HTTP request.
    private func sendRequest(with options: [String: Any]) {
        guard let messageId = options["messageId"] as? Int else { return }
        guard let urlString = options["url"] as? String,
              let url = urlString.addingPercentEncoding(withAllowedCharacters: WebViewHandler.urlAllowedCharacters).flatMap({ URL(string: $0) }),
              let method = options["method"] as? String else {
            self.sendErrorResponse(for: messageId)
            return
        }

        let headers = (options["headers"] as? [String: String]) ?? [:]
        let body = options["body"] as? String
        let timeout = (options["timeout"] as? Double).flatMap({ $0 / 1000 }) ?? 60
        let successCodes = (options["successCodes"] as? [Int]) ?? []

        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let cookies = self.cookies {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body?.data(using: .utf8)
        request.timeoutInterval = timeout

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 400
            guard let script = self?.javascript(for: messageId, statusCode: statusCode, successCodes: successCodes, data: data) else { return }

            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
        task.resume()
    }

    private func sendErrorResponse(for messageId: Int) {
        let error = "Incorrect URL request from javascript".data(using: .utf8)
        let script = self.javascript(for: messageId, statusCode: -1, successCodes: [200], data: error)
        self.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func javascript(for messageId: Int, statusCode: Int, successCodes: [Int], data: Data?) -> String {
        let isSuccess = successCodes.isEmpty ? 200..<300 ~= statusCode : successCodes.contains(statusCode)
        let responseText = data.flatMap({ String(data: $0, encoding: .utf8) }) ?? ""

        var payload: [String: Any]
        if isSuccess {
            payload = ["status": statusCode, "responseText": responseText]
        } else {
            payload = ["error": ["status": statusCode, "responseText": responseText]]
        }

        return "Zotero.Messaging.receiveResponse('\(messageId)', \(self.encodeJSONForJavascript(payload)));"
    }

    /// Report received items from translation server.
    /// - parameter result: Result with either successfully translated items or failure.
    private func receiveItems(with result: Result<[[String: Any]], Error>) {
        switch result {
        case .success(let info):
            self.observable.on(.next(.loadedItems(info)))
        case .failure(let error):
            self.observable.on(.error(error))
        }
    }

    // MARK: - Helpers

    /// Makes a javascript call to `webView` with `Single` response.
    /// - parameter script: JS script to be performed.
    /// - returns: `Single` with response from `webView`.
    private func callJavascript(_ script: String) -> Single<Any> {
        return Single.create { subscriber -> Disposable in
            self.webView.evaluateJavaScript(script) { result, error in
                if let data = result {
                    subscriber(.success(data))
                } else {
                    let error = error ?? Error.jsError("Unknown error")
                    let nsError = error as NSError

                    // TODO: - Check JS code to see if it's possible to remove this error.
                    // For some calls we get an WKWebView error "JavaScript execution returned a result of an unsupported type" even though
                    // no error really occured in the code. Because of this error the observable doesn't send any more "next" events and we don't
                    // receive the response. So we just ignore this error.
                    if nsError.domain == WKErrorDomain && nsError.code == 5 {
                        return
                    }

                    subscriber(.error(error))
                }
            }

            return Disposables.create()
        }
    }

    /// Encodes data which need to be sent to `webView`. All data that is passed to JS is Base64 encoded so that it can be sent as a simple `String`.
    private func encodeForJavascript(_ data: Data?) -> String {
        return data.flatMap({ "'" + $0.base64EncodedString(options: .endLineWithLineFeed) + "'" }) ?? "null"
    }

    /// Encodes JSON payload so that it can be sent to `webView`.
    private func encodeJSONForJavascript(_ payload: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        return self.encodeForJavascript(data)
    }
}

extension WebViewHandler: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webDidLoad?(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Swift.Error) {
        self.webDidLoad?(.error(error))
    }
}

/// Communication with JS in `webView`. The `webView` sends a message through one of the registered `JSHandlers`, which is received here.
/// Each message contains a `messageId` in the body, which is used to identify the message in case a response is expected.
extension WebViewHandler: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handler = JSHandlers(rawValue: message.name) else { return }

        switch handler {
        case .request:
            if let options = message.body as? [String: Any] {
                self.sendRequest(with: options)
            }
        case .item:
            if let info = message.body as? [[String: Any]] {
                self.receiveItems(with: .success(info))
            } else if let info = message.body as? [String: Any] {
                self.receiveItems(with: .success([info]))
            } else if let error = message.body as? String {
                self.receiveItems(with: .failure(.jsError(error)))
            } else {
                self.receiveItems(with: .failure(.jsError("Unknown response")))
            }
        case .itemSelection:
            if let info = message.body as? [String: Any],
               let messageId = info["messageId"] as? Int,
               let data = info.filter({ $0.key != "messageId" }) as? [String: String] {
                self.itemSelectionMessageId = messageId
                self.observable.on(.next(.selectItem(data)))
            }
        case .log:
            DDLogInfo("JSLOG: \(message.body)")
        }
    }
}
