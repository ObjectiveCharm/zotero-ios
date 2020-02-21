//
//  ItemsViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 17/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import MobileCoreServices
import UIKit
import SwiftUI

import CocoaLumberjack
import RealmSwift
import RxSwift

class ItemsViewController: UIViewController {
    private static let cellId = "ItemCell"
    private static let barButtonItemEmptyTag = 1
    private static let barButtonItemSingleTag = 2

    private let store: ViewModel<ItemsActionHandler>
    private let controllers: Controllers
    private let disposeBag: DisposeBag

    private weak var tableView: UITableView!

    private var overlaySink: AnyCancellable?
    private var resultsToken: NotificationToken?

    init(store: ViewModel<ItemsActionHandler>, controllers: Controllers) {
        self.store = store
        self.controllers = controllers
        self.disposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.definesPresentationContext = true

        self.setupTableView()
        self.setupToolbar()
        self.updateNavigationBarItems()

        if let results = self.store.state.results {
            self.startObserving(results: results)
        }
        self.store.stateObservable
                  .observeOn(MainScheduler.instance)
                  .subscribe(onNext: { [weak self] state in
                      self?.update(state: state)
                  })
                  .disposed(by: self.disposeBag)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        // Set the search controller here so that it doesn't appear initially
        if self.navigationItem.searchController == nil {
            self.setupSearchController()
        }
    }

    private func update(state: ItemsState) {
        if state.changes.contains(.editing) {
            self.tableView.setEditing(state.isEditing, animated: true)
            self.navigationController?.setToolbarHidden(!state.isEditing, animated: true)
            self.updateNavigationBarItems()
        }

        if state.changes.contains(.results),
           let results = state.results {
            self.startObserving(results: results)
        }

        if state.changes.contains(.sortType) {
            self.tableView.reloadData()
        }

        if state.changes.contains(.selection) {
            self.updateToolbarItems()
        }

        if let item = state.itemDuplication {
            self.showItemDetail(for: .duplication(item, collectionKey: self.store.state.type.collectionKey))
        }
    }

    // MARK: - Actions

    private func perform(overlayAction: ItemsActionSheetView.Action) {
        var shouldDismiss = true
        
        switch overlayAction {
        case .dismiss: break
        case .showAttachmentPicker:
            self.showAttachmentPicker()
        case .showItemCreation:
            self.showItemCreation()
        case .showNoteCreation:
            self.showNoteCreation()
        case .showSortTypePicker:
            self.presentSortTypePicker()
        case .startEditing:
            self.store.process(action: .startEditing)
        case .toggleSortOrder:
            self.store.process(action: .toggleSortOrder)
            shouldDismiss = false
        }

        if shouldDismiss {
            self.dismiss(animated: true, completion: nil)
        }
    }

    private func presentSortTypePicker() {
        let binding: Binding<ItemsSortType.Field> = Binding(get: {
            return self.store.state.sortType.field
        }) { value in
            self.store.process(action: .setSortField(value))
        }
        let view = ItemSortTypePickerView(sortBy: binding,
                                          closeAction: { [weak self] in
                                              self?.dismiss(animated: true, completion: nil)
                                          })
        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        self.present(navigationController, animated: true, completion: nil)
    }

    private func showNoteEditing(for note: Note) {
        self.presentNoteEditor(with: note.text) { [weak self] text in
            self?.store.process(action: .saveNote(note.key, text))
        }
    }

    private func showNoteCreation() {
        self.presentNoteEditor(with: "") { [weak self] text in
            self?.store.process(action: .saveNote(nil, text))
        }
    }

    private func presentNoteEditor(with text: String, save: @escaping (String) -> Void) {
        let controller = NoteEditorViewController(text: text, saveAction: save)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.isModalInPresentation = true
        self.present(navigationController, animated: true, completion: nil)
    }

    private func showAttachmentPicker() {
        let documentTypes = [String(kUTTypePDF), String(kUTTypePNG), String(kUTTypeJPEG)]
        let controller = DocumentPickerViewController(documentTypes: documentTypes, in: .import)
        controller.popoverPresentationController?.sourceView = self.view
        controller.observable
                  .observeOn(MainScheduler.instance)
                  .subscribe(onNext: { [weak self] urls in
                      self?.store.process(action: .addAttachments(urls))
                  })
                  .disposed(by: self.disposeBag)
        self.present(controller, animated: true, completion: nil)
    }

    private func showCollectionPicker() {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }

