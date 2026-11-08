import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let duocordServerMove = UTType(exportedAs: "com.saphid.duocord.server-move", conformingTo: .data)
}

struct ServerDragSource: ViewModifier {
    @Environment(AppModel.self) private var model
    let guild: Snowflake

    func body(content: Content) -> some View {
        content.onDrag {
            let provider = NSItemProvider()
            let receipt = model.serverDrag(guild)
            guard !receipt.isEmpty else { return provider }
            provider.registerDataRepresentation(forTypeIdentifier: UTType.duocordServerMove.identifier, visibility: .all) { completion in
                completion(Data(receipt.utf8), nil)
                return nil
            }
            return provider
        }
    }
}

struct ServerDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let before: Snowflake?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted && !model.servers.busy {
                    Capsule().fill(Color.accentBlurple).frame(width: 44, height: 3).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.duocordServerMove.identifier], isTargeted: $targeted) { providers in
                guard providers.count == 1, !model.servers.busy else { return false }
                providers[0].loadDataRepresentation(forTypeIdentifier: UTType.duocordServerMove.identifier) { data, _ in
                    guard let data, data.count < 100, let receipt = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in model.receiveServerDrag(receipt, before: before) }
                }
                return true
            }
    }
}
