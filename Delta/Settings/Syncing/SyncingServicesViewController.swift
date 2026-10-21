//
//  SyncingServicesViewController.swift
//  Delta
//
//  Created by Riley Testut on 6/27/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI

import Harmony

import Roxas

extension SyncingServicesViewController
{
    struct ViewRepresentable: UIViewControllerRepresentable
    {
        func makeUIViewController(context: Context) -> SyncingServicesViewController
        {
            let storyboard = UIStoryboard(name: "Settings", bundle: .main)
            let viewController = storyboard.instantiateViewController(withIdentifier: "syncingServices") as! SyncingServicesViewController
            return viewController
        }

        func updateUIViewController(_ uiViewController: SyncingServicesViewController, context: Context)
        {
            let parentViewController = uiViewController.parent ?? uiViewController
            parentViewController.navigationItem.title = uiViewController.navigationItem.title // Fixes title not appearing in SwiftUI NavigationStack
        }
    }
}

extension SyncingServicesViewController
{
    enum Section: Int, CaseIterable
    {
        case syncing
        case service
        case account
        case authenticate
    }
    
    enum AccountRow: Int, CaseIterable
    {
        case name
        case emailAddress
    }
}

class SyncingServicesViewController: UITableViewController
{
    @IBOutlet private var syncingEnabledSwitch: UISwitch!
    private var activityIndicatorView: UIActivityIndicatorView!
    
    private var selectedSyncingService = SyncManager.currentBoundService
    private var isDropboxConnected: Bool {
        SyncManager.shared.coordinator?.isAuthenticated == true && SyncManager.shared.coordinator?.account != nil
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.activityIndicatorView = UIActivityIndicatorView(style: .medium)
        self.activityIndicatorView.hidesWhenStopped = true
        
        let barButtonItem = UIBarButtonItem(customView: self.activityIndicatorView)
        self.navigationItem.rightBarButtonItem = barButtonItem
        
        self.syncingEnabledSwitch.onTintColor = .deltaPurple
        self.syncingEnabledSwitch.isOn = (self.selectedSyncingService != nil)
        NotificationCenter.default.addObserver(self, selector: #selector(boundAccountChanged(_:)),
            name: BoundFriendAccount.sessionDidChangeNotification, object: nil)
    }

