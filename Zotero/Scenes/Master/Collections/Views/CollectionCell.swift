//
//  CollectionCell.swift
//  Zotero
//
//  Created by Michal Rentka on 14/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

final class CollectionCell: UICollectionViewListCell {
    struct ContentConfiguration: UIContentConfiguration {
        let collection: Collection
        let hasChildren: Bool
        let isCollapsed: Bool

        var toggleCollapsed: (() -> Void)?

        func makeContentView() -> UIView & UIContentView {
            return ContentView(baseConfiguration: self)
        }

        func updated(for state: UIConfigurationState) -> ContentConfiguration {
            return self
        }
    }

    struct SearchContentConfiguration: UIContentConfiguration {
        let collection: Collection
        let hasChildren: Bool
        let isActive: Bool

        func makeContentView() -> UIView & UIContentView {
            return ContentView(searchConfiguration: self)
        }

        func updated(for state: UIConfigurationState) -> SearchContentConfiguration {
            return self
        }
    }

    final class ContentView: UIView, UIContentView {
        var configuration: UIContentConfiguration {
            didSet {
                if let configuration = self.configuration as? ContentConfiguration {
                    self.apply(configuration: configuration)
                } else if let configuration = self.configuration as? SearchContentConfiguration {
                    self.apply(configuration: configuration)
                }
            }
        }

        fileprivate weak var contentView: CollectionCellContentView?

        private init(configuration: UIContentConfiguration) {
            self.configuration = configuration

            super.init(frame: .zero)

            guard let view = UINib.init(nibName: "CollectionCellContentView", bundle: nil).instantiate(withOwner: self)[0] as? CollectionCellContentView else { return }
            self.setup(view: view)
        }

        convenience init(baseConfiguration: ContentConfiguration) {
            self.init(configuration: baseConfiguration)
            self.apply(configuration: baseConfiguration)
        }

        convenience init(searchConfiguration: SearchContentConfiguration) {
            self.init(configuration: searchConfiguration)
            self.apply(configuration: searchConfiguration)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        private func apply(configuration: ContentConfiguration) {
            self.contentView?.set(collection: configuration.collection, hasChildren: configuration.hasChildren, isCollapsed: configuration.isCollapsed, toggleCollapsed: configuration.toggleCollapsed)
        }

        private func apply(configuration: SearchContentConfiguration) {
            self.contentView?.set(collection: configuration.collection, hasChildren: configuration.hasChildren, isActive: configuration.isActive)
        }

        private func setup(view: CollectionCellContentView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(view)
            self.contentView = view

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                self.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                view.topAnchor.constraint(equalTo: self.topAnchor),
                self.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }
}
