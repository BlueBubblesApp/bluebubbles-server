# Google Contacts Sync

BlueBubbles can pull your Google Contacts (names, phone numbers, emails, and
avatars) into the server's contact database and serve them to connected clients.

There are **two modes**, selected by a toggle on the **Contacts** page of the
server app:

| Mode | Toggle | What it does | Setup required |
|------|--------|--------------|----------------|
| **One‑time import** | OFF (default) | Imports your Google Contacts once, using BlueBubbles' built‑in Google sign‑in. | **None** — just click *Continue with Google*. |
| **Background sync** | ON | Keeps contacts in sync automatically on an interval (adds/updates/deletes). | Your **own** Google OAuth client (this guide). |

> **Why your own client for background sync?** Background sync needs *offline*
> access (a long‑lived **refresh token**). Google only issues refresh tokens
> through the authorization‑code flow, which requires a **client secret**. The
> built‑in BlueBubbles client is a public/secret‑less client, so it can't grant
> offline access — hence the one‑time import is the most it can do. Using your
> own OAuth client gives you a secret you control, which unlocks background sync.

---

## Setting up your own Google OAuth client (background sync)

This takes ~5 minutes in the [Google Cloud Console](https://console.cloud.google.com).

### 1. Create or select a project
- Top bar → project picker → **New Project** (or reuse an existing one).

### 2. Enable the People API
- **APIs & Services → Library** → search **"People API"** → **Enable**.

### 3. Configure the OAuth consent screen
- **APIs & Services → OAuth consent screen**.
- **User type: External** → Create.
- Fill in the required fields (app name, your email).
- **Scopes:** add `https://www.googleapis.com/auth/contacts.readonly`.
- **Test users:** add the Google account you'll sign in with.
- ⚠️ **Important — publishing status & the 7‑day token expiry:**
  While the app is in **"Testing"**, Google **expires refresh tokens after 7
  days**, which will silently break background sync once a week. To get a
  non‑expiring token, set the publishing status to **"In production"**
  (**OAuth consent screen → Publish app**). For personal use you can ignore the
  "unverified app" warning — `contacts.readonly` is a sensitive scope, but
  unverified production apps still work for a small number of users; you'll just
  see a one‑time warning during sign‑in. (Verification is only needed to remove
  the warning / support many users.)

### 4. Create the OAuth client ID
- **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
- **Application type: Desktop app** (recommended — it gets a client secret and
  automatically allows the loopback redirect, so there's nothing else to
  configure).
- Click **Create**, then copy the **Client ID** and **Client secret**.

> **Using a "Web application" client instead?** It also works, but you must add
> this exact **Authorized redirect URI**:
> `http://localhost:8641/oauth/callback`
> Desktop‑app clients don't need this — loopback redirects are allowed by default.

### 5. Connect it in BlueBubbles
1. Open the **BlueBubbles Server** app → **Contacts** page.
2. Turn **ON** the toggle **"Use my own Google OAuth client (enables automatic
   background sync)"**.
3. Under **Step 1**, paste your **Client ID** and **Client secret** → **Save**.
4. Under **Step 2**, click **Continue with Google**, sign in with your **test‑user**
   account, and grant access.
5. On success the status shows **Synced** and the background controls appear:
   - **Keep contacts synced in the background** — enable/disable the scheduler.
   - **Sync every N minutes** — how often to sync (default 360 = 6 hours).
   - **Sync Now** — run a sync immediately.
   - **Disconnect** — revoke and clear the stored token, and stop syncing.

---

## How it works

- The first sync is a **full** sync; subsequent syncs are **incremental** using
  the People API *sync token*, so only changes (including deletions) are applied.
- Contacts are matched by their Google `resourceName` (stored as `externalId`).
  Existing contacts from a previous one‑time import are matched by name and have
  their `externalId` back‑filled, so they aren't duplicated.
- Google's generic silhouette avatars are skipped (only real photos are saved).
- The scheduler runs on the configured interval and also does a catch‑up sync on
  server startup if it's overdue.

## Configuration keys

Stored in the server config (set automatically via the UI; listed for reference):

| Key | Meaning |
|-----|---------|
| `google_contacts_use_own_client` | `0` = one‑time mode, `1` = background mode |
| `google_oauth_client_id` | Your OAuth client ID (background mode) |
| `google_oauth_client_secret` | Your OAuth client secret (background mode) |
| `google_contacts_sync_enabled` | Whether the background scheduler is on |
| `google_contacts_sync_interval` | Minutes between syncs (default 360) |
| `google_contacts_refresh_token` | Stored offline token (managed automatically) |
| `google_contacts_sync_token` | People API incremental sync token (managed automatically) |
| `google_contacts_last_sync` | Timestamp of the last successful sync |

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| **"client_secret is missing"** | You're connecting with the built‑in client (one‑time toggle OFF) but the server tried the offline flow, **or** the secret wasn't saved. Make sure the toggle is ON and you saved a valid Client **ID + secret**. |
| **"access_denied" / "app is being tested"** | Add your Google account as a **test user** on the OAuth consent screen. |
| **Sync worked, then stopped after ~a week** | Your app is still in **"Testing"** — refresh tokens expire after 7 days. Set the consent screen to **"In production"**, then **Disconnect** and **Continue with Google** again. |
| **"invalid_grant" in the logs** | The refresh token was revoked/expired. Reconnect via **Continue with Google**. |
| **People API errors** | Make sure the **People API** is enabled in the same project as your OAuth client. |

## Privacy & security

- The scope requested is **read‑only** (`contacts.readonly`).
- Your client secret and refresh token are stored in the server's local config
  database (the same place other server secrets live). Use **Disconnect** to
  revoke and remove the token at any time.
