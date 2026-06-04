import AppKit

/// The expanded view shown when the menu bar gauge is clicked: one card per
/// provider with 5-hour and weekly bars, reset countdowns, plan label, and a
/// footer with Refresh / Quit.
@MainActor
final class PopoverViewController: NSViewController {
    private static let cardWidth: CGFloat = 280
    private static let popoverWidth: CGFloat = cardWidth + 24

    /// Called when the user taps Refresh. Assignable so the owner can wire it up
    /// after construction.
    var onRefresh: () -> Void = {}
    private var snapshots: [UsageSnapshot] = []
    private let stack = NSStackView()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 200))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        view = container
    }

    /// Replaces the popover contents with the latest snapshots.
    func update(with snapshots: [UsageSnapshot]) {
        self.snapshots = snapshots
        guard isViewLoaded else { return }
        render()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        stack.addArrangedSubview(header())

        let ordered = Provider.allCases.compactMap { provider in
            snapshots.first { $0.provider == provider }
        }
        let cards = ordered.isEmpty
            ? Provider.allCases.map { UsageSnapshot.disconnected($0) }
            : ordered
        for snapshot in cards {
            stack.addArrangedSubview(card(for: snapshot))
        }

        stack.addArrangedSubview(footer())

        // Lay out, then size the popover to fit.
        view.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        preferredContentSize = NSSize(
            width: Self.popoverWidth,
            height: fitting.height + 24
        )
    }

    private func header() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2

        let title = NSTextField(labelWithString: "Usage")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        container.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Claude & ChatGPT limits")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        container.addArrangedSubview(subtitle)

        return container
    }

    private func footer() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "r"
        row.addArrangedSubview(refresh)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        quit.bezelStyle = .rounded
        row.addArrangedSubview(quit)

        return row
    }

    private func card(for snapshot: UsageSnapshot) -> NSView {
        let innerWidth = Self.cardWidth - 24

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .clear
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                content.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10)
            ])
        }

        content.addArrangedSubview(headerRow(for: snapshot, width: innerWidth))

        if !snapshot.isConnected {
            let note = NSTextField(wrappingLabelWithString: "Not signed in.")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = innerWidth
            content.addArrangedSubview(note)

            let login = NSButton(title: "Sign in to \(snapshot.provider.rawValue)",
                                 target: self, action: #selector(loginTapped(_:)))
            login.bezelStyle = .rounded
            login.identifier = NSUserInterfaceItemIdentifier(snapshot.provider.rawValue)
            content.addArrangedSubview(login)
        } else if let error = snapshot.error {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = .systemFont(ofSize: 12)
            errorLabel.textColor = .systemOrange
            errorLabel.preferredMaxLayoutWidth = innerWidth
            content.addArrangedSubview(errorLabel)
        } else {
            content.addArrangedSubview(limitBar(caption: "5-hour", percent: snapshot.dailyPercent, width: innerWidth))
            content.addArrangedSubview(resetRow(label: "5h resets", date: snapshot.dailyResetAt, width: innerWidth))
            content.setCustomSpacing(10, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(limitBar(caption: "Weekly", percent: snapshot.weeklyPercent, width: innerWidth))
            content.addArrangedSubview(resetRow(label: "Week resets", date: snapshot.weeklyResetAt, width: innerWidth))

            let meta = NSTextField(labelWithString: metaText(for: snapshot))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .tertiaryLabelColor
            meta.lineBreakMode = .byTruncatingTail
            content.addArrangedSubview(meta)
            content.setCustomSpacing(10, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        }

        return box
    }

    private func headerRow(for snapshot: UsageSnapshot, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true

        let icon = NSImageView(image: ProviderBranding.icon(for: snapshot.provider, size: 20))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        row.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: snapshot.provider.rawValue)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = snapshot.error == nil ? .labelColor : .systemOrange
        row.addArrangedSubview(name)

        if let plan = snapshot.planLabel {
            let planLabel = NSTextField(labelWithString: plan.uppercased())
            planLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            planLabel.textColor = .tertiaryLabelColor
            row.addArrangedSubview(planLabel)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let dotColor: NSColor
        if !snapshot.isConnected {
            dotColor = .systemOrange
        } else if snapshot.error != nil {
            dotColor = .systemGray
        } else {
            dotColor = UsageFormat.color(forPercent: snapshot.headlinePercent ?? 0)
        }
        let dot = StatusDotView(color: dotColor)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(dot)

        return row
    }

    private func limitBar(caption: String, percent: Double?, width: CGFloat) -> NSView {
        let bar = PopoverLimitBar(caption: caption, percent: percent)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return bar
    }

    /// A small right-aligned reset caption beneath a window's usage bar, e.g.
    /// `5h resets in 2h 14m  ·  9:00 PM`.
    private func resetRow(label: String, date: Date?, width: CGFloat) -> NSView {
        let text: String
        if let date {
            let relative = UsageFormat.resetText(date)
            let clock = Self.clockFormatter.string(from: date)
            text = relative == "now" ? "\(label) now" : "\(label) in \(relative)  ·  \(clock)"
        } else {
            text = "\(label) —"
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.alignment = .right
        return field
    }

    private func metaText(for snapshot: UsageSnapshot) -> String {
        var parts: [String] = []
        if let tokens = snapshot.totalTokens, tokens > 0 {
            parts.append("\(UsageFormat.tokenText(tokens)) tokens")
        }
        parts.append("updated \(relativeFormatter.localizedString(for: snapshot.updatedAt, relativeTo: Date()))")
        return parts.joined(separator: "  ·  ")
    }

    @objc private func refreshTapped() {
        onRefresh()
    }

    @objc private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func loginTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let provider = Provider(rawValue: raw) else { return }
        NSWorkspace.shared.open(provider.loginURL)
    }
}
