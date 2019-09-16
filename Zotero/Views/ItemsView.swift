//
//  ItemsView.swift
//  Zotero
//
//  Created by Michal Rentka on 23/08/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

import RealmSwift

struct ItemsView: View {
    @ObservedObject private(set) var store: NewItemsStore

    var body: some View {
        List {
            self.store.state.sections.flatMap {
                ForEach($0, id: \.self) { section in
                    self.store.state.items(for: section).flatMap { section in
                        ItemSectionView(results: section,
                                        libraryId: self.store.state.libraryId)
                    }
                }
            }
        }
    }
}

fileprivate struct ItemSectionView: View {
    let results: Results<RItem>
    let libraryId: LibraryIdentifier

    @Environment(\.dbStorage) private var dbStorage: DbStorage
    @Environment(\.apiClient) private var apiClient: ApiClient
    @Environment(\.schemaController) private var schemaController: SchemaController
    @Environment(\.fileStorage) private var fileStorage: FileStorage

    var body: some View {
        Section {
            ForEach(self.results, id: \.key) { item in
                NavigationLink(destination: ItemDetailView(store: self.detailStore(for: item))) {
                    ItemRow(item: item)
                }
            }
        }
    }

    private func detailStore(for item: RItem) -> ItemDetailStore {
        return ItemDetailStore(type: .preview(item),
                               libraryId: self.libraryId,
                               apiClient: self.apiClient,
                               fileStorage: self.fileStorage,
                               dbStorage: self.dbStorage,
                               schemaController: self.schemaController)
    }
}

#if DEBUG

struct ItemsView_Previews: PreviewProvider {
    static var previews: some View {
        ItemsView(store: NewItemsStore(libraryId: .custom(.myLibrary),
                                       type: .all,
                                       metadataEditable: true,
                                       filesEditable: true,
                                       dbStorage: Controllers().dbStorage))
    }
}

#endif
