# TMS AI Mail Desk (FMX showcase demo)

A car dealership / garage ("Brightline Motors", fictional) receives customer mail in shared Gmail and Outlook
mailboxes. The system fetches the mails, lets an LLM classify them and write a reply, saves that reply as a draft
for a person to review, and forwards each mail to the right handler.

The whole system is an **MCP server** (`MCPServer\GarageMailMCP.exe`, see its README): the inbox, the routing
table, the settings, the work queues and every action live there, and every part of it is an MCP tool. An LLM
(Claude Code, Claude Desktop, n8n, ...) can run and maintain it remotely: triage mail, fix errors, review spam,
edit the routing table, change the AI service or switch on automation. **GarageMailDesk.exe** is the dashboard:
it shows what the server is doing and controls it through the same MCP tools, so what an LLM changes shows up in
the dashboard within a second, and the other way round.

The dashboard is itself an MCP client with an AI: its **Assistant** (the panel on the right) is a `TTMSMCPClient` (TMS AI Studio)
connected to the server. It discovers the server's tools and gives them to its built-in `TTMSMCPCloudAI`, so you
can ask it anything an external LLM could do ("which urgent Audi mails came in?", "retry the failed mails",
"Audi sales now goes to Jan Smets"), plus three tools of its own that steer the dashboard (`filter_inbox`,
`show_mail`, `show_page`).

```
 LLM (Claude, n8n, ...) --MCP--+
                               +--> GarageMailMCP.exe (engine + state) --> Gmail / Outlook / AI / Pushover
 GarageMailDesk.exe  --MCP---+    %APPDATA%\TMSGarageMailDesk: settings, tokens, routing, inbox, history
  (dashboard + Assistant:
   TTMSMCPClient + its own AI)
```

| Step | Product | Component |
|---|---|---|
| Fetch mail from Gmail / Outlook, save reply drafts, forward | TMS FNC Cloud Pack | `TTMSFNCCloudGoogleGmail`, `TTMSFNCCloudMicrosoftOutlookMail` |
| Classify (department, brand, priority, confidence, summary) and write a reply in the customer's language | TMS AI Studio | `TTMSMCPCloudAI` (OpenAI, Claude, Gemini, Mistral, Ollama, ...) |
| Inbox, conditional formatting, filtering, sorting, routing editor | TMS FNC UI Pack | `TTMSFNCDataGrid` |

Departments: Sales, Accessories, Maintenance, Finance, Second-hand (+ Reception for everything else).
The **Routing** page maps *department + brand* to a handler (brand `*` = fallback), so e.g. Audi sales
and Volkswagen sales go to different people.

## Download

