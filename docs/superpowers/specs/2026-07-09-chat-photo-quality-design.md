# Chat Photo Quality Controls Design

## Purpose

AVIF chat photos now fit the current 15 KB target budget, roughly half the previous 31 KB image size. That is useful for fees, but users should be able to trade lower fees for higher image quality when a specific photo needs it.

This feature adds both:

- A global default photo quality setting.
- A per-photo preview control before sending.

The message protocol stays unchanged. The sender still uploads an inline image payload, preferring AVIF and falling back to JPEG where needed.

## Quality Model

Photo quality is a stepped preset, not a free continuous byte slider. The slider UI moves between named stops so behavior is predictable, localizable, and easy to test.

Presets:

| Preset | Target encoded size | Intent |
| --- | ---: | --- |
| Data Saver | 10 KB | Lowest fee, acceptable quick sharing |
| Balanced | 15 KB | Current default behavior |
| High | 31 KB | Close to the previous pre-AVIF image size |
| Best | 50 KB | Higher visual quality when fee is less important |

The encoded output is a target budget, not a guaranteed exact file size. `ImagePrep` should continue binary-searching encoder quality and shrinking dimensions when needed. If even the smallest fallback output exceeds the selected budget, it may still send the best achievable final attempt, matching current behavior.

## Settings UX

In `SettingsView`, the Chats section gains a "Photo quality" row.

The control is a stepped slider bound to a new `AppSettings` value. It shows the selected preset name and target size, for example:

`Photo quality    Balanced · ~15 KB`

The default for migrated users is `Balanced`, preserving current behavior. Changing the setting affects newly attached photos only; it does not mutate a photo that is already pending in a chat composer.

## Chat Preview UX

When the user attaches, pastes, drops, or shares an image into a one-to-one chat, the pending photo composer row expands from the current compact row into a preview control:

- Thumbnail preview.
- Title: `Photo quality`.
- Current preset text, for example `High · ~31 KB`.
- Stepped slider with the same preset stops as Settings.
- Trash button to cancel the pending photo.

The per-photo slider starts from the global default when the image is attached. Moving it affects only that pending image. After the pending photo is sent or cancelled, the next photo starts from the global default again.

The row must stay compact enough for the composer. The thumbnail remains small, and the slider uses a single horizontal row rather than opening a separate screen.

## Fee Estimate Behavior

Pending-photo fee estimation uses the selected preset target size instead of the fixed `ImagePrep.defaultChatTargetBytes`.

If "Estimate fees while composing" is enabled:

- Attaching an image schedules a fee estimate using the selected default quality.
- Moving the pending-photo slider schedules a new estimate using the new target size.
- Updates should be debounced or coalesced so dragging the slider does not spam network calls.

If fee estimation is disabled, the slider still updates the selected quality label, but no fee request is made.

## Encoding Flow

`ImagePrep.prepareForChatMessage` gains an overload or parameter that accepts the selected quality preset or target byte count.

Flow:

1. Downscale to the existing chat max dimension.
2. Try AVIF with the selected target byte budget.
3. If AVIF cannot be produced, fall back to JPEG with the same selected target byte budget.
4. Return `PreparedChatImage` with the correct filename and MIME type.

Existing decode compatibility remains unchanged. JPEG and WebP messages from other clients still display. AVIF remains the preferred upload format for new KaChat chat image messages.

## Data Model

Add a Codable quality preset enum, for example `ChatPhotoQualityPreset`, with raw values stable enough for persisted settings.

Add `chatPhotoQualityPreset` to `AppSettings`.

Migration:

- Missing value decodes as `.balanced`.
- Encoding writes the selected value.
- `AppSettings.default` uses `.balanced`.

The per-photo pending selection can stay as `@State` in `ChatDetailView`; it does not need persistence.

## Tests

Focused tests should cover:

- Quality preset target-byte mapping.
- `AppSettings` default and migration to `.balanced` when old settings do not contain the new field.
- `ImagePrep.prepareForChatMessage` using a supplied target budget.
- Existing AVIF preference and JPEG fallback behavior remains available.
- Pending-photo fee estimate uses the selected target byte budget.

Build verification should include the existing iOS build and Mac Catalyst build because the image paste/drop/send flow is used on desktop too.

## Non-Goals

- No receiver-side message format changes.
- No KNS avatar/banner upload changes.
- No per-contact quality setting.
- No continuous arbitrary byte input.
