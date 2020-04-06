//
//  SyncActionsSpec.swift
//  ZoteroTests
//
//  Created by Michal Rentka on 09/07/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

@testable import Zotero

import Alamofire
import CocoaLumberjack
import Nimble
import OHHTTPStubs
import RealmSwift
import RxSwift
import Quick

class SyncActionsSpec: QuickSpec {
    private static let userId = 100
    private static let apiClient = ZoteroApiClient(baseUrl: ApiConstants.baseUrlString, configuration: URLSessionConfiguration.default)
    private static let fileStorage = FileStorageController()
    private static let schemaController = SchemaController()
    private static let realmConfig = Realm.Configuration(inMemoryIdentifier: "TestsRealmConfig")
    // We need to retain realm with memory identifier so that data are not deleted
    private static let realm = try! Realm(configuration: realmConfig)
    private static let dbStorage = RealmDbStorage(config: realmConfig)
    private static let disposeBag = DisposeBag()

    override func spec() {
        beforeEach {
            let url = URL(fileURLWithPath: Files.documentsRootPath).appendingPathComponent("downloads")
            try? FileManager.default.removeItem(at: url)

            OHHTTPStubs.removeAllStubs()

            let realm = SyncActionsSpec.realm
            try! realm.write {
                realm.deleteAll()
            }
        }

        describe("conflict resolution") {
            it("reverts group changes") {
                // Load urls for bundled files
                guard let collectionUrl = Bundle(for: type(of: self)).url(forResource: "test_collection", withExtension: "json"),
                      let itemUrl = Bundle(for: type(of: self)).url(forResource: "test_item", withExtension: "json"),
                      let searchUrl = Bundle(for: type(of: self)).url(forResource: "test_search", withExtension: "json") else {
                    fail("Could not find json files")
                    return
                }

                // Load their data
                let collectionData = try! Data(contentsOf: collectionUrl)
                let searchData = try! Data(contentsOf: searchUrl)
                let itemData = try! Data(contentsOf: itemUrl)

                guard let itemJson = try! JSONSerialization.jsonObject(with: itemData, options: .allowFragments) as? [String: Any] else {
                    fail("Item json is not a dictionary")
                    return
                }

                // Write original json files to directory folder for SyncActionHandler to use when reverting
                let collectionFile = Files.objectFile(for: .collection, libraryId: .group(1234123), key: "BBBBBBBB", ext: "json")
                try! FileManager.default.createMissingDirectories(for: collectionFile.createUrl().deletingLastPathComponent())
                try! collectionData.write(to: collectionFile.createUrl())
                let searchFile = Files.objectFile(for: .search, libraryId: .custom(.myLibrary), key: "CCCCCCCC", ext: "json")
                try! searchData.write(to: searchFile.createUrl())
                let itemFile = Files.objectFile(for: .item, libraryId: .custom(.myLibrary), key: "AAAAAAAA", ext: "json")
                try! itemData.write(to: itemFile.createUrl())

                // Create response models
                let collectionResponse = try! JSONDecoder().decode(CollectionResponse.self, from: collectionData)
                let searchResponse = try! JSONDecoder().decode(SearchResponse.self, from: searchData)
                let itemResponse = try! ItemResponse(response: itemJson, schemaController: SyncActionsSpec.schemaController)

                let coordinator = try! SyncActionsSpec.dbStorage.createCoordinator()
                // Store original objects to db
                _ = try! coordinator.perform(request: StoreItemsDbRequest(response: [itemResponse],
                                                                          schemaController: SyncActionsSpec.schemaController,
                                                                          preferRemoteData: false))
                try! coordinator.perform(request: StoreCollectionsDbRequest(response: [collectionResponse]))
                try! coordinator.perform(request: StoreSearchesDbRequest(response: [searchResponse]))

                // Change some objects so that they are updated locally
                try! coordinator.perform(request: StoreCollectionDbRequest(libraryId: .group(1234123), key: "BBBBBBBB",
                                                                           name: "New name", parentKey: nil))
                let changeRequest = StoreItemDetailChangesDbRequest(libraryId: .custom(.myLibrary),
                                                                    itemKey: "AAAAAAAA",
                                                                    data: .init(title: "New title",
                                                                                type: "magazineArticle",
                                                                                localizedType: "Magazine Article",
                                                                                creators: [:],
                                                                                creatorIds: [],
                                                                                fields: [:],
                                                                                fieldIds: [],
                                                                                abstract: "New abstract",
                                                                                notes: [],
                                                                                attachments: [],
                                                                                tags: [],
                                                                                dateModified: Date(),
                                                                                dateAdded: Date()),
                                                                    snapshot: .init(title: "Bachelor thesis",
                                                                                    type: "thesis",
                                                                                    localizedType: "Thesis",
                                                                                    creators: [:],
                                                                                    creatorIds: [],
                                                                                    fields: [:],
                                                                                    fieldIds: [],
                                                                                    abstract: "Some note",
                                                                                    notes: [],
                                                                                    attachments: [],
                                                                                    tags: [],
                                                                                    dateModified: Date(),
                                                                                    dateAdded: Date()),
                                                                    schemaController: SyncActionsSpec.schemaController)
                try! coordinator.perform(request: changeRequest)

                let realm = SyncActionsSpec.realm
                realm.refresh()

                let item = realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                expect(item?.rawType).to(equal("magazineArticle"))
                expect(item?.baseTitle).to(equal("New title"))
                expect(item?.fields.filter("key =  %@", FieldKeys.abstract).first?.value).to(equal("New abstract"))
                expect(item?.isChanged).to(beTrue())

                let collection = realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                expect(collection?.name).to(equal("New name"))
                expect(collection?.parent).to(beNil())

                waitUntil(timeout: 10, action: { doneAction in
                    RevertLibraryUpdatesSyncAction(libraryId: .custom(.myLibrary),
                                                   dbStorage: SyncActionsSpec.dbStorage,
                                                   fileStorage: SyncActionsSpec.fileStorage,
                                                   schemaController: SyncActionsSpec.schemaController).result
                                         .subscribe(onSuccess: { failures in
                                             expect(failures[.item]).to(beEmpty())
                                             expect(failures[.collection]).to(beEmpty())
                                             expect(failures[.search]).to(beEmpty())

                                             let realm = try! Realm(configuration: SyncActionsSpec.realmConfig)
                                             realm.refresh()

                                             let item = realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                                             expect(item?.rawType).to(equal("thesis"))
                                             expect(item?.baseTitle).to(equal("Bachelor thesis"))
                                             expect(item?.fields.filter("key =  %@", FieldKeys.abstract).first?.value).to(equal("Some note"))
                                             expect(item?.rawChangedFields).to(equal(0))

                                             doneAction()
                                         }, onError: { error in
                                             fail("Could not revert user library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })

                waitUntil(timeout: 10, action: { doneAction in
                    RevertLibraryUpdatesSyncAction(libraryId: .group(1234123),
                                                   dbStorage: SyncActionsSpec.dbStorage,
                                                   fileStorage: SyncActionsSpec.fileStorage,
                                                   schemaController: SyncActionsSpec.schemaController).result
                                         .subscribe(onSuccess: { failures in
                                             expect(failures[.item]).to(beEmpty())
                                             expect(failures[.collection]).to(beEmpty())
                                             expect(failures[.search]).to(beEmpty())

                                             let realm = try! Realm(configuration: SyncActionsSpec.realmConfig)
                                             realm.refresh()

                                             let collection = realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                                             expect(collection?.name).to(equal("Bachelor sources"))
                                             expect(collection?.parent).to(beNil())

                                             doneAction()
                                         }, onError: { error in
                                             fail("Could not revert group library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }

            it("marks local changes as synced") {
                // Load urls for bundled files
                guard let collectionUrl = Bundle(for: type(of: self)).url(forResource: "test_collection", withExtension: "json"),
                      let itemUrl = Bundle(for: type(of: self)).url(forResource: "test_item", withExtension: "json") else {
                    fail("Could not find json files")
                    return
                }

                // Load their data
                let collectionData = try! Data(contentsOf: collectionUrl)
                let itemData = try! Data(contentsOf: itemUrl)

                guard let itemJson = try! JSONSerialization.jsonObject(with: itemData, options: .allowFragments) as? [String: Any] else {
                    fail("Item json is not a dictionary")
                    return
                }

                // Create response models
                let collectionResponse = try! JSONDecoder().decode(CollectionResponse.self, from: collectionData)
                let itemResponse = try! ItemResponse(response: itemJson, schemaController: SyncActionsSpec.schemaController)

                let coordinator = try! SyncActionsSpec.dbStorage.createCoordinator()
                // Store original objects to db
                _ = try! coordinator.perform(request: StoreItemsDbRequest(response: [itemResponse],
                                                                          schemaController: SyncActionsSpec.schemaController,
                                                                          preferRemoteData: false))
                try! coordinator.perform(request: StoreCollectionsDbRequest(response: [collectionResponse]))

                // Change some objects so that they are updated locally
                try! coordinator.perform(request: StoreCollectionDbRequest(libraryId: .group(1234123), key: "BBBBBBBB",
                                                                           name: "New name", parentKey: nil))
                let changeRequest = StoreItemDetailChangesDbRequest(libraryId: .custom(.myLibrary),
                                                                    itemKey: "AAAAAAAA",
                                                                    data: .init(title: "New title",
                                                                                type: "magazineArticle",
                                                                                localizedType: "Magazine Article",
                                                                                creators: [:],
                                                                                creatorIds: [],
                                                                                fields: [:],
                                                                                fieldIds: [],
                                                                                abstract: "New abstract",
                                                                                notes: [],
                                                                                attachments: [],
                                                                                tags: [],
                                                                                dateModified: Date(),
                                                                                dateAdded: Date()),
                                                                    snapshot: .init(title: "Title",
                                                                                    type: "thesis",
                                                                                    localizedType: "Thesis",
                                                                                    creators: [:],
                                                                                    creatorIds: [],
                                                                                    fields: [:],
                                                                                    fieldIds: [],
                                                                                    abstract: "Some note",
                                                                                    notes: [],
                                                                                    attachments: [],
                                                                                    tags: [],
                                                                                    dateModified: Date(),
                                                                                    dateAdded: Date()),
                                                                    schemaController: SyncActionsSpec.schemaController)
                try! coordinator.perform(request: changeRequest)

                let realm = SyncActionsSpec.realm
                realm.refresh()

                let item = realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                expect(item?.rawType).to(equal("magazineArticle"))
                expect(item?.baseTitle).to(equal("New title"))
                expect(item?.fields.filter("key =  %@", FieldKeys.abstract).first?.value).to(equal("New abstract"))
                expect(item?.rawChangedFields).toNot(equal(0))
                expect(item?.isChanged).to(beTrue())

                let collection = realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                expect(collection?.name).to(equal("New name"))
                expect(collection?.parent).to(beNil())
                expect(collection?.rawChangedFields).toNot(equal(0))

                waitUntil(timeout: 10, action: { doneAction in
                    MarkChangesAsResolvedSyncAction(libraryId: .custom(.myLibrary), dbStorage: SyncActionsSpec.dbStorage).result
                                         .subscribe(onSuccess: { _ in
                                             let realm = try! Realm(configuration: SyncActionsSpec.realmConfig)
                                             realm.refresh()

                                             let item = realm.objects(RItem.self).filter(.key("AAAAAAAA")).first
                                             expect(item?.rawType).to(equal("magazineArticle"))
                                             expect(item?.baseTitle).to(equal("New title"))
                                             expect(item?.fields.filter("key =  %@", FieldKeys.abstract).first?.value).to(equal("New abstract"))
                                             expect(item?.rawChangedFields).to(equal(0))

                                             doneAction()
                                        }, onError: { error in
                                            fail("Could not sync user library: \(error)")
                                            doneAction()
                                        })
                                        .disposed(by: SyncActionsSpec.disposeBag)
                })

                waitUntil(timeout: 10, action: { doneAction in
                    MarkChangesAsResolvedSyncAction(libraryId: .group(1234123), dbStorage: SyncActionsSpec.dbStorage).result
                                         .subscribe(onSuccess: { _ in
                                             let realm = try! Realm(configuration: SyncActionsSpec.realmConfig)
                                             realm.refresh()

                                             let collection = realm.objects(RCollection.self).filter(.key("BBBBBBBB")).first
                                             expect(collection?.name).to(equal("New name"))
                                             expect(collection?.parent).to(beNil())
                                             expect(collection?.rawChangedFields).to(equal(0))

                                             doneAction()
                                         }, onError: { error in
                                             fail("Could not sync group library: \(error)")
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }
        }

        describe("attachment upload") {
            let baseUrl = URL(string: ApiConstants.baseUrlString)!

            it("fails when item metadata not submitted") {
                let key = "AAAAAAAA"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: key, ext: "pdf")

                let realm = SyncActionsSpec.realm

                try! realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.group = library
                    item.changedFields = .all
                    item.attachmentNeedsSync = true
                    realm.add(item)
                }

                waitUntil(timeout: 10, action: { doneAction in
                    UploadAttachmentSyncAction(key: key, file: file, filename: "doc.pdf", md5: "aaaaaaaa", mtime: 0, libraryId: libraryId,
                                               userId: SyncActionsSpec.userId,
                                               apiClient: SyncActionsSpec.apiClient,
                                               dbStorage: SyncActionsSpec.dbStorage,
                                               fileStorage: SyncActionsSpec.fileStorage).result
                                         .flatMap({ response, _ -> Single<Never> in
                                             return response.asObservable().asSingle()
                                         })
                                         .subscribe(onSuccess: { test in
                                             fail("Upload didn't fail with unsubmitted item")
                                             doneAction()
                                         }, onError: { error in
                                             if let handlerError = error as? SyncActionError {
                                                 expect(handlerError).to(equal(.attachmentItemNotSubmitted))
                                             } else {
                                                 fail("Unknown error: \(error.localizedDescription)")
                                             }
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }

            it("fails when file is not available") {
                let key = "AAAAAAAA"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: key, ext: "pdf")

                let realm = SyncActionsSpec.realm

                try! realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.group = library
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true
                    realm.add(item)
                }

                waitUntil(timeout: 10, action: { doneAction in
                    UploadAttachmentSyncAction(key: key, file: file, filename: "doc.pdf", md5: "aaaaaaaa", mtime: 0, libraryId: libraryId,
                                               userId: SyncActionsSpec.userId,
                                               apiClient: SyncActionsSpec.apiClient,
                                               dbStorage: SyncActionsSpec.dbStorage,
                                               fileStorage: SyncActionsSpec.fileStorage).result
                                         .flatMap({ response, _ -> Single<Never> in
                                             return response.asObservable().asSingle()
                                         })
                                         .subscribe(onSuccess: { _ in
                                             fail("Upload didn't fail with unsubmitted item")
                                             doneAction()
                                         }, onError: { error in
                                             if let handlerError = error as? SyncActionError {
                                                 expect(handlerError).to(equal(.attachmentMissing))
                                             } else {
                                                 fail("Unknown error: \(error.localizedDescription)")
                                             }
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }

            it("it doesn't reupload when file is already uploaded") {
                let key = "AAAAAAAA"
                let filename = "doc.txt"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: key, ext: "txt")

                let data = "test string".data(using: .utf8)!
                try! FileStorageController().write(data, to: file, options: .atomicWrite)
                let fileMd5 = md5(from: file.createUrl())!

                let realm = SyncActionsSpec.realm

                try! realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.group = library
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true
                    realm.add(item)

                    let contentField = RItemField()
                    contentField.key = FieldKeys.contentType
                    contentField.value = "text/plain"
                    contentField.item = item
                    realm.add(contentField)

                    let filenameField = RItemField()
                    filenameField.key = FieldKeys.filename
                    filenameField.value = filename
                    filenameField.item = item
                    realm.add(filenameField)
                }

                createStub(for: AuthorizeUploadRequest(libraryId: libraryId, userId: SyncActionsSpec.userId, key: key,
                                                       filename: filename, filesize: UInt64(data.count), md5: fileMd5, mtime: 123),
                           baseUrl: baseUrl, jsonResponse: ["exists": 1])

                waitUntil(timeout: 10, action: { doneAction in
                    UploadAttachmentSyncAction(key: key, file: file, filename: filename, md5: fileMd5, mtime: 123, libraryId: libraryId,
                                               userId: SyncActionsSpec.userId,
                                               apiClient: SyncActionsSpec.apiClient,
                                               dbStorage: SyncActionsSpec.dbStorage,
                                               fileStorage: SyncActionsSpec.fileStorage).result
                                         .flatMap({ response, _ -> Single<()> in
                                             return Single.create { subscriber -> Disposable in
                                                response.subscribe(onCompleted: {
                                                            subscriber(.success(()))
                                                        }, onError: { error in
                                                            subscriber(.error(error))
                                                        })
                                                        .disposed(by: SyncActionsSpec.disposeBag)
                                                return Disposables.create()
                                             }
                                         })
                                         .subscribe(onSuccess: { _ in
                                             doneAction()
                                         }, onError: { error in
                                             fail("Unknown error: \(error.localizedDescription)")
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }

            it("uploads new file") {
                let key = "AAAAAAAA"
                let filename = "doc.txt"
                let libraryId = LibraryIdentifier.group(1)
                let file = Files.objectFile(for: .item, libraryId: libraryId, key: key, ext: "txt")

                let data = "test string".data(using: .utf8)!
                try! FileStorageController().write(data, to: file, options: .atomicWrite)
                let fileMd5 = md5(from: file.createUrl())!

                let realm = SyncActionsSpec.realm

                try! realm.write {
                    let library = RGroup()
                    library.identifier = 1
                    realm.add(library)

                    let item = RItem()
                    item.key = key
                    item.rawType = "attachment"
                    item.group = library
                    item.rawChangedFields = 0
                    item.attachmentNeedsSync = true
                    realm.add(item)

                    let contentField = RItemField()
                    contentField.key = FieldKeys.contentType
                    contentField.value = "text/plain"
                    contentField.item = item
                    realm.add(contentField)

                    let filenameField = RItemField()
                    filenameField.key = FieldKeys.filename
                    filenameField.value = filename
                    filenameField.item = item
                    realm.add(filenameField)
                }

                createStub(for: AuthorizeUploadRequest(libraryId: libraryId, userId: SyncActionsSpec.userId, key: key,
                                                       filename: filename, filesize: UInt64(data.count), md5: fileMd5, mtime: 123),
                           baseUrl: baseUrl, jsonResponse: ["url": "https://www.zotero.org/",
                                                        "uploadKey": "key",
                                                        "params": ["key": "key"]])
                createStub(for: RegisterUploadRequest(libraryId: libraryId, userId: SyncActionsSpec.userId, key: key, uploadKey: "key"),
                           baseUrl: baseUrl, headers: nil, statusCode: 204, jsonResponse: [:])
                stub(condition: { request -> Bool in
                    return request.url?.absoluteString == "https://www.zotero.org/"
                }, response: { _ -> OHHTTPStubsResponse in
                    return OHHTTPStubsResponse(jsonObject: [:], statusCode: 201, headers: nil)
                })

                waitUntil(timeout: 10, action: { doneAction in
                    UploadAttachmentSyncAction(key: key, file: file, filename: filename, md5: fileMd5, mtime: 123, libraryId: libraryId,
                                               userId: SyncActionsSpec.userId,
                                               apiClient: SyncActionsSpec.apiClient,
                                               dbStorage: SyncActionsSpec.dbStorage,
                                               fileStorage: SyncActionsSpec.fileStorage).result
                                         .flatMap({ response, _ -> Single<()> in
                                             return Single.create { subscriber -> Disposable in
                                                response.subscribe(onCompleted: {
                                                            subscriber(.success(()))
                                                        }, onError: { error in
                                                            subscriber(.error(error))
                                                        })
                                                        .disposed(by: SyncActionsSpec.disposeBag)
                                                return Disposables.create()
                                             }
                                         })
                                         .subscribe(onSuccess: { _ in
                                             let realm = try! Realm(configuration: SyncActionsSpec.realmConfig)
                                             realm.refresh()

                                             let item = realm.objects(RItem.self).filter(.key(key)).first
                                             expect(item?.attachmentNeedsSync).to(beFalse())

                                             doneAction()
                                         }, onError: { error in
                                             fail("Unknown error: \(error.localizedDescription)")
                                             doneAction()
                                         })
                                         .disposed(by: SyncActionsSpec.disposeBag)
                })
            }
        }
    }
}