Prebuilt Win32 binaries of both editions are on the
[Releases](https://github.com/tmssoftware/tms.demos.aimaildesk/releases) page: unzip and start the server
(`MCPServer\GarageMailMCP.exe` or `MailDeskServer.exe`), then the dashboard. To build from source, see below.
The configurable edition is in [`MailDesk\`](MailDesk/README.md); [API-KEYS.md](API-KEYS.md) explains how to get
the optional API keys.

## Running the demo

1. Build and start the server, `MCPServer\GarageMailMCP.dproj` (FNC Core, FNC Cloud Pack and AI Studio must be
   installed). It serves MCP on `http://localhost:8787/mcp` and creates its bearer token on the first start.
2. Build and start the dashboard, `GarageMailDesk.dproj` (FNC UI Pack). On the same machine it finds the server
   and its token by itself; for a server elsewhere, enter the URL and token on **Settings > Triage server**.
3. Click **Get mail**. With no mailbox connected this loads 13 multilingual sample mails (EN/NL/FR/DE).
4. On **Settings**, pick an AI service, enter its API key, and click **Save settings** (the settings are saved on
   the server). Without a key you can pick *Offline keyword rules*, a simple fallback (English template replies)
   that shows why the AI is better.
5. Click **Triage with AI**. Select a mail: the detail panel shows the **AI analysis** with the original message,
   and the **Reply draft** (editable, signed by the routed handler). To re-route a mail, drag its card on the
   **Board** or ask the Assistant.
6. Click *Save reply draft* to store the reply as a draft in the mailbox (or switch on *Save reply drafts* under
   Automation).
7. Click **Forward**. With **Dry run** on (the default, on Settings), nothing is sent and the mails are only marked.

The toolbar buttons are single MCP tool calls (`fetch_mails`, `run_triage`, `forward_mails`). The status line shows
the tool's note and then the server's own activity log, so the dashboard has no messages of its own to keep in sync.

The server keeps working without the dashboard: the inbox survives a restart (`inbox.json`), and with
*Automation* on (Settings, or the `update_setting` tool) it fetches on a schedule, triages new mails and saves
their reply drafts by itself. Forwarding is never automatic.

## Auto-reply drafts

The AI writes the reply in the customer's language, ending with a `[SIGNATURE]` placeholder that is replaced by
the signature of the handler the mail is routed to (so a manual re-route updates the signature too).

Drafts are **never sent**: they appear in the Drafts folder of the mailbox the mail came from, threaded as a
reply, for a person to review and send. Dry run only affects forwarding.

`uReplyDrafts.pas` uses the draft API of the Cloud Pack mail components (v1.4.0.0 and later):

* Gmail: `TTMSFNCCloudGoogleGmail.CreateReplyDraft`, which threads the draft via `ThreadId` and the
  `In-Reply-To` / `References` headers.
* Outlook: `TTMSFNCCloudMicrosoftOutlookMail.CreateReplyDraft` on the original message; Graph adds the quoted original.
* Demo mails go to the first connected mailbox as a new draft (`CreateReplyDraft` on Gmail, `CreateDraft` on
  Outlook); with no mailbox connected they are simulated.

Each mail keeps the id of its saved draft (`draft_id` in `inbox.json`). When an edited reply is saved again, the
existing draft is updated in place with `UpdateDraft` instead of adding a second draft to the mailbox:

* Gmail: `UpdateDraft` replaces the whole message, so recipient, subject, thread and the `In-Reply-To` /
  `References` headers are sent again with the new HTML body.
* Outlook: `UpdateDraft` patches subject, body and recipients of the draft. The new body includes its own quote of
  the original, as it replaces the quote Graph added when the reply draft was created.
* If the draft is gone (the person already sent or deleted it, HTTP 404), a new draft is created.

The required scopes (`gmail.compose`, `Mail.ReadWrite`) are already requested by the components.

## Real mailboxes

* Gmail: create an OAuth client in the Google Cloud console and enable the Gmail API.
* Outlook: register an app in Microsoft Entra ID with `Mail.ReadWrite` and `Mail.Send`.
* Add the callback URL (default `http://127.0.0.1:8888`) as a redirect URI in both.
* The first login opens in a browser **on the machine that runs the server** (*Connect* next to Gmail / Outlook on
  Settings, or the `connect_mailbox` tool with `interactive: true`); after that the server reconnects with the
  saved tokens. Once a mailbox is connected, *Get mail* fetches from it instead of loading the demo inbox.

When dry run is off, a mail is forwarded through the mailbox it came from (demo mails use the first connected
mailbox). The default handler addresses use the reserved `.example` domain, so replace them on the Routing page
before sending for real.

Settings, OAuth tokens, `routing.json`, the inbox (`inbox.json`), the customer history and the encrypted API keys
are stored by the server in `%APPDATA%\TMSGarageMailDesk`. The dashboard only stores where the server is (and the
Assistant's AI service), in `dashboard.ini` in the same folder.

## Design

Everything is laid out at design time: the main form (`uMain.fmx`) holds the icon sidebar, the toolbar and the
status line, and every page is a frame with its own `.fmx` (see *Files*). Rounded "card" panels, pill buttons
(`TRectangle` + `TLabel`, icons from the *Segoe MDL2 Assets* font, a design-time opacity animation on hover), KPI tiles, department filter chips, and a
master/detail inbox. Both grids are styled at design time as well (row height, horizontal lines only, header and
selection colours), as are the conditional formatting rules (the routing grid uses the same department badges and mutes the `*` fallback brand; text rules are wildcard patterns, so that rule matches `?`, exactly one character): department colours, priority, the confidence data bar,
status and reply state. Code only switches pages/chips/segments and sets runtime state.

### Board, workshop, alerts and report

| Feature | Component | How it works |
|---|---|---|
| **Handler board** (sidebar *Board*) | `TTMSFNCKanbanBoard` (UI Pack) | One column per department; every triaged mail is a card, with a red or orange mark for urgent or high priority. Dropping a card on another column re-routes the mail: the handler, the reply signature and the grid follow. |
| **Workshop** (sidebar *Workshop*) | `TTMSFNCPlanner` (UI Pack) | For maintenance requests the AI suggests a slot that matches the customer's wishes (offline: next working day 09:00); clashing slots move to the next free hour. Select an appointment and drag its handle to reschedule. |
| **Calendar sync** | `TTMSFNCCloudGoogleCalendar`, `TTMSFNCCloudMicrosoftOutlookCalendar` (Cloud Pack) | *Sync to calendar* adds the appointments to the calendar of the connected mailbox: Google Calendar for Gmail, Outlook Calendar for Outlook. It uses the same app registration (enable the Google Calendar API, or add `Calendars.ReadWrite`); the first sync asks for consent. |
| **Urgent alerts** | `TTMSFNCCloudPushOver` (Cloud Pack) | Every mail triaged as *Urgent* sends a push message to the on-call mechanic. Set the Pushover API token and user key on Settings; until then the alert is only logged. |
| **PDF report** | `TTMSFNCDataGridPDFIO` (UI Pack) | *PDF report* exports the inbox grid, with conditional formatting, to `Documents\GarageMailDesk-<date>.pdf`, always in the light colours. |

The board is styled at design time in `uBoardFrame.fmx` to match the app: a header in the department colour, rounded cards with an HTML layout and a red / orange bar for urgent / high priority, and columns that share the full width. The workshop planner (`uWorkshopFrame.fmx`) gets the same treatment: light day headers and time line, thin grid lines, a soft background outside working hours, and rounded appointments in the department colour with an accent bar.

### Attachments, customer history, translation and the Assistant

| Feature | Component | How it works |
|---|---|---|
| **Attachments** | Cloud Pack mail components, `TTMSMCPCloudAI.AddFile` | Photos and PDFs are downloaded when the mails are fetched (Gmail `GetAttachment`, Outlook `GetAttachments`) to `%APPDATA%\TMSGarageMailDesk\attachments`. They go to the AI with the mail, and the model describes them in the analysis (e.g. warning lights on a dashboard photo). Gmail forwards include them. Two demo mails carry an attachment (`DemoAttachments\`). |
| **Customer history** | FireDAC + SQLite (`history.db`) | Every triaged mail is stored. A new mail from a known address shows the earlier contact in the analysis, and the AI gets it in the prompt. A returning customer goes to the person who handled their last mail of the same department, as long as that person is still in the routing table. The database starts with three demo contacts: Pieter Jacobs' Audi test drive goes to Lukas Peeters, who sent him an earlier quote, instead of the Audi salesperson. |
| **Translation** | `TTMSMCPCloudAI` (the triage's AI service) | Only on request: the `translate_mail` tool (ask the Assistant, e.g. "translate the Dubois mail") has the AI service translate a mail into the handler's language (Settings, a language name or code, default `EN-GB`). The result shows in the AI analysis, below the original, and the forward includes it above the original. No extra key: it uses the triage's AI service, key and model. |
| **Assistant** | `TTMSFNCChat` (UI Pack), `TTMSMCPClient` (AI Studio) | The Assistant panel, always shown on the right, is a chat with an AI agent that uses the triage server's MCP tools: it can answer questions about the inbox and also act (triage, re-route, retry, spam, routing, settings). Its own tools filter the grid (a priority filter shows as a removable chip), select a mail or open a page. Tools that change or send things (forward, delete, routing, settings, mailbox login) ask for a yes first (`OnBeforeUseTool`). It uses the AI service and key of the Settings page (the service must support tool calling); the key comes from the server's key store when the server runs on the same machine, else from an encrypted copy (`assistant.cfg`) kept when the key is saved on Settings. The last six turns go along with every question, so follow-ups work. |

### Filing forwarded mail and the spam filter

| Feature | How it works |
|---|---|
| **Filing after forwarding** | Once a mail is really forwarded (dry run off), the original leaves the inbox of its mailbox and is filed per department: Gmail gets the label `Triage/<Department>` and loses the `INBOX` label; Outlook moves it to the folder `Triage` > `<Department>`. Labels and folders are created on first use. The next forward waits until the filing request answered. In dry run the status only says where it would be filed. |
| **Spam filter** | The AI returns `"spam"` and `"spam_reason"` with every classification; offline, a keyword score is used (two or more typical scam / cold-pitch phrases). Spam leaves the inbox and waits on the **Spam** page (count in the sidebar), with the reason and a preview. |
| **Review** | *Not spam* puts the mail back in the inbox as new; it is never flagged again. *Delete* / *Delete all* move mailbox mails to the trash of that mailbox (Gmail `trash`, Outlook *Deleted Items*), so a mistake can be undone there; demo mails are just removed. |

The Cloud Pack has no API for labels, folders, moving or trash, so `uMailboxFiling.pas` calls the Gmail and Graph REST endpoints through the component's own request pipeline and OAuth token. The required scopes (`gmail.modify`, `Mail.ReadWrite`) are already requested. The demo inbox contains two spam mails.

### Search and filters

The search box next to the department chips filters the inbox as you type. It matches sender, subject,
brand, handler, department or source, case-insensitively, and combines with the selected department chip.
Both use the DataGrid's own filter engine: the search adds one *contains* rule per column joined with OR,
followed by an AND rule for the department. The filter is re-applied when mails are added, triaged or
re-routed.

### Look

All colours are designed in the `.fmx` files; code only sets colours that depend on the data (department badges,
priority marks, the selected chip and segment, a connected mailbox). The standard FMX controls (memos, edits, combo
boxes, switch, scrollbars) use Embarcadero's redistributable *Win10Modern* style, stored in `LightStyle.res` and
loaded into a `TStyleBook` at startup (`AppStyleBook` in `uTheme.pas`). While loading, the square bitmap background
of edits, memos and combo boxes is replaced by a rounded rectangle in the app's colours, with a blue outline while
it has focus.

All pages use the same building blocks: rounded cards, pill buttons, department colours from one palette (grid
badges, board column headers, workshop appointments), slate input fields and blue for selection, focus and the
primary action. The kanban board, the planner and the chat are styled at design time rather than with FNC's stock styles, so they
follow the same palette.
The card is always the only border: grids, chat, board and planner sit inside a rounded card with a 12 px inset and draw no frame or background of their own (the chat and the board columns are table views around an inner tree view, so `FlattenTreeView` turns that frame off too). The board has no column tracks; each column is a coloured dot, name and count above its cards, with a thin divider between the columns (plain rectangles laid over the board in `kbBoardResized`). `FlattenTreeView` also turns off `FillEmptySpaces`: the header corner above a collapsed scrollbar is otherwise filled with the default white column fill, which shows as a dot above every column.
Scrollbars (grids, memos, lists) are patched in the same style book: no arrow buttons, an invisible track and a thin rounded thumb that turns blue on hover.

## Files

Dashboard (`GarageMailDesk.dproj`):

* `uMain.pas/.fmx`: the main window: sidebar, toolbar, status line; hosts the pages
* `uDashboard.pas`: the dashboard's copy of the server's state (mails, spam, routing, settings, status), with an
  event per change, and `RunTool` to call an MCP tool
* `uEngineClient.pas`: stateless MCP client over HTTP: polls `get_dashboard_state`, runs commands in the background
* `uTheme.pas`: department colours, helpers for the FNC controls, the FMX style book
* One frame (`.pas` + `.fmx`) per page:
  * `uInboxFrame`: mail grid, department chips, search, KPI tiles, mail detail (analysis + reply draft), PDF report
  * `uAssistantFrame`: the Assistant panel on the inbox page (`TTMSMCPClient` and its own tools)
  * `uBoardFrame`: handler board (`TTMSFNCKanbanBoard`)
  * `uWorkshopFrame`: workshop appointments (`TTMSFNCPlanner`)
  * `uRoutingFrame`: routing table editor
  * `uSettingsFrame`: server and dashboard settings, mailbox login, dry run
  * `uSpamFrame`: spam review
* `LightStyle.res`: the Win10Modern FMX style as an RCDATA resource

Server (`MCPServer/GarageMailMCP.dproj`, see its README):

* `MCPServer/uTriageEngine.pas`: the engine: inbox, spam, routing, settings, queues, customer history, automation
* `MCPServer/uMailTools.pas`: the MCP tools, prompts and resources over the engine
* `uTriageAI.pas`: system prompt, JSON response parsing, offline keyword fallback
* `uReplyDrafts.pas`: template replies, Gmail / Outlook reply drafts (Cloud Pack draft API)
* `uMailboxFiling.pas`: filing forwarded mail in department labels / folders, spam to the trash
* `uMailSources.pas`: shared settings folder, FNC mail item to `TTriageMail` mapping, forward message
* `uDemoMails.pas`: sample inbox
* `DemoAttachments/`: the dashboard photo and invoice PDF of the demo mails

Shared:

* `uTriageModel.pas`: mail model and helpers (HTML to text, address parsing, reply signature)
* `uRouting.pas`: routing table (JSON load/save, department + brand resolution)
* `uMailJSON.pas`: a mail as JSON, for the tools, `inbox.json` and the dashboard

Note: with many units in the form's `uses` clause, the Delphi compiler can no longer resolve the anonymous-method
overloads of `TThread.ForceQueue` and `TMessageManager.SubscribeToMessage`, so the code passes method pointers
(`QueuedPageRefresh`, ...).
