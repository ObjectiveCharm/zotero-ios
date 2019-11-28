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
    @EnvironmentObject private(set) var store: ItemsStore

    @Environment(\.editMode) private var editMode: Binding<EditMode>
    @Environment(\.dbStorage) private var dbStorage: DbStorage
    @Environment(\.apiClient) private var apiClient: ApiClient
    @Environment(\.schemaController) private var schemaController: SchemaController
    @Environment(\.fileStorage) private var fileStorage: FileStorage

    var body: some View {
        VStack {
            NavigationLink(destination: self.itemCreationView,
                           isActive: self.$store.state.showingCreation,
                           label: { EmptyView() })

//            List(selection: self.$store.state.selectedItems) {
//                self.store.state.sections.flatMap {
//                    ForEach($0, id: \.self) { section in
//                        self.store.state.items(for: section).flatMap { items in
//                            ItemSectionView(results: items,
//                                            libraryId: self.store.state.library.identifier)
//                        }
//                    }
//                }
//            }

            if self.editMode?.wrappedValue.isEditing == true {
                Toolbar()
            }
        }
        .onAppear(perform: { self.store.state.showingCreation = false })
        .overlay(ItemsActionSheetView())
        .navigationBarTitle(self.navigationBarTitle, displayMode: .inline)
        .navigationBarItems(trailing: self.trailingItems)
        .edgesIgnoringSafeArea(self.editMode?.wrappedValue.isEditing == true ? .bottom : Edge.Set(rawValue: 0))
    }

    private var navigationBarTitle: Text {
        if self.editMode?.wrappedValue.isEditing == true {
            switch self.store.state.selectedItems.count {
            case 0:
                return Text("Select Items")
            case 1:
                return Text("1 Item Selected")
            default:
                return Text("\(self.store.state.selectedItems.count) Items Selected")
            }
        }
        return Text("")
    }

    private var trailingItems: some View {
        Group {
            if self.editMode?.wrappedValue.isEditing == true {
                Button(action: {
                    self.editMode?.animation().wrappedValue = .inactive
                }, label: {
                    Text("Done")
                })
            } else {
                Button(action: {
                    withAnimation {
//                        self.store.state.menuActionSheetPresented = true
                    }
                }) {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    private var itemCreationView: some View {
        let store = ItemDetailStore(type: .creation(libraryId: self.store.state.library.identifier,
                                                    collectionKey: self.store.state.type.collectionKey,
                                                    filesEditable: self.store.state.library.filesEditable),
                                    userId: Defaults.shared.userId,
                                    apiClient: self.apiClient,
                                    fileStorage: self.fileStorage,
                                    dbStorage: self.dbStorage,
                                    schemaController: self.schemaController)
        return ItemDetailView()
                    .environmentObject(store)
    }
}

fileprivate struct Toolbar: View {
    @EnvironmentObject private(set) var store: ItemsStore

    var body: some View {
        Group {
            if self.store.state.type.isTrash {
                self.trashActions
            } else {
                self.mainActions
            }
        }
        .padding(.vertical)
        .padding(.bottom, 20)
        .background(Color.gray.opacity(0.05))
    }

    private var mainActions: some View {
        HStack {
            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .presentCollectionsPicker, object: (self.store.state.library, self.store.assignSelectedItems))
            }) {
                Image(systemName: "folder.badge.plus")
                    .imageScale(.large)
            }
            .disabled(self.store.state.selectedItems.isEmpty)

            Spacer()

            Button(action: self.store.trashSelectedItems) {
                Image(systemName: "trash")
                    .imageScale(.large)
            }
            .disabled(self.store.state.selectedItems.isEmpty)

            Spacer()

            Button(action: {
                let key = self.store.state.selectedItems.first ?? ""
                NotificationCenter.default.post(name: .showDuplicateCreation,
                                                object: (key, self.store.state.library, self.store.state.type.collectionKey))
            }) {
                Image(systemName: "square.on.square")
                    .imageScale(.large)
            }
            .disabled(self.store.state.selectedItems.count != 1)

            Spacer()
        }
    }

    private var trashActions: some View {
        HStack {
            Spacer()

            Button(action: self.store.restoreSelectedItems) {
                Image("restore_trash")
            }
            .disabled(self.store.state.selectedItems.isEmpty)

            Spacer()

            Button(action: self.store.deleteSelectedItems) {
                Image("empty_trash")
            }
            .disabled(self.store.state.selectedItems.isEmpty)

            Spacer()
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
                NavigationLink(destination: ItemDetailView().environmentObject(self.detailStore(for: item))) {
                    ItemRow(item: item)
                }
            }
        }
    }

    private func detailStore(for item: RItem) -> ItemDetailStore {
        return ItemDetailStore(type: .preview(item),
                               userId: Defaults.shared.userId,
                               apiClient: self.apiClient,
                               fileStorage: self.fileStorage,
                               dbStorage: self.dbStorage,
                               schemaController: self.schemaController)
    }
}

//struct ItemsView_Previews: PreviewProvider {
//    static var previews: some View {
//        let controllers = Controllers()
//        let store = ItemsStore(type: .all,
//                               library: Library(identifier: .custom(.myLibrary), name: "My library",
//                                                metadataEditable: true, filesEditable: true),
//                               dbStorage: controllers.dbStorage,
//                               fileStorage: controllers.fileStorage,
//                               schemaController: controllers.schemaController)
//        return ItemsView().environmentObject(store)
//    }
//}
