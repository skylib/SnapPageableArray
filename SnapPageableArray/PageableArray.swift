import Foundation

public struct PageableArray<T: DTOProtocol> {
    public typealias Element = T


    private var elements: [ElementWithState<T>]
    public var pageSize: UInt
    public var numberOfItemsAheadOfLastToTriggerLoadMore: UInt

    weak public var delegate: PageableArrayDelegate?

    public init(capacity: UInt, pageSize: UInt) {
        self.pageSize = pageSize
        self.numberOfItemsAheadOfLastToTriggerLoadMore = pageSize / 2

        self.elements = [ElementWithState]()
        for _ in 0..<capacity {
            self.elements.append(ElementWithState(element: nil, state: .Unavailable))
        }
    }

    public var count: UInt {
        get {
            return UInt(self.elements.count)
        }
    }

    mutating private func markElementsInRangeAsRequested(range: Range<UInt>) {
        let timestamp = NSDate().timeIntervalSince1970
        for i in range where i < UInt(self.elements.count) {
            let updatedElement = self.elements[Int(i)]
            updatedElement.state = .Requested(timestamp: timestamp)
            self.elements[Int(i)] = updatedElement
        }
    }

    mutating public func topUpWithElements(elements: [T]) -> UpdateResult {
        var newItems = 0
        var allNewElements = [ElementWithState<T>]()

        for newElement in elements {
            guard let newElementId = newElement.id else {
                continue
            }

            var didReplace = false
            for i in 0..<self.elements.count {

                if let oldElementId = self.elements[i].element?.id where
                   newElementId == oldElementId {
                        let updatedElement = ElementWithState(element: newElement, state: .Available)
                        self.elements[i] = updatedElement
                        didReplace = true

                        break
                    }
            }

            if didReplace == false {
                let newElement = ElementWithState(element: newElement, state: .Available)
                allNewElements.append(newElement)
                newItems += 1
            }
        }

        self.elements = allNewElements + self.elements

        if allNewElements.count == elements.count {
            return .AllNewItems
        } else if allNewElements.count == 0 {
            return .NoNewItems
        }

        return .SomeNewItems(newItems: newItems)
    }

    mutating public func appendElement(element: T) {

        let newElement = ElementWithState(element: element, state: .Available)
        self.elements.append(newElement)
    }

    mutating public func updatePage(page: Pageable, withElements elements: [T], offset: UInt = 0) {
        let start = page.startItemIndex + offset
        let end = start + UInt(elements.count)
        if start == end && elements.count == 0 {
            return
        }

        assert(start <= UInt(self.elements.count) + offset)
        assert(end <= UInt(self.elements.count) + offset)

        if start < end {
            for i in start..<end {
                let updatedElement = ElementWithState(element: elements[Int(i - start)], state: .Available)
                self.elements[Int(i)] = updatedElement
            }
        }

    }

    mutating public func markAllItemsAsNeedToReload() {
        for i in 0..<Int(count) {
            let oldElement = elements[i]
            switch(oldElement.state) {
            case .Unavailable:
                continue
            default:
                let newElement = oldElement
                newElement.state = .Unavailable
                elements[i] = newElement
            }
        }
    }

    mutating public func resizeTo(newSize: UInt) {
        var newElements = [ElementWithState<T>]()
        let oldSize = UInt(self.elements.count)
        for i in 0..<newSize {
            if i < oldSize {
                newElements.append(self.elements[Int(i)])
            } else {
                newElements.append(ElementWithState(element: nil, state: .Unavailable))
            }
        }
        self.elements = newElements
    }

    public subscript(index: UInt) -> T? {
        mutating get {
            if index >= UInt(self.elements.count) {
                return nil
            } else {
                willServeItemAtIndex(index)
                return self.elements[Int(index)].element
            }
        }

        mutating set {
            guard let newValue = newValue else {
                return
            }

            if index >= UInt(self.elements.count) {
                return
            } else {
                let oldElement = self.elements[Int(index)]
                let newElement: ElementWithState<T>
                switch(oldElement.state) {
                case .Unavailable:
                    newElement = ElementWithState<T>(element: newValue, state: .Available)
                default:
                    newElement = ElementWithState<T>(element: newValue, state: oldElement.state)

                }
                self.elements[Int(index)] = newElement

            }
        }
    }

    public mutating func removeElementAtIndex(index: UInt) {
        elements.removeAtIndex(Int(index))
        resizeTo(UInt(elements.count))
    }

    public func hasElementAtIndex(index: UInt) -> Bool { // Peek, without triggering fetch
        if index >= UInt(elements.count) { return false }
        let elementWithState = self.elements[Int(index)]
        switch elementWithState.state {
        case .Available:
            return true
        default:
            return false
        }
    }

    private mutating func willServeItemAtIndex(index: UInt) {
        let end = min(self.count, index + numberOfItemsAheadOfLastToTriggerLoadMore)
        let range = index..<end
        for i in range {
            let element = self.elements[Int(i)]
            if element.state.isUnavailable() {
                let requestRange = i..<min(self.count, (i+pageSize))
                markElementsInRangeAsRequested(requestRange)
                delegate?.loadContentForRange(requestRange, pageSize: pageSize)
                return
            }
        }
    }

    public func persist() -> [UInt64?] {
        return elements.map { return $0.element?.id }
    }

    mutating public func removeElementsMatching(matcher: Element -> (Bool)) -> UInt {

        var indexes = [UInt]()
        for index in 0..<UInt(elements.count) {

            guard let element = self[index] else { continue }

            if matcher(element) == true {
                indexes.append(index)
            }
        }

        for i in 0..<indexes.count {
            let pos = UInt(indexes.count - 1 - i)
            removeElementAtIndex(pos)
        }

        return UInt(indexes.count)
    }
}

extension PageableArray : PageableArrayProtocol { }
