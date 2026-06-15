import Foundation

#if !canImport(ObjectiveC)
@discardableResult
func autoreleasepool<Result>(_ work: () throws -> Result) rethrows -> Result {
    try work()
}
#endif

#if os(Windows)
public typealias pid_t = Int32
#endif