    @objc private func boundAccountChanged(_ notification: Notification) {
        guard notification.object as? BoundFriendAccount === BoundFriendAccount.shared else { return }
        selectedSyncingService = SyncManager.currentBoundService
        syncingEnabledSwitch.setOn(selectedSyncingService != nil, animated: true)
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
}

private extension SyncingServicesViewController
{
    @IBAction func toggleSyncing(_ sender: UISwitch)
    {
        if sender.isOn
        {
            let service = SyncManager.availableBoundServices.first(where: SyncManager.isServiceConfigured)
            guard let service else {
                sender.setOn(false, animated: true)
                self.tableView.reloadData()
                self.presentProviderConfigurationAlert()
                return
            }
            self.changeService(to: service)
        }
        else
        {
            if SyncManager.shared.coordinator?.account != nil
            {
                let alertController = UIAlertController(title: NSLocalizedString("Disable Syncing?", comment: ""), message: NSLocalizedString("Enabling syncing again later may result in conflicts that must be resolved manually.", comment: ""), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { (action) in
                    sender.setOn(true, animated: true)
                })
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Disable", comment: ""), style: .default) { (action) in
                    self.changeService(to: nil)
                })
                self.present(alertController, animated: true, completion: nil)
            }
            else
            {
                self.changeService(to: nil)
            }
        }
    }
    
    func changeService(to service: SyncManager.Service?)
    {
        if let service,
           !SyncManager.isServiceConfigured(service) {
            self.presentProviderConfigurationAlert()
            return
        }

        SyncManager.shared.reset(for: service) { (result) in
            DispatchQueue.main.async {
                do
                {
                    try result.get()
                    
                    let previousService = self.selectedSyncingService
                    self.selectedSyncingService = service
                    
                    // Same check as below when showing Sign In or Sign Out.
                    if self.isDropboxConnected
                    {
                        // Authenticated, so assign syncingService.
                        Settings.syncingService = service
                        SyncManager.shared.sync()
                    }
                    else
                    {
                        // Set to non-nil if we later authenticate.
                        Settings.syncingService = nil
                    }
                                        
                    if (previousService == nil && service != nil) || (previousService != nil && service == nil)
                    {
                        self.tableView.reloadSections(IndexSet(integersIn: Section.service.rawValue ... Section.authenticate.rawValue), with: .fade)
                    }
                    else
                    {
                        self.tableView.reloadData()
                    }
                }
                catch
                {
                    if self.selectedSyncingService == nil {
                        self.syncingEnabledSwitch.setOn(false, animated: true)
                        self.tableView.reloadData()
                    }
                    let alertController = UIAlertController(title: NSLocalizedString("Unable to Change Syncing Service", comment: ""), error: error)
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }

    func manageDropboxConnection()
    {
        let identity = BoundFriendAccount.shared.session
        let alert = UIAlertController(title: "Dropbox Connection",
            message: "Disconnect this device to pause its sync, or unlink Dropbox from your Bound account on all devices. Dropbox files and local games are kept.", preferredStyle: .alert)
        alert.addAction(.cancel)
        func disconnect(unlink: Bool) {
            guard let identity, identity.isSameSession(as: BoundFriendAccount.shared.session) else { return }
            self.activityIndicatorView.startAnimating()
            SyncManager.shared.deauthenticate { result in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        defer { self.activityIndicatorView.stopAnimating(); self.tableView.reloadData() }
                        do {
                            try result.get()
                            guard identity.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundDropboxOAuth.Failure.changed }
                            Settings.syncingService = nil
                            self.selectedSyncingService = nil
                            self.syncingEnabledSwitch.setOn(false, animated: true)
                            if unlink { try await BoundDropboxOAuth.shared.unlink() }
                        } catch {
                            let failure = UIAlertController(title: unlink ? "Unable to Unlink Dropbox" : "Unable to Disconnect", error: error)
                            self.present(failure, animated: true)
                        }
                    }
                }
            }
        }
        alert.addAction(UIAlertAction(title: "Disconnect This Device", style: .default) { _ in disconnect(unlink: false) })
        alert.addAction(UIAlertAction(title: "Unlink Dropbox Everywhere", style: .destructive) { _ in disconnect(unlink: true) })
        self.present(alert, animated: true)
    }

    func presentProviderConfigurationAlert()
    {
        let unavailable = SyncManager.availableBoundServices.filter { !SyncManager.isServiceConfigured($0) }
            .map(\.localizedName).joined(separator: ", ")
        let alert = UIAlertController(
            title: NSLocalizedString("Cloud Sync Not Configured", comment: ""),
            message: String(format: NSLocalizedString("Sign-in is not configured for %@ in this Bound app yet.", comment: ""), unavailable),
            preferredStyle: .alert)
        alert.addAction(.init(title: UIAlertAction.ok.title, style: .default))
        self.present(alert, animated: true)
    }
}

private extension SyncingServicesViewController
{
    func isSectionHidden(_ section: Section) -> Bool
    {
        switch section
        {
        case .service: return false
        case .account: return !self.syncingEnabledSwitch.isOn || !self.isDropboxConnected
        case .authenticate: return !self.syncingEnabledSwitch.isOn
        default: return false
        }
    }
}

