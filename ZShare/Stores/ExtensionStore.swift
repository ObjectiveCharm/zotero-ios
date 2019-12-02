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

import RxSwift
import RxAlamofire

class ExtensionStore {
    struct State {
        enum PickerState {
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

        enum DownloadState {
            case loadingMetadata
            case progress(Float)
            case failed(DownloadError)
        }

        enum UploadState {
            case preparing
            case ready
            case error(UploadError)
        }

        let key: String
        var pickerState: PickerState
        var downloadState: DownloadState?
        var uploadState: UploadState?

        init() {
            self.key = KeyGenerator.newKey
            self.pickerState = .loading
            self.downloadState = .loadingMetadata
        }
    }

    enum DownloadError: Swift.Error {
        case cantLoadWebData, downloadFailed, expired, unknown
    }

    enum UploadError: Swift.Error {
        case expired, fileMissing, unknown
    }

    @Published var state: State

    private static let defaultLibraryId: LibraryIdentifier = .custom(.myLibrary)
    private static let defaultExtension = "pdf"

    private let syncController: SyncController
    private let apiClient: ApiClient
    private let backgroundApiClient: ApiClient
    private let dbStorage: DbStorage
    private let fileStorage: FileStorage
    private let schemaController: SchemaController
    private let disposeBag: DisposeBag

    init(apiClient: ApiClient, backgroundApiClient: ApiClient, dbStorage: DbStorage,
         schemaController: SchemaController, fileStorage: FileStorage, syncController: SyncController) {
        self.syncController = syncController
        self.apiClient = apiClient
        self.backgroundApiClient = backgroundApiClient
        self.dbStorage = dbStorage
        self.fileStorage = fileStorage
        self.schemaController = schemaController
        self.state = State()
        self.disposeBag = DisposeBag()

        self.syncController.observable
                           .observeOn(MainScheduler.instance)
                           .subscribe(onNext: { [weak self] data in
                               self?.finishSync(successful: (data == nil))
                           }, onError: { [weak self] _ in
                               self?.finishSync(successful: false)
                           })
                           .disposed(by: self.disposeBag)
    }

    func upload() {
        let key = self.state.key
        let libraryId = self.state.pickerState.library?.identifier ?? ExtensionStore.defaultLibraryId
        let userId = Defaults.shared.userId
        let file = Files.objectFile(for: .item, libraryId: libraryId, key: self.state.key, ext: ExtensionStore.defaultExtension)

        self.prepareUpload(key: key, libraryId: libraryId, userId: userId, file: file)
            .subscribe(onSuccess: { [weak self] response in
                guard let `self` = self else { return }

                switch response {
                case .exists:
                    self.state.uploadState = .ready

                case .new(let response):
                    self.startBackgroundUpload(to: response.url, params: response.params, uploadKey: response.uploadKey)
                    self.state.uploadState = .ready
                }
            }, onError: { error in
                let error = (error as? UploadError) ?? .unknown
                self.state.uploadState = .error(error)
            })
            .disposed(by: self.disposeBag)
    }

    private func startBackgroundUpload(to url: URL, params: [String: String], uploadKey: String) {

    }

    private func prepareUpload(key: String, libraryId: LibraryIdentifier, userId: Int, file: File) -> Single<AuthorizeUploadResponse> {
        return self.moveTmpFile(with: key, to: file, libraryId: libraryId)
                    .flatMap { [weak self] filesize -> Single<(UInt64, RItem)> in
                        guard let `self` = self else { return Single.error(UploadError.expired) }
                        return self.createAttachment(for: file, key: key, libraryId: libraryId).flatMap({ Single.just((filesize, $0)) })
                    }
                    .flatMap { [weak self] filesize, item -> Single<(UInt64, RItem)> in
                        guard let `self` = self else { return Single.error(UploadError.expired) }
                        let request = CreateItemRequest(libraryId: libraryId, userId: userId, version: 0, parameters: item.updateParameters)
                        return self.apiClient.send(request: request).flatMap({ _ in Single.just((filesize, item)) })
                    }
                    .flatMap { [weak self] filesize, item -> Single<(Data, ResponseHeaders)> in
                        guard let `self` = self else { return Single.error(UploadError.expired) }
                        let request = self.createAuthorizeRequest(from: item, libraryId: libraryId, userId: userId, filesize: filesize)
                        return self.apiClient.send(request: request)
                    }
                    .flatMap { data, _ -> Single<AuthorizeUploadResponse> in
                       do {
                           let jsonObject = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
                           let response = try AuthorizeUploadResponse(from: jsonObject)
                           return Single.just(response)
                       } catch {
                           return Single.error(error)
                       }
                    }
    }

