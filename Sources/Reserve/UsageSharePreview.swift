import AppKit
import ReserveCore

/// Preview of the sanitized usage card. Copy and Save both use the same model.
/// The panel never screenshots the dashboard and never uploads anything.
@MainActor
final class UsageSharePreviewController: NSWindowController, NSWindowDelegate {
  /// One account the person may narrow the card to, by its neutral name.
  struct Choice {
    let provider: ProviderID
    let name: String
  }

  private(set) var model: UsageShareModel
  private(set) var options: UsageShareOptions
  private let choices: [Choice]
  private let build: (UsageShareOptions) -> UsageShareModel
  private let pasteboard: NSPasteboard
  private let savePanelFactory: () -> NSSavePanel
  private let statusLabel = NSTextField(labelWithString: "")
  private let card: UsageShareCardView
  private let scrollView = NSScrollView()
  private var scrollHeight: NSLayoutConstraint?
  private let cardDocument = ShareCardDocumentView()
  private var limitsToggle: NSButton?
  private var costToggle: NSButton?
  private var modelsToggle: NSButton?

  private static let privacyNote =
    "Private by default. Account names, organizations, emails and file paths are never included."

  init(
    options: UsageShareOptions,
    choices: [Choice],
    build: @escaping (UsageShareOptions) -> UsageShareModel,
    pasteboard: NSPasteboard = .general,
    savePanelFactory: @escaping () -> NSSavePanel = { NSSavePanel() }
  ) {
    self.options = options
    self.choices = choices
    self.build = build
    self.model = build(options)
    self.pasteboard = pasteboard
    self.savePanelFactory = savePanelFactory
    self.card = UsageShareCardView(model: self.model)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: UsageShareCardView.cardWidth + 64, height: 600),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Share usage"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentView = self.makeContent()
    self.fitWindow(keepingTop: false)
  }

  /// A fixed card with no controls to change it. Used by automation.
  convenience init(
    model: UsageShareModel,
    pasteboard: NSPasteboard = .general,
    savePanelFactory: @escaping () -> NSSavePanel = { NSSavePanel() }
  ) {
    self.init(
      options: UsageShareOptions(), choices: [], build: { _ in model },
      pasteboard: pasteboard, savePanelFactory: savePanelFactory)
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    self.window?.center()
    self.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Copies onto the injected pasteboard. Automation passes a private board
  /// so the system clipboard is left alone.
  func copyForTesting() -> Bool {
    self.copyText()
    return self.pasteboard.string(forType: .string) == self.model.plainText()
  }

  /// Writes the card PNG without opening a save panel.
  func pngDataForTesting() throws -> Data {
    try UsageShareCardView.pngData(for: self.model, appearance: self.window?.effectiveAppearance)
  }

  /// Applies options as the controls would. Automation uses it to prove a
  /// change reaches the card.
  func applyForTesting(_ options: UsageShareOptions) {
    self.apply(options)
  }

  var cardHeightForTesting: CGFloat { self.card.bounds.height }

  func renderOpaque(to url: URL, appearance: NSAppearance) throws {
    guard let view = self.window?.contentView else { throw CocoaError(.fileWriteUnknown) }
    self.window?.appearance = appearance
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else { throw CocoaError(.fileWriteUnknown) }
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(bounds.width),
      pixelsHigh: Int(bounds.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    view.displayIgnoringOpacity(bounds, in: context ?? NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }

  // MARK: Content

  private func makeContent() -> NSView {
    self.card.identifier = NSUserInterfaceItemIdentifier("share-card")
    self.cardDocument.addSubview(self.card)
    self.cardDocument.frame = self.card.frame
    self.scrollView.documentView = self.cardDocument
    self.scrollView.hasVerticalScroller = true
    self.scrollView.autohidesScrollers = true
    self.scrollView.drawsBackground = false
    self.scrollView.borderType = .noBorder
    self.scrollView.translatesAutoresizingMaskIntoConstraints = false
    self.scrollView.identifier = NSUserInterfaceItemIdentifier("share-scroll")
    let scrollHeight = self.scrollView.heightAnchor.constraint(equalToConstant: self.card.bounds.height)
    scrollHeight.isActive = true
    self.scrollHeight = scrollHeight
    self.scrollView.widthAnchor.constraint(equalToConstant: UsageShareCardView.cardWidth).isActive = true

    let copy = NSButton(title: "Copy text", target: self, action: #selector(self.copyText))
    copy.identifier = NSUserInterfaceItemIdentifier("share-copy")
    copy.bezelStyle = .rounded
    copy.controlSize = .large
    copy.setAccessibilityLabel("Copy usage card text")
    let copyImage = NSButton(title: "Copy image", target: self, action: #selector(self.copyImage))
    copyImage.identifier = NSUserInterfaceItemIdentifier("share-copy-image")
    copyImage.bezelStyle = .rounded
    copyImage.controlSize = .large
    copyImage.setAccessibilityLabel("Copy usage card image")
    let save = NSButton(title: "Save image…", target: self, action: #selector(self.saveImage))
    save.identifier = NSUserInterfaceItemIdentifier("share-save")
    save.bezelStyle = .rounded
    save.controlSize = .large
    save.keyEquivalent = "\r"
    save.setAccessibilityLabel("Save usage card image")
    self.statusLabel.font = .systemFont(ofSize: 11)
    self.statusLabel.textColor = .secondaryLabelColor
    self.statusLabel.identifier = NSUserInterfaceItemIdentifier("share-status")
    self.statusLabel.stringValue = Self.privacyNote
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [copy, copyImage, spacer, save])
    buttons.orientation = .horizontal
    buttons.spacing = 10
    buttons.widthAnchor.constraint(equalToConstant: UsageShareCardView.cardWidth).isActive = true

    var views: [NSView] = []
    if !self.choices.isEmpty { views.append(self.makeControls()) }
    views += [self.scrollView, buttons, self.statusLabel]
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 32, bottom: 20, right: 32)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("share-preview")
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    return root
  }

  private func makeControls() -> NSView {
    let period = NSSegmentedControl(
      labels: ["Today", "7 days", "30 days"], trackingMode: .selectOne,
      target: self, action: #selector(self.periodChanged(_:)))
    period.selectedSegment = UsageShareOptions.periods.firstIndex(of: self.options.periodDays) ?? 1
    period.identifier = NSUserInterfaceItemIdentifier("share-period")
    period.setAccessibilityLabel("Usage period")

    let accounts = NSPopUpButton(frame: .zero, pullsDown: false)
    accounts.addItem(withTitle: "All providers")
    for choice in self.choices { accounts.addItem(withTitle: choice.name) }
    if let provider = self.options.provider,
      let index = self.choices.firstIndex(where: { $0.provider == provider })
    {
      accounts.selectItem(at: index + 1)
    }
    accounts.target = self
    accounts.action = #selector(self.providerChanged(_:))
    accounts.identifier = NSUserInterfaceItemIdentifier("share-provider")
    accounts.setAccessibilityLabel("Providers on the card")

    func toggle(_ title: String, _ on: Bool, _ id: String, _ action: Selector) -> NSButton {
      let button = NSButton(checkboxWithTitle: title, target: self, action: action)
      button.state = on ? .on : .off
      button.identifier = NSUserInterfaceItemIdentifier(id)
      return button
    }
    let limits = toggle("Limits", self.options.includesLimits, "share-limits", #selector(self.limitsChanged(_:)))
    let cost = toggle("API estimate", self.options.includesCost, "share-cost", #selector(self.costChanged(_:)))
    let models = toggle("Models", self.options.includesModels, "share-models", #selector(self.modelsChanged(_:)))
    self.limitsToggle = limits
    self.costToggle = cost
    self.modelsToggle = models
    self.updateToggleAvailability()
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [period, accounts, spacer, limits, cost, models])
    row.orientation = .horizontal
    row.spacing = 12
    row.widthAnchor.constraint(equalToConstant: UsageShareCardView.cardWidth).isActive = true
    return row
  }

  private func apply(_ options: UsageShareOptions) {
    self.options = options
    self.model = self.build(options)
    self.card.model = self.model
    self.cardDocument.frame = NSRect(origin: .zero, size: self.card.frame.size)
    self.statusLabel.stringValue = Self.privacyNote
    self.updateToggleAvailability()
    self.fitWindow(keepingTop: true)
  }

  /// A toggle for a section the selection has no data for is disabled, so
  /// switching it on can never add an empty or zero section.
  private func updateToggleAvailability() {
    var everything = self.options
    everything.includesLimits = true
    everything.includesCost = true
    everything.includesModels = true
    let full = self.build(everything)
    let available: [(NSButton?, Bool)] = [
      (self.limitsToggle, !full.plans.isEmpty),
      (self.costToggle, full.usage?.metric == .cost),
      (self.modelsToggle, full.usage.map { !$0.models.isEmpty || $0.otherModelTokens > 0 } ?? false),
    ]
    for (button, hasData) in available {
      button?.isEnabled = hasData
      button?.toolTip = hasData ? nil : "Nothing recorded for this period and provider."
    }
  }

  var enabledTogglesForTesting: [String] {
    [self.limitsToggle, self.costToggle, self.modelsToggle].compactMap { $0 }
      .filter(\.isEnabled).map(\.title)
  }

  /// The card scrolls only when it is taller than the screen allows.
  private func fitWindow(keepingTop: Bool) {
    guard let window = self.window, let content = window.contentView else { return }
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    let chrome: CGFloat = self.choices.isEmpty ? 120 : 160
    let viewport = min(self.card.bounds.height, max(320, visible - chrome - 40))
    self.scrollHeight?.constant = viewport
    content.layoutSubtreeIfNeeded()
    let size = content.fittingSize
    let top = window.frame.maxY
    window.setContentSize(NSSize(width: max(UsageShareCardView.cardWidth + 64, ceil(size.width)), height: ceil(size.height)))
    if keepingTop {
      var frame = window.frame
      frame.origin.y = top - frame.height
      window.setFrame(frame, display: true)
    }
    self.cardDocument.scroll(NSPoint(x: 0, y: 0))
  }

  @objc private func periodChanged(_ sender: NSSegmentedControl) {
    var options = self.options
    options.periodDays = UsageShareOptions.periods[max(0, min(2, sender.selectedSegment))]
    self.apply(options)
  }

  @objc private func providerChanged(_ sender: NSPopUpButton) {
    var options = self.options
    let index = sender.indexOfSelectedItem - 1
    options.provider = self.choices.indices.contains(index) ? self.choices[index].provider : nil
    self.apply(options)
  }

  @objc private func limitsChanged(_ sender: NSButton) {
    var options = self.options
    options.includesLimits = sender.state == .on
    self.apply(options)
  }

  @objc private func costChanged(_ sender: NSButton) {
    var options = self.options
    options.includesCost = sender.state == .on
    self.apply(options)
  }

  @objc private func modelsChanged(_ sender: NSButton) {
    var options = self.options
    options.includesModels = sender.state == .on
    self.apply(options)
  }

  @objc private func copyText() {
    let text = self.model.plainText()
    self.pasteboard.clearContents()
    let wrote = self.pasteboard.setString(text, forType: .string)
    self.statusLabel.stringValue = wrote ? "Text copied." : "Could not copy text."
    self.statusLabel.setAccessibilityLabel(self.statusLabel.stringValue)
  }

  @objc private func copyImage() {
    guard let data = try? UsageShareCardView.pngData(for: self.model, appearance: self.window?.effectiveAppearance)
    else {
      self.statusLabel.stringValue = "Could not copy image."
      return
    }
    self.pasteboard.clearContents()
    let wrote = self.pasteboard.setData(data, forType: .png)
    self.statusLabel.stringValue = wrote ? "Image copied." : "Could not copy image."
    self.statusLabel.setAccessibilityLabel(self.statusLabel.stringValue)
  }

  @objc private func saveImage() {
    let panel = self.savePanelFactory()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Reserve usage.png"
    panel.canCreateDirectories = true
    let model = self.model
    panel.begin { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        self.statusLabel.stringValue = "Save cancelled."
        return
      }
      do {
        try UsageShareCardView.pngData(
          for: model,
          appearance: self.window?.effectiveAppearance
        ).write(to: url, options: .atomic)
        self.statusLabel.stringValue = "Saved."
      } catch {
        self.statusLabel.stringValue = "Could not save image."
      }
    }
  }
}

/// Keeps the card pinned to the top of the scroll view.
final class ShareCardDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// Draws the share card from the safe model. The image has its own hierarchy
/// and never screenshots the dashboard or preview controls.
@MainActor
final class UsageShareCardView: NSView {
  var model: UsageShareModel {
    didSet { self.resize() }
  }

  static let cardWidth: CGFloat = 720

  init(model: UsageShareModel) {
    self.model = model
    super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.measuredHeight(for: model)))
    self.setAccessibilityElement(true)
    self.setAccessibilityRole(.image)
    self.setAccessibilityLabel(model.plainText())
  }

  required init?(coder: NSCoder) { nil }

  /// The painter lays the card out once without drawing to learn its height,
  /// then again to draw, so text can never be cropped by a stale estimate.
  static func measuredHeight(for model: UsageShareModel) -> CGFloat {
    ceil(ShareCardPainter.render(model, on: ShareCanvas(drawing: false, height: 0)))
  }

  private func resize() {
    self.setFrameSize(NSSize(width: Self.cardWidth, height: Self.measuredHeight(for: self.model)))
    self.setAccessibilityLabel(self.model.plainText())
    self.needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    ShareCardPainter.render(self.model, on: ShareCanvas(drawing: true, height: self.bounds.height))
  }

  static func pngData(
    for model: UsageShareModel,
    appearance: NSAppearance? = nil
  ) throws -> Data {
    let height = Self.measuredHeight(for: model)
    let bounds = NSRect(x: 0, y: 0, width: Self.cardWidth, height: height)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(bounds.width * scale)),
      pixelsHigh: Int(ceil(bounds.height * scale)),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    rep.size = bounds.size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
      throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let draw = { ShareCardPainter.render(model, on: ShareCanvas(drawing: true, height: height)) }
    if let appearance {
      appearance.performAsCurrentDrawingAppearance { _ = draw() }
    } else {
      _ = draw()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}

/// Top-down drawing surface. Measuring and drawing run the same calls, so
/// the measured height is the drawn height.
@MainActor
private struct ShareCanvas {
  let drawing: Bool
  /// Total card height, used to turn top offsets into AppKit coordinates.
  let height: CGFloat

  func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: self.height - y - height, width: width, height: height)
  }

  static func lineHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }

  static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
    let rect = (text as NSString).boundingRect(
      with: NSSize(width: max(20, width), height: 10_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font])
    return max(ceil(rect.height), Self.lineHeight(font))
  }

  static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }

  /// Draws `text` at a top offset and returns its height. A single line
  /// truncates; otherwise it wraps.
  @discardableResult
  func text(
    _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor,
    alignment: NSTextAlignment = .left, singleLine: Bool = false
  ) -> CGFloat {
    let height = singleLine ? Self.lineHeight(font) : Self.textHeight(text, font: font, width: width)
    guard self.drawing else { return height }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
    (text as NSString).draw(
      with: self.rect(x, y, width, height),
      options: singleLine
        ? [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        : [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    return height
  }

  func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat, color: NSColor) {
    guard self.drawing, width > 0, height > 0 else { return }
    color.setFill()
    let radius = min(radius, width / 2, height / 2)
    NSBezierPath(roundedRect: self.rect(x, y, width, height), xRadius: radius, yRadius: radius).fill()
  }

  func image(_ image: NSImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    guard self.drawing else { return }
    image.draw(in: self.rect(x, y, size, size), from: .zero, operation: .sourceOver, fraction: 1)
  }
}

@MainActor
private enum ShareCardPainter {
  static let insetX: CGFloat = 32
  static let insetTop: CGFloat = 28
  static let insetBottom: CGFloat = 24
  static let sectionGap: CGFloat = 18
  static let tileGap: CGFloat = 12
  static let tilePadding: CGFloat = 16

  /// Lays out the card from the top and returns its height.
  @discardableResult
  static func render(_ model: UsageShareModel, on canvas: ShareCanvas) -> CGFloat {
    let width = UsageShareCardView.cardWidth
    if canvas.drawing { self.drawChrome(canvas, width: width) }
    let left = self.insetX
    let content = width - 2 * self.insetX
    var y = self.insetTop

    y += self.header(model, canvas: canvas, x: left, y: y, width: content)
    y += 20

    if let usage = model.usage {
      y += self.hero(usage, canvas: canvas, x: left, y: y, width: content)
      if self.hasChart(usage) {
        y += self.sectionGap
        y += self.chart(usage, canvas: canvas, x: left, y: y, width: content)
      }
      y += self.sectionGap
    }

    if !model.plans.isEmpty {
      y += self.limits(model, canvas: canvas, x: left, y: y, width: content)
      y += self.sectionGap
    }

    if let usage = model.usage {
      let breakdown = self.breakdown(usage, canvas: canvas, x: left, y: y, width: content)
      if breakdown > 0 { y += breakdown + self.sectionGap }
      if !usage.models.isEmpty || usage.otherModelTokens > 0 || usage.unattributedTokens > 0 {
        y += self.models(usage, canvas: canvas, x: left, y: y, width: content)
        y += self.sectionGap
      }
    }

    if model.isEmpty {
      y += self.tiles([{ canvas, x, y, width in
        canvas.text("No usage or limits recorded for this selection", x: x, y: y, width: width,
          font: .systemFont(ofSize: 16, weight: .semibold), color: self.secondary)
      }], canvas: canvas, x: left, y: y, width: content)
      y += self.sectionGap
    }

    y += self.footer(model, canvas: canvas, x: left, y: y - 4, width: content)
    return y + self.insetBottom
  }

  // MARK: Sections

  private static func header(
    _ model: UsageShareModel, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    canvas.fill(x, y, 34, 34, radius: 10, color: self.accent)
    canvas.text("R", x: x, y: y + 7, width: 34, font: .systemFont(ofSize: 16, weight: .bold),
      color: .white, alignment: .center, singleLine: true)
    canvas.text("Reserve", x: x + 46, y: y, width: 200, font: .systemFont(ofSize: 16, weight: .semibold),
      color: self.primary, singleLine: true)
    canvas.text(self.subtitle(model), x: x + 46, y: y + 19, width: 200, font: .systemFont(ofSize: 11.5),
      color: self.quiet, singleLine: true)
    let title: String
    let detail: String
    if let usage = model.usage {
      title = usage.periodLabel
      detail = usage.rangeLabel
    } else {
      title = "Plan limits"
      detail = model.generatedAt.formatted(date: .abbreviated, time: .omitted)
    }
    canvas.text(title, x: x + width - 300, y: y, width: 300, font: .systemFont(ofSize: 15, weight: .semibold),
      color: self.primary, alignment: .right, singleLine: true)
    canvas.text(detail, x: x + width - 300, y: y + 19, width: 300, font: .systemFont(ofSize: 11.5),
      color: self.secondary, alignment: .right, singleLine: true)
    return 34
  }

  /// Names the provider when the card is about only one, so a single-provider
  /// card still says whose usage it is.
  private static func subtitle(_ model: UsageShareModel) -> String {
    let kinds = Set(model.plans.map(\.kind) + (model.usage?.providers.compactMap(\.kind) ?? []))
    guard kinds.count == 1, let kind = kinds.first else { return "AI usage report" }
    return "\(kind.displayName) usage report"
  }

  private static func hero(
    _ usage: UsageShareModel.Usage, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    let value = usage.metric == .cost
      ? UsageShareFormat.money(usage.costUSD ?? 0) : UsageShareFormat.tokens(usage.tokens)
    y += canvas.text(value, x: x, y: y, width: width, font: .systemFont(ofSize: 52, weight: .bold),
      color: self.primary, singleLine: true)
    let caption = usage.metric == .cost
      ? "Estimated API equivalent · not an actual charge"
      : "Tokens processed"
    y += canvas.text(caption, x: x, y: y, width: width, font: .systemFont(ofSize: 13, weight: .medium),
      color: self.secondary)
    if !usage.unpricedNames.isEmpty {
      y += 3
      y += canvas.text(
        "No API price for \(UsageShareFormat.list(usage.unpricedNames)); their tokens are counted, not priced.",
        x: x, y: y, width: width, font: .systemFont(ofSize: 11), color: self.quiet)
    }

    var stats: [(value: String, label: String)] = []
    if usage.metric == .cost { stats.append((UsageShareFormat.tokens(usage.tokens), "Tokens")) }
    if usage.periodDays > 1 {
      stats.append(("\(usage.activeDays) of \(usage.periodDays)", "Active days"))
    }
    if let title = usage.peakTitle, let label = usage.peakLabel, let peak = usage.peakValue {
      stats.append((UsageShareFormat.value(peak, metric: usage.metric), "\(title) · \(label)"))
    }
    if let savings = usage.cacheSavingsUSD {
      stats.append((UsageShareFormat.money(savings) + (usage.cacheSavingsIsPartial ? "+" : ""), "Saved by caching"))
    }
    if usage.metric == .tokens, let cache = usage.tokenMix, cache.total > 0, cache.cacheRead > 0 {
      stats.append((UsageShareFormat.share(Double(cache.cacheRead) / Double(cache.total)), "Served from cache"))
    }
    // The average is the least telling figure, so it is the first to give way.
    if let average = usage.averagePerActiveDay {
      stats.append((UsageShareFormat.value(average, metric: usage.metric), "Per active day"))
    }
    let shown = Array(stats.prefix(4))
    guard !shown.isEmpty else { return y - start }
    y += 16
    let gap = self.tileGap
    let column = (width - gap * CGFloat(shown.count - 1)) / CGFloat(shown.count)
    let blocks = shown.map { stat -> TileContent in
      { canvas, x, y, width in
        var height = canvas.text(stat.value, x: x, y: y, width: width,
          font: .monospacedDigitSystemFont(ofSize: 20, weight: .semibold), color: self.primary, singleLine: true)
        height += 2
        height += canvas.text(stat.label, x: x, y: y + height, width: width,
          font: .systemFont(ofSize: 11, weight: .medium), color: self.secondary, singleLine: true)
        return height
      }
    }
    y += self.row(blocks, widths: Array(repeating: column, count: shown.count), canvas: canvas,
      x: x, y: y, padding: 12)
    return y - start
  }

  private static func hasChart(_ usage: UsageShareModel.Usage) -> Bool {
    usage.bars.count > 1 && usage.bars.contains { $0.total > 0 }
  }

  private static func chart(
    _ usage: UsageShareModel.Usage, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    let title = usage.barsAreHourly
      ? (usage.metric == .cost ? "Hourly API estimate" : "Hourly tokens")
      : (usage.metric == .cost ? "Daily API estimate" : "Daily tokens")
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    canvas.text(title, x: x, y: y, width: width / 2, font: titleFont, color: self.primary, singleLine: true)

    // Legend by provider kind, right-aligned on the title line.
    let kinds = ProviderKind.allCases.filter { kind in usage.bars.contains { $0.segments.contains { $0.kind == kind } } }
    if kinds.count > 1 {
      let font = NSFont.systemFont(ofSize: 11, weight: .medium)
      var right = x + width
      for kind in kinds.reversed() {
        let name = kind.displayName
        let textWidth = ShareCanvas.textWidth(name, font: font)
        right -= textWidth
        canvas.text(name, x: right, y: y + 1, width: textWidth + 2, font: font, color: self.secondary, singleLine: true)
        right -= 12
        canvas.fill(right, y + 5, 8, 8, radius: 4, color: self.providerColor(kind))
        right -= 12
      }
    }
    y += ShareCanvas.lineHeight(titleFont) + 10

    let chartHeight: CGFloat = 120
    let peak = usage.bars.map(\.total).max() ?? 0
    let axisFont = NSFont.systemFont(ofSize: 10)
    // Faint guides at the peak and halfway; the peak's value is in the stats.
    canvas.fill(x, y, width, 1, radius: 0, color: self.track)
    canvas.fill(x, y + chartHeight / 2, width, 1, radius: 0, color: self.track)
    let count = CGFloat(usage.bars.count)
    let gap: CGFloat = usage.bars.count > 14 ? 3 : 10
    let barWidth = max(2, (width - gap * (count - 1)) / count)
    let baseline = y + chartHeight
    for (index, bar) in usage.bars.enumerated() {
      let left = x + CGFloat(index) * (barWidth + gap)
      let total = bar.total
      if total <= 0 || peak <= 0 {
        canvas.fill(left, baseline - 2, barWidth, 2, radius: 1, color: self.track)
        continue
      }
      let barHeight = max(3, chartHeight * CGFloat(total / peak))
      if canvas.drawing {
        NSGraphicsContext.saveGraphicsState()
        let radius = min(4, barWidth / 2)
        NSBezierPath(roundedRect: canvas.rect(left, baseline - barHeight, barWidth, barHeight),
          xRadius: radius, yRadius: radius).addClip()
        var top = baseline
        for segment in bar.segments where segment.value > 0 {
          let height = barHeight * CGFloat(segment.value / total)
          top -= height
          self.providerColor(segment.kind).setFill()
          canvas.rect(left, top, barWidth, height + 0.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
      }
    }
    canvas.fill(x, baseline, width, 1, radius: 0, color: self.border)
    y = baseline + 6

    // Labels: every bar up to a week, then evenly spaced ending on the last.
    let stride = usage.bars.count <= 8 ? 1 : usage.barsAreHourly ? 6 : 7
    let labelWidth: CGFloat = 54
    for (index, bar) in usage.bars.enumerated() {
      let show = usage.barsAreHourly ? index % stride == 0 : (usage.bars.count - 1 - index) % stride == 0
      guard show, !bar.label.isEmpty else { continue }
      let center = x + CGFloat(index) * (barWidth + gap) + barWidth / 2
      let left = min(max(x, center - labelWidth / 2), x + width - labelWidth)
      let alignment: NSTextAlignment = left == x ? .left : left == x + width - labelWidth ? .right : .center
      canvas.text(bar.label, x: left, y: y, width: labelWidth, font: axisFont, color: self.quiet,
        alignment: alignment, singleLine: true)
    }
    y += ShareCanvas.lineHeight(axisFont)
    return y - start
  }

  private static func limits(
    _ model: UsageShareModel, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    canvas.text("Plan limits", x: x, y: y, width: width / 2, font: titleFont, color: self.primary, singleLine: true)
    if let checked = model.limitsCheckedAt {
      canvas.text("As of " + UsageShareFormat.moment(checked), x: x + width / 2, y: y + 1, width: width / 2,
        font: .systemFont(ofSize: 11), color: self.quiet, alignment: .right, singleLine: true)
    }
    y += ShareCanvas.lineHeight(titleFont) + 10

    let columns = model.plans.count > 1 ? 2 : 1
    let column = (width - self.tileGap * CGFloat(columns - 1)) / CGFloat(columns)
    var index = 0
    while index < model.plans.count {
      let pair = Array(model.plans[index..<min(index + columns, model.plans.count)])
      let blocks = pair.map { plan -> TileContent in
        { canvas, x, y, width in self.planTile(plan, canvas: canvas, x: x, y: y, width: width) }
      }
      y += self.row(blocks, widths: Array(repeating: column, count: pair.count), canvas: canvas, x: x, y: y)
      index += columns
      if index < model.plans.count { y += self.tileGap }
    }
    return y - start
  }

  private static func planTile(
    _ plan: UsageShareModel.Plan, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    self.logo(plan.kind, canvas: canvas, x: x, y: y, size: 20)
    let nameFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    canvas.text(plan.name, x: x + 28, y: y + 1, width: width - 28, font: nameFont,
      color: self.primary, singleLine: true)
    if let planName = plan.planName {
      let nameWidth = min(width - 28, ShareCanvas.textWidth(plan.name, font: nameFont))
      let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
      let badgeWidth = ShareCanvas.textWidth(planName, font: badgeFont) + 14
      let badgeX = x + 28 + nameWidth + 8
      if badgeX + badgeWidth <= x + width {
        canvas.fill(badgeX, y + 1, badgeWidth, 18, radius: 9, color: self.accent.withAlphaComponent(0.14))
        canvas.text(planName, x: badgeX, y: y + 3, width: badgeWidth, font: badgeFont,
          color: self.accentText, alignment: .center, singleLine: true)
      }
    }
    y += 20
    if plan.limits.isEmpty {
      y += 10
      y += canvas.text("Limits unavailable", x: x, y: y, width: width, font: .systemFont(ofSize: 12),
        color: self.secondary)
      return y - start
    }
    for limit in plan.limits {
      y += 12
      let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
      let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
      let value = "\(UsageShareFormat.percent(limit.remainingPercent)) left"
      let valueWidth = ShareCanvas.textWidth(value, font: valueFont) + 2
      canvas.text(limit.label, x: x, y: y, width: width - valueWidth - 8, font: labelFont,
        color: self.primary, singleLine: true)
      canvas.text(value, x: x + width - valueWidth, y: y, width: valueWidth, font: valueFont,
        color: self.primary, alignment: .right, singleLine: true)
      y += ShareCanvas.lineHeight(labelFont) + 5
      self.meter(limit.remainingPercent, canvas: canvas, x: x, y: y, width: width, height: 6,
        color: limit.pace == .overPace || limit.pace == .exhausted ? self.warning : self.accent)
      y += 6 + 5
      // Pace and forecast on the left, the reset on the right; the reset
      // drops to its own line when both do not fit.
      let detailFont = NSFont.systemFont(ofSize: 11)
      let paceFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
      let reset = limit.resetsAt.map { "Resets " + UsageShareFormat.reset($0) }
      let resetWidth = reset.map { ShareCanvas.textWidth($0, font: detailFont) + 2 } ?? 0
      var leftWidth: CGFloat = 0
      var forecast: String?
      if let pace = limit.pace {
        leftWidth = 11 + ShareCanvas.textWidth(pace.label, font: paceFont)
        if let projected = limit.projectedRemainingAtResetPercent {
          forecast = " · ~\(UsageShareFormat.percent(projected)) at reset"
          leftWidth += ShareCanvas.textWidth(forecast!, font: detailFont)
        }
      }
      if let pace = limit.pace {
        let color = pace == .overPace || pace == .exhausted ? self.warning : self.success
        canvas.fill(x, y + 4, 7, 7, radius: 3.5, color: color)
        let paceWidth = ShareCanvas.textWidth(pace.label, font: paceFont)
        canvas.text(pace.label, x: x + 11, y: y, width: paceWidth + 2, font: paceFont, color: color, singleLine: true)
        if let forecast {
          canvas.text(forecast, x: x + 11 + paceWidth, y: y, width: width - 11 - paceWidth, font: detailFont,
            color: self.secondary, singleLine: true)
        }
      }
      if let reset {
        let fits = leftWidth == 0 || leftWidth + 12 + resetWidth <= width
        if !fits { y += ShareCanvas.lineHeight(detailFont) + 2 }
        canvas.text(reset, x: x + width - resetWidth, y: y, width: resetWidth, font: detailFont,
          color: self.secondary, alignment: .right, singleLine: true)
      }
      y += ShareCanvas.lineHeight(detailFont)
    }
    return y - start
  }

  private static func breakdown(
    _ usage: UsageShareModel.Usage, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    var blocks: [TileContent] = []
    // One provider's share is the whole headline; its row would only repeat it.
    if usage.providers.count > 1 {
      blocks.append { canvas, x, y, width in self.providerTile(usage, canvas: canvas, x: x, y: y, width: width) }
    }
    if let mix = usage.tokenMix, mix.total > 0 {
      blocks.append { canvas, x, y, width in
        self.mixTile(mix, usage: usage, canvas: canvas, x: x, y: y, width: width)
      }
    }
    guard !blocks.isEmpty else { return 0 }
    let column = (width - self.tileGap * CGFloat(blocks.count - 1)) / CGFloat(blocks.count)
    return self.row(blocks, widths: Array(repeating: column, count: blocks.count), canvas: canvas, x: x, y: y)
  }

  private static func providerTile(
    _ usage: UsageShareModel.Usage, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    y += self.tileHeading("By provider", unit: usage.metric == .cost ? "API estimate" : "Tokens",
      canvas: canvas, x: x, y: y, width: width)
    let peak = usage.providers.compactMap(\.share).max() ?? 1
    for line in usage.providers.prefix(6) {
      y += 10
      let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
      let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
      var value = UsageShareFormat.lineValue(line, metric: usage.metric)
      if let share = line.share, usage.providers.count > 1 { value += " · " + UsageShareFormat.share(share) }
      let valueWidth = ShareCanvas.textWidth(value, font: valueFont) + 2
      if let kind = line.kind { self.logo(kind, canvas: canvas, x: x, y: y, size: 16) }
      canvas.text(line.name, x: x + 22, y: y, width: width - 22 - valueWidth - 6, font: font,
        color: self.primary, singleLine: true)
      canvas.text(value, x: x + width - valueWidth, y: y, width: valueWidth, font: valueFont,
        color: usage.metric == .cost && line.costUSD == nil ? self.secondary : self.primary,
        alignment: .right, singleLine: true)
      y += ShareCanvas.lineHeight(font) + 4
      let fraction = (line.share ?? 0) / max(peak, 0.0001)
      canvas.fill(x + 22, y, width - 22, 4, radius: 2, color: self.track)
      canvas.fill(x + 22, y, max(4, (width - 22) * CGFloat(min(1, fraction))), 4, radius: 2,
        color: line.kind.map(self.providerColor) ?? self.accent)
      y += 4
    }
    return y - start
  }

  private static func mixTile(
    _ mix: UsageShareModel.Mix, usage: UsageShareModel.Usage, canvas: ShareCanvas,
    x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let start = y
    var y = y
    y += self.tileHeading("Token mix", unit: nil, canvas: canvas, x: x, y: y, width: width)
    y += 12
    let parts = UsageShareFormat.mixParts(mix)
    let colors: [String: NSColor] = [
      "Cache read": self.accent.withAlphaComponent(0.28),
      "Uncached input": self.accent.withAlphaComponent(0.55),
      "Cache write": self.accent.withAlphaComponent(0.78),
      "Output": self.accent,
    ]
    let total = Double(mix.total)
    if canvas.drawing, total > 0 {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: canvas.rect(x, y, width, 10), xRadius: 5, yRadius: 5).addClip()
      var left = x
      for (index, part) in parts.enumerated() {
        let partWidth = index == parts.count - 1
          ? x + width - left : max(3, width * CGFloat(Double(part.tokens) / total))
        (colors[part.label] ?? self.accent).setFill()
        canvas.rect(left, y, max(0, partWidth - 1), 10).fill()
        left += partWidth
      }
      NSGraphicsContext.restoreGraphicsState()
    }
    y += 10
    let font = NSFont.systemFont(ofSize: 11.5)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    for part in parts {
      y += 8
      canvas.fill(x, y + 3, 8, 8, radius: 2, color: colors[part.label] ?? self.accent)
      let value = UsageShareFormat.tokens(part.tokens) + " · " + UsageShareFormat.share(Double(part.tokens) / max(1, total))
      let valueWidth = ShareCanvas.textWidth(value, font: valueFont) + 2
      canvas.text(part.label, x: x + 14, y: y, width: width - 14 - valueWidth, font: font,
        color: self.secondary, singleLine: true)
      canvas.text(value, x: x + width - valueWidth, y: y, width: valueWidth, font: valueFont,
        color: self.primary, alignment: .right, singleLine: true)
      y += ShareCanvas.lineHeight(font)
    }
    if usage.tokenMixIsPartial {
      y += 8
      y += canvas.text("Some days record no token types; those tokens are not split here.",
        x: x, y: y, width: width, font: .systemFont(ofSize: 10.5), color: self.quiet)
    }
    return y - start
  }

  private static func models(
    _ usage: UsageShareModel.Usage, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    self.tiles([{ canvas, x, y, width in
      let start = y
      var y = y
      y += self.tileHeading("Top models", unit: usage.metric == .cost ? "API estimate" : "Tokens",
        canvas: canvas, x: x, y: y, width: width)
      let peak = usage.models.compactMap(\.share).max() ?? 1
      let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
      let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
      for (index, line) in usage.models.enumerated() {
        y += 10
        canvas.text("\(index + 1)", x: x, y: y, width: 16, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
          color: self.quiet, singleLine: true)
        var value = UsageShareFormat.lineValue(line, metric: usage.metric)
        if let share = line.share { value += " · " + UsageShareFormat.share(share) }
        let valueWidth = ShareCanvas.textWidth(value, font: valueFont) + 2
        canvas.text(line.name, x: x + 20, y: y, width: width - 20 - valueWidth - 8, font: font,
          color: self.primary, singleLine: true)
        canvas.text(value, x: x + width - valueWidth, y: y, width: valueWidth, font: valueFont,
          color: self.primary, alignment: .right, singleLine: true)
        y += ShareCanvas.lineHeight(font) + 4
        let fraction = (line.share ?? 0) / max(peak, 0.0001)
        canvas.fill(x + 20, y, width - 20, 4, radius: 2, color: self.track)
        canvas.fill(x + 20, y, max(4, (width - 20) * CGFloat(min(1, fraction))), 4, radius: 2,
          color: line.kind.map(self.providerColor) ?? self.accent)
        y += 4
      }
      var notes: [String] = []
      if usage.otherModelTokens > 0 {
        notes.append("\(UsageShareFormat.tokens(usage.otherModelTokens)) tokens in other models")
      }
      if usage.unattributedTokens > 0 {
        notes.append("\(UsageShareFormat.tokens(usage.unattributedTokens)) tokens with no model recorded")
      }
      if !notes.isEmpty {
        y += 10
        y += canvas.text("Plus " + notes.joined(separator: " · "), x: x, y: y, width: width,
          font: .systemFont(ofSize: 11), color: self.quiet)
      }
      return y - start
    }], canvas: canvas, x: x, y: y, width: width)
  }

  private static func footer(
    _ model: UsageShareModel, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    var parts: [String] = []
    if let checked = model.limitsCheckedAt { parts.append("Limits as of " + UsageShareFormat.moment(checked)) }
    if let checked = model.usage?.checkedAt { parts.append("Usage as of " + UsageShareFormat.moment(checked)) }
    let font = NSFont.systemFont(ofSize: 10.5)
    var height = canvas.text(
      UsageShareFormat.disclaimer(includesCost: model.includesCost && model.usage?.metric == .cost),
      x: x, y: y, width: width, font: font, color: self.quiet)
    if !parts.isEmpty {
      height += 2
      height += canvas.text(parts.joined(separator: " · "), x: x, y: y + height, width: width,
        font: font, color: self.quiet)
    }
    return height
  }

  // MARK: Building blocks

  typealias TileContent = (ShareCanvas, CGFloat, CGFloat, CGFloat) -> CGFloat

  /// A full-width tile.
  private static func tiles(
    _ blocks: [TileContent], canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    self.row(blocks, widths: [width], canvas: canvas, x: x, y: y)
  }

  /// Tiles side by side, all as tall as the tallest.
  private static func row(
    _ blocks: [TileContent], widths: [CGFloat], canvas: ShareCanvas, x: CGFloat, y: CGFloat,
    padding: CGFloat = ShareCardPainter.tilePadding
  ) -> CGFloat {
    let measure = ShareCanvas(drawing: false, height: 0)
    let heights = zip(blocks, widths).map { block, width in
      block(measure, 0, 0, width - 2 * padding) + 2 * padding
    }
    let height = ceil(heights.max() ?? 0)
    var left = x
    for (block, width) in zip(blocks, widths) {
      canvas.fill(left, y, width, height, radius: 14, color: self.well)
      _ = block(canvas, left + padding, y + padding, width - 2 * padding)
      left += width + self.tileGap
    }
    return height
  }

  private static func tileHeading(
    _ title: String, unit: String?, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat
  ) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    canvas.text(title, x: x, y: y, width: width * 0.6, font: font, color: self.primary, singleLine: true)
    if let unit {
      canvas.text(unit, x: x + width * 0.5, y: y + 1, width: width * 0.5, font: .systemFont(ofSize: 11),
        color: self.quiet, alignment: .right, singleLine: true)
    }
    return ShareCanvas.lineHeight(font)
  }

  private static func meter(
    _ remaining: Double, canvas: ShareCanvas, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
    color: NSColor
  ) {
    canvas.fill(x, y, width, height, radius: height / 2, color: self.track)
    let fraction = CGFloat(min(100, max(0, remaining)) / 100)
    guard fraction > 0 else { return }
    canvas.fill(x, y, max(height, width * fraction), height, radius: height / 2, color: color)
  }

  /// Provider marks sit on a light chip so dark marks stay legible on a dark card.
  private static func logo(_ kind: ProviderKind, canvas: ShareCanvas, x: CGFloat, y: CGFloat, size: CGFloat) {
    canvas.fill(x, y, size, size, radius: size * 0.28, color: NSColor(white: 1, alpha: self.isDark ? 0.92 : 1))
    guard canvas.drawing else { return }
    let image = ProviderArtwork.image(for: ProviderID(kind: kind))
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      canvas.image(image, x: x + size * 0.15, y: y + size * 0.15, size: size * 0.7)
    }
  }

  private static func drawChrome(_ canvas: ShareCanvas, width: CGFloat) {
    let bounds = canvas.rect(0, 0, width, canvas.height).insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24)
    self.background.setFill()
    path.fill()
    self.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  // MARK: Colors

  private static func providerColor(_ kind: ProviderKind) -> NSColor {
    InsightTrendView.color(ProviderID(kind: kind))
  }

  private static var isDark: Bool {
    NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  private static var background: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.105, green: 0.102, blue: 0.098, alpha: 1)
      : NSColor(srgbRed: 0.975, green: 0.962, blue: 0.941, alpha: 1)
  }

  private static var primary: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
      : NSColor(srgbRed: 0.12, green: 0.105, blue: 0.09, alpha: 1)
  }

  private static var secondary: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.72, green: 0.70, blue: 0.66, alpha: 1)
      : NSColor(srgbRed: 0.37, green: 0.34, blue: 0.30, alpha: 1)
  }

  private static var quiet: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.56, green: 0.54, blue: 0.50, alpha: 1)
      : NSColor(srgbRed: 0.49, green: 0.45, blue: 0.40, alpha: 1)
  }

  private static var accent: NSColor {
    self.isDark
      ? NSColor(srgbRed: 1.0, green: 0.46, blue: 0.22, alpha: 1)
      : NSColor(srgbRed: 0.94, green: 0.35, blue: 0.10, alpha: 1)
  }

  private static var accentText: NSColor {
    self.isDark
      ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.42, alpha: 1)
      : NSColor(srgbRed: 0.72, green: 0.25, blue: 0.05, alpha: 1)
  }

  private static var success: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.40, green: 0.82, blue: 0.50, alpha: 1)
      : NSColor(srgbRed: 0.13, green: 0.55, blue: 0.27, alpha: 1)
  }

  private static var warning: NSColor {
    self.isDark
      ? NSColor(srgbRed: 1.0, green: 0.70, blue: 0.25, alpha: 1)
      : NSColor(srgbRed: 0.80, green: 0.45, blue: 0.0, alpha: 1)
  }

  private static var track: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.10)
      : NSColor.black.withAlphaComponent(0.08)
  }

  private static var well: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.055)
      : NSColor.white.withAlphaComponent(0.75)
  }

  private static var border: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.12)
      : NSColor.black.withAlphaComponent(0.10)
  }
}
