import AppKit
import QuartzCore
import SwiftUI

struct LaunchpadTileStyle {
    let iconSize: CGFloat
    let titleFontSize: CGFloat
    let titleHeight: CGFloat
    let iconTitleSpacing: CGFloat

    var tileSize: CGSize {
        CGSize(
            width: max(iconSize + 28, iconSize * 1.42),
            height: iconSize + iconTitleSpacing + titleHeight
        )
    }
}

struct LaunchpadGridMetrics {
    let tileStyle: LaunchpadTileStyle
    let horizontalInset: CGFloat
    let columnPitch: CGFloat
    let rowPitch: CGFloat
    let gridStartY: CGFloat

    init(
        size: CGSize,
        columnCount: Int,
        rowCount: Int,
        horizontalInset requestedHorizontalInset: CGFloat,
        showsPageIndicator: Bool
    ) {
        let columns = max(1, columnCount)
        let rows = max(1, rowCount)
        let horizontalInset = min(
            requestedHorizontalInset,
            max(24, size.width * 0.12)
        )
        let topInset: CGFloat = 15
        let bottomInset: CGFloat = showsPageIndicator ? 40 : 15
        let availableWidth = max(1, size.width - horizontalInset * 2)
        let availableHeight = max(1, size.height - topInset - bottomInset)

        // 7 x 5 is the visual baseline. Sparse grids grow gently while denser
        // layouts shrink, with the current screen and Dock providing hard caps.
        let densityScale = sqrt(35 / CGFloat(columns * rows))
        let densityIconSize = 94 * densityScale
        let widthLimitedIconSize = availableWidth / CGFloat(columns) - 24
        let provisionalFontSize = min(15, max(11, densityIconSize * 0.145))
        let provisionalTitleHeight = provisionalFontSize * 2.4
        let provisionalSpacing = min(11, max(7, densityIconSize * 0.115))
        let heightLimitedIconSize = (
            availableHeight - CGFloat(max(0, rows - 1)) * 6
        ) / CGFloat(rows) - provisionalTitleHeight - provisionalSpacing
        let iconSize = min(
            112,
            max(
                42,
                min(densityIconSize, widthLimitedIconSize, heightLimitedIconSize)
            )
        )
        let titleFontSize = min(15, max(11, iconSize * 0.145))
        let titleHeight = titleFontSize * 2.4
        let iconTitleSpacing = min(11, max(7, iconSize * 0.115))
        let tileStyle = LaunchpadTileStyle(
            iconSize: iconSize,
            titleFontSize: titleFontSize,
            titleHeight: titleHeight,
            iconTitleSpacing: iconTitleSpacing
        )
        let tileHeight = tileStyle.tileSize.height
        let rawRowSpacing = rows > 1
            ? (availableHeight - CGFloat(rows) * tileHeight) / CGFloat(rows - 1)
            : 0
        let rowSpacing = rows > 1 ? min(64, max(6, rawRowSpacing)) : 0
        let contentHeight = CGFloat(rows) * tileHeight
            + CGFloat(max(0, rows - 1)) * rowSpacing

        self.tileStyle = tileStyle
        self.horizontalInset = horizontalInset
        columnPitch = availableWidth / CGFloat(columns)
        rowPitch = tileHeight + rowSpacing
        gridStartY = topInset + max(0, (availableHeight - contentHeight) / 2)
    }

    func tileOrigin(row: Int, column: Int) -> CGPoint {
        CGPoint(
            x: horizontalInset
                + CGFloat(column) * columnPitch
                + (columnPitch - tileStyle.tileSize.width) / 2,
            y: gridStartY + CGFloat(row) * rowPitch
        )
    }

    func slotCenter(row: Int, column: Int) -> CGPoint {
        let origin = tileOrigin(row: row, column: column)
        return CGPoint(
            x: origin.x + tileStyle.tileSize.width / 2,
            y: origin.y + tileStyle.iconSize / 2
        )
    }
}

struct CoreAnimationPager: NSViewRepresentable {
    let pages: [[LaunchpadItem]]
    let columnCount: Int
    let rowCount: Int
    let horizontalInset: CGFloat
    @Binding var selectedPage: Int
    let openAction: (InstalledApp) -> Void
    let revealAction: (InstalledApp) -> Void
    let openFolderAction: (String) -> Void
    let moveAction: (String, String) -> Void
    let mergeAction: (String, String) -> Void
    let allowsEditing: Bool
    let dismissAction: () -> Void

    func makeNSView(context: Context) -> LaunchpadPagingView {
        LaunchpadPagingView()
    }

