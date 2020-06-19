//
//  SyncToolbarController.swift
//  Zotero
//
//  Created by Michal Rentka on 28/01/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

class SyncToolbarController {
    private static let finishVisibilityTime: RxTimeInterval = .seconds(2)
    private unowned let viewController: UINavigationController
    private let disposeBag: DisposeBag

    private var pendingErrors: [Error]?

    init(parent: UINavigationController, progressObservable: PublishSubject<SyncProgress>) {
        self.viewController = parent
        self.disposeBag = DisposeBag()

        progressObservable.observeOn(MainScheduler.instance)
                          .subscribe(onNext: { [weak self] progress in
                              guard let `self` = self else { return }
                              self.update(progress: progress, in: self.viewController)
                          })
                          .disposed(by: self.disposeBag)
    }

    // MARK: - Actions

    private func update(progress: SyncProgress, in controller: UINavigationController) {
        self.set(progress: progress, in: controller)

        if controller.isToolbarHidden {
            controller.setToolbarHidden(false, animated: true)
        }

        if case .aborted(let error) = progress {
            self.pendingErrors = [error]
        } else if case .finished(let errors) = progress {
            if errors.isEmpty {
                self.hideToolbarWithDelay(in: controller)
            } else {
                self.pendingErrors = errors
            }
        }
    }

    private func showErrorAlert(with errors: [Error]) {
        let controller = UIAlertController(title: L10n.error, message: self.alertMessage(from: errors), preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: L10n.ok, style: .cancel, handler: { [weak self] _ in
            self?.pendingErrors = nil
        }))
        self.viewController.present(controller, animated: true, completion: nil)
        self.viewController.setToolbarHidden(true, animated: true)
    }

    private func alertMessage(from errors: [Error]) -> String {
        return "Unknown error"
    }

    private func hideToolbarWithDelay(in controller: UINavigationController) {
        Single<Int>.timer(SyncToolbarController.finishVisibilityTime,
                          scheduler: MainScheduler.instance)
                   .subscribe(onSuccess: { [weak controller] _ in
                       controller?.setToolbarHidden(true, animated: true)
                   })
                   .disposed(by: self.disposeBag)
    }

    private func set(progress: SyncProgress, in controller: UINavigationController) {
        let item = UIBarButtonItem(customView: self.toolbarView(with: self.text(for: progress)))
        controller.toolbar.setItems([item], animated: false)
    }

    private func toolbarView(with text: String) -> UIView {
        let textColor: UIColor = self.viewController.traitCollection.userInterfaceStyle == .light ? .black : .white
        let button = UIButton(frame: UIScreen.main.bounds)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.numberOfLines = 2
        button.setTitleColor(textColor, for: .normal)
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.setTitle(text, for: .normal)

        button.rx
              .tap
              .observeOn(MainScheduler.instance)
              .subscribe(onNext: { [weak self] _ in
                  guard let errors = self?.pendingErrors else { return }
                  self?.showErrorAlert(with: errors)
              })
              .disposed(by: self.disposeBag)

        return button
    }

    private func text(for progress: SyncProgress) -> String {
        switch progress {
        case .starting:
            return L10n.SyncToolbar.starting
        case .groups(let progress):
            if let progress = progress {
                return L10n.SyncToolbar.groupsWithData(progress.completed, progress.total)
            }
            return L10n.SyncToolbar.groups
        case .library(let name):
            return L10n.SyncToolbar.library(name)
        case .object(let object, let progress, let library):
            if let progress = progress {
                return L10n.SyncToolbar.objectWithData(self.name(for: object), progress.completed, progress.total, library)
            }
            return L10n.SyncToolbar.object(self.name(for: object), library)
        case .changes(let progress):
            return L10n.SyncToolbar.writes(progress.completed, progress.total)
        case .uploads(let progress):
        return L10n.SyncToolbar.uploads(progress.completed, progress.total)
        case .finished(let errors):
            if errors.isEmpty {
                return L10n.SyncToolbar.finished
            }
            let issues = errors.count == 1 ? L10n.SyncToolbar.oneError : L10n.SyncToolbar.multipleErrors(errors.count)
            return L10n.SyncToolbar.finishedWithErrors(issues)
        case .deletions(let name):
            return  L10n.SyncToolbar.deletion(name)
        case .aborted(let error):
            return L10n.SyncToolbar.aborted(error.localizedDescription)
        }
    }

    private func name(for object: SyncObject) -> String {
        switch object {
        case .collection:
            return L10n.SyncToolbar.Object.collections
        case .item, .trash:
            return L10n.SyncToolbar.Object.items
        case .search:
            return L10n.SyncToolbar.Object.searches
        }
    }
}
