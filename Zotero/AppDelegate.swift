//
//  AppDelegate.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import UIKit

import CocoaLumberjack
import SwiftUI

#if PDFENABLED
import PSPDFKit
#endif

// TODO: - remove once API support is added for debug/crash log submission
extension UIViewController {
    fileprivate func presentActivityViewController(with items: [Any], completed: @escaping () -> Void) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { (_, _, _, _) in
            completed()
        }

        var topController = self
        while let presented = topController.presentedViewController {
            topController = presented
        }
        topController = (topController as? MainViewController)?.viewControllers.last ?? topController
        controller.popoverPresentationController?.sourceView = topController.view
        topController.present(controller, animated: true, completion: nil)
    }
}

extension UIViewController: DebugLoggingCoordinator {
    func share(logs: [URL], completed: @escaping () -> Void) {
        self.presentActivityViewController(with: logs, completed: completed)
    }

    func show(error: DebugLogging.Error) {
        let message: String
        switch error {
        case .start:
            message = "Can't start debug logging."
        case .contentReading:
            message = "Can't find log files."
        }
        let controller = UIAlertController(title: "Debugging error", message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "Ok", style: .cancel, handler: nil))
        self.present(controller, animated: true, completion: nil)
    }
}

extension UIViewController: CrashReporterCoordinator {
    func report(crash: String, completed: @escaping () -> Void) {
        let controller = UIAlertController(title: "Crash report", message: "It seems you encountered a crash. Would you like to report it?", preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "No", style: .cancel, handler: { _ in
            completed()
        }))
        controller.addAction(UIAlertAction(title: "Yes", style: .default, handler: { [weak self] _ in
            controller.dismiss(animated: true) {
                self?.presentActivityViewController(with: [crash], completed: completed)
            }
        }))
        self.present(controller, animated: true, completion: nil)
    }
}

class AppDelegate: UIResponder {
    var window: UIWindow?
    var controllers: Controllers!
    private var sessionCancellable: AnyCancellable?

    // MARK: - Actions

    private func showMainScreen(isLogged: Bool, animated: Bool) {
        if !isLogged {
            let view = OnboardingView()
                            .environment(\.apiClient, self.controllers.apiClient)
                            .environment(\.sessionController, self.controllers.sessionController)
            self.show(viewController: UIHostingController(rootView: view), animated: animated)
        } else {
            let controller = MainViewController(controllers: self.controllers)
            self.show(viewController: controller, animated: animated)

            self.controllers.userControllers?.syncScheduler.syncController.setConflictPresenter(controller)
        }

        self.controllers.debugLogging.coordinator = self.window?.rootViewController
        self.controllers.crashReporter.coordinator = self.window?.rootViewController
    }

    private func show(viewController: UIViewController?, animated: Bool = false) {
        guard let window = self.window else { return }

        window.rootViewController = viewController

        guard animated else { return }

        UIView.transition(with: window, duration: 0.2, options: .transitionCrossDissolve, animations: {}, completion: { _ in })
    }

    // MARK: - Setups

    private func setupObservers() {
        self.sessionCancellable = self.controllers.sessionController.$isLoggedIn
                                                                    .receive(on: DispatchQueue.main)
                                                                    .dropFirst()
                                                                    .sink { [weak self] isLoggedIn in
                                                                        self?.showMainScreen(isLogged: isLoggedIn, animated: true)
                                                                    }
    }

    private func setupLogs() {
        #if DEBUG
        // Enable console logs only for debug mode
        DDLog.add(DDTTYLogger.sharedInstance)

        // Change to .info to enable server logging
        // Change to .warning/.error to disable server logging
        dynamicLogLevel = .info
        #else
        dynamicLogLevel = .error
        #endif
    }

    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if PDFENABLED
        if let key = Licenses.shared.pspdfkitKey {
            PSPDFKit.setLicenseKey(key)
        }
        #endif

        self.setupLogs()
        self.controllers = Controllers()

        self.setupObservers()

        self.window = UIWindow(frame: UIScreen.main.bounds)
        self.window?.makeKeyAndVisible()
        self.setupNavigationBarAppearance()

        self.showMainScreen(isLogged: self.controllers.sessionController.isLoggedIn, animated: false)

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        self.controllers.didEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        self.controllers.willEnterForeground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let controllers = self.controllers ?? Controllers()
        if let uploader = controllers.userControllers?.backgroundUploader {
            uploader.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}
