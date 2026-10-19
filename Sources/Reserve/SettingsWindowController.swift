import AppKit
import ServiceManagement
import ReserveCore

/// Reserve's settings, built the way macOS builds settings: a toolbar of panes
/// above a resizable window. No page titles and no introductory copy; the
/// toolbar already says where you are. Sections sit on the chosen theme's
/// cards and window color, like the dashboard.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSToolbarDelegate,
  NSWindowDelegate, NSMenuDelegate
{
  enum Pane: String, CaseIterable {
    case general
    case providers
    case api
    case notifications
    case appearance
    case insights
    case privacy
    case about

    var title: String {
      switch self {
      case .general: "General"
      case .providers: "Providers"
      case .api: "API"
      case .notifications: "Notifications"
      case .appearance: "Appearance"
      case .insights: "Insights"
      case .privacy: "Privacy"
      case .about: "About"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .providers: "person.2"
      case .api: "curlybraces"
      case .notifications: "bell"
      case .appearance: "paintpalette"
      case .insights: "chart.bar"
      case .privacy: "hand.raised"
      case .about: "info.circle"
      }
    }

    var itemIdentifier: NSToolbarItem.Identifier {
      NSToolbarItem.Identifier("settings-pane-\(self.rawValue)")
    }
  }

  private let store: UsageStore
  private var insightFilters = InsightDashboardView.Filters()
  private var layoutSize: NSSize {
    self.pane == .insights ? NSSize(width: 1040, height: 720) : SettingsLayout.defaultSize
  }
  private var contentWidth: CGFloat { self.layoutSize.width - 2 * SettingsLayout.inset - (self.pane == .insights ? 16 : 0) }
  private let updater: ReserveUpdater?
  private let setupProvider: (ProviderID) -> Void
  private(set) var pane = Pane.general
  private weak var updateStatusLabel: NSTextField?
  private weak var updateButton: NSButton?
  private var renewalStatusLabels: [ProviderID: NSTextField] = [:]
  private var expandedProviders: Set<ProviderID> = []
  /// Held so the registration is explicit; the observer closure itself keeps
  /// only a weak reference to this controller, which lives for the app's run.
  private var storeObserver: UsageStore.ObserverToken?
  /// Guards against a pane rebuild re-entering through a store write made by one
  /// of the controls it is building.
  private var isApplyingPane = false
  private var restoreAfterUpdatePresentation = false
  /// Last document offset per pane, so a store refresh does not jump the reader.
  private var savedScrollOffsets: [Pane: NSPoint] = [:]
  private let uiRefresh = UISurfaceRefresh()
  private var installedStructure = ""
  private var needsLiveRefresh = false
  private var pendingStructural = false
  /// One in-flight key save. A second click does nothing until it finishes.
  private var keySaveInFlight = false
  private var keyOperationStatus: (identifier: String, text: String)?

  init(
    store: UsageStore,
    updater: ReserveUpdater?,
    setupProvider: @escaping (ProviderID) -> Void
  ) {
    self.store = store
    self.updater = updater
    self.setupProvider = setupProvider
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsLayout.defaultSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true)
    window.title = Pane.general.title
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .preference
    // An ordinary window: it comes to the front when opened from the menu bar
    // and goes behind whatever app is clicked next, like any other app's.
    window.level = .normal
    window.hidesOnDeactivate = false
    // Opening Settings from another Space brings the window to that Space
    // instead of switching back to the one it was left on.
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.center()
    super.init(window: window)
    window.delegate = self

    let toolbar = NSToolbar(identifier: "settings-toolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = false
    toolbar.displayMode = .iconAndLabel
    toolbar.selectedItemIdentifier = self.pane.itemIdentifier
    window.toolbar = toolbar
    self.applyPane(animated: false)
    // Settings shows live provider state — connection, plan, freshness — so it
    // has to observe the same store the dashboard does. Without this it keeps
    // whatever was true when the pane was last built.
    self.installedStructure = self.controlStructureSignature()
    self.storeObserver = store.observe { [weak self] in self?.storeChanged() }
    self.updater?.onChange = { [weak self] in self?.storeChanged() }
    self.updater?.onWillPresentUpdateUI = { [weak self] in
      self?.prepareForUpdatePresentation()
    }
    self.updater?.onDidFinishUpdateUI = { [weak self] in
      self?.restoreAfterUpdatePresentationIfNeeded()
    }
  }

  /// Schedules one refresh for a burst of store events. Hidden windows wait
  /// until they are shown. Typing keeps the field, and other readings still move.
  private func storeChanged() {
    guard !self.isApplyingPane else { return }
    self.uiRefresh.coalesce { [weak self] in self?.applyLiveUpdate() }
  }

  private var editingField: NSTextField? {
    guard let editor = self.window?.firstResponder as? NSText else { return nil }
    return editor.delegate as? NSTextField
  }

  private func applyLiveUpdate() {
    guard let window = self.window, window.isVisible, window.contentView != nil else {
      self.needsLiveRefresh = true
      return
    }
    self.needsLiveRefresh = false
    let structure = self.controlStructureSignature()
    if structure != self.installedStructure {
      if self.editingField != nil {
        self.applyLiveLabels()
        self.pendingStructural = true
        return
      }
      self.rememberScrollOffset()
      self.applyPane(animated: false)
      self.pendingStructural = false
      return
    }
    self.applyLiveLabels()
  }

  required init?(coder: NSCoder) { nil }

  /// Settings opens on the screen the person is working on: the one with the
  /// pointer, which is where the menu-bar window they just used is. A window
  /// left on another display moves over, centred, keeping its size.
  private func moveToPresentingScreen() {
    guard let window = self.window else { return }
    let mouse = NSEvent.mouseLocation
    guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      ?? NSScreen.main,
      window.screen != target
    else { return }
    let visible = target.visibleFrame
    var frame = window.frame
    frame.size.width = min(frame.width, visible.width)
    frame.size.height = min(frame.height, visible.height)
    frame.origin.x = visible.midX - frame.width / 2
    frame.origin.y = visible.midY - frame.height / 2
    window.setFrame(frame, display: false)
  }

  override func showWindow(_ sender: Any?) {
    // The current pane is already live. Rebuilding it on every reopen retained
    // a complete control tree until the next AppKit autorelease drain.
    if self.window?.contentView == nil { self.applyPane(animated: false) }
    self.store.insightsVisible = self.pane == .insights
    self.moveToPresentingScreen()
    super.showWindow(sender)
    self.window?.makeKeyAndOrderFront(nil)
    self.window?.orderFrontRegardless()
    if self.needsLiveRefresh || self.pendingStructural {
      self.uiRefresh.flush()
      if self.needsLiveRefresh || self.pendingStructural {
        self.applyLiveUpdate()
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === self.window else { return }
    // A closed Settings window can hold every Insights chart and provider row
    // for the rest of the app session. Release that hidden control tree; the
    // next show rebuilds the current pane through the existing lazy path.
    self.store.insightsVisible = false
    self.renewalStatusLabels.removeAll()
    self.window?.contentView = nil
  }

  func show(_ pane: Pane) {
    let paneChanged = self.pane != pane
    self.pane = pane
    self.store.insightsVisible = pane == .insights && self.window?.isVisible == true
    self.window?.toolbar?.selectedItemIdentifier = pane.itemIdentifier
    if paneChanged || self.window?.contentView == nil {
      self.applyPane(animated: self.window?.isVisible == true)
    }
    self.showWindow(nil)
    if pane == .insights { self.store.requestInsights() }
  }

  /// The analytical surface, reached from the popover footer.
  func showInsights() { self.show(.insights) }

  /// Settings normally floats so it remains usable from an accessory app, but
  /// Sparkle's standard alert does not. Hide Settings for the update session so
  /// the alert cannot be trapped behind it, then return to the same pane.
  private func prepareForUpdatePresentation() {
    guard let window = self.window, window.isVisible else { return }
    self.restoreAfterUpdatePresentation = true
    window.orderOut(nil)
  }

  private func restoreAfterUpdatePresentationIfNeeded() {
    guard self.restoreAfterUpdatePresentation else { return }
    self.restoreAfterUpdatePresentation = false
    self.showWindow(nil)
  }

  func exerciseUpdatePresentationForSelfTest() -> Bool {
    guard let window = self.window, window.isVisible else { return false }
    let originalPane = self.pane
    self.prepareForUpdatePresentation()
    let movedAside = !window.isVisible && self.restoreAfterUpdatePresentation
    self.restoreAfterUpdatePresentationIfNeeded()
    return movedAside && window.isVisible && self.pane == originalPane
  }

  // MARK: - Toolbar

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let pane = Pane.allCases.first(where: { $0.itemIdentifier == itemIdentifier }) else {
      return nil
    }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = pane.title
    item.paletteLabel = pane.title
    item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
    item.target = self
    item.action = #selector(self.toolbarItemSelected(_:))
    return item
  }

  @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
    guard let pane = Pane.allCases.first(where: { $0.itemIdentifier == sender.itemIdentifier })
    else { return }
    self.pane = pane
    self.store.insightsVisible = pane == .insights && self.window?.isVisible == true
    if pane == .insights { self.store.requestInsights() }
    self.applyPane(animated: true)
  }

  /// Swaps the pane and resizes to it, keeping the window's top-left corner
  /// anchored the way macOS settings windows do.
  private func applyPane(animated: Bool) {
    guard let window = self.window else { return }
    guard !self.isApplyingPane else { return }
    self.isApplyingPane = true
    defer {
      self.isApplyingPane = false
      self.installedStructure = self.controlStructureSignature()
    }
    let drafts = Self.descendants(of: window.contentView ?? NSView())
      .compactMap { $0 as? NSTextField }.reduce(into: [String: String]()) { values, field in
        guard let id = field.identifier?.rawValue,
          id.hasPrefix("api-key-") || id.hasPrefix("plan-key-") else { return }
        values[id] = field.stringValue
      }
    window.title = self.pane.title
    // The chosen theme reaches Settings the way it reaches the dashboard.
    window.backgroundColor = ReserveColor.background
    let content = self.makeContentView()
    for field in Self.descendants(of: content).compactMap({ $0 as? NSTextField }) {
      if let id = field.identifier?.rawValue, let draft = drafts[id] {
        field.stringValue = draft
      }
    }
    content.layoutSubtreeIfNeeded()
    let screenLimit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
    let limit = max(SettingsLayout.minimumHeight, screenLimit - 80)
    let natural = max(SettingsLayout.minimumHeight, content.frame.height)
    let view: NSView
    if natural > limit {
      let scroll = NSScrollView()
      scroll.identifier = NSUserInterfaceItemIdentifier("settings-scroll")
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = false
      scroll.scrollerStyle = .legacy
      scroll.drawsBackground = false
      scroll.documentView = content
      let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
      content.frame.size.width = self.layoutSize.width - scrollerWidth
      scroll.frame = NSRect(
        x: 0, y: 0, width: self.layoutSize.width, height: limit)
      // Non-flipped documents open at the bottom unless the clip is pinned
      // to the top of the document.
      let saved = self.savedScrollOffsets[self.pane]
      let top = NSPoint(x: 0, y: max(0, content.frame.height - limit))
      scroll.contentView.scroll(to: saved ?? top)
      view = scroll
      scroll.reflectScrolledClipView(scroll.contentView)
      // The clip view ignores scroll(to:) until it is in a window.
      scroll.contentView.postsBoundsChangedNotifications = false
    } else {
      view = content
    }
    let size = NSSize(
      width: self.layoutSize.width,
      height: min(natural, limit))
    window.contentView = view
    let frame = window.frame
    let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    let newFrame = NSRect(
      x: frame.minX,
      y: frame.maxY - target.height,
      width: target.width,
      height: target.height)
    window.setFrame(newFrame, display: true, animate: animated && !ReserveMotion.isReduced)
    window.contentMinSize = NSSize(width: size.width, height: SettingsLayout.minimumHeight)
    if let scroll = window.contentView as? NSScrollView, let document = scroll.documentView {
      let saved = self.savedScrollOffsets[self.pane]
      let top = NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height))
      scroll.contentView.scroll(to: saved ?? top)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    if let operation = self.keyOperationStatus {
      self.setStatus(operation.identifier, operation.text)
    }
  }

  private func makeContentView() -> NSView {
    switch self.pane {
    case .general: self.generalPane()
    case .providers: self.providersPane()
    case .api: self.apiPane()
    case .notifications: self.notificationsPane()
    case .appearance: self.appearancePane()
    case .insights: self.insightsPane()
    case .privacy: self.privacyPane()
    case .about: self.aboutPane()
    }
  }

  // MARK: - Panes

  private func generalPane() -> NSView {
    self.pane(
      identifier: "pane-general",
      sections: [
        self.section(
          title: "Behavior",
          rows: [
            self.formRow("Refresh limits:", self.refreshIntervalControl()),
            self.formRow("Startup:", self.launchAtLoginCheckbox()),
            self.formRow("History:", self.localHistoryCheckbox()),
            self.formRow("Open dashboard:", self.hotKeyControl()),
            self.formRow("Privacy:", self.hidePersonalCheckbox()),
          ]),
        self.section(
          title: "Menu bar",
          rows: [
            self.formRow("Display:", self.menuBarModeControl()),
            self.formRow("Details:", self.menuBarDetailControls()),
            self.formRow("Preview:", MenuBarPreview(store: self.store)),
          ]),
      ])
  }

  private func providersPane() -> NSView {
    var rows: [NSView] = [self.addAccountRow()]
    for provider in self.store.accounts {
      rows.append(self.providerRow(provider))
      if self.expandedProviders.contains(provider) {
        rows.append(self.providerDetail(provider))
      }
      if provider != self.store.accounts.last {
        rows.append(SettingsSeparator(width: SettingsLayout.contentWidth))
      }
    }
    return self.pane(
      identifier: "pane-providers",
      sections: [
        self.section(
          title: nil,
          footer: "Reserve reuses your existing provider sign-ins. It never asks for passwords "
            + "or saves sign-ins. Claude and Cursor need your permission before Reserve can read their usage. macOS may also ask you to approve access.",
          rows: rows)
      ])
  }

  private func apiPane() -> NSView {
    var rows: [NSView] = [self.addAccountRow()]
    for provider in self.store.apiAccounts {
      rows.append(self.apiProviderRow(provider))
      if provider != self.store.apiAccounts.last {
        rows.append(SettingsSeparator(width: SettingsLayout.contentWidth))
      }
    }
    return self.pane(
      identifier: "pane-api",
      sections: [
        self.section(
          title: nil,
          footer: "Paste a key to measure API spend or balance. It is saved in the macOS Keychain "
            + "on this Mac and sent only to that provider. Remove deletes it. Some keys can "
            + "also call models; for those, use one made just for Reserve.",
          rows: rows)
      ])
  }

  private func notificationsPane() -> NSView {
    let smart = [
      ("Notify when a plan may run out early", "deficit"),
      ("Limit exhausted", "exhausted"),
      ("Capacity available again", "weeklyRenewal"),
      ("Data stale or provider disconnected", "stale"),
      ("Provider service incident", "incident"),
    ].map { self.notificationCheckbox(title: $0.0, key: $0.1) }

    let advanced = [
      self.notificationCheckbox(title: "Notify at 50% left", key: "threshold50"),
      self.notificationCheckbox(title: "Notify at 10% left", key: "threshold90"),
      self.notificationCheckbox(title: "Notify before a plan renewal", key: "planRenewal"),
      self.notificationCheckbox(
        title: "Notify when a 5-hour window resets", key: "fiveHourRenewal"),
      self.notificationCheckbox(title: "Play a sound", key: "sound"),
    ]

    return self.pane(
      identifier: "pane-notifications",
      sections: [
        self.section(title: nil, rows: [self.notificationsEnabledCheckbox()]),
        self.section(
          title: "Smart alerts",
          footer: "Reserve reports factual state changes rather than treating normal usage "
            + "conditions as emergencies. These are on by default.",
          rows: smart),
        self.section(
          title: "Advanced",
          footer: "Fixed thresholds fire regardless of pace. They stay off unless you turn "
            + "them on.",
          rows: advanced),
      ])
  }

  private func appearancePane() -> NSView {
    self.pane(
      identifier: "pane-appearance",
      sections: [
        self.section(
          title: "Appearance",
          rows: [self.formRow("Theme:", self.appearanceModeControl())]),
        self.section(
          title: "Accent",
          footer: "Accent themes shape Reserve's surfaces and controls. Green means healthy, "
            + "orange means attention, and gray means data is unavailable.",
          rows: [self.accentRow()]),
        self.section(
          title: "Preview",
          rows: [ThemePreview(theme: self.store.appearanceTheme)]),
      ])
  }

  private func insightsPane() -> NSView {
    let dashboard = InsightDashboardView(store: self.store, width: self.contentWidth,
      filters: self.insightFilters) { [weak self] filters in
        guard let self else { return }
        self.insightFilters = filters
        self.rememberScrollOffset()
        self.applyPane(animated: false)
      }
    dashboard.searchChanged = { [weak self] filters in
      self?.insightFilters = filters
      self?.reflowLiveContent()
    }
    return self.pane(identifier: "pane-insights", sections: [dashboard])
  }

  /// Identity, updates and links, in the order someone looks for them. This is
  /// the About surface: the standard AppKit panel opens at the normal window
  /// level, which is below Reserve's floating windows, so it was invisible
  /// whenever it was opened from here.
  private func aboutPane() -> NSView {
    self.pane(
      identifier: "pane-about",
      sections: [
        self.section(title: nil, rows: [AboutHeaderView()]),
        self.section(
          title: "Updates",
          footer: "Checks once a day. When a signed update is ready, Reserve offers to install it and asks before restarting.",
          rows: [
            self.automaticUpdateCheckbox(),
            self.updateControls(),
          ]),
        self.section(
          title: "Links",
          rows: [
            self.linkRow("GitHub", symbol: "chevron.left.forwardslash.chevron.right",
              url: ReserveLinks.repository),
            self.linkRow("@pocarles on X", symbol: "at", url: ReserveLinks.xProfile),
          ]),
        self.section(
          title: nil,
          rows: [
            SettingsLabel(
              "© 2026 Pierre-Olivier Carles. MIT License.",
              size: 11, color: .secondaryLabelColor),
            SettingsLabel(
              "Not affiliated with or endorsed by OpenAI, Anthropic, xAI, or Anysphere.",
              size: 11, color: .tertiaryLabelColor),
            SettingsLabel(
              "Made in Florida with love.", size: 11, color: .tertiaryLabelColor),
          ]),
      ])
  }

  private func automaticUpdateCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Check daily and notify me about updates", target: self,
      action: #selector(self.automaticUpdatesChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("updates-automatic")
    let enabled = self.updater?.automaticallyChecksForUpdates ?? self.store.automaticUpdateChecks
    checkbox.state = enabled ? .on : .off
    return checkbox
  }

  /// A row that opens a URL, with the standard outward arrow so it reads as
  /// leaving the app.
  private func linkRow(_ title: String, symbol: String, url: URL) -> NSView {
    let button = NSButton(title: "", target: self, action: #selector(self.openLink(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("link-\(url.absoluteString)")
    button.isBordered = false
    button.title = ""
    button.setAccessibilityLabel("\(title), opens in your browser")
    button.toolTip = url.absoluteString

    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    icon.setAccessibilityElement(false)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
    let label = SettingsLabel(title, size: 13, color: .labelColor)
    let arrow = NSImageView(
      image: NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil) ?? NSImage())
    arrow.contentTintColor = .tertiaryLabelColor
    arrow.setAccessibilityElement(false)
    arrow.translatesAutoresizingMaskIntoConstraints = false
    arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, label, spacer, arrow])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }

  @objc private func openLink(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(of: "link-", with: "")
    guard let url = URL(string: raw), url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func automaticUpdatesChanged(_ sender: NSButton) {
    let enabled = sender.state == .on
    if let updater {
      updater.setAutomaticChecks(enabled)
    } else {
      self.store.automaticUpdateChecks = enabled
    }
  }

  private func privacyPane() -> NSView {
    self.pane(
      identifier: "pane-privacy",
      sections: [
        self.section(
          title: nil,
          rows: [
            SettingsLabel(
              "Reserve processes usage information on this Mac.",
              size: 13, weight: .medium, color: .labelColor)
          ]),
        self.section(
          title: "Reserve reads",
          footer: "Reserve reuses the sign-ins of the provider tools you already have. It never "
            + "asks for a password and never stores a token.",
          rows: [
            self.bullets([
              "Claude's protected macOS sign-in, only after you choose Allow access",
              "Cursor's cursor-user / cursor-access-token Keychain item, only after you choose Allow access",
              "~/.claude/.credentials.json and ~/.grok/auth.json",
              "Session logs under ~/.claude/projects, ~/.codex/sessions and ~/.grok/sessions, "
                + "for token counts only, when local history is enabled",
              "Cursor account usage totals from Cursor's authenticated DashboardService; Reserve does not read Cursor prompts or transcripts",
              "Optional quota updates shared by Claude Code; Reserve stores only limits and their observation time",
              "Copilot allowance and OpenAI account activity through their installed helpers, without sending prompts",
              "Gemini plan limits by running the Antigravity CLI's own usage command (agy -p /usage), "
                + "which starts no conversation and spends no quota; Reserve never reads agy's Google sign-in",
            ])
          ]),
        self.section(
          title: "Reserve stores",
          rows: [
            self.bullets([
              "Aggregate token totals",
              "Per-day token and estimated cost totals for up to 90 days, from scans Reserve already runs",
              "Normalized quota values and reset times",
              "Your preferences",
            ])
          ]),
        self.section(
          title: "Reserve does not store",
          rows: [
            self.bullets([
              "Prompts or responses",
              "Personal identifiers in the daily history cache",
              "Raw provider payloads",
              "OAuth tokens, account identifiers or passwords",
              "API keys, including Z.ai and Kimi plan keys — those stay in the macOS Keychain",
            ])
          ]),
        self.section(
          title: "Reserve contacts",
          footer: "Nothing else. There is no analytics, no telemetry, and no Reserve server.",
          rows: [
            self.bullets([
              "Your providers, to read your limits",
              "OpenAI, Anthropic, OpenRouter, xAI, TypeSafe, DeepSeek and Moonshot APIs, only after you save a key",
              "Z.ai (api.z.ai) and Kimi Code (api.kimi.com) usage endpoints, only after you save a plan key",
              "Their official status pages",
              "GitHub, only to look for a Reserve update",
            ])
          ]),
        self.section(
          title: "Data",
          footer: "Caches live in Application Support and are removed when you delete Reserve.",
          rows: [self.formRow("Location:", self.dataFolderControls())]),
      ])
  }

  // MARK: - Rows

  private func localHistoryCheckbox() -> NSButton {
    let button = NSButton(checkboxWithTitle: "Include activity from this Mac", target: self,
      action: #selector(self.localHistoryChanged(_:)))
    button.state = self.store.localHistoryEnabled ? .on : .off
    button.identifier = NSUserInterfaceItemIdentifier("history-local-enabled")
    button.toolTip = "Optional token history from enabled providers. Allowance checks do not need it."
    return button
  }

  @objc private func localHistoryChanged(_ sender: NSButton) {
    self.store.localHistoryEnabled = sender.state == .on
  }

  private func refreshIntervalControl() -> NSView {
    let popup = NSPopUpButton()
    popup.identifier = NSUserInterfaceItemIdentifier("settings-refresh-interval")
    popup.addItems(withTitles: Self.refreshIntervalTitles)
    let minutes = self.store.refreshIntervalMinutes
    let index = Self.refreshIntervalMinutes.firstIndex(of: minutes) ?? 0
    popup.selectItem(at: index)
    popup.target = self
    popup.action = #selector(self.intervalChanged(_:))
    popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    return popup
  }

  static let refreshIntervalMinutes = [0, 1, 5, 10, 15, 30]
  static let refreshIntervalTitles = [
    "Adaptive (2 to 30 min)",
    "Every 1 minute", "Every 5 minutes", "Every 10 minutes",
    "Every 15 minutes", "Every 30 minutes",
  ]

  private func hotKeyControl() -> NSView {
    let popup = NSPopUpButton()
    popup.identifier = NSUserInterfaceItemIdentifier("settings-dashboard-hotkey")
    popup.addItems(withTitles: DashboardHotKeyChoice.allCases.map(\.title))
    let index = DashboardHotKeyChoice.allCases.firstIndex(of: self.store.dashboardHotKey) ?? 0
    popup.selectItem(at: index)
    popup.target = self
    popup.action = #selector(self.hotKeyChanged(_:))
    popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    let status = SettingsLabel(self.hotKeyStatusText(), size: 11, color: .secondaryLabelColor)
    status.identifier = NSUserInterfaceItemIdentifier("settings-hotkey-status")
    let stack = NSStackView(views: [popup, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    return stack
  }

  private func hotKeyStatusText() -> String {
    switch self.store.dashboardHotKeyStatus {
    case .inactive:
      return "Off"
    case .registered:
      return "Registered. Opens the dashboard and does not close it."
    case .conflict:
      return "Already used by another app"
    case .failed:
      return "Could not register"
    }
  }

  private func hidePersonalCheckbox() -> NSButton {
    let button = NSButton(
      checkboxWithTitle: "Hide personal info", target: self,
      action: #selector(self.hidePersonalChanged(_:)))
    button.state = self.store.hidesPersonalInfo ? .on : .off
    button.identifier = NSUserInterfaceItemIdentifier("settings-hide-personal")
    button.toolTip = "Masks account and organization on screen. Originals stay in memory."
    return button
  }

  private func launchAtLoginCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Launch at login", target: self, action: #selector(self.loginChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("settings-launch-at-login")
    checkbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    return checkbox
  }

  private func menuBarModeControl() -> NSView {
    let popup = NSPopUpButton()
    popup.identifier = NSUserInterfaceItemIdentifier("menu-bar-provider")
    popup.addItems(
      withTitles: ["Automatic"] + self.store.accounts.map { "Pinned: \($0.displayName)" })
    let selection =
      self.store.menuBarProvider.flatMap { self.store.accounts.firstIndex(of: $0) }
      .map { $0 + 1 } ?? 0
    popup.selectItem(at: selection)
    popup.target = self
    popup.action = #selector(self.menuBarProviderChanged(_:))
    popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
    return popup
  }

  private func menuBarDetailControls() -> NSView {
    let remaining = NSButton(
      checkboxWithTitle: "Percentage left", target: self,
      action: #selector(self.menuBarDetailChanged(_:)))
    remaining.identifier = NSUserInterfaceItemIdentifier("menu-bar-remaining")
    remaining.state = self.store.menuBarShowsRemaining ? .on : .off
    let reset = NSButton(
      checkboxWithTitle: "Reset countdown", target: self,
      action: #selector(self.menuBarDetailChanged(_:)))
    reset.identifier = NSUserInterfaceItemIdentifier("menu-bar-reset")
    reset.state = self.store.menuBarShowsReset ? .on : .off
    let stack = NSStackView(views: [remaining, reset])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    return stack
  }

  private func updateControls() -> NSView {
    let statusText: String
    if let checked = self.updater?.lastUpdateCheckDate {
      let ago = DashboardFormat.updated(checked, now: Date())
        .replacingOccurrences(of: "Updated ", with: "")
      statusText = "Checked \(ago)"
    } else {
      statusText = "Not checked yet"
    }
    let status = SettingsLabel(statusText, size: 12, color: .secondaryLabelColor)
    status.identifier = NSUserInterfaceItemIdentifier("about-update-status")
    self.updateStatusLabel = status
    let button = NSButton(
      title: "Check for Updates…",
      target: self, action: #selector(self.checkForUpdates(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("about-check-updates")
    button.bezelStyle = .rounded
    button.isEnabled = self.updater?.canCheckForUpdates ?? false
    self.updateButton = button
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [status, spacer, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  private func dataFolderControls() -> NSView {
    let button = NSButton(
      title: "Show Data Folder", target: self, action: #selector(self.showDataFolder(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("privacy-data-folder")
    button.bezelStyle = .rounded
    return button
  }

  private func bullets(_ items: [String]) -> NSView {
    let labels = items.map { item -> NSView in
      let dot = SettingsLabel("•", size: 12, color: .tertiaryLabelColor)
      let text = SettingsLabel(item, size: 12, color: .secondaryLabelColor)
      let row = NSStackView(views: [dot, text])
      row.orientation = .horizontal
      row.alignment = .firstBaseline
      row.spacing = 7
      return row
    }
    let stack = NSStackView(views: labels)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    return stack
  }

  private func providerRow(_ provider: ProviderID) -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "", target: self, action: #selector(self.providerChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
    checkbox.state = self.store.isEnabled(provider) ? .on : .off
    checkbox.setAccessibilityLabel("Track \(provider.displayName)")

    let logo = SettingsProviderLogo(provider: provider)
    // The logo carries the brand; the name stays in the system label colour.
    // An added account shows its own name: the logo already says which kind.
    let nameLabel = SettingsLabel(
      self.store.accountShownLabel(for: provider) ?? provider.displayName,
      size: 13, weight: .medium, color: .labelColor)
    nameLabel.setAccessibilityLabel(ReserveBetaBadge.accessibilityName(for: provider))
    let name: NSView
    if ProviderDescriptor.forProvider(provider).isBeta {
      // The tag sits right after the name, inside the same fixed column, so
      // the plan and status columns stay aligned with every other row.
      nameLabel.setContentHuggingPriority(.required, for: .horizontal)
      let badge = ReserveBetaBadge()
      badge.identifier = NSUserInterfaceItemIdentifier("provider-beta-\(provider.rawValue)")
      let column = NSStackView.row([nameLabel, badge], spacing: 5, alignment: .centerY)
      column.setHuggingPriority(.defaultLow, for: .horizontal)
      name = column
    } else {
      name = nameLabel
    }
    name.widthAnchor.constraint(equalToConstant: 92).isActive = true
    let plan = SettingsLabel(
      Self.displayPlanName(self.store.states[provider]?.snapshot?.planName),
      size: 12, color: .secondaryLabelColor)
    plan.identifier = NSUserInterfaceItemIdentifier("settings-plan-\(provider.rawValue)")
    plan.widthAnchor.constraint(equalToConstant: 118).isActive = true
    let state = self.providerStatus(provider)
    let status = SettingsLabel(state.text, size: 12, color: state.color)
    status.identifier = NSUserInterfaceItemIdentifier("settings-status-\(provider.rawValue)")
    status.widthAnchor.constraint(equalToConstant: 128).isActive = true
    let updated = SettingsLabel(
      (self.store.states[provider]?.snapshot?.fetchedAt).map {
        DashboardFormat.updated($0, now: Date()).replacingOccurrences(of: "Updated ", with: "")
      } ?? "never",
      size: 12, color: .tertiaryLabelColor)
    updated.identifier = NSUserInterfaceItemIdentifier("settings-updated-\(provider.rawValue)")
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let disclose = NSButton(
      title: "", target: self, action: #selector(self.toggleProviderDetail(_:)))
    disclose.identifier = NSUserInterfaceItemIdentifier("provider-disclose-\(provider.rawValue)")
    disclose.bezelStyle = .disclosure
    disclose.setButtonType(.pushOnPushOff)
    disclose.state = self.expandedProviders.contains(provider) ? .on : .off
    disclose.setAccessibilityLabel("Show \(provider.displayName) details")

    var views: [NSView] = [checkbox, logo, name, plan, status, updated, spacer]
    let providerState = self.store.states[provider] ?? ProviderViewState(provider: provider)
    let quickSetupAction = AllowanceBuilder.setupAction(for: providerState)
    if !self.store.isEnabled(provider) || quickSetupAction != nil {
      // A tracked provider already knows what it needs — a sign-in, permission,
      // a helper — so the button says that rather than a generic "Reconnect".
      let pendingAction = self.store.isEnabled(provider) ? quickSetupAction : nil
      let quickSetup = NSButton(
        title: pendingAction?.buttonTitle ?? "Connect",
        target: self,
        action: #selector(self.setupProviderClicked(_:)))
      quickSetup.identifier = NSUserInterfaceItemIdentifier("provider-quick-setup-\(provider.rawValue)")
      quickSetup.bezelStyle = .rounded
      quickSetup.controlSize = .small
      quickSetup.toolTip = pendingAction?.toolTip(for: provider)
        ?? "Connect \(provider.displayName) to Reserve"
      views.append(quickSetup)
    }
    views.append(disclose)
    let row = NSStackView(views: views)
    row.identifier = NSUserInterfaceItemIdentifier("settings-provider-\(provider.rawValue)")
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    row.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return row
  }

  /// Everything provider-specific lives behind its own row, including the
  /// Provider sign-in permission.
  private func providerDetail(_ provider: ProviderID) -> NSView {
    var rows: [NSView] = [
      self.formRow("Monthly cost:", self.planControls(provider), labelWidth: 92),
      self.formRow("Sources:", self.sourceLabels(provider), labelWidth: 92),
    ]
    if provider == .copilot {
      rows.append(SettingsLabel("Experimental support · quota checks only", size: 11, color: .secondaryLabelColor))
    }
    if provider == .gemini {
      rows.append(SettingsLabel(
        "Antigravity CLI 1.1.11 or later · sign in by running agy in Terminal",
        size: 11, color: .secondaryLabelColor))
    }
    if ProviderDescriptor.forProvider(provider).usesAPIKey {
      rows.append(self.formRow("API key:", self.planKeyControls(provider), labelWidth: 92))
      rows.append(SettingsLabel(
        "Unofficial usage endpoint · the key can call models, so use a dedicated one",
        size: 11, color: .secondaryLabelColor))
    }
    if self.store.canNameAccount(provider) {
      rows.append(self.formRow("Name:", self.accountNameControls(provider), labelWidth: 92))
    }
    if provider.isAdded, ProviderDescriptor.forProvider(provider).homeFolderEnvironmentKey != nil {
      rows.append(self.formRow("Folder:", self.configDirectoryControls(provider), labelWidth: 92))
      rows.append(SettingsLabel(
        "\(AccountFolderCopy.helperName(provider)) keeps one sign-in per folder · the same email on several accounts is fine",
        size: 11, color: .secondaryLabelColor))
    }
    if provider.isAnthropic || provider == .cursor {
      let checkbox = NSButton(
        checkboxWithTitle: "Allow access to my \(provider.displayName) usage",
        target: self, action: #selector(self.keychainChanged(_:)))
      checkbox.identifier = NSUserInterfaceItemIdentifier(
        "settings-keychain-\(provider.rawValue)")
      checkbox.state = self.store.keychainReadAllowed(for: provider) ? .on : .off
      checkbox.toolTip =
        "Uses \(provider.displayName)'s existing sign-in only to check usage. Reserve never stores it."
      rows.append(self.formRow("\(provider.displayName):", checkbox, labelWidth: 92))
    }
    if provider.isAnthropic {
      let passive = NSButton(checkboxWithTitle: "Also use Claude Code's status line in Terminal", target: self,
        action: #selector(self.claudePassiveUpdatesChanged(_:)))
      passive.state = self.store.claudePassiveUpdatesEnabled(for: provider) ? .on : .off
      passive.identifier = NSUserInterfaceItemIdentifier(Self.passiveUpdatesIdentifier(provider))
      // The status line is installed in the account's own folder, so it
      // waits for that folder to be chosen.
      passive.isEnabled = !provider.isAdded || self.store.claudeConfigDirectory(for: provider) != nil
      passive.toolTip = "Claude Code in a terminal shares your limits after each response, which updates Reserve right away. Your existing status line is kept. The Claude desktop app does not send these updates."
      rows.append(self.formRow("Updates:", passive, labelWidth: 92))
      rows.append(SettingsLabel(
        "Faster updates while you use Claude Code in Terminal. Not sent by the desktop app.",
        size: 11, color: .secondaryLabelColor))
    }
    if let setupAction = AllowanceBuilder.setupAction(
      for: self.store.states[provider] ?? ProviderViewState(provider: provider))
    {
      let setup = NSButton(
        title: setupAction.buttonTitle,
        target: self,
        action: #selector(self.setupProviderClicked(_:)))
      setup.identifier = NSUserInterfaceItemIdentifier("provider-setup-\(provider.rawValue)")
      setup.bezelStyle = .rounded
      setup.toolTip = setupAction.toolTip(for: provider)
      rows.append(self.formRow("", setup, labelWidth: 92))
    }
    if provider.isAdded {
      let remove = NSButton(
        title: "Remove account", target: self, action: #selector(self.removeAccountClicked(_:)))
      remove.identifier = NSUserInterfaceItemIdentifier("provider-remove-account-\(provider.rawValue)")
      remove.bezelStyle = .rounded
      remove.toolTip = ProviderDescriptor.forProvider(provider).usesAPIKey
        ? "Stops tracking this account and deletes its saved key from Reserve."
        : "Stops tracking this account and forgets its settings. Its folder and sign-in stay on disk."
      rows.append(self.formRow("", remove, labelWidth: 92))
    }
    // A key-connected plan disconnects by removing its key, next to the field.
    if !ProviderDescriptor.forProvider(provider).usesAPIKey,
      self.store.isEnabled(provider) || self.store.states[provider]?.snapshot != nil
    {
      let disconnect = NSButton(
        title: "Disconnect from Reserve", target: self,
        action: #selector(self.disconnectProvider(_:)))
      disconnect.identifier = NSUserInterfaceItemIdentifier("provider-disconnect-\(provider.rawValue)")
      disconnect.bezelStyle = .rounded
      disconnect.toolTip = "Stops Reserve checks and clears its cached usage. Your provider app stays signed in."
      rows.append(self.formRow("", disconnect, labelWidth: 92))
    }
    let refresh = NSButton(
      title: "Refresh Now", target: self, action: #selector(self.refreshProvider(_:)))
    refresh.identifier = NSUserInterfaceItemIdentifier("provider-refresh-\(provider.rawValue)")
    refresh.bezelStyle = .rounded
    rows.append(self.formRow("", refresh, labelWidth: 92))

    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.identifier = NSUserInterfaceItemIdentifier("provider-detail-\(provider.rawValue)")
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 22, bottom: 10, right: 0)
    return stack
  }

  private func planControls(_ provider: ProviderID) -> NSView {
    let currency = SettingsLabel("$", size: 12, color: .secondaryLabelColor)
    let field = SettingsTextField(
      value: self.store.monthlySubscriptionCost(for: provider).map {
        String(format: "%.0f", $0)
      } ?? "")
    field.placeholderString = "Optional"
    field.identifier = NSUserInterfaceItemIdentifier("subscription.\(provider.rawValue)")
    field.delegate = self
    field.target = self
    field.action = #selector(self.subscriptionCostChanged(_:))
    field.widthAnchor.constraint(equalToConstant: 68).isActive = true
    let suffix = SettingsLabel("per month", size: 12, color: .secondaryLabelColor)

    let reported = self.store.states[provider]?.snapshot?.billingRenewsAt
    let renewalLabel = SettingsLabel(
      self.renewalStatusText(for: provider), size: 12, color: .secondaryLabelColor)
    renewalLabel.identifier = NSUserInterfaceItemIdentifier("renewal-status.\(provider.rawValue)")
    self.renewalStatusLabels[provider] = renewalLabel
    let renewalField = SettingsTextField(
      value: self.store.renewalDay(for: provider).map(String.init) ?? "")
    renewalField.placeholderString = "1–31"
    renewalField.identifier = NSUserInterfaceItemIdentifier("renewal.\(provider.rawValue)")
    renewalField.delegate = self
    renewalField.target = self
    renewalField.action = #selector(self.renewalDayChanged(_:))
    renewalField.toolTip =
      reported == nil
      ? "This provider does not report its billing date. Enter the billing day once."
      : "Provider-reported renewal date"
    renewalField.isHidden = reported != nil
    renewalField.widthAnchor.constraint(equalToConstant: 58).isActive = true
    let dayLabel = SettingsLabel("Billing day", size: 12, color: .secondaryLabelColor)
    dayLabel.isHidden = reported != nil

    let price = NSStackView(views: [currency, field, suffix])
    price.orientation = .horizontal
    price.alignment = .centerY
    price.spacing = 5
    let billing = NSStackView(views: [dayLabel, renewalField, renewalLabel])
    billing.orientation = .horizontal
    billing.alignment = .centerY
    billing.spacing = 6
    let stack = NSStackView(views: [price, billing])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    return stack
  }

  /// Where each number came from, so estimates cannot masquerade as authority.
  private func tokenSourceText(_ provider: ProviderID) -> String {
    let state = self.store.states[provider]
    if self.store.hasUnattributedClaudeHistory(for: provider) {
      return "Tokens · account split unavailable · device total in Insights"
    }
    if let usage = state?.localUsage {
      return usage.origin == .providerAccount
        ? "Tokens and value · provider-reported account data"
        : "Tokens · from local logs on this Mac · value estimated"
    }
    return state?.snapshot?.detailedUsageUnavailable == true
      ? "Tokens · detailed usage unavailable for this account" : "Tokens · no usage data found"
  }

  private func sourceLabels(_ provider: ProviderID) -> NSView {
    let state = self.store.states[provider]
    let quotaSource = state?.snapshot?.source ?? "not connected"
    let quotaPrefix = state?.snapshot?.windows.isEmpty == true ? "Usage" : "Limits"
    let quota = SettingsLabel(
      "\(quotaPrefix) · provider reported · \(quotaSource)",
      size: 12, color: .secondaryLabelColor)
    quota.identifier = NSUserInterfaceItemIdentifier("settings-source-quota-\(provider.rawValue)")
    let tokens = SettingsLabel(
      self.tokenSourceText(provider), size: 12, color: .secondaryLabelColor)
    tokens.identifier = NSUserInterfaceItemIdentifier("settings-source-tokens-\(provider.rawValue)")
    let freshness = SettingsLabel(
      (state?.snapshot?.fetchedAt).map { DashboardFormat.updated($0, now: Date()) }
        ?? "Never updated",
      size: 12, color: .tertiaryLabelColor)
    freshness.identifier = NSUserInterfaceItemIdentifier(
      "settings-source-freshness-\(provider.rawValue)")
    let stack = NSStackView(views: [quota, tokens, freshness])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    return stack
  }

  private func apiProviderRow(_ provider: APIAccountID) -> NSView {
    let availability = self.store.apiConsumptionKeyAvailability(provider)
    let saved = availability == .present
    let writable = availability == .present || availability == .missing
    let checkbox = NSButton(
      checkboxWithTitle: "", target: self, action: #selector(self.apiConsumptionChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("api-enabled-\(provider.rawValue)")
    checkbox.state = self.store.isAPIConsumptionEnabled(provider) ? .on : .off
    checkbox.isEnabled = saved || self.store.isAPIConsumptionEnabled(provider)
    checkbox.toolTip =
      saved
      ? "Measure \(provider.displayName) API consumption"
      : (writable ? "Save a \(provider.keyKind.lowercased()) first" : "Waiting for Keychain access")
    checkbox.setAccessibilityLabel("Measure \(provider.displayName) API consumption")

    let name = SettingsLabel(provider.displayName, size: 13, weight: .medium, color: .labelColor)
    let kind = SettingsLabel(provider.keyKind, size: 12, color: .secondaryLabelColor)
    let status = SettingsLabel(
      self.apiReading(for: provider, saved: saved), size: 12, color: .secondaryLabelColor)
    status.identifier = NSUserInterfaceItemIdentifier("api-status-\(provider.rawValue)")
    status.toolTip =
      self.apiExplanation(for: provider)
      ?? self.store.apiConsumption[provider]?.breakdownSummary
      ?? status.stringValue
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let heading = NSStackView(views: [checkbox, SettingsProviderLogo(api: provider.provider), name, kind, status])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 8

    let tag = self.store.apiAccounts.firstIndex(of: provider) ?? 0
    var buttons: [NSButton] = [
      self.apiRowButton(
        title: saved ? "Replace" : "Save",
        identifier: "api-save-\(provider.rawValue)",
        action: #selector(self.apiKeySubmitted(_:)),
        tag: tag,
        toolTip: "Save this key in the macOS Keychain",
        accessibility: "Save \(provider.displayName) API key")
    ]
    if saved {
      buttons.append(
        self.apiRowButton(
          title: "Remove",
          identifier: "api-remove-\(provider.rawValue)",
          action: #selector(self.apiKeyRemoved(_:)),
          tag: tag,
          toolTip: "Delete this key from the macOS Keychain",
          accessibility: "Remove the saved \(provider.displayName) API key"))
    }
    // The key is created on the provider's own site, so the row hands the
    // browser the exact page rather than leaving people to find it.
    buttons.append(
      self.apiRowButton(
        title: "Get a key",
        identifier: "api-page-\(provider.rawValue)",
        action: #selector(self.apiKeyPageOpened(_:)),
        tag: tag,
        toolTip: "Open \(provider.keySettingsURL.host ?? "the provider") to create a "
          + provider.keyKind.lowercased(),
        accessibility: "Get a \(provider.displayName) \(provider.keyKind.lowercased())"))

    let field = self.apiCredentialField(
      identifier: "api-key-\(provider.rawValue)",
      placeholder: saved ? "Replace key" : provider.keyHint,
      accessibility: "\(provider.displayName) API key",
      toolTip: "Paste a \(provider.displayName) \(provider.keyKind.lowercased()) "
        + "(\(provider.keyHint)). Return saves it.",
      minimumWidth: 120)

    if !writable {
      field.isEnabled = false
      field.placeholderString = availability == .unknown ? "Checking Keychain…" : "Keychain temporarily unavailable"
      buttons.first?.isEnabled = false
    }
    if provider.isAdded {
      buttons.append(
        self.apiRowButton(
          title: "Remove account",
          identifier: "api-forget-\(provider.rawValue)",
          action: #selector(self.apiAccountRemoved(_:)),
          tag: tag,
          toolTip: "Stop tracking this account and delete its key from Reserve",
          accessibility: "Remove \(provider.displayName)"))
    }
    let fields = NSStackView(views: [field] + buttons)
    fields.orientation = .horizontal
    fields.alignment = .centerY
    fields.spacing = 8
    // The row is pinned to the pane; the field takes whatever the buttons leave,
    // so a saved provider showing three buttons still lines up with the footer.
    fields.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    for button in buttons {
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    var rowViews: [NSView] = [heading, fields]
    if self.apiAccountTakesName(provider) { rowViews.append(self.apiAccountNameRow(provider)) }
    let help: String?
    switch provider.provider {
    case .anthropic:
      help = "Spend needs an admin key from a Claude Console organization. Other keys only show that they work."
    case .typeSafe:
      help = "TypeSafe reports available models, descriptions and release dates. "
        + "Its documented API does not expose account spend or balance."
    default: help = nil
    }
    if let help {
      let explanation = NSTextField(wrappingLabelWithString: help)
      explanation.identifier = NSUserInterfaceItemIdentifier("api-help-\(provider.rawValue)")
      explanation.font = .systemFont(ofSize: 11)
      explanation.textColor = .secondaryLabelColor
      explanation.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
      rowViews.append(explanation)
    }
    // Why the provider refused or failed, in full: the status line above has
    // room only for "Needs attention".
    // Keep the error label installed even without an error. A refresh can finish
    // while the credential editor has focus, when structural rebuilds are deferred.
    // Live updates must still replace or clear the previous key's explanation.
    let error = self.apiExplanation(for: provider)
    let reason = NSTextField(wrappingLabelWithString: error ?? "")
    reason.identifier = NSUserInterfaceItemIdentifier("api-error-\(provider.rawValue)")
    reason.font = .systemFont(ofSize: 11)
    reason.textColor = .secondaryLabelColor
    reason.isHidden = error == nil
    reason.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    rowViews.append(reason)
    let row = NSStackView(views: rowViews)
    row.identifier = NSUserInterfaceItemIdentifier("api-provider-\(provider.rawValue)")
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = 6
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  /// Paste, save, remove and "Get a key" for a key-connected plan, mirroring
  /// the API account rows. The key goes straight to the Keychain.
  private func planKeyControls(_ provider: ProviderID) -> NSView {
    let availability = self.store.planKeyAvailability(for: provider)
    let saved = availability == .present
    let writable = availability == .present || availability == .missing
    let connection = ProviderDescriptor.forProvider(provider).apiKeyConnection
    let hint = connection?.keyHint ?? "API key"
    let field = NSSecureTextField()
    field.identifier = NSUserInterfaceItemIdentifier("plan-key-\(provider.rawValue)")
    field.placeholderString = saved ? "Replace key" : hint
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.bezelStyle = .roundedBezel
    field.target = self
    field.delegate = self
    field.action = #selector(self.planKeySubmitted(_:))
    field.toolTip = "Paste a \(provider.displayName) API key (\(hint)). Return saves it."
    field.setAccessibilityLabel("\(provider.displayName) API key")
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    var buttons: [NSButton] = [
      self.apiRowButton(
        title: saved ? "Replace" : "Save",
        identifier: "plan-save-\(provider.rawValue)",
        action: #selector(self.planKeySubmitted(_:)), tag: 0,
        toolTip: "Save this key in the macOS Keychain and connect \(provider.displayName)",
        accessibility: "Save \(provider.displayName) API key")
    ]
    if saved {
      buttons.append(self.apiRowButton(
        title: "Remove",
        identifier: "plan-remove-\(provider.rawValue)",
        action: #selector(self.planKeyRemoved(_:)), tag: 0,
        toolTip: "Delete this key from the macOS Keychain and disconnect \(provider.displayName)",
        accessibility: "Remove the saved \(provider.displayName) API key"))
    }
    buttons.append(self.apiRowButton(
      title: "Get a key",
      identifier: "plan-page-\(provider.rawValue)",
      action: #selector(self.planKeyPageOpened(_:)), tag: 0,
      toolTip: "Open \(connection?.keySettingsURL.host ?? provider.displayName) to create an API key",
      accessibility: "Get a \(provider.displayName) API key"))
    for button in buttons {
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    if !writable {
      field.isEnabled = false
      field.placeholderString = availability == .unknown ? "Checking Keychain…" : "Keychain temporarily unavailable"
      buttons.first?.isEnabled = false
    }
    let row = NSStackView(views: [field] + buttons)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  /// The first slot keeps the identifier its self-tests and existing users know.
  private static func passiveUpdatesIdentifier(_ provider: ProviderID) -> String {
    provider == .anthropic ? "settings-claude-passive" : "settings-claude-passive-\(provider.rawValue)"
  }

  /// A plain path field with a Finder chooser beside it. The value is a folder
  /// path, never a secret, so it stays visible and editable.
  private func configDirectoryControls(_ provider: ProviderID) -> NSView {
    let field = NSTextField()
    field.identifier = NSUserInterfaceItemIdentifier("config-dir-\(provider.rawValue)")
    field.stringValue = self.store.accountFolder(for: provider)?.path ?? ""
    field.placeholderString = AccountFolderCopy.example(provider)
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.maximumNumberOfLines = 1
    field.target = self
    field.delegate = self
    field.action = #selector(self.configDirectorySubmitted(_:))
    field.toolTip = "The folder \(AccountFolderCopy.helperName(provider)) uses for this account (its \(AccountFolderCopy.variable(provider))). Return saves it."
    field.setAccessibilityLabel("\(provider.displayName) configuration folder")
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let choose = self.apiRowButton(
      title: "Choose…",
      identifier: "config-dir-choose-\(provider.rawValue)",
      action: #selector(self.chooseConfigDirectoryClicked(_:)), tag: 0,
      toolTip: "Pick the folder in Finder. A new folder is filled in by \(AccountFolderCopy.helperName(provider)) at sign-in.",
      accessibility: "Choose the \(provider.displayName) configuration folder")
    choose.setContentHuggingPriority(.required, for: .horizontal)
    choose.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = NSStackView(views: [field, choose])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func configDirectoryProvider(for sender: NSControl) -> ProviderID? {
    guard let raw = sender.identifier?.rawValue else { return nil }
    for prefix in ["config-dir-choose-", "config-dir-"] where raw.hasPrefix(prefix) {
      let provider = ProviderID(rawValue: String(raw.dropFirst(prefix.count)))
      return provider.flatMap {
        $0.isAdded && ProviderDescriptor.forProvider($0).homeFolderEnvironmentKey != nil ? $0 : nil
      }
    }
    return nil
  }

  /// The person's own name for an added account. Return or leaving the field
  /// saves it; an empty name goes back to the automatic one.
  private func accountNameControls(_ provider: ProviderID) -> NSView {
    let field = NSTextField()
    field.identifier = NSUserInterfaceItemIdentifier("account-name-\(provider.rawValue)")
    field.stringValue = self.store.accountShownLabel(for: provider) ?? ""
    field.placeholderString = provider.isAdded ? "Team, client…" : "Personal…"
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.maximumNumberOfLines = 1
    field.target = self
    field.delegate = self
    field.action = #selector(self.accountNameSubmitted(_:))
    field.toolTip = provider.isAdded
      ? "Your name for this account, shown everywhere in Reserve. Leave empty to use its organization."
      : "Your name for this account, shown everywhere in Reserve. Leave empty to show just \(provider.kind.displayName)."
    field.setAccessibilityLabel("\(provider.kind.displayName) account name")
    field.widthAnchor.constraint(equalToConstant: 220).isActive = true
    let save = self.apiRowButton(
      title: "Saved",
      identifier: "account-name-save-\(provider.rawValue)",
      action: #selector(self.accountNameSubmitted(_:)), tag: 0,
      toolTip: "Save this name",
      accessibility: "Save the \(provider.kind.displayName) account name")
    // Lights up as soon as the name differs from the saved one.
    save.isEnabled = false
    save.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [field, save])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func accountNameProvider(for sender: NSControl) -> ProviderID? {
    guard let raw = sender.identifier?.rawValue else { return nil }
    for prefix in ["account-name-save-", "account-name-"] where raw.hasPrefix(prefix) {
      return ProviderID(rawValue: String(raw.dropFirst(prefix.count)))
        .flatMap { self.store.canNameAccount($0) ? $0 : nil }
    }
    return nil
  }

  /// Return, the Save button, or leaving the field all save the name.
  @objc private func accountNameSubmitted(_ sender: NSControl) {
    guard let provider = self.accountNameProvider(for: sender),
      let field = self.textField(identifier: "account-name-\(provider.rawValue)")
    else { return }
    let saved = self.store.accountShownLabel(for: provider) ?? ""
    let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if typed != saved { self.store.setAccountLabel(typed, for: provider) }
    field.stringValue = self.store.accountShownLabel(for: provider) ?? ""
    if let save = self.button(identifier: "account-name-save-\(provider.rawValue)") {
      save.title = "Saved"
      save.isEnabled = false
    }
    self.uiRefresh.coalesce { [weak self] in self?.applyLiveUpdate() }
  }

  private func button(identifier: String) -> NSButton? {
    self.window?.contentView.flatMap { view in
      Self.descendants(of: view).compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == identifier
      }
    }
  }

  /// One entry point for every account Reserve can track: subscriptions
  /// signed in with the provider's helper, plans read with a key, and API
  /// spend. Each entry follows the provider's descriptor, so a new provider
  /// shows up here with the right behaviour.
  private func addAccountRow() -> NSView {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    button.identifier = NSUserInterfaceItemIdentifier("settings-add-account-\(self.pane.rawValue)")
    button.controlSize = .regular
    button.setAccessibilityLabel("Add an account")
    button.toolTip = "Track another subscription, coding plan or API account"
    let menu = NSMenu()
    menu.autoenablesItems = false
    // Filled each time it opens, so every entry reflects what is connected now.
    menu.delegate = self
    self.fillAddAccountMenu(menu)
    button.menu = menu
    let note = SettingsLabel(
      self.pane == .api ? "API spend and balances" : "Subscriptions and coding plans", size: 12,
      color: .secondaryLabelColor)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [note, spacer, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu.items.first?.title == Self.addAccountTitle else { return }
    self.fillAddAccountMenu(menu)
  }

  private static let addAccountTitle = "Add Account…"

  private func fillAddAccountMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    // A pull-down shows its first item as the button title.
    menu.addItem(withTitle: Self.addAccountTitle, action: nil, keyEquivalent: "")
    menu.addItem(.sectionHeader(title: "Subscriptions"))
    for kind in AccountAddition.subscriptionKinds { menu.addItem(self.addAccountItem(kind)) }
    menu.addItem(.sectionHeader(title: "Coding plans"))
    for kind in AccountAddition.keyPlanKinds { menu.addItem(self.addAccountItem(kind)) }
    menu.addItem(.sectionHeader(title: "API spend"))
    for provider in APIConsumptionProvider.allCases { menu.addItem(self.addAPIAccountItem(provider)) }
  }

  private func addAccountItem(_ kind: ProviderKind) -> NSMenuItem {
    let defaultAccount = ProviderID(kind: kind)
    let action = AccountAddition.action(for: kind, defaultConnected: self.isConnected(defaultAccount))
    let item = NSMenuItem(
      title: kind.displayName, action: #selector(self.addAccountChosen(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = kind.rawValue
    item.image = Self.menuImage(ProviderArtwork.image(for: defaultAccount))
    let summary = AccountAddition.summary(for: kind)
    switch action {
    case .connectDefault, .addAccount:
      item.isEnabled = true
      item.toolTip = summary
      Self.setSubtitle(summary, on: item)
    case .unavailable(let reason):
      item.isEnabled = false
      item.toolTip = reason
      Self.setSubtitle("Connected · one account per Mac", on: item)
    }
    item.setAccessibilityLabel("Add \(kind.displayName) account")
    return item
  }

  private func addAPIAccountItem(_ provider: APIConsumptionProvider) -> NSMenuItem {
    let title = provider == .anthropic ? "Claude API (Anthropic)" : "\(provider.displayName) API"
    let item = NSMenuItem(
      title: title, action: #selector(self.addAPIAccountChosen(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = provider.rawValue
    item.image = Self.menuImage(ProviderArtwork.image(for: provider))
    let saved = self.store.apiConsumptionKeyAvailability(APIAccountID(provider: provider)) == .present
    let summary = saved
      ? "Add another \(provider.keyKind.lowercased()) · several accounts"
      : "Paste \(provider.keyKind.lowercased()) (\(provider.keyHint))"
    item.toolTip = summary
    Self.setSubtitle(summary, on: item)
    item.setAccessibilityLabel("Add \(title) account")
    return item
  }

  /// Turned on and holding a sign-in or key Reserve could read. An enabled
  /// card still waiting for its sign-in is not one: the menu connects it
  /// rather than adding another empty account beside it.
  private func isConnected(_ provider: ProviderID) -> Bool {
    guard self.store.isEnabled(provider), let state = self.store.states[provider] else { return false }
    return state.snapshot != nil && !state.requiresConnection && !state.requiresConfigDirectory
  }

  private static func menuImage(_ image: NSImage) -> NSImage {
    let sized = image.copy() as? NSImage ?? image
    sized.size = NSSize(width: 16, height: 16)
    return sized
  }

  private static func setSubtitle(_ subtitle: String, on item: NSMenuItem) {
    if #available(macOS 14.4, *) { item.subtitle = subtitle }
  }

  @objc private func addAccountChosen(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let kind = ProviderKind(rawValue: raw) else { return }
    let defaultAccount = ProviderID(kind: kind)
    switch AccountAddition.action(for: kind, defaultConnected: self.isConnected(defaultAccount)) {
    case .connectDefault:
      self.show(.providers)
      self.expandedProviders.insert(defaultAccount)
      self.rememberScrollOffset()
      self.applyPane(animated: false)
      self.setupProvider(defaultAccount)
    case .addAccount:
      do {
        let account = try self.store.addAccount(kind: kind)
        self.show(.providers)
        self.expandedProviders.insert(account)
        self.rememberScrollOffset()
        self.applyPane(animated: false)
        self.setupProvider(account)
      } catch {
        self.presentAlert("The account could not be added", error.localizedDescription)
      }
    case .unavailable(let reason):
      self.presentAlert("\(kind.displayName) is already connected", reason)
    }
  }

  /// API accounts are measured from the API pane; the entry takes the person
  /// to that provider's key field.
  @objc private func addAPIAccountChosen(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let provider = APIConsumptionProvider(rawValue: raw)
    else { return }
    // The first account takes the first key; every later key is an account
    // of its own beside it.
    let first = APIAccountID(provider: provider)
    let account = self.store.apiConsumptionKeyAvailability(first) == .present
      ? self.store.addAPIAccount(provider) : first
    self.show(.api)
    self.rememberScrollOffset()
    self.applyPane(animated: false)
    if let field = self.textField(identifier: "api-key-\(account.rawValue)") {
      field.scrollToVisible(field.bounds)
      self.window?.makeFirstResponder(field)
    }
  }

  private func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    if let window = self.window, window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: nil)
    } else {
      alert.runModal()
    }
  }

  @objc private func removeAccountClicked(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(of: "provider-remove-account-", with: "")
    guard let provider = ProviderID(rawValue: raw), provider.isAdded else { return }
    let alert = NSAlert()
    alert.messageText = "Remove \(provider.displayName) from Reserve?"
    alert.informativeText = ProviderDescriptor.forProvider(provider).usesAPIKey
      ? "Reserve stops tracking it, forgets its settings and deletes its saved key from Reserve. The key itself keeps working until you revoke it at \(provider.kind.displayName)."
      : "Reserve stops tracking it and forgets its settings. The account's folder and its \(AccountFolderCopy.helperName(provider)) sign-in stay on this Mac."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    let remove: () -> Void = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await self.store.removeAccountAndKey(provider)
          self.expandedProviders.remove(provider)
          self.rememberScrollOffset()
          self.applyPane(animated: false)
        } catch is CancellationError {
          // A new key was saved meanwhile; the account stays with it.
          self.applyPane(animated: false)
        } catch {
          let failure = NSAlert()
          failure.messageText = "The account could not be removed"
          failure.informativeText = error.localizedDescription
          failure.addButton(withTitle: "OK")
          if let window = self.window, window.isVisible {
            failure.beginSheetModal(for: window, completionHandler: nil)
          } else {
            failure.runModal()
          }
        }
      }
    }
    if let window = self.window, window.isVisible {
      alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { remove() }
      }
    } else if alert.runModal() == .alertFirstButtonReturn {
      remove()
    }
  }

  private func textField(identifier: String) -> NSTextField? {
    self.window?.contentView.flatMap { view in
      Self.descendants(of: view).compactMap { $0 as? NSTextField }.first {
        $0.identifier?.rawValue == identifier
      }
    }
  }

  @objc private func configDirectorySubmitted(_ sender: NSControl) {
    guard let provider = self.configDirectoryProvider(for: sender),
      let field = sender as? NSTextField
    else { return }
    self.saveConfigDirectory(field.stringValue, for: provider)
  }

  @objc private func chooseConfigDirectoryClicked(_ sender: NSButton) {
    guard let provider = self.configDirectoryProvider(for: sender) else { return }
    AccountFolderPicker.choose(
      for: provider, current: self.store.accountFolder(for: provider), from: self.window
    ) { [weak self] url in
      guard let self, let url else { return }
      self.saveConfigDirectory(url.path, for: provider)
    }
  }

  private func saveConfigDirectory(_ value: String, for provider: ProviderID) {
    let field = self.textField(identifier: "config-dir-\(provider.rawValue)")
    do {
      let directory = try self.store.setAccountFolder(value, for: provider)
      field?.stringValue = directory?.path ?? ""
      // The folder is part of the control structure, so the live update
      // rebuilds the card once AppKit has released the field editor.
      self.uiRefresh.coalesce { [weak self] in self?.applyLiveUpdate() }
    } catch {
      field?.stringValue = self.store.accountFolder(for: provider)?.path ?? ""
      let alert = NSAlert()
      alert.messageText = "That folder cannot be used"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      if let window = self.window, window.isVisible {
        alert.beginSheetModal(for: window, completionHandler: nil)
      } else {
        alert.runModal()
      }
    }
  }

  private func planKeyProvider(for sender: NSControl) -> ProviderID? {
    guard let raw = sender.identifier?.rawValue else { return nil }
    for prefix in ["plan-key-", "plan-save-", "plan-remove-", "plan-page-"] where raw.hasPrefix(prefix) {
      let provider = ProviderID(rawValue: String(raw.dropFirst(prefix.count)))
      return provider.flatMap { ProviderDescriptor.forProvider($0).usesAPIKey ? $0 : nil }
    }
    return nil
  }

  private func planKeyField(for provider: ProviderID) -> NSTextField? {
    self.window?.contentView.flatMap { view in
      Self.descendants(of: view).compactMap { $0 as? NSTextField }.first {
        $0.identifier?.rawValue == "plan-key-\(provider.rawValue)"
      }
    }
  }

  @objc private func planKeySubmitted(_ sender: NSControl) {
    guard let provider = self.planKeyProvider(for: sender),
      let field = self.planKeyField(for: provider)
    else { return }
    guard !self.keySaveInFlight else { return }
    let value = field.stringValue
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    self.keySaveInFlight = true
    sender.isEnabled = false
    self.setStatus("settings-status-\(provider.rawValue)", "Saving…")
    Task { @MainActor in
      defer {
        self.keySaveInFlight = false
        self.keyOperationStatus = nil
        sender.isEnabled = true
        self.applyLiveUpdate()
      }
      do {
        try await self.store.savePlanKey(value, for: provider)
        self.planKeyField(for: provider)?.stringValue = ""
        field.stringValue = ""
        self.rememberScrollOffset()
        self.applyPane(animated: false)
      } catch is CancellationError { } catch {
        self.presentKeySaveError(error, key: value)
      }
    }
  }

  @objc private func planKeyRemoved(_ sender: NSButton) {
    guard let provider = self.planKeyProvider(for: sender) else { return }
    guard !self.keySaveInFlight else { return }
    self.keySaveInFlight = true
    sender.isEnabled = false
    self.setStatus("settings-status-\(provider.rawValue)", "Removing…")
    Task { @MainActor in
      defer {
        self.keySaveInFlight = false
        self.keyOperationStatus = nil
        sender.isEnabled = true
        self.applyLiveUpdate()
      }
      do {
        try await self.store.removePlanKeyAsync(provider)
        self.applyLiveUpdate()
      } catch is CancellationError { } catch {
        self.presentKeySaveError(error, key: "", action: "removed")
      }
    }
  }

  @objc private func planKeyPageOpened(_ sender: NSButton) {
    guard let provider = self.planKeyProvider(for: sender),
      let url = ProviderDescriptor.forProvider(provider).apiKeyConnection?.keySettingsURL,
      url.scheme?.lowercased() == "https"
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func apiExplanation(for provider: APIAccountID) -> String? {
    self.store.apiConsumptionErrors[provider]
  }

  private func apiReading(for provider: APIAccountID, saved: Bool) -> String {
    switch self.store.apiConsumptionKeyAvailability(provider) {
    case .unknown: return "Checking Keychain…"
    case .unavailable: return "Keychain temporarily unavailable · retrying automatically"
    case .missing, .present: break
    }
    if self.store.apiConsumptionRefreshing.contains(provider) { return "Measuring…" }
    let snapshot = self.store.apiConsumption[provider]
    if self.store.apiConsumptionErrors[provider] != nil {
      return snapshot == nil ? "Needs attention" : "Latest check failed"
    }
    if let note = snapshot?.note {
      return [note.headline, note.detail].compactMap { $0 }.joined(separator: " · ")
    }
    if let primary = snapshot?.primary {
      let reading =
        primary.limitUSD.map {
          "\(DashboardFormat.money(primary.usedUSD)) of \(DashboardFormat.money($0))"
        } ?? "\(DashboardFormat.money(primary.usedUSD)) \(primary.label.lowercased())"
      // Settings is wide enough to name what the spend went on, not just how much.
      guard let snapshot, !snapshot.breakdown.isEmpty else { return reading }
      let leaders = snapshot.breakdown.prefix(2)
        .map { "\($0.label) \(DashboardFormat.money($0.usedUSD))" }
        .joined(separator: " · ")
      return "\(reading) — \(leaders)"
    }
    if saved {
      return self.store.isAPIConsumptionEnabled(provider) ? "Waiting for first read" : "Key saved"
    }
    return "No key"
  }

  private func apiRowButton(
    title: String,
    identifier: String,
    action: Selector,
    tag: Int,
    toolTip: String,
    accessibility: String
  ) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.tag = tag
    button.toolTip = toolTip
    button.setAccessibilityLabel(accessibility)
    return button
  }

  /// A normal field, not a secure one. Secure fields block paste and draw a
  /// focus ring that does not match the rest of Settings. The value is cleared
  /// as soon as it is saved to Keychain.
  private func apiCredentialField(
    identifier: String,
    placeholder: String,
    accessibility: String,
    toolTip: String,
    minimumWidth: CGFloat
  ) -> NSTextField {
    let field = NSTextField()
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.placeholderString = placeholder
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.maximumNumberOfLines = 1
    field.target = self
    field.action = #selector(self.apiKeySubmitted(_:))
    field.delegate = self
    field.toolTip = toolTip
    field.setAccessibilityLabel(accessibility)
    // Yields rather than breaking the row if a provider's buttons ever grow wide.
    let floor = field.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
    floor.priority = .defaultHigh
    floor.isActive = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  private func appearanceModeControl() -> NSView {
    let control = NSSegmentedControl(
      labels: AppearanceMode.allCases.map(\.displayName),
      trackingMode: .selectOne,
      target: self,
      action: #selector(self.appearanceModeChanged(_:)))
    control.identifier = NSUserInterfaceItemIdentifier("appearance-mode")
    control.selectedSegmentBezelColor = ReserveColor.accent
    control.selectedSegment =
      AppearanceMode.allCases.firstIndex(of: self.store.appearanceMode) ?? 0
    control.segmentDistribution = .fillEqually
    control.widthAnchor.constraint(equalToConstant: 220).isActive = true
    return control
  }

  private func accentRow() -> NSView {
    let buttons = AppearanceTheme.allCases.map { theme -> NSView in
      let button = AccentChoiceButton(theme: theme, selected: theme == self.store.appearanceTheme)
      button.identifier = NSUserInterfaceItemIdentifier("appearance-\(theme.rawValue)")
      button.target = self
      button.action = #selector(self.appearanceChanged(_:))
      return button
    }
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    return row
  }

  private func notificationsEnabledCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Enable Reserve notifications", target: self,
      action: #selector(self.notificationsChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("settings-notifications")
    checkbox.state = self.store.notificationsEnabled ? .on : .off
    checkbox.font = .systemFont(ofSize: 13, weight: .medium)
    return checkbox
  }

  private func notificationCheckbox(title: String, key: String) -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: title, target: self,
      action: #selector(self.notificationPreferenceChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("notification.option.\(key)")
    checkbox.state = self.store.notificationPreference(key) ? .on : .off
    return checkbox
  }

  // MARK: - Layout helpers

  private func pane(identifier: String, sections: [NSView]) -> NSView {
    let root = NSView()
    let stack = NSStackView(views: sections)
    stack.identifier = NSUserInterfaceItemIdentifier(identifier)
    stack.orientation = .vertical
    stack.alignment = .leading
    // Section cards are drawn just outside their content; keep a clear gap.
    stack.spacing = 22 + 2 * SettingsSectionCard.outset.height - 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsLayout.inset),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: root.trailingAnchor, constant: -SettingsLayout.inset),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: SettingsLayout.inset),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: root.bottomAnchor, constant: -SettingsLayout.inset),
    ])
    root.frame = NSRect(
      x: 0, y: 0, width: self.layoutSize.width, height: self.layoutSize.height)
    root.layoutSubtreeIfNeeded()
    let height = max(
      SettingsLayout.minimumHeight, ceil(stack.frame.height) + 2 * SettingsLayout.inset)
    root.frame = NSRect(
      x: 0, y: 0, width: self.layoutSize.width, height: height)
    root.layoutSubtreeIfNeeded()
    return root
  }

  private func section(
    title: String?, footer: String? = nil, footerIdentifier: String? = nil, rows: [NSView]
  ) -> NSView {
    var views: [NSView] = []
    if let title {
      views.append(SettingsLabel(title, size: 11, weight: .semibold, color: .secondaryLabelColor))
    }
    views.append(contentsOf: rows)
    if let footer {
      let label = NSTextField(wrappingLabelWithString: footer)
      label.identifier = footerIdentifier.map { NSUserInterfaceItemIdentifier($0) }
      label.font = .systemFont(ofSize: 11)
      label.textColor = .tertiaryLabelColor
      label.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
      views.append(label)
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    if title != nil, let first = views.first { stack.setCustomSpacing(11, after: first) }
    if footer != nil, views.count >= 2 {
      stack.setCustomSpacing(11, after: views[views.count - 2])
    }
    return SettingsSectionCard(content: stack, width: self.contentWidth)
  }

  /// A right-aligned label beside its control, the macOS settings idiom.
  private func formRow(_ label: String, _ control: NSView, labelWidth: CGFloat = 108) -> NSView {
    let caption = SettingsLabel(label, size: 13, color: .labelColor)
    caption.alignment = .right
    caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
    let row = NSStackView(views: [caption, control])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 10
    return row
  }

  // MARK: - Actions

  @objc private func providerChanged(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let provider = ProviderID(rawValue: raw) else {
      return
    }
    if sender.state == .on {
      self.setupProvider(provider)
    } else {
      self.store.setEnabled(provider, enabled: false)
    }
  }

  @objc private func toggleProviderDetail(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "provider-disclose-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    if self.expandedProviders.contains(provider) {
      self.expandedProviders.remove(provider)
    } else {
      self.expandedProviders.insert(provider)
    }
    self.applyPane(animated: true)
  }

  @objc private func refreshProvider(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "provider-refresh-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    self.store.refresh(provider)
  }

  @objc private func setupProviderClicked(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "")
      .replacingOccurrences(of: "provider-quick-setup-", with: "")
      .replacingOccurrences(of: "provider-setup-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    self.setupProvider(provider)
  }

  @objc private func disconnectProvider(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "provider-disconnect-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    self.store.disconnect(provider)
  }

  @objc private func claudePassiveUpdatesChanged(_ sender: NSButton) {
    let raw = sender.identifier?.rawValue ?? ""
    let provider = raw == "settings-claude-passive"
      ? ProviderID.anthropic
      : ProviderID(rawValue: raw.replacingOccurrences(of: "settings-claude-passive-", with: ""))
        ?? .anthropic
    do { try self.store.setClaudePassiveUpdatesEnabled(sender.state == .on, for: provider) }
    catch {
      sender.state = self.store.claudePassiveUpdatesEnabled(for: provider) ? .on : .off
      let alert = NSAlert()
      alert.messageText = "Claude updates could not be changed"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  @objc private func apiConsumptionChanged(_ sender: NSButton) {
    guard let provider = self.apiProvider(for: sender) else { return }
    self.store.setAPIConsumptionEnabled(provider, enabled: sender.state == .on)
    self.applyPane(animated: false)
  }

  @objc private func apiKeySubmitted(_ sender: NSControl) {
    guard let provider = self.apiProvider(for: sender),
      let field = self.apiKeyField(for: provider)
    else { return }
    guard !self.keySaveInFlight else { return }
    let value = field.stringValue
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    self.keySaveInFlight = true
    sender.isEnabled = false
    self.setStatus("api-status-\(provider.rawValue)", "Saving…")
    Task { @MainActor in
      defer {
        self.keySaveInFlight = false
        self.keyOperationStatus = nil
        sender.isEnabled = true
        self.applyLiveUpdate()
      }
      do {
        try await self.store.saveAPIConsumptionKey(value, for: provider)
        self.clearAPICredentialFields(for: provider)
        field.stringValue = ""
        self.rememberScrollOffset()
        self.applyPane(animated: false)
      } catch is CancellationError { } catch {
        self.presentKeySaveError(error, key: value)
      }
    }
  }

  private func setStatus(_ identifier: String, _ text: String) {
    self.keyOperationStatus = (identifier, text)
    guard let root = self.window?.contentView else { return }
    Self.descendants(of: root).compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == identifier
    }?.stringValue = text
  }

  /// The alert names the failure and never repeats the pasted key.
  private func presentKeySaveError(_ error: Error, key: String, action: String = "saved") {
    var message = error.localizedDescription
    if key.count >= 4 {
      message = message.replacingOccurrences(of: key, with: "that key")
    }
    let alert = NSAlert()
    alert.messageText = "The key could not be \(action)"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    if let window = self.window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  @objc private func apiKeyPageOpened(_ sender: NSButton) {
    guard let provider = self.apiProvider(for: sender) else { return }
    let url = provider.keySettingsURL
    guard url.scheme?.lowercased() == "https" else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func apiKeyRemoved(_ sender: NSButton) {
    guard let provider = self.apiProvider(for: sender) else { return }
    guard !self.keySaveInFlight else { return }
    self.keySaveInFlight = true
    sender.isEnabled = false
    self.setStatus("api-status-\(provider.rawValue)", "Removing…")
    Task { @MainActor in
      defer {
        self.keySaveInFlight = false
        self.keyOperationStatus = nil
        sender.isEnabled = true
        self.applyLiveUpdate()
      }
      do {
        try await self.store.removeAPIConsumptionKeyAsync(provider)
        self.applyLiveUpdate()
      } catch is CancellationError { } catch {
        self.presentKeySaveError(error, key: "", action: "removed")
      }
    }
  }

  private func apiProvider(for sender: NSControl) -> APIAccountID? {
    if let raw = sender.identifier?.rawValue {
      for prefix in ["api-enabled-", "api-key-", "api-save-", "api-remove-", "api-page-", "api-name-", "api-forget-"]
      where raw.hasPrefix(prefix) {
        return APIAccountID(rawValue: String(raw.dropFirst(prefix.count)))
      }
    }
    let index = sender.tag
    return self.store.apiAccounts.indices.contains(index) ? self.store.apiAccounts[index] : nil
  }

  /// Accounts are named once their provider has more than one, so two Claude
  /// API keys read "Anthropic · Perso" and "Anthropic · Nimbus".
  private func apiAccountTakesName(_ account: APIAccountID) -> Bool {
    self.store.apiAccounts.filter { $0.provider == account.provider }.count > 1
  }

  private func apiAccountNameRow(_ account: APIAccountID) -> NSView {
    let field = NSTextField()
    field.identifier = NSUserInterfaceItemIdentifier("api-name-\(account.rawValue)")
    field.stringValue = self.store.apiAccountLabel(for: account) ?? ""
    field.placeholderString = account.isAdded ? "Team, client…" : "Personal…"
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.target = self
    field.action = #selector(self.apiAccountNameSubmitted(_:))
    field.toolTip = "A name to tell this \(account.provider.displayName) account apart. Return saves it."
    field.setAccessibilityLabel("\(account.provider.displayName) account name")
    field.widthAnchor.constraint(equalToConstant: 220).isActive = true
    let caption = SettingsLabel("Name:", size: 12, color: .secondaryLabelColor)
    let row = NSStackView(views: [caption, field])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  @objc private func apiAccountNameSubmitted(_ sender: NSTextField) {
    guard let account = self.apiProvider(for: sender) else { return }
    self.store.setAPIAccountLabel(sender.stringValue, for: account)
    self.uiRefresh.coalesce { [weak self] in
      self?.rememberScrollOffset()
      self?.applyPane(animated: false)
    }
  }

  @objc private func apiAccountRemoved(_ sender: NSButton) {
    guard let account = self.apiProvider(for: sender), account.isAdded, !self.keySaveInFlight else { return }
    let alert = NSAlert()
    alert.messageText = "Remove \(account.displayName) from Reserve?"
    alert.informativeText = "Reserve stops measuring it and deletes its saved key from Reserve. The key itself keeps working until you revoke it at \(account.provider.displayName)."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    let remove: () -> Void = { [weak self] in
      guard let self else { return }
      self.keySaveInFlight = true
      Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.keySaveInFlight = false }
        do {
          try await self.store.removeAPIAccount(account)
        } catch is CancellationError {
        } catch {
          self.presentKeySaveError(error, key: "", action: "removed")
        }
        self.rememberScrollOffset()
        self.applyPane(animated: false)
      }
    }
    if let window = self.window, window.isVisible {
      alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { remove() }
      }
    } else if alert.runModal() == .alertFirstButtonReturn {
      remove()
    }
  }

  private func clearAPICredentialFields(for provider: APIAccountID) {
    self.apiKeyField(for: provider)?.stringValue = ""
  }

  private func apiKeyField(for provider: APIAccountID) -> NSTextField? {
    self.window?.contentView.flatMap { view in
      Self.descendants(of: view).compactMap { $0 as? NSTextField }.first {
        $0.identifier?.rawValue == "api-key-\(provider.rawValue)"
      }
    }
  }

  @objc private func keychainChanged(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "settings-keychain-", with: "")
    guard let provider = ProviderID(rawValue: raw),
      provider.isAnthropic || provider == .cursor
    else { return }
    if sender.state == .on {
      sender.state = .off
      self.setupProvider(provider)
    } else {
      self.store.setKeychainReadAllowed(false, for: provider)
    }
  }

  @objc private func intervalChanged(_ sender: NSPopUpButton) {
    let choices = Self.refreshIntervalMinutes
    let index = min(max(0, sender.indexOfSelectedItem), choices.count - 1)
    self.store.refreshIntervalMinutes = choices[index]
  }

  @objc private func hotKeyChanged(_ sender: NSPopUpButton) {
    let choices = DashboardHotKeyChoice.allCases
    let index = min(max(0, sender.indexOfSelectedItem), choices.count - 1)
    self.store.dashboardHotKey = choices[index]
  }

  @objc private func hidePersonalChanged(_ sender: NSButton) {
    self.store.hidesPersonalInfo = sender.state == .on
  }

  @objc private func checkForUpdates(_: NSButton) {
    guard let updater else { return }
    self.updateStatusLabel?.stringValue = "Checking GitHub Releases…"
    self.updateButton?.isEnabled = false
    updater.checkForUpdates()
  }

  @objc private func showDataFolder(_: NSButton) {
    guard
      let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Reserve", isDirectory: true)
    else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
  }

  @objc private func appearanceModeChanged(_ sender: NSSegmentedControl) {
    let index = max(0, sender.selectedSegment)
    guard AppearanceMode.allCases.indices.contains(index) else { return }
    self.store.appearanceMode = AppearanceMode.allCases[index]
    self.applyPane(animated: false)
  }

  @objc private func appearanceChanged(_ sender: NSButton) {
    guard let identifier = sender.identifier?.rawValue,
      let theme = AppearanceTheme(
        rawValue: identifier.replacingOccurrences(of: "appearance-", with: ""))
    else { return }
    self.store.appearanceTheme = theme
    self.applyPane(animated: false)
  }

  @objc private func menuBarProviderChanged(_ sender: NSPopUpButton) {
    let providerIndex = sender.indexOfSelectedItem - 1
    self.store.menuBarProvider =
      self.store.accounts.indices.contains(providerIndex)
      ? self.store.accounts[providerIndex] : nil
    self.applyPane(animated: false)
  }

  @objc private func menuBarDetailChanged(_ sender: NSButton) {
    switch sender.identifier?.rawValue {
    case "menu-bar-remaining": self.store.menuBarShowsRemaining = sender.state == .on
    case "menu-bar-reset": self.store.menuBarShowsReset = sender.state == .on
    default: break
    }
    self.applyPane(animated: false)
  }

  @objc private func notificationsChanged(_ sender: NSButton) {
    self.store.notificationsEnabled = sender.state == .on
  }

  @objc private func notificationPreferenceChanged(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue.split(separator: ".").last else { return }
    self.store.setNotificationPreference(sender.state == .on, name: String(key))
  }

  @objc private func subscriptionCostChanged(_ sender: NSTextField) {
    guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
      let provider = ProviderID(rawValue: String(raw))
    else { return }
    let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      self.store.setMonthlySubscriptionCost(nil, for: provider)
      return
    }
    guard let value = Double(trimmed), value.isFinite, value >= 0 else {
      sender.stringValue = self.store.monthlySubscriptionCost(for: provider).map {
        String(format: "%.0f", $0)
      } ?? ""
      sender.toolTip = "Enter your monthly cost, or leave this blank"
      return
    }
    sender.toolTip = "Optional · used only for Insights"
    self.store.setMonthlySubscriptionCost(value, for: provider)
  }

  @objc private func renewalDayChanged(_ sender: NSTextField) {
    guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
      let provider = ProviderID(rawValue: String(raw))
    else { return }
    let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      self.store.setRenewalDay(nil, for: provider)
      self.renewalStatusLabels[provider]?.stringValue = self.renewalStatusText(for: provider)
      sender.toolTip = "Enter the billing day, from 1 to 31"
      return
    }
    guard let day = Int(trimmed), (1...31).contains(day) else {
      sender.stringValue = self.store.renewalDay(for: provider).map(String.init) ?? ""
      sender.toolTip = "Enter a day from 1 to 31"
      return
    }
    sender.stringValue = "\(day)"
    sender.toolTip = "Saved · the next billing date is calculated from day \(day)"
    self.store.setRenewalDay(day, for: provider)
    self.renewalStatusLabels[provider]?.stringValue = self.renewalStatusText(for: provider)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let identifier = field.identifier?.rawValue
    else { return }
    if identifier.hasPrefix("subscription.") {
      self.subscriptionCostChanged(field)
    } else if identifier.hasPrefix("renewal.") {
      self.renewalDayChanged(field)
    } else if identifier.hasPrefix("config-dir-") {
      self.configDirectorySubmitted(field)
    } else if identifier.hasPrefix("account-name-") {
      self.accountNameSubmitted(field)
    }
    // AppKit still owns the field editor while delivering this notification.
    // Apply deferred changes on the next turn, after it releases that editor.
    self.uiRefresh.coalesce { [weak self] in self?.applyLiveUpdate() }
  }

  func controlTextDidChange(_ notification: Notification) {
    if let field = notification.object as? NSTextField,
      let provider = self.accountNameProvider(for: field),
      let save = self.button(identifier: "account-name-save-\(provider.rawValue)")
    {
      let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let changed = typed != (self.store.accountShownLabel(for: provider) ?? "")
      save.title = changed ? "Save" : "Saved"
      save.isEnabled = changed
      return
    }
    guard let field = notification.object as? NSTextField,
      let identifier = field.identifier?.rawValue,
      identifier.hasPrefix("renewal.")
    else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    field.toolTip = value.isEmpty || Int(value).map({ (1...31).contains($0) }) == true
      ? "Saved when editing ends"
      : "Enter a day from 1 to 31"
  }

  @objc private func loginChanged(_ sender: NSButton) {
    do {
      if sender.state == .on {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
      self.presentError(error)
    }
  }

  // MARK: - Helpers

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
  }

  private static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }

  private static func displayPlanName(_ value: String?) -> String {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "—" }
    return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
  }

  private static func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
  }

  private func renewalStatusText(for provider: ProviderID) -> String {
    self.store.nextRenewal(for: provider).map { "Next \(Self.shortDate($0))" } ?? "not set"
  }

  private func providerStatus(_ provider: ProviderID) -> (text: String, color: NSColor) {
    let state = self.store.states[provider]
    // Key-connected plans have no tool to detect; the key is what matters.
    if ProviderDescriptor.forProvider(provider).usesAPIKey {
      switch self.store.planKeyAvailability(for: provider) {
      case .unknown: return ("Checking Keychain…", .secondaryLabelColor)
      case .unavailable: return ("Keychain unavailable", .secondaryLabelColor)
      case .missing, .present: break
      }
      let saved = self.store.hasPlanKey(provider)
      if !self.store.isEnabled(provider) { return (saved ? "Key saved" : "Off", .secondaryLabelColor) }
      if !saved || state?.requiresConnection == true { return ("Key needed", ReserveColor.accent) }
      if state?.snapshot == nil, state?.error == nil { return ("Checking", .secondaryLabelColor) }
      return Self.providerStatus(
        provider: provider, hasSnapshot: state?.snapshot != nil,
        hasError: state?.error != nil, toolDetected: true)
    }
    let executable = ProviderDescriptor.forProvider(provider).helper?.executable ?? ""
    if !self.store.isEnabled(provider) {
      return (BinaryLocator.find(executable) != nil ? "Available on this Mac" : "Off", .secondaryLabelColor)
    }
    // Setup and permission states are next steps, not capacity risk, so they
    // use the accent rather than the warning colour.
    if state?.requiresConfigDirectory == true { return ("Folder needed", ReserveColor.accent) }
    if state?.requiresKeychainAccess == true { return ("Permission needed", ReserveColor.accent) }
    if state?.usageAccessDenied == true { return ("Usage access denied", ReserveColor.accent) }
    if state?.isConnecting == true { return ("Connecting", .secondaryLabelColor) }
    if state?.requiresConnection == true { return ("Sign-in needed", ReserveColor.accent) }
    return Self.providerStatus(
      provider: provider,
      hasSnapshot: state?.snapshot != nil,
      hasError: state?.error != nil,
      toolDetected: BinaryLocator.find(executable) != nil)
  }

  /// Records each registration outcome so Settings can show it. Does not call Carbon.
  func exerciseHotKeyStatusForSelfTest() -> Bool {
    let original = self.store.dashboardHotKeyStatus
    defer { self.store.setDashboardHotKeyStatus(original) }
    self.store.setDashboardHotKeyStatus(.conflict)
    self.pane = .general
    self.applyPane(animated: false)
    let conflict = self.statusText("settings-hotkey-status")
    self.store.setDashboardHotKeyStatus(.failed(-50))
    self.applyPane(animated: false)
    let failed = self.statusText("settings-hotkey-status")
    self.store.setDashboardHotKeyStatus(.registered)
    self.applyPane(animated: false)
    let registered = self.statusText("settings-hotkey-status")
    self.store.setDashboardHotKeyStatus(.inactive)
    self.applyPane(animated: false)
    let off = self.statusText("settings-hotkey-status")
    return conflict == "Already used by another app"
      && failed == "Could not register"
      && registered == "Registered. Opens the dashboard and does not close it."
      && off == "Off"
  }

  private func statusText(_ identifier: String) -> String {
    guard let window = self.window else { return "" }
    return Self.descendants(of: window.contentView ?? NSView()).compactMap { $0 as? NSTextField }
      .first { $0.identifier?.rawValue == identifier }?.stringValue ?? ""
  }

  /// Which controls exist. Reading text, status colour, and timestamps are not
  /// part of it, so those updates keep the same fields.
  private func controlStructureSignature() -> String {
    var parts = [
      self.pane.rawValue,
      ReserveAppearance.current.rawValue,
      ReserveAppearance.resolvedAppearance.name.rawValue,
      // Account names appear in row titles and the menu-bar pin popup, and
      // an added account's name can change under them.
      self.store.accounts.map(\.displayName).joined(separator: ","),
    ]
    switch self.pane {
    case .providers:
      for provider in self.store.accounts {
        let enabled = self.store.isEnabled(provider)
        let state = self.store.states[provider] ?? ProviderViewState(provider: provider)
        let setup = AllowanceBuilder.setupAction(for: state)
        let expanded = self.expandedProviders.contains(provider)
        let quick = !enabled || setup != nil
        var detail = ""
        if expanded {
          let reportedRenewal = state.snapshot?.billingRenewsAt != nil
          let planKey = ProviderDescriptor.forProvider(provider).usesAPIKey
          let savedKey = planKey ? String(describing: self.store.planKeyAvailability(for: provider)) : "-"
          // An added account's folder decides which controls are live (its
          // passive-updates checkbox waits for one).
          let folder = provider.isAdded
            ? (self.store.accountFolder(for: provider) != nil ? "folder" : "no-folder") : "-"
          detail = [
            reportedRenewal ? "reported" : "manual",
            planKey ? "key" : "-",
            savedKey,
            folder,
            setup?.buttonTitle ?? "-",
          ].joined(separator: ",")
        }
        parts.append(
          "\(provider.rawValue):\(enabled):\(expanded):\(quick):\(setup?.buttonTitle ?? "-"):\(detail)")
      }
    case .api:
      for provider in self.store.apiAccounts {
        parts.append("\(provider.rawValue):\(self.store.apiConsumptionKeyAvailability(provider))")
        // The name field appears once a provider has a second account.
        parts.append(self.apiAccountTakesName(provider) ? "named" : "-")
        parts.append(self.apiExplanation(for: provider) ?? "-")
      }
    case .insights:
      parts.append(self.store.accounts.map(\.rawValue).joined(separator: ","))
      parts.append(String(self.store.insightHistoryDays))
      for provider in self.store.accounts {
        parts.append("\(provider.rawValue):\(self.store.isEnabled(provider))")
      }
    case .appearance:
      parts.append(self.store.appearanceMode.rawValue)
      parts.append(self.store.appearanceTheme.rawValue)
    case .general, .notifications, .privacy, .about:
      break
    }
    return parts.joined(separator: "\u{1}")
  }

  /// Writes the current readings into the controls already on screen.
  private func applyLiveLabels() {
    guard let root = self.window?.contentView else { return }
    let views = Self.descendants(of: root)
    func field(_ identifier: String) -> NSTextField? {
      views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == identifier }
    }
    func setText(_ identifier: String, _ text: String, color: NSColor? = nil) {
      guard let label = field(identifier), label !== self.editingField else { return }
      if label.stringValue != text { label.stringValue = text }
      if let color { label.textColor = color }
    }
    func button(_ identifier: String) -> NSButton? {
      views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
    }
    func check(_ identifier: String, _ enabled: Bool) {
      button(identifier)?.state = enabled ? .on : .off
    }
    func select(_ identifier: String, _ index: Int) {
      (button(identifier) as? NSPopUpButton)?.selectItem(at: index)
    }
    switch self.pane {
    case .providers:
      for provider in self.store.accounts {
        let status = self.providerStatus(provider)
        setText(
          "settings-plan-\(provider.rawValue)",
          Self.displayPlanName(self.store.states[provider]?.snapshot?.planName))
        setText("settings-status-\(provider.rawValue)", status.text, color: status.color)
        let updated = (self.store.states[provider]?.snapshot?.fetchedAt).map {
          DashboardFormat.updated($0, now: Date()).replacingOccurrences(of: "Updated ", with: "")
        } ?? "never"
        setText("settings-updated-\(provider.rawValue)", updated)
        setText("renewal-status.\(provider.rawValue)", self.renewalStatusText(for: provider))
        setText("subscription.\(provider.rawValue)",
          self.store.monthlySubscriptionCost(for: provider).map { String(format: "%.0f", $0) } ?? "")
        setText("renewal.\(provider.rawValue)", self.store.renewalDay(for: provider).map(String.init) ?? "")
        check("settings-keychain-\(provider.rawValue)", self.store.keychainReadAllowed(for: provider))
        if provider.isAnthropic {
          check(Self.passiveUpdatesIdentifier(provider), self.store.claudePassiveUpdatesEnabled(for: provider))
        }
        if let button = views.compactMap({ $0 as? NSButton }).first(where: {
          $0.identifier?.rawValue == provider.rawValue
        }) {
          let state: NSControl.StateValue = self.store.isEnabled(provider) ? .on : .off
          if button.state != state { button.state = state }
        }
        setText("settings-source-tokens-\(provider.rawValue)", self.tokenSourceText(provider))
        let providerState = self.store.states[provider]
        let quotaSource = providerState?.snapshot?.source ?? "not connected"
        let quotaPrefix = providerState?.snapshot?.windows.isEmpty == true ? "Usage" : "Limits"
        setText(
          "settings-source-quota-\(provider.rawValue)",
          "\(quotaPrefix) · provider reported · \(quotaSource)")
        setText(
          "settings-source-freshness-\(provider.rawValue)",
          (providerState?.snapshot?.fetchedAt).map { DashboardFormat.updated($0, now: Date()) }
            ?? "Never updated")
      }
    case .api:
      for provider in self.store.apiAccounts {
        let saved = self.store.hasAPIConsumptionKey(provider)
        check("api-enabled-\(provider.rawValue)", self.store.isAPIConsumptionEnabled(provider))
        setText("api-status-\(provider.rawValue)", self.apiReading(for: provider, saved: saved))
        let error = self.apiExplanation(for: provider)
        setText("api-error-\(provider.rawValue)", error ?? "")
        field("api-error-\(provider.rawValue)")?.isHidden = error == nil
        field("api-status-\(provider.rawValue)")?.toolTip =
          self.apiExplanation(for: provider)
          ?? self.store.apiConsumption[provider]?.breakdownSummary
          ?? field("api-status-\(provider.rawValue)")?.stringValue
      }
    case .general:
      check("history-local-enabled", self.store.localHistoryEnabled)
      check("settings-hide-personal", self.store.hidesPersonalInfo)
      check("menu-bar-remaining", self.store.menuBarShowsRemaining)
      check("menu-bar-reset", self.store.menuBarShowsReset)
      select("settings-refresh-interval", Self.refreshIntervalMinutes.firstIndex(of: self.store.refreshIntervalMinutes) ?? 0)
      select("settings-dashboard-hotkey", DashboardHotKeyChoice.allCases.firstIndex(of: self.store.dashboardHotKey) ?? 0)
      select("menu-bar-provider", self.store.menuBarProvider.flatMap { self.store.accounts.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
      setText("settings-hotkey-status", self.hotKeyStatusText())
      if let preview = views.first(where: { $0.identifier?.rawValue == "menu-bar-preview" })
        as? MenuBarPreview
      {
        preview.reload()
      }
    case .insights:
      (views.first { $0.identifier?.rawValue == "insights-dashboard" } as? InsightDashboardView)?.refresh()
      self.reflowLiveContent()
    case .about:
      self.updateButton?.isEnabled = self.updater?.canCheckForUpdates ?? false
      if let checked = self.updater?.lastUpdateCheckDate {
        let ago = DashboardFormat.updated(checked, now: Date())
          .replacingOccurrences(of: "Updated ", with: "")
        setText("about-update-status", "Checked \(ago)")
      }
    case .notifications:
      check("settings-notifications", self.store.notificationsEnabled)
      for control in views.compactMap({ $0 as? NSButton }) {
        guard let identifier = control.identifier?.rawValue,
          identifier.hasPrefix("notification.option.") else { continue }
        let key = String(identifier.dropFirst("notification.option.".count))
        control.state = self.store.notificationPreference(key) ? .on : .off
      }
    case .appearance, .privacy:
      break
    }
    if let operation = self.keyOperationStatus {
      setText(operation.identifier, operation.text)
    }
  }

  /// Wrapping readings can change the document height without changing its
  /// controls. Keep their identities and the reader's distance from the top.
  private func reflowLiveContent() {
    guard let window = self.window, let installed = window.contentView else { return }
    let existingScroll = installed as? NSScrollView
    let document = existingScroll?.documentView ?? installed
    guard let stack = document.subviews.first as? NSStackView else { return }
    document.layoutSubtreeIfNeeded()
    let natural = max(SettingsLayout.minimumHeight,
      ceil(stack.fittingSize.height) + 2 * SettingsLayout.inset)
    guard abs(document.frame.height - natural) >= 1 else { return }
    let limit = max(SettingsLayout.minimumHeight,
      ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 80)
    let distanceFromTop = existingScroll.map {
      max(0, document.frame.height - $0.contentView.documentVisibleRect.maxY)
    } ?? 0
    document.frame.size.height = natural
    let scroll: NSScrollView?
    if natural > limit {
      if let existingScroll {
        scroll = existingScroll
      } else {
        let newScroll = NSScrollView()
        newScroll.identifier = NSUserInterfaceItemIdentifier("settings-scroll")
        newScroll.hasVerticalScroller = true
        newScroll.autohidesScrollers = false
        newScroll.scrollerStyle = .legacy
        newScroll.drawsBackground = false
        window.contentView = nil
        newScroll.documentView = document
        window.contentView = newScroll
        scroll = newScroll
      }
      document.frame.size.width = self.layoutSize.width
        - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    } else {
      if let existingScroll {
        existingScroll.documentView = nil
        window.contentView = document
      }
      document.frame.size.width = self.layoutSize.width
      scroll = nil
    }
    let size = NSSize(width: self.layoutSize.width, height: min(natural, limit))
    let frame = window.frame
    let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    window.setFrame(NSRect(x: frame.minX, y: frame.maxY - target.height,
      width: target.width, height: target.height), display: true)
    document.layoutSubtreeIfNeeded()
    if let scroll {
      let maximum = max(0, natural - scroll.contentView.bounds.height)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, maximum - distanceFromTop)))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }

  private func rememberScrollOffset() {
    guard let scroll = self.window?.contentView as? NSScrollView else { return }
    self.savedScrollOffsets[self.pane] = scroll.contentView.bounds.origin
  }

  /// A scroll view exists only if the last row is inside the document, the
  /// document is taller than the viewport, and a persistent scroller is shown.
  /// Scrolling that row into view has to land it inside the clip.
  private static func scrollReachable(_ row: NSView, scroll: NSScrollView, document: NSView) -> Bool {
    document.layoutSubtreeIfNeeded()
    scroll.layoutSubtreeIfNeeded()
    let inDocument = row.convert(row.bounds, to: document)
    guard inDocument.minY >= -0.5, inDocument.maxY <= document.frame.height + 0.5 else {
      return false
    }
    guard document.frame.height <= scroll.contentView.bounds.height + 0.5
      || (scroll.hasVerticalScroller && !scroll.autohidesScrollers)
    else { return false }
    if document.frame.height > scroll.contentView.bounds.height + 0.5 {
      let target = NSPoint(x: 0, y: max(0, inDocument.maxY - scroll.contentView.bounds.height))
      scroll.contentView.scroll(to: target)
      scroll.reflectScrolledClipView(scroll.contentView)
      let visible = scroll.contentView.documentVisibleRect
      guard visible.insetBy(dx: -1, dy: -1).intersects(inDocument) else { return false }
    }
    let widthLimit = scroll.contentView.bounds.width + 1
    return document.frame.width <= widthLimit
  }

  private static func providerStatus(
    provider: ProviderID,
    hasSnapshot: Bool,
    hasError: Bool,
    toolDetected: Bool
  ) -> (text: String, color: NSColor) {
    if hasSnapshot {
      return hasError
        ? ("Last update failed", .systemOrange)
        : ("Connected", .secondaryLabelColor)
    }
    if toolDetected {
      return ("Detected, not signed in", ReserveColor.accent)
    }
    return ("Setup needed", ReserveColor.accent)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
  }

  /// The comparable-value label must wrap inside the pane width, and its
  /// cell must be tall enough for every line. A scroll view nearby does not
  /// count.
  /// Lays out the window first. `layoutSubtreeIfNeeded` on the label alone
  /// does not give it the section width, and `boundingRect` with font leading
  /// is not the height `NSTextFieldCell` draws.
  private static func insightsTotalFits(window: NSWindow) -> Bool {
    guard let root = window.contentView else {
      fputs("insights-total missing content view\n", stderr)
      return false
    }
    root.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    guard let label = Self.descendants(of: root).compactMap({ $0 as? NSTextField }).first(where: {
      $0.identifier?.rawValue == "insights-total"
    }), let cell = label.cell as? NSTextFieldCell else {
      fputs("insights-total missing wrapping label\n", stderr)
      return false
    }
    let width = label.alignmentRect(forFrame: label.bounds).width
    let limit = NSSize(width: width, height: 10_000)
    let needed = cell.cellSize(forBounds: NSRect(origin: .zero, size: limit))
    let frame = label.convert(label.bounds, to: root)
    // Width constraints apply to the alignment rect. Bounds are 2 pt wider
    // on each side, so comparing bounds.width to contentWidth is always short.
    let alignmentWidth = label.alignmentRect(forFrame: label.bounds).width
    let full = label.stringValue
    let spoken = label.accessibilityLabel() ?? ""
    let fits = cell.wraps
      && !full.isEmpty
      && !full.contains("…")
      && alignmentWidth <= width + 0.5
      && alignmentWidth + 0.5 >= min(width, needed.width)
      && label.bounds.height + 0.5 >= needed.height
      && frame.maxX <= root.bounds.width + 0.5
      && spoken == full
    if !fits {
      fputs(
        "insights-total bounds=\(Int(label.bounds.width))x\(Int(label.bounds.height)) "
          + "alignment=\(Int(alignmentWidth.rounded())) "
          + "cell=\(Int(needed.width.rounded(.up)))x\(Int(needed.height.rounded(.up))) "
          + "frameMaxX=\(Int(frame.maxX)) root=\(Int(root.bounds.width)) "
          + "wraps=\(cell.wraps) lines=\(full.split(separator: "\n").count)\n",
        stderr)
    }
    return fits
  }

  private func exerciseInsightControlsForSelfTest() -> Bool {
    let saved = self.insightFilters
    let range = self.store.insightHistoryDays
    let loads = self.store.dailyHistoryLoadCountForTesting
    defer {
      self.insightFilters = saved
      self.store.insightHistoryDays = range
      self.applyPane(animated: false)
    }
    func control<T: NSView>(_ id: String, as type: T.Type) -> T? {
      self.window?.contentView.flatMap { root in
        Self.descendants(of: root).first { $0.identifier?.rawValue == id } as? T
      }
    }
    func send(_ control: NSControl) -> Bool {
      guard let action = control.action else { return false }
      return NSApp.sendAction(action, to: control.target, from: control)
    }
    guard let providers = control("insights-provider-filter", as: NSPopUpButton.self),
      let index = providers.itemTitles.firstIndex(of: ProviderID.openAI.displayName) else { return false }
    providers.selectItem(at: index)
    guard send(providers), self.insightFilters.provider == .openAI,
      control("insights-heatmap-grok", as: NSView.self) == nil,
      let metric = control("insights-metric", as: NSSegmentedControl.self) else { return false }
    metric.selectedSegment = 0
    guard send(metric), self.insightFilters.metric == .cost,
      let group = control("insights-breakdown-group", as: NSSegmentedControl.self) else { return false }
    group.selectedSegment = 1
    guard send(group), self.insightFilters.group == .day,
      let source = control("insights-source-filter", as: NSPopUpButton.self) else { return false }
    source.selectItem(at: 2)
    guard send(source), self.insightFilters.source == 2,
      let popup = control("insights-history-range", as: NSPopUpButton.self) else { return false }
    popup.selectItem(at: 0)
    guard send(popup), self.store.insightHistoryDays == 1 else { return false }
    // Rebuild synchronously: production's observer coalesces this update.
    self.applyPane(animated: false)
    guard control("insights-daily-trend", as: InsightTrendView.self)?.title == "Today's hourly estimated API value",
      control("insights-hourly-coverage", as: NSTextField.self)?.stringValue.contains("daily totals only") == true
    else { return false }
    self.store.insightHistoryDays = 7
    self.applyPane(animated: false)
    guard control("insights-daily-trend", as: InsightTrendView.self)?.title == "Daily estimated API value"
    else { return false }
    self.store.insightHistoryDays = 1
    self.applyPane(animated: false)
    guard let currentMetric = control("insights-metric", as: NSSegmentedControl.self) else { return false }
    currentMetric.selectedSegment = 2
    guard send(currentMetric), self.insightFilters.metric == .limits,
      control("insights-breakdown-group", as: NSSegmentedControl.self) == nil else { return false }
    return loads == self.store.dailyHistoryLoadCountForTesting
      && InsightTrendView.validateCurvesForSelfTest()
  }

  // MARK: - Self test

  func validateForSelfTest() -> (success: Bool, details: String) {
    guard let window = self.window else { return (false, "settings window was not created") }

    func descendants() -> [NSView] {
      window.contentView.map { Self.descendants(of: $0) } ?? []
    }
    func identifiers() -> Set<String> {
      Set(descendants().compactMap { $0.identifier?.rawValue })
    }
    func fits(_ stackID: String) -> Bool {
      guard let content = window.contentView else { return false }
      content.layoutSubtreeIfNeeded()
      guard let stack = descendants().first(where: { $0.identifier?.rawValue == stackID }) else {
        return false
      }
      if let scroll = stack.enclosingScrollView ?? descendants().compactMap({ $0 as? NSScrollView }).first,
        let document = scroll.documentView
      {
        return Self.scrollReachable(stack, scroll: scroll, document: document)
      }
      let frame = stack.convert(stack.bounds, to: content)
      return content.bounds.insetBy(dx: -1, dy: -1).contains(frame)
    }
    func typographyIsReadable() -> Bool {
      let fonts = descendants().compactMap { ($0 as? NSControl)?.font }
      return !fonts.isEmpty && fonts.allSatisfy { $0.pointSize >= 11 }
    }

    // The window is native: system appearance, resizable, toolbar navigation.
    let isNative =
      window.appearance == nil
      && window.styleMask.contains(.resizable)
      && window.toolbarStyle == .preference
      && window.toolbar?.items.count == Pane.allCases.count
      && window.toolbar?.identifier == "settings-toolbar"
    let usesOrdinaryWindowLevel = window.level == .normal

    var paneResults: [String] = []
    var allPanesFit = true
    var allPanesReadable = true
    let originalPane = self.pane
    for pane in Pane.allCases {
      self.pane = pane
    self.store.insightsVisible = pane == .insights && self.window?.isVisible == true
      self.applyPane(animated: false)
      let readable = typographyIsReadable()
      let fitted = fits("pane-\(pane.rawValue)")
      allPanesFit = allPanesFit && fitted
      allPanesReadable = allPanesReadable && readable
      paneResults.append("\(pane.rawValue)=\(fitted && readable)")
    }

    // General
    self.pane = .general
    self.applyPane(animated: false)
    let generalIDs = identifiers()
    let intervalPopup = descendants().compactMap { $0 as? NSPopUpButton }.first {
      $0.identifier?.rawValue == "settings-refresh-interval"
    }
    let expectedIntervals = [
      "Adaptive (2 to 30 min)",
      "Every 1 minute", "Every 5 minutes", "Every 10 minutes", "Every 15 minutes",
      "Every 30 minutes",
    ]
    let originalInterval = self.store.refreshIntervalMinutes
    intervalPopup?.selectItem(at: 1)
    let oneMinuteRefreshWorks =
      intervalPopup.flatMap { popup -> Bool? in
        guard let action = popup.action else { return nil }
        return NSApp.sendAction(action, to: popup.target, from: popup)
          && self.store.refreshIntervalMinutes == 1
      } ?? false
    self.store.refreshIntervalMinutes = originalInterval
    let generalSuccess =
      intervalPopup?.itemTitles == expectedIntervals
      && oneMinuteRefreshWorks
      && generalIDs.contains("settings-dashboard-hotkey")
      && generalIDs.contains("settings-hide-personal")
      && generalIDs.contains("settings-launch-at-login")
      && generalIDs.contains("menu-bar-provider")
      && generalIDs.contains("menu-bar-remaining")
      && generalIDs.contains("menu-bar-reset")
      && generalIDs.contains("menu-bar-preview")
      // Opacity is gone; system materials adapt on their own.
      && !generalIDs.contains("appearance-window-opacity")

    // Providers, including the per-provider disclosure.
    self.pane = .providers
    self.applyPane(animated: false)
    let providerIDs = identifiers()
    let providerRowsPresent = self.store.accounts.allSatisfy {
      providerIDs.contains("settings-provider-\($0.rawValue)")
        && providerIDs.contains("provider-disclose-\($0.rawValue)")
    }
    let providerStatusesAreTruthful =
      Self.providerStatus(
        provider: .openAI, hasSnapshot: true, hasError: true, toolDetected: true
      ).text
      == "Last update failed"
      && Self.providerStatus(
        provider: .openAI, hasSnapshot: true, hasError: false, toolDetected: true
      ).text
        == "Connected"
      && Self.providerStatus(
        provider: .openAI, hasSnapshot: false, hasError: false, toolDetected: true
      ).text
        == "Detected, not signed in"
      && Self.providerStatus(
        provider: .anthropic, hasSnapshot: false, hasError: false, toolDetected: false
      ).text
        == "Setup needed"
    let keychainAccessIsHiddenUntilExpanded =
      !providerIDs.contains("settings-keychain-anthropic")
      && !providerIDs.contains("settings-keychain-cursor")
    let quickProvider = ProviderID.copilot
    let quickProviderWasEnabled = self.store.isEnabled(quickProvider)
    self.store.setEnabled(quickProvider, enabled: false, refreshImmediately: false)
    self.applyPane(animated: false)
    let disconnectedProviderOffersConnect = identifiers().contains(
      "provider-quick-setup-\(quickProvider.rawValue)")
      && descendants().compactMap { $0 as? NSButton }.contains { $0.title == "Connect" }
    self.store.setEnabled(quickProvider, enabled: quickProviderWasEnabled, refreshImmediately: false)
    self.applyPane(animated: false)
    self.expandedProviders = [.anthropic, .cursor]
    self.applyPane(animated: false)
    let expandedIDs = identifiers()
    let expandedButtonTitles = descendants().compactMap { ($0 as? NSButton)?.title }
    let renewalField = descendants().compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .first { $0.identifier?.rawValue == "renewal.anthropic" }
    let originalRenewalDay = self.store.renewalDay(for: .anthropic)
    renewalField?.stringValue = "20"
    let renewalInputWorks: Bool
    if let renewalField {
      self.controlTextDidEndEditing(
        Notification(name: NSText.didEndEditingNotification, object: renewalField))
      renewalInputWorks =
        self.store.renewalDay(for: .anthropic) == 20
        && self.store.nextRenewal(for: .anthropic).map {
          Calendar.current.component(.day, from: $0) == 20
        } == true
        && self.renewalStatusLabels[.anthropic]?.stringValue.hasPrefix("Next ") == true
    } else {
      renewalInputWorks = false
    }
    self.store.setRenewalDay(originalRenewalDay, for: .anthropic)
    // Key-connected plans show a secure key field, Save and Get a key, and no
    // Keychain-consent checkbox or helper actions.
    self.expandedProviders = [.zai, .kimi]
    self.applyPane(animated: false)
    let keyIDs = identifiers()
    let planKeyControlsWork = [ProviderID.zai, .kimi].allSatisfy { provider in
      let field = descendants().first { $0.identifier?.rawValue == "plan-key-\(provider.rawValue)" }
      return field is NSSecureTextField
        && keyIDs.contains("plan-save-\(provider.rawValue)")
        && keyIDs.contains("plan-page-\(provider.rawValue)")
        && !keyIDs.contains("settings-keychain-\(provider.rawValue)")
        && !keyIDs.contains("provider-disconnect-\(provider.rawValue)")
    }
    let providersSuccess =
      providerRowsPresent
      && planKeyControlsWork
      && keychainAccessIsHiddenUntilExpanded
      && expandedIDs.contains("settings-keychain-anthropic")
      && expandedIDs.contains("settings-keychain-cursor")
      && expandedButtonTitles.contains("Allow access to my Claude usage")
      && expandedButtonTitles.contains("Allow access to my Cursor usage")
      && expandedIDs.contains("subscription.anthropic")
      && expandedIDs.contains("renewal.anthropic")
      && expandedIDs.contains("provider-detail-anthropic")
      && providerStatusesAreTruthful
      && disconnectedProviderOffersConnect
      && renewalInputWorks
    self.expandedProviders = []

    self.pane = .api
    self.applyPane(animated: false)
    let apiIDs = identifiers()
    let apiKeyEntryPresent = self.store.apiAccounts.allSatisfy {
      apiIDs.contains("api-provider-\($0.rawValue)")
        && apiIDs.contains("api-key-\($0.rawValue)")
        && apiIDs.contains("api-save-\($0.rawValue)")
        && apiIDs.contains("api-enabled-\($0.rawValue)")
        && apiIDs.contains("api-page-\($0.rawValue)")
    }
    // Every key page must be an https provider URL the row can hand the browser.
    let apiKeyPagesAreHTTPS = self.store.apiAccounts.allSatisfy {
      $0.keySettingsURL.scheme?.lowercased() == "https" && $0.keySettingsURL.host?.isEmpty == false
    }
    let apiMeasurementStartsOff = self.store.apiAccounts.allSatisfy {
      !self.store.isAPIConsumptionEnabled($0)
    }
    let apiSuccess = apiKeyEntryPresent && apiMeasurementStartsOff && apiKeyPagesAreHTTPS

    // Notifications: smart alerts first, thresholds behind Advanced.
    self.pane = .notifications
    self.applyPane(animated: false)
    let notificationIDs = identifiers()
    let notificationLabels = descendants().compactMap { ($0 as? NSButton)?.title }
    let smartKeys = ["deficit", "exhausted", "weeklyRenewal", "stale", "incident"]
    let advancedKeys = ["threshold50", "threshold90", "planRenewal", "fiveHourRenewal", "sound"]
    let notificationsSuccess =
      notificationIDs.contains("settings-notifications")
      && (smartKeys + advancedKeys).allSatisfy {
        notificationIDs.contains("notification.option.\($0)")
      }
      && notificationLabels.contains("Notify at 50% left")
      && notificationLabels.contains("Notify at 10% left")
      && !notificationLabels.contains { $0.hasSuffix("% used") }

    // Appearance keeps the four identities as accents, and light/dark is the
    // system's business.
    self.pane = .appearance
    self.applyPane(animated: false)
    let appearanceIDs = identifiers()
    let originalMode = self.store.appearanceMode
    let modeControl = descendants().compactMap { $0 as? NSSegmentedControl }.first {
      $0.identifier?.rawValue == "appearance-mode"
    }
    modeControl?.selectedSegment = 2
    let appearanceModeWorks =
      modeControl.flatMap { control -> Bool? in
        guard let action = control.action else { return nil }
        return NSApp.sendAction(action, to: control.target, from: control)
          && self.store.appearanceMode == .dark
          && NSApplication.shared.appearance?.name == .darkAqua
      } ?? false
    self.store.appearanceMode = originalMode
    let originalTheme = self.store.appearanceTheme
    self.store.appearanceTheme = .matrix
    let matrixBase = ReserveAppearance.palette.windowBase.usingColorSpace(.sRGB)
    self.store.appearanceTheme = .ocean
    let oceanBase = ReserveAppearance.palette.windowBase.usingColorSpace(.sRGB)
    let accentTokensSwitch =
      self.store.appearanceTheme == .ocean
      && matrixBase?.isEqual(oceanBase) == false
      && ReserveColor.accent.usingColorSpace(.sRGB)?.isEqual(
        AppearanceTheme.ocean.palette.accent.usingColorSpace(.sRGB)) == true
    self.store.appearanceTheme = originalTheme
    let appearanceSuccess =
      AppearanceTheme.allCases.allSatisfy { appearanceIDs.contains("appearance-\($0.rawValue)") }
      && appearanceIDs.contains("theme-preview")
      && appearanceIDs.contains("appearance-mode")
      && !appearanceIDs.contains("menu-bar-provider")
      && !appearanceIDs.contains("menu-bar-remaining")
      && !appearanceIDs.contains("menu-bar-reset")
      && appearanceModeWorks
      && accentTokensSwitch

    // Insights carries the activity numbers the popover no longer shows.
    self.pane = .insights
    self.applyPane(animated: false)
    let insightIDs = identifiers()
    let insightLabels = descendants().compactMap { ($0 as? NSTextField)?.stringValue }
    let insightsSuccess =
      insightIDs.contains("insights-dashboard")
      && insightIDs.contains("insights-total")
      && Self.insightsTotalFits(window: window)
      && insightIDs.contains("insights-history-range")
      && insightIDs.contains("insights-heatmap-openAI")
      && insightIDs.contains("insights-heatmap-cursor")
      && insightIDs.contains("insights-provider-filter")
      && insightIDs.contains("insights-source-filter")
      && insightIDs.contains("insights-metric")
      && insightIDs.contains("insights-breakdown-group")
      && insightLabels.contains { $0.contains("missing day, not zero") }
      && insightLabels.contains { $0.contains("Account history can include other devices") }
      && insightLabels.contains { $0.contains("separate reference") }
      && self.exerciseInsightControlsForSelfTest()
      && self.exerciseHotKeyStatusForSelfTest()

    self.pane = .privacy
    self.applyPane(animated: false)
    let privacySuccess = identifiers().contains("privacy-data-folder")

    // About: identity, the update controls, and the links — in one place, and
    // reachable, which the standard AppKit panel was not from a floating window.
    self.pane = .about
    self.applyPane(animated: false)
    let aboutIDs = identifiers()
    let originalAutomatic = self.store.automaticUpdateChecks
    let automaticBox = descendants().compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "updates-automatic"
    }
    automaticBox?.state = originalAutomatic ? .off : .on
    let automaticUpdatesToggle =
      automaticBox.flatMap { box -> Bool? in
        guard let action = box.action else { return nil }
        return NSApp.sendAction(action, to: box.target, from: box)
          && self.store.automaticUpdateChecks == !originalAutomatic
      } ?? false
    self.store.automaticUpdateChecks = originalAutomatic
    let aboutSuccess =
      aboutIDs.contains("about-header")
      && aboutIDs.contains("about-version")
      && aboutIDs.contains("about-check-updates")
      && aboutIDs.contains("updates-automatic")
      && automaticBox?.title == "Check daily and notify me about updates"
      && aboutIDs.contains("link-\(ReserveLinks.repository.absoluteString)")
      && aboutIDs.contains("link-\(ReserveLinks.xProfile.absoluteString)")
      && automaticUpdatesToggle
      // The update controls must not also live in General.
      && !generalIDs.contains("about-check-updates")

    self.pane = originalPane
    self.applyPane(animated: false)

    window.close()
    let closeReleasesHiddenPane = window.contentView == nil
    self.showWindow(nil)
    let reopenRebuildsPane = window.contentView != nil
    window.orderOut(nil)

    let success =
      isNative && usesOrdinaryWindowLevel && allPanesFit && allPanesReadable && generalSuccess
      && providersSuccess && apiSuccess && notificationsSuccess && appearanceSuccess && insightsSuccess
      && privacySuccess && aboutSuccess && closeReleasesHiddenPane && reopenRebuildsPane
    let details =
      success
      ? "settings is a native toolbar window with \(Pane.allCases.count) resizable panes, one General menu-bar model, adaptive full-surface themes with fixed quota semantics, deficit transition alerts, provider detail behind disclosure, and an About pane carrying identity, updates and links"
      : "settings native=\(isNative), ordinaryLevel=\(usesOrdinaryWindowLevel), panes=[\(paneResults.joined(separator: ","))], fit=\(allPanesFit), readable=\(allPanesReadable), general=\(generalSuccess), providers=\(providersSuccess), api=\(apiSuccess), notifications=\(notificationsSuccess), appearance=\(appearanceSuccess), insights=\(insightsSuccess), privacy=\(privacySuccess), about=\(aboutSuccess), closeReleases=\(closeReleasesHiddenPane), reopenRebuilds=\(reopenRebuildsPane)"
    return (success, details)
  }

  // MARK: - Rendering

  func render(to url: URL) throws { try self.renderPane(.general, to: url) }
  func renderAbout(to url: URL) throws { try self.renderPane(.about, to: url) }
  func renderAppearance(to url: URL) throws { try self.renderPane(.appearance, to: url) }
  func renderAlerts(to url: URL) throws { try self.renderPane(.notifications, to: url) }
  func renderInsights(to url: URL) throws { try self.renderPane(.insights, to: url) }
  func renderProviders(to url: URL) throws { try self.renderPane(.providers, to: url) }

  func renderAPI(to url: URL) throws { try self.renderPane(.api, to: url) }

  func renderInsightsOpaque(to url: URL, appearance: NSAppearance, metric: InsightDashboardView.Metric = .tokens) throws {
    self.insightFilters.metric = metric
    self.window?.appearance = appearance
    self.pane = .insights
    self.store.insightsVisible = false
    self.applyPane(animated: false)
    guard let root = self.window?.contentView else {
      throw SettingsRenderError.viewUnavailable
    }
    let view = (root as? NSScrollView)?.documentView ?? root
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard bounds.width >= 1, bounds.height >= 1 else { throw SettingsRenderError.viewUnavailable }
    view.frame = bounds
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(bounds.width.rounded(.up)),
      pixelsHigh: Int(bounds.height.rounded(.up)),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else { throw SettingsRenderError.bitmapUnavailable }
    rep.size = bounds.size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
      throw SettingsRenderError.bitmapUnavailable
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    ReserveColor.background.setFill()
    bounds.fill()
    view.displayIgnoringOpacity(bounds, in: context)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw SettingsRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  private func renderPane(_ pane: Pane, to url: URL) throws {
    self.pane = pane
    self.store.insightsVisible = pane == .insights && self.window?.isVisible == true
    if pane == .providers { self.expandedProviders = [.anthropic] }
    self.applyPane(animated: false)
    guard let view = self.window?.contentView else { throw SettingsRenderError.viewUnavailable }
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SettingsRenderError.bitmapUnavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw SettingsRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }
}

/// A compact live sample of the selected accent family. The three short status
/// marks deliberately retain their semantic colors across every theme.
@MainActor
private final class ThemePreview: NSView {
  private let theme: AppearanceTheme

  init(theme: AppearanceTheme) {
    self.theme = theme
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("theme-preview")
    self.setAccessibilityRole(.group)
    self.setAccessibilityLabel(
      "\(theme.displayName) theme preview with reserve, on pace, and deficit states")
    self.wantsLayer = true
    self.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    self.heightAnchor.constraint(equalToConstant: 96).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let palette = self.theme.palette
    let outer = NSBezierPath(roundedRect: self.bounds, xRadius: 12, yRadius: 12)
    palette.windowBase.setFill()
    outer.fill()
    palette.border.setStroke()
    outer.lineWidth = 1
    outer.stroke()

    let card = NSRect(x: 14, y: 14, width: self.bounds.width - 28, height: 68)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
    palette.cardSurface.setFill()
    cardPath.fill()
    palette.border.setStroke()
    cardPath.stroke()

    let title = NSAttributedString(
      string: self.theme.displayName,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ])
    title.draw(at: NSPoint(x: card.minX + 13, y: card.maxY - 25))

    palette.progressTrack.setFill()
    let track = NSRect(x: card.minX + 13, y: card.minY + 17, width: card.width - 300, height: 7)
    NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
    palette.accent.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * 0.62, height: 7),
      xRadius: 3.5, yRadius: 3.5
    ).fill()

    let labels: [(String, NSColor)] = [
      ("Under pace", .systemGreen), ("On pace", .systemGreen),
      ("May run out early", .systemOrange),
    ]
    var x = track.maxX + 20
    for (text, color) in labels {
      let value = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color,
        ])
      value.draw(at: NSPoint(x: x, y: card.minY + 13))
      x += value.size().width + 12
    }
  }
}

