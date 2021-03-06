//
//  InAppPurchase.swift
//
//
//  Created by Iridescent on 30/04/2020.
//

import Foundation
import StoreKit


public class InAppPurchase: NSObject, InAppPurchaseLib {
    /// InAppPurchaseLib version number.
    internal static let versionNumber = "1.0.2"
    /// The initialize function has been called.
    internal static var initialized: Bool {
        return !iapProducts.isEmpty && iapPurchaseDelegate != nil && validatorUrlString != nil
    }
    /// Callbacks that are waiting for the refresh.
    private static var refreshCallbacks: Array<IAPRefreshCallback> = []
    /// The date of the last refresh.
    private static var lastRefreshDate: Date? = nil
    
    
    /* MARK: - Properties */
    public static var iapProducts: Array<IAPProduct> = []
    public static var iapPurchaseDelegate: IAPPurchaseDelegate? = nil
    public static var validatorUrlString: String? = nil
    public static var applicationUsername: String? = nil
    
    
    /* MARK: - Main methods */
    // Start observing the payment queue, as soon as possible, and refresh Product list and user Receipt.
    public static func initialize(iapProducts: Array<IAPProduct>, iapPurchaseDelegate: IAPPurchaseDelegate, validatorUrlString: String, applicationUsername: String?) {
        
        InAppPurchase.iapProducts = iapProducts
        InAppPurchase.iapPurchaseDelegate = iapPurchaseDelegate
        InAppPurchase.validatorUrlString = validatorUrlString
        InAppPurchase.applicationUsername = applicationUsername
        
        refresh(callback: {_ in })
        IAPTransactionObserver.shared.start()
    }
    
    // Stop observing the payment queue, when the application will terminate, for proper cleanup.
    public static func stop() {
        IAPTransactionObserver.shared.stop()
    }
    
    // Refresh Product list and user Receipt.
    public static func refresh(callback: @escaping IAPRefreshCallback) {
        if !initialized {
            callback(IAPRefreshResult(state: .failed, iapError: IAPError(code: .libraryNotInitialized)))
            return
        }
        
        let refreshInterval: TimeInterval = IAPReceiptService.shared.refreshRequired() ? 60 : 3600 // every minute if refresh is required, every hour otherwise.
        if lastRefreshDate != nil && lastRefreshDate!.addingTimeInterval(refreshInterval) > Date() {
            callback(IAPRefreshResult(state: .skipped)) // Do not refresh again if the last one is not far enough.
            return
        }
        
        refreshCallbacks.append(callback) // Add the callback to the queue.
        if refreshCallbacks.count > 1 { return } // Refresh is already running.
        
        // Now we can start to refresh!
        var refreshProductResult: IAPRefreshResult? = nil
        var refreshReceiptResult: IAPRefreshResult? = nil
        
        let asyncGroup = DispatchGroup()
        if IAPProductService.shared.getProducts().isEmpty { // Load products before receipt.
            asyncGroup.enter()
            IAPProductService.shared.refresh(callback: { result in
                refreshProductResult = result
                IAPReceiptService.shared.refresh(callback: { result in
                    refreshReceiptResult = result
                    asyncGroup.leave()
                })
            })
        } else { // Refresh products and receipt at the same time.
            asyncGroup.enter()
            asyncGroup.enter()
            IAPProductService.shared.refresh(callback: { result in
                refreshProductResult = result
                asyncGroup.leave()
            })
            IAPReceiptService.shared.refresh(callback: { result in
                refreshReceiptResult = result
                asyncGroup.leave()
            })
        }
        
        asyncGroup.notify(queue: .main) {
            var result = IAPRefreshResult(state: .succeeded)
            if refreshProductResult?.state == .succeeded && refreshReceiptResult?.state == .succeeded {
                result.addedPurchases = refreshReceiptResult!.addedPurchases
                result.updatedPurchases = refreshReceiptResult!.updatedPurchases
            } else {
                result.state = .failed
                result.iapError = refreshProductResult?.state != .succeeded ? IAPError(code: .refreshProductsFailed) : refreshReceiptResult?.iapError
            }
            
            lastRefreshDate = Date()
            let tmp = refreshCallbacks
            refreshCallbacks = []
            for refreshCallback in tmp {
                refreshCallback(result)
            }
        }
    }
    
    
    /* MARK: - Products information */
    // Returns all products retrieved from the App Store.
    public static func getProducts() -> Array<SKProduct> {
        return IAPProductService.shared.getProducts()
    }
    
    // Gets the product by its identifier from the list of products retrieved from the App Store.
    public static func getProductBy(identifier: String) -> SKProduct? {
        return IAPProductService.shared.getProductBy(identifier: identifier)
    }
    
    
    /* MARK: - Purchasing and Restoring */
    // Request a Payment from the App Store.
    public static func purchase(productIdentifier: String, quantity: Int, callback: @escaping IAPPurchaseCallback) {
        if !initialized {
            callback(IAPPurchaseResult(state: .failed, iapError: IAPError(code: .libraryNotInitialized)))
            return
        }
        
        guard let product = IAPProductService.shared.getProductBy(identifier: productIdentifier) else {
            callback(IAPPurchaseResult(state: .failed, iapError: IAPError(code: .productNotFound)))
            return
        }
        IAPTransactionObserver.shared.purchase(product: product, quantity: quantity, applicationUsername: applicationUsername, callback: callback)
    }
    
    // Restore purchased products.
    public static func restorePurchases(callback: @escaping IAPRefreshCallback) {
        if !initialized {
            callback(IAPRefreshResult(state: .failed, iapError: IAPError(code: .libraryNotInitialized)))
            return
        }
        
        IAPReceiptService.shared.refresh(callback: callback)
    }
    
    // Checks if the user is allowed to authorize payments.
    public static func canMakePayments() -> Bool {
        return IAPTransactionObserver.shared.canMakePayments()
    }
    
    // Finish all transactions for the product.
    public static func finishTransactions(for productIdentifier: String) {
        IAPTransactionObserver.shared.finishTransactions(for: productIdentifier)
    }
    
    // Checks if the last transaction state for a given product was deferred.
    public static func hasDeferredTransaction(for productIdentifier: String) -> Bool {
        return IAPTransactionObserver.shared.hasDeferredTransaction(for: productIdentifier)
    }
    
    
    /* MARK: - Purchases information */
    // Checks if the user has already purchased at least one product.
    public static func hasAlreadyPurchased() -> Bool {
        return IAPReceiptService.shared.hasAlreadyPurchased()
    }
    
    // Checks if the user currently own (or is subscribed to) a given product (nonConsumable or autoRenewableSubscription).
    public static func hasActivePurchase(for productIdentifier: String) -> Bool {
        return IAPReceiptService.shared.hasActivePurchase(for: productIdentifier)
    }
    
    // Checks if the user has an active auto renewable subscription.
    public static func hasActiveSubscription() -> Bool {
        for productIdentifier in (InAppPurchase.iapProducts.filter{ $0.productType == IAPProductType.autoRenewableSubscription }.map{ $0.productIdentifier }) {
            if IAPReceiptService.shared.hasActivePurchase(for: productIdentifier){
                return true
            }
        }
        return false;
    }
    
    // Returns the latest purchased date for a given product.
    public static func getPurchaseDate(for productIdentifier: String) -> Date? {
        return IAPReceiptService.shared.getPurchaseDate(for: productIdentifier)
    }
    
    // Returns the expiry date for a subcription. May be past or future.
    public static func getExpiryDate(for productIdentifier: String) -> Date? {
        return IAPReceiptService.shared.getExpiryDate(for: productIdentifier)
    }
}
