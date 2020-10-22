//
//  Attachment.swift
//  Zotero
//
//  Created by Michal Rentka on 02/12/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift

struct Attachment: Identifiable, Equatable {
    enum FileLocation {
        case local, remote
    }

    enum ContentType: Equatable {
        case file(file: File, filename: String, location: FileLocation?)
        case snapshot(htmlFile: File, filename: String, zipFile: File, location: FileLocation?)
        case url(URL)

        var fileContentType: String? {
            switch self {
            case .file(let file, _, _),
                 .snapshot(let file, _, _, _):
                return file.mimeType
            case .url: return nil
            }
        }

        var fileLocation: FileLocation? {
            switch self {
            case .file(_, _, let location),
                 .snapshot(_, _, _, let location):
                return location
            default:
                return nil
            }
        }

        static func == (lhs: ContentType, rhs: ContentType) -> Bool {
            switch (lhs, rhs) {
            case (.url(let lUrl), .url(let rUrl)):
                return lUrl == rUrl
            case (.file(let lFile, _, _), .file(let rFile, _, _)):
                return lFile.createUrl() == rFile.createUrl()
            default:
                return false
            }
        }
    }

    let key: String
    let title: String
    let contentType: ContentType
    let libraryId: LibraryIdentifier

    var id: String { return self.key }

    init(key: String, title: String, type: ContentType, libraryId: LibraryIdentifier) {
        self.key = key
        self.title = title
        self.contentType = type
        self.libraryId = libraryId
    }

    init?(item: RItem, type: ContentType) {
        guard let libraryId = item.libraryId else {
            DDLogError("Attachment: library not assigned to item (\(item.key))")
            return nil
        }

        self.libraryId = libraryId
        self.key = item.key
        self.title = item.displayTitle
        self.contentType = type
    }

    func changed(location: FileLocation?) -> Attachment {
        switch self.contentType {
        case .url: return self
        case .file(let file, let filename, _):
            return Attachment(key: self.key,
                              title: self.title,
                              type: .file(file: file, filename: filename, location: location),
                              libraryId: self.libraryId)
        case .snapshot(let htmlFile, let filename, let zipFile, _):
                return Attachment(key: self.key,
                                  title: self.title,
                                  type: .snapshot(htmlFile: htmlFile, filename: filename, zipFile: zipFile, location: location),
                                  libraryId: self.libraryId)
        }
    }
}

extension Attachment: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.key)
        hasher.combine(self.title)
    }
}
