//
//  File.swift
//  Zotero
//
//  Created by Michal Rentka on 21/11/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation
import MobileCoreServices

protocol File {
    var rootPath: String { get }
    var relativeComponents: [String] { get }
    var name: String { get }
    var ext: String { get }
    var mimeType: String { get }
    var isDirectory: Bool { get }
    var directory: File { get }

    func createUrl() -> URL
    func createRelativeUrl() -> URL
}

extension File {
    var isDirectory: Bool {
        return self.name.isEmpty && self.ext.isEmpty && self.mimeType.isEmpty
    }

    func createUrl() -> URL {
        if self.isDirectory {
            return self.createRelativeUrl()
        }
        return self.createRelativeUrl().appendingPathComponent(self.name).appendingPathExtension(self.ext)
    }

    func createRelativeUrl() -> URL {
        var url = URL(fileURLWithPath: self.rootPath)
        self.relativeComponents.forEach { component in
            url = url.appendingPathComponent(component)
        }
        return url
    }

    var directory: File {
        if self.isDirectory {
            return self
        }
        return FileData.directory(rootPath: self.rootPath, relativeComponents: self.relativeComponents)
    }
}

struct FileData: File {
    enum ContentType {
        case contentType(String)
        case ext(String)
        case directory
    }

    let rootPath: String
    let relativeComponents: [String]
    let name: String
    let ext: String
    let mimeType: String

    init(rootPath: String, relativeComponents: [String], name: String, type: ContentType) {
        self.rootPath = rootPath
        self.relativeComponents = relativeComponents
        self.name = name

        switch type {
        case .contentType(let contentType):
            self.mimeType = contentType
            self.ext = FileData.ext(from: contentType)
        case .ext(let ext):
            self.mimeType = FileData.mimeType(from: ext)
            self.ext = ext
        case .directory:
            self.mimeType = ""
            self.ext = ""
        }
    }

    init(rootPath: String, relativeComponents: [String], name: String, ext: String) {
        self.init(rootPath: rootPath, relativeComponents: relativeComponents, name: name, type: .ext(ext))
    }

    init(rootPath: String, relativeComponents: [String], name: String, contentType: String) {
        self.init(rootPath: rootPath, relativeComponents: relativeComponents, name: name, type: .contentType(contentType))
    }

    static func directory(rootPath: String, relativeComponents: [String]) -> FileData {
        return FileData(rootPath: rootPath, relativeComponents: relativeComponents, name: "", type: .directory)
    }

    private static func mimeType(from ext: String) -> String {
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as NSString, nil)?.takeRetainedValue() {
            if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                return mimetype as String
            }
        }
        return "application/octet-stream"
    }

    private static func ext(from mimeType: String) -> String {
        guard let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType as CFString, nil),
              let ext = UTTypeCopyPreferredTagWithClass(uti.takeRetainedValue(), kUTTagClassFilenameExtension) else{
            return ""
        }
        return ext.takeRetainedValue() as String
    }
}
