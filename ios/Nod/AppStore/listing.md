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

Pick one. Each fits the 30-char limit. Top recommendation first. Plain words a
first-time visitor understands; no tech terms.

```
A private place to talk.           (24)  ← recommended
Say what's on your mind.           (24)
Talk it out. It stays private.     (30)
Private AI chat. On-device.        (27)
```

---

## Promotional Text (170 char max)

Editable post-launch without re-submission. Use for "what's new" or campaigns.

```
Say what's on your mind. Just Nod listens, replies gently, and keeps everything on your iPhone. No account, no ads, and it works offline.
```
(137 characters)

---

## Description (4,000 char max)

Plain language for someone who has never heard of on-device AI: what it's
like to use, what stays private, what you need. No model names, frameworks or
storage details (those live on GitHub and in the review notes below). The
in-app helpline card is deliberately not mentioned, to keep the listing clear
of mental-health framing (see Positioning above).

```
A private place to say what's on your mind.

Just Nod is a calm AI you can talk to about anything: a long day, something you can't stop thinking about, or whatever's on your mind. It listens, replies in a warm, unhurried way, and asks the kind of question that helps you keep going. Everything stays on your iPhone.

— NO SIGN-UP
No account, no email, no password. Open the app and start typing. Not sure where to begin? Tap a suggestion like "Something's on my mind."

— STAYS ON YOUR PHONE
Your conversation is saved on your iPhone and answered by AI that runs on your iPhone. It isn't sent to us or anyone else. No ads, no tracking.

— WORKS OFFLINE
On a plane, in a tunnel, with the Wi-Fi off. Nod doesn't need the internet to reply.

— REMEMBERS WHAT MATTERS
As you talk, Nod keeps short notes about what's been going on, so you don't have to repeat yourself. You can read every note, forget any of them, or start fresh and clear everything.

— OR JUST TALK
Tap the mic and say it out loud. Your words appear as text you can check before sending, and your voice is turned into text on your iPhone.

— YOUR WAY
Choose shorter or longer replies, and whether Nod mostly listens, reflects back, or offers a little perspective. Add a line about yourself and Nod keeps it in mind.

— LOCKED WITH FACE ID
Turn on Face ID and only you can open it. Not a partner glancing at your phone, not a friend passing it around.

— LIGHT AND DARK
A warm, simple design that follows your iPhone's appearance, or pick light or dark yourself.

— OPEN SOURCE
All of Nod's code is public, so anyone can check it works the way we say.

WHAT YOU NEED
iOS 26 or later. On iPhones with Apple Intelligence, Nod works right away. Other iPhones with at least 6 GB of memory (such as iPhone 13 Pro, iPhone 14 and newer) download Nod's own AI once, about 2–3 GB over Wi-Fi.

Just Nod is for everyday conversation and doesn't give professional advice. Made by Speculative Dynamics.
```

(About 2,000 characters, well under the 4,000 limit. Framing stays "private AI you can talk to", with no mental-health, wellness or therapy language.)

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

**China availability:** the `gpt` keyword triggers China's Deep Synthesis
Technology (DST) rules under Guideline 5 (Legal) — apps referencing
ChatGPT/OpenAI in metadata need a MIIT permit to ship in China. We keep
`gpt` for global SEO and deselect mainland China from Availability in App
Store Connect. Re-enable later by removing `gpt` here AND in the App
Store Connect Keywords field, or by securing the MIIT permit.

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
Just Nod is a private on-device AI chat app. All inference runs locally on the user's iPhone: Apple Intelligence (FoundationModels) by default, or, on iPhones without Apple Intelligence or by choice in advanced settings, an open-weights model (Qwen 3.5 4B or Qwen 3.5 2B) via MLX Swift.

KEY POINTS FOR REVIEW:

1. No accounts. No servers receiving conversations. No analytics, no third-party SDKs.

2. The only outbound network call is the one-time download of model weights from Cloudflare R2 (HTTPS), on iPhones without Apple Intelligence or when a user picks a downloadable model in advanced settings.

3. No user-generated content is ever shared with other users. There are no social features, no inter-user communication, no public posting. All conversations stay private to the device.

4. This is a general-purpose AI chat app — not a mental health, wellness, therapy, or medical app. No medical claims are made anywhere in the app or listing. As a safety measure, if a message clearly signals risk of self-harm, the app shows a local crisis helpline number; it gives no advice or treatment.

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