    func updateNSView(_ nsView: LaunchpadPagingView, context: Context) {
        nsView.pageDidChange = { page in
            if selectedPage != page {
                selectedPage = page
            }
        }
        nsView.update(
            pages: pages,
            columnCount: columnCount,
            rowCount: rowCount,
            horizontalInset: horizontalInset,
            openAction: openAction,
            revealAction: revealAction,
            openFolderAction: openFolderAction,
            moveAction: moveAction,
            mergeAction: mergeAction,
            allowsEditing: allowsEditing,
            dismissAction: dismissAction
        )
        nsView.setPage(selectedPage, animated: !context.transaction.disablesAnimations)
    }
}

final class LaunchpadPagingView: NSView {
    var pageDidChange: ((Int) -> Void)?

    private let scrollView = LaunchpadScrollView()
    private let documentView = FlippedDocumentView()
    private var pages: [[LaunchpadItem]] = []
    private var columnCount = 1
    private var rowCount = 1
    private var horizontalInset: CGFloat = 56
    private var openAction: ((InstalledApp) -> Void)?
    private var revealAction: ((InstalledApp) -> Void)?
    private var openFolderAction: ((String) -> Void)?
    private var moveAction: ((String, String) -> Void)?
    private var mergeAction: ((String, String) -> Void)?
    private var allowsEditing = true
    private var dismissAction: (() -> Void)?
    private var contentSignature = ""
    private var lastLayoutSize = CGSize.zero
    private var currentPage = 0
    private var gestureStartPage = 0
    private var accumulatedScroll: CGFloat = 0
    private var lastInputWasPrecise = false
    private var isInteracting = false
    private var isSnapping = false
    private var snapWorkItem: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval = 0
    private var displayedOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var pendingPage = 0
    private var reportedPage = 0
    private weak var draggingTile: LaunchpadItemTileView?
    private var dragProxy: NSImageView?
    private weak var dragOriginalPage: LaunchpadPageView?
    private var dragOriginalFrame = CGRect.zero
    private var dragPageTiles: [LaunchpadItemTileView] = []
    private var dragPageFrames: [CGRect] = []
    private var proposedReorderTargetID: String?
    private var isShowingReorderPreview = false
    private var dragGrabOffset = CGPoint.zero
    private weak var hoveredTile: LaunchpadItemTileView?
    private var hoverBecameMergeTarget = false
    private var hoverWorkItem: DispatchWorkItem?
    private var reorderWorkItem: DispatchWorkItem?
    private var pendingReorderTargetID: String?
    private var edgePageWorkItem: DispatchWorkItem?
    private var lastDragLocationInWindow = CGPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.owner = self
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.wantsLayer = true
        scrollView.documentView = documentView
        scrollView.wantsLayer = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        lastDisplayTimestamp = 0

