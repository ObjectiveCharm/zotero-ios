//
//  ExtensionStore.swift
//  ZShare
//
//  Created by Michal Rentka on 25/11/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation
import MobileCoreServices
import WebKit

import Alamofire
import CocoaLumberjackSwift
import RxSwift

/// `ExtensionStore` performs fetching of basic website data, runs the translation server which translates the web data, downloads item data with
/// pdf attachment if available and uploads new item to Zotero.
///
/// These steps are performed for each share:
/// 1. Website data (url, title, cookies and full HTML) are loaded from `NSExtensionItem`,
/// 2. Translation server is run in a hidden WebView (handled by `TranslationWebViewHandler`). It loads item data and attachment if available,
/// 3. If there are multiple items available a picker is shown to the user and after picking an item, translation is finished for that item,
/// 4. If available, pdf attachment is downloaded,
/// 5. The item (with attachment) is stored to DB and necessary API requests are made to submit the item (and prepare for upload),
/// 6. A background upload of the pdf attachment is enqueued,
/// 7. The share extension is closed.
///
/// If there was an upload, it is finished in the main app. The main app marks the attachment item as synced
/// and sends additional request to Zotero API to register the upload.
///
/// Sync is also run in background so that the user can see a current list of collections and pick a Collection where the item should be stored.
final class ExtensionStore {
    struct State {
        enum CollectionPickerState {
            case loading, failed
            case picked(Library, Collection?)
        }

        struct ItemPickerState {
            let items: [(key: String, value: String)]
            var picked: String?
        }

        /// State for loading and processing attachment.
        /// - decoding: Decoding attachment and deciding what to do with it. This is the initial state.
        /// - translating: Translation is in progress. `String` is progress report from javascript code.
        /// - downloading: Translation has ended. The item has an attachment which is being downloaded.
        /// - processed: Processing of attachment has ended (either loading of URL or translation of web). Waiting for submission.
        /// - submitting: Submitting processed attachment to backend.
        /// - done: Sharing was successful, extension should close.
        /// - failed: The attachment decoding, translation process or attachment download failed.
        enum AttachmentState {
            enum Error: Swift.Error {
                case apiFailure
                case cantLoadSchema
                case cantLoadWebData
                case downloadFailed
                case itemsNotFound
                case expired
                case unknown
                case fileMissing
                case downloadedFileNotPdf
                case webViewError(TranslationWebViewHandler.Error)
                case parseError(Parsing.Error)
                case schemaError(SchemaError)
                case quotaLimit(LibraryIdentifier)
                case webDavNotVerified
                case webDavFailure
                case md5Missing
                case mtimeMissing

                var isFatal: Bool {
                    switch self {
                    case .cantLoadWebData, .cantLoadSchema: return true
                    default: return false
                    }
                }

                var isFatalOrQuota: Bool {
                    switch self {
                    case .cantLoadWebData, .cantLoadSchema, .quotaLimit: return true
                    default: return false
                    }
                }
            }

            case decoding
            case translating(String)
            case downloading(Double)
            case processed
            case failed(Error)

            var error: Error? {
                switch self {
                case .failed(let error):
                    return error
                default:
                    return nil
                }
            }

            var translationInProgress: Bool {
                switch self {
                case .decoding, .translating, .downloading:
                    return true
                default:
                    return false
                }
            }

            var isSubmittable: Bool {
                switch self {
                case .processed: return true
                case .failed(let error):
                    if error.isFatal {
                        return false
                    }
                    
                    switch error {
                    case .apiFailure, .quotaLimit:
                        return false
                    default:
                        return true
                    }
                default: return false
                }
            }
        }

        /// Raw attachment received from NSItemProvider.
        /// - web: Web content received from browser. Web content should be translated.
        /// - remoteUrl: `URL` instance which is not a local file. This `URL` should be opened in a browser and transformed to `.web(...)` or `.fileUrl(...)`.
        /// - fileUrl: `URL` pointing to a local file.
        /// - remoteFileUrl: `URL` pointing to a remote file.
        enum RawAttachment {
            case web(title: String, url: URL, html: String, cookies: String, frames: [String])
            case remoteUrl(URL)
            case fileUrl(URL)
            case remoteFileUrl(url: URL, contentType: String)
        }

        /// Attachment which has been loaded and translated processed/translated.
        /// - item: Translated item which doesn't have an attachment.
        /// - itemWithAttachment: Translated item with attachment data.
        /// - localFile: `URL` pointing to a local file.
        /// - remoteFile: `URL` pointing to a remote file.
        enum ProcessedAttachment {
            case item(ItemResponse)
            case itemWithAttachment(item: ItemResponse, attachment: [String: Any], attachmentFile: File)
            case localFile(file: File, filename: String)
        }

        fileprivate struct UploadData {
            enum Kind {
                case localFile(location: File, collections: Set<String>, tags: [TagResponse])
                case translated(item: ItemResponse, location: File)
            }

            let type: Kind
            let attachment: Attachment
            let file: File
            let filename: String
            let libraryId: LibraryIdentifier
            let userId: Int

            init(item: ItemResponse, attachmentKey: String, attachmentData: [String: Any], attachmentFile: File, defaultTitle: String,
                 collections: Set<String>, tags: [TagResponse], libraryId: LibraryIdentifier, userId: Int, dateParser: DateParser) {
                let newItem = item.copy(libraryId: libraryId, collectionKeys: collections, addedTags: tags)
                let filename = FilenameFormatter.filename(from: item, defaultTitle: defaultTitle, ext: attachmentFile.ext, dateParser: dateParser)
                let file = Files.attachmentFile(in: libraryId, key: attachmentKey, filename: filename, contentType: attachmentFile.mimeType)
                let attachment = Attachment(type: .file(filename: filename, contentType: attachmentFile.mimeType, location: .local, linkType: .importedFile),
                                            title: filename,
                                            key: attachmentKey,
                                            libraryId: libraryId)

                self.type = .translated(item: newItem, location: attachmentFile)
                self.attachment = attachment
                self.file = file
                self.filename = filename
                self.libraryId = libraryId
                self.userId = userId
            }

            init(localFile: File, filename: String, attachmentKey: String, collections: Set<String>, tags: [TagResponse], libraryId: LibraryIdentifier, userId: Int) {
                let file = Files.attachmentFile(in: libraryId, key: attachmentKey, filename: filename, contentType: localFile.mimeType)
                let attachment = Attachment(type: .file(filename: filename, contentType: localFile.mimeType, location: .local, linkType: .importedFile),
                                            title: filename,
                                            key: attachmentKey,
                                            libraryId: libraryId)

                self.type = .localFile(location: localFile, collections: collections, tags: tags)
                self.attachment = attachment
                self.file = file
                self.filename = filename
                self.libraryId = libraryId
                self.userId = userId
            }
        }

