//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

/// Direction of pagination scrolling.
public enum PaginationAxis {
    case horizontal
    case vertical
}

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) } ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation) async
}

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at the given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at the given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
    weak var delegate: PaginationViewDelegate?

    /// Total number of page views in this pagination.
    private(set) var pageCount: Int = 0

    /// Index of the page currently displayed.
    private(set) var currentIndex: Int = 0

    /// Direction of reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// The loaded page views, keyed by their index.
    private(set) var loadedViews: [Int: (UIView & PageView)] = [:]

    /// Number of positions to preload before the current page.
    private let preloadPreviousPositionCount: Int

    /// Number of positions to preload after the current page.
    private let preloadNextPositionCount: Int

    /// A queue of indexes to be loaded.
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []

    /// Returns true if there are no loaded views.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// The currently displayed page view, if any.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    /// Internal sort of the loaded views in reading order.
    private var orderedViews: [UIView & PageView] {
        var views = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)
        if readingProgression == .rtl && axis == .horizontal {
            views.reverse()
        }
        return views
    }

    /// The scroll view used for horizontal/vertical pagination.
    private let scrollView = UIScrollView()

    /// Axis for pagination: horizontal or vertical.
    private let axis: PaginationAxis

    /// Initializes the PaginationView.
    ///
    /// - Parameters:
    ///   - frame: View frame.
    ///   - preloadPreviousPositionCount: Number of positions to preload before the current page.
    ///   - preloadNextPositionCount: Number of positions to preload after the current page.
    ///   - axis: Horizontal or vertical pagination.
    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        axis: PaginationAxis
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.axis = axis

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]

        scrollView.isPagingEnabled = true

        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        // Insert an empty view to prevent iOS from adjusting scroll insets automatically
        insertSubview(UIView(frame: .zero), at: 0)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Layout the subviews based on the current axis.
    override public func layoutSubviews() {
        super.layoutSubviews()

        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size

        switch axis {
        case .horizontal:
            scrollView.contentSize = CGSize(
                width: size.width * CGFloat(pageCount),
                height: size.height
            )
            for (index, view) in loadedViews {
                view.frame = CGRect(
                    origin: CGPoint(
                        x: xOffsetForIndex(index, containerWidth: size.width),
                        y: 0
                    ),
                    size: size
                )
            }
            scrollView.contentOffset.x = xOffsetForIndex(currentIndex, containerWidth: size.width)

        case .vertical:
            scrollView.contentSize = CGSize(
                width: size.width,
                height: size.height * CGFloat(pageCount)
            )
            for (index, view) in loadedViews {
                view.frame = CGRect(
                    origin: CGPoint(
                        x: 0,
                        y: yOffsetForIndex(index, containerHeight: size.height)
                    ),
                    size: size
                )
            }
            scrollView.contentOffset.y = yOffsetForIndex(currentIndex, containerHeight: size.height)
        }
    }

    /// Calculates the horizontal offset for a given index in LTR or RTL.
    private func xOffsetForIndex(_ index: Int, containerWidth: CGFloat) -> CGFloat {
        if readingProgression == .rtl {
            return scrollView.contentSize.width - (CGFloat(index + 1) * containerWidth)
        } else {
            return containerWidth * CGFloat(index)
        }
    }

    /// Calculates the vertical offset for a given index.
    private func yOffsetForIndex(_ index: Int, containerHeight: CGFloat) -> CGFloat {
        containerHeight * CGFloat(index)
    }

    /// Reloads the pagination with the specified parameters, and moves to the given index.
    ///
    /// - Parameters:
    ///   - index: Index to move to.
    ///   - location: Page location to move to.
    ///   - pageCount: Total number of pages.
    ///   - readingProgression: Reading progression direction.
    func reloadAtIndex(
        _ index: Int,
        location: PageLocation,
        pageCount: Int,
        readingProgression: ReadingProgression
    ) async {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        // Remove old views
        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()

        await setCurrentIndex(index, location: location)
    }

    /// Updates the current index, adding pages to the load queue.
    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) async {
        guard isEmpty || index != currentIndex else {
            return
        }

        let movingBackward = (currentIndex - 1 == index)
        let actualLocation = location ?? (movingBackward ? .end : .start)
        currentIndex = index

        // Schedule loads: current index, then next, then previous
        scheduleLoadPage(at: index, location: actualLocation)
        let lastIndex = scheduleLoadPages(
            from: index,
            upToPositionCount: preloadNextPositionCount,
            direction: .forward,
            location: .start
        )
        let firstIndex = scheduleLoadPages(
            from: index,
            upToPositionCount: preloadPreviousPositionCount,
            direction: .backward,
            location: .end
        )

        // Remove views that are out of this range
        for (i, view) in loadedViews {
            if !(firstIndex ... lastIndex).contains(i) {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
            }
        }

        await loadNextPage()
        delegate?.paginationViewDidUpdateViews(self)
    }

    /// Recursively loads pages from the queue.
    private func loadNextPage() async {
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            return
        }

        if loadedViews[index] == nil {
            if let view = delegate?.paginationView(self, pageViewAtIndex: index) {
                loadedViews[index] = view
                scrollView.addSubview(view)
                setNeedsLayout()
            }
        }

        guard let pageView = loadedViews[index] else {
            return
        }

        await pageView.go(to: location)
        await loadNextPage()
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    /// Schedules loading of pages in a given direction until `positionCount` is reached.
    private func scheduleLoadPages(
        from sourceIndex: Int,
        upToPositionCount positionCount: Int,
        direction: PageIndexDirection,
        location: PageLocation
    ) -> Int {
        let nextIndex = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: nextIndex, location: location),
            let posCount = delegate?.paginationView(self, positionCountAtIndex: nextIndex)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: nextIndex,
            upToPositionCount: positionCount - posCount,
            direction: direction,
            location: location
        )
    }

    /// Enqueues a single page load at the given index, if valid.
    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }
        loadingIndexQueue.removeAll { $0.index == index }
        loadingIndexQueue.append((index, location))
        return true
    }

    // MARK: - Navigation

    /// Moves to the given index, optionally animating.
    @discardableResult
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        if currentIndex == index {
            if let view = currentView {
                await view.go(to: location)
            }
        } else {
            await fadeToView(at: index, location: location, animated: options.animated)
        }
        return true
    }

    /// Fades out, moves to the target index, then fades back in.
    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
        func fade(alpha: CGFloat) async {
            if animated {
                await withCheckedContinuation { continuation in
                    UIView.animate(withDuration: 0.15, animations: {
                        self.alpha = alpha
                    }) { _ in
                        continuation.resume()
                    }
                }
            } else {
                self.alpha = alpha
            }
        }

        await fade(alpha: 0)
        await scrollToView(at: index, location: location)
        await fade(alpha: 1)
    }

    /// Scrolls to the given index without fade animation.
    private func scrollToView(at index: Int, location: PageLocation) async {
        guard currentIndex != index else {
            if let view = currentView {
                await view.go(to: location)
            }
            return
        }

        scrollView.isScrollEnabled = true
        await setCurrentIndex(index, location: location)

        let size = scrollView.frame.size

        switch axis {
        case .horizontal:
            scrollView.scrollRectToVisible(
                CGRect(
                    origin: CGPoint(
                        x: xOffsetForIndex(index, containerWidth: size.width),
                        y: scrollView.contentOffset.y
                    ),
                    size: size
                ),
                animated: false
            )
        case .vertical:
            scrollView.scrollRectToVisible(
                CGRect(
                    origin: CGPoint(
                        x: scrollView.contentOffset.x,
                        y: yOffsetForIndex(index, containerHeight: size.height)
                    ),
                    size: size
                ),
                animated: false
            )
        }
    }
}

// MARK: - UIScrollViewDelegate

extension PaginationView: UIScrollViewDelegate {
    /// Disables scrolling after drag is released, so the user can only move one page at a time.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = true
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = true
        let size = scrollView.frame.size

        switch axis {
        case .horizontal:
            let currentOffset = (readingProgression == .rtl)
                ? scrollView.contentSize.width - (scrollView.contentOffset.x + size.width)
                : scrollView.contentOffset.x
            let newIndex = Int(round(currentOffset / size.width))
            Task { await setCurrentIndex(newIndex) }

        case .vertical:
            let currentOffset = scrollView.contentOffset.y
            let newIndex = Int(round(currentOffset / size.height))
            Task { await setCurrentIndex(newIndex) }
        }
    }
}
