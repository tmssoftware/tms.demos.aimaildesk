# AI Mail Desk MCP server

The dealership mail triage system itself, as an MCP server built with **TMS AI Studio**'s attribute-based server
(plain methods with `[TTMSMCPTool]` attributes, turned into a server by `TTMSMCPServerFactory.CreateFromObject`).
Mailboxes, calendars and alerts use the **TMS FNC Cloud Pack** (VCL flavour, so it runs as a console
app); the triage and the on-request translations use `TTMSMCPCloudAI`; the customer history is SQLite through FireDAC.

The server owns everything: the inbox, the spam list, the routing table, the settings, the work queues, the customer
history and the automation (`uTriageEngine.pas`). Every part of it is an MCP tool (`uMailTools.pas`), so an LLM can
run it **and maintain it remotely**: work the inbox, retry errors, review spam, edit the routing table, switch the AI
service or model, turn automation on. The **GarageMailDesk** app is a dashboard over the same tools: it shows what
the server does and controls it, and what an LLM changes shows up there within a second.

## Tools

**Looking** (read-only)

| Tool | What it does |
|---|---|
| `get_status` | Mailbox connections, AI engine, counts per department, urgent, errors, spam, running work, automation, last error. Start here. |
| `list_mails(status?, department?, priority?, text?)` | The inbox with the triage state of every mail |
| `get_mail(id)` | One mail (inbox or spam): body, triage result, reply draft, attachments, customer history, translation, workshop slot |
| `list_spam` | Mails flagged as spam, with the reason |
| `get_routing_table` | Departments, brands and the rules (department + brand -> handler; brand `*` = fallback) |
| `get_settings` | Every setting (secrets only show `set` / `not set`) and the available AI services |
| `get_log(since?, limit?)` | The server's activity log |
| `list_workshop` | Workshop appointments and whether they are in the calendar |
| `find_customer(email)` | Earlier contacts of a customer from the customer history |
| `get_dashboard_state(since_version?, log_since?)` | Used by the dashboard: everything when the version changed, plus new log lines |

**Working the inbox**

