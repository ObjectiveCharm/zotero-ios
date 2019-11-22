//
//  ZoteroApiClient.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import Alamofire
import CocoaLumberjack
import RxAlamofire
import RxSwift

struct ApiConstants {
    static let baseUrlString: String = "https://api.zotero.org/"
    static let version: Int = 3
}

enum ZoteroApiError: Error {
    case unknown
    case expired
    case unknownItemType(String)
    case jsonDecoding(Error)
}

class ZoteroApiClient: ApiClient {
    private let url: URL
    private let manager: SessionManager

    private var token: String?

    init(baseUrl: String, headers: [String: String]? = nil) {
        guard let url = URL(string: baseUrl) else {
            fatalError("Incorrect base url provided for ZoteroApiClient")
        }

        self.url = url

        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = headers

        self.manager = SessionManager(configuration: configuration)
    }

    func set(authToken: String?) {
        self.token = authToken
    }

    func send<Request: ApiResponseRequest>(request: Request) -> Single<(Request.Response, ResponseHeaders)> {
        let convertible = Convertible(request: request, baseUrl: self.url, token: self.token)
        return self.manager.rx.request(urlRequest: convertible)
                              .validate()
                              .responseDataWithResponseError()
                              .log(request: request, convertible: convertible)
                              .retryIfNeeded()
                              .flatMap { (response, data) -> Observable<(Request.Response, ResponseHeaders)> in
                                  do {
                                      let decodedResponse = try JSONDecoder().decode(Request.Response.self,
                                                                                     from: data)
                                      return Observable.just((decodedResponse, response.allHeaderFields))
                                  } catch let error {
                                      return Observable.error(error)
                                  }
                              }
                              .asSingle()
    }

    func send(request: ApiRequest) -> Single<(Data, ResponseHeaders)> {
        let convertible = Convertible(request: request, baseUrl: self.url, token: self.token)
        return self.manager.rx.request(urlRequest: convertible)
                              .validate()
                              .responseDataWithResponseError()
                              .log(request: request, convertible: convertible)
                              .retryIfNeeded()
                              .flatMap { (response, data) -> Observable<(Data, [AnyHashable : Any])> in
                                  return Observable.just((data, response.allHeaderFields))
                              }
                              .asSingle()
    }

    func download(request: ApiDownloadRequest) -> Observable<RxProgress> {
        let convertible = Convertible(request: request, baseUrl: self.url, token: self.token)
        return self.manager.rx.download(convertible) { _, _ -> (destinationURL: URL, options: DownloadRequest.DownloadOptions) in
                                  return (request.downloadUrl, [.createIntermediateDirectories, .removePreviousFile])
                              }
                              .flatMap { downloadRequest -> Observable<RxProgress> in
                                  return downloadRequest.rx.progress()
                              }
    }

    func upload(request: ApiRequest, multipartFormData: @escaping (MultipartFormData) -> Void) -> Single<UploadRequest> {
        return Single.create { [weak self] subscriber in
            guard let `self` = self else {
                subscriber(.error(ZoteroApiError.expired))
                return Disposables.create()
            }


            let convertible = Convertible(request: request, baseUrl: self.url, token: self.token)

            let method = HTTPMethod(rawValue: request.httpMethod.rawValue)!
            self.manager.upload(multipartFormData: multipartFormData,
                                to: convertible,
                                method: method,
                                headers: request.headers,
                                encodingCompletion: { result in
                switch result {
                case .success(let request, _, _):
                    subscriber(.success(request))
                case .failure(let error):
                    subscriber(.error(error))
                }
            })

            return Disposables.create()
        }
    }
}

struct Convertible {
    private let url: URL
    private let token: String?
    private let httpMethod: ApiHttpMethod
    private let encoding: ParameterEncoding
    private let parameters: [String: Any]?
    private let headers: [String: String]

    init(request: ApiRequest, baseUrl: URL, token: String?) {
        switch request.endpoint {
        case .zotero(let path):
            self.url = baseUrl.appendingPathComponent(path)
        case .other(let url):
            self.url = url
        }
        self.token = token
        self.httpMethod = request.httpMethod
        self.encoding = request.encoding.alamoEncoding
        self.parameters = request.parameters
        self.headers = request.headers ?? [:]
    }
}

extension Convertible: URLRequestConvertible {
    func asURLRequest() throws -> URLRequest {
        var request = URLRequest(url: self.url)
        request.httpMethod = self.httpMethod.rawValue
        request.allHTTPHeaderFields = self.headers
        if let token = self.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try self.encoding.encode(request as URLRequestConvertible, with: self.parameters)
    }
}

extension Convertible: URLConvertible {
    func asURL() throws -> URL {
        return self.url
    }
}

extension ApiParameterEncoding {
    fileprivate var alamoEncoding: ParameterEncoding {
        switch self {
        case .json:
            return JSONEncoding()
        case .url:
            return URLEncoding()
        case .array:
            return ArrayEncoding()
        }
    }
}
