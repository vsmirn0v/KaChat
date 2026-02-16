# macOS Notification Limitation (Mac Catalyst)

## Problem

On macOS, push notifications show "New message" instead of the decrypted message content, while on iOS everything works correctly.

## Root Cause

**Notification Service Extensions do NOT run on Mac Catalyst apps.**

- The main app has `SUPPORTS_MACCATALYST = YES`, allowing it to run on macOS
- The `KaChatNotificationService` extension also has Catalyst support enabled
- **However, Apple does not invoke notification service extensions for Catalyst apps on macOS**

This is a platform limitation, not a configuration issue.

## Why iOS Works but macOS Doesn't

| Platform | Behavior |
|----------|----------|
| **iOS** | Notification received → `NotificationService.didReceive()` called → Message decrypted → "Hello world" shown |
| **macOS (Catalyst)** | Notification received → Extension NOT invoked → Raw notification shown → "New message" shown |

## Technical Details

### Extension Configuration (Correct)

```bash
# Main app
SUPPORTS_MACCATALYST = YES ✓

# Notification Service
SUPPORTS_MACCATALYST = YES ✓
SUPPORTED_PLATFORMS = iphoneos iphonesimulator ✓
```

### What Happens on macOS

1. Push notification arrives from APNs
2. macOS notification center receives it
3. **Extension is skipped** (Catalyst limitation)
4. Notification is shown with original content:
   - Title: Sender address (last 8 chars)
   - Body: "New message" (from APNs payload)

### What Should Happen (iOS)

1. Push notification arrives from APNs
2. iOS notification service calls `didReceive()`
3. Extension:
   - Loads private key from keychain
   - Decrypts encrypted payload
   - Replaces body with actual message text
4. Notification shown with decrypted content:
   - Title: Contact name (from shared contacts)
   - Body: "Hello world" (decrypted message)

## Workarounds

### Option 1: Accept the Limitation (Recommended for Now)

**Pros:**
- No code changes required
- macOS users still get notified (just not the content preview)
- Opening the app shows the decrypted message

**Cons:**
- macOS notification previews show "New message" instead of actual content
- Less convenient for macOS users

### Option 2: Native macOS App Target

Create a separate native macOS app (not Catalyst) with proper notification service extension support.

**Steps:**
1. Add new macOS app target in Xcode
2. Add macOS notification service extension target
3. Share code between iOS and macOS targets
4. Separate bundle IDs: `com.kachat.app.mac` and `com.kachat.app.ios`
5. Maintain two separate App Store listings

**Pros:**
- Full notification service extension support on macOS
- Better native macOS experience
- Can use macOS-specific features

**Cons:**
- More complex project structure
- Need to maintain two separate apps
- Users need to download different apps for iOS/macOS
- Two separate development/distribution workflows

### Option 3: Alternative Notification Strategy

Use a different approach for macOS notifications:

**Foreground Notifications:**
- When app is running in foreground, handle notifications directly
- No need for service extension
- Can decrypt immediately in main app

**Background Polling:**
- Periodically check for new messages in background
- Show local notifications with decrypted content
- Downside: Delays compared to push

**Cons:**
- More complex logic
- Background polling drains battery
- Still no solution for when app is completely closed

### Option 4: Silent Notifications + Local Notifications

1. Send silent push notification (no alert)
2. App wakes up in background
3. App fetches and decrypts message
4. App schedules local notification with decrypted content

**Implementation:**
```swift
// APNs payload
{
  "aps": {
    "content-available": 1  // Silent notification
  },
  "tx_id": "...",
  "sender": "..."
}
```

**In AppDelegate:**
```swift
func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    // Fetch and decrypt message
    // Schedule local notification with content
}
```

**Pros:**
- Works on Catalyst
- Can show decrypted content

**Cons:**
- App must be running (even if in background)
- macOS might not wake app reliably
- Adds complexity
- Delayed notification delivery

## Apple's Official Stance

From Apple's documentation on Mac Catalyst:

> "Notification Service Extensions are not supported on Mac Catalyst. If your iOS app uses a notification service extension, that extension will not run when the app runs on macOS."

This is explicitly documented as a known limitation.

## Recommended Approach

For now, **accept the limitation** and document it:

1. Update user documentation to note that macOS shows generic notification previews
2. Emphasize that message content is still encrypted and secure
3. Full message content is available when opening the app
4. Consider native macOS app in the future if demand is high

## Testing

### Verify on iOS
```bash
# Send test push notification
curl -X POST "https://api.development.push.apple.com/3/device/$DEVICE_TOKEN" \
  -H "apns-topic: com.kachat.app" \
  -H "authorization: bearer $JWT_TOKEN" \
  -H "apns-push-type: alert" \
  -d '{
    "aps": {
      "alert": {
        "title": "kaspa:test",
        "body": "New message"
      },
      "mutable-content": 1
    },
    "tx_id": "test123",
    "sender": "kaspa:test...",
    "type": "contextual",
    "payload": "636970685f6d73673a313a636f6d6d3a..."
  }'
```

**Expected:**
- Notification shows decrypted message content ✓

### Verify on macOS (Catalyst)
Same test notification

**Expected:**
- Notification shows "New message" (extension not invoked)
- This is the platform limitation, not a bug

## Related Files

| File | Description |
|------|-------------|
| `KaChatNotificationService/NotificationService.swift` | Notification service extension (iOS only) |
| `KaChatNotificationService/Info.plist` | Extension configuration |
| `KaChatNotificationService/KaChatNotificationService.entitlements` | Extension entitlements |
| `PUSH_NOTIFICATIONS.md` | Push notification architecture doc |

## References

- [Apple: Mac Catalyst Documentation](https://developer.apple.com/documentation/uikit/mac_catalyst)
- [Apple: Modifying Content in Newly Delivered Notifications](https://developer.apple.com/documentation/usernotifications/modifying_content_in_newly_delivered_notifications)
- [WWDC: What's New in Mac Catalyst](https://developer.apple.com/wwdc/)

## Status

**Current:** Known limitation, documented
**Future:** Consider native macOS app if user demand warrants the development effort

---

**Last Updated:** 2026-02-02
