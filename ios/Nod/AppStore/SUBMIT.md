# Just Nod — App Store Submission Walkthrough

Concrete step-by-step. Everything is already prepared:

- Archive: `~/Library/Developer/Xcode/Archives/2026-04-25/Nod 1.0.0 (22).xcarchive`
- Listing copy: [`listing.md`](./listing.md)
- Screenshots: [`screenshots/`](./screenshots/) — 8 PNGs, exact 1290×2796
- Privacy / Support / Terms URLs: live on usenod.app

The whole submission takes ~30–45 minutes once you sit down with it.

---

## Step 1 — Upload the build

1. Open **Xcode → Window → Organizer** (⌘⌥⇧O)
2. Left sidebar: **Archives** tab → select **Nod**
3. You should see **Nod 1.0.0 (22)** at the top, dated 25 Apr 2026
   - If it's not there, click anywhere in the panel and press ⌘R to refresh, or quit/reopen Xcode
4. Click **Distribute App** (top right)
5. Choose **App Store Connect** → **Next**
6. Choose **Upload** → **Next**
7. Distribution options — leave defaults:
   - ☑ Upload your app's symbols
   - ☑ Manage Version and Build Number (Xcode auto-bumps if needed)
   - **Next**
8. Re-signing — leave **Automatically manage signing** → **Next**
   (Xcode will fetch the Apple Distribution cert and re-sign the archive.)
9. Review the summary → **Upload**
10. Wait 2–5 minutes. You'll see "**Upload Successful**" — click **Done**

The build now goes into App Store Connect's processing queue. It usually appears in the **TestFlight → Builds** section within 5–15 minutes with a yellow "Processing" badge, then turns green when ready.

---

## Step 2 — Create the App Store Connect record

If the app already exists in App Store Connect (from earlier TestFlight uploads), skip to Step 3.

1. Open **<https://appstoreconnect.apple.com>** → **My Apps** → **+** → **New App**
2. Fill in:
   - **Platforms**: iOS
   - **Name**: `Just Nod`
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: `app.usenod.nod` (pick from dropdown — should appear because the build was uploaded)
   - **SKU**: `nod-ios-001` (any unique string, never shown publicly)
   - **User Access**: Full Access
3. **Create**

---

## Step 3 — Paste the App Information (one-time, applies across versions)

In the left sidebar of the new app, click **App Information**:

| Field | Value |
|---|---|
| Subtitle | `Private AI chat. On-device.` |
| Privacy Policy URL | `https://usenod.app/privacy/` |
| Category — Primary | **Productivity** |
| Category — Secondary | **Lifestyle** (optional) |
| Content Rights | ☑ "Does not contain, show, or access third-party content" |

**Save** (top right).

---

## Step 4 — Pricing and Availability

Left sidebar → **Pricing and Availability**:

- **Price**: Free (USD 0.00)
- **Availability**: All countries and regions **except China mainland**
  (the `gpt` keyword triggers China's Deep Synthesis Technology rules
  under Guideline 5 — see Keywords notes in `listing.md`. Re-enable by
  either removing `gpt` from keywords or securing a MIIT permit.)
- **App Distribution Methods**: Public on the App Store

