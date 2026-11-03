// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The "In a meeting" menu bar icon options: the icon the status item shows
/// while the switch is on, its color and its transparency. The first cell is
/// the current menu bar mark, the next three are the offered symbols, and the
/// last takes any other symbol by name, like the menu bar icon gallery does.
/// Everything renders through the same drawing the status item uses, so a
/// cell previews exactly what the menu bar will show.
struct InMeetingIconPicker: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.inMeetingMenuBarSymbol) private var symbolName = ""
    @AppStorage(DefaultsKey.inMeetingIconTint) private var tintValue = InMeetingIconTint.orange.rawValue
    @AppStorage(DefaultsKey.inMeetingIconOpacity) private var opacity = 1.0
    @State private var typingName = false

    /// Filtered like the menu bar gallery, so a symbol a future macOS drops
    /// leaves no empty cell.
    private static let symbols = Defaults.inMeetingIconGallery.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    private var strings: QuickToggleFeatureStrings { FeatureStrings.quickToggles(l10n.language) }

    private var selectedSymbol: String {
        Defaults.sanitizedMenuBarIconSymbol(symbolName)
    }

    private var selectedTint: InMeetingIconTint {
        Defaults.sanitizedInMeetingIconTint(tintValue)
    }

    /// A stored name that is none of the offered cells rides on the last one.
    private var otherName: String {
        selectedSymbol.isEmpty || Self.symbols.contains(selectedSymbol) ? "" : selectedSymbol
    }

    var body: some View {
        let text = FeatureStrings.generalSettings(l10n.language)
        VStack(alignment: .leading, spacing: 10) {
            choiceHeader(strings.inMeetingActiveIcon,
                         value: selectedSymbol.isEmpty ? "Vorssaint" : selectedSymbol)
            HStack(spacing: 7) {
                iconCell(selected: selectedSymbol.isEmpty) {
                    symbolName = ""
                } label: {
                    preview(symbol: "")
                }
                .help(text.menuBarIconReset)
                .accessibilityLabel(text.menuBarIconReset)
                ForEach(Self.symbols, id: \.self) { symbol in
                    iconCell(selected: selectedSymbol == symbol) {
                        symbolName = symbol
                    } label: {
                        preview(symbol: symbol)
                    }
                    .help(symbol)
                }
                iconCell(selected: !otherName.isEmpty) {
                    typingName = true
                } label: {
                    // A name from a newer macOS has nothing to draw here.
                    otherLabel
                }
                .help(otherName.isEmpty ? text.menuBarIconOther : otherName)
                .accessibilityLabel(text.menuBarIconOther)
                .popover(isPresented: $typingName, arrowEdge: .bottom) {
                    InMeetingSymbolNameField()
                }
            }

            choiceHeader(strings.inMeetingActiveIconColor,
                         value: selectedTint.title(strings))
            HStack(spacing: 8) {
                ForEach(InMeetingIconTint.allCases) { tint in
                    tintButton(tint)
                }
            }

            choiceHeader(strings.inMeetingIconOpacity,
                         value: "\(Int((opacity * 100).rounded()))%")
            Slider(value: $opacity, in: 0.2...1)
                .accessibilityLabel(strings.inMeetingIconOpacity)
        }
        .onAppear {
            opacity = Defaults.sanitizedInMeetingIconOpacity(opacity)
        }
    }

    private func choiceHeader(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func iconCell<Label: View>(selected: Bool,
                                       action: @escaping () -> Void,
                                       @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: 21, maxHeight: 16)
                .frame(maxWidth: .infinity)
                .frame(height: 35)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.14)
                                       : Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.75)
                                               : Color.secondary.opacity(0.13),
                                      lineWidth: selected ? 1.2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The symbol rendered the way the status item renders it, tint and
    /// transparency included; an empty name means the current menu bar mark.
    private func preview(symbol: String) -> some View {
        Group {
            if let image = BlackHoleGlyph.inMeetingImage(symbol: symbol,
                                                         tint: selectedTint,
                                                         opacity: opacity) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var otherLabel: some View {
        if !otherName.isEmpty, BlackHoleGlyph.customMark(named: otherName) != nil {
            preview(symbol: otherName)
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func tintButton(_ tint: InMeetingIconTint) -> some View {
        let selected = tint == selectedTint
        return Button {
            tintValue = tint.rawValue
        } label: {
            ZStack {
                if let color = tintColor(tint) {
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.2)
                        .frame(width: 14, height: 14)
                    // "slash" is not a symbol the system has, so the bar
                    // across the circle was never drawn: the choice for no
                    // icon showed an empty ring.
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear,
                                  lineWidth: 1.1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tint.title(strings))
        .accessibilityLabel(tint.title(strings))
    }

    private func tintColor(_ tint: InMeetingIconTint) -> Color? {
        switch tint {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        case .none: return nil
        }
    }
}

/// Takes any symbol by name for the "In a meeting" icon. The icon follows
/// the typing: a name this Mac has a symbol for is kept at once, and any
/// other name brings back the icon the field opened with, so a typo never
/// leaves a valid half of the name behind.
private struct InMeetingSymbolNameField: View {
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.inMeetingMenuBarSymbol) private var savedName = ""
    @State private var draft = ""
    @State private var openingName = ""
    @FocusState private var focused: Bool

    private var text: GeneralSettingsStrings { FeatureStrings.generalSettings(l10n.language) }

    var body: some View {
        let name = Defaults.sanitizedMenuBarIconSymbol(draft)
        VStack(alignment: .leading, spacing: 8) {
            Text(text.menuBarIconOther)
                .font(.headline)
            HStack(spacing: 6) {
                TextField(text.menuBarIconOther, text: $draft, prompt: Text(verbatim: "person.crop.circle.badge.clock"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { dismiss() }
                // Kept in place while hidden, so the field does not change
                // width as the name is typed or cleared.
                Button {
                    draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(text.menuBarIconReset)
                .accessibilityLabel(text.menuBarIconReset)
                .opacity(draft.isEmpty ? 0 : 1)
                .disabled(draft.isEmpty)
                .accessibilityHidden(draft.isEmpty)
            }
            Text(text.menuBarIconOtherCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !name.isEmpty, BlackHoleGlyph.customMark(named: name) == nil {
                Text(text.menuBarIconUnknown)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            openingName = InMeetingService.storedSymbol
            draft = openingName
            // The popover's window is not key yet while it appears.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: draft) { _, newValue in
            let kept = Defaults.menuBarIconSymbolToSave(typed: newValue, opening: openingName) {
                BlackHoleGlyph.customMark(named: $0) != nil
            }
            if kept != savedName { savedName = kept }
        }
    }
}
