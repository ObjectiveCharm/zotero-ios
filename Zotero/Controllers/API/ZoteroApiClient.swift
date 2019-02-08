//
//  ZoteroApiClient.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import Alamofire
import RxAlamofire
import RxSwift

struct ApiConstants {
    static var baseUrlString: String = "https://api.zotero.org/"
    static var version: Int = 3
}

enum ZoteroApiError: Error {
    case unknown
    case expired
    case jsonDecoding(Error)
}

class ZoteroApiClient: ApiClient {
    private let url: URL
    private let defaultHeaders: [String: String]
    private let manager: SessionManager

    private var token: String?

    init(baseUrl: String, headers: [String: String]? = nil) {
        guard let url = URL(string: baseUrl) else {
            fatalError("Incorrect base url provided for ZoteroApiClient")
        }

        self.url = url

        var allHeaders = SessionManager.defaultHTTPHeaders
        if let headers = headers {
            headers.forEach { data in
                allHeaders[data.key] = data.value
            }
        }
        self.defaultHeaders = allHeaders
        self.manager = SessionManager()
    }

    func set(authToken: String?) {
        self.token = authToken
    }

    func send<Request: ApiResponseRequest>(request: Request,
                                           completion: @escaping RequestCompletion<(Request.Response, ResponseHeaders)>) {
        let convertible = Convertible(request: request, baseUrl: self.url,
                                      token: self.token, headers: self.defaultHeaders)
        self.manager.request(convertible).validate().responseData { response in
            if let error = response.error {
                completion(.failure(error))
                return
            }

            if let data = response.data {
                do {
                    let decodedResponse = try JSONDecoder().decode(Request.Response.self, from: data)
                    let headers = response.response?.allHeaderFields ?? [:]
                    completion(.success((decodedResponse, headers)))
                } catch let error {
                    completion(.failure(ZoteroApiError.jsonDecoding(error)))
                }

                return
            }

            completion(.failure(ZoteroApiError.unknown))
        }
    }

    func send<Request: ApiResponseRequest>(request: Request) -> Single<(Request.Response, ResponseHeaders)> {
        let convertible = Convertible(request: request, baseUrl: self.url,
                                      token: self.token, headers: self.defaultHeaders)
        return self.manager.rx.request(urlRequest: convertible)
                              .validate()
                              .responseData()
                              .flatMap { response -> Observable<(Request.Response, ResponseHeaders)> in
                                  do {
                                      let decodedResponse = try JSONDecoder().decode(Request.Response.self,
                                                                                     from: response.1)
                                      return Observable.just((decodedResponse, response.0.allHeaderFields))
                                  } catch let error {
                                      return Observable.error(error)
                                  }
                              }
                              .asSingle()
    }

    func send(dataRequest: ApiRequest) -> Single<(Data, [AnyHashable : Any])> {
        let convertible = Convertible(request: dataRequest, baseUrl: self.url,
                                      token: self.token, headers: self.defaultHeaders)
        return self.manager.rx.request(urlRequest: convertible)
                                .validate()
                                .responseData()
                                .flatMap { response -> Observable<(Data, [AnyHashable : Any])> in
                                    return Observable.just((response.1, response.0.allHeaderFields))
                                }
                                .asSingle()
    }
}

fileprivate struct Convertible {
    private let url: URL
    private let token: String?
    private let httpMethod: ApiHttpMethod
    private let encoding: ParameterEncoding
    private let parameters: [String: Any]?
    private let headers: [String: String]

    init(request: ApiRequest, baseUrl: URL, token: String?, headers: [String: String]) {
        self.url = baseUrl.appendingPathComponent(request.path)
        self.token = token
        self.httpMethod = request.httpMethod
        self.encoding = request.encoding.alamoEncoding
        self.parameters = request.parameters
        self.headers = headers
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

extension ApiParameterEncoding {
    fileprivate var alamoEncoding: ParameterEncoding {
        switch self {
        case .json:
            return JSONEncoding()
        case .url:
            return URLEncoding()
        }
    }
}