/// A live preview of what the menu bar will show.
@MainActor
private final class MenuBarPreview: NSView {
  private let store: UsageStore
  private var lastPresentation: String?

  init(store: UsageStore) {
    self.store = store
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("menu-bar-preview")
    self.setAccessibilityRole(.group)
    self.setAccessibilityLabel(
      store.menuBarProvider.map { "Menu bar preview, \($0.displayName)" }
        ?? "Menu bar preview, Reserve icon")
    self.wantsLayer = true
    self.applyChrome()
    self.layer?.cornerRadius = 6
    self.layer?.borderWidth = 1
    self.reload()
    self.heightAnchor.constraint(equalToConstant: 26).isActive = true
  }

  /// Replaces the sample row when the menu-bar reading changes. The preview
  /// view itself stays put.
  func reload() {
    let now = Date()
    let summaries = store.orderedStates.filter { store.isEnabled($0.provider) }
      .map { AllowanceBuilder.summary(for: $0, now: now) }
    let selection = AllowanceBuilder.menuBarSummary(
      from: summaries, pinnedProvider: store.menuBarProvider)
    let presentation = "\(selection.isPinned):\(selection.summary?.provider.rawValue ?? "-"):"
      + "\(selection.summary?.primary?.remainingPercent ?? -1):\(String(describing: selection.summary?.paceState)):"
      + "\(store.menuBarShowsRemaining):\(store.menuBarShowsReset)"
    guard presentation != self.lastPresentation else { return }
    self.lastPresentation = presentation
    self.setAccessibilityLabel(
      store.menuBarProvider.map { "Menu bar preview, \($0.displayName)" }
        ?? "Menu bar preview, Reserve icon")
    for subview in self.subviews { subview.removeFromSuperview() }
    let image = selection.isPinned
      ? selection.summary.map { ProviderArtwork.image(for: $0.provider) }
      : NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Reserve")
    var views: [NSView] = []
    if let image {
      image.size = NSSize(width: 14, height: 14)
      let logo = NSImageView(image: image)
      logo.contentTintColor = image.isTemplate ? .labelColor : nil
      logo.translatesAutoresizingMaskIntoConstraints = false
      logo.widthAnchor.constraint(equalToConstant: 14).isActive = true
      views.append(logo)
    }
    var parts: [String] = []
    if store.menuBarShowsRemaining {
      parts.append(selection.summary?.primary.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—%")
    }
    if store.menuBarShowsReset { parts.append("2d 4h") }
    if !parts.isEmpty {
      let label = NSTextField(labelWithString: parts.joined(separator: "  "))
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
      label.textColor = selection.summary?.paceState.color ?? .secondaryLabelColor
      views.append(label)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 5
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 9),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -9),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private func applyChrome() {
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
    self.layer?.borderColor = self.resolvedCGColor(.separatorColor)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyChrome()
  }
}

/// Each choice previews the theme's surfaces as well as its control accent.
@MainActor
private final class AccentChoiceButton: NSButton {
  private let theme: AppearanceTheme
  private let selected: Bool

