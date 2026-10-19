//
//  LicensesViewController.swift
//  Delta
//
//  Created by Riley Testut on 9/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI

extension LicensesViewController
{
    struct ViewRepresentable: UIViewControllerRepresentable
    {
        func makeUIViewController(context: Context) -> LicensesViewController
        {
            let storyboard = UIStoryboard(name: "Settings", bundle: .main)
            let viewController = storyboard.instantiateViewController(withIdentifier: "licenses") as! LicensesViewController
            return viewController
        }

        func updateUIViewController(_ uiViewController: LicensesViewController, context: Context)
        {
            let parentViewController = uiViewController.parent ?? uiViewController
            parentViewController.navigationItem.title = uiViewController.navigationItem.title // Fixes title not appearing in SwiftUI NavigationStack
        }
    }
}

class LicensesViewController: UIViewController
{
    private var _didAppear = false
    
    @IBOutlet private var textView: UITextView!

    override func viewDidLoad()
    {
        super.viewDidLoad()
        self.textView.accessibilityIdentifier = "bound.software-licenses-text"
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
        
        // Fix incorrect initial offset on iPhone SE.
        self.textView.contentOffset.y = 0
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        _didAppear = true
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        // The text view already starts inside the safe area. Apply only the
        // remaining margin so landscape does not count the side insets twice.
        self.textView.textContainerInset.left = max(0, self.view.layoutMargins.left - self.textView.frame.minX)
        self.textView.textContainerInset.right = max(0, self.view.layoutMargins.right - (self.view.bounds.maxX - self.textView.frame.maxX))
        self.textView.textContainer.lineFragmentPadding = 0
        
        if !_didAppear
        {
            // Fix incorrect initial offset on iPhone SE.
            self.textView.contentOffset.y = 0
        }
    }
}
