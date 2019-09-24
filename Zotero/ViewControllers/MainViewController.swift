//
//  MainViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 11/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit
import SafariServices
import SwiftUI

import BetterSheet
import RxSwift

#if PDFENABLED
import PSPDFKit
import PSPDFKitUI
#endif

fileprivate enum PrimaryColumnState {
    case minimum
    case dynamic(CGFloat)
}

class MainViewController: UISplitViewController, ConflictPresenter {
    // Constants
    private static let minPrimaryColumnWidth: CGFloat = 300
    private static let maxPrimaryColumnFraction: CGFloat = 0.4
    private static let averageCharacterWidth: CGFloat = 10.0
    private let defaultLibrary: Library
    private let defaultCollection: Collection
    private let controllers: Controllers
    private let disposeBag: DisposeBag
    // Variables
    private var currentLandscapePrimaryColumnFraction: CGFloat = 0
    private var isViewingLibraries: Bool {
        return (self.viewControllers.first as? UINavigationController)?.viewControllers.count == 1
    }
    private var maxSize: CGFloat {
        return max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
    }

    // MARK: - Lifecycle

    init(controllers: Controllers) {
        self.defaultLibrary = Library(identifier: .custom(.myLibrary),
                                      name: RCustomLibraryType.myLibrary.libraryName,
                                      metadataEditable: true,
                                      filesEditable: true)
        self.defaultCollection = Collection(custom: .all)
        self.controllers = controllers
        self.disposeBag = DisposeBag()

        super.init(nibName: nil, bundle: nil)

        self.setupControllers()

        self.preferredDisplayMode = .allVisible
        self.minimumPrimaryColumnWidth = MainViewController.minPrimaryColumnWidth
        self.maximumPrimaryColumnWidth = self.maxSize * MainViewController.maxPrimaryColumnFraction

        NotificationCenter.default.rx.notification(.presentPdf)
                                     .observeOn(MainScheduler.instance)
                                     .subscribe(onNext: { [weak self] notification in
                                        if let url = notification.object as? URL {
                                            self?.presentPdf(with: url)
                                        }
                                     })
                                     .disposed(by: self.disposeBag)
         NotificationCenter.default.rx.notification(.presentWeb)
                                      .observeOn(MainScheduler.instance)
                                      .subscribe(onNext: { [weak self] notification in
                                         if let url = notification.object as? URL {
                                            self?.presentWeb(with: url)
                                         }
                                      })
                                      .disposed(by: self.disposeBag)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.delegate = self
        self.setPrimaryColumn(state: .minimum, animated: false)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        let isLandscape = size.width > size.height
        coordinator.animate(alongsideTransition: { _ in
            if !isLandscape || self.isViewingLibraries {
                self.setPrimaryColumn(state: .minimum, animated: false)
                return
            }
            self.setPrimaryColumn(state: .dynamic(self.currentLandscapePrimaryColumnFraction), animated: false)
        }, completion: nil)
    }

    // MARK: - Actions

    private func presentPdf(with url: URL) {
        #if PDFENABLED
        let controller = PSPDFViewController(document: PSPDFDocument(url: url))
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        self.present(navigationController, animated: true, completion: nil)
        #endif
    }

    private func presentWeb(with url: URL) {
        let controller = SFSafariViewController(url: url)
        self.present(controller, animated: true, completion: nil)
    }

    private func showCollections(in library: Library) {
        guard let navigationController = self.viewControllers.first as? UINavigationController else { return }
        let store = CollectionsStore(library: library, dbStorage: self.controllers.dbStorage)
        let view = CollectionsView(store: store, rowSelected: self.showItems)

        self.showItems(in: Collection(custom: .all), library: library)

        navigationController.pushViewController(UIHostingController(rootView: view), animated: true)
        navigationController.transitionCoordinator?.animate(alongsideTransition: nil, completion: { _ in
            self.reloadPrimaryColumnFraction(with: store.state.cellData, animated: true)
        })
    }

    private func showItems(in collection: Collection, library: Library) {
        let view = ItemsView(store: self.itemsStore(for: collection, library: library))
                        .environment(\.dbStorage, self.controllers.dbStorage)
                        .environment(\.apiClient, self.controllers.apiClient)
                        .environment(\.fileStorage, self.controllers.fileStorage)
                        .environment(\.schemaController, self.controllers.schemaController)
        self.showSecondaryController(UIHostingController.withBetterSheetSupport(rootView: view))
    }

