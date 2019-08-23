//
//  CollectionsView.swift
//  Zotero
//
//  Created by Michal Rentka on 20/08/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

import RealmSwift

struct CollectionsView: View {
    @ObservedObject private(set) var store: NewCollectionsStore

    var body: some View {
        List {
            ForEach(self.store.state.cellData) { cell in
                CollectionRow(data: cell)
                    .deleteDisabled(cell.type.isCustom)
            }
            .onDelete(perform: self.delete)
        }
        .onAppear {
            self.store.handle(action: .load)
        }
    }
    
    private func delete(at offsets: IndexSet) {
        self.store.handle(action: .deleteCells(offsets))
    }
}

#if DEBUG

struct CollectionsView_Previews: PreviewProvider {
    static var previews: some View {
        let config = Realm.Configuration(inMemoryIdentifier: "swiftui")
        let state = NewCollectionsStore.StoreState(libraryId: .custom(.myLibrary), title: "Test", metadataEditable: true, filesEditable: true)
        let store = NewCollectionsStore(initialState: state,
                                        dbStorage: RealmDbStorage(config: config))
        return CollectionsView(store: store)
    }
}

#endif
