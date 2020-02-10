//
//  ItemDetailNoteSectionView.swift
//  Zotero
//
//  Created by Michal Rentka on 01/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct ItemDetailNoteSectionView: View {
    @EnvironmentObject private(set) var store: ItemDetailStore

    var body: some View {
        Section {
            ItemDetailSectionVView(title: "Notes")
            ForEach(self.store.state.data.notes) { note in
                Button(action: {
                    self.store.state.presentedNote = note
                    NotificationCenter.default.post(name: .presentNote, object: (self.$store.state.presentedNote, self.store.saveNote))
                }) {
                    ItemDetailNoteView(text: note.title)
                }
            }
        }
    }
}

struct ItemDetailNoteSectionView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            ItemDetailNoteSectionView()
        }
    }
}