        guard let window else { return }
        let link = window.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        let maximumRefreshRate = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximumRefreshRate),
            maximum: maximumRefreshRate,
            preferred: maximumRefreshRate
        )
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        guard bounds.width > 0, bounds.height > 0 else { return }
        if lastLayoutSize != bounds.size {
            lastLayoutSize = bounds.size
            rebuildPages()
            setPage(currentPage, animated: false)
        }
    }

    func update(
        pages: [[LaunchpadItem]],
        columnCount: Int,
        rowCount: Int,
        horizontalInset: CGFloat,
        openAction: @escaping (InstalledApp) -> Void,
        revealAction: @escaping (InstalledApp) -> Void,
        openFolderAction: @escaping (String) -> Void,
        moveAction: @escaping (String, String) -> Void,
        mergeAction: @escaping (String, String) -> Void,
        allowsEditing: Bool,
        dismissAction: @escaping () -> Void
    ) {
        self.openAction = openAction
        self.revealAction = revealAction
        self.openFolderAction = openFolderAction
        self.moveAction = moveAction
        self.mergeAction = mergeAction
        self.allowsEditing = allowsEditing
        self.dismissAction = dismissAction

        let signature = pages
            .flatMap { $0 }
            .map(\.id)
            .joined(separator: "\u{1F}")
            + "|\(columnCount)|\(rowCount)|\(horizontalInset)"

        guard signature != contentSignature else { return }
        contentSignature = signature
        self.pages = pages
        self.columnCount = max(1, columnCount)
        self.rowCount = max(1, rowCount)
        self.horizontalInset = horizontalInset
        currentPage = min(currentPage, max(0, pages.count - 1))
        rebuildPages()
    }

    func setPage(_ page: Int, animated: Bool) {
        guard bounds.width > 0 else { return }
        let targetPage = min(max(0, page), max(0, pages.count - 1))
        let target = NSPoint(x: CGFloat(targetPage) * bounds.width, y: 0)

        // Ignore the SwiftUI binding echo produced when the visual page crosses
        // its midpoint. Let the active drag or snap animation continue smoothly.
        if (isInteracting || isSnapping), targetPage == reportedPage {
            return
        }

        guard animated, targetPage != currentPage else {
            currentPage = targetPage
            pendingPage = targetPage
            displayedOffset = target.x
            targetOffset = target.x
            scrollVelocity = 0
            isSnapping = false
            scrollView.contentView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            displayLink?.isPaused = true
            reportPage(targetPage)
            return
        }

        animate(to: targetPage)
    }

    fileprivate func handleScrollWheel(_ event: NSEvent) {
        guard draggingTile == nil, pages.count > 1, bounds.width > 0 else { return }

        snapWorkItem?.cancel()
        snapWorkItem = nil

        if !event.momentumPhase.isEmpty {
            scheduleSnap(after: 0.01)
            return
        }

        if !isInteracting {
            isInteracting = true
            isSnapping = false
            gestureStartPage = nearestPage()
            accumulatedScroll = 0
            displayedOffset = scrollView.contentView.bounds.origin.x
            targetOffset = displayedOffset
            scrollVelocity *= 0.35
        }

        lastInputWasPrecise = event.hasPreciseScrollingDeltas
        let deltaX = CGFloat(event.scrollingDeltaX)
        let deltaY = CGFloat(event.scrollingDeltaY)
        let dominantDelta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 42
        let movement = -dominantDelta * multiplier

        let lastPage = max(0, pages.count - 1)
        let maximumOffset = CGFloat(lastPage) * bounds.width
        let boundaryTolerance: CGFloat = 0.5
        let isPastFirstPage = gestureStartPage == 0
            && targetOffset <= boundaryTolerance
            && movement < 0
        let isPastLastPage = gestureStartPage == lastPage
            && targetOffset >= maximumOffset - boundaryTolerance
            && movement > 0

        if isPastFirstPage || isPastLastPage {
            // Consume outward movement at the ends. In particular, do not leave
            // accumulated input behind: a zero displacement used to interpret
            // that residue as a request to advance to page two.
            targetOffset = isPastFirstPage ? 0 : maximumOffset
            displayedOffset = targetOffset
            accumulatedScroll = 0
            scrollVelocity = 0
            scrollView.contentView.scroll(to: NSPoint(x: targetOffset, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                scheduleSnap(after: 0.01)
            } else {
                scheduleSnap(after: event.hasPreciseScrollingDeltas ? 0.06 : 0.1)
            }
            return
        }

        accumulatedScroll += movement
        targetOffset = min(
            max(0, targetOffset + movement),
            maximumOffset
        )
        displayLink?.isPaused = false

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scheduleSnap(after: 0.015)
        } else {
            scheduleSnap(after: event.hasPreciseScrollingDeltas ? 0.09 : 0.14)
        }
    }

    private func scheduleSnap(after delay: TimeInterval) {
        snapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishInteraction()
        }
        snapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishInteraction() {
        guard isInteracting else { return }

        let pageWidth = bounds.width
        let startOrigin = CGFloat(gestureStartPage) * pageWidth
        let displacement = targetOffset - startOrigin
        let threshold = min(pageWidth * 0.14, 150)
        let inputThreshold: CGFloat = lastInputWasPrecise ? 26 : 12
        var targetPage = gestureStartPage

        if abs(displacement) >= threshold || abs(accumulatedScroll) >= inputThreshold {
            let direction = abs(displacement) > 0.5
                ? displacement
                : accumulatedScroll
            targetPage += direction > 0 ? 1 : -1
        }

        targetPage = min(max(0, targetPage), max(0, pages.count - 1))
        animate(to: targetPage)
    }

    private func animate(to page: Int) {
        let targetPage = min(max(0, page), max(0, pages.count - 1))
        pendingPage = targetPage
        targetOffset = CGFloat(targetPage) * bounds.width
        isInteracting = false
        isSnapping = true
        accumulatedScroll = 0
        displayLink?.isPaused = false
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard bounds.width > 0 else { return }

        let timestamp = link.timestamp
        let rawDelta = lastDisplayTimestamp > 0
            ? timestamp - lastDisplayTimestamp
            : link.duration
        lastDisplayTimestamp = timestamp
        let deltaTime = CGFloat(min(max(rawDelta, 1.0 / 240.0), 1.0 / 30.0))

        let stiffness: CGFloat
        let damping: CGFloat
        if isInteracting {
            stiffness = lastInputWasPrecise ? 520 : 300
            damping = lastInputWasPrecise ? 44 : 34
        } else {
            stiffness = 210
            damping = 29
        }

        let acceleration = (targetOffset - displayedOffset) * stiffness
            - scrollVelocity * damping
        scrollVelocity += acceleration * deltaTime
        displayedOffset += scrollVelocity * deltaTime

        let maximumOffset = CGFloat(max(0, pages.count - 1)) * bounds.width
        displayedOffset = min(max(0, displayedOffset), maximumOffset)
        scrollView.contentView.scroll(to: NSPoint(x: displayedOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if draggingTile != nil {
            positionDraggingTile()
            updateHoveredTile(at: lastDragLocationInWindow)
        }
        reportPage(nearestPage())

        guard isSnapping,
              abs(targetOffset - displayedOffset) < 0.35,
              abs(scrollVelocity) < 4
        else {
            return
        }

        displayedOffset = targetOffset
        scrollVelocity = 0
        isSnapping = false
        currentPage = pendingPage
        scrollView.contentView.scroll(to: NSPoint(x: targetOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        link.isPaused = true
        lastDisplayTimestamp = 0
        reportPage(pendingPage)
    }

    private func reportPage(_ page: Int) {
        guard reportedPage != page else { return }
        reportedPage = page
        pageDidChange?(page)
    }

    private func nearestPage() -> Int {
        guard bounds.width > 0 else { return currentPage }
        return min(
            max(0, Int(round(scrollView.contentView.bounds.origin.x / bounds.width))),
            max(0, pages.count - 1)
        )
    }

    fileprivate func beginDragging(
        _ tile: LaunchpadItemTileView,
        with event: NSEvent
    ) -> Bool {
        guard allowsEditing,
              draggingTile == nil,
              !isInteracting,
              !isSnapping,
              let page = tile.superview as? LaunchpadPageView
        else { return false }

        snapWorkItem?.cancel()
        snapWorkItem = nil
        draggingTile = tile
        dragOriginalPage = page
        dragOriginalFrame = tile.frame
        dragPageTiles = page.subviews
            .compactMap { $0 as? LaunchpadItemTileView }
            .sorted { first, second in
                if abs(first.frame.minY - second.frame.minY) > 1 {
                    return first.frame.minY < second.frame.minY
                }
                return first.frame.minX < second.frame.minX
            }
        dragPageFrames = dragPageTiles.map(\.frame)
        proposedReorderTargetID = nil
        isShowingReorderPreview = false
        dragGrabOffset = tile.convert(event.locationInWindow, from: nil)
        lastDragLocationInWindow = event.locationInWindow

        let frameInDocument = documentView.convert(tile.bounds, from: tile)
        let proxy = NSImageView(frame: frameInDocument)
        proxy.image = NSImage(data: tile.dataWithPDF(inside: tile.bounds))
        proxy.imageScaling = .scaleAxesIndependently
        proxy.wantsLayer = true
        proxy.layer?.zPosition = 1_000
        proxy.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.06, y: 1.06))
        documentView.addSubview(proxy, positioned: .above, relativeTo: nil)
        dragProxy = proxy

        // Keep the real tile in its page so AppKit continues delivering the
        // entire mouse tracking sequence to it. Only the visual proxy moves.
        tile.alphaValue = 0
        positionDraggingTile()
        return true
    }

    fileprivate func updateDragging(
        _ tile: LaunchpadItemTileView,
        with event: NSEvent
    ) {
        guard draggingTile === tile else { return }
        lastDragLocationInWindow = event.locationInWindow
        positionDraggingTile()
        updateHoveredTile(at: event.locationInWindow)
        scheduleEdgePageIfNeeded(at: event.locationInWindow)
    }

    fileprivate func endDragging(
        _ tile: LaunchpadItemTileView,
        with event: NSEvent
    ) {
        guard draggingTile === tile else { return }
        lastDragLocationInWindow = event.locationInWindow
        updateHoveredTile(at: event.locationInWindow)

        let sourceID = tile.item.id
        let mergeTargetID = hoveredTile?.item.id
        // Dropping while the dragged icon is centered over another icon is
        // always a folder operation. The hover delay only controls the visual
        // confirmation; it must not turn a quick, accurate drop into reorder.
        let shouldMerge = mergeTargetID != nil
        let targetID = shouldMerge
            ? mergeTargetID
            : proposedReorderTargetID ?? mergeTargetID
        let hasDropAction = targetID != nil

        cancelDragScheduling()
        hoveredTile?.setMergeHighlighted(false)
        hoveredTile = nil
        hoverBecameMergeTarget = false

        if !hasDropAction {
            applyReorderPreview(targetID: nil, animated: true)
        }
        draggingTile = nil

        dragProxy?.removeFromSuperview()
        dragProxy = nil
        tile.frame = dragOriginalFrame
        tile.alphaValue = hasDropAction ? 0 : 1
        dragOriginalPage = nil

        dragPageTiles = []
        dragPageFrames = []
        proposedReorderTargetID = nil
        isShowingReorderPreview = false

        guard let targetID, sourceID != targetID else { return }
        if hasDropAction {
            tile.alphaValue = 0
        }

        DispatchQueue.main.async { [weak self] in
            if shouldMerge {
                self?.mergeAction?(sourceID, targetID)
            } else {
                self?.moveAction?(sourceID, targetID)
            }
        }
    }

    private func positionDraggingTile() {
        guard draggingTile != nil, let dragProxy else { return }
        let point = documentView.convert(lastDragLocationInWindow, from: nil)
        dragProxy.setFrameOrigin(
            CGPoint(
                x: point.x - dragGrabOffset.x,
                y: point.y - dragGrabOffset.y
            )
        )
    }

    private func updateHoveredTile(at locationInWindow: CGPoint) {
        guard let source = draggingTile else { return }
        let visiblePageIndex = nearestPage()
        guard let page = documentView.subviews
            .compactMap({ $0 as? LaunchpadPageView })
            .first(where: { $0.pageIndex == visiblePageIndex })
        else {
            setHoveredTile(nil, source: source)
            setReorderTarget(nil, on: nil, source: source, showsPreview: false)
            return
        }

        let point = page.convert(locationInWindow, from: nil)
        let candidates = page.subviews
            .compactMap { $0 as? LaunchpadItemTileView }
            .filter { $0 !== source }
        let referenceFrame: (LaunchpadItemTileView) -> CGRect = { [weak self, weak page] tile in
            guard let self,
                  page === self.dragOriginalPage,
                  let index = self.dragPageTiles.firstIndex(where: { $0 === tile }),
                  self.dragPageFrames.indices.contains(index)
            else { return tile.frame }
            return self.dragPageFrames[index]
        }

        let centralTarget = candidates.first { tile in
            tile.mergeTargetFrame(using: referenceFrame(tile)).contains(point)
        }
        if let centralTarget,
           source.item.app != nil,
           centralTarget.item.app != nil || centralTarget.item.folder != nil {
            cancelPendingReorder()
            setReorderTarget(
                centralTarget,
                on: page,
                source: source,
                showsPreview: false
            )
            setHoveredTile(centralTarget, source: source)
            return
        }

        setHoveredTile(nil, source: source)
        let reorderTarget = candidates.min { first, second in
            distance(from: point, to: referenceFrame(first))
                < distance(from: point, to: referenceFrame(second))
        }
        if let reorderTarget,
           distance(from: point, to: referenceFrame(reorderTarget))
                <= max(72, max(reorderTarget.frame.width, reorderTarget.frame.height) * 0.85) {
            scheduleReorderTarget(
                reorderTarget,
                on: page,
                source: source
            )
        } else {
            cancelPendingReorder()
            setReorderTarget(nil, on: page, source: source, showsPreview: false)
        }
    }

    private func scheduleReorderTarget(
        _ target: LaunchpadItemTileView,
        on page: LaunchpadPageView,
        source: LaunchpadItemTileView
    ) {
        reorderWorkItem?.cancel()
        pendingReorderTargetID = target.item.id

        // Keep every icon in place while the pointer is still moving. This
        // lets the dragged icon reach the merge zone instead of having its
        // target displaced on approach. Pausing in a gap confirms reorder.
        setReorderTarget(target, on: page, source: source, showsPreview: false)

        let targetID = target.item.id
        let workItem = DispatchWorkItem { [weak self, weak target, weak page, weak source] in
            guard let self,
                  let target,
                  let page,
                  let source,
                  self.draggingTile === source,
                  self.hoveredTile == nil,
                  self.pendingReorderTargetID == targetID
            else { return }

            self.reorderWorkItem = nil
            self.pendingReorderTargetID = nil
            self.setReorderTarget(target, on: page, source: source, showsPreview: true)
        }
        reorderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func cancelPendingReorder() {
        reorderWorkItem?.cancel()
        reorderWorkItem = nil
        pendingReorderTargetID = nil
    }

    private func setReorderTarget(
        _ target: LaunchpadItemTileView?,
        on page: LaunchpadPageView?,
        source: LaunchpadItemTileView,
        showsPreview: Bool
    ) {
        let targetID = target?.item.id
        let canPreview = showsPreview && page === dragOriginalPage && target != nil
        guard proposedReorderTargetID != targetID
                || isShowingReorderPreview != canPreview
        else { return }

        proposedReorderTargetID = targetID
        isShowingReorderPreview = canPreview
        applyReorderPreview(
            targetID: canPreview ? targetID : nil,
            animated: true
        )
    }

    private func applyReorderPreview(targetID: String?, animated: Bool) {
        guard dragPageTiles.count == dragPageFrames.count,
              let source = draggingTile
        else { return }

        var previewOrder = dragPageTiles
        if let targetID,
           let sourceIndex = previewOrder.firstIndex(where: { $0 === source }),
           let targetIndex = previewOrder.firstIndex(where: { $0.item.id == targetID }),
           sourceIndex != targetIndex {
            let sourceTile = previewOrder.remove(at: sourceIndex)
            previewOrder.insert(sourceTile, at: min(targetIndex, previewOrder.count))
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.17 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for tile in dragPageTiles where tile !== source {
                guard let destinationIndex = previewOrder.firstIndex(where: { $0 === tile }),
                      dragPageFrames.indices.contains(destinationIndex)
                else { continue }
                tile.animator().frame = dragPageFrames[destinationIndex]
            }
        }
    }

    private func setHoveredTile(
        _ target: LaunchpadItemTileView?,
        source: LaunchpadItemTileView
    ) {
        guard hoveredTile !== target else { return }

        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        hoveredTile?.setMergeHighlighted(false)
        hoveredTile = target
        hoverBecameMergeTarget = false

        guard let target,
              source.item.app != nil,
              target.item.app != nil || target.item.folder != nil
        else { return }

        let workItem = DispatchWorkItem { [weak self, weak source, weak target] in
            guard let self,
                  let source,
                  let target,
                  self.draggingTile === source,
                  self.hoveredTile === target
            else { return }
            self.hoverBecameMergeTarget = true
            target.setMergeHighlighted(true)
        }
        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: workItem)
    }

    private func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        hypot(point.x - frame.midX, point.y - frame.midY)
    }

    private func scheduleEdgePageIfNeeded(at locationInWindow: CGPoint) {
        let point = scrollView.convert(locationInWindow, from: nil)
        let visiblePage = nearestPage()
        let lastPage = max(0, pages.count - 1)
        let destination: Int?

        if point.x < 56, visiblePage > 0 {
            destination = visiblePage - 1
        } else if point.x > scrollView.bounds.width - 56, visiblePage < lastPage {
            destination = visiblePage + 1
        } else {
            destination = nil
        }

        guard let destination else {
            edgePageWorkItem?.cancel()
            edgePageWorkItem = nil
            return
        }
        guard edgePageWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.draggingTile != nil else { return }
            self.edgePageWorkItem = nil
            self.hoverWorkItem?.cancel()
            self.hoveredTile?.setMergeHighlighted(false)
            self.hoveredTile = nil
            self.hoverBecameMergeTarget = false
            self.cancelPendingReorder()
            if let source = self.draggingTile {
                self.setReorderTarget(
                    nil,
                    on: nil,
                    source: source,
                    showsPreview: false
                )
            }
            self.animate(to: destination)
        }
        edgePageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58, execute: workItem)
    }

    private func cancelDragScheduling() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        cancelPendingReorder()
        edgePageWorkItem?.cancel()
        edgePageWorkItem = nil
    }

    private func rebuildPages() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        cancelDragScheduling()
        dragProxy?.removeFromSuperview()
        dragProxy = nil
        draggingTile?.alphaValue = 1
        draggingTile = nil
        hoveredTile = nil
        dragPageTiles = []
        dragPageFrames = []
        proposedReorderTargetID = nil
        isShowingReorderPreview = false
        documentView.subviews.forEach { $0.removeFromSuperview() }
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, pages.count)) * bounds.width,
            height: bounds.height
        )
        documentView.wantsLayer = true

        let metrics = LaunchpadGridMetrics(
            size: bounds.size,
            columnCount: columnCount,
            rowCount: rowCount,
            horizontalInset: horizontalInset,
            showsPageIndicator: pages.count > 1
        )

        for (pageIndex, apps) in pages.enumerated() {
            let pageView = LaunchpadPageView()
            pageView.frame = NSRect(
                x: CGFloat(pageIndex) * bounds.width,
                y: 0,
                width: bounds.width,
                height: bounds.height
            )
            pageView.pageIndex = pageIndex
            pageView.dismissAction = dismissAction
            pageView.wantsLayer = true
            pageView.layer?.drawsAsynchronously = true

            for (itemIndex, item) in apps.enumerated() {
                let row = itemIndex / columnCount
                let column = itemIndex % columnCount
                guard row < rowCount else { continue }

                let origin = metrics.tileOrigin(row: row, column: column)
                let tile = LaunchpadItemTileView(
                    item: item,
                    style: metrics.tileStyle,
                    openAction: { [weak self] app in self?.openAction?(app) },
                    revealAction: { [weak self] app in self?.revealAction?(app) },
                    openFolderAction: { [weak self] folderID in
                        self?.openFolderAction?(folderID)
                    }
                )
                tile.dragOwner = self
                tile.frame = NSRect(origin: origin, size: metrics.tileStyle.tileSize)
                pageView.addSubview(tile)
            }

            documentView.addSubview(pageView)
        }

        scrollView.contentView.setBoundsOrigin(
            NSPoint(x: CGFloat(currentPage) * bounds.width, y: 0)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        displayedOffset = CGFloat(currentPage) * bounds.width
        targetOffset = displayedOffset
        pendingPage = currentPage
        scrollVelocity = 0
        displayLink?.isPaused = true
    }
}

