//
//  DetailCoordinator.swift
//  Zotero
//
//  Created by Michal Rentka on 12/03/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import AVKit
import MobileCoreServices
import UIKit
import SafariServices
import SwiftUI

import CocoaLumberjackSwift
import RxSwift
import SwiftyGif

#if PDFENABLED

import PSPDFKit
import PSPDFKitUI

#endif

protocol DetailPdfCoordinatorDelegate: class {
    func showComment(with text: String, imageLoader: Single<UIImage>?, save: @escaping (String) -> Void)
    func showHighlight(with text: String, imageLoader: Single<UIImage>?, save: @escaping (String) -> Void)
    func showTagPicker(libraryId: LibraryIdentifier, selected: Set<String>, picked: @escaping ([Tag]) -> Void)
    func showColorPicker(selected: String?, sender: UIButton, save: @escaping (String) -> Void)
    #if PDFENABLED
    func showCellOptions(for annotation: Annotation, sender: UIButton, viewModel: ViewModel<PDFReaderActionHandler>)
    func showSearch(pdfController: PDFViewController, sender: UIBarButtonItem, result: @escaping (SearchResult) -> Void)
    func showAnnotationPopover(viewModel: ViewModel<PDFReaderActionHandler>, sourceRect: CGRect, actionHandler: @escaping AnnotationViewControllerAction, dismissHandler: @escaping () -> Void)
    #endif
}

protocol DetailItemsCoordinatorDelegate: class {
    func showCollectionPicker(in library: Library, selectedKeys: Binding<Set<String>>)
    func showItemDetail(for type: ItemDetailState.DetailType, library: Library)
    func showNote(with text: String, readOnly: Bool, save: @escaping (String) -> Void)
    func showAddActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem)
    func showSortActions(viewModel: ViewModel<ItemsActionHandler>, button: UIBarButtonItem)
    func show(attachment: Attachment, library: Library, sourceView: UIView, sourceRect: CGRect?)
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
    func showTypePicker(selected: String, picked: @escaping (String) -> Void)
    func show(attachment: Attachment, library: Library, sourceView: UIView, sourceRect: CGRect?)
    func showWeb(url: URL)
    func showCreatorCreation(for itemType: String, saved: @escaping CreatorEditSaveAction)
    func showCreatorEditor(for creator: ItemDetailState.Creator, itemType: String, saved: @escaping CreatorEditSaveAction, deleted: @escaping CreatorEditDeleteAction)
    func showAttachmentError(_ error: Error, retryAction: @escaping () -> Void)
}

