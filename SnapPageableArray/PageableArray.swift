import Foundation

public struct PageableArray<T: DTOProtocol> {
    public typealias Element = T


    fileprivate var elements: [ElementWithState<T>]
    fileprivate var indexes: [UInt64: UInt]
    public var pageSize: UInt
    public var numberOfItemsAheadOfLastToTriggerLoadMore: UInt

    weak public var delegate: PageableArrayDelegate?

    public init(capacity: UInt, pageSize: UInt) {
        self.pageSize = pageSize
        self.numberOfItemsAheadOfLastToTriggerLoadMore = pageSize / 2

        self.elements = [ElementWithState]()
        for _ in 0..<capacity {
            self.elements.append(ElementWithState(element: nil, state: .unavailable))
        }
        self.indexes = [UInt64: UInt]()
    }
    
    public init(items: [T]) {
        self.pageSize = UInt(items.count)
        self.numberOfItemsAheadOfLastToTriggerLoadMore = UInt(items.count)
        
        self.indexes = [UInt64: UInt]()
        self.elements = [ElementWithState]()

        var index: UInt = 0
        for item in items {
            self.elements.append(ElementWithState(element: item, state: .available))
            if let id = item.id {
                indexes[id] = index
            }
            index += 1
        }
    }

    public var count: UInt {
        get {
            return UInt(self.elements.count)
        }
    }

    mutating fileprivate func markElementsInRangeAsRequested(_ range: CountableRange<UInt>) {
        let timestamp = Date().timeIntervalSince1970
        for i in range where i < UInt(self.elements.count) {
            self.elements[Int(i)].state = .requested(timestamp: timestamp)
        }
    }

    mutating public func topUpWithElements(_ elements: [T]) -> UpdateResult {
        var newItems = 0
        var allNewElements = [ElementWithState<T>]()

        for newElement in elements {
            guard let newElementId = newElement.id else {
                continue
            }

            var didReplace = false
            for i in 0..<self.elements.count {

                if let oldElementId = self.elements[i].id ,
                   newElementId == oldElementId {
                    self.elements[i].element = newElement
                    self.elements[i].state = .available
                    didReplace = true

                    break
                }
            }

            if didReplace == false {
                let newElement = ElementWithState(element: newElement, state: .available)
                allNewElements.append(newElement)
                newItems += 1
            }
        }

        self.elements = allNewElements + self.elements

        if allNewElements.count == elements.count {
            return .allNewItems
        } else if allNewElements.count == 0 {
            return .noNewItems
        }

        return .someNewItems(newItems: newItems)
    }

    mutating public func appendElement(_ element: T) {
        if let id = element.id {
            indexes[id] = count
        }
        let newElement = ElementWithState(element: element, state: .available)
        self.elements.append(newElement)
    }

    mutating public func updatePage(_ page: Pageable, withElements elements: [T], offset: UInt = 0) {
        let start = page.startItemIndex + offset
        let end = start + UInt(elements.count)
        
        if start == end && elements.count == 0 {
            return
        }

        if start < end {
            for i in start..<end {
                if i < count {
                    if self.elements[Int(i)].id != elements[Int(i - start)].id {
                        if let oldId = self.elements[Int(i)].id {
                            indexes[oldId] = nil
                        }
                        if let newId = elements[Int(i - start)].id {
                            indexes[newId] = i
                        }
                    }
                    self.elements[Int(i)].element = elements[Int(i - start)]
                    self.elements[Int(i)].state = .available
                }
            }
        }
    }

    mutating public func markAllItemsAsNeedToReload() {
        for i in 0..<Int(count) {
            switch(elements[i].state) {
            case .unavailable:
                continue
            default:
                elements[i].state = .unavailable
            }
        }
    }

    mutating public func resizeTo(_ newSize: UInt) {
        var newElements = [ElementWithState<T>]()
        let oldSize = UInt(self.elements.count)
        for i in 0..<newSize {
            if i < oldSize {
                newElements.append(self.elements[Int(i)])
                if let id = self.elements[Int(i)].id {
                    indexes[id] = i
                }
            } else {
                newElements.append(ElementWithState(element: nil, state: .unavailable))
            }
        }
        self.elements = newElements
    }
    
    mutating public func updateElements(_ updatedElements: [T]) -> [UInt] {
        var array = [UInt]()
        for element in updatedElements {
            if let id = element.id,
               let index = mapIdToIndex(id) , hasElementAtIndex(index) {
                elements[Int(index)].element = element
                array.append(index)
            }
        }
        
        return array
    }
    
    fileprivate func mapIdToIndex(_ id: UInt64) -> UInt? {
        return indexes[id]
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
                if oldElement.id != newValue.id {
                    if let oldId = oldElement.id {
                        indexes[oldId] = nil
                    }
                    if let newId = newValue.id {
                        indexes[newId] = index
                    }
                }
                switch(oldElement.state) {
                case .unavailable:
                    self.elements[Int(index)].element = newValue
                    self.elements[Int(index)].state = .available
                default:
                    self.elements[Int(index)].element = newValue

                }
            }
        }
    }

    public mutating func removeElementAtIndex(_ index: UInt) {
        if index < count {
            let element = elements[Int(index)]
            if let id = element.id {
                indexes[id] = nil
            }
        }
        elements.remove(at: Int(index))
        resizeTo(UInt(elements.count))
    }

    public func hasElementAtIndex(_ index: UInt) -> Bool { // Peek, without triggering fetch
        if index >= UInt(elements.count) { return false }
        let elementWithState = self.elements[Int(index)]
        switch elementWithState.state {
        case .available:
            return true
        default:
            return false
            
        }
    }

    fileprivate mutating func willServeItemAtIndex(_ index: UInt) {
        let end = Int(min(self.count, index + numberOfItemsAheadOfLastToTriggerLoadMore)) - 1
        let element = elements[end]
        if element.state.isUnavailable() {
            let requestRange = index..<min(self.count, (index + pageSize))
            markElementsInRangeAsRequested(requestRange)
            delegate?.loadContentForRange(requestRange, pageSize: pageSize)
        }
    }

    public func persist() -> [UInt64?] {
        return elements.map { return $0.element?.id }
    }

    mutating public func removeElementsMatching(_ matcher: (Element) -> (Bool)) -> UInt {

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

extension PageableArray : CustomStringConvertible {
    public var description: String {
        var str = ""
        for i in 0..<count {
            let element = elements[Int(i)]
            str = "\(str)Index: \(i), \(element.description) \n"
            if element.element == nil {
                break
            }
        }
        
        return str
    }
}
