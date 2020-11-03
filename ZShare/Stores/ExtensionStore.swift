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

import CocoaLumberjackSwift
import RxSwift
import RxAlamofire

/// `ExtensionStore` performs fetching of basic website data, runs the translation server which translates the web data, downloads item data with
/// pdf attachment if available and uploads new item to Zotero.
///
/// These steps are performed for each share:
/// 1. Website data (url, title, cookies and full HTML) are loaded from `NSExtensionItem`,
/// 2. Translation server is run in a hidden WebView (handled by `WebViewHandler`). It loads item data and attachment if available,
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
class ExtensionStore {
    struct State {
        enum CollectionPicker {
            case loading, failed
            case picked(Library, Collection?)

            var library: Library? {
                switch self {
                case .picked(let library, _):
                    return library
                default:
                    return nil
                }
            }
        }

        struct ItemPicker {
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
                case cantLoadSchema, cantLoadWebData, downloadFailed, itemsNotFound, expired, unknown,
                     fileMissing, missingBackgroundUploader
                case webViewError(WebViewHandler.Error)
                case parseError(Parsing.Error)
                case schemaError(SchemaError)

                var isFatal: Bool {
                    switch self {
                    case .cantLoadWebData, .cantLoadSchema: return true
                    default: return false
                    }
                }
            }

            case decoding
            case translating(String)
            case downloading(Float)
            case processed
            case submitting
            case done
            case failed(Error)