protocol DetailCreatorEditCoordinatorDelegate: class {
    func showCreatorTypePicker(itemType: String, selected: String, picked: @escaping (String) -> Void)
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
        guard let userControllers = self.controllers.userControllers else { return }
        let controller = self.createItemsViewController(collection: self.collection, library: self.library,
                                                        dbStorage: userControllers.dbStorage, fileDownloader: userControllers.fileDownloader)
        self.navigationController.setViewControllers([controller], animated: animated)
    }

    private func createItemsViewController(collection: Collection, library: Library, dbStorage: DbStorage,
                                           fileDownloader: FileDownloader) -> ItemsViewController {
        let type = self.fetchType(from: collection)
        let state = ItemsState(type: type, library: library, results: nil, sortType: .default, error: nil)
        let handler = ItemsActionHandler(dbStorage: dbStorage,
                                         fileStorage: self.controllers.fileStorage,
                                         schemaController: self.controllers.schemaController,
                                         urlDetector: self.controllers.urlDetector,
                                         fileDownloader: fileDownloader)
        return ItemsViewController(viewModel: ViewModel(initialState: state, handler: handler),
                                   controllers: self.controllers, coordinatorDelegate: self)
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

    func show(attachment: Attachment, library: Library, sourceView: UIView, sourceRect: CGRect?) {
        switch attachment.contentType {
        case .url(let url):
            self.showWeb(url: url)

        case .file(let file, let filename, let location, _),
             .snapshot(let file, let filename, _, let location):
            guard let location = location, location == .local else { return }

            let url = file.createUrl()

            switch file.mimeType {
            case "application/pdf":
                self.showPdf(at: url, key: attachment.key, library: library)
            case "text/html":
                self.showWebView(for: url)
            case _ where file.mimeType.contains("image"):
                let image = (file.mimeType == "image/gif") ? (try? Data(contentsOf: url)).flatMap({ try? UIImage(gifData: $0) }) :
                                                             UIImage(contentsOfFile: url.path)
                if let image = image {
                    self.show(image: image, title: filename)
                } else {
                    self.showUnknownAttachment(for: file, filename: filename, attachment: attachment, sourceView: sourceView, sourceRect: sourceRect)
                }
            default:
                if AVURLAsset(url: url).isPlayable {
                    self.showVideo(for: url)
                } else {
                    self.showUnknownAttachment(for: file, filename: filename, attachment: attachment, sourceView: sourceView, sourceRect: sourceRect)
                }
            }
        }
    }

    private func show(image: UIImage, title: String) {
        let controller = ImagePreviewViewController(image: image, title: title)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }

    private func showVideo(for url: URL) {
        let player = AVPlayer(url: url)
        let controller = AVPlayerViewController()
        controller.player = player
        self.topViewController.present(controller, animated: true) {
            player.play()
        }
    }

    private func showPdf(at url: URL, key: String, library: Library) {
        #if PDFENABLED
        guard let dbStorage = self.controllers.userControllers?.dbStorage,
              let userId = self.controllers.sessionController.sessionData?.userId else { return }

        let handler = PDFReaderActionHandler(dbStorage: dbStorage,
                                             annotationPreviewController: self.controllers.annotationPreviewController,
                                             htmlAttributedStringConverter: self.controllers.htmlAttributedStringConverter,
                                             schemaController: self.controllers.schemaController,
                                             fileStorage: self.controllers.fileStorage)
        let state = PDFReaderState(url: url, key: key, library: library, userId: userId)
        let controller = PDFReaderViewController(viewModel: ViewModel(initialState: state, handler: handler),
                                                 compactSize: UIDevice.current.isCompactWidth(size: self.navigationController.view.frame.size),
                                                 annotationPreviewController: self.controllers.annotationPreviewController,
                                                 pageController: self.controllers.pageController)
        controller.coordinatorDelegate = self
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        self.topViewController.present(navigationController, animated: true, completion: nil)
        #endif
    }

    private func showWebView(for url: URL) {
        let controller = WebViewController(url: url)
        let navigationController = UINavigationController(rootViewController: controller)
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }

    private func showUnknownAttachment(for file: File, filename: String, attachment: Attachment, sourceView: UIView, sourceRect: CGRect?) {
        let linkFile = Files.link(filename: filename, key: attachment.key)
        do {
            try self.controllers.fileStorage.link(file: file, to: linkFile)
            self.showUnknownAttachment(at: linkFile.createUrl(), sourceView: sourceView, sourceRect: sourceRect)
        } catch let error {
            DDLogError("DetailCoordinator: can't link file - \(error)")
            self.showUnknownAttachment(at: file.createUrl(), sourceView: sourceView, sourceRect: sourceRect)
        }
    }

    private func showUnknownAttachment(at url: URL, sourceView: UIView, sourceRect: CGRect?) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.modalPresentationStyle = .pageSheet
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = sourceRect ?? CGRect(x: (sourceView.frame.width / 3.0),
                                                                                    y: (sourceView.frame.height * 2.0 / 3.0),
                                                                                    width: (sourceView.frame.width / 3),
                                                                                    height: (sourceView.frame.height / 3))
        self.topViewController.present(controller, animated: true, completion: nil)
    }

    func showWeb(url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    fileprivate var topViewController: UIViewController {
        var controller: UIViewController = self.navigationController
        while let presentedController = controller.presentedViewController {
            controller = presentedController
        }
        return controller
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

        controller.addAction(UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil))

        self.topViewController.present(controller, animated: true, completion: nil)
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

        controller.addAction(UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil))

        self.topViewController.present(controller, animated: true, completion: nil)
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
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }

    func showItemDetail(for type: ItemDetailState.DetailType, library: Library) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage,
            let fileDownloader = self.controllers.userControllers?.fileDownloader else { return }

        do {
            let hidesBackButton: Bool
            switch type {
            case .preview:
                hidesBackButton = false
            case .creation, .duplication:
                hidesBackButton = true
            }

            let (data, attachmentErrors) = try ItemDetailDataCreator.createData(from: type,
                                                                                schemaController: self.controllers.schemaController,
                                                                                dateParser: self.controllers.dateParser,
                                                                                fileStorage: self.controllers.fileStorage,
                                                                                urlDetector: self.controllers.urlDetector,
                                                                                doiDetector: FieldKeys.Item.isDoi)
            let state = ItemDetailState(type: type, library: library, userId: Defaults.shared.userId, data: data, attachmentErrors: attachmentErrors)
            let handler = ItemDetailActionHandler(apiClient: self.controllers.apiClient,
                                                  fileStorage: self.controllers.fileStorage,
                                                  dbStorage: dbStorage,
                                                  schemaController: self.controllers.schemaController,
                                                  dateParser: self.controllers.dateParser,
                                                  urlDetector: self.controllers.urlDetector,
                                                  fileDownloader: fileDownloader)
            let viewModel = ViewModel(initialState: state, handler: handler)

            let controller = ItemDetailViewController(viewModel: viewModel, controllers: self.controllers)
            controller.coordinatorDelegate = self
            controller.navigationItem.setHidesBackButton(hidesBackButton, animated: false)
            self.navigationController.pushViewController(controller, animated: true)
        } catch let error {
            DDLogError("DetailCoordinator: could not open item detail - \(error)")
            let controller = UIAlertController(title: L10n.error, message: L10n.Items.Error.openDetail, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: L10n.ok, style: .cancel, handler: nil))
            self.topViewController.present(controller, animated: true, completion: nil)
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
                                            self?.topViewController.dismiss(animated: true, completion: nil)
                                         })
                                         .environmentObject(viewModel)

        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        navigationController.modalPresentationStyle = .formSheet
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }
}

