//
//  TagPickerView.swift
//  Zotero
//
//  Created by Michal Rentka on 09/09/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct TagPickerView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: ViewModel<TagPickerActionHandler>

    let saveAction: ([Tag]) -> Void
    let dismiss: () -> Void

    var body: some View {
        List(selection: self.viewModel.binding(keyPath: \.selectedTags, action: { .setSelected($0) })) {
            SearchBar(text: self.viewModel.binding(keyPath: \.searchTerm, action: { .search($0) }), placeholder: L10n.ItemDetail.searchTags)
            ForEach(self.viewModel.state.tags) { tag in
                TagView(name: tag.name, hex: tag.color, scheme: self.colorScheme)
            }
        }
        .navigationBarItems(leading: self.leadingBarItems, trailing: self.trailingBarItems)
        .environment(\.editMode, .constant(.active))
        .onAppear(perform: {
            self.viewModel.process(action: .load)
        })
    }

    private var leadingBarItems: some View {
        return Button(action: self.dismiss) {
            return Text(L10n.cancel)
        }
    }

    private var trailingBarItems: some View {
        return Button(action: {
            let tags = self.viewModel.state.selectedTags.compactMap { id in
                self.viewModel.state.tags.first(where: { $0.id == id })
            }.sorted(by: { $0.name < $1.name })
            self.saveAction(tags)
            self.dismiss()
        }) {
            return Text(L10n.save)
        }
    }
}

struct TagPickerView_Previews: PreviewProvider {
    static var previews: some View {
        let state = TagPickerState(libraryId: .custom(.myLibrary), selectedTags: [])
        let handler = TagPickerActionHandler(dbStorage: Controllers().userControllers!.dbStorage)
        return TagPickerView(saveAction: { _ in }, dismiss: {})
                        .environmentObject(ViewModel(initialState: state, handler: handler))
    }
}