        // Newly generated key for attachment (used to store attachment file at correct location)
        let attachmentKey: String
        // Title of website where share extension is visible
        var title: String?
        // URL of website where share extension is visible
        var url: String?
        // Selected collection in collection picker
        var selectedCollectionId: CollectionIdentifier
        // Library id of selected collection in collection picker
        var selectedLibraryId: LibraryIdentifier
        // State of collection picker
        var collectionPickerState: CollectionPickerState
        // Recently picked collections in collection picker
        var recents: [RecentData]
        // Item picker state
        var itemPickerState: ItemPickerState?
        // State of attachment
        var attachmentState: AttachmentState
        // Item that was decoded and is expected to be saved by share extension (shown in UI)
        var expectedItem: ItemResponse?
        // Attachment that was decoded and is expected to be saved by share extension (shown in UI)
        var expectedAttachment: (String, File)?
        // Actually processed item/attachment/both which were successfully decoded, downloaded and are ready for submission.
        var processedAttachment: ProcessedAttachment?
        // Tags decoded with item
        var tags: [Tag]
        // `true` when share extension is submitting item/attachment/both, `false` otherwise
        var isSubmitting: Bool
        // `true` when share extension should close
        var isDone: Bool

        init() {
            self.attachmentKey = KeyGenerator.newKey
            self.selectedCollectionId = Defaults.shared.selectedCollectionId
            self.selectedLibraryId = Defaults.shared.selectedLibrary
            self.collectionPickerState = .loading
            self.attachmentState = .decoding
            self.recents = []
            self.tags = []
            self.isSubmitting = false
            self.isDone = false
        }
    }

    @Published var state: State
    // Optional handler to deal with webs that provide PDFs through redirection
    private var redirectHandler: RedirectWebViewHandler?
    private weak var webView: WKWebView?

    private static let defaultLibraryId: LibraryIdentifier = .custom(.myLibrary)
    private static let defaultExtension = "pdf"
    private static let defaultMimetype = "application/pdf"
    private static let zipMimetype = "application/zip"

    private let syncController: SyncController
    private let apiClient: ApiClient
    private let dbStorage: DbStorage
    private let fileStorage: FileStorage
    private let schemaController: SchemaController
    private let webDavController: WebDavController
    private let dateParser: DateParser
    private let translationHandler: TranslationWebViewHandler
    private let backgroundUploader: BackgroundUploader
    private let backgroundUploadObserver: BackgroundUploadObserver
    private let backgroundQueue: DispatchQueue
    private let backgroundScheduler: SerialDispatchQueueScheduler
    private let disposeBag: DisposeBag

    private struct SubmissionData {
        let filesize: UInt64
        let md5: String
        let mtime: Int
    }

    init(webView: WKWebView, apiClient: ApiClient, backgroundUploader: BackgroundUploader, backgroundUploadObserver: BackgroundUploadObserver, dbStorage: DbStorage, schemaController: SchemaController,
         webDavController: WebDavController, dateParser: DateParser, fileStorage: FileStorage, syncController: SyncController, translatorsController: TranslatorsAndStylesController) {
        let queue = DispatchQueue(label: "org.zotero.ZShare.BackgroundQueue", qos: .userInteractive)
        self.webView = webView
        self.syncController = syncController
        self.apiClient = apiClient
        self.backgroundUploader = backgroundUploader
        self.backgroundUploadObserver = backgroundUploadObserver
        self.dbStorage = dbStorage
        self.fileStorage = fileStorage
        self.schemaController = schemaController
        self.webDavController = webDavController
        self.dateParser = dateParser
        self.translationHandler = TranslationWebViewHandler(webView: webView, translatorsController: translatorsController)
        self.backgroundQueue = queue
        self.backgroundScheduler = SerialDispatchQueueScheduler(queue: queue, internalSerialQueueName: "org.zotero.ZShare.BackgroundScheduler")
        self.state = State()
        self.disposeBag = DisposeBag()

        self.setupSyncObserving()
        self.setupWebHandlerObserving()
    }

    // MARK: - Actions

    func start(with extensionItem: NSExtensionItem) {
        // Start sync in background, so that collections are available for user to pick
        DDLogInfo("ExtensionStore: start sync")
        self.syncController.start(type: .collectionsOnly, libraries: .all)
        DDLogInfo("ExtensionStore: load extension item")
        self.loadAttachment(from: extensionItem)
            .subscribe(onSuccess: { [weak self] attachment in
                self?.process(attachment: attachment)
            }, onFailure: { [weak self] error in
                guard let `self` = self else { return }
                DDLogError("ExtensionStore: could not load attachment - \(error)")
                self.state.attachmentState = .failed(self.attachmentError(from: error, libraryId: nil))
            })
            .disposed(by: self.disposeBag)
    }

    func cancel() {
        guard let attachment = self.state.processedAttachment else { return }
        switch attachment {
        case .itemWithAttachment(_, _, let file), .localFile(let file, _):
            // Remove temporary local file if it exists
            try? self.fileStorage.remove(file)
        case .item: break
        }
    }

    // MARK: - Processing attachments