    private func createAuthorizeRequest(from item: RItem, libraryId: LibraryIdentifier, userId: Int, filesize: UInt64) -> AuthorizeUploadRequest {
        let filename = item.fields.filter(.key(FieldKeys.filename)).first?.value ?? ""
        let mtime = item.fields.filter(.key(FieldKeys.mtime)).first.flatMap({ Int($0.value) }) ?? 0
        let md5 = item.fields.filter(.key(FieldKeys.md5)).first?.value ?? ""
        return AuthorizeUploadRequest(libraryId: libraryId, userId: userId, key: item.key,
                                      filename: filename, filesize: filesize,
                                      md5: md5, mtime: mtime)
    }

    private func createAttachment(for file: File, key: String, libraryId: LibraryIdentifier) -> Single<RItem> {
        let attachment = Attachment(key: key,
                                    title: file.name,
                                    type: .file(file: file, filename: file.name, isLocal: true),
                                    libraryId: libraryId)
        let localizedType = self.schemaController.localized(itemType: ItemTypes.attachment) ?? ""
        let request = CreateAttachmentDbRequest(attachment: attachment, localizedType: localizedType, libraryId: libraryId)

        do {
            let item = try self.dbStorage.createCoordinator().perform(request: request)
            return Single.just(item)
        } catch let error {
            return Single.error(error)
        }
    }

    private func moveTmpFile(with key: String, to file: File, libraryId: LibraryIdentifier) -> Single<UInt64> {
        let tmpFile = Files.shareExtensionTmpItem(key: key, ext: ExtensionStore.defaultExtension)

        do {
            let size = self.fileStorage.size(of: tmpFile)
            if size == 0 {
                return Single.error(UploadError.fileMissing)
            }
            try self.fileStorage.move(from: tmpFile, to: file)
            return Single.just(size)
        } catch {
            return Single.error(UploadError.fileMissing)
        }
    }

    func loadCollections() {
        self.syncController.start(type: .normal, libraries: .all)
    }

    private func finishSync(successful: Bool) {
        if successful {
            self.state.pickerState = .picked(Library(identifier: ExtensionStore.defaultLibraryId,
                                                     name: RCustomLibraryType.myLibrary.libraryName,
                                                     metadataEditable: true,
                                                     filesEditable: true),
                                             nil)
        } else {
            self.state.pickerState = .failed
        }
    }

    func loadDocument(with extensionItem: NSExtensionItem) {
        self.loadWebData(extensionItem: extensionItem)
            .flatMap { [weak self] data -> Observable<RxProgress> in
                guard let `self` = self else { return Observable.error(DownloadError.expired) }
                let file = Files.shareExtensionTmpItem(key: self.state.key, ext: ExtensionStore.defaultExtension)
                let request = FileDownloadRequest(url: data.1, downloadUrl: file.createUrl())
                return self.apiClient.download(request: request)
            }
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] progress in
                self?.state.downloadState = .progress(progress.completed)
            }, onError: { [weak self] error in
                self?.state.downloadState = .failed((error as? DownloadError) ?? .unknown)
            }, onCompleted: {
                self.state.downloadState = nil
            })
            .disposed(by: self.disposeBag)
    }

    private func loadWebData(extensionItem: NSExtensionItem) -> Observable<(String, URL)> {
        let propertyList = kUTTypePropertyList as String

        guard let itemProvider = extensionItem.attachments?.first,
              itemProvider.hasItemConformingToTypeIdentifier(propertyList) else {
            return Observable.error(DownloadError.cantLoadWebData)
        }

        return Observable.create { subscriber in
            itemProvider.loadItem(forTypeIdentifier: propertyList, options: nil, completionHandler: { item, error -> Void in
                guard let scriptData = item as? [String: Any],
                      let data = scriptData[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] else {
                    subscriber.onError(DownloadError.cantLoadWebData)
                    return
                }

                let title = (data["title"] as? String) ?? ""
                let url = URL(string: "https://bitcoin.org/bitcoin.pdf")!//(data["url"] as? String) ?? ""

                subscriber.onNext((title, url))
                subscriber.onCompleted()
            })

            return Disposables.create()
        }
    }

    func set(collection: Collection, library: Library) {
        self.state.pickerState = .picked(library, (collection.type.isCustom ? nil : collection))
    }
}
