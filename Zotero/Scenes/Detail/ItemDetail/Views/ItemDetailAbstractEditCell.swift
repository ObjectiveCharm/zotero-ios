//
//  ItemDetailAbstractEditCell.swift
//  Zotero
//
//  Created by Michal Rentka on 23/10/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

final class ItemDetailAbstractEditCell: UICollectionViewListCell {
    struct ContentConfiguration: UIContentConfiguration {
        let text: String
        let layoutMargins: UIEdgeInsets
        let textChanged: (String) -> Void

        func makeContentView() -> UIView & UIContentView {
            return ContentView(configuration: self)
        }

        func updated(for state: UIConfigurationState) -> ContentConfiguration {
            return self
        }
    }

    final class ContentView: UIView, UIContentView {
        var configuration: UIContentConfiguration {
            didSet {
                guard let configuration = self.configuration as? ContentConfiguration else { return }
                self.contentView.setup(with: configuration.text)
            }
        }

        fileprivate weak var contentView: ItemDetailAbstractEditContentView!

        init(configuration: ContentConfiguration) {
            self.configuration = configuration

            super.init(frame: .zero)

            guard let view = UINib.init(nibName: "ItemDetailAbstractEditContentView", bundle: nil).instantiate(withOwner: self)[0] as? ItemDetailAbstractEditContentView else { return }

            self.add(contentView: view)
            view.layoutMargins = configuration.layoutMargins
            view.textChanged = configuration.textChanged
            self.contentView = view
            self.contentView.setup(with: configuration.text)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }
    }
}