private final class LaunchpadScrollView: NSScrollView {
    weak var owner: LaunchpadPagingView?

    override func scrollWheel(with event: NSEvent) {
        owner?.handleScrollWheel(event)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class LaunchpadPageView: NSView {
    var pageIndex = 0
    var dismissAction: (() -> Void)?
    private var mouseDownPoint = CGPoint.zero

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) < 4 {
            dismissAction?()
        }
    }
}

private final class LaunchpadItemTileView: NSView {
    let item: LaunchpadItem
    private let style: LaunchpadTileStyle
    weak var dragOwner: LaunchpadPagingView?
    private let openAction: (InstalledApp) -> Void
    private let revealAction: (InstalledApp) -> Void
    private let openFolderAction: (String) -> Void
    private let iconContainer = NSView()
    private let imageView = NSImageView()
    private let folderBackground = NSView()
    private var folderPreviewViews: [NSImageView] = []
    private let titleField = NSTextField(labelWithString: "")
    private var mouseDownPoint = CGPoint.zero
    private var isDraggingItem = false
    private var isTrackingMouse = false

    override var isFlipped: Bool { true }

    init(
        item: LaunchpadItem,
        style: LaunchpadTileStyle,
        openAction: @escaping (InstalledApp) -> Void,
        revealAction: @escaping (InstalledApp) -> Void,
        openFolderAction: @escaping (String) -> Void
    ) {
        self.item = item
        self.style = style
        self.openAction = openAction
        self.revealAction = revealAction
        self.openFolderAction = openFolderAction
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = style.iconSize * 0.19
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)