extension DetailCoordinator: DetailItemActionSheetCoordinatorDelegate {
    func showSortTypePicker(sortBy: Binding<ItemsSortType.Field>) {
        let view = ItemSortTypePickerView(sortBy: sortBy,
                                          closeAction: { [weak self] in
                                              self?.topViewController.dismiss(animated: true, completion: nil)
                                          })
        let navigationController = UINavigationController(rootViewController: UIHostingController(rootView: view))
        navigationController.isModalInPresentation = true
        navigationController.modalPresentationStyle = .formSheet
        self.topViewController.present(navigationController, animated: true, completion: nil)
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
        self.topViewController.present(controller, animated: true, completion: nil)
    }


    func showItemCreation(library: Library, collectionKey: String?) {
        self.showTypePicker(selected: "") { [weak self] type in
            self?.showItemDetail(for: .creation(collectionKey: collectionKey, type: type), library: library)
        }
    }
}

extension DetailCoordinator: DetailItemDetailCoordinatorDelegate {
    func showAttachmentError(_ error: Error, retryAction: @escaping () -> Void) {
        let controller = UIAlertController(title: L10n.error, message: "\(error)", preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: L10n.ok, style: .cancel, handler: nil))
        controller.addAction(UIAlertAction(title: L10n.retry, style: .default, handler: { _ in
            retryAction()
        }))
        self.topViewController.present(controller, animated: true, completion: nil)
    }

    func showTagPicker(libraryId: LibraryIdentifier, selected: Set<String>, picked: @escaping ([Tag]) -> Void) {
        guard let dbStorage = self.controllers.userControllers?.dbStorage else { return }

        let state = TagPickerState(libraryId: libraryId, selectedTags: selected)
        let handler = TagPickerActionHandler(dbStorage: dbStorage)
        let viewModel = ViewModel(initialState: state, handler: handler)
        let tagController = TagPickerViewController(viewModel: viewModel, saveAction: picked)

        let controller = UINavigationController(rootViewController: tagController)
        controller.isModalInPresentation = true
        controller.modalPresentationStyle = .formSheet
        self.topViewController.present(controller, animated: true, completion: nil)
    }

    func showCreatorCreation(for itemType: String, saved: @escaping CreatorEditSaveAction) {
        guard let schema = self.controllers.schemaController.creators(for: itemType)?.first(where: { $0.primary }),
              let localized = self.controllers.schemaController.localized(creator: schema.creatorType) else { return }
        let creator = ItemDetailState.Creator(type: schema.creatorType, primary: schema.primary, localizedType: localized)
        self._showCreatorEditor(for: creator, itemType: itemType, saved: saved, deleted: nil)
    }

    func showCreatorEditor(for creator: ItemDetailState.Creator, itemType: String, saved: @escaping CreatorEditSaveAction, deleted: @escaping CreatorEditDeleteAction) {
        self._showCreatorEditor(for: creator, itemType: itemType, saved: saved, deleted: deleted)
    }

    private func _showCreatorEditor(for creator: ItemDetailState.Creator, itemType: String, saved: @escaping CreatorEditSaveAction, deleted: CreatorEditDeleteAction?) {
        let state = CreatorEditState(itemType: itemType, creator: creator)
        let handler = CreatorEditActionHandler(schemaController: self.controllers.schemaController)
        let viewModel = ViewModel(initialState: state, handler: handler)
        let controller = CreatorEditViewController(viewModel: viewModel, saved: saved, deleted: deleted)
        controller.coordinatorDelegate = self

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.isModalInPresentation = true
        navigationController.modalPresentationStyle = .formSheet
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }

    func showTypePicker(selected: String, picked: @escaping (String) -> Void) {
        let viewModel = ItemTypePickerViewModelCreator.create(selected: selected, schemaController: self.controllers.schemaController)
        self.presentPicker(viewModel: viewModel, requiresSaveButton: false, saveAction: picked)
    }

    private func presentPicker(viewModel: ViewModel<SinglePickerActionHandler>, requiresSaveButton: Bool, saveAction: @escaping (String) -> Void) {
        let view = SinglePickerView(requiresSaveButton: requiresSaveButton, requiresCancelButton: true, saveAction: saveAction) { [weak self] in
            self?.topViewController.dismiss(animated: true, completion: nil)
        }
        .environmentObject(viewModel)

        let controller = UINavigationController(rootViewController: UIHostingController(rootView: view))
        controller.isModalInPresentation = true
        controller.modalPresentationStyle = .formSheet
        self.topViewController.present(controller, animated: true, completion: nil)
    }
}