  init(theme: AppearanceTheme, selected: Bool) {
    self.theme = theme
    self.selected = selected
    super.init(frame: .zero)
    self.title = ""
    self.isBordered = false
    self.setAccessibilityRole(.radioButton)
    self.setAccessibilityLabel("\(theme.displayName) accent")
    self.setAccessibilityValue(selected ? 1 : 0)
    self.toolTip = "Use the \(theme.displayName) accent"
    self.widthAnchor.constraint(equalToConstant: 76).isActive = true
    self.heightAnchor.constraint(equalToConstant: 56).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  override func draw(_ dirtyRect: NSRect) {
    let palette = self.theme.palette
    let accent = palette.accent
    let swatch = NSRect(x: 0, y: self.bounds.height - 36, width: self.bounds.width, height: 36)
    let path = NSBezierPath(roundedRect: swatch, xRadius: 7, yRadius: 7)
    palette.windowBase.setFill()
    path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.setClip()
    accent.setFill()
    NSRect(x: 9, y: swatch.minY + 9, width: swatch.width - 18, height: 6).fill()
    accent.withAlphaComponent(0.35).setFill()
    NSRect(x: 9, y: swatch.minY + 21, width: (swatch.width - 18) * 0.6, height: 6).fill()
    NSGraphicsContext.restoreGraphicsState()

    if self.selected {
      accent.setStroke()
      let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
      ring.lineWidth = 2
      ring.stroke()
    } else {
      palette.border.setStroke()
      let ring = NSBezierPath(
        roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
      ring.lineWidth = 1
      ring.stroke()
    }

    let name = NSAttributedString(
      string: self.theme.displayName,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: self.selected ? .semibold : .regular),
        .foregroundColor: self.selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    name.draw(at: NSPoint(x: (self.bounds.width - name.size().width) / 2, y: 2))
  }
}

/// Reserve's identity: the app's own icon, its version, when this copy was
/// built, and one line on what it is for.
@MainActor
private final class AboutHeaderView: NSView {
  init() {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("about-header")
    self.setAccessibilityRole(.group)
    self.wantsLayer = true
    self.layer?.cornerRadius = 10
    self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    self.layer?.borderWidth = 1
    self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

    let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.setAccessibilityElement(false)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

    let name = SettingsLabel("Reserve", size: 20, weight: .semibold, color: .labelColor)
    name.alignment = .center
    let version = SettingsLabel(
      "Version \(Self.version) (\(Self.build))", size: 12, color: .secondaryLabelColor)
    version.identifier = NSUserInterfaceItemIdentifier("about-version")
    version.alignment = .center
    let built = SettingsLabel(Self.builtLine(), size: 11, color: .tertiaryLabelColor)
    built.alignment = .center
    let tagline = SettingsLabel(
      "Keep subscription limits, resets and local usage clearly in view.",
      size: 11, color: .tertiaryLabelColor)
    tagline.alignment = .center

    let stack = NSStackView(views: [icon, name, version, built, tagline])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 3
    stack.setCustomSpacing(10, after: icon)
    stack.setCustomSpacing(6, after: name)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -20),
      self.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
  }

  private static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }

