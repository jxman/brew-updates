import Foundation

extension Result where Failure == Error {
    /// `Result { try await ... }` - capture an async throwing call as a value.
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