| Tool | What it does |
|---|---|
| `connect_mailbox(source, interactive?)` | Connect Gmail / Outlook with the saved login; `interactive: true` opens the login page in a browser on the server machine (first time) |
| `fetch_mails(source?, max?)` | Fetch new mails (`all`, `gmail`, `outlook`) or the 13 sample mails (`demo`) and wait for them |
| `run_triage(id?, wait?)` | Let the server's own AI service (or the offline rules) classify, write replies and flag spam: all new / failed mails, or one mail again |
| `triage_mail(id, department, brand, priority, summary, reply?, spam?)` | Record *your* classification instead; returns the routed handler |
| `reroute_mail(id, department, brand?)` | Move a mail to another department / brand; handler and signature follow |
| `update_reply(id, text)` | Replace the reply draft (keep `[SIGNATURE]` for the handler's signature) |
| `save_reply_drafts(id?)` | Save reply drafts in the Drafts folder of the mailbox; nothing is sent |
| `forward_mails(id?, confirm_send?)` | Forward to the handlers and file the originals in `Triage/<Department>`. Only sent when the `dry_run` setting is off **and** `confirm_send` is true |
| `archive_forwarded` | Remove the forwarded mails from the working inbox (they stay in the mailbox and the history) |
| `set_appointment(id, start)` | Set, move (`yyyy-mm-dd hh:nn`) or remove (empty) the workshop slot of a maintenance mail |
| `sync_calendar` | Put the new appointments in Google Calendar / Outlook Calendar |
| `notify_on_call(id, message?)` | Pushover message to the on-call mechanic |
| `translate_mail(id)` | Translation into the handler's language (`target_language`) by the AI service, only when asked for; the forward includes it |
| `mark_spam(id, reason?)`, `mark_not_spam(id)`, `delete_spam(id?)` | Spam review; deleted mailbox mails go to the mailbox's trash |

**Maintaining the system**

| Tool | What it does |
|---|---|
| `set_routing_rule(department, brand, handler_name, handler_email)` | Add or change a rule; triaged mails that are not forwarded yet are routed again |
| `delete_routing_rule(department, brand)` | Delete a rule |
| `replace_routing_table(rules)` | Replace the whole table (JSON array as text) |
| `reset_routing_table` | Restore the default table |
| `update_setting(name, value)` | `ai_service`, `ai_api_key`, `ai_model`, `max_mails`, `dry_run`, `auto_fetch_minutes`, `auto_triage`, `auto_drafts`, `alerts_enabled`, `pushover_token`, `pushover_user`, `target_language`, `gmail_client_id`, `gmail_secret`, `outlook_client_id`, `outlook_secret`, `callback_url` |

Two prompts walk a model through the work: `triage_inbox` (classify, route and prepare replies) and `health_check`
(connections, errors, spam, routing; fixes only after you agree). Three resources can be attached without a tool
call: `garage://inbox`, `garage://routing` and `garage://status`.

Tools that need a mailbox or an AI service for one mail (`save_reply_drafts(id)`, `forward_mails(id)`,
`run_triage(id)`, `fetch_mails`, `translate_mail`, ...) wait for the result. Without an id they queue the work and
return at once; follow it with `get_status` or `list_mails`.

## Automation and state

* The inbox and the spam list are saved in `inbox.json` and restored on the next start; work that was running
  (triage, forward) starts over.
* `auto_fetch_minutes` fetches from the connected mailboxes on a schedule, `auto_triage` triages new mails as soon
  as they (and their attachments) are in, and `auto_drafts` saves the reply draft right after the triage. Urgent
  mails alert the on-call mechanic when `alerts_enabled` is on. Forwarding is never automatic.

## Running it

```
GarageMailMCP.exe                   Streamable HTTP on port 8787 ([MCPServer] Port in settings.ini)
GarageMailMCP.exe --http 9000       the same, on another port
```

The server only speaks Streamable HTTP: start it once and point every client (the dashboard, Claude Code, Claude
Desktop, n8n, ...) at `http://<host>:8787/mcp`. Run one server per data folder: two servers would each keep their own
copy of the inbox.

Settings, OAuth tokens, `routing.json`, `inbox.json`, `history.db`, attachments and the encrypted API keys live in
`%APPDATA%\TMSGarageMailDesk`. Mailbox logins need a browser once, on the machine that runs the server
(`connect_mailbox` with `interactive: true`, or the *Gmail* / *Outlook* button of the dashboard on that machine);
after that the server reconnects with the saved tokens, also at startup. Without a mailbox, use `fetch_mails` with
`source: "demo"`; drafts and forwards are then simulated.

## HTTP and the bearer token

Every HTTP request needs `Authorization: Bearer <token>`. On first start the server creates a random token in
`[MCPServer] Token` in `settings.ini`; hand it to whoever (or whatever) may use the server. Without a valid token the
server answers `401` with a pointer to its OAuth protected-resource metadata
(`/.well-known/oauth-protected-resource/mcp`), which is how MCP clients discover where to get a token. To use your
identity provider (Entra ID, Google, Auth0, ...) instead of a shared token, validate the JWT in
`TGarageMailTools.ValidateToken` and list the provider in the transport's `AuthorizationServers`.

The token gives full control, including the settings and the routing table. The server listens on all interfaces:
open the port in the firewall only where it is needed, and for traffic outside your own network turn on the
transport's `UseSSL` (`CertFile` / `KeyFile`).

## Connecting clients

Claude Code:

```
claude mcp add --transport http garage http://localhost:8787/mcp --header "Authorization: Bearer <token>"
```

Claude Desktop: add the URL as a custom connector, or bridge the local server with `mcp-remote` in
`claude_desktop_config.json` (the token goes in an environment variable because Windows splits arguments on the space
after `Bearer`):

```json
{
  "mcpServers": {
    "ai-mail-desk": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:8787/mcp", "--header", "Authorization:${GARAGE_AUTH}"],
      "env": { "GARAGE_AUTH": "Bearer <token>" }
    }
  }
}
```

Start `GarageMailMCP.exe` before Claude Desktop; Claude Desktop and the dashboard then share the same running server.

n8n: the *MCP Client Tool* node with the URL and a *Bearer Auth* credential.

MCP Inspector: `npx @modelcontextprotocol/inspector`, transport *Streamable HTTP*, URL `http://localhost:8787/mcp`,
and the token as a Bearer token under *Authentication*.

Then ask for example *"Use the health_check prompt"*, *"Which urgent Audi mails came in, and who handles them?"* or
*"From now on Audi sales goes to Jan Smets, jan.smets@brightline-motors.be"*.

## Build

Open `GarageMailMCP.dproj` (it defines `GARAGE_VCL` and shares the units in the parent folder) and build.

## Notes

* Everything in the engine runs on the main thread, which pumps `CheckSynchronize` (`GarageMailMCP.dpr`): the cloud
  components and `TTMSMCPCloudAI` deliver their results there with `TThread.Queue`. Tools run on the transport's
  request threads and reach the engine with `TThread.Synchronize` (`OnMain` in `uMailTools.pas`); a tool that waits
  for a result sleeps on its own thread (`WaitUntil`), so other clients (the dashboard) keep being served.
* The dashboard calls the tools statelessly (protocol 2026-07-28: version and client capabilities in `_meta`, no
  session) and polls `get_dashboard_state`; this AI Studio version has no server-to-client push over stateless HTTP.
* `OnBeforeExecute` of the server cannot serve as a lock: in this AI Studio version the attribute server calls it
  once per parameter, inside its parameter loop, and not at all for tools without parameters.
* The prompts are registered with `Server.Prompts.RegisterPrompt` rather than `[TTMSMCPPrompt]`: in this AI Studio
  version the attribute server only invokes methods that also carry `[TTMSMCPTool]` (`GetAttributedMethod` in
  `TMS.MCP.Helpers.pas`), so attributed prompts return no messages.
* `TDateTime` tool parameters do not work in this version (an ISO date string is rejected as "expects a number"), so
  dates are strings (`yyyy-mm-dd hh:nn`).
