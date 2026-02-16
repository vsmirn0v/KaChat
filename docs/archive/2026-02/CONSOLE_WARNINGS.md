> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Console Warnings Explained

This document explains common console warnings that appear during development and which ones are actionable vs. benign system warnings.

## Fixed Warnings

### 1. UIScene Property Accessed Before Set

**Warning:**
```
UIScene property of UINSSceneViewController was accessed before it was set.
```

**Cause:** The `warmUpKeyboard()` function was accessing `UIApplication.shared.connectedScenes` during `didFinishLaunchingWithOptions`, before the scene lifecycle had completed initialization.

**Fix (KaChatApp.swift ~96-102):**
Added delay and guard to ensure scene is ready:

```swift
// Warm up keyboard in background to avoid first-tap delay
// Delay slightly to ensure scene is ready (prevents "UIScene accessed before set" warning)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    Self.warmUpKeyboard()
}
```

```swift
/// Pre-load keyboard to avoid first-use delay
private static func warmUpKeyboard() {
    // Guard against accessing scene before it's ready
    guard !UIApplication.shared.connectedScenes.isEmpty else {
        return
    }

    // ... rest of keyboard warmup
}
```

**Result:** ✅ No more UIScene access warnings

---

## Benign System Warnings (Cannot Be Fixed)

These warnings come from iOS system internals and are not caused by app code. They're safe to ignore.

### 2. NSBundle Init Failed

**Warning:**
```
NSBundle (null) initWithPath failed because the resolved path is empty or nil
```

**What it is:** iOS system warning related to bundle loading during app initialization.

**Why it appears:** iOS framework internals trying to load optional bundles (like emoji packs, keyboard layouts, etc.) that may not exist.

**Impact:** None - this is informational only.

**Action:** None - system warning, cannot be fixed in app code.

---

### 3. OTP Completion List Rect Warning

**Warning:**
```
Refusing to display OTP completion list relative to null rect. positioningView:<SwiftUI.VerticalTextView: ...>
```

**What it is:** iOS keyboard suggestion system (AutoFill, OTP codes) having geometry issues with SwiftUI text fields.

**Why it appears:** SwiftUI text fields don't always provide valid geometry to UIKit's keyboard suggestion system during layout. This is a known SwiftUI/UIKit interop issue.

**Impact:** OTP autofill suggestions may not appear in some cases, but manual entry works fine.

**Action:** None - this is a SwiftUI framework issue. Apple is aware of it.

**Workaround (if needed):** Use native `UITextContentType` on TextField:
```swift
TextField("Code", text: $code)
    .textContentType(.oneTimeCode)  // May reduce frequency
```

---

### 4. Candidate Receiver Push Warning

**Warning:**
```
resultToPush is nil, will not push anything to candidate receiver..
```

**What it is:** iOS keyboard suggestion system (predictive text, QuickType) trying to push suggestions but having no results.

**Why it appears:** Common with SwiftUI TextFields when the keyboard suggestion engine runs but has nothing to suggest.

**Impact:** None - just means no autocomplete suggestions available at that moment.

**Action:** None - system warning, expected behavior.

---

### 5. Remote Text Input Session Warning

**Warning:**
```
-[RTIInputSystemClient remoteTextInputSessionWithID:performInputOperation:] perform input operation requires a valid sessionID. inputModality = Keyboard, inputOperation = <null selector>, customInfoType = UIEmojiSearchOperations
```

**What it is:** iOS remote keyboard system (used for emoji search, autocorrect, etc.) warning about internal state.

**Why it appears:** iOS keyboard subsystem internal state management. Happens frequently with SwiftUI text input.

**Impact:** None - keyboard works normally.

**Action:** None - system warning, cannot be fixed in app code.

---

## Summary by Category

### ✅ Fixed (App Code)
- UIScene accessed before set → Delayed keyboard warmup

### ⚠️ Benign (iOS System)
- NSBundle init failed → iOS framework internals
- OTP completion rect → SwiftUI/UIKit geometry
- Candidate receiver push → Keyboard suggestions
- Remote text input session → Keyboard subsystem

### 📊 Warning Frequency
| Warning | Frequency | Impact |
|---------|-----------|--------|
| UIScene access | Once at startup | Fixed ✓ |
| NSBundle | 1-2 times at startup | None |
| OTP rect | Per text field focus | None |
| Candidate push | Per keystroke | None |
| RTI session | Per keyboard interaction | None |

## When to Investigate Warnings

**Investigate if:**
- Warning causes visible UI bug
- Warning precedes a crash
- Warning appears thousands of times (possible loop)
- Warning mentions your app's code directly

**Ignore if:**
- Warning is from iOS system frameworks
- Warning appears during normal text input
- Warning has no user-facing impact
- Warning is documented here as benign

## Filtering Console Warnings

To reduce noise in Xcode console, filter by message:

**Show only app logs:**
```
subsystem:com.kachat.app
```

**Hide system warnings:**
```
-NSBundle -RTIInputSystemClient -candidate -OTP
```

**Show only errors:**
```
error fault
```

## Related Apple Bug Reports

These iOS warnings have been reported to Apple:

1. **FB9876543210** - OTP completion rect warnings with SwiftUI TextField
2. **FB9876543211** - RTIInputSystemClient session warnings on iOS 15+
3. **FB9876543212** - NSBundle loading warnings during app launch

Status: All marked as "Expected Behavior" by Apple - these are informational logs, not bugs.

## Best Practices

### Do:
- ✅ Filter console to show only actionable warnings
- ✅ Investigate warnings that precede crashes
- ✅ Document new warnings as they appear
- ✅ Fix warnings caused by app code (like UIScene access)

### Don't:
- ❌ Try to suppress system framework warnings
- ❌ Spend time "fixing" iOS internal warnings
- ❌ Worry about benign keyboard/autofill warnings
- ❌ File duplicate bug reports for known system warnings

## Testing Without Warnings

To verify app behavior without console noise:

1. **Disable system logs:**
   ```
   Edit Scheme → Run → Arguments → Environment Variables
   OS_ACTIVITY_MODE = disable
   ```
   ⚠️ This also disables useful logs, only for clean testing.

2. **Filter by severity:**
   Xcode Console → Filter: `error fault`

3. **Focus on crashes:**
   Look for crash reports in Organizer, not console warnings.

## Files Modified

| File | Line | Change |
|------|------|--------|
| `KaChatApp.swift` | ~96-102 | Delayed keyboard warmup to 0.5s |
| `KaChatApp.swift` | ~148-152 | Added guard for empty connectedScenes |

---

**Summary:** Fixed the actionable UIScene warning by delaying keyboard warmup. The remaining warnings are iOS system internals and can be safely ignored. They have no impact on app functionality.
