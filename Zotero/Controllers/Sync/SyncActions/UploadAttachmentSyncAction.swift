//
//  UploadAttachmentSyncAction.swift
//  Zotero
//
//  Created by Michal Rentka on 30/01/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import Alamofire
import CocoaLumberjackSwift
import RxAlamofire
import RxSwift

struct UploadAttachmentSyncAction: SyncAction {
    typealias Result = (Completable, Observable<RxProgress>) // Upload completion, Upload progress

    let key: String
    let file: File
    let filename: String
    let md5: String
    let mtime: Int
    let libraryId: LibraryIdentifier
    let userId: Int
    let oldMd5: String?

    unowned let apiClient: ApiClient
    unowned let dbStorage: DbStorage
    unowned let fileStorage: FileStorage
    let queue: DispatchQueue
    let scheduler: SchedulerType

    var result: Single<(Completable, Observable<RxProgress>)> {
        let dbCheck: Single<()> = Single.create { subscriber -> Disposable in
            do {
                let request = CheckItemIsChangedDbRequest(libraryId: self.libraryId, key: self.key)
                let isChanged = try self.dbStorage.createCoordinator().perform(request: request)
                if !isChanged {
                    subscriber(.success(()))
                } else {
                    DDLogError("UploadAttachmentSyncAction: attachment item not submitted")
                    subscriber(.failure(SyncActionError.attachmentItemNotSubmitted))
                }
            } catch let error {
                subscriber(.failure(error))
            }

            return Disposables.create()
        }

        let upload = dbCheck.flatMap { _ -> Single<UInt64> in
                                let size = self.fileStorage.size(of: self.file)
                                if size == 0 {
                                    DDLogError("UploadAttachmentSyncAction: missing attachment - \(self.file.createUrl().absoluteString)")
                                    let item = try? self.dbStorage.createCoordinator().perform(request: ReadItemDbRequest(libraryId: self.libraryId, key: self.key))
                                    let title = item?.displayTitle ?? "L10n.notFound"
                                    return Single.error(SyncActionError.attachmentMissing(key: self.key, title: title))
                                } else {
                                    return Single.just(size)
                                }
                            }
                            .flatMap { filesize -> Single<AuthorizeUploadResponse> in
                                return AuthorizeUploadSyncAction(key: self.key, filename: self.filename, filesize: filesize,
                                                                 md5: self.md5, mtime: self.mtime, libraryId: self.libraryId,
                                                                 userId: self.userId, oldMd5: self.oldMd5, apiClient: self.apiClient,
                                                                 queue: self.queue, scheduler: self.scheduler).result
                            }
                            .observe(on: self.scheduler)
                            .flatMap { response -> Single<Swift.Result<(UploadRequest, AttachmentUploadRequest, String), SyncActionError>> in
                                switch response {
                                case .exists:
                                    return Single.just(.failure(SyncActionError.attachmentAlreadyUploaded))
                                case .new(let response):
                                    let request = AttachmentUploadRequest(url: response.url)
                                    return self.apiClient.upload(request: request, multipartFormData: { data in
                                        response.params.forEach({ (key, value) in
                                            if let stringData = value.data(using: .utf8) {
                                                data.append(stringData, withName: key)
                                            }
                                        })
                                        data.append(self.file.createUrl(), withName: "file", fileName: self.filename, mimeType: self.file.mimeType)
                                    })
                                    .flatMap({ Single.just(.success(($0, request, response.uploadKey))) })
                                }
                            }

        let startTime = CFAbsoluteTimeGetCurrent()
        let response = upload.observe(on: self.scheduler)
                             .flatMap({ result -> Single<Swift.Result<String, SyncActionError>> in
                                 switch result {
                                 case .success((let uploadRequest, let apiRequest, let uploadKey)):
                                     let logId = ApiLogger.log(request: apiRequest, url: uploadRequest.request?.url)
                                     return uploadRequest.rx.responseData()
                                                            .log(identifier: logId, startTime: startTime, request: apiRequest)
                                                            .asSingle()
                                                            .flatMap({ response in
                                                                return Single.just(.success(uploadKey))
                                                            })
                                 case .failure(let error):
                                     return Single.just(.failure(error))
                                 }
                             })
                             .flatMap({ result -> Single<Swift.Result<(Data, ResponseHeaders), SyncActionError>> in
                                 switch result {
                                 case .success(let uploadKey):
                                     let request = RegisterUploadRequest(libraryId: self.libraryId,
                                                                         userId: self.userId,
                                                                         key: self.key,
                                                                         uploadKey: uploadKey,
                                                                         oldMd5: self.oldMd5)
                                     return self.apiClient.send(request: request, queue: self.queue).flatMap({ Single.just(.success($0)) })
                                 case .failure(let error):
                                     return Single.just(.failure(error))
                                 }
                             })
                             .observe(on: self.scheduler)
                             .flatMap({ result -> Single<()> in

                                let markDbAction: (Int?) -> Single<()> = { version in
                                     do {
                                         var requests: [DbRequest] = [MarkAttachmentUploadedDbRequest(libraryId: self.libraryId, key: self.key)]
                                         if let version = version {
                                             requests.append(UpdateVersionsDbRequest(version: version, libraryId: self.libraryId, type: .object(.item)))
                                         }
                                         try self.dbStorage.createCoordinator().perform(requests: requests)
                                         return Single.just(())
                                     } catch let error {
                                        DDLogError("UploadAttachmentSyncAction: can't mark attachment as uploaded - \(error)")
                                         return Single.error(error)
                                     }
                                 }

                                 switch result {
                                 case .success((_, let headers)):
                                     return markDbAction(headers.lastModifiedVersion)
                                 case .failure(let error):
                                    switch error {
                                    case .attachmentAlreadyUploaded:
                                        return markDbAction(nil)
                                    default:
                                        return Single.error(error)
                                    }
                                 }
                             })
                             .asCompletable()

        let progress = upload.asObservable()
                             .flatMap({ result -> Observable<RxProgress> in
                                 switch result {
                                 case .success((let uploadRequest, _, _)):
                                     return uploadRequest.rx.progress()
                                 case .failure(let error):
                                     return Observable.error(error)
                                 }
                             })
                             .do(onNext: { progress in
                                DDLogInfo("--- Upload progress: \(progress.completed) ---")
                             })

        return Single.just((response, progress))
    }
}