**To deselect China mainland:**
1. **Pricing and Availability** → **Edit** next to the country list
2. Uncheck **China mainland** (it's listed alphabetically under "C")
3. **Done** → **Save**

**Save**.

---

## Step 5 — Set up the 1.0 version page

Left sidebar → under **iOS App** → **1.0 Prepare for Submission**.

### Screenshots (6.7" iPhone — required)

Drag all 8 PNGs from `ios/Nod/AppStore/screenshots/` into the upload area, in this order:

1. `01-listening.png`
2. `02-offline.png`
3. `03-engines.png`
4. `04-memory.png`
5. `05-voice.png`
6. `06-personal.png`
7. `07-private.png`
8. `08-proof.png`

App Store Connect auto-uses 6.7" screenshots for all newer iPhone sizes. You don't need to upload separate 6.5" or 5.5" sets unless you want to.

### Promotional Text (170 char)

```
A small AI chat app that runs entirely on your iPhone. Talk to it about anything. No accounts, no servers, no tracking. Your phone, your words, no one else.
```

### Description (paste from `listing.md`)

Open `listing.md`, copy the block under **## Description**, paste in.

### Keywords (100 char)

```
ai,chat,assistant,private,offline,on-device,llm,gpt,conversation,journal,companion,local,opensource
```

### Support URL

```
https://usenod.app/support/
```

### Marketing URL (optional)

```
https://usenod.app/
```

### Version

```
1.0.0
```

### Copyright

```
2026 Speculative Dynamics Private Limited
```

---

## Step 6 — App Review Information

Scroll down on the same page:

### Sign-In Required

☐ Unchecked. Nod has no accounts.

### Contact Information

- **First name**: Anoop
- **Last name**: Thiparala
- **Phone**: (your number, country code first)
- **Email**: hello@usenod.app

### Notes (paste from `listing.md`)

Open `listing.md`, copy the block under **## App Review Information**, paste in.

### Attachment

Optional. Skip unless reviewer requests later.

---

## Step 7 — Version Release

Scroll down further:

- ☑ **Manually release this version**
   (Recommended for first launch — gives you control to coordinate the public moment.)

OR

- ☑ **Automatically release this version after App Review approval**
   (Use if you want zero-touch publish.)

---

## Step 8 — Age Rating

Left sidebar → **Age Rating** → **Edit**:

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Sexual Content or Nudity | None |
| Profanity or Crude Humor | None |
| Alcohol, Tobacco, or Drug Use | None |
| Mature/Suggestive Themes | None |
| Simulated Gambling | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | **None** |
| Unrestricted Web Access | No |
| Gambling and Contests | No |
| User Generated Content | No |

Result: **4+**.

**Done**.

---

## Step 9 — Privacy Questionnaire (App Privacy)

Left sidebar → **App Privacy** → **Get Started**.

### "Do you or your third-party partners collect data from this app?"

→ **No, we do not collect data from this app.**

That's it. The whole questionnaire ends. App Store Connect will show "Data Not Collected" on the listing.

(If asked about Background Assets / model downloads: weights are static binary content from your own infrastructure, not user data — they don't need to be declared.)

---

## Step 10 — Link the build and Submit

Back on the **1.0 Prepare for Submission** page:

1. Scroll to **Build** section → click **+ Add Build**
2. Select the **1.0.0 (22)** build that finished processing → **Done**
3. Top right: **Add for Review** (button label varies)
4. App Store Connect runs a final check, surfaces any missing fields
5. If it shows **Submit for Review** → click it
6. Confirm Export Compliance:
   - **Does your app use encryption?** → **Yes**
   - **Is your app exempt under...?** → **Yes** (uses only iOS standard encryption: HTTPS for the model download, iOS file encryption for the local DB. No custom crypto. Qualifies for the standard exemption.)
7. **Submit**

Status flips to **Waiting for Review**.

---

## Timeline

- **Waiting for Review**: usually 24–48 hours
- **In Review**: usually under 24 hours
- **Approved** → release immediately if you chose auto, or click **Release this version** when ready

If rejected, the rejection note will be in the **App Review** tab. Common first-time issues to watch:
- Reviewer can't reach the AI — make sure Apple Intelligence works on the device they test on (newer Macs with Apple Silicon, iPhone simulators in iOS 26)
- Privacy URL not loading — verify usenod.app/privacy/ in a browser
- Screenshots flagged for inaccurate content — ours are accurate (real UI), no risk

---

## After approval

1. **Release** (if you chose manual)
2. Save the App Store URL — App Store Connect shows it once live
3. Add the App Store badge to `website/index.html` hero
4. Tweet, post, etc.
5. Bump `ios/project.yml` to `1.0.1` / build `23` so the next archive doesn't conflict

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| Build doesn't appear in Organizer | `open ~/Library/Developer/Xcode/Archives/2026-04-25/` and double-click the archive |
| Upload fails with signing error | In Xcode preferences → Accounts → Download Manual Profiles |
| App Store Connect can't find the build after 30 min | Check email — Apple sometimes sends "ITMS-9000" rejections directly |
| Screenshots rejected for wrong dimensions | They're already exact 1290×2796 — should not happen |
| Reviewer asks for demo account | Reply: "No account required. Open the app and type any message." |
| Reviewer asks how to test offline | Reply: "Enable Airplane Mode before opening the app for the first time." |

---

## Reference

- Listing copy: [`listing.md`](./listing.md)
- Screenshots: [`screenshots/`](./screenshots/)
- App Store Connect: <https://appstoreconnect.apple.com>
- Xcode Organizer shortcut: ⌘⌥⇧O
