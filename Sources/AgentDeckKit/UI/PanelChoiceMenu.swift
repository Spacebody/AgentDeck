import SwiftUI

struct PanelChoiceMenu: View {
    struct Choice: Identifiable {
        let id: String
        let title: String
    }
    let title: String
    let selected: String
    let choices: [Choice]
    let onSelect: (String) -> Void
    @State private var open = false
    @State private var hover: String?
    @FocusState private var focused: String?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(open ? DashboardStyle.accent : Theme.ink2)
            .padding(.horizontal, 6).frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(choices) { option in
                    let current = selected == option.id
                    Button {
                        open = false
                        onSelect(option.id)
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.title)
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(current ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .font(.system(size: 13, weight: current ? .medium : .regular)).monospacedDigit()
                        .foregroundStyle(current ? DashboardStyle.accent : Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(hover == option.id ? Color.white.opacity(0.10)
                                  : current ? DashboardStyle.accent.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .focused($focused, equals: option.id)
                    .onHover { inside in
                        if inside { hover = option.id } else if hover == option.id { hover = nil }
                    }
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            .padding(6).frame(minWidth: 156).fixedSize()
            .background(DashboardStyle.background)
            .preferredColorScheme(.dark)
            .onAppear {
                hover = nil
                focused = choices.first { $0.id == selected }?.id ?? choices.first?.id
            }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down, !choices.isEmpty else { return }
                let i = choices.firstIndex { $0.id == focused } ?? 0
                focused = choices[(i + (direction == .down ? 1 : choices.count - 1)) % choices.count].id
            }
            .onExitCommand { open = false }
        }
    }
}
