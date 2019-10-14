//
//  ItemSortTypePickerView.swift
//  Zotero
//
//  Created by Michal Rentka on 11/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct ItemSortTypePickerView: View {
    @Binding var sortBy: ItemsSortType.Field

        // SWIFTUI BUG: - presentationMode.wrappedValule.dismiss() didn't work when presented from UIViewController, so I pass a closure
        // This view is presented by UIKit, because modals in SwiftUI are currently buggy
//    @Environment(\.presentationMode) private var presentationMode: Binding<PresentationMode>
    let closeAction: () -> Void

    var body: some View {
        List {
            ForEach(ItemsSortType.Field.allCases) { sortType in
                SortTypeRow(title: sortType.title,
                            isSelected: (self.sortBy == sortType))
                    .onTapGesture {
                        self.sortBy = sortType
                        self.closeAction()
                    }
            }
        }
        .navigationBarTitle(Text("Sort By"), displayMode: .inline)
        .navigationBarItems(leading: Button(action: self.closeAction,
                                            label: { Text("Cancel") }))
    }
}

fileprivate struct SortTypeRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(self.title)
            if self.isSelected {
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundColor(.blue)
            }
        }
    }
}

struct ItemSortTypePickerView_Previews: PreviewProvider {
    static var previews: some View {
        ItemSortTypePickerView(sortBy: .constant(.title), closeAction: {})
    }
}
