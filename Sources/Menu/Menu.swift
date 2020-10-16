//
//  File.swift
//  
//
//  Created by Ivan Sapozhnik on 10.04.20.
//

import Cocoa
//import EventMonitor

open class EventMonitor {
    
    fileprivate var monitor: AnyObject?
    fileprivate let mask: NSEvent.EventTypeMask
    fileprivate let handler: (NSEvent?) -> ()
    
    public init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> ()) {
        self.mask = mask
        self.handler = handler
    }
    
    deinit {
        stop()
    }
    
    open func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) as AnyObject?
    }
    
    open func stop() {
        if monitor != nil {
            NSEvent.removeMonitor(monitor!)
            monitor = nil
        }
    }
}


public final class Menu {
    public private(set) var items: [MenuItem]
    public var numberOfItems: Int {
        return items.count
    }
    public var selectedItem: MenuItem? {
        return items.first { $0.id == selectedId }
    }

    private var window: Window?
    private var lostFocusObserver: Any?
    private var localMonitor: EventMonitor?
    private let configuration: Configuration
    private var selectedId: UUID?
    private let title: String?
    private weak var targetView: NSView?

    public convenience init() {
        self.init(with: nil)
    }

    public init(with title: String?, items: [MenuItem] = [MenuItem](), configuration: Configuration = MenuConfiguration()) {
        self.title = title
        self.items = items
        self.configuration = configuration
    }

    // MARK: - Show and dismiss
    public func show(from view: NSView, animated: Bool = true) {
        show(items, from: view, animated: animated)
    }

    public func dismiss(animated: Bool = true) {
        let actualDismiss: (NSWindow) -> Void = { [weak self] menuWindow in
            self?.window?.parent?.removeChildWindow(menuWindow)
            self?.window?.orderOut(self)
            self?.window = nil
            self?.stopMonitors()
        }
        if let menuWindow = window {
            if animated {
                fadeOut(window: menuWindow) {
                    actualDismiss(menuWindow)
                }
            } else {
                actualDismiss(menuWindow)
            }
        }
    }

    // MARK: - Selection
    public func selectItem(at index: Int) {
        guard let item = item(at: index) else { return }
        selectedId = item.id
        item.action?(index)
    }

    // MARK: - Adding and Removing Menu Items
    public func insertItem(_ item: MenuItem, at index: Int) {
        items.insert(item, at: index)
    }

    public func addItem(_ item: MenuItem) {
        items.append(item)
    }

    public func addItems(_ items: [MenuItem]) {
        self.items.append(contentsOf: items)
    }

    public func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let deletedItem = items.remove(at: index)
        if deletedItem.id == selectedId {
            selectedId = nil
        }
    }

    public func removeItem(_ item: MenuItem) {
        items.removeAll { $0.id == item.id }
        if item.id == selectedId {
            selectedId = nil
        }
    }

    public func removeAllItems() {
        items.removeAll()
        selectedId = nil
    }

    // MARK: - Finding Menu Items
    public func item(at index: Int) -> MenuItem? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    public func item(withTitle title: String) -> MenuItem? {
        items.first { $0.title == title }
    }

    // MARK: - Disabling&Enabling
    public func disableAllItems() {
        items = items.map { oldItem in
            var newItem = oldItem
            newItem.isEnabled = false
            return newItem
        }
    }

    public func enableAllItems() {
        items = items.map { oldItem in
            var newItem = oldItem
            newItem.isEnabled = true
            return newItem
        }
    }

    // MARK: - Private
    private func show(_ items: [MenuItem], from view: NSView, animated: Bool) {
        guard window == nil, let parentWindow = view.window else { return }

        let menuWindow = makeWindow(
            with: title,
            menuItems: items,
            attachedTo: parentWindow,
            relativeTo: view
        )
        self.window = menuWindow

        setupMonitors(for: parentWindow, targetView: view)

        if animated {
            fadeIn(menuWindow)
        } else {
            menuWindow.alphaValue = 1.0
        }
    }

    private func fadeIn(_ window: NSWindow) {
        window.alphaValue = 0.0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = configuration.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseIn)
            window.animator().alphaValue = 1.0
        }
    }

    private func fadeOut(window: NSWindow, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup ({ context in
            context.duration = configuration.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseOut)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            completion()
        })
    }

    private func setupMonitors(for parentWindow: NSWindow, targetView: NSView) {
        lostFocusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parentWindow, queue: nil, using: { [weak self] (_ arg1: Notification) -> Void in
            self?.dismiss(animated: false)
        })

        localMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let localEvent = event else { return }

            if localEvent.window != self?.window {
                if localEvent.window == parentWindow {
                    self?.dismiss(animated: true)
//                    Ignore clicking on presenting view
//                    let contentView = parentWindow.contentView
//                    let locationTest = contentView?.convert(localEvent.locationInWindow, from: nil)
//                    let hitView = contentView?.hitTest(locationTest ?? .zero)
//                    if hitView != targetView {
//                        self?.dismiss()
//                    }
                }
            }
        })
        localMonitor?.start()
    }

    private func stopMonitors() {
        localMonitor?.stop()
        localMonitor = nil

        if let lostFocusObserver = lostFocusObserver {
            NotificationCenter.default.removeObserver(lostFocusObserver)
            self.lostFocusObserver = nil
        }
    }

    private func makeWindow(with title: String?, menuItems: [MenuItem], attachedTo parentWindow: NSWindow, relativeTo targetView: NSView) -> Window {
        let contentViewController = ContentViewController(with: title, menuItems: menuItems, selectedId: selectedId, configuration: configuration)
        contentViewController.delegate = self

        let window = Window.make(with: configuration)
        window.contentViewController = contentViewController
        parentWindow.addChildWindow(window, ordered: .above)

        setFrame(for: window, relativeTo: targetView)

        return window
    }

    private func setFrame(for window: NSWindow, relativeTo view: NSView) {
        guard let parentWindow = view.window, let topMostSuperView = parentWindow.contentView else { return }

        let locationInWindow = view.convert(topMostSuperView.frame.origin, to: nil)
        let rectInWindow = NSRect(origin: locationInWindow, size: CGSize(width: NSWidth(view.frame), height: NSHeight(window.frame)))
        let rectInScreen = parentWindow.convertToScreen(rectInWindow)
        let origin = rectInScreen.origin
        var additionalYOffset = configuration.appearsBelowSender ? NSHeight(view.frame) : 0
        additionalYOffset += abs(configuration.presentingOffset)
        let newFrame = NSRect(x: origin.x, y: origin.y - NSHeight(window.frame) - additionalYOffset, width: NSWidth(view.frame), height: NSHeight(window.frame))

        window.setFrame(newFrame, display: true, animate: false)
    }
}

extension Menu: ContentViewControllerDelegate {
    func didClickMenuItem(withId id: UUID) {
        selectedId = id
        dismiss(animated: true)
    }
}