    private func loadAttachment(from extensionItem: NSExtensionItem) -> Single<State.RawAttachment> {
        if let itemProvider = extensionItem.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypePropertyList as String) }) {
            DDLogInfo("ExtensionStore: item provider for property list")
            return self.loadWebData(from: itemProvider)
        } else if let itemProvider = extensionItem.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypeURL as String) }) {
            DDLogInfo("ExtensionStore: item provider for URL")
            return self.loadUrl(from: itemProvider)
                       .flatMap({ $0.isFileURL ? Single.just(.fileUrl($0)) : Single.just(.remoteUrl($0)) })
        }
        return Single.error(State.AttachmentState.Error.cantLoadWebData)
    }

    private func process(attachment: State.RawAttachment) {
        switch attachment {
        case .web(let title, let url, let html, let cookies, let frames):
            var state = self.state
            state.title = title
            state.url = url.absoluteString
            self.state = state
            DDLogInfo("ExtensionStore: start translation")
            self.translationHandler.translate(url: url, title: title, html: html, cookies: cookies, frames: frames)

        case .remoteUrl(let url):
            DDLogInfo("ExtensionStore: load web")
            self.translationHandler.loadWebData(from: url)
                                   .subscribe(onSuccess: { [weak self] attachment in
                                       self?.process(attachment: attachment)
                                   }, onFailure: { [weak self] error in
                                       guard let `self` = self else { return }
                                       DDLogError("ExtensionStore: webview could not load data - \(error)")
                                       self.state.attachmentState = .failed(self.attachmentError(from: error, libraryId: nil))
                                   })
                                   .disposed(by: self.disposeBag)

        case .fileUrl(let url):
            let filename = url.lastPathComponent
            let tmpFile = Files.temporaryFile(ext: url.pathExtension)

            self.copyFile(from: url.path, to: tmpFile)
                .subscribe(with: self, onSuccess: { `self`, _ in
                    var state = self.state
                    state.processedAttachment = .localFile(file: tmpFile, filename: filename)
                    state.expectedAttachment = (filename, tmpFile)
                    state.attachmentState = .processed
                    self.state = state
                }, onFailure: { `self`, error in
                    self.state.attachmentState = .failed(.fileMissing)
                })
                .disposed(by: self.disposeBag)

        case .remoteFileUrl(let url, let contentType):
            let filename = url.lastPathComponent
            let file = Files.shareExtensionDownload(key: self.state.attachmentKey, contentType: contentType)

            var state = self.state
            state.url = url.absoluteString
            state.title = url.absoluteString
            state.attachmentState = .downloading(0)
            state.expectedAttachment = (filename, file)
            self.state = state

            DDLogInfo("ExtensionStore: download file")
            self.download(url: url, to: file)
                .observe(on: MainScheduler.instance)
                .subscribe(onSuccess: { [weak self] _ in
                    guard let `self` = self else { return }

                    var state = self.state
                    if self.fileStorage.isPdf(file: file) {
                        DDLogInfo("ExtensionStore: downloaded pdf")
                        state.processedAttachment = .localFile(file: file, filename: filename)
                        state.attachmentState = .processed
                    } else {
                        DDLogInfo("ExtensionStore: downloaded unsupported file")
                        state.processedAttachment = nil
                        state.attachmentState = .failed(.downloadedFileNotPdf)
                        state.expectedAttachment = nil
                        // Remove downloaded file, it won't be used anymore
                        try? self.fileStorage.remove(file)
                    }
                    self.state = state
                }, onFailure: { [weak self] error in
                    DDLogError("ExtensionStore: could not download shared file - \(url.absoluteString) - \(error)")
                    self?.state.attachmentState = .failed(.downloadFailed)
                })
                .disposed(by: self.disposeBag)
        }
    }

    private func loadUrl(from itemProvider: NSItemProvider) -> Single<URL> {
        return Single.create { [weak itemProvider] subscriber in
            guard let itemProvider = itemProvider else {
                subscriber(.failure(State.AttachmentState.Error.cantLoadWebData))
                return Disposables.create()
            }

            DDLogInfo("ExtensionStore: load item provider")

            itemProvider.loadItem(forTypeIdentifier: (kUTTypeURL as String), options: nil, completionHandler: { item, error -> Void in
                DDLogInfo("ExtensionStore: loaded item provider")
                if let error = error {
                    DDLogError("ExtensionStore: url load error - \(error)")
                }

                if let url = item as? URL {
                    DDLogInfo("ExtensionStore: loaded url")
                    subscriber(.success(url))
                } else {
                    DDLogError("ExtensionStore: can't load URL")
                    subscriber(.failure(State.AttachmentState.Error.cantLoadWebData))
                }
            })

            return Disposables.create()
        }
    }

    /// Creates an Observable for NSExtensionItem to load web data.
    /// - parameter extensionItem: `NSExtensionItem` passed from `NSExtensionContext` from share extension view controller.
    /// - returns: Observable for loading: title, url, full HTML, cookies, iframes content.
    private func loadWebData(from itemProvider: NSItemProvider) -> Single<State.RawAttachment> {
        return Single.create { [weak itemProvider] subscriber in
            guard let itemProvider = itemProvider else {
                subscriber(.failure(State.AttachmentState.Error.cantLoadWebData))
                return Disposables.create()
            }

            DDLogInfo("ExtensionStore: load item provider")

            itemProvider.loadItem(forTypeIdentifier: (kUTTypePropertyList as String), options: nil, completionHandler: { item, error -> Void in
                DDLogInfo("ExtensionStore: loaded item provider")
                if let error = error {
                    DDLogError("ExtensionStore: web data load error - \(error)")
                }

                guard let scriptData = item as? [String: Any],
                      let data = scriptData[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                      let isFile = data["isFile"] as? Bool,
                      let url = (data["url"] as? String).flatMap(URL.init) else {
                    DDLogError("ExtensionStore: can't read script data")
                    subscriber(.failure(State.AttachmentState.Error.cantLoadWebData))
                    return
                }

                if isFile, let contentType = data["contentType"] as? String {
                    DDLogInfo("ExtensionStore: loaded remote file")
                    subscriber(.success(.remoteFileUrl(url: url, contentType: contentType)))
                } else if let title = data["title"] as? String,
                          let html = data["html"] as? String,
                          let cookies = data["cookies"] as? String,
                          let frames = data["frames"] as? [String] {
                    DDLogInfo("ExtensionStore: loaded web")
                    subscriber(.success(.web(title: title, url: url, html: html, cookies: cookies, frames: frames)))
                } else {
                    DDLogError("ExtensionStore: script data don't contain required info")
                    DDLogError("\(data)")
                    subscriber(.failure(State.AttachmentState.Error.cantLoadWebData))
                }
            })

            return Disposables.create()
        }
    }

    // MARK: - Translation

    /// Observes `WebViewHandler` translation process and acts accordingly.
    private func setupWebHandlerObserving() {
        self.translationHandler.observable
                               .observe(on: MainScheduler.instance)
                               .subscribe(onNext: { [weak self] action in
                                   switch action {
                                   case .loadedItems(let data):
                                       DDLogInfo("ExtensionStore: webview action - loaded \(data.count) zotero items")
                                       self?.processItems(data)
                                   case .selectItem(let data):
                                       DDLogInfo("ExtensionStore: webview action - loaded \(data.count) list items")
                                       self?.state.itemPickerState = State.ItemPickerState(items: data, picked: nil)
                                   case .reportProgress(let progress):
                                       DDLogInfo("ExtensionStore: webview action - progress \(progress)")
                                       self?.state.attachmentState = .translating(progress)
                                   }
                               }, onError: { [weak self] error in
                                   guard let `self` = self else { return }
                                   DDLogError("ExtensionStore: web view error - \(error)")
                                   self.state.attachmentState = .failed(self.attachmentError(from: error, libraryId: nil))
                               })
                               .disposed(by: self.disposeBag)

    }

    /// Parses item from translation response, starts attachment download if available.
    private func processItems(_ data: [[String: Any]]) {
        let item: ItemResponse
        let attachment: [String: Any]?

        do {
            DDLogInfo("ExtensionStore: parse zotero items")
            let (_item, _attachment) = try self.parse(data, schemaController: self.schemaController)
            item = _item
            attachment = _attachment
        } catch let error {
            DDLogError("ExtensionStore: could not process item - \(error)")
            self.state.attachmentState = .failed(self.attachmentError(from: error, libraryId: nil))
            return
        }

        guard let attachment = attachment, let urlString = attachment["url"] as? String, let url = URL(string: urlString) else {
            DDLogInfo("ExtensionStore: parsed item without attachment")
            var state = self.state
            state.processedAttachment = .item(item)
            state.expectedItem = item
            state.attachmentState = .processed
            self.state = state
            return
        }

        DDLogInfo("ExtensionStore: parsed item with attachment, download attachment")

        let file = Files.shareExtensionDownload(key: self.state.attachmentKey, ext: ExtensionStore.defaultExtension)
        self.download(item: item, attachment: attachment, attachmentUrl: url, to: file)
    }

    private func download(item: ItemResponse, attachment: [String: Any], attachmentUrl url: URL, to file: File) {
        let attachmentTitle = ((attachment["title"] as? String) ?? self.state.title) ?? ""

        var state = self.state
        state.attachmentState = .downloading(0)
        state.expectedItem = item
        state.expectedAttachment = (attachmentTitle, file)
        state.processedAttachment = .item(item)
        self.state = state

        self.download(url: url, to: file)
            .observe(on: MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] _ in
                self?.processDownload(of: attachment, url: url, file: file, item: item)
            }, onFailure: { [weak self] error in
                DDLogError("ExtensionStore: could not download translated file - \(url.absoluteString) - \(error)")
                self?.state.attachmentState = .failed(.downloadFailed)
            })
            .disposed(by: self.disposeBag)
    }

    private func processDownload(of attachment: [String: Any], url: URL, file: File, item: ItemResponse) {
        if self.fileStorage.isPdf(file: file) {
            DDLogInfo("ExtensionStore: downloaded pdf")
            var state = self.state
            state.attachmentState = .processed
            state.processedAttachment = .itemWithAttachment(item: item, attachment: attachment, attachmentFile: file)
            self.state = state
            return
        }

        DDLogInfo("ExtensionStore: downloaded unsupported attachment")

        // Remove downloaded file, it won't be used anymore
        try? self.fileStorage.remove(file)

        guard (url.host ?? "").contains("sciencedirect") else {
            self.state.attachmentState = .failed(.downloadedFileNotPdf)
            return
        }

        // Try loading the url in webview to bypass redirects

        DDLogInfo("ExtensionStore: detected sciencedirect, trying redirect")

        self.state.attachmentState = .downloading(0)

        self.getRedirectedPdfUrl(from: url) { [weak self] newUrl in
            guard let `self` = self else { return }

            if let url = newUrl {
                self.download(item: item, attachment: attachment, attachmentUrl: url, to: file)
                return
            }

            // Didn't help, report failed PDF download
            self.state.attachmentState = .failed(.downloadedFileNotPdf)
        }
    }

    private func getRedirectedPdfUrl(from url: URL, completion: @escaping (URL?) -> Void) {
        guard let webView = self.webView else {
            completion(nil)
            return
        }

        let handler = RedirectWebViewHandler(url: url, timeoutPerRedirect: .seconds(2), webView: webView)
        handler.getPdfUrl(completion: completion)
        self.redirectHandler = handler
    }

    /// Tries to parse `ItemResponse` from data returned by translation server. It prioritizes items with attachments if there are multiple items.
    /// - parameter data: Data to parse
    /// - parameter schemaController: SchemaController which is used for validating item type and field types
    /// - returns: `ItemResponse` of parsed item and optional attachment dictionary with title and url.
    private func parse(_ data: [[String: Any]], schemaController: SchemaController) throws -> (ItemResponse, [String: Any]?) {
        // Sort items so that the first item will have a PDF attachment (if available)
        let sortedData = data.sorted { left, right -> Bool in
            let leftAttachments = (left["attachments"] as? [[String: String]]) ?? []
            let leftHasPdf = leftAttachments.contains(where: { $0["mimeType"] == ExtensionStore.defaultMimetype })
            let rightAttachments = (right["attachments"] as? [[String: String]]) ?? []
            let rightHasPdf = rightAttachments.contains(where: { $0["mimeType"] == ExtensionStore.defaultMimetype })
            return leftHasPdf || !rightHasPdf
        }

        guard let itemData = sortedData.first else {
            throw State.AttachmentState.Error.itemsNotFound
        }

        var item = try ItemResponse(translatorResponse: itemData, schemaController: self.schemaController)
        if !item.tags.isEmpty {
            item = item.copyWithAutomaticTags
        }
        var attachment: [String: Any]?
        if Defaults.shared.shareExtensionIncludeAttachment {
            attachment = (itemData["attachments"] as? [[String: Any]])?.first(where: { ($0["mimeType"] as? String) == ExtensionStore.defaultMimetype })
        }

        return (item, attachment)
    }

    /// Sets picked item if multiple items were found.
    func pickItem(_ data: (String, String)) {
        self.state.itemPickerState?.picked = data.1
        self.translationHandler.selectItem(data)
    }

    // MARK: - Attachment Download

    /// Starts download of PDF attachment. Downloads it to temporary folder.
    /// - parameter url: URL of file to download
    private func download(url: URL, to file: File) -> Single<DownloadRequest> {
        let request = FileRequest(url: url, destination: file)
        return self.apiClient.download(request: request, queue: .main)
                             .subscribe(on: self.backgroundScheduler)
                             .do(onNext: { [weak self] request in
                                 if let `self` = self {
                                     self.observe(downloadProgress: request.downloadProgress)
                                 }
                                 request.resume()
                             })
                             .asSingle()
    }

    private func observe(downloadProgress: Progress) {
        downloadProgress.observable
                       .observe(on: MainScheduler.instance)
                       .subscribe(onNext: { [weak self] progress in
                           guard let `self` = self else { return }
                           switch self.state.attachmentState {
                           case .downloading:
                               self.state.attachmentState = .downloading(progress.fractionCompleted)
                           default: break
                           }
                       })
                       .disposed(by: self.disposeBag)
    }

    // MARK: - Submission

    /// Submits translated item (and attachment) to Zotero API. Enqueues background upload if needed.
    func submit() {
        guard self.state.attachmentState.isSubmittable else {
            DDLogError("ExtensionStore: tried to submit unsubmittable state")
            return
        }

        self.state.isSubmitting = true

        let tags = self.state.tags.map({ TagResponse(tag: $0.name, type: $0.type) })
        let libraryId: LibraryIdentifier
        let collectionKeys: Set<String>
        let userId = Defaults.shared.userId

        switch self.state.collectionPickerState {
        case .picked(let library, let collection):
            libraryId = library.identifier
            collectionKeys = collection?.identifier.key.flatMap({ [$0] }) ?? []
        default:
            libraryId = ExtensionStore.defaultLibraryId
            collectionKeys = []
        }

        if let attachment = self.state.processedAttachment {
            switch attachment {
            case .item(let item):
                DDLogInfo("ExtensionStore: submit item")
                self.submit(item: item.copy(libraryId: libraryId, collectionKeys: collectionKeys, addedTags: tags), libraryId: libraryId, userId: userId,
                            apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage, schemaController: self.schemaController, dateParser: self.dateParser)

            case .itemWithAttachment(let item, let attachmentData, let attachmentFile):
                DDLogInfo("ExtensionStore: submit item with attachment")
                let data = State.UploadData(item: item, attachmentKey: self.state.attachmentKey, attachmentData: attachmentData,
                                            attachmentFile: attachmentFile, defaultTitle: (self.state.title ?? "Unknown"),
                                            collections: collectionKeys, tags: tags, libraryId: libraryId, userId: userId, dateParser: self.dateParser)
                self.upload(data: data, apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage, webDavController: self.webDavController)

            case .localFile(let file, let filename):
                DDLogInfo("ExtensionStore: upload local file")
                let data = State.UploadData(localFile: file, filename: filename, attachmentKey: self.state.attachmentKey, collections: collectionKeys, tags: tags, libraryId: libraryId, userId: userId)
                self.upload(data: data, apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage, webDavController: self.webDavController)
            }
        } else if let url = self.state.url {
            DDLogInfo("ExtensionStore: submit webpage")

            let date = Date()
            let fields: [String: String] = [FieldKeys.Item.Attachment.url: url,
                                            FieldKeys.Item.title: (self.state.title ?? "Unknown"),
                                            FieldKeys.Item.accessDate: Formatter.iso8601.string(from: date)]

            let webItem = ItemResponse(rawType: ItemTypes.webpage, key: KeyGenerator.newKey, library: LibraryResponse(libraryId: libraryId),
                                       parentKey: nil, collectionKeys: collectionKeys, links: nil, parsedDate: nil, isTrash: false, version: 0,
                                       dateModified: date, dateAdded: date, fields: fields, tags: tags, creators: [], relations: [:], createdBy: nil,
                                       lastModifiedBy: nil, rects: nil, paths: nil)

            self.submit(item: webItem, libraryId: libraryId, userId: userId, apiClient: self.apiClient, dbStorage: self.dbStorage,
                        fileStorage: self.fileStorage, schemaController: self.schemaController, dateParser: self.dateParser)
        } else {
            DDLogInfo("ExtensionStore: nothing to submit")
        }
    }

    /// Used for item without attachment. Creates a DB model of item and submits it to Zotero API.
    /// - parameter item: Parsed item to submit.
    /// - parameter libraryId: Identifier of library to which the item will be submitted.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    /// - parameter schemaController: Schema controller for validating item type and field types.
    /// - parameter dateParser: Date parser for item creation
    private func submit(item: ItemResponse, libraryId: LibraryIdentifier, userId: Int, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage, schemaController: SchemaController,
                        dateParser: DateParser) {
        let itemToSubmit = item.tags.isEmpty || Defaults.shared.shareExtensionIncludeTags ? item : item.copyWithoutTags
        self.createItem(itemToSubmit, libraryId: libraryId, schemaController: schemaController, dateParser: dateParser)
            .subscribe(on: self.backgroundScheduler)
            .flatMap { parameters in
                return SubmitUpdateSyncAction(parameters: [parameters], sinceVersion: nil, object: .item, libraryId: libraryId, userId: userId, updateLibraryVersion: false, apiClient: apiClient,
                                              dbStorage: dbStorage, fileStorage: fileStorage, queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
            }
            .observe(on: MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] _ in
                self?.state.isDone = true
            }, onFailure: { [weak self] error in
                guard let `self` = self else { return }

                DDLogError("ExtensionStore: could not submit standalone item - \(error)")

                var state = self.state
                state.attachmentState = .failed(self.attachmentError(from: error, libraryId: libraryId))
                state.isSubmitting = false
                self.state = state
            })
            .disposed(by: self.disposeBag)
    }

    private func attachmentError(from error: Error, libraryId: LibraryIdentifier?) -> State.AttachmentState.Error {
        if let error = error as? State.AttachmentState.Error {
            return error
        }
        if let error = error as? Parsing.Error {
            DDLogError("ExtensionStore: could not parse item - \(error)")
            return .parseError(error)
        }
        if let error = error as? SchemaError {
            DDLogError("ExtensionStore: schema failed - \(error)")
            return .schemaError(error)
        }
        if let error = error as? TranslationWebViewHandler.Error {
            return .webViewError(error)
        }
        if let responseError = error as? AFResponseError {
            return self.alamoErrorRequiresAbort(responseError.error, url: responseError.url, libraryId: libraryId)
        }
        if let alamoError = error as? AFError {
            return self.alamoErrorRequiresAbort(alamoError, url: nil, libraryId: libraryId)
        }
        return .unknown
    }

    private func alamoErrorRequiresAbort(_ error: AFError, url: URL?, libraryId: LibraryIdentifier?) -> State.AttachmentState.Error {
        let defaultError: State.AttachmentState.Error = (url?.absoluteString ?? "").contains(ApiConstants.baseUrlString) ? .apiFailure : .webDavFailure
        switch error {
        case .responseValidationFailed(let reason):
            switch reason {
            case .unacceptableStatusCode(let code):
                if code == 413, let libraryId = libraryId {
                    return .quotaLimit(libraryId)
                }
                return defaultError
            default:
                return defaultError
            }
        default:
            return defaultError
        }
    }

    /// Creates an `RItem` instance in DB.
    /// - parameter item: Parsed item to be created.
    /// - parameter schemaController: Schema controller for validating item type and field types.
    /// - returns: `Single` with `updateParameters` of created `RItem`.
    private func createItem(_ item: ItemResponse, libraryId: LibraryIdentifier, schemaController: SchemaController, dateParser: DateParser) -> Single<[String: Any]> {
        return Single.create { subscriber -> Disposable in

            DDLogInfo("ExtensionStore: create db item")

            let request = CreateBackendItemDbRequest(item: item, schemaController: schemaController, dateParser: dateParser)
            do {
                let coordinator = try self.dbStorage.createCoordinator()
                if let collectionKey = item.collectionKeys.first {
                    try coordinator.perform(request: UpdateCollectionLastUsedDbRequest(key: collectionKey, libraryId: libraryId))
                }
                let item = try coordinator.perform(request: request)
                subscriber(.success(item.updateParameters ?? [:]))
            } catch let error {
                subscriber(.failure(error))
            }

            return Disposables.create()
        }
    }

    /// Used for file uploads. Prepares the item(s) for upload and enqueues a background upload.
    /// - parameter data: Data for upload.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    private func upload(data: State.UploadData, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage, webDavController: WebDavController) {
        if Defaults.shared.webDavEnabled {
            self.uploadToWebDav(data: data, apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage, webDavController: webDavController)
        } else {
            self.uploadToZotero(data: data, apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage)
        }
    }

    private func uploadToZotero(data: State.UploadData, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) {
        let authorize = self.submit(data: data, apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage)
                            .flatMap { submissionData -> Single<(AuthorizeUploadResponse, String)> in
                                return AuthorizeUploadSyncAction(key: data.attachment.key, filename: data.filename, filesize: submissionData.filesize, md5: submissionData.md5,
                                                                 mtime: submissionData.mtime, libraryId: data.libraryId, userId: data.userId, oldMd5: nil, apiClient: apiClient,
                                                                 queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                            .flatMap({ return Single.just(($0, submissionData.md5)) })
                            }

        authorize.flatMap { [weak self] response, md5 -> Single<()> in
                   guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }

                   switch response {
                   case .exists(let version):
                       DDLogInfo("ExtensionStore: file exists remotely")

                       do {
                           let request = MarkAttachmentUploadedDbRequest(libraryId: data.libraryId, key: data.attachment.key, version: version)
                           let request2 = UpdateVersionsDbRequest(version: version, libraryId: data.libraryId, type: .object(.item))
                           try dbStorage.createCoordinator().perform(requests: [request, request2])
                           return Single.just(())
                       } catch let error {
                           return Single.error(error)
                       }

                   case .new(let response):
                       DDLogInfo("ExtensionStore: upload authorized")

                       // sessionId and size are set by background uploader.
                       let upload = BackgroundUpload(type: .zotero(uploadKey: response.uploadKey), key: self.state.attachmentKey, libraryId: data.libraryId, userId: data.userId,
                                                     remoteUrl: response.url, fileUrl: data.file.createUrl(), md5: md5, date: Date())
                       return self.backgroundUploader.start(upload: upload, filename: data.filename, mimeType: ExtensionStore.defaultMimetype, parameters: response.params,
                                                            headers: ["If-None-Match": "*"], delegate: self.backgroundUploadObserver)
                                  .flatMap({ session in
                                      self.backgroundUploadObserver.startObservingInShareExtension(session: session)
                                      return Single.just(())
                                  })
                   }
               }
               .observe(on: MainScheduler.instance)
               .subscribe(onSuccess: { [weak self] _ in
                   self?.state.isDone = true
               }, onFailure: { [weak self] error in
                   guard let `self` = self else { return }

                   DDLogError("ExtensionStore: could not submit item or attachment - \(error)")

                   var state = self.state
                   state.attachmentState = .failed(self.attachmentError(from: error, libraryId: data.libraryId))
                   state.isSubmitting = false
                   self.state = state
               })
               .disposed(by: self.disposeBag)
    }

    private func uploadToWebDav(data: State.UploadData, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage, webDavController: WebDavController) {
        let prepare = self.submit(data: data, apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage)
                          .flatMap { submissionData -> Single<(WebDavUploadResult, SubmissionData)> in
                              return webDavController.prepareForUpload(key: data.attachment.key, mtime: submissionData.mtime, hash: submissionData.md5, file: data.file, queue: self.backgroundQueue)
                                                     .flatMap({ return Single.just(($0, submissionData)) })
                          }

        prepare.flatMap { [weak self] response, submissionData -> Single<()> in
            guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }

            switch response {
            case .exists:
                DDLogInfo("ExtensionStore: file exists remotely")

                do {
                    let request = MarkAttachmentUploadedDbRequest(libraryId: data.libraryId, key: data.attachment.key, version: nil)
                    try dbStorage.createCoordinator().perform(request: request)
                    return Single.just(())
                } catch let error {
                    return Single.error(error)
                }

            case .new(let url, let file):
                DDLogInfo("ExtensionStore: upload authorized")

                let upload = BackgroundUpload(type: .webdav(mtime: submissionData.mtime), key: self.state.attachmentKey, libraryId: data.libraryId, userId: data.userId,
                                              remoteUrl: url, fileUrl: file.createUrl(), md5: submissionData.md5, date: Date())
                return self.backgroundUploader.start(upload: upload, filename: (data.attachment.key + ".zip"), mimeType: ExtensionStore.zipMimetype, parameters: [:], headers: [:],
                                                     delegate: self.backgroundUploadObserver)
                           .flatMap({ session in
                               self.backgroundUploadObserver.startObservingInShareExtension(session: session)
                               return Single.just(())
                           })
            }
        }
        .observe(on: MainScheduler.instance)
        .subscribe(onSuccess: { [weak self] _ in
            self?.state.isDone = true
        }, onFailure: { [weak self] error in
            guard let `self` = self else { return }

            DDLogError("ExtensionStore: could not submit item or attachment - \(error)")

            var state = self.state
            state.attachmentState = .failed(self.attachmentError(from: error, libraryId: data.libraryId))
            state.isSubmitting = false
            self.state = state
        })
        .disposed(by: self.disposeBag)
    }

    private func submit(data: State.UploadData, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) -> Single<SubmissionData> {
        switch data.type {
        case .localFile(let location, let collections, let tags):
            DDLogInfo("ExtensionStore: prepare upload for local file")
            return self.prepareAndSubmit(attachment: data.attachment, collections: collections, tags: tags, file: data.file, tmpFile: location, libraryId: data.libraryId, userId: data.userId,
                                         apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage)
        case .translated(let item, let location):
            DDLogInfo("ExtensionStore: prepare upload for local file")
            return self.prepareAndSubmit(item: item, attachment: data.attachment, file: data.file, tmpFile: location, libraryId: data.libraryId, userId: data.userId, apiClient: apiClient,
                                         dbStorage: dbStorage, fileStorage: fileStorage)
        }
    }

    /// Prepares for file upload. Copies local file to new location appropriate for new item. Creates `RItem` instance in DB for attachment. Submits new `RItem`s to Zotero API.
    /// - parameter attachment: Attachment to be created and submitted.
    /// - parameter collections: Collections to which the attachment is assigned.
    /// - parameter tags: Tags picked by user.
    /// - parameter file: File to upload.
    /// - parameter tmpFile: Original file.
    /// - parameter filename: Filename of file to upload.
    /// - parameter libraryId: Identifier of library to which items will be submitted.
    /// - parameter userId: Id of current user.
    /// - parameter apiClient: API client.
    /// - parameter dbStorage: Database storage.
    /// - parameter fileStorage: File storage.
    /// - parameter webDavController: WebDAV controller.
    /// - returns: `Single` with Authorization response and md5 hash of file.
    private func prepareAndSubmit(attachment: Attachment, collections: Set<String>, tags: [TagResponse], file: File, tmpFile: File, libraryId: LibraryIdentifier, userId: Int,
                                  apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) -> Single<SubmissionData> {
        return self.moveFile(from: tmpFile, to: file)
                   .subscribe(on: self.backgroundScheduler)
                   .flatMap { [weak self] filesize -> Single<([String: Any], SubmissionData)> in
                       guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }
                       return self.create(attachment: attachment, collections: collections, tags: tags)
                                  .flatMap({ Single.just(($0, SubmissionData(filesize: filesize, md5: $1, mtime: $2))) })
                                  .do(onError: { [weak self] _ in
                                      // If attachment item couldn't be created in DB, remove the moved file if possible, it won't be processed even from the main app
                                      try? self?.fileStorage.remove(file)
                                  })
                   }
                   .flatMap { parameters, data -> Single<SubmissionData> in
                       return SubmitUpdateSyncAction(parameters: [parameters], sinceVersion: nil, object: .item, libraryId: libraryId, userId: userId, updateLibraryVersion: false,
                                                     apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage,
                                                     queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ _ in Single.just(data) })
                   }
    }

    /// Prepares for file upload. Moves file to new location appropriate for new item. Creates `RItem` instances in DB for item and attachment. Submits new `RItem`s to Zotero API.
    /// - parameter item: Item to be created and submitted.
    /// - parameter attachment: Attachment to be created and submitted.
    /// - parameter file: File to upload.
    /// - parameter tmpFile: Original file.
    /// - parameter filename: Filename of file to upload.
    /// - parameter libraryId: Identifier of library to which items will be submitted.
    /// - parameter userId: Id of current user.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    /// - returns: `Single` with Authorization response and md5 hash of file.
    private func prepareAndSubmit(item: ItemResponse, attachment: Attachment, file: File, tmpFile: File, libraryId: LibraryIdentifier, userId: Int,
                                  apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) -> Single<SubmissionData> {
        return self.moveFile(from: tmpFile, to: file)
                   .subscribe(on: self.backgroundScheduler)
                   .flatMap { [weak self] filesize -> Single<([[String: Any]], SubmissionData)> in
                       guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }
                       return self.createItems(item: item, attachment: attachment)
                                  .flatMap({ Single.just(($0, SubmissionData(filesize: filesize, md5: $1, mtime: $2))) })
                                  .do(onError: { [weak self] _ in
                                      // If attachment item couldn't be created in DB, remove the moved file if possible, it won't be processed even from the main app
                                      try? self?.fileStorage.remove(file)
                                  })
                   }
                   .flatMap { parameters, data -> Single<SubmissionData> in
                       return SubmitUpdateSyncAction(parameters: parameters, sinceVersion: nil, object: .item, libraryId: libraryId, userId: userId, updateLibraryVersion: false,
                                                     apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage,
                                                     queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ _ in Single.just(data) })
                   }
    }

    /// Moves downloaded file from temporary folder to file appropriate for given attachment item.
    /// - parameter from: `File` where from the file is being moved.
    /// - parameter to: `File` where the file needs to be moved.
    /// - returns: `Single` with size of file.
    private func moveFile(from fromFile: File, to toFile: File) -> Single<UInt64> {
        return Single.create { subscriber -> Disposable in
            DDLogInfo("ExtensionStore: move file to attachment folder")

            do {
                let size = self.fileStorage.size(of: fromFile)
                if size == 0 {
                    subscriber(.failure(State.AttachmentState.Error.fileMissing))
                    return Disposables.create()
                }
                try self.fileStorage.move(from: fromFile, to: toFile)
                subscriber(.success(size))
            } catch let error {
                DDLogError("ExtensionStore: can't move file: \(error)")
                // If tmp file couldn't be moved, remove it if it's there
                try? self.fileStorage.remove(fromFile)
                subscriber(.failure(State.AttachmentState.Error.fileMissing))
            }

            return Disposables.create()
        }
    }

    /// Copies local file from temporary folder to file appropriate for given attachment item.
    /// - parameter from: `File` where from the file is being moved.
    /// - parameter to: `File` where the file needs to be moved.
    /// - returns: `Single` with size of file.
    private func copyFile(from path: String, to toFile: File) -> Single<UInt64> {
        return Single.create { subscriber -> Disposable in
            DDLogInfo("ExtensionStore: copy file to attachment folder")

            do {
                let size = self.fileStorage.size(of: path)
                if size == 0 {
                    subscriber(.failure(State.AttachmentState.Error.fileMissing))
                    return Disposables.create()
                }
                try self.fileStorage.copy(from: path, to: toFile)
                subscriber(.success(size))
            } catch let error {
                DDLogError("ExtensionStore: can't copy file: \(error)")
                subscriber(.failure(State.AttachmentState.Error.fileMissing))
            }

            return Disposables.create()
        }
    }

    /// Creates `RItem` instances in DB from parsed item and attachement.
    /// - parameter item: Parsed item to be created.
    /// - parameter attachment: Parsed attachment to be created.
    /// - returns: `Single` with `updateParameters` of both new items, md5 and mtime of attachment.
    private func createItems(item: ItemResponse, attachment: Attachment) -> Single<([[String: Any]], String, Int)> {
        return Single.create { subscriber -> Disposable in
            DDLogInfo("ExtensionStore: create item and attachment db items")

            let request = CreateItemWithAttachmentDbRequest(item: item, attachment: attachment, schemaController: self.schemaController, dateParser: self.dateParser)

            do {
                let coordinator = try self.dbStorage.createCoordinator()

                if let collectionKey = item.collectionKeys.first {
                    try coordinator.perform(request: UpdateCollectionLastUsedDbRequest(key: collectionKey, libraryId: attachment.libraryId))
                }

                let (item, attachment) = try coordinator.perform(request: request)

                guard let mtime = attachment.fields.filter(.key(FieldKeys.Item.Attachment.mtime)).first.flatMap({ Int($0.value) }) else {
                    throw State.AttachmentState.Error.mtimeMissing
                }
                guard let md5 = attachment.fields.filter(.key(FieldKeys.Item.Attachment.md5)).first?.value else {
                    throw State.AttachmentState.Error.md5Missing
                }

                var parameters: [[String: Any]] = []
                if let updateParameters = item.updateParameters {
                    parameters.append(updateParameters)
                }
                if let updateParameters = attachment.updateParameters {
                    parameters.append(updateParameters)
                }

                subscriber(.success((parameters, md5, mtime)))
            } catch let error {
                subscriber(.failure(error))
            }

            return Disposables.create()
        }
    }

    /// Creates `RItem` instance in DB from parsed attachement.
    /// - parameter attachment: Parsed attachment to be created.
    /// - parameter collections: Set of collections to which the attachment is assigned.
    /// - parameter tags: Tags picked by user.
    /// - returns: `Single` with `updateParameters` of both new items, md5 and mtime of attachment.
    private func create(attachment: Attachment, collections: Set<String>, tags: [TagResponse]) -> Single<([String: Any], String, Int)> {
        return Single.create { subscriber -> Disposable in
            DDLogInfo("ExtensionStore: create attachment db item")

            let localizedType = self.schemaController.localized(itemType: ItemTypes.attachment) ?? ""
            let request = CreateAttachmentDbRequest(attachment: attachment, localizedType: localizedType, collections: collections, tags: tags)

            do {
                let coordinator = try self.dbStorage.createCoordinator()

                if let collectionKey = collections.first {
                    try coordinator.perform(request: UpdateCollectionLastUsedDbRequest(key: collectionKey, libraryId: attachment.libraryId))
                }

                let attachment = try coordinator.perform(request: request)
                guard let mtime = attachment.fields.filter(.key(FieldKeys.Item.Attachment.mtime)).first.flatMap({ Int($0.value) }) else {
                    throw State.AttachmentState.Error.mtimeMissing
                }
                guard let md5 = attachment.fields.filter(.key(FieldKeys.Item.Attachment.md5)).first?.value else {
                    throw State.AttachmentState.Error.md5Missing
                }

                subscriber(.success((attachment.updateParameters ?? [:], md5, mtime)))
            } catch let error {
                subscriber(.failure(error))
            }

            return Disposables.create()
        }
    }

    // MARK: - Collection picker

    func set(collection: Collection?, library: Library) {
        self.updateSelected(collection: collection, library: library) { state in
            if let new = state.recents.first(where: { $0.collection?.identifier == collection?.identifier && $0.library.identifier == library.identifier }) {
                if new.isRecent && !state.recents[0].isRecent {
                    state.recents.removeFirst()
                }
            } else {
                if !state.recents[0].isRecent {
                    state.recents[0] = RecentData(collection: collection, library: library, isRecent: false)
                } else {
                    state.recents.insert(RecentData(collection: collection, library: library, isRecent: false), at: 0)
                }
            }
        }
    }

    func setFromRecent(collection: Collection?, library: Library) {
        self.updateSelected(collection: collection, library: library)
    }

    private func updateSelected(collection: Collection?, library: Library, additionalStateChange: ((inout State) -> Void)? = nil) {
        var state = self.state
        state.selectedLibraryId = library.identifier
        state.selectedCollectionId = collection?.identifier ?? Collection(custom: .all).identifier
        state.collectionPickerState = .picked(library, collection)
        if let change = additionalStateChange {
            change(&state)
        }
        self.state = state

        Defaults.shared.selectedCollectionId = state.selectedCollectionId
        Defaults.shared.selectedLibrary = state.selectedLibraryId
    }

    // MARK: - Tag picker

    func set(tags: [Tag]) {
        self.state.tags = tags
    }

    // MARK: - Sync

    private func setupSyncObserving() {
        self.syncController.observable
                           .observe(on: MainScheduler.instance)
                           .subscribe(onNext: { [weak self] data in
                               self?.finishSync(successful: (data == nil))
                           }, onError: { [weak self] _ in
                               self?.finishSync(successful: false)
                           })
                           .disposed(by: self.disposeBag)
    }

    private func finishSync(successful: Bool) {
        if successful {
            do {
                let coordinator = try self.dbStorage.createCoordinator()
                let request = ReadCollectionAndLibraryDbRequest(collectionId: self.state.selectedCollectionId, libraryId: self.state.selectedLibraryId)
                let (collection, library) = try coordinator.perform(request: request)
                let recentCollections = try coordinator.perform(request: ReadRecentCollections(excluding: nil))
                var recents = recentCollections
                if !recents.contains(where: { $0.collection?.identifier == collection?.identifier && $0.library.identifier == library.identifier }) {
                    recents.insert(RecentData(collection: collection, library: library, isRecent: false), at: 0)
                }

                var state = self.state
                state.collectionPickerState = .picked(library, collection)
                state.recents = recents
                self.state = state
            } catch let error {
                DDLogError("ExtensionStore: can't load collections - \(error)")
                let library = Library(identifier: ExtensionStore.defaultLibraryId, name: RCustomLibraryType.myLibrary.libraryName, metadataEditable: true, filesEditable: true)
                self.state.collectionPickerState = .picked(library, nil)
            }
        } else {
            self.state.collectionPickerState = .failed
        }
    }
}
