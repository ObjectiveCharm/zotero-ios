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
        case local, remote, remoteMissing
    }

    enum FileLinkType {
        case imported, linked, embeddedImage
    }

    enum ContentType: Equatable {
        case file(file: File, filename: String, location: FileLocation?, linkType: FileLinkType)
        case snapshot(htmlFile: File, filename: String, zipFile: File, location: FileLocation?)
        case url(URL)

        var fileLocation: FileLocation? {
            switch self {
            case .file(_, _, let location, let linkType):
                return linkType == .imported ? location : nil
            case .snapshot(_, _, _, let location):
                return location
            default:
                return nil
            }
        }

        static func == (lhs: ContentType, rhs: ContentType) -> Bool {
            switch (lhs, rhs) {
            case (.url(let lUrl), .url(let rUrl)):
                return lUrl == rUrl
            case (.file(let lFile, _, _, _), .file(let rFile, _, _, _)):
                return lFile.createUrl() == rFile.createUrl()
            case (.snapshot(let lHtmlFile, _, _, _), .snapshot(let rHthmlFile, _, _, _)):
                return lHtmlFile.createUrl() == rHthmlFile.createUrl()
            default:
                return false
            }
        }
    }

    enum NewFileLinkType {
        case importedUrl, importedFile, embeddedImage, linkedFile
    }

    enum Kind: Equatable {
        case file(filename: String, contentType: String, location: FileLocation, linkType: NewFileLinkType)
        case url(URL)
    }

    let key: String
    let title: String
    let contentType: ContentType
    let type: Kind
    let libraryId: LibraryIdentifier

    var id: String { return self.key }

    init(key: String, title: String, type: ContentType, type2: Kind, libraryId: LibraryIdentifier) {
        self.key = key
        self.title = title
        self.contentType = type
        self.libraryId = libraryId
        self.type = type2
    }

    init?(item: RItem, type: ContentType, type2: Kind) {
        guard let libraryId = item.libraryId else {
            DDLogError("Attachment: library not assigned to item (\(item.key))")
            return nil
        }

        self.libraryId = libraryId
        self.key = item.key
        self.title = item.displayTitle
        self.contentType = type
        self.type = type2
    }

    func changed(location: FileLocation?) -> Attachment {
        switch self.contentType {
        case .url: return self
        case .file(let file, let filename, _, let linkType):
            return Attachment(key: self.key,
                              title: self.title,
                              type: .file(file: file, filename: filename, location: location, linkType: linkType),
                              type2: self.type,
                              libraryId: self.libraryId)
        case .snapshot(let htmlFile, let filename, let zipFile, _):
                return Attachment(key: self.key,
                                  title: self.title,
                                  type: .snapshot(htmlFile: htmlFile, filename: filename, zipFile: zipFile, location: location),
                                  type2: self.type,
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
