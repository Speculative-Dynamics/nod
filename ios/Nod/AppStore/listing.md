# Just Nod — App Store Listing

> Positioning: a **private AI chat app**, not a mental-health or wellness
> app. The brand voice can stay quiet and contemplative (it's the brand);
> the framing avoids any medical/wellness language that triggers Apple's
> medical-app review (Guideline 1.4.1) or the healthcare-fitness category.

---

## App Name (30 char max)

```
Just Nod
```
(8 characters)

---

## Subtitle (30 char max)

Pick one. Each is under 30 chars. Top recommendation first.

```
Private AI chat. On-device.        (28) ← recommended
A small AI you can talk to.        (27)
On-device AI chat. No servers.     (29)
Talk to an AI. Stays on phone.     (29)
Your private AI conversation.      (29)
```

---

## Promotional Text (170 char max)

Editable post-launch without re-submission. Use for "what's new" or campaigns.

```
A small AI chat app that runs entirely on your iPhone. Talk to it about anything. No accounts, no servers, no tracking. Your phone, your words, no one else.
```
(157 characters)

---

## Description (4,000 char max)

```
A private AI chat app for your iPhone.

Just Nod is a small on-device AI you can talk to. Open the app, type or speak, and have a real conversation. Whatever you talk about stays on your phone.

Every word stays on your iPhone. There are no servers receiving your conversations, no accounts to create, no analytics, no ads, no third-party SDKs. Nod has no backend. There's nothing to leak, nothing to delete, no API key to revoke.

— OPEN AND TYPE

No onboarding, no setup, no sign-in. Open the app and start. The replies are warm and unhurried — Nod is built to be a calm conversation partner, not a tool that rushes to answer.

— RUNS WHEN YOU CAN'T CONNECT

Apple Intelligence runs the moment you install. The full conversation happens on the same chip that renders this text. No network required. On a plane, in a tunnel, on a trail with one bar — Nod still works.

— FOUR ON-DEVICE ENGINES

Apple's own foundation model is the default, so Nod works the second you open it. Prefer open weights? Switch in settings to Qwen 3 Instruct, Qwen 3.5 4B, or Gemma 4 E2B via MLX Swift. The weights download once over Wi-Fi, then run on your phone forever.

— REMEMBERS WHAT MATTERS

After each conversation, Nod picks up the details that come up — the people you mention, what you're working on, recurring topics. Browse them in the sidebar. Swipe any one away. Tap "Start fresh" to wipe the whole thing. No profile builds up in a data center somewhere, because there is no data center.

— OR JUST TALK

Tap the mic and speak. A warm orange glow hugs the edge of the screen while Nod listens. It commits when you pause. Transcription runs entirely on-device using iOS 26's SpeechAnalyzer — what you say never leaves your phone, not even for speech-to-text.

— MAKE IT YOURS

Two quiet pickers and a free-form field shape how Nod talks to you. Shorter or deeper, more direct or more curious. Add a line about yourself and Nod tucks it into every response.

— KEEP IT YOURS

Turn on Require Face ID and the whole app sits behind biometric auth. Nobody else gets in — not a partner glancing at your phone, not a friend passing it around.

— OPEN SOURCE

Nod is MIT-licensed. Every line of Swift, every system prompt, every database migration is on GitHub. If "trust us" bothers you, verify us.

REQUIREMENTS

Requires iPhone with Apple Intelligence support — iOS 26.0 or later. Works instantly on Apple's on-device model. If you switch to an open-weights engine in settings, Nod downloads the selected model once (2–3 GB, Wi-Fi by default).

Just Nod is a chat app for everyday conversation, not professional advice. Made by Speculative Dynamics. Open source on GitHub.
```

(About 2,500 characters — well under the 4,000 limit. Headline framing is "private AI chat", not "mental health" or "wellness". Mental-health/therapy/treatment language removed entirely.)

---

## Keywords (100 char max, comma-separated, NO spaces after commas)

App Store keyword field strips spaces — pack tightly. Reframed for "AI chat" instead of "mental wellness".

```
ai,chat,assistant,private,offline,on-device,llm,gpt,conversation,journal,companion,local,opensource
```
(99 characters)

Notes on choices:
- `ai`, `chat`, `assistant` — direct category match for what Nod is
- `private`, `offline`, `on-device`, `local` — the differentiators
- `llm`, `gpt` — captures users searching for ChatGPT-alternatives
- `conversation`, `companion` — atmospheric terms
- `journal` — adjacent category, high search volume, neutral (not medical)
- `opensource` — the verifiability angle

**Removed** (would push toward medical-app review): `mental`, `mindfulness`, `therapy`, `wellness`, `mood`, `reflection`, `quiet`, `venting`.

---

## URLs

- **Privacy Policy URL:** `https://usenod.app/privacy/` ✓
- **Marketing URL:** `https://usenod.app/` ✓
- **Support URL:** `https://usenod.app/support/` (created — see `website/support/index.html`)

---

## Categories

- **Primary:** Productivity (`public.app-category.productivity`)
- **Secondary:** Lifestyle

Why Productivity over Health & Fitness:
- ChatGPT, Claude, and other AI chat apps live here
- Avoids Apple's medical-app review (Guideline 1.4.1)
- Higher discovery for "AI chat" / "AI assistant" searches
- Reframes Nod as a tool, not a therapy adjunct

Already added to `ios/Nod/Info.plist`:
```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>
```

---

## Age Rating Questionnaire — recommended answers

Expect **4+** rating with the chat-app framing (no longer 12+):

- Frequent/Intense Mature/Suggestive Themes → None
- Frequent/Intense Profanity or Crude Humor → None
- Medical/Treatment Information → **None** (chat app, no medical claims)
- Unrestricted Web Access → No
- Gambling and Contests → No
- User-Generated Content shared between users → No (private to device)

Result: **4+** — broadest possible audience.

---

## App Review Information (notes to Apple's reviewer)

```
Just Nod is a private on-device AI chat app. All inference runs locally on the user's iPhone using Apple Intelligence (default) or one of three optional open-weights engines (Qwen 3, Qwen 3.5, Gemma 4) via MLX Swift.

KEY POINTS FOR REVIEW:

1. No accounts. No servers receiving conversations. No analytics, no third-party SDKs.

2. The only outbound network call is the one-time download of model weights from Cloudflare R2 (HTTPS) when a user opts to switch from Apple Intelligence to an open-weights engine.

3. No user-generated content is ever shared with other users. There are no social features, no inter-user communication, no public posting. All conversations stay private to the device.

4. This is a general-purpose AI chat app — not a mental health, wellness, therapy, or medical app. No medical claims are made anywhere in the app, listing, or marketing materials.

5. Source code is fully open: https://github.com/Speculative-Dynamics/nod (MIT license).

6. To test: open the app, type any message, observe a response. To verify on-device inference, enable Airplane Mode before the first message — it will still respond.
```

---

## Final pre-submission checklist

- [x] App Store category set in Info.plist (Productivity)
- [x] Version bumped to 1.0.0 (build 22) in `ios/project.yml`
- [x] Support page created at `website/support/`
- [x] Mental-health / wellness language stripped from listing
- [x] App Group `group.app.usenod.nod` registered in developer portal
- [ ] All 8 screenshots uploaded at 1290×2796
- [ ] Listing copy entered in App Store Connect (use sections above)
- [ ] Re-generate Xcode project after `project.yml` change: `cd ios && xcodegen generate`
