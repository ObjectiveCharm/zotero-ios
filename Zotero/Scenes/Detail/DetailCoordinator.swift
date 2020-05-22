//
//  DetailCoordinator.swift
//  Zotero
//
//  Created by Michal Rentka on 12/03/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import MobileCoreServices
import UIKit
import SafariServices
import SwiftUI

import CocoaLumberjack
import RxSwift

protocol DetailItemsCoordinatorDelegate: class {
    func showCollectionPicker(in library: Library, selectedKeys: Binding<Set<String>>)
    func showItemDetail(for type: ItemDetailState.DetailType, library: Library)
    func showNote(with text: String, readOnly: Bool, save: @escaping (String) -> Void)
    func showAddActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem)
    func showSortActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem)
}

protocol DetailItemActionSheetCoordinatorDelegate: class {
    func showSortTypePicker(sortBy: Binding<ItemsSortType.Field>)
    func showNoteCreation(save: @escaping (String) -> Void)
    func showAttachmentPicker(save: @escaping ([URL]) -> Void)
    func showItemCreation(library: Library, collectionKey: String?)
}

protocol DetailItemDetailCoordinatorDelegate: class {
    func showNote(with text: String, readOnly: Bool, save: @escaping (String) -> Void)
    func showAttachmentPicker(save: @escaping ([URL]) -> Void)
    func showTagPicker(libraryId: LibraryIdentifier, selected: Set<String>, picked: @escaping ([Tag]) -> Void)
    func showCreatorTypePicker(itemType: String, selected: String, picked: @escaping (String) -> Void)
    func showTypePicker(selected: String, picked: @escaping (String) -> Void)
    func showPdf(at url: URL, key: String)
    func showUnknownAttachment(at url: URL)
    func showWeb(url: URL)
}

class DetailCoordinator: Coordinator {
    var parentCoordinator: Coordinator?
    var childCoordinators: [Coordinator]

    let collection: Collection
    let library: Library
    private unowned let controllers: Controllers
    unowned let navigationController: UINavigationController
    private let disposeBag: DisposeBag

    init(library: Library, collection: Collection, navigationController: UINavigationController, controllers: Controllers) {
        self.library = library
        self.collection = collection
        self.navigationController = navigationController
        self.controllers = controllers
        self.childCoordinators = []
        self.disposeBag = DisposeBag()
    }

    func start(animated: Bool) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }
        let controller = self.createItemsViewController(collection: self.collection, library: self.library, dbStorage: dbStorage)
        self.navigationController.setViewControllers([controller], animated: animated)
    }

    private func createItemsViewController(collection: Collection, library: Library, dbStorage: DbStorage) -> ItemsViewController {
        let type = self.fetchType(from: collection)
        let state = ItemsState(type: type, library: library, results: nil, sortType: .default, error: nil)
        let handler = ItemsActionHandler(dbStorage: dbStorage,
                                         fileStorage: self.controllers.fileStorage,
                                         schemaController: self.controllers.schemaController)
        let controller = ItemsViewController(viewModel: ViewModel(initialState: state, handler: handler), controllers: self.controllers)
        controller.coordinatorDelegate = self
        return controller
    }

    private func fetchType(from collection: Collection) -> ItemFetchType {
        switch collection.type {
        case .collection:
            return .collection(collection.key, collection.name)
        case .search:
            return .search(collection.key, collection.name)
        case .custom(let customType):
            switch customType {
            case .all:
                return .all
            case .publications:
                return .publications
            case .trash:
                return .trash
            }
        }
    }
}

