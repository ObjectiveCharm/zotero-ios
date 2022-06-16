//
//  LookupState.swift
//  Zotero
//
//  Created by Michal Rentka on 17.05.2022.
//  Copyright © 2022 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct LookupState: ViewModelState {
    struct LookupData {
        let response: ItemResponse
        let attachments: [(Attachment, URL)]
    }

    enum State {
        case input
        case loading
        case done([LookupData])
        case failed
    }

    let initialText: String?
    let collectionKeys: Set<String>
    let libraryId: LibraryIdentifier

    var state: State
    var scannedText: String?

    init(initialText: String?, collectionKeys: Set<String>, libraryId: LibraryIdentifier) {
        self.initialText = initialText
        self.collectionKeys = collectionKeys
        self.libraryId = libraryId
        self.state = initialText == nil ? .input : .loading
    }

    mutating func cleanup() {
        self.scannedText = nil
    }
}