extension SyncingServicesViewController
{
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        
        switch Section.allCases[indexPath.section]
        {
        case .syncing:
            cell.textLabel?.text = NSLocalizedString("Syncing", comment: "")
            
        case .service:
            let service = SyncManager.availableBoundServices[indexPath.row]
            cell.accessoryType = (service == self.selectedSyncingService) ? .checkmark : .none
            if !SyncManager.isServiceConfigured(service) {
                cell.textLabel?.text = "\(service.localizedName) — \(NSLocalizedString("Not configured", comment: ""))"
                cell.textLabel?.textColor = .secondaryLabel
            } else {
                cell.textLabel?.text = service.localizedName
                cell.textLabel?.textColor = .label
            }
            
        case .account:
            guard let account = SyncManager.shared.coordinator?.account else { return cell }
            
            let row = AccountRow(rawValue: indexPath.row)!
            switch row
            {
            case .name: cell.textLabel?.text = account.name
            case .emailAddress: cell.textLabel?.text = account.emailAddress
            }
            
        case .authenticate:
            if self.isDropboxConnected
            {
                cell.textLabel?.textColor = .red
                cell.textLabel?.text = NSLocalizedString("Manage Dropbox Connection", comment: "")
            }
            else
            {
                cell.textLabel?.textColor = .deltaPurple
                cell.textLabel?.text = NSLocalizedString("Connect Dropbox", comment: "")
            }
        }
        
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
    {
        return nil
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        switch Section.allCases[indexPath.section]
        {
        case .syncing: break
            
        case .service:
            let syncingService = SyncManager.availableBoundServices[indexPath.row]
            if !SyncManager.isServiceConfigured(syncingService) {
                self.presentProviderConfigurationAlert()
                tableView.deselectRow(at: indexPath, animated: true)
                return
            }
            guard syncingService != self.selectedSyncingService else { return }
            self.syncingEnabledSwitch.setOn(true, animated: true)
            
            if SyncManager.shared.coordinator?.account != nil
            {
                let alertController = UIAlertController(title: NSLocalizedString("Are you sure you want to change sync services?", comment: ""), message: NSLocalizedString("Switching back later may result in conflicts that must be resolved manually.", comment: ""), preferredStyle: .alert)
                alertController.addAction(.cancel)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Change Sync Service", comment: ""), style: .destructive, handler: { (action) in
                    self.changeService(to: syncingService)
                }))
                
                self.present(alertController, animated: true, completion: nil)
            }
            else
            {
                self.changeService(to: syncingService)
            }
            
        case .account: break
            
        case .authenticate:            
            if self.isDropboxConnected
            {
                self.manageDropboxConnection()
            }
            else
            {
                self.activityIndicatorView.startAnimating()
                
                SyncManager.shared.authenticate(presentingViewController: self) { (result) in
                    DispatchQueue.main.async {
                        do
                        {
                            _ = try result.get()
                            self.tableView.reloadData()
                            
                            Settings.syncingService = self.selectedSyncingService
                            SyncManager.shared.sync()
                        }
                        catch GeneralError.cancelled.self
                        {
                            // Ignore
                        }
                        catch
                        {
                            let alertController = UIAlertController(title: NSLocalizedString("Unable to Connect Dropbox", comment: ""), error: error)
                            self.present(alertController, animated: true, completion: nil)
                        }
                        
                        self.activityIndicatorView.stopAnimating()
                    }
                }
            }
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        let section = Section.allCases[section]
        
        switch section
        {
        case let section where self.isSectionHidden(section): return 0
        case .service: return SyncManager.availableBoundServices.count
        case .account where SyncManager.shared.coordinator?.account?.emailAddress == nil: return 1
        default: return super.tableView(tableView, numberOfRowsInSection: section.rawValue)
        }
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
    {
        let section = Section.allCases[section]
        
        if self.isSectionHidden(section)
        {
            return nil
        }
        else
        {
            return super.tableView(tableView, titleForHeaderInSection: section.rawValue)
        }
    }
    
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat
    {
        let section = Section.allCases[section]
        
        if self.isSectionHidden(section)
        {
            return 1
        }
        else
        {
            return super.tableView(tableView, heightForHeaderInSection: section.rawValue)
        }
    }
    
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat
    {
        let section = Section.allCases[section]
        
        if self.isSectionHidden(section)
        {
            return 1
        }
        else
        {
            return super.tableView(tableView, heightForFooterInSection: section.rawValue)
        }
    }
}