        iconContainer.wantsLayer = true
        iconContainer.layer?.masksToBounds = false
        addSubview(iconContainer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.3
        imageView.layer?.shadowRadius = style.iconSize * 0.085
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -style.iconSize * 0.05)
        iconContainer.addSubview(imageView)

        folderBackground.wantsLayer = true
        folderBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        folderBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        folderBackground.layer?.borderWidth = 1
        folderBackground.layer?.cornerRadius = style.iconSize * 0.21
        folderBackground.layer?.shadowColor = NSColor.black.cgColor
        folderBackground.layer?.shadowOpacity = 0.25
        folderBackground.layer?.shadowRadius = style.iconSize * 0.085
        folderBackground.layer?.shadowOffset = CGSize(width: 0, height: -style.iconSize * 0.05)
        iconContainer.addSubview(folderBackground)

        configureIcon()

        titleField.stringValue = item.name
        titleField.font = .systemFont(ofSize: style.titleFontSize, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.96)
        titleField.alignment = .center
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.wraps = true
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        textShadow.shadowBlurRadius = 2
        textShadow.shadowOffset = CGSize(width: 0, height: -1)
        titleField.shadow = textShadow
        addSubview(titleField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let iconX = (bounds.width - style.iconSize) / 2
        iconContainer.frame = NSRect(
            x: iconX,
            y: 0,
            width: style.iconSize,
            height: style.iconSize
        )
        imageView.frame = iconContainer.bounds
        folderBackground.frame = iconContainer.bounds

        let previewPadding = style.iconSize * 0.105
        let previewGap = style.iconSize * 0.085
        let previewSize = (style.iconSize - previewPadding * 2 - previewGap) / 2
        let secondPreviewOrigin = previewPadding + previewSize + previewGap
        let positions = [
            CGPoint(x: previewPadding, y: previewPadding),
            CGPoint(x: secondPreviewOrigin, y: previewPadding),
            CGPoint(x: previewPadding, y: secondPreviewOrigin),
            CGPoint(x: secondPreviewOrigin, y: secondPreviewOrigin)
        ]
        for (index, preview) in folderPreviewViews.enumerated() {
            preview.frame = NSRect(origin: positions[index], size: CGSize(width: previewSize, height: previewSize))
        }
        titleField.frame = NSRect(
            x: 0,
            y: style.iconSize + style.iconTitleSpacing,
            width: bounds.width,
            height: style.titleHeight
        )
    }