        let view = CollectionsPickerView(selectedKeys: { [weak self] keys in
                                             self?.store.process(action: .assignSelectedItemsToCollections(keys))
                                         },
                                         closeAction: { [weak self] in
                                             self?.dismiss(animated: true, completion: nil)
                                         })
                        .environmentObject(CollectionPickerStore(library: self.store.state.library, dbStorage: dbStorage))

        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        self.present(navigationController, animated: true, completion: nil)
    }

    private func showItemCreation() {
        self.showItemDetail(for: .creation(libraryId: self.store.state.library.identifier,
                                           collectionKey: self.store.state.type.collectionKey,
                                           filesEditable: self.store.state.library.filesEditable))
    }

    private func showItemDetail(for item: RItem) {
        switch item.rawType {
        case ItemTypes.note:
            if let note = Note(item: item) {
                self.showNoteEditing(for: note)
            }

        default:
            self.showItemDetail(for: .preview(item))
        }
    }

    private func showItemDetail(for type: ItemDetailState.DetailType) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }

        do {
            let data = try ItemDetailDataCreator.createData(from: type,
                                                            schemaController: self.controllers.schemaController,
                                                            fileStorage: self.controllers.fileStorage)
            let state = ItemDetailState(type: type, userId: Defaults.shared.userId, data: data)
            let handler = ItemDetailActionHandler(apiClient: self.controllers.apiClient,
                                                  fileStorage: self.controllers.fileStorage,
                                                  dbStorage: dbStorage,
                                                  schemaController: self.controllers.schemaController)
            let viewModel = ViewModel(initialState: state, handler: handler)

            let hidesBackButton: Bool
            switch type {
            case .preview:
                hidesBackButton = false
            case .creation, .duplication:
                hidesBackButton = true
            }

            let controller = ItemDetailViewController(viewModel: viewModel, controllers: self.controllers)
            if hidesBackButton {
                controller.navigationItem.setHidesBackButton(true, animated: false)
            }
            self.navigationController?.pushViewController(controller, animated: true)
        } catch let error {
            // TODO: - show error
        }
    }

    private func startObserving(results: Results<RItem>) {
        self.resultsToken = results.observe({ [weak self] changes  in
            switch changes {
            case .initial:
                self?.tableView.reloadData()
            case .update(_, let deletions, let insertions, let modifications):
                guard let `self` = self else { return }
                self.tableView.performBatchUpdates({
                    self.tableView.deleteRows(at: deletions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                    self.tableView.reloadRows(at: modifications.map({ IndexPath(row: $0, section: 0) }), with: .none)
                    self.tableView.insertRows(at: insertions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                }, completion: nil)
            case .error(let error):
                DDLogError("ItemsViewController: could not load results - \(error)")
                self?.store.process(action: .observingFailed)
            }
        })
    }

    private func showActionSheet() {
        let view = ItemsActionSheetView(sortType: self.store.state.sortType)
        self.overlaySink = view.actionObserver.sink { [weak self] action in
            self?.perform(overlayAction: action)
        }

        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .overCurrentContext
        controller.modalTransitionStyle = .crossDissolve
        self.present(controller, animated: true, completion: nil)
    }

    private func updateNavigationBarItems() {
        let trailingitem: UIBarButtonItem

        if self.tableView.isEditing {
            trailingitem = UIBarButtonItem(title: "Done", style: .done, target: nil, action: nil)
            trailingitem.rx.tap.subscribe(onNext: { [weak self] _ in
                self?.store.process(action: .stopEditing)
            })
            .disposed(by: self.disposeBag)
        } else {
            trailingitem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain, target: nil, action: nil)
            trailingitem.rx.tap.subscribe(onNext: { [weak self] _ in
                self?.showActionSheet()
            })
            .disposed(by: self.disposeBag)
        }

        self.navigationItem.rightBarButtonItem = trailingitem
    }

    private func updateToolbarItems() {
        self.toolbarItems?.forEach({ item in
            switch item.tag {
            case ItemsViewController.barButtonItemEmptyTag:
                item.isEnabled = !self.store.state.selectedItems.isEmpty
            case ItemsViewController.barButtonItemSingleTag:
                item.isEnabled = self.store.state.selectedItems.count == 1
            default: break
            }
        })
    }

    // MARK: - Setups

    private func setupTableView() {
        let tableView = UITableView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.rowHeight = 58
        tableView.allowsMultipleSelectionDuringEditing = true

        self.view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: self.view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])

        tableView.register(ItemCell.self, forCellReuseIdentifier: ItemsViewController.cellId)

        self.tableView = tableView
    }

    private func setupToolbar() {
        self.toolbarItems = self.store.state.type.isTrash ? self.createTrashToolbarItems() : self.createNormalToolbarItems()
    }

    private func createNormalToolbarItems() -> [UIBarButtonItem] {
        let pickerItem = UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: nil, action: nil)
        pickerItem.rx.tap.subscribe(onNext: { [weak self] _ in
            self?.showCollectionPicker()
        })
        .disposed(by: self.disposeBag)
        pickerItem.tag = ItemsViewController.barButtonItemEmptyTag

        let trashItem = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: nil, action: nil)
        trashItem.rx.tap.subscribe(onNext: { [weak self] _ in
            self?.store.process(action: .trashSelectedItems)
        })
        .disposed(by: self.disposeBag)
        trashItem.tag = ItemsViewController.barButtonItemEmptyTag

        let duplicateItem = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), style: .plain, target: nil, action: nil)
        duplicateItem.rx.tap.subscribe(onNext: { [weak self] _ in
            if let key = self?.store.state.selectedItems.first {
                self?.store.process(action: .loadItemToDuplicate(key))
            }
        })
        .disposed(by: self.disposeBag)
        duplicateItem.tag = ItemsViewController.barButtonItemSingleTag

        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        var items = [spacer, pickerItem, spacer, trashItem, spacer, duplicateItem, spacer]

        if self.store.state.type.collectionKey != nil {
            let removeItem = UIBarButtonItem(image: UIImage(systemName: "folder.badge.minus"), style: .plain, target: nil, action: nil)
            removeItem.rx.tap.subscribe(onNext: { [weak self] _ in
                self?.store.process(action: .trashSelectedItems)
            })
            .disposed(by: self.disposeBag)
            removeItem.tag = ItemsViewController.barButtonItemEmptyTag

            items.insert(contentsOf: [spacer, removeItem], at: 2)
        }

        return items
    }

    private func createTrashToolbarItems() -> [UIBarButtonItem] {
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let trashItem = UIBarButtonItem(image: UIImage(named: "restore_trash"), style: .plain, target: nil, action: nil)
        trashItem.rx.tap.subscribe(onNext: { [weak self] _ in
            self?.store.process(action: .restoreSelectedItems)
        })
        .disposed(by: self.disposeBag)
        trashItem.tag = ItemsViewController.barButtonItemEmptyTag

        let emptyItem = UIBarButtonItem(image: UIImage(named: "empty_trash"), style: .plain, target: nil, action: nil)
        emptyItem.rx.tap.subscribe(onNext: { [weak self] _ in
            self?.store.process(action: .deleteSelectedItems)
        })
        .disposed(by: self.disposeBag)
        emptyItem.tag = ItemsViewController.barButtonItemEmptyTag

        return [spacer, trashItem, spacer, emptyItem, spacer]
    }

    private func setupSearchController() {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchBar.placeholder = "Search Items"
        controller.obscuresBackgroundDuringPresentation = false
        self.navigationItem.searchController = controller


        controller.searchBar.rx.text.observeOn(MainScheduler.instance)
                                    .debounce(.milliseconds(150), scheduler: MainScheduler.instance)
                                    .subscribe(onNext: { [weak self] text in
                                        self?.store.process(action: .search(text ?? ""))
                                    })
                                    .disposed(by: self.disposeBag)
    }
}