            var isSubmittable: Bool {
                switch self {
                case .processed: return true
                case .failed(let error): return !error.isFatal
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
        fileprivate enum ProcessedAttachment {
            case item(ItemResponse)
            case itemWithAttachment(item: ItemResponse, attachment: [String: String], attachmentFile: File)
            case localFile(File)
        }

        fileprivate struct UploadData {
            enum Kind {
                case localFile(location: File, collections: Set<String>)
                case translated(item: ItemResponse, location: File)
            }

            let type: Kind
            let attachment: Attachment
            let file: File
            let filename: String
            let libraryId: LibraryIdentifier
            let userId: Int

            init(item: ItemResponse, attachmentKey: String, attachmentData: [String: String], attachmentFile: File, defaultTitle: String,
                 collections: Set<String>, libraryId: LibraryIdentifier, userId: Int) {
                let newItem = item.copy(libraryId: libraryId, collectionKeys: collections)
                let filename = attachmentData["title"] ?? defaultTitle
                let file = Files.attachmentFile(in: libraryId, key: attachmentKey, ext: ExtensionStore.defaultExtension)
                let attachment = Attachment(key: attachmentKey, title: filename, type: .file(file: file, filename: filename, location: .local, linkType: .imported),
                                            libraryId: libraryId)

                self.type = .translated(item: newItem, location: attachmentFile)
                self.attachment = attachment
                self.file = file
                self.filename = filename
                self.libraryId = libraryId
                self.userId = userId
            }

            init(localFile: File, attachmentKey: String, collections: Set<String>, libraryId: LibraryIdentifier, userId: Int) {
                let filename = localFile.name
                let file = Files.attachmentFile(in: libraryId, key: attachmentKey, ext: localFile.ext)
                let attachment = Attachment(key: attachmentKey, title: filename, type: .file(file: file, filename: filename, location: .local, linkType: .imported),
                                            libraryId: libraryId)

                self.type = .localFile(location: localFile, collections: collections)
                self.attachment = attachment
                self.file = file
                self.filename = filename
                self.libraryId = libraryId
                self.userId = userId
            }
        }

        let attachmentKey: String
        var title: String?
        var url: String?
        var attachmentState: AttachmentState
        var collectionPicker: CollectionPicker
        var itemPicker: ItemPicker?
        fileprivate var processedAttachment: ProcessedAttachment?

        init() {
            self.attachmentKey = KeyGenerator.newKey
            self.collectionPicker = .loading
            self.attachmentState = .decoding
        }
    }

    @Published var state: State
    // The background uploader is optional because it needs to be deinitialized after starting the upload. See more in comment where the uploader is nilled.
    private var backgroundUploader: BackgroundUploader?

    private static let defaultLibraryId: LibraryIdentifier = .custom(.myLibrary)
    private static let defaultExtension = "pdf"
    private static let defaultMimetype = "application/pdf"

    private let syncController: SyncController
    private let apiClient: ApiClient
    private let dbStorage: DbStorage
    private let fileStorage: FileStorage
    private let schemaController: SchemaController
    private let dateParser: DateParser
    private let webViewHandler: WebViewHandler
    private let backgroundQueue: DispatchQueue
    private let backgroundScheduler: SerialDispatchQueueScheduler
    private let disposeBag: DisposeBag

    init(webView: WKWebView, apiClient: ApiClient, backgroundUploader: BackgroundUploader,
         dbStorage: DbStorage, schemaController: SchemaController, dateParser: DateParser, fileStorage: FileStorage,
         syncController: SyncController, translatorsController: TranslatorsController) {
        let queue = DispatchQueue(label: "org.zotero.ZShare.BackgroundQueue", qos: .userInteractive)
        self.syncController = syncController
        self.apiClient = apiClient
        self.backgroundUploader = backgroundUploader
        self.dbStorage = dbStorage
        self.fileStorage = fileStorage
        self.schemaController = schemaController
        self.dateParser = dateParser
        self.webViewHandler = WebViewHandler(webView: webView, translatorsController: translatorsController)
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
        self.syncController.start(type: .normal, libraries: .all)

        self.loadAttachment(from: extensionItem)
            .subscribe(onSuccess: { [weak self] attachment in
                self?.process(attachment: attachment)
            }, onError: { [weak self] error in
                self?.state.attachmentState = .failed((error as? State.AttachmentState.Error) ?? .unknown)
            })
            .disposed(by: self.disposeBag)
    }

    func cancel() {
        guard let attachment = self.state.processedAttachment else { return }
        switch attachment {
        case .itemWithAttachment(_, _, let file), .localFile(let file):
            // Remove temporary local file if it exists
            try? self.fileStorage.remove(file)
        case .item: break
        }
    }

    // MARK: - Processing attachments

    private func loadAttachment(from extensionItem: NSExtensionItem) -> Single<State.RawAttachment> {
        if let itemProvider = extensionItem.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypePropertyList as String) }) {
            return self.loadWebData(from: itemProvider)
        } else if let itemProvider = extensionItem.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypeURL as String) }) {
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

            self.webViewHandler.translate(url: url, title: title, html: html, cookies: cookies, frames: frames)
        case .remoteUrl(let url):
            self.webViewHandler.loadWebData(from: url)
                               .subscribe(onSuccess: { [weak self] attachment in
                                   self?.process(attachment: attachment)
                               }, onError: { [weak self] error in
                                   self?.state.attachmentState = .failed((error as? State.AttachmentState.Error) ?? .unknown)
                               })
                               .disposed(by: self.disposeBag)
        case .fileUrl(let url):
            let file = Files.file(from: url)

            var state = self.state
            state.processedAttachment = .localFile(file)
            state.attachmentState = .processed
            self.state = state

        case .remoteFileUrl(let url, let contentType):
            var state = self.state
            state.url = url.absoluteString
            state.title = url.absoluteString
            state.attachmentState = .downloading(0)
            self.state = state

            let file = Files.shareExtensionTmpItem(key: self.state.attachmentKey, contentType: contentType)
            self.download(url: url, to: file)
                .observeOn(MainScheduler.instance)
                .subscribe(onNext: { [weak self] progress in
                    self?.state.attachmentState = .downloading(progress.completed)
                }, onError: { [weak self] error in
                    self?.state.attachmentState = .failed(.downloadFailed)
                }, onCompleted: { [weak self] in
                    guard let `self` = self else { return }

                    var state = self.state
                    state.processedAttachment = .localFile(file)
                    state.attachmentState = .processed
                    self.state = state
                })
                .disposed(by: self.disposeBag)
            break
        }
    }

    private func loadUrl(from itemProvider: NSItemProvider) -> Single<URL> {
        return Single.create { [weak itemProvider] subscriber in
            guard let itemProvider = itemProvider else {
                subscriber(.error(State.AttachmentState.Error.cantLoadWebData))
                return Disposables.create()
            }

            itemProvider.loadItem(forTypeIdentifier: (kUTTypeURL as String), options: nil, completionHandler: { item, error -> Void in
                if let error = error {
                    DDLogError("ExtensionStore: url load error - \(error)")
                }

                if let url = item as? URL {
                    subscriber(.success(url))
                } else {
                    DDLogError("ExtensionStore: can't load URL")
                    subscriber(.error(State.AttachmentState.Error.cantLoadWebData))
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
                subscriber(.error(State.AttachmentState.Error.cantLoadWebData))
                return Disposables.create()
            }

            itemProvider.loadItem(forTypeIdentifier: (kUTTypePropertyList as String), options: nil, completionHandler: { item, error -> Void in
                if let error = error {
                    DDLogError("ExtensionStore: web data load error - \(error)")
                }

                guard let scriptData = item as? [String: Any],
                      let data = scriptData[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                      let isFile = data["isFile"] as? Bool,
                      let url = (data["url"] as? String).flatMap(URL.init) else {
                    DDLogError("ExtensionStore: can't read script data")
                    subscriber(.error(State.AttachmentState.Error.cantLoadWebData))
                    return
                }

                if isFile,
                   let contentType = data["contentType"] as? String {
                    subscriber(.success(.remoteFileUrl(url: url, contentType: contentType)))
                } else if let title = data["title"] as? String,
                          let html = data["html"] as? String,
                          let cookies = data["cookies"] as? String,
                          let frames = data["frames"] as? [String] {
                    subscriber(.success(.web(title: title, url: url, html: html, cookies: cookies, frames: frames)))
                } else {
                    DDLogError("ExtensionStore: script data don't contain required info")
                    DDLogError("\(data)")
                    subscriber(.error(State.AttachmentState.Error.cantLoadWebData))
                }
            })

            return Disposables.create()
        }
    }

    // MARK: - Translation

    /// Observes `WebViewHandler` translation process and acts accordingly.
    private func  setupWebHandlerObserving() {
        self.webViewHandler.observable
                           .observeOn(MainScheduler.instance)
                           .subscribe(onNext: { [weak self] action in
                               switch action {
                               case .loadedItems(let data):
                                   self?.processItems(data)
                               case .selectItem(let data):
                                   self?.state.itemPicker = State.ItemPicker(items: data, picked: nil)
                               case .reportProgress(let progress):
                                   self?.state.attachmentState = .translating(progress)
                               }
                           }, onError: { [weak self] error in
                               self?.state.attachmentState = .failed((error as? WebViewHandler.Error).flatMap({ .webViewError($0) }) ?? .unknown)
                           })
                           .disposed(by: self.disposeBag)

    }

    /// Parses item from translation response, starts attachment download if available.
    private func processItems(_ data: [[String: Any]]) {
        do {
            let (item, attachment) = try self.parse(data, schemaController: self.schemaController)
            if let attachment = attachment,
               let urlString = attachment["url"],
               let url = URL(string: urlString) {
                let file = Files.shareExtensionTmpItem(key: self.state.attachmentKey, ext: ExtensionStore.defaultExtension)

                self.state.attachmentState = .downloading(0)

                self.download(url: url, to: file)
                    .observeOn(MainScheduler.instance)
                    .subscribe(onNext: { [weak self] progress in
                        self?.state.attachmentState = .downloading(progress.completed)
                    }, onError: { [weak self] error in
                        self?.state.attachmentState = .failed(.downloadFailed)
                    }, onCompleted: { [weak self] in
                        guard let `self` = self else { return }

                        var state = self.state
                        state.processedAttachment = .itemWithAttachment(item: item, attachment: attachment, attachmentFile: file)
                        state.attachmentState = .processed
                        self.state = state
                    })
                    .disposed(by: self.disposeBag)
            } else {
                var state = self.state
                state.processedAttachment = .item(item)
                state.attachmentState = .processed
                self.state = state
            }
        } catch let error as Parsing.Error {
            self.state.attachmentState = .failed(.parseError(error))
        } catch let error as SchemaError {
            self.state.attachmentState = .failed(.schemaError(error))
        } catch let error as State.AttachmentState.Error {
            self.state.attachmentState = .failed(error)
        } catch {
            self.state.attachmentState = .failed(.unknown)
        }
    }

    /// Tries to parse `ItemResponse` from data returned by translation server. It prioritizes items with attachments if there are multiple items.
    /// - parameter data: Data to parse
    /// - parameter schemaController: SchemaController which is used for validating item type and field types
    /// - returns: `ItemResponse` of parsed item and optional attachment dictionary with title and url.
    private func parse(_ data: [[String: Any]], schemaController: SchemaController) throws -> (ItemResponse, [String: String]?) {
        // Sort items so that the first item will have a PDF attachment (if available)
        let sortedData = data.sorted { left, right -> Bool in
            let leftAttachments = (left["attachments"] as? [[String: String]]) ?? []
            let leftHasPdf = leftAttachments.contains(where: { $0["mimeType"] == ExtensionStore.defaultMimetype })
            let rightAttachments = (right["attachments"] as? [[String: String]]) ?? []
            let rightHasPdf = rightAttachments.contains(where: { $0["mimeType"] == ExtensionStore.defaultMimetype })

            if !leftHasPdf && rightHasPdf {
                return false
            }
            return true
        }

        guard let itemData = sortedData.first else {
            throw State.AttachmentState.Error.itemsNotFound
        }

        let item = try ItemResponse(translatorResponse: itemData, schemaController: self.schemaController)
        let attachment = (itemData["attachments"] as? [[String: String]])?.first(where: { $0["mimeType"] == ExtensionStore.defaultMimetype })

        return (item, attachment)
    }

    /// Sets picked item if multiple items were found.
    func pickItem(_ data: (String, String)) {
        self.state.itemPicker?.picked = data.1
        self.webViewHandler.selectItem(data)
    }

    // MARK: - Attachment Download

    /// Starts download of PDF attachment. Downloads it to temporary folder.
    /// - parameter url: URL of file to download
    private func download(url: URL, to file: File) -> Observable<RxProgress> {
        let request = FileRequest(data: .external(url), destination: file)
        return self.apiClient.download(request: request)
                             .subscribeOn(self.backgroundScheduler)
                             .flatMap { request in
                                 return request.rx.progress()
                             }
    }

    // MARK: - Submission

    /// Submits translated item (and attachment) to Zotero API. Enqueues background upload if needed.
    func submit() {
        guard self.state.attachmentState.isSubmittable else { return }

        self.state.attachmentState = .submitting

        let libraryId: LibraryIdentifier
        let collectionKeys: Set<String>
        let userId = Defaults.shared.userId

        switch self.state.collectionPicker {
        case .picked(let library, let collection):
            libraryId = library.identifier
            collectionKeys = collection.flatMap({ [$0.key] }) ?? []
        default:
            libraryId = ExtensionStore.defaultLibraryId
            collectionKeys = []
        }

        if let attachment = self.state.processedAttachment {
            switch attachment {
            case .item(let item):
                self.submit(item: item.copy(libraryId: libraryId, collectionKeys: collectionKeys), libraryId: libraryId, userId: userId,
                            apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage,
                            schemaController: self.schemaController)

            case .itemWithAttachment(let item, let attachmentData, let attachmentFile):
                let data = State.UploadData(item: item, attachmentKey: self.state.attachmentKey, attachmentData: attachmentData,
                                            attachmentFile: attachmentFile, defaultTitle: (self.state.title ?? "Unknown"),
                                            collections: collectionKeys, libraryId: libraryId, userId: userId)
                self.upload(data: data, apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage)

            case .localFile(let file):
                let data = State.UploadData(localFile: file, attachmentKey: self.state.attachmentKey, collections: collectionKeys,
                                            libraryId: libraryId, userId: userId)
                self.upload(data: data, apiClient: self.apiClient, dbStorage: self.dbStorage, fileStorage: self.fileStorage)
            }
        } else if let url = self.state.url {
            let date = Date()
            let fields: [String: String] = [FieldKeys.Item.Attachment.url: url,
                                            FieldKeys.Item.title: (self.state.title ?? "Unknown"),
                                            FieldKeys.Item.accessDate: Formatter.iso8601.string(from: date)]

            let webItem = ItemResponse(rawType: ItemTypes.webpage, key: KeyGenerator.newKey, library: LibraryResponse(libraryId: libraryId),
                                       parentKey: nil, collectionKeys: collectionKeys, links: nil, parsedDate: nil, isTrash: false, version: 0,
                                       dateModified: date, dateAdded: date, fields: fields, tags: [], creators: [], relations: [:], createdBy: nil,
                                       lastModifiedBy: nil, rects: nil)

            self.submit(item: webItem, libraryId: libraryId, userId: userId, apiClient: self.apiClient, dbStorage: self.dbStorage,
                        fileStorage: self.fileStorage, schemaController: self.schemaController)
        }
    }

    /// Used for item without attachment. Creates a DB model of item and submits it to Zotero API.
    /// - parameter item: Parsed item to submit.
    /// - parameter libraryId: Identifier of library to which the item will be submitted.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    /// - parameter schemaController: Schema controller for validating item type and field types.
    private func submit(item: ItemResponse, libraryId: LibraryIdentifier, userId: Int,
                        apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage, schemaController: SchemaController) {
        self.createItem(item, schemaController: schemaController)
            .subscribeOn(self.backgroundScheduler)
            .flatMap { parameters in
                return SubmitUpdateSyncAction(parameters: [parameters], sinceVersion: nil, object: .item, libraryId: libraryId,
                                              userId: userId, apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage,
                                              queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
            }
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] _ in
                self?.state.attachmentState = .done
            }, onError: { [weak self] error in
                self?.state.attachmentState = .failed((error as? State.AttachmentState.Error) ?? .unknown)
            })
            .disposed(by: self.disposeBag)
    }

    /// Creates an `RItem` instance in DB.
    /// - parameter item: Parsed item to be created.
    /// - parameter schemaController: Schema controller for validating item type and field types.
    /// - returns: `Single` with `updateParameters` of created `RItem`.
    private func createItem(_ item: ItemResponse, schemaController: SchemaController) -> Single<[String: Any]> {
        let request = CreateBackendItemDbRequest(item: item, schemaController: schemaController, dateParser: self.dateParser)
        do {
            let item = try self.dbStorage.createCoordinator().perform(request: request)
            return Single.just(item.updateParameters ?? [:])
        } catch let error {
            return Single.error(error)
        }
    }

    /// Used for file uploads. Prepares the item(s) for upload and enqueues a background upload.
    /// - parameter data: Data for upload.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    private func upload(data: State.UploadData, apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) {
        let prepare: Single<(AuthorizeUploadResponse, String)>

        switch data.type {
        case .localFile(let location, let collections):
            prepare = self.prepareUpload(attachment: data.attachment, collections: collections, file: data.file, tmpFile: location,
                                         filename: data.filename, libraryId: data.libraryId, userId: data.userId, apiClient: apiClient,
                                         dbStorage: dbStorage, fileStorage: fileStorage)
        case .translated(let item, let location):
            prepare = self.prepareUpload(item: item, attachment: data.attachment, file: data.file, tmpFile: location, filename: data.filename,
                                         libraryId: data.libraryId, userId: data.userId, apiClient: apiClient, dbStorage: dbStorage,
                                         fileStorage: fileStorage)
        }

        prepare.flatMap { [weak self] response, md5 -> Single<()> in
                   guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }

                   switch response {
                   case .exists:
                       return Single.just(())
                   case .new(let response):
                       guard let backgroundUploader = self.backgroundUploader else {
                           return Single.error(State.AttachmentState.Error.missingBackgroundUploader)
                       }

                       let upload = BackgroundUpload(key: self.state.attachmentKey, libraryId: data.libraryId, userId: data.userId,
                                                     remoteUrl: response.url, fileUrl: data.file.createUrl(), uploadKey: response.uploadKey, md5: md5)
                       return backgroundUploader.start(upload: upload, filename: data.filename, mimeType: ExtensionStore.defaultMimetype,
                                                       parameters: response.params, headers: ["If-None-Match": "*"])
                   }
               }
               .observeOn(MainScheduler.instance)
               .subscribe(onSuccess: { [weak self] _ in
                   // The `backgroundUploader` is set to `nil` so that the `URLSession` delegate no longer exists for the share extension.
                   // This way the URLSession delegate will always be called in the main (container) app, where additional upload
                   // processing is performed.
                   self?.backgroundUploader = nil
                   self?.state.attachmentState = .done
               }, onError: { [weak self] error in
                   self?.state.attachmentState = .failed((error as? State.AttachmentState.Error) ?? .unknown)
               })
               .disposed(by: self.disposeBag)
    }

    /// Prepares for file upload. Copies local file to new location appropriate for new item. Creates `RItem` instance in DB for attachment.
    /// Submits new `RItem`s to Zotero API. Authorizes new upload to Zotero API.
    /// - parameter attachment: Attachment to be created and submitted.
    /// - parameter collections: Collections to which the attachment is assigned.
    /// - parameter file: File to upload.
    /// - parameter tmpFile: Original file.
    /// - parameter filename: Filename of file to upload.
    /// - parameter libraryId: Identifier of library to which items will be submitted.
    /// - parameter userId: Id of current user.
    /// - parameter apiClient: API client
    /// - parameter dbStorage: Database storage
    /// - parameter fileStorage: File storage
    /// - returns: `Single` with Authorization response and md5 hash of file.
    private func prepareUpload(attachment: Attachment, collections: Set<String>, file: File, tmpFile: File, filename: String, libraryId: LibraryIdentifier, userId: Int,
                               apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) -> Single<(AuthorizeUploadResponse, String)> {
        return self.copyFile(from: tmpFile, to: file)
                   .subscribeOn(self.backgroundScheduler)
                   .flatMap { [weak self] filesize -> Single<(UInt64, [String: Any], String, Int)> in
                       guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }
                       return self.create(attachment: attachment, collections: collections)
                                  .flatMap({ Single.just((filesize, $0, $1, $2)) })
                   }
                   .flatMap { filesize, parameters, md5, mtime -> Single<(UInt64, String, Int)> in
                       return SubmitUpdateSyncAction(parameters: [parameters], sinceVersion: nil, object: .item, libraryId: libraryId, userId: userId,
                                                     apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage,
                                                     queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ _ in Single.just((filesize, md5, mtime)) })
                   }
                   .flatMap { filesize, md5, mtime -> Single<(AuthorizeUploadResponse, String)> in
                       return AuthorizeUploadSyncAction(key: attachment.key, filename: filename, filesize: filesize, md5: md5, mtime: mtime,
                                                        libraryId: libraryId, userId: userId, oldMd5: nil, apiClient: apiClient,
                                                        queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ return Single.just(($0, md5)) })
                   }
    }

    /// Prepares for file upload. Moves file to new location appropriate for new item. Creates `RItem` instances in DB for item and attachment.
    /// Submits new `RItem`s to Zotero API. Authorizes new upload to Zotero API.
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
    private func prepareUpload(item: ItemResponse, attachment: Attachment, file: File, tmpFile: File, filename: String, libraryId: LibraryIdentifier, userId: Int,
                               apiClient: ApiClient, dbStorage: DbStorage, fileStorage: FileStorage) -> Single<(AuthorizeUploadResponse, String)> {
        return self.moveFile(from: tmpFile, to: file)
                   .subscribeOn(self.backgroundScheduler)
                   .flatMap { [weak self] filesize -> Single<(UInt64, [[String: Any]], String, Int)> in
                       guard let `self` = self else { return Single.error(State.AttachmentState.Error.expired) }
                       return self.createItems(item: item, attachment: attachment)
                                  .flatMap({ Single.just((filesize, $0, $1, $2)) })
                                  .do(onError: { [weak self] _ in
                                      // If attachment item couldn't be created in DB, remove the moved file if possible,
                                      // it won't be processed even from the main app
                                      try? self?.fileStorage.remove(file)
                                  })
                   }
                   .flatMap { filesize, parameters, md5, mtime -> Single<(UInt64, String, Int)> in
                       return SubmitUpdateSyncAction(parameters: parameters, sinceVersion: nil, object: .item, libraryId: libraryId, userId: userId,
                                                     apiClient: apiClient, dbStorage: dbStorage, fileStorage: fileStorage,
                                                     queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ _ in Single.just((filesize, md5, mtime)) })
                   }
                   .flatMap { filesize, md5, mtime -> Single<(AuthorizeUploadResponse, String)> in
                       return AuthorizeUploadSyncAction(key: attachment.key, filename: filename, filesize: filesize, md5: md5, mtime: mtime,
                                                        libraryId: libraryId, userId: userId, oldMd5: nil, apiClient: apiClient,
                                                        queue: self.backgroundQueue, scheduler: self.backgroundScheduler).result
                                    .flatMap({ return Single.just(($0, md5)) })
                   }
    }

    /// Moves downloaded file from temporary folder to file appropriate for given attachment item.
    /// - parameter from: `File` where from the file is being moved.
    /// - parameter to: `File` where the file needs to be moved.
    /// - returns: `Single` with size of file.
    private func moveFile(from fromFile: File, to toFile: File) -> Single<UInt64> {
        return Single.create { subscriber -> Disposable in
            do {
                let size = self.fileStorage.size(of: fromFile)
                if size == 0 {
                    subscriber(.error(State.AttachmentState.Error.fileMissing))
                    return Disposables.create()
                }
                try self.fileStorage.move(from: fromFile, to: toFile)
                subscriber(.success(size))
            } catch let error {
                DDLogError("ExtensionStore: can't move file: \(error)")
                // If tmp file couldn't be moved, remove it if it's there
                try? self.fileStorage.remove(fromFile)
                subscriber(.error(State.AttachmentState.Error.fileMissing))
            }

            return Disposables.create()
        }
    }

    /// Copies local file from temporary folder to file appropriate for given attachment item.
    /// - parameter from: `File` where from the file is being moved.
    /// - parameter to: `File` where the file needs to be moved.
    /// - returns: `Single` with size of file.
    private func copyFile(from fromFile: File, to toFile: File) -> Single<UInt64> {
        return Single.create { subscriber -> Disposable in
            do {
                let size = self.fileStorage.size(of: fromFile)
                if size == 0 {
                    subscriber(.error(State.AttachmentState.Error.fileMissing))
                    return Disposables.create()
                }
                try self.fileStorage.copy(from: fromFile, to: toFile)
                subscriber(.success(size))
            } catch let error {
                DDLogError("ExtensionStore: can't copy file: \(error)")
                subscriber(.error(State.AttachmentState.Error.fileMissing))
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
            let request = CreateItemWithAttachmentDbRequest(item: item, attachment: attachment,
                                                            schemaController: self.schemaController, dateParser: self.dateParser)

            do {
                let (item, attachment) = try self.dbStorage.createCoordinator().perform(request: request)

                let mtime = attachment.fields.filter(.key(FieldKeys.Item.Attachment.mtime)).first.flatMap({ Int($0.value) }) ?? 0
                let md5 = attachment.fields.filter(.key(FieldKeys.Item.Attachment.md5)).first?.value ?? ""

                var parameters: [[String: Any]] = []
                if let updateParameters = item.updateParameters {
                    parameters.append(updateParameters)
                }
                if let updateParameters = attachment.updateParameters {
                    parameters.append(updateParameters)
                }

                subscriber(.success((parameters, md5, mtime)))
            } catch let error {
                subscriber(.error(error))
            }

            return Disposables.create()
        }
    }

    /// Creates `RItem` instance in DB from parsed attachement.
    /// - parameter attachment: Parsed attachment to be created.
    /// - parameter collections: Set of collections to which the attachment is assigned.
    /// - returns: `Single` with `updateParameters` of both new items, md5 and mtime of attachment.
    private func create(attachment: Attachment, collections: Set<String>) -> Single<([String: Any], String, Int)> {
        return Single.create { subscriber -> Disposable in
            let localizedType = self.schemaController.localized(itemType: ItemTypes.attachment) ?? ""
            let request = CreateAttachmentDbRequest(attachment: attachment, localizedType: localizedType, collections: collections)

            do {
                let attachment = try self.dbStorage.createCoordinator().perform(request: request)
                let mtime = attachment.fields.filter(.key(FieldKeys.Item.Attachment.mtime)).first.flatMap({ Int($0.value) }) ?? 0
                let md5 = attachment.fields.filter(.key(FieldKeys.Item.Attachment.md5)).first?.value ?? ""

                subscriber(.success((attachment.updateParameters ?? [:], md5, mtime)))
            } catch let error {
                subscriber(.error(error))
            }

            return Disposables.create()
        }
    }

    // MARK: - Collection picker

    func set(collection: Collection, library: Library) {
        self.state.collectionPicker = .picked(library, (collection.type.isCustom ? nil : collection))
    }

    // MARK: - Sync

    private func setupSyncObserving() {
        self.syncController.observable
                           .observeOn(MainScheduler.instance)
                           .subscribe(onNext: { [weak self] data in
                               self?.finishSync(successful: (data == nil))
                           }, onError: { [weak self] _ in
                               self?.finishSync(successful: false)
                           })
                           .disposed(by: self.disposeBag)
    }

    private func finishSync(successful: Bool) {
        if successful {
            self.state.collectionPicker = .picked(Library(identifier: ExtensionStore.defaultLibraryId,
                                                               name: RCustomLibraryType.myLibrary.libraryName,
                                                               metadataEditable: true,
                                                               filesEditable: true),
                                                       nil)
        } else {
            self.state.collectionPicker = .failed
        }
    }
}