extension DetailCoordinator: DetailCreatorEditCoordinatorDelegate {
    func showCreatorTypePicker(itemType: String, selected: String, picked: @escaping (String) -> Void) {
        let navigationController = self.topViewController as? UINavigationController

        let viewModel = CreatorTypePickerViewModelCreator.create(itemType: itemType, selected: selected,
                                                                 schemaController: self.controllers.schemaController)
        let view = SinglePickerView(requiresSaveButton: false, requiresCancelButton: false, saveAction: picked) { [weak navigationController] in
            navigationController?.popViewController(animated: true)
        }
        .environmentObject(viewModel)

        let controller = UIHostingController(rootView: view)
        navigationController?.pushViewController(controller, animated: true)
    }
}

extension DetailCoordinator: DetailPdfCoordinatorDelegate {
    func showComment(with text: String, imageLoader: Single<UIImage>?, save: @escaping (String) -> Void) {
        self.showAnnotationPreviewEditor(with: text, imageLoader: imageLoader, converter: self.controllers.htmlAttributedStringConverter, save: save)
    }

    func showHighlight(with text: String, imageLoader: Single<UIImage>?, save: @escaping (String) -> Void) {
        self.showAnnotationPreviewEditor(with: text, imageLoader: imageLoader, converter: nil, save: save)
    }