    private func showSecondaryController(_ controller: UIViewController) {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            (self.viewControllers.last as? UINavigationController)?.setViewControllers([controller], animated: false)
        case .phone:
            (self.viewControllers.first as? UINavigationController)?.pushViewController(controller, animated: true)
        default: break
        }
    }

    private func itemsStore(for collection: Collection, library: Library) -> ItemsStore {
        let type: ItemsStore.State.ItemType

        switch collection.type {
        case .collection:
            type = .collection(collection.key, collection.name)
        case .search:
            type = .search(collection.key, collection.name)
        case .custom(let customType):
            switch customType {
            case .all:
                type = .all
            case .publications:
                type = .publications
            case .trash:
                type = .trash
            }
        }

        return ItemsStore(type: type, library: library, dbStorage: self.controllers.dbStorage)
    }

    // MARK: - Dynamic primary column

    private func reloadPrimaryColumnFraction(with data: [Collection], animated: Bool) {
        let newFraction = self.calculatePrimaryColumnFraction(from: data)
        self.currentLandscapePrimaryColumnFraction = newFraction
        if UIDevice.current.orientation.isLandscape {
            self.setPrimaryColumn(state: .dynamic(newFraction), animated: animated)
        }
    }

    private func setPrimaryColumn(state: PrimaryColumnState, animated: Bool) {
        let primaryColumnFraction: CGFloat
        switch state {
        case .minimum:
            primaryColumnFraction = 0.0
        case .dynamic(let fraction):
            primaryColumnFraction = fraction
        }

        guard primaryColumnFraction != self.preferredPrimaryColumnWidthFraction else { return }

        if !animated {
            self.preferredPrimaryColumnWidthFraction = primaryColumnFraction
            return
        }

        UIView.animate(withDuration: 0.2) {
            self.preferredPrimaryColumnWidthFraction = primaryColumnFraction
        }
    }

    private func calculatePrimaryColumnFraction(from collections: [Collection]) -> CGFloat {
        guard !collections.isEmpty else { return 0 }

        var maxCollection: Collection?
        var maxWidth: CGFloat = 0

        collections.forEach { data in
            let width = (CGFloat(data.level) * CollectionCell.levelOffset) +
                        (CGFloat(data.name.count) * MainViewController.averageCharacterWidth)
            if width > maxWidth {
                maxCollection = data
                maxWidth = width
            }
        }

        guard let collection = maxCollection else { return 0 }

        let titleSize = collection.name.size(withAttributes:[.font: UIFont.systemFont(ofSize: 18.0)])
        let actualWidth = titleSize.width + (CGFloat(collection.level) * CollectionCell.levelOffset) + (2 * CollectionCell.baseOffset)

        return min(1.0, (actualWidth / self.maxSize))
    }

    // MARK: - Setups

    private func setupControllers() {
        let librariesView = LibrariesView(store: LibrariesStore(dbStorage: self.controllers.dbStorage),
                                          librarySelected: self.showCollections)
        let collectionsStore = CollectionsStore(library: self.defaultLibrary,
                                                dbStorage: self.controllers.dbStorage)
        let collectionsView = CollectionsView(store: collectionsStore, rowSelected: self.showItems)

        let masterController = UINavigationController()
        masterController.viewControllers = [UIHostingController(rootView: librariesView),
                                            UIHostingController(rootView: collectionsView)]

        let itemsView = ItemsView(store: self.itemsStore(for: self.defaultCollection,
                                                         library: self.defaultLibrary))
                            .environment(\.dbStorage, self.controllers.dbStorage)
                            .environment(\.apiClient, self.controllers.apiClient)
                            .environment(\.fileStorage, self.controllers.fileStorage)
                            .environment(\.schemaController, self.controllers.schemaController)

        let detailController = UINavigationController(rootViewController: UIHostingController.withBetterSheetSupport(rootView: itemsView))

        self.viewControllers = [masterController, detailController]
        self.reloadPrimaryColumnFraction(with: collectionsStore.state.cellData, animated: false)
    }
}

extension MainViewController: UISplitViewControllerDelegate {
    func splitViewController(_ splitViewController: UISplitViewController,
                             collapseSecondary secondaryViewController: UIViewController,
                             onto primaryViewController: UIViewController) -> Bool {
        return true
    }
}