    fileprivate func mergeTargetFrame(using tileFrame: CGRect) -> CGRect {
        CGRect(
            x: tileFrame.minX,
            y: tileFrame.minY - style.iconSize * 0.15,
            width: tileFrame.width,
            height: min(tileFrame.height, style.iconSize * 1.3)
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is supplied in the coordinate space expected by AppKit's
        // normal hit-testing implementation. Let AppKit do the frame/visibility
        // checks, then collapse hits on the icon and label back to this tile so
        // mouseDown/mouseDragged/mouseUp always arrive at the same view.
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func accessibilityPerformPress() -> Bool {
        activateItem()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        animatePressed(true)

        guard let window else { return }
        isTrackingMouse = true
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] trackedEvent, stop in
            guard let self, let trackedEvent else {
                stop.pointee = true
                return
            }

            switch trackedEvent.type {
            case .leftMouseDragged:
                self.handleMouseDragged(trackedEvent)
            case .leftMouseUp:
                self.handleMouseUp(trackedEvent)
                stop.pointee = true
            default:
                break
            }
        }
        isTrackingMouse = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isTrackingMouse else { return }
        handleMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isTrackingMouse else { return }
        handleMouseUp(event)
    }

    private func handleMouseDragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingItem,
           hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 6 {
            animatePressed(false)
            isDraggingItem = dragOwner?.beginDragging(self, with: event) == true
        }

