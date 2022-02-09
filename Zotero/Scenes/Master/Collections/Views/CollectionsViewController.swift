//
//  CollectionsViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 17/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import UIKit
import SwiftUI

import RealmSwift
import RxSwift

final class CollectionsViewController: UIViewController {
    @IBOutlet private weak var collectionView: UICollectionView!

    private let viewModel: ViewModel<CollectionsActionHandler>
    private unowned let dragDropController: DragDropController
    private let disposeBag: DisposeBag

    private var collectionViewHandler: ExpandableCollectionsCollectionViewHandler!
    weak var coordinatorDelegate: MasterCollectionsCoordinatorDelegate?

    init(viewModel: ViewModel<CollectionsActionHandler>, dragDropController: DragDropController) {
        self.viewModel = viewModel
        self.dragDropController = dragDropController
        self.disposeBag = DisposeBag()

        super.init(nibName: "CollectionsViewController", bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.viewModel.process(action: .loadData)

        self.setupTitleWithContextMenu(self.viewModel.state.library.name)
        if self.viewModel.state.library.metadataEditable {
            self.setupAddNavbarItem()
        }
        self.collectionViewHandler = ExpandableCollectionsCollectionViewHandler(collectionView: self.collectionView, dragDropController: self.dragDropController, viewModel: self.viewModel, splitDelegate: self.coordinatorDelegate)
        self.updateCollections(to: self.viewModel.state, animated: false)

        self.viewModel.stateObservable
                      .observe(on: MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(to: state)
                      })
                      .disposed(by: self.disposeBag)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.selectIfNeeded(collectionId: self.viewModel.state.selectedCollectionId, scrollToPosition: true)
        if self.coordinatorDelegate?.isSplit == true, let collection = self.viewModel.state.collections[self.viewModel.state.selectedCollectionId] {
            self.coordinatorDelegate?.showItems(for: collection, in: self.viewModel.state.library, isInitial: true)
        }
    }

    // MARK: - UI state

    private func update(to state: CollectionsState) {
        if state.changes.contains(.results) {
            self.updateCollections(to: state, animated: true)
            self.selectIfNeeded(collectionId: state.selectedCollectionId, scrollToPosition: false)
        }
        
        if state.changes.contains(.allItemCount) || state.changes.contains(.trashItemCount) {
            self.updateCollections(to: state, animated: false)
        }

        if state.changes.contains(.selection), let collection = state.collections[state.selectedCollectionId] {
            self.coordinatorDelegate?.showItems(for: collection, in: state.library, isInitial: false)
            self.selectIfNeeded(collectionId: state.selectedCollectionId, scrollToPosition: false)
        }

        if state.changes.contains(.collapsedState) {
            self.collectionViewHandler.update(collapsedState: state.collapsedState)
        }

        if let data = state.editingData {
            self.coordinatorDelegate?.showEditView(for: data, library: state.library)
        }

        if let result = state.itemKeysForBibliography {
            switch result {
            case .success(let keys):
                self.coordinatorDelegate?.showCiteExport(for: keys, libraryId: state.libraryId)
            case .failure:
                self.coordinatorDelegate?.showCiteExportError()
            }
        }
    }

    private func updateCollections(to state: CollectionsState, animated: Bool) {
        self.collectionViewHandler.update(root: state.rootCollections, children: state.childCollections, collapsed: state.collapsedState, collections: state.collections,
                                          selected: state.selectedCollectionId, animated: animated)
    }

    // MARK: - Actions

    private func selectIfNeeded(collectionId: CollectionIdentifier, scrollToPosition: Bool) {
        // Selection is disabled in compact mode (when UISplitViewController is a single column instead of master + detail).
        guard self.coordinatorDelegate?.isSplit == true else { return }
        self.collectionViewHandler.selectIfNeeded(collectionId: collectionId, scrollToPosition: scrollToPosition)
    }

    private func select(searchResult: Collection) {
        let isSplit = self.coordinatorDelegate?.isSplit ?? false

        if isSplit {
            self.selectIfNeeded(collectionId: searchResult.identifier, scrollToPosition: false)
        }

        // We don't need to always show it on iPad, since the currently selected collection is visible. So we show only a new one. On iPhone
        // on the other hand we see only the collection list, so we always need to open the item list for selected collection.
        guard !isSplit ? true : searchResult.identifier != self.viewModel.state.selectedCollectionId else { return }
        self.viewModel.process(action: .select(searchResult.identifier))
    }

    private func createCollapseAllContextMenu() -> UIMenu? {
        guard self.collectionViewHandler.hasExpandableCollection else { return nil }

        let allExpanded = self.collectionViewHandler.allCollectionsExpanded
        let selectedCollectionIsRoot = self.collectionViewHandler.selectedCollectionIsRoot
        let title = allExpanded ? L10n.Collections.collapseAll : L10n.Collections.expandAll
        let action = UIAction(title: title) { [weak self] _ in
            self?.viewModel.process(action: (allExpanded ? .collapseAll(selectedCollectionIsRoot: selectedCollectionIsRoot) : .expandAll(selectedCollectionIsRoot: selectedCollectionIsRoot)))
        }
    
        return UIMenu(title: "", children: [action])
    }

    // MARK: - Setups

    private func setupAddNavbarItem() {
        let addItem = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: nil, action: nil)
        addItem.accessibilityLabel = L10n.Accessibility.Collections.createCollection
        addItem.rx.tap
               .subscribe(onNext: { [weak self] _ in
                self?.viewModel.process(action: .startEditing(.add))
               })
               .disposed(by: self.disposeBag)

        let searchItem = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain, target: nil, action: nil)
        searchItem.accessibilityLabel = L10n.Accessibility.Collections.searchCollections
        searchItem.rx.tap
                  .subscribe(onNext: { [weak self] _ in
                      guard let `self` = self else { return }
                      self.coordinatorDelegate?.showSearch(for: self.viewModel.state, in: self, selectAction: { [weak self] collection in
                          self?.select(searchResult: collection)
                      })
                  })
                  .disposed(by: self.disposeBag)

        self.navigationItem.rightBarButtonItems = [addItem, searchItem]
    }

    private func setupTitleWithContextMenu(_ title: String) {
        let button = UIButton(type: .custom)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = "\(title) \(L10n.Accessibility.Collections.expandAllCollections)"
        button.setTitleColor(UIColor(dynamicProvider: { $0.userInterfaceStyle == .light ? .black : .white }), for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let interaction = UIContextMenuInteraction(delegate: self)
        button.addInteraction(interaction)
        self.navigationItem.titleView = button
    }
}

extension CollectionsViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in
            return self.createCollapseAllContextMenu()
        })
    }
}
