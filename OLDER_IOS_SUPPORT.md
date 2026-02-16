# Older iOS Support Plan

Current deployment target: **iOS 17.6** (project-level: iOS 17.0)

---

## Plan A: iOS 16 Support

Dropping to iOS 16.0 is relatively straightforward — the main blocker is the iOS 17+ `.onChange` signature used throughout the app.

### 1. `.onChange(of:)` two-parameter → single-parameter (39 instances across 9 files)

The iOS 17+ variant `{ oldValue, newValue in }` must be converted to the iOS 14+ form `{ newValue in }`.

**Files affected:**

| File | Count |
|------|-------|
| `KaChat/Views/Chat/ChatDetailView.swift` | 12 |
| `KaChat/Views/Settings/SettingsView.swift` | 9 |
| `KaChat/Views/Chat/ChatListView.swift` | 6 |
| `KaChat/App/MainTabView.swift` | 4 |
| `KaChat/Views/Contacts/ContactsView.swift` | 3 |
| `KaChat/App/KaChatApp.swift` | 2 |
| `KaChat/Views/Chat/MessageBubbleView.swift` | 1 |
| `KaChat/Views/Contacts/AddContactView.swift` | 1 |
| `KaChat/Views/Onboarding/ImportWalletView.swift` | 1 |

**Migration pattern:**
```swift
// iOS 17+ (current)
.onChange(of: value) { oldValue, newValue in
    doSomething(newValue)
}

// iOS 16 compatible (single-parameter)
.onChange(of: value) { newValue in
    doSomething(newValue)
}

// If oldValue is needed, capture it manually:
// @State private var previousValue = initialValue
// .onChange(of: value) { newValue in
//     let old = previousValue
//     previousValue = newValue
//     doSomething(old, newValue)
// }
```

**Special case — `initial:` parameter (1 instance):**
`MessageBubbleView.swift:152` uses `.onChange(of:initial:)` which is iOS 17+ only.
Replace with `.onAppear { ... }` + `.onChange(of:) { ... }` to emulate initial fire.

### 2. `AVAudioApplication.requestRecordPermission` (1 instance)

`ChatDetailView.swift:2023` — already guarded with `#available(iOS 17.0, *)` and has fallback. **No work needed.**

### 3. Deployment target change

Update `IPHONEOS_DEPLOYMENT_TARGET` in `project.pbxproj`:
- Project-level: `17.0` → `16.0`
- KaChat target (Debug + Release): `17.6` → `16.0`
- KaChatNotificationService target (Debug + Release): `17.6` → `16.0`

### 4. Dependency verification

Verify these prebuilt xcframeworks were built with iOS 16 deployment target:
- GRPCAll.xcframework
- SwiftProtobuf.xcframework
- P256K.xcframework
- YbridOpus (SPM)

If any were built with iOS 17 minimum, they must be rebuilt with `-destination 'generic/platform=iOS'` and `IPHONEOS_DEPLOYMENT_TARGET=16.0`.

### Effort: **Low-Medium** — mostly mechanical `.onChange` signature changes (~1–2 hours)

---

## Plan B: iOS 15 Support

Dropping to iOS 15.0 requires significantly more work on top of everything in Plan A.

### 1. Everything from Plan A (iOS 16 changes)

All `.onChange` signature changes described above.

### 2. NavigationStack → NavigationView (17 instances across 12 files)

`NavigationStack` (iOS 16+) must be replaced with `NavigationView` everywhere.

**Files affected:**
- `GiftClaimView.swift` (1)
- `CreateWalletView.swift` (1)
- `OnboardingView.swift` (1)
- `ImportWalletView.swift` (1)
- `ChatInfoView.swift` (2)
- `ChatListView.swift` (1)
- `ChatDetailView.swift` (1)
- `MessageBubbleView.swift` (1)
- `QRScannerView.swift` (1)
- `ContactsView.swift` (3)
- `AddContactView.swift` (1)
- `SettingsView.swift` (3)

**Migration pattern:**
```swift
// iOS 16+ (current)
NavigationStack {
    content
}

// iOS 15 compatible
NavigationView {
    content
}
.navigationViewStyle(.stack)
```

**Caveats:** `NavigationView` has known bugs with state management and deep linking. Test thoroughly.

### 3. `.navigationDestination` → `NavigationLink(destination:)` (3 instances)

```
OnboardingView.swift:117  .navigationDestination(isPresented: $showCreateWallet)
OnboardingView.swift:120  .navigationDestination(isPresented: $showImportWallet)
ChatListView.swift:63     .navigationDestination(item: $selectedContact)
```

Replace with traditional `NavigationLink` or `background(NavigationLink(...).hidden())` pattern.

### 4. `.scrollDismissesKeyboard(.interactively)` (1 instance)

```
ChatDetailView.swift:385
```

Remove or wrap in `#available(iOS 16.0, *)`. For iOS 15, implement keyboard dismissal via UIKit (`UIScrollView.keyboardDismissMode` through introspection or a UIKit wrapper).

### 5. `ShareLink` + `Transferable` (2 instances)

```
MessageBubbleView.swift:1638  ShareLink(...)
MessageBubbleView.swift:1696  struct ShareableImage: Transferable
```

Replace with `UIActivityViewController` presented via `UIViewControllerRepresentable`.

### 6. `.font(.title.bold())` chain syntax (5 instances)

```
GiftClaimView.swift:55   .font(.title2.bold())
GiftClaimView.swift:100  .font(.title3.bold())
GiftClaimView.swift:124  .font(.title3.bold())
GiftClaimView.swift:146  .font(.title3.bold())
ChatInfoView.swift:53    .font(.title2.bold())
```

Replace with: `.font(.title2).fontWeight(.bold)`

### 7. `.foregroundStyle` → `.foregroundColor` (3 instances)

```
OnboardingView.swift:21      .foregroundStyle(.accent)
ChatDetailView.swift:993     .foregroundStyle(.orange)
ChatDetailView.swift:998     .foregroundStyle(.secondary)
```

Replace with `.foregroundColor(.accentColor)`, `.foregroundColor(.orange)`, `.foregroundColor(.secondary)`.

### 8. `UNUserNotificationCenter.setBadgeCount` (1 instance)

`ChatService+Persistence.swift:851` — already guarded with `#available(iOS 16.0, *)` and has fallback. **No work needed.**

### 9. `AVAsset.loadTracks(withMediaType:)` (1 instance)

`ChatDetailView.swift:2452` — already guarded with `#available(iOS 16.0, *)` and has fallback. **No work needed.**

### 10. Deployment target + dependency rebuild

Same as Plan A but targeting iOS 15.0. Swift Concurrency back-deployment requires Swift 5.5+ toolchain (Xcode 13.2+), which is satisfied by any modern Xcode. Verify all xcframeworks support iOS 15.

### Effort: **Medium-High** — NavigationStack migration is the bulk of the work (~4–8 hours), plus thorough regression testing of all navigation flows.

---

## Recommendation

**iOS 16** is the pragmatic choice — it's almost entirely mechanical `.onChange` changes with minimal risk. iOS 15 requires a full navigation rewrite with significant regression risk and covers <3% of active devices as of early 2026.