extension DetailCoordinator: DetailItemsCoordinatorDelegate {
    func showAddActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem) {
        let controller = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        controller.popoverPresentationController?.barButtonItem = button

        controller.addAction(UIAlertAction(title: L10n.Items.new, style: .default, handler: { [weak self, weak viewModel] _ in
            guard let `self` = self, let viewModel = viewModel else { return }
            self.showItemCreation(library: viewModel.state.library, collectionKey: viewModel.state.type.collectionKey)
        }))

        controller.addAction(UIAlertAction(title: L10n.Items.newNote, style: .default, handler: { [weak self, weak viewModel] _ in
            self?.showNoteCreation(save: { text in
                viewModel?.process(action: .saveNote(nil, text))
            })
        }))

        controller.addAction(UIAlertAction(title: L10n.Items.newFile, style: .default, handler: { [weak self, weak viewModel] _ in
            self?.showAttachmentPicker(save: { urls in
                viewModel?.process(action: .addAttachments(urls))
            })
        }))

        if UIDevice.current.userInterfaceIdiom == .phone {
            controller.addAction(UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil))
        }

        self.navigationController.present(controller, animated: true, completion: nil)
    }

    func showSortActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem) {
        let (fieldTitle, orderTitle) = self.sortButtonTitles(for: viewModel.state.sortType)
        let controller = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        controller.popoverPresentationController?.barButtonItem = button

        controller.addAction(UIAlertAction(title: fieldTitle, style: .default, handler: { [weak self, weak viewModel] _ in
            guard let `self` = self, let viewModel = viewModel else { return }
            let binding = viewModel.binding(keyPath: \.sortType.field, action: { .setSortField($0) })
            self.showSortTypePicker(sortBy: binding)
        }))

        controller.addAction(UIAlertAction(title: orderTitle, style: .default, handler: { [weak viewModel] _ in
            viewModel?.process(action: .toggleSortOrder)
        }))

        if UIDevice.current.userInterfaceIdiom == .phone {
            controller.addAction(UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil))
        }

        self.navigationController.present(controller, animated: true, completion: nil)
    }

    private func sortButtonTitles(for sortType: ItemsSortType) -> (field: String, order: String) {
        let sortOrderTitle = sortType.ascending ? L10n.Items.ascending : L10n.Items.descending
        return ("\(L10n.Items.sortBy): \(sortType.field.title)",
                "\(L10n.Items.sortOrder): \(sortOrderTitle)")
    }

    func showNote(with text: String, readOnly: Bool, save: @escaping (String) -> Void) {
        let controller = NoteEditorViewController(text: text, readOnly: readOnly, saveAction: save)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.isModalInPresentation = true
        self.navigationController.present(navigationController, animated: true, completion: nil)
    }

    func showItemDetail(for type: ItemDetailState.DetailType, library: Library) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }

        do {
            let hidesBackButton: Bool
            switch type {
            case .preview:
                hidesBackButton = false
            case .creation, .duplication:
                hidesBackButton = true
            }

            let data = try ItemDetailDataCreator.createData(from: type,
                                                            schemaController: self.controllers.schemaController,
                                                            fileStorage: self.controllers.fileStorage)
            let state = ItemDetailState(type: type, library: library, userId: Defaults.shared.userId, data: data)
            let handler = ItemDetailActionHandler(apiClient: self.controllers.apiClient,
                                                  fileStorage: self.controllers.fileStorage,
                                                  dbStorage: dbStorage,
                                                  schemaController: self.controllers.schemaController)
            let viewModel = ViewModel(initialState: state, handler: handler)

            let controller = ItemDetailViewController(viewModel: viewModel, controllers: self.controllers)
            controller.coordinatorDelegate = self
            controller.navigationItem.setHidesBackButton(hidesBackButton, animated: false)
            self.navigationController.pushViewController(controller, animated: true)
        } catch let error {
            DDLogError("DetailCoordinator: could not open item detail - \(error)")
            let controller = UIAlertController(title: L10n.error, message: L10n.Items.Error.openDetail, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: L10n.ok, style: .cancel, handler: nil))
            self.navigationController.present(controller, animated: true, completion: nil)
        }
    }

    func showCollectionPicker(in library: Library, selectedKeys: Binding<Set<String>>) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }
        let state = CollectionPickerState(library: library, excludedKeys: [], selected: [])
        let handler = CollectionPickerActionHandler(dbStorage: dbStorage)
        let viewModel = ViewModel(initialState: state, handler: handler)

        // SWIFTUI BUG: - We need to call loadData here, because when we do so in `onAppear` in SwiftUI `View` we'll crash when data change
        // instantly in that function. If we delay it, the user will see unwanted animation of data on screen. If we call it here, data
        // is available immediately.
        viewModel.process(action: .loadData)

        let view = CollectionsPickerView(selectedKeys: selectedKeys,
                                         closeAction: { [weak self] in
                                             self?.navigationController.dismiss(animated: true, completion: nil)
                                         })
                                         .environmentObject(viewModel)

        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        navigationController.modalPresentationStyle = .formSheet
        self.navigationController.present(navigationController, animated: true, completion: nil)
    }
}

