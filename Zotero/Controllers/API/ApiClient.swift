//
//  ApiClient.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import Alamofire
import RxAlamofire
import RxSwift

enum ApiParameterEncoding {
    case json
    case url
    case array
    case jsonAndUrl
}

enum ApiHttpMethod: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

enum ApiEndpoint {
    case zotero(path: String)
    case other(URL)
}

protocol ApiRequest {
    var endpoint: ApiEndpoint { get }
    var httpMethod: ApiHttpMethod { get }
    var parameters: [String: Any]? { get }
    var encoding: ApiParameterEncoding { get }
    var headers: [String: String]? { get }
    var debugUrl: String { get }

    func redact(parameters: [String: Any]) -> [String: Any]
    func redact(response: String) -> String
}

extension ApiRequest {
    func redact(parameters: [String: Any]) -> [String: Any] {
        return parameters
    }

    func redact(response: String) -> String {
        return response
    }

    var debugUrl: String {
        switch self.endpoint {
        case .zotero(let path):
            return ApiConstants.baseUrlString + path
        case .other(let url):
            return url.absoluteString
        }
    }
}

protocol ApiResponseRequest: ApiRequest {
    associatedtype Response: Decodable
}

protocol ApiDownloadRequest: ApiRequest {
    var downloadUrl: URL { get }
}

typealias RequestCompletion<Response> = (Swift.Result<Response, Error>) -> Void
typealias ResponseHeaders = [AnyHashable: Any]

protocol ApiClient: AnyObject {
    func set(authToken: String?)
    func send<Request: ApiResponseRequest>(request: Request) -> Single<(Request.Response, ResponseHeaders)>
    func send<Request: ApiResponseRequest>(request: Request, queue: DispatchQueue) -> Single<(Request.Response, ResponseHeaders)>
    func send(request: ApiRequest) -> Single<(Data, ResponseHeaders)>
    func send(request: ApiRequest, queue: DispatchQueue) -> Single<(Data, ResponseHeaders)>
    func download(request: ApiDownloadRequest) -> Observable<DownloadRequest>
    func upload(request: ApiRequest, multipartFormData: @escaping (MultipartFormData) -> Void) -> Single<UploadRequest>
    func upload(request: ApiRequest, data: Data) -> Single<UploadRequest>
    func operation(from request: ApiRequest, queue: DispatchQueue, completion: @escaping (Swift.Result<(Data, ResponseHeaders), Error>) -> Void) -> ApiOperation
}

protocol ApiRequestCreator: AnyObject {
    func dataRequest(for request: ApiRequest) -> DataRequest
}