  /// Taken from the executable itself, so it describes this copy rather than a
  /// date baked in at some earlier point.
  private static func builtLine() -> String {
    guard let executable = Bundle.main.executableURL,
      let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
      let date = attributes[.modificationDate] as? Date
    else { return "" }
    let formatter = DashboardFormat.localizedDateFormatter(template: "yMMMdjm")
    return "Built \(formatter.string(from: date))"
  }
}

private final class SettingsSeparator: NSView {
  init(width: CGFloat) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(.separatorColor)
    self.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.heightAnchor.constraint(equalToConstant: 1),
      self.widthAnchor.constraint(equalToConstant: width),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(.separatorColor)
  }
}

@MainActor
private final class SettingsProviderLogo: NSView {
  convenience init(api provider: APIConsumptionProvider) {
    self.init(
      image: ProviderArtwork.image(for: provider), tinted: provider != .anthropic)
  }

  convenience init(provider: ProviderID) {
    self.init(image: ProviderArtwork.image(for: provider), tinted: !provider.isAnthropic)
  }

  private init(image source: NSImage, tinted: Bool) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
    self.layer?.cornerRadius = 5
    self.setAccessibilityElement(false)
    let image = NSImageView(image: source)
    image.setAccessibilityElement(false)
    image.contentTintColor = tinted ? .labelColor : nil
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 22),
      self.heightAnchor.constraint(equalToConstant: 22),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 13),
      image.heightAnchor.constraint(equalToConstant: 13),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
  }
}

