//
//  CollectionsPickerView.swift
//  Zotero
//
//  Created by Michal Rentka on 11/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct CollectionsPickerView: View {
    @EnvironmentObject private(set) var store: CollectionPickerStore
    private(set) var selectedKeys: (Set<String>) -> Void

    // SWIFTUI BUG: - presentationMode.wrappedValule.dismiss() didn't work when presented from UIViewController, so I pass a closure
    // This view is presented by UIKit, because modals in SwiftUI are currently buggy
//    @Environment(\.presentationMode) private var presentationMode: Binding<PresentationMode>
    let closeAction: () -> Void

    var body: some View {
        List(selection: self.$store.state.selected) {
            ForEach(self.store.state.collections) { collection in
                CollectionRow(data: collection)
                    .listRowInsets(EdgeInsets(top: 0,
                                              leading: self.inset(for: collection.level),
                                              bottom: 0,
                                              trailing: 0))
            }
        }
        .navigationBarTitle(Text(self.navBarTitle), displayMode: .inline)
        .navigationBarItems(leading:
                                Button(action: self.closeAction,
                                       label: { Text("Cancel") })
                            , trailing:
                                Button(action: {
                                    self.selectedKeys(self.store.state.selected)
                                    self.closeAction()
                                },
                                label: {
                                    Text("Save")
                                })
        )
        .environment(\.editMode, .constant(.active))
    }

    private var navBarTitle: String {
        switch self.store.state.selected.count {
        case 0:
            return "Select a Collection"
        case 1:
            return "1 Collection Selected"
        default:
            return "\(self.store.state.selected.count) Collections Selected"
        }
    }

    private func inset(for level: Int) -> CGFloat {
        return CollectionRow.levelOffset + (CGFloat(level) * CollectionRow.levelOffset)
    }
}

struct CollectionsPickerView_Previews: PreviewProvider {
    static var previews: some View {
        CollectionsPickerView(selectedKeys: { _ in }, closeAction: {})
                .environmentObject(CollectionPickerStore(library: .init(identifier: .custom(.myLibrary),
                                                                           name: "My Library",
                                                                           metadataEditable: true,
                                                                           filesEditable: true),
                                                            dbStorage: Controllers().dbStorage))
    }
}