    private func showAnnotationPreviewEditor(with text: String, imageLoader: Single<UIImage>?,
                                             converter: HtmlAttributedStringConverter?, save: @escaping (String) -> Void) {
        let controller = AnnotationPreviewCommentEditorViewController(text: text, imageLoader: imageLoader, converter: converter, saveAction: save)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.isModalInPresentation = true
        self.topViewController.present(navigationController, animated: true, completion: nil)
    }

    func showColorPicker(selected: String?, sender: UIButton, save: @escaping (String) -> Void) {
        let view = ColorPicker(selected: selected, selectionAction: { [weak self] color in
            save(color)
            self?.topViewController.dismiss(animated: true, completion: nil)
        })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .popover : .formSheet
        controller.popoverPresentationController?.sourceView = sender
        controller.preferredContentSize = CGSize(width: 322, height: 74)
        self.topViewController.present(controller, animated: true, completion: nil)
    }

    #if PDFENABLED
    func showAnnotationPopover(viewModel: ViewModel<PDFReaderActionHandler>, sourceRect: CGRect, actionHandler: @escaping AnnotationViewControllerAction, dismissHandler: @escaping () -> Void) {
        let controller = AnnotationViewController(viewModel: viewModel)
        controller.performAction = actionHandler
        controller.willDismiss = dismissHandler
        controller.modalPresentationStyle = .popover
        controller.popoverPresentationController?.sourceView = self.navigationController.presentedViewController?.view
        controller.popoverPresentationController?.sourceRect = sourceRect
        self.topViewController.present(controller, animated: true, completion: nil)
    }
    
    func showCellOptions(for annotation: Annotation, sender: UIButton, viewModel: ViewModel<PDFReaderActionHandler>) {
        let controller = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        controller.popoverPresentationController?.sourceView = sender

        controller.addAction(UIAlertAction(title: L10n.delete, style: .destructive, handler: { [weak self, weak viewModel] _ in
            guard let `self` = self, let viewModel = viewModel else { return }
            self.confirmAnnotationDeletion(annotation, viewModel: viewModel)
        }))

        controller.addAction(UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil))

        /// Pdf controller is presented modally, alert needs to be presented on top of it
        var presented: UIViewController = self.navigationController
        while let ctrl = presented.presentedViewController {
            presented = ctrl
        }
        presented.present(controller, animated: true, completion: nil)
    }

    private func confirmAnnotationDeletion(_ annotation: Annotation, viewModel: ViewModel<PDFReaderActionHandler>) {
        let controller = UIAlertController(title: L10n.warning, message: "Do you really want to delete this annotation?", preferredStyle: .alert)

        controller.addAction(UIAlertAction(title: L10n.yes, style: .destructive, handler: { [weak viewModel] _ in
            viewModel?.process(action: .removeAnnotation(annotation))
        }))

        controller.addAction(UIAlertAction(title: L10n.no, style: .cancel, handler: nil))

        self.topViewController.present(controller, animated: true, completion: nil)
    }

    func showSearch(pdfController: PDFViewController, sender: UIBarButtonItem, result: @escaping (SearchResult) -> Void) {
        let viewController = PDFSearchViewController(controller: pdfController, searchSelected: result)
        viewController.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .popover : .formSheet
        viewController.popoverPresentationController?.barButtonItem = sender
        self.topViewController.present(viewController, animated: true, completion: nil)
    }
    #endif
}