        if isDraggingItem {
            dragOwner?.updateDragging(self, with: event)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        if isDraggingItem {
            isDraggingItem = false
            dragOwner?.endDragging(self, with: event)
            return
        }

        animatePressed(false)
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point),
              hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) < 5
        else {
            return
        }

        activateItem()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard item.app != nil else { return nil }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开", action: #selector(openApp), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let revealItem = NSMenuItem(
            title: "在 Finder 中显示",
            action: #selector(revealApp),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)
        return menu
    }

    @objc private func openApp() {
        guard let app = item.app else { return }
        openAction(app)
    }

    @objc private func revealApp() {
        guard let app = item.app else { return }
        revealAction(app)
    }

    private func activateItem() {
        switch item.content {
        case .app(let app):
            openAction(app)
        case .folder(let folder):
            openFolderAction(folder.id)
        }
    }

    func setDragging(_ dragging: Bool) {
        alphaValue = dragging ? 0.94 : 1
        layer?.zPosition = dragging ? 100 : 0
        setIconScale(dragging ? 1.08 : 1, duration: 0.14)
    }

    func setMergeHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        setIconScale(highlighted ? 1.13 : 1, duration: 0.18)
    }

    private func configureIcon() {
        switch item.content {
        case .app(let app):
            imageView.image = app.icon
            imageView.isHidden = false
            folderBackground.isHidden = true

        case .folder(let folder):
            imageView.isHidden = true
            folderBackground.isHidden = false
            for app in folder.apps.prefix(4) {
                let preview = NSImageView()
                preview.image = app.icon
                preview.imageScaling = .scaleProportionallyUpOrDown
                folderBackground.addSubview(preview)
                folderPreviewViews.append(preview)
            }
        }
    }

    private func setIconScale(_ scale: CGFloat, duration: CFTimeInterval) {
        guard let layer = iconContainer.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    private func animatePressed(_ pressed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = pressed ? 0.82 : 1
        }
    }
}
