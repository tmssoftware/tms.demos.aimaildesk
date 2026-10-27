# Getting the API keys for AI Mail Desk

Everything is optional: with **Demo** mails and *Offline keyword rules* the demo runs without any key. Each key
below switches on one more part of it.

| What you get | Service | What you need | Setting(s) on the server | Cost |
|---|---|---|---|---|
| AI triage + reply drafts + translations | OpenAI, Claude, Gemini, Mistral, ... (or Ollama) | 1 API key | `ai_service`, `ai_api_key`, `ai_model` | Pay per use (Gemini/Mistral have free tiers, Ollama is local and free) |
| The Assistant | Same list, tool calling only | The AI key above | Uses `ai_service` / `ai_api_key` | Same |
| Real Gmail mailbox + Google Calendar | Google Cloud | OAuth client ID + secret | `gmail_client_id`, `gmail_secret`, `callback_url` | Free |
| Real Outlook mailbox + Outlook Calendar | Microsoft Entra ID | App (client) ID + secret | `outlook_client_id`, `outlook_secret`, `callback_url` | Free |
| Urgent alerts on a phone | Pushover | API token + user key | `pushover_token`, `pushover_user`, `alerts_enabled` | Free 30-day trial, then a one-time app purchase |

All of them are entered on the dashboard's **Settings** page (then *Save settings*), or by an LLM with the
`update_setting` tool. The server stores them encrypted in `%APPDATA%\TMSGarageMailDesk`.

The OAuth callback URL is `http://127.0.0.1:8888` unless you change `callback_url`. Whatever it is, it must match
the redirect URI you register with Google and Microsoft **exactly** (scheme, `127.0.0.1` vs `localhost`, port, no
trailing slash).

---

## 1. AI service (triage, replies and translations)

Pick one. The dashboard's AI list shows every service `TTMSMCPCloudAI` supports; these are the common ones.

**OpenAI**
1. Sign in at <https://platform.openai.com>.
2. *Settings > Billing*: add a payment method and some credit (the API does not work on a ChatGPT subscription).
3. *API keys > Create new secret key*. Copy it now; it is shown only once (`sk-...`).

**Anthropic Claude**
1. Sign in at <https://console.anthropic.com> (Claude Console).
2. *Billing*: buy credits.
3. *API keys > Create key*. Copy it (`sk-ant-...`).

**Google Gemini**
1. Go to <https://aistudio.google.com/apikey> with a Google account.
2. *Create API key* (it creates or picks a Google Cloud project). The free tier is enough for the demo.

**Mistral**
1. Sign in at <https://console.mistral.ai>.
2. Choose a plan (the free *Experiment* plan works), then *API keys > Create new key*.

**Ollama (no key)**
Install Ollama from <https://ollama.com>, run `ollama pull <model>` (e.g. `llama3.1`), and pick Ollama on Settings.
It runs on the server machine; vision (photo attachments) needs a vision model.

Then on **Settings**: pick the service, paste the key, optionally set the model, *Save settings*.

**Translations** use this same service, key and model too, only when someone clicks *Translate* on a mail (or an
LLM calls `translate_mail`). Set the handlers' language on Settings (`target_language`: a name such as `English` or a
code such as `EN-GB`, default `EN-GB`).

**The Assistant** (the panel on the right of the dashboard) uses this same service and key, so pick a service with
tool calling (OpenAI, Claude, Gemini, Mistral). With the server on the same machine it reads the key from the server's
key store; otherwise the dashboard keeps an encrypted copy (`assistant.cfg`) of the key you save on Settings.

---

## 2. Gmail + Google Calendar (OAuth client)

1. Open <https://console.cloud.google.com> and create a project (e.g. *AI Mail Desk*).
2. *APIs & Services > Library*: enable the **Gmail API** and the **Google Calendar API**.
3. *Google Auth Platform* (OAuth consent screen):
   * *Branding*: app name and your support e-mail.
   * *Audience*: **External**, publishing status **Testing**, and under *Test users* add every Gmail address you
     will connect (e.g. the shared garage mailbox).
   * *Data access*: add the scopes the components ask for: `https://mail.google.com/`, `gmail.modify`,
     `gmail.compose`, `gmail.readonly`, `calendar`, `calendar.events`. (Listing them is optional in Testing mode,
     but it makes the consent screen clearer.)
