import SwiftData

/// Adds per-keyword free-form tag records without changing any V1-V5
/// persistent model definition.
enum OpenASOSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(6, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV5.models + [
            TrackedKeywordTagRecord.self
        ]
    }
}