private final class SettingsTextField: NSTextField {
  convenience init(value: String) {
    self.init(frame: .zero)
    self.stringValue = value
    self.alignment = .right
    self.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    self.isBezeled = true
    self.bezelStyle = .roundedBezel
    self.formatter = NumberFormatter()
  }
}

private final class SettingsLabel: NSTextField {
  init(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor,
    wraps: Bool = false
  ) {
    super.init(frame: .zero)
    self.stringValue = text
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = false
    self.font = .systemFont(ofSize: size, weight: weight)
    self.textColor = color
    self.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
    self.maximumNumberOfLines = wraps ? 0 : 1
    self.cell?.wraps = wraps
    self.cell?.isScrollable = false
    if wraps {
      self.setAccessibilityLabel(text)
      self.setContentCompressionResistancePriority(.required, for: .vertical)
    }
  }

  required init?(coder: NSCoder) { nil }
}

/// A settings or Insights section on the theme's card surface, like the
/// dashboard's cards. The card is drawn just outside its content, so every
/// row keeps the width and alignment it was laid out with.
final class SettingsSectionCard: NSView {
  static let outset = NSSize(width: 12, height: 10)
  private let card = CALayer()

  init(content: NSView, width: CGFloat) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.masksToBounds = false
    self.card.cornerRadius = 10
    self.card.borderWidth = 1
    self.layer?.insertSublayer(self.card, at: 0)
    self.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      content.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor),
      content.topAnchor.constraint(equalTo: self.topAnchor),
      content.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: width),
    ])
    self.applyChrome()
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.card.frame = self.bounds.insetBy(dx: -Self.outset.width, dy: -Self.outset.height)
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyChrome()
  }

  private func applyChrome() {
    self.card.backgroundColor = self.resolvedCGColor(ReserveColor.section)
    self.card.borderColor = self.resolvedCGColor(ReserveColor.hairline)
  }
}

private enum SettingsLayout {
  static let defaultSize = NSSize(width: 680, height: 500)
  static let minimumHeight: CGFloat = 320
  static let inset: CGFloat = 22
  static var contentWidth: CGFloat { self.defaultSize.width - 2 * self.inset }
}

private enum SettingsRenderError: Error {
  case viewUnavailable
  case bitmapUnavailable
  case pngUnavailable
}