4. *Clients > Create client*:
   * Application type: **Web application**.
   * *Authorized redirect URIs*: `http://127.0.0.1:8888` (your `callback_url`).
5. Copy the **Client ID** and **Client secret** into *Gmail client ID* / *secret* on Settings and save.
6. Click **Gmail** on the dashboard **on the server machine** (or `connect_mailbox` with `interactive: true`), sign
   in with a test user and accept. Google warns that the app is unverified: *Continue*.

Notes
* The Gmail scopes are *restricted*, so a public (non-Testing) app would need Google's security review. For a
  demo, stay in Testing mode with test users.
* In Testing mode Google expires the refresh token after **7 days**: after that, connect once more interactively.
* The first *Sync to calendar* asks for the calendar consent.

---

## 3. Outlook + Outlook Calendar (Microsoft Entra app registration)

1. Open <https://entra.microsoft.com> (or *Azure portal > Microsoft Entra ID*) > *App registrations > New
   registration*.
   * Name: *AI Mail Desk*.
   * Supported account types: **Accounts in any organizational directory and personal Microsoft accounts** (so both
     Microsoft 365 and outlook.com / hotmail mailboxes work). Use *single tenant* only for a company mailbox.
   * Redirect URI: platform **Web**, `http://127.0.0.1:8888` (your `callback_url`).
2. On the *Overview* page, copy the **Application (client) ID**.
3. *Certificates & secrets > Client secrets > New client secret*. Copy the **Value** (not the *Secret ID*); it is
   shown only once. Note the expiry date (at most 24 months) and renew it before then.
4. *API permissions > Add a permission > Microsoft Graph > Delegated permissions*, add:
   `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Calendars.Read.Shared`, `offline_access`, `User.Read`.
   In a Microsoft 365 tenant that blocks user consent, an admin clicks *Grant admin consent*.
5. Put the client ID and secret value in *Outlook client ID* / *secret* on Settings and save.
6. Click **Outlook** on the dashboard on the server machine and sign in with the mailbox account.

---

## 4. Pushover (urgent alerts)

1. Create an account at <https://pushover.net> **as / for the on-call mechanic** and install the Pushover app on
   their phone (free 30-day trial, then a one-time purchase per platform).
2. The **User Key** is on the dashboard of pushover.net after login: that is `pushover_user`.
3. *Your Applications > Create an Application/API Token*: name *AI Mail Desk*, type *Application*. The
   **API Token/Key** it shows is `pushover_token`.
4. On Settings, enter both and switch on alerts (`alerts_enabled`). A mail triaged as *Urgent* now pushes a message;
   test it with `notify_on_call` on any mail.

To alert several people, create a Pushover *Delivery Group* and use its group key as the user key.

---

## 5. The server's own token (no request needed)

The bearer token clients use for the MCP server is generated by `GarageMailMCP.exe` on its first start
(`[MCPServer] Token` in `settings.ini`). The dashboard on the same machine finds it by itself; give it to Claude
Code / Claude Desktop / n8n as described in `MCPServer\README.md`.

---

## Checklist

- [ ] AI service key (and Assistant key, may be the same)
- [ ] Google: project, Gmail API + Calendar API enabled, test users, Web client with redirect URI, ID + secret
- [ ] Microsoft: app registration with Web redirect URI, client ID, secret **value**, Graph delegated permissions
- [ ] Pushover: user key + application token, app installed on the phone
- [ ] Everything entered on Settings, *Save settings*, mailboxes connected once on the server machine

Keep the keys out of source control and screenshots; for a recorded demo, blur the Settings page or show only
`set` / `not set` via `get_settings`.
