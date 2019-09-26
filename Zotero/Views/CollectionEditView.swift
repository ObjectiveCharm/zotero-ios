//
//  CollectionEditView.swift
//  Zotero
//
//  Created by Michal Rentka on 24/09/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct CollectionEditView: View {
    @ObservedObject private(set) var store: NewCollectionEditStore

    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    @Environment(\.dbStorage) private var dbStorage: DbStorage

    private var title: Text {
        return Text(self.store.state.key == nil ? "Create collection" : "Edit collection")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: self.$store.state.name)
            }

            Section {
                NavigationLink(destination: self.createPickerView()) {
                    HStack {
                        Image(self.store.state.parent == nil ?
                                "icon_cell_library" :
                                "icon_cell_collection")
                            .renderingMode(.template)
                            .foregroundColor(.blue)
                        Text(self.store.state.parent?.name ?? self.store.state.library.name)
                    }
                }
            }

            if self.store.state.key != nil {
                Section {
                    Button(action: self.store.delete) {
                        Text("Delete Collection")
                            .foregroundColor(Color.red)
                    }
                    Button(action: self.store.deleteWithItems) {
                        Text("Delete Collection and Items")
                            .foregroundColor(Color.red)
                    }
                }
            }
        }
        .navigationBarItems(leading:
            Button(action: {
                self.presentationMode.wrappedValue.dismiss()
            }, label: {
                Text("Cancel")
            })
        )
        .navigationBarItems(trailing:
            Group {
                if self.store.state.loading {
                    ActivityIndicatorView(style: .medium, isAnimating: .constant(true))
                } else {
                    Button(action: self.store.save, label: {
                        Text("Save")
                    })
                }
            }
        )
        .navigationBarTitle(self.title, displayMode: .inline)
        .alert(item: self.$store.state.error) { error -> Alert in
            return Alert(title: Text("Error"), message: Text(self.message(for: error)))
        }
        .disabled(self.store.state.loading)
    }

    private func message(for error: NewCollectionEditStore.Error) -> String {
        switch error {
        case .emptyName:
            return "You have to fill the name"
        case .saveFailed:
            return "Could not save collection '\(self.store.state.name)'. Try again."
        }
    }

    private func createPickerView() -> CollectionPickerView {
        CollectionPickerView(collection: self.$store.state.parent,
                             store: NewCollectionPickerStore(library: self.store.state.library,
                                                             dbStorage: self.dbStorage))
    }
}

struct CollectionEditView_Previews: PreviewProvider {
    static var previews: some View {
        CollectionEditView(store: NewCollectionEditStore(library: .init(identifier: .custom(.myLibrary),
                                                                        name: "My Librrary",
                                                                        metadataEditable: true,
                                                                        filesEditable: true),
                                                         dbStorage: Controllers().dbStorage))
    }
}
