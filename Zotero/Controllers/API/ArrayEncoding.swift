//
//  ArrayEncoding.swift
//  Zotero
//
//  Created by Michal Rentka on 11/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import Alamofire
import CocoaLumberjackSwift

enum ArrayEncodingError: Error {
    case cantCreateOutputStream
    case cantCreateInputStream
}

/// Extenstion that allows an array be sent as a request parameters
extension Array {
    /// Convert the receiver array to a `Parameters` object.
    func asParameters() -> Parameters {
        return [ArrayEncoding.arrayParametersKey: self]
    }
}

/// Convert the parameters into a json array, and it is added as the request body.
/// The array must be sent as parameters using its `asParameters` method.
struct ArrayEncoding: ParameterEncoding {
    static let arrayParametersKey = "arrayParametersKey"

    /// The options for writing the parameters as JSON data.
    public let options: JSONSerialization.WritingOptions

    /// Creates a new instance of the encoding using the given options
    ///
    /// - parameter options: The options used to encode the json. Default is `[]`
    ///
    /// - returns: The new instance
    public init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    public func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        guard JSONSerialization.isValidJSONObject(parameters) else {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: JSONEncoding.Error.invalidJSONObject))
        }

        guard let array = parameters[ArrayEncoding.arrayParametersKey] else { return urlRequest }

        let tmpPath = NSTemporaryDirectory() + UUID().uuidString + ".json"

        guard let outputStream = OutputStream(toFileAtPath: tmpPath, append: false) else {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: ArrayEncodingError.cantCreateOutputStream))
        }

        outputStream.open()

        var error: NSError?
        JSONSerialization.writeJSONObject(array, to: outputStream, options: self.options, error: &error)

        outputStream.close()

        if let error = error {
            DDLogError("ArrayEncoding: serialization error - \(error)")
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: error))
        }

        guard let inputStream = InputStream(fileAtPath: tmpPath) else {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: ArrayEncodingError.cantCreateInputStream))
        }

        if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        urlRequest.httpBodyStream = inputStream

        return urlRequest
    }
}
