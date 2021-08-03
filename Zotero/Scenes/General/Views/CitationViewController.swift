//
//  CitationViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 15.06.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit
import WebKit

import RxSwift

final class CitationViewController: UIViewController {
    @IBOutlet private weak var webView: WKWebView!
    @IBOutlet private weak var locatorButton: UIButton!
    @IBOutlet private weak var locatorTextField: UITextField!
    @IBOutlet private weak var omitAuthorTitle: UILabel!
    @IBOutlet private weak var omitAuthorSwitch: UISwitch!
    @IBOutlet private weak var previewTitleLabel: UILabel!
    @IBOutlet private weak var previewContainer: UIView!
    @IBOutlet private weak var previewLabel: UILabel!
    @IBOutlet private weak var activityIndicatorContainer: UIView!
    @IBOutlet private weak var activityIndicator: UIActivityIndicatorView!

    private static let width: CGFloat = 500
    private let viewModel: ViewModel<CitationActionHandler>
    private let disposeBag: DisposeBag

    // MARK: - Lifecycle

    init(viewModel: ViewModel<CitationActionHandler>) {
        self.viewModel = viewModel
        self.disposeBag = DisposeBag()
        super.init(nibName: "CitationViewController", bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.previewTitleLabel.text = L10n.Citation.preview
        self.omitAuthorTitle.text = L10n.Citation.omitAuthor
        self.locatorButton.setTitle(self.localized(locator: self.viewModel.state.locator), for: .normal)
        self.setupPreview()
        self.setupNavigationBar()
        self.setupObserving()

        self.viewModel.process(action: .preload(self.webView))
    }

    deinit {
        self.viewModel.process(action: .cleanup)
    }

    // MARK: - Actions

    private func update(state: CitationState) {
        if state.changes.contains(.preview) {
            self.previewLabel.text = state.preview
        }

        if state.changes.contains(.locator) {
            self.locatorButton.setTitle(self.localized(locator: state.locator), for: .normal)
        }

        if state.changes.contains(.loading) {
            self.activityIndicatorContainer.isHidden = state.webView != nil
            self.previewContainer.isHidden = state.webView == nil
            self.locatorButton.isEnabled = state.webView != nil
            self.locatorTextField.isEnabled = state.webView != nil
            self.navigationItem.rightBarButtonItem?.isEnabled = state.webView != nil
        }

        if let error = state.error {
            // TODO: - show error
        }

        if state.changes.contains(.preview) || state.changes.contains(.loading) {
            self.updatePreferredContentSize()
        }
    }

    // MARK: - Helpers

    private func localized(locator: String) -> String {
        return NSLocalizedString("citation.locator.\(locator)", comment: "")
    }

    private func updatePreferredContentSize() {
        let size = self.view.systemLayoutSizeFitting(CGSize(width: CitationViewController.width, height: .greatestFiniteMagnitude))
        self.preferredContentSize = size
        self.navigationController?.preferredContentSize = size
    }

    // MARK: - Setups

    private func setupPreview() {
        self.previewContainer.layer.cornerRadius = 4
        self.previewContainer.layer.masksToBounds = true
    }

    private func setupNavigationBar() {
        let cancel = UIBarButtonItem(title: L10n.cancel, style: .plain, target: nil, action: nil)
        cancel.rx.tap.subscribe(onNext: { [weak self] in
            self?.navigationController?.presentingViewController?.dismiss(animated: true, completion: nil)
        })
        .disposed(by: self.disposeBag)
        self.navigationItem.leftBarButtonItem = cancel

        let copy = UIBarButtonItem(title: L10n.copy, style: .done, target: nil, action: nil)
        copy.rx.tap.subscribe(onNext: { [weak self] in
            self?.viewModel.process(action: .copy)
            self?.navigationController?.presentingViewController?.dismiss(animated: true, completion: nil)
        })
        .disposed(by: self.disposeBag)
        self.navigationItem.rightBarButtonItem = copy
    }

    private func setupObserving() {
        self.viewModel.stateObservable
                      .subscribe(with: self, onNext: { `self`, state in
                          self.update(state: state)
                      })
                      .disposed(by: self.disposeBag)

        self.locatorTextField.rx.controlEvent(.editingChanged).flatMap({ Observable.just(self.locatorTextField.text ?? "") })
                             .debounce(.milliseconds(150), scheduler: MainScheduler.instance)
                             .subscribe(onNext: { [weak self] value in
                                 self?.viewModel.process(action: .setLocatorValue(value))
                             })
                             .disposed(by: self.disposeBag)

        self.omitAuthorSwitch.rx.controlEvent(.valueChanged)
                                .subscribe(onNext: { [weak self] _ in
                                    guard let `self` = self else { return }
                                    self.viewModel.process(action: .setOmitAuthor(self.omitAuthorSwitch.isOn))
                                })
                                .disposed(by: self.disposeBag)
    }
}
