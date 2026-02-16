# Device Token Error Handling

## Overview

The kasia-indexer push notification system tracks invalid device tokens and automatically deregisters them after repeated failures to prevent wasting resources on invalid tokens.

## Error Types

### 1. Unregistered
**APNs Reason:** `"Unregistered"`
**Meaning:** Device explicitly unregistered from APNs
**Handling:** Immediately deregister from database (no retry)

### 2. Invalid Token
**APNs Reasons:**
- `"BadDeviceToken"` - Malformed or invalid token format
- `"DeviceTokenNotForTopic"` - Token is valid but not for this app's bundle ID

**Meaning:** The device token cannot be used for push notifications
**Handling:**
- Increment failure counter for this token
- After 10 consecutive failures, deregister from database
- Counter resets on successful delivery

### 3. Other Rejections
**APNs Reasons:** Any other rejection reason (e.g., "PayloadTooLarge", "TooManyRequests")
**Meaning:** Temporary or non-token-related error
**Handling:** Log warning but don't increment failure counter

## Implementation

**File:** `indexer/src/push.rs`

### Error Mapping (Lines ~677-681)

```rust
match reason.as_deref() {
    Some("Unregistered") => Err(ApnsError::Unregistered),
    Some("BadDeviceToken") | Some("DeviceTokenNotForTopic") => Err(ApnsError::InvalidToken),
    _ => Err(ApnsError::Rejected { status, reason }),
}
```

### Error Handling (Lines ~409-447)

```rust
match apns.send(&token, &payload).await {
    Ok(()) => {
        info!("[Push] Delivered to ...{}", token_short);
        // Reset counter on success
        self.invalid_token_counts.remove(&token);
    }
    Err(ApnsError::Unregistered) => {
        warn!("[Push] Unregistered token ...{}, removing", token_short);
        // Immediate deregistration
        registry.unregister(token_clone).await.ok();
        self.invalid_token_counts.remove(&token);
    }
    Err(ApnsError::InvalidToken) => {
        let count = self.invalid_token_counts.entry(token.clone()).or_insert(0);
        *count = count.saturating_add(1);
        warn!(
            "[Push] Invalid token ...{} ({} consecutive)",
            token_short,
            count
        );
        // Deregister after 10 consecutive failures
        if *count >= 10 {
            warn!(
                "[Push] Invalid token threshold reached for ...{}, removing",
                token_short
            );
            registry.unregister(token_clone).await.ok();
            self.invalid_token_counts.remove(&token);
        }
    }
    Err(err) => {
        // Other errors don't increment counter
        warn!("[Push] Failed to deliver to ...{}: {err}", token_short);
    }
}
```

## DeviceTokenNotForTopic Error

### What It Means

The `DeviceTokenNotForTopic` error occurs when:
- The device token is valid and properly formatted
- But the token was issued for a **different app** (different bundle ID)
- Or the APNs certificate/key doesn't match the token's app

### Common Causes

1. **Development vs Production Mismatch:**
   - Token generated with sandbox environment
   - Trying to send with production certificate (or vice versa)

2. **Bundle ID Mismatch:**
   - Token generated for `com.example.app`
   - Sending with certificate for `com.example.otherapp`

3. **App Reinstall/Transfer:**
   - User reinstalled app with different bundle ID
   - Old token still in database

4. **Certificate Misconfiguration:**
   - Wrong APNs certificate loaded
   - Certificate expired or revoked

### Why We Deregister After 10 Failures

**Before the fix:** These tokens would remain in the database forever, causing:
- Wasted APNs API calls on every push event
- Unnecessary database lookups
- Cluttered device registry

**After the fix:** Track consecutive failures and deregister after 10 attempts:
- If truly invalid, token is removed after reasonable retry period
- If temporary misconfiguration, admin has time to fix before removal
- Reduces database bloat from stale tokens

### Example Log Sequence

**First failure:**
```
[Push] Invalid token ...a1b2c3d4 (1 consecutive)
```

**Subsequent failures:**
```
[Push] Invalid token ...a1b2c3d4 (2 consecutive)
[Push] Invalid token ...a1b2c3d4 (3 consecutive)
...
[Push] Invalid token ...a1b2c3d4 (9 consecutive)
```

**Deregistration:**
```
[Push] Invalid token ...a1b2c3d4 (10 consecutive)
[Push] Invalid token threshold reached for ...a1b2c3d4, removing
```

**If delivery succeeds before threshold:**
```
[Push] Invalid token ...a1b2c3d4 (5 consecutive)
[Push] Delivered to ...a1b2c3d4  ← Counter reset to 0
```

## Testing

### Simulate DeviceTokenNotForTopic Error

1. **Use wrong APNs environment:**
   ```bash
   # If using sandbox tokens, switch to production
   APNS_ENVIRONMENT=production
   ```

2. **Use wrong bundle ID in APNs certificate:**
   - Generate token with `com.kachat.app`
   - Send with certificate for `com.example.other`

3. **Monitor logs:**
   ```bash
   docker logs -f kasia-indexer | grep "Invalid token"
   ```

### Verify Deregistration

After 10 consecutive failures:

```bash
# Check device is removed from database
curl http://localhost:8080/v1/push/devices | jq '.[] | select(.device_token | endswith("a1b2c3d4"))'
# Should return empty
```

## Database Impact

### Before Fix
- Stale tokens accumulate forever
- Each push event queries stale tokens
- Wasted APNs API calls

### After Fix
- Stale tokens automatically removed after 10 failures
- Database stays clean
- APNs quota preserved

### Monitoring

Track deregistration rate:
```sql
-- If you add deregistration logging
SELECT COUNT(*) FROM deregistration_log
WHERE reason = 'invalid_token_threshold'
AND timestamp > NOW() - INTERVAL '1 day';
```

## Related Files

| File | Purpose |
|------|---------|
| `indexer/src/push.rs` | Main push notification logic |
| `indexer-db/src/push.rs` | Device registration database schema |
| `indexer-actors/src/push.rs` | Push event types |

## Configuration

No additional configuration needed. The threshold is hardcoded:

```rust
const INVALID_TOKEN_THRESHOLD: u8 = 10;
```

To change the threshold, modify line 431 in `push.rs`.

## Summary

The fix ensures that `DeviceTokenNotForTopic` errors are treated the same as `BadDeviceToken` errors:
- Both increment the invalid token counter
- Both trigger deregistration after 10 consecutive failures
- Both reset the counter on successful delivery

This prevents the accumulation of invalid tokens in the database and reduces wasted APNs API calls.
