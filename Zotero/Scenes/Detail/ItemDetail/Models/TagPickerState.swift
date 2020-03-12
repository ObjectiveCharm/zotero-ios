//
//  TagPickerState.swift
//  Zotero
//
//  Created by Michal Rentka on 28/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct TagPickerState: ViewModelState {
    let libraryId: LibraryIdentifier
    var tags: [Tag]
    var selectedTags: Set<String>
    var error: TagPickerError?

    init(libraryId: LibraryIdentifier, selectedTags: Set<String>) {
        self.libraryId = libraryId
        self.tags = []
        self.selectedTags = selectedTags
    }

    func cleanup() {}
}