extension ItemsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.store.state.results?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ItemsViewController.cellId, for: indexPath)

        if let item = self.store.state.results?[indexPath.row],
           let cell = cell as? ItemCell {
            cell.set(item: item)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = self.store.state.results?[indexPath.row] else { return }

        if tableView.isEditing {
            self.store.process(action: .selectItem(item.key))
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            self.showItemDetail(for: item)
        }
    }
}

extension ItemsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing,
            let item = self.store.state.results?[indexPath.row] {
            self.store.process(action: .deselectItem(item.key))
        }
    }
}

extension ItemsViewController: UITableViewDragDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let item = self.store.state.results?[indexPath.row] else { return [] }
        return [self.controllers.dragDropController.dragItem(from: item)]
    }
}

extension ItemsViewController: UITableViewDropDelegate {
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let indexPath = coordinator.destinationIndexPath,
              let key = self.store.state.results?[indexPath.row].key else { return }

        switch coordinator.proposal.operation {
        case .move:
            self.controllers.dragDropController.itemKeys(from: coordinator.items) { [weak self] keys in
                self?.store.process(action: .moveItems(keys, key))
            }
        default: break
        }
    }

    func tableView(_ tableView: UITableView,
                   dropSessionDidUpdate session: UIDropSession,
                   withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        // Allow only local drag session
        guard session.localDragSession != nil else {
            return UITableViewDropProposal(operation: .forbidden)
        }

        // Allow dropping only to non-standalone items
        if let item = destinationIndexPath.flatMap({ self.store.state.results?[$0.row] }),
           (item.rawType == ItemTypes.note || item.rawType == ItemTypes.attachment) {
           return UITableViewDropProposal(operation: .forbidden)
        }

        // Allow drops of only standalone items
        if session.items.compactMap({ self.controllers.dragDropController.item(from: $0) })
                        .contains(where: { $0.rawType != ItemTypes.attachment && $0.rawType != ItemTypes.note }) {
            return UITableViewDropProposal(operation: .forbidden)
        }

        return UITableViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }
}