extension DetailCoordinator: DetailItemActionSheetCoordinatorDelegate {
    func showSortTypePicker(sortBy: Binding<ItemsSortType.Field>) {
        let view = ItemSortTypePickerView(sortBy: sortBy,
                                          closeAction: { [weak self] in
                                              self?.navigationController.dismiss(animated: true, completion: nil)
                                          })
        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        navigationController.modalPresentationStyle = .formSheet
        self.navigationController.present(navigationController, animated: true, completion: nil)
    }


    func showNoteCreation(save: @escaping (String) -> Void) {
        self.showNote(with: "", readOnly: false, save: save)
    }


    func showAttachmentPicker(save: @escaping ([URL]) -> Void) {
        let documentTypes = [String(kUTTypePDF), String(kUTTypePNG), String(kUTTypeJPEG)]
        let controller = DocumentPickerViewController(documentTypes: documentTypes, in: .import)
        controller.popoverPresentationController?.sourceView = self.navigationController.visibleViewController?.view
        controller.observable
                  .observeOn(MainScheduler.instance)
                  .subscribe(onNext: { urls in
                      save(urls)
                  })
                  .disposed(by: self.disposeBag)
        self.navigationController.present(controller, animated: true, completion: nil)
    }


    func showItemCreation(library: Library, collectionKey: String?) {
        self.showTypePicker(selected: "") { [weak self] type in
            self?.showItemDetail(for: .creation(collectionKey: collectionKey, type: type), library: library)
        }
    }
}

extension DetailCoordinator: DetailItemDetailCoordinatorDelegate {
    func showTagPicker(libraryId: LibraryIdentifier, selected: Set<String>, picked: @escaping ([Tag]) -> Void) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }

        let state = TagPickerState(libraryId: libraryId, selectedTags: selected)
        let handler = TagPickerActionHandler(dbStorage: dbStorage)

        let view = TagPickerView(saveAction: picked,
                                 dismiss: { [weak self] in
                                     self?.navigationController.dismiss(animated: true, completion: nil)
                                 })
                                 .environmentObject(ViewModel(initialState: state, handler: handler))

        let controller = UINavigationController(rootViewController: UIHostingController(rootView: view))
        controller.isModalInPresentation = true
        controller.modalPresentationStyle = .formSheet
        self.navigationController.present(controller, animated: true, completion: nil)
    }

    func showCreatorTypePicker(itemType: String, selected: String, picked: @escaping (String) -> Void) {
        let viewModel = CreatorTypePickerViewModelCreator.create(itemType: itemType, selected: selected,
                                                                 schemaController: self.controllers.schemaController)
        self.presentPicker(viewModel: viewModel, saveAction: picked)
    }

    func showTypePicker(selected: String, picked: @escaping (String) -> Void) {
        let viewModel = ItemTypePickerViewModelCreator.create(selected: selected, schemaController: self.controllers.schemaController)
        self.presentPicker(viewModel: viewModel, saveAction: picked)
    }

    func showPdf(at url: URL, key: String) {
        #if PDFENABLED
        let controller = PDFReaderViewController(viewModel: ViewModel(initialState: PDFReaderState(url: url, key: key),
                                                                      handler: PDFReaderActionHandler(annotationPreviewController: self.controllers.annotationPreviewController)))
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        self.navigationController.present(navigationController, animated: true, completion: nil)
        #endif
    }

    func showUnknownAttachment(at url: URL) {
        guard let view = self.navigationController.visibleViewController?.view else { return }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.modalPresentationStyle = .pageSheet
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = CGRect(x: (view.frame.width / 3.0),
                                                                      y: (view.frame.height * 2.0 / 3.0),
                                                                      width: (view.frame.width / 3),
                                                                      height: (view.frame.height / 3))
        self.navigationController.present(controller, animated: true, completion: nil)
    }

    func showWeb(url: URL) {
        let controller = SFSafariViewController(url: url)
        controller.modalPresentationStyle = .fullScreen
        self.navigationController.present(controller, animated: true, completion: nil)
    }

    private func presentPicker(viewModel: ViewModel<SinglePickerActionHandler>, saveAction: @escaping (String) -> Void) {
        let view = SinglePickerView(saveAction: saveAction) { [weak self] in
            self?.navigationController.dismiss(animated: true, completion: nil)
        }
        .environmentObject(viewModel)

        let controller = UINavigationController(rootViewController: UIHostingController(rootView: view))
        controller.isModalInPresentation = true
        controller.modalPresentationStyle = .formSheet
        self.navigationController.present(controller, animated: true, completion: nil)
    }
}
