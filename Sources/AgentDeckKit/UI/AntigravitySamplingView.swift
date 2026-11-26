import SwiftUI

private struct SamplingStoreKey: EnvironmentKey {
    static let defaultValue: AppStore? = nil
}

extension EnvironmentValues {
    var samplingStore: AppStore? {
        get { self[SamplingStoreKey.self] }
        set { self[SamplingStoreKey.self] = newValue }
    }
}

struct AntigravitySamplingView: View {
    let state: AntigravitySamplingState
    @Environment(\.samplingStore) private var store

    var body: some View {
        if let store {
            InteractiveState(state: state, store: store)
        } else {
            Text(L(state.messageKey)).font(.caption).foregroundStyle(Theme.ink3)
        }
    }

    private struct InteractiveState: View {
        let state: AntigravitySamplingState
        @ObservedObject var store: AppStore
        var body: some View {
            let shown = store.antigravitySetupReply ?? state
            VStack(alignment: .leading, spacing: 4) {
                Text(L(shown.messageKey)).fixedSize(horizontal: false, vertical: true)
                if shown == .available {
                    Button {
                        Task { await store.enableAntigravitySampling() }
                    } label: {
                        Label(L("quota.ag.enable"), systemImage: "plus.circle")
                    }.buttonStyle(.borderless).disabled(store.enablingAntigravity)
                    if store.antigravitySetupFailed {
                        Text(L("common.opFailed")).foregroundStyle(Theme.warn)
                    }
                }
            }.font(.caption).foregroundStyle(Theme.ink2)
        }
    }
}
