{ TMS AI Mail Desk - MCP server
  The whole triage system as MCP tools: an LLM (Claude Code, Claude Desktop,
  n8n, a TMS AI Studio TTMSMCPClient, ...) can run it, check on it and
  maintain it, from reading the inbox to editing the routing table and the
  settings. The GarageMailDesk app is a dashboard over the same tools.

  The tools are plain methods turned into an MCP server by
  TTMSMCPServerFactory (TMS AI Studio) through the [TTMSMCP...] attributes.
  Each tool runs its engine work on the main thread (OnMain), where the
  engine and the cloud components live. Tools that wait for a mailbox or an
  AI service wait on the request thread (WaitUntil), so the main thread keeps
  delivering results and other clients (the dashboard) keep working. }

unit uMailTools;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  TMS.MCP.Attributes, TMS.MCP.Prompts, TMS.MCP.Auth,
  uTriageModel, uTriageEngine;

type
  TGarageMailTools = class(TPersistent)
  private
    FEngine: TTriageEngine;
    FToken: string;
    function OnMain(const AFunc: TFunc<string>): string;
    function WaitUntil(const ACondition: TFunc<Boolean>; ATimeoutSec: Integer): Boolean;
    function MailResult(AID: Integer): string;
    function DashboardState(ASinceVersion, ALogSince: Int64): string;
  public
    constructor Create(AEngine: TTriageEngine);

    { --- Looking --- }

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_status')]
    [TTMSMCPDescription('Overview of the triage system: mailbox connections, AI engine, counts per department, ' +
      'urgent mails, errors, spam, running work (queues) and automation. Start here.')]
    function GetStatus: string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('list_mails')]
    [TTMSMCPDescription('The inbox with the triage state of every mail. All filters are optional and combine.')]
    function ListMails(
      [TTMSMCPName('status')][TTMSMCPDescription('new, queued, analyzing, triaged, forwarding, forwarded, dry_run or error')][TTMSMCPOptional] const AStatus: string;
      [TTMSMCPName('department')][TTMSMCPDescription('sales, accessories, maintenance, finance, secondhand or other')][TTMSMCPOptional] const ADepartment: string;
      [TTMSMCPName('priority')][TTMSMCPDescription('low, normal, high or urgent')][TTMSMCPOptional] const APriority: string;
      [TTMSMCPName('text')][TTMSMCPDescription('Text in sender, subject, brand or handler')][TTMSMCPOptional] const AText: string): string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_mail')]
    [TTMSMCPDescription('One mail (inbox or spam) with its full body, triage result, reply draft, attachments, ' +
      'customer history, translation and workshop slot.')]
    function GetMail([TTMSMCPName('id')] AID: Integer): string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('list_spam')]
    [TTMSMCPDescription('Mails flagged as spam, with the reason. They wait for review: mark_not_spam or delete_spam.')]
    function ListSpam: string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_routing_table')]
    [TTMSMCPDescription('Departments, car brands and the routing rules (department + brand -> handler). ' +
      'Brand "*" is the fallback for a department.')]
    function GetRoutingTable: string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_settings')]
    [TTMSMCPDescription('All settings with their current value (secrets only show "set" / "not set") and the ' +
      'available AI services. Change one with update_setting.')]
    function GetSettings: string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_log')]
    [TTMSMCPDescription('The activity log of the server: what was fetched, triaged, saved, sent and what failed.')]
    function GetLog(
      [TTMSMCPName('since')][TTMSMCPDescription('Only entries after this seq number')][TTMSMCPOptional] ASince: Integer;
      [TTMSMCPName('limit')][TTMSMCPDescription('Maximum entries, default 100')][TTMSMCPOptional] ALimit: Integer): string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('list_workshop')]
    [TTMSMCPDescription('Workshop appointments of maintenance mails, and whether they are in the calendar yet, ' +
      'plus the bookings that were already in the workshop planning (existing_booking).')]
    function ListWorkshop: string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('find_customer')]
    [TTMSMCPDescription('Earlier contacts of a customer from the customer history: department, handler and summary.')]
    function FindCustomer([TTMSMCPName('email')] const AEmail: string): string;

    [TTMSMCPTool]
    [TTMSMCPReadOnly]
    [TTMSMCPName('get_dashboard_state')]
    [TTMSMCPDescription('Used by the GarageMailDesk dashboard app to follow the server. Returns everything ' +
      '(inbox, spam, routing, settings, status) when the version changed, plus the new log entries.')]
    function GetDashboardState(
      [TTMSMCPName('since_version')][TTMSMCPOptional] ASinceVersion: Integer;
      [TTMSMCPName('log_since')][TTMSMCPOptional] ALogSince: Integer): string;

    { --- Mailboxes --- }

    [TTMSMCPTool]
    [TTMSMCPOpenworld]
    [TTMSMCPName('connect_mailbox')]
    [TTMSMCPDescription('Connect Gmail or Outlook with the saved login. The first time, set interactive=true: the ' +
      'login page then opens in a browser on the machine that runs this server, and someone there has to sign in. ' +
      'Needs gmail_client_id / gmail_secret or outlook_client_id (update_setting).')]
    function ConnectMailbox(
      [TTMSMCPName('source')][TTMSMCPDescription('gmail or outlook')] const ASource: string;
      [TTMSMCPName('interactive')][TTMSMCPOptional] AInteractive: Boolean): string;

    [TTMSMCPTool]
    [TTMSMCPName('fetch_mails')]
    [TTMSMCPDescription('Fetch new mails from the connected mailboxes into the inbox and wait for them. ' +
      'source: "all" (default), "gmail", "outlook" or "demo" (13 multilingual sample mails, no mailbox needed).')]
    function FetchMails(
      [TTMSMCPName('source')][TTMSMCPOptional] const ASource: string;
      [TTMSMCPName('max')][TTMSMCPDescription('Maximum mails per mailbox, default the max_mails setting')][TTMSMCPOptional] AMax: Integer): string;

    { --- Triage --- }

    [TTMSMCPTool]
    [TTMSMCPName('run_triage')]
    [TTMSMCPDescription('Let the server''s own AI service (setting ai_service, or the offline keyword rules) ' +
      'classify mails, write the reply drafts and flag spam. Without id: every new mail and every mail with an ' +
      'error. With id: that one mail again. Set wait=true to wait for the result (otherwise follow get_status).')]
    function RunTriage(
      [TTMSMCPName('id')][TTMSMCPOptional] AID: Integer;
      [TTMSMCPName('wait')][TTMSMCPOptional] AWait: Boolean): string;

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('triage_mail')]
    [TTMSMCPDescription('Record YOUR classification of a mail instead of the server''s AI. The handler is resolved ' +
      'from the routing table (a returning customer keeps their earlier handler) and returned. Urgent mails alert ' +
      'the on-call mechanic when alerts are on.')]
    function TriageMail(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('department')][TTMSMCPDescription('sales, accessories, maintenance, finance, secondhand or other')] const ADepartment: string;
      [TTMSMCPName('brand')][TTMSMCPDescription('One of the brands from get_routing_table, or Other')] const ABrand: string;
      [TTMSMCPName('priority')][TTMSMCPDescription('low, normal, high or urgent (broken down, safety issue, legal threat)')] const APriority: string;
      [TTMSMCPName('summary')][TTMSMCPDescription('One short sentence in English for the handler')] const ASummary: string;
      [TTMSMCPName('reply')][TTMSMCPDescription('Draft reply to the customer in the customer''s language. ' +
        'End with the line [SIGNATURE]; it is replaced by the handler''s signature. Omit for a template reply.')][TTMSMCPOptional] const AReply: string;
      [TTMSMCPName('spam')][TTMSMCPDescription('true for spam, phishing, scams and cold sales pitches: the mail goes ' +
        'to the spam list instead (summary = the reason)')][TTMSMCPOptional] ASpam: Boolean): string;

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('reroute_mail')]
    [TTMSMCPDescription('Move a mail to another department (and brand): the handler and the reply signature follow. ' +
      'Also triages a mail that was not triaged yet, with a template reply.')]
    function RerouteMail(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('department')] const ADepartment: string;
      [TTMSMCPName('brand')][TTMSMCPOptional] const ABrand: string): string;

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('update_reply')]
    [TTMSMCPDescription('Replace the reply draft of a triaged mail. Keep the [SIGNATURE] line to get the handler''s ' +
      'signature. Save it to the mailbox afterwards with save_reply_drafts.')]
    function UpdateReply(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('text')] const AText: string): string;

    { --- Drafts and forwarding --- }

    [TTMSMCPTool]
    [TTMSMCPName('save_reply_drafts')]
    [TTMSMCPDescription('Save reply drafts in the Drafts folder of the mailbox the mail came from (a threaded ' +
      'reply). Nothing is sent: a person reviews and sends them. With id: that mail (and wait for it); without: ' +
      'every triaged mail whose draft is not saved yet.')]
    function SaveReplyDrafts([TTMSMCPName('id')][TTMSMCPOptional] AID: Integer): string;

    [TTMSMCPTool]
    [TTMSMCPOpenworld]
    [TTMSMCPName('forward_mails')]
    [TTMSMCPDescription('Forward triaged mails to their handler with the triage result on top, then file the ' +
      'original in Triage/<Department>. Mails are ONLY sent when the dry_run setting is off AND confirm_send is ' +
      'true; otherwise it is a dry run. Only send when the user asked for it. With id: that mail (and wait); ' +
      'without: every triaged mail.')]
    function ForwardMails(
      [TTMSMCPName('id')][TTMSMCPOptional] AID: Integer;
      [TTMSMCPName('confirm_send')][TTMSMCPOptional] AConfirmSend: Boolean): string;

    [TTMSMCPTool]
    [TTMSMCPName('archive_forwarded')]
    [TTMSMCPDescription('Remove the mails that were really forwarded from the working inbox. They stay in the ' +
      'mailbox (filed per department) and in the customer history.')]
    function ArchiveForwarded: string;

    { --- Workshop, alerts, translation --- }

    [TTMSMCPTool]
    [TTMSMCPDestructive]
    [TTMSMCPName('cancel_booking')]
    [TTMSMCPDescription('Cancel a booking that was already in the workshop planning (existing_booking in ' +
      'list_workshop), e.g. when the customer cancels it. Its hour becomes free.')]
    function CancelBooking(
      [TTMSMCPName('start')][TTMSMCPDescription('Start of the booking, yyyy-mm-dd hh:nn, local time')] const AStart: string): string;

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('set_appointment')]
    [TTMSMCPDescription('Set or move the workshop slot of a triaged maintenance mail (one hour, weekdays 08:00-17:00). ' +
      'A slot that is taken or outside those hours moves to the next free hour. An empty start removes the appointment. Use sync_calendar to put it in the calendar.')]
    function SetAppointment(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('start')][TTMSMCPDescription('yyyy-mm-dd hh:nn, local time; empty to remove')] const AStart: string): string;

    [TTMSMCPTool]
    [TTMSMCPOpenworld]
    [TTMSMCPName('sync_calendar')]
    [TTMSMCPDescription('Add the workshop appointments that are not in the calendar yet to the calendar of the ' +
      'connected mailbox (Google Calendar or Outlook). The first time this asks for consent in a browser on the server machine.')]
    function SyncCalendar: string;

    [TTMSMCPTool]
    [TTMSMCPOpenworld]
    [TTMSMCPName('notify_on_call')]
    [TTMSMCPDescription('Send a push message (Pushover) about a mail to the on-call mechanic, e.g. for a breakdown. ' +
      'Simulated when alerts are not set up.')]
    function NotifyOnCall(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('message')][TTMSMCPDescription('Text for the mechanic; default: the triage summary')][TTMSMCPOptional] const AMessage: string): string;

    [TTMSMCPTool]
    [TTMSMCPName('translate_mail')]
    [TTMSMCPDescription('Translate a mail into the handler''s language (setting target_language) with the AI ' +
      'service (ai_service). Only runs when called, never during triage. The forward then includes the translation.')]
    function TranslateMail([TTMSMCPName('id')] AID: Integer): string;

    { --- Spam --- }

    [TTMSMCPTool]
    [TTMSMCPName('mark_spam')]
    [TTMSMCPDescription('Move a mail from the inbox to the spam list.')]
    function MarkSpam(
      [TTMSMCPName('id')] AID: Integer;
      [TTMSMCPName('reason')][TTMSMCPOptional] const AReason: string): string;

    [TTMSMCPTool]
    [TTMSMCPName('mark_not_spam')]
    [TTMSMCPDescription('Put a mail from the spam list back in the inbox as a new mail. It is never flagged again.')]
    function MarkNotSpam([TTMSMCPName('id')] AID: Integer): string;

    [TTMSMCPTool]
    [TTMSMCPDestructive]
    [TTMSMCPName('delete_spam')]
    [TTMSMCPDescription('Delete spam: mailbox mails go to the trash of their mailbox (recoverable there), demo mails ' +
      'are removed. With id: that mail; without: the whole spam list. Ask the user before deleting everything.')]
    function DeleteSpam([TTMSMCPName('id')][TTMSMCPOptional] AID: Integer): string;

    { --- Maintenance: routing and settings --- }

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('set_routing_rule')]
    [TTMSMCPDescription('Add or change the rule for a department + brand (brand "*" = fallback for the department). ' +
      'Triaged mails that are not forwarded yet are routed again.')]
    function SetRoutingRule(
      [TTMSMCPName('department')] const ADepartment: string;
      [TTMSMCPName('brand')][TTMSMCPDescription('Brand name, or * for every other brand')] const ABrand: string;
      [TTMSMCPName('handler_name')] const AName: string;
      [TTMSMCPName('handler_email')] const AEmail: string): string;

    [TTMSMCPTool]
    [TTMSMCPDestructive]
    [TTMSMCPName('delete_routing_rule')]
    [TTMSMCPDescription('Delete the rule for a department + brand. Mails then fall back to the "*" rule of the ' +
      'department, or to reception.')]
    function DeleteRoutingRule(
      [TTMSMCPName('department')] const ADepartment: string;
      [TTMSMCPName('brand')] const ABrand: string): string;

    [TTMSMCPTool]
    [TTMSMCPDestructive]
    [TTMSMCPName('replace_routing_table')]
    [TTMSMCPDescription('Replace the whole routing table. rules is a JSON array as text: ' +
      '[{"department":"sales","brand":"Audi","name":"...","email":"..."}, ...].')]
    function ReplaceRoutingTable([TTMSMCPName('rules')] const ARules: string): string;

    [TTMSMCPTool]
    [TTMSMCPDestructive]
    [TTMSMCPName('reset_routing_table')]
    [TTMSMCPDescription('Restore the default (demo) routing table.')]
    function ResetRoutingTable: string;

    [TTMSMCPTool]
    [TTMSMCPIdempotent]
    [TTMSMCPName('update_setting')]
    [TTMSMCPDescription('Change one setting; get_settings lists them. ai_service (offline or a service name), ' +
      'ai_api_key and ai_model (for the selected service), max_mails, dry_run, auto_fetch_minutes (0 = off), ' +
      'auto_triage, auto_drafts, alerts_enabled, pushover_token, pushover_user, target_language,' +
      'gmail_client_id, gmail_secret, outlook_client_id, outlook_secret, callback_url.')]
    function UpdateSetting(
      [TTMSMCPName('name')] const AName: string;
      [TTMSMCPName('value')][TTMSMCPDescription('Booleans as true / false')] const AValue: string): string;

    // MCP prompts and resources, registered in GarageMailMCP.dpr. ([TTMSMCPPrompt] is not
    // used: the attribute server only invokes methods that also carry [TTMSMCPTool].)
    function TriageInboxPrompt: TTMSMCPPromptMessages;
    function HealthCheckPrompt: TTMSMCPPromptMessages;
    function InboxResource: string;
    function RoutingResource: string;
    function StatusResource: string;
    // HTTP transport: accepts the team token from settings.ini
    procedure ValidateToken(Sender: TObject; const AToken, AResourceURI: string;
      var AValidation: TTMSMCPAccessTokenValidation);
    property Token: string read FToken write FToken;
  end;

implementation

uses
  System.Diagnostics, System.StrUtils, System.Math, uMailJSON, uRouting;

function JSONText(AValue: TJSONValue): string;
begin
  // Takes ownership of AValue
  try
    Result := AValue.ToJSON;
  finally
    AValue.Free;
  end;
end;

function SourceFromName(const AName: string): TMailSource;
begin
  if SameText(AName.Trim, 'gmail') then
    Result := msGmail
  else if SameText(AName.Trim, 'outlook') then
    Result := msOutlook
  else
    raise Exception.Create('source must be gmail or outlook');
end;

function CheckDepartment(const AKey: string): TDepartment;
var
  D: TDepartment;
begin
  // DepartmentFromKey falls back to "other": an unknown department is an error here
  Result := DepartmentFromKey(AKey);
  if Result = dpOther then
  begin
    for D := Low(TDepartment) to High(TDepartment) do
      if SameText(AKey.Trim, DepartmentKeys[D]) or SameText(AKey.Trim, DepartmentNames[D]) then
        Exit;
    if not MatchText(AKey.Trim, ['other', 'reception']) then
      raise Exception.Create('department must be sales, accessories, maintenance, finance, secondhand or other');
  end;
end;

constructor TGarageMailTools.Create(AEngine: TTriageEngine);
begin
  inherited Create;
  FEngine := AEngine;
end;

function TGarageMailTools.OnMain(const AFunc: TFunc<string>): string;
var
  R: string;
begin
  // The engine lives on the main thread. Synchronize re-raises an exception of
  // AFunc here, so it reaches the MCP client as a tool error.
  if TThread.Current.ThreadID = MainThreadID then
    Exit(AFunc());
  TThread.Synchronize(nil,
    procedure
    begin
      R := AFunc();
    end);
  Result := R;
end;

function TGarageMailTools.WaitUntil(const ACondition: TFunc<Boolean>; ATimeoutSec: Integer): Boolean;
var
  Watch: TStopwatch;
  Done: Boolean;
begin
  Watch := TStopwatch.StartNew;
  repeat
    OnMain(
      function: string
      begin
        Done := ACondition();
        Result := '';
      end);
    if Done then
      Exit(True);
    if TThread.Current.ThreadID = MainThreadID then
      CheckSynchronize(50)
    else
      Sleep(50);
  until Watch.Elapsed.TotalSeconds > ATimeoutSec;
  Result := False;
end;

function TGarageMailTools.MailResult(AID: Integer): string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(MailToJSON(FEngine.MailByID(AID), mjFull));
    end);
end;

{ Looking }

function TGarageMailTools.GetStatus: string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(FEngine.StatusJSON);
    end);
end;

function TGarageMailTools.ListMails(const AStatus, ADepartment, APriority, AText: string): string;
begin
  Result := OnMain(
    function: string
    var
      Arr: TJSONArray;
      M: TTriageMail;
    begin
      Arr := TJSONArray.Create;
      for M in FEngine.Mails do
      begin
        if (AStatus <> '') and not SameText(StatusKeys[M.Status], AStatus.Trim) then
          Continue;
        if (ADepartment <> '') and (not M.IsTriaged or (M.Department <> CheckDepartment(ADepartment))) then
          Continue;
        if (APriority <> '') and not SameText(M.Priority, NormalizePriority(APriority)) then
          Continue;
        if (AText <> '') and not ContainsText(M.FromDisplay + ' ' + M.Subject + ' ' + M.Brand + ' ' + M.HandlerName, AText.Trim) then
          Continue;
        Arr.AddElement(MailToJSON(M, mjList));
      end;
      Result := JSONText(Arr);
    end);
end;

function TGarageMailTools.GetMail(AID: Integer): string;
begin
  Result := MailResult(AID);
end;

function TGarageMailTools.ListSpam: string;
begin
  Result := OnMain(
    function: string
    var
      Arr: TJSONArray;
      M: TTriageMail;
    begin
      Arr := TJSONArray.Create;
      for M in FEngine.Spam do
        Arr.AddElement(MailToJSON(M, mjList).AddPair('spam_reason', M.SpamReason));
      Result := JSONText(Arr);
    end);
end;

function TGarageMailTools.GetRoutingTable: string;
begin
  Result := OnMain(
    function: string
    var
      Root: TJSONObject;
      Arr: TJSONArray;
      D: TDepartment;
      B: string;
    begin
      Root := TJSONObject.Create;
      Arr := TJSONArray.Create;
      for D := Low(TDepartment) to High(TDepartment) do
        Arr.Add(DepartmentKeys[D]);
      Root.AddPair('departments', Arr);
      Arr := TJSONArray.Create;
      for B in FEngine.Routing.Brands do
        Arr.Add(B);
      Root.AddPair('brands', Arr);
      Root.AddPair('rules', TJSONObject.ParseJSONValue(FEngine.Routing.ToJSON));
      Result := JSONText(Root);
    end);
end;

function TGarageMailTools.GetSettings: string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(FEngine.SettingsJSON);
    end);
end;

function TGarageMailTools.GetLog(ASince, ALimit: Integer): string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(FEngine.LogJSON(ASince, ALimit));
    end);
end;

function TGarageMailTools.ListWorkshop: string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(FEngine.WorkshopJSON);
    end);
end;

function TGarageMailTools.FindCustomer(const AEmail: string): string;
begin
  Result := OnMain(
    function: string
    begin
      Result := JSONText(FEngine.CustomerHistory(AEmail));
    end);
end;

function TGarageMailTools.DashboardState(ASinceVersion, ALogSince: Int64): string;
begin
  Result := OnMain(
    function: string
    var
      Root: TJSONObject;
      Arr: TJSONArray;
      M: TTriageMail;
    begin
      Root := TJSONObject.Create;
      Root.AddPair('version', TJSONNumber.Create(FEngine.Version));
      Root.AddPair('changed', TJSONBool.Create(FEngine.Version <> ASinceVersion));
      Root.AddPair('log', FEngine.LogJSON(ALogSince, 500));
      if FEngine.Version <> ASinceVersion then
      begin
        Root.AddPair('status', FEngine.StatusJSON);
        Arr := TJSONArray.Create;
        for M in FEngine.Mails do
          Arr.AddElement(MailToJSON(M, mjFull));
        Root.AddPair('mails', Arr);
        Arr := TJSONArray.Create;
        for M in FEngine.Spam do
          Arr.AddElement(MailToJSON(M, mjFull));
        Root.AddPair('spam', Arr);
        Root.AddPair('bookings', FEngine.BookingsJSON);
        Root.AddPair('routing', TJSONObject.ParseJSONValue(FEngine.Routing.ToJSON));
        Root.AddPair('settings', FEngine.SettingsJSON);
      end;
      Result := JSONText(Root);
    end);
end;

function TGarageMailTools.GetDashboardState(ASinceVersion, ALogSince: Integer): string;
begin
  Result := DashboardState(ASinceVersion, ALogSince);
end;

{ Mailboxes }

function TGarageMailTools.ConnectMailbox(const ASource: string; AInteractive: Boolean): string;
var
  Source: TMailSource;
  Note: string;
  Connected: Boolean;
begin
  Source := SourceFromName(ASource);
  Note := OnMain(
    function: string
    begin
      Result := FEngine.ConnectMailbox(Source, AInteractive);
    end);
  if Note <> '' then
    Exit(JSONText(TJSONObject.Create.AddPair('connected', TJSONBool.Create(False)).AddPair('note', Note)));
  // An interactive login waits for a person at the browser
  Connected := WaitUntil(
    function: Boolean
    begin
      Result := FEngine.IsConnected(Source) or not FEngine.IsConnecting(Source);
    end, IfThen(AInteractive, 170, 30));
  Result := OnMain(
    function: string
    begin
      Result := JSONText(TJSONObject.Create
        .AddPair('connected', TJSONBool.Create(FEngine.IsConnected(Source)))
        .AddPair('note', IfThen(FEngine.IsConnected(Source), '',
          IfThen(Connected, 'The mailbox did not accept the login: connect interactively.',
            'Still waiting for the login; check get_status later.'))));
    end);
end;

function TGarageMailTools.FetchMails(const ASource: string; AMax: Integer): string;
var
  Note: string;
  Before: Integer;
begin
  Before := StrToInt(OnMain(
    function: string
    begin
      Result := IntToStr(FEngine.Mails.Count + FEngine.Spam.Count);
    end));
  Note := OnMain(
    function: string
    begin
      Result := FEngine.FetchMails(ASource, AMax);
    end);
  WaitUntil(
    function: Boolean
    begin
      Result := not FEngine.IsFetching;
    end, 90);
  Result := OnMain(
    function: string
    var
      Root: TJSONObject;
      Arr: TJSONArray;
      I: Integer;
    begin
      Root := TJSONObject.Create;
      Root.AddPair('new_mails', TJSONNumber.Create(FEngine.Mails.Count + FEngine.Spam.Count - Before));
      if Note <> '' then
        Root.AddPair('note', Note);
      if FEngine.IsFetching then
        Root.AddPair('still_fetching', TJSONBool.Create(True));
      Arr := TJSONArray.Create;
      for I := 0 to FEngine.Mails.Count - 1 do
        Arr.AddElement(MailToJSON(FEngine.Mails[I], mjList));
      Root.AddPair('inbox', Arr);
      Result := JSONText(Root);
    end);
end;

{ Triage }

function TGarageMailTools.RunTriage(AID: Integer; AWait: Boolean): string;
var
  Count: Integer;
begin
  Count := StrToInt(OnMain(
    function: string
    begin
      Result := IntToStr(FEngine.QueueTriage(AID));
    end));
  if Count = 0 then
    Exit('{"queued":0,"note":"Nothing to triage: every mail is already classified."}');
  if AID <> 0 then
  begin
    WaitUntil(
      function: Boolean
      var
        M: TTriageMail;
      begin
        M := FEngine.FindMail(AID);
        Result := not Assigned(M) or not (M.Status in [tsQueued, tsAnalyzing]);
      end, 120);
    Exit(MailResult(AID));
  end;
  if AWait then
    WaitUntil(
      function: Boolean
      begin
        Result := not FEngine.IsTriaging;
      end, 300);
  Result := OnMain(
    function: string
    var
      Root: TJSONObject;
    begin
      Root := FEngine.StatusJSON;
      Root.AddPair('queued', TJSONNumber.Create(Count));
      Root.AddPair('finished', TJSONBool.Create(not FEngine.IsTriaging));
      Result := JSONText(Root);
    end);
end;

function TGarageMailTools.TriageMail(AID: Integer; const ADepartment, ABrand, APriority, ASummary,
  AReply: string; ASpam: Boolean): string;
begin
  OnMain(
    function: string
    var
      M: TTriageMail;
    begin
      M := FEngine.MailByID(AID);
      if ASpam then
        FEngine.MarkSpam(M, ASummary)
      else
        FEngine.RecordTriage(M, CheckDepartment(ADepartment), ABrand, APriority, ASummary, AReply);
      Result := '';
    end);
  Result := MailResult(AID);
end;

function TGarageMailTools.RerouteMail(AID: Integer; const ADepartment, ABrand: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.Reroute(FEngine.MailByID(AID), CheckDepartment(ADepartment), ABrand, 'Manual (MCP client)');
      Result := '';
    end);
  Result := MailResult(AID);
end;

function TGarageMailTools.UpdateReply(AID: Integer; const AText: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.UpdateReply(FEngine.MailByID(AID), AText);
      Result := '';
    end);
  Result := MailResult(AID);
end;

{ Drafts and forwarding }

function TGarageMailTools.SaveReplyDrafts(AID: Integer): string;
var
  Count: Integer;
begin
  Count := StrToInt(OnMain(
    function: string
    begin
      Result := IntToStr(FEngine.QueueDrafts(AID));
    end));
  if AID = 0 then
    Exit(Format('{"queued":%d,"note":"Drafts are saved one by one; follow get_status or list_mails (reply_status)."}', [Count]));
  WaitUntil(
    function: Boolean
    var
      M: TTriageMail;
    begin
      M := FEngine.FindMail(AID);
      Result := not Assigned(M) or (M.ReplyStatus <> rsCreating);
    end, 60);
  Result := MailResult(AID);
end;

function TGarageMailTools.ForwardMails(AID: Integer; AConfirmSend: Boolean): string;
var
  Count: Integer;
begin
  Count := StrToInt(OnMain(
    function: string
    begin
      Result := IntToStr(FEngine.QueueForwards(AID, AConfirmSend));
    end));
  // The note is written for people too: the dashboard shows it in its status line
  if AID = 0 then
    Exit(OnMain(
      function: string
      var
        DryRun: Boolean;
        Note: string;
      begin
        DryRun := FEngine.Settings.DryRun or not AConfirmSend;
        if Count = 0 then
          Note := 'Nothing to forward: triage the mails first.'
        else if DryRun then
          Note := Format('Dry run: %d forward(s) simulated, nothing is sent.', [Count])
        else
          Note := Format('Forwarding %d mail(s) to the handlers, one by one (follow get_status).', [Count]);
        Result := JSONText(TJSONObject.Create
          .AddPair('queued', TJSONNumber.Create(Count))
          .AddPair('dry_run', TJSONBool.Create(DryRun))
          .AddPair('note', Note));
      end));
  WaitUntil(
    function: Boolean
    var
      M: TTriageMail;
    begin
      M := FEngine.FindMail(AID);
      Result := not Assigned(M) or ((M.Status <> tsForwarding) and (FEngine.ActiveForwardID <> AID));
    end, 90);
  Result := MailResult(AID);
end;

function TGarageMailTools.ArchiveForwarded: string;
begin
  Result := OnMain(
    function: string
    begin
      Result := Format('{"archived":%d}', [FEngine.ArchiveForwarded]);
    end);
end;

{ Workshop, alerts, translation }

function TGarageMailTools.CancelBooking(const AStart: string): string;
begin
  Result := OnMain(
    function: string
    var
      Slot: TDateTime;
      B: TWorkshopBooking;
    begin
      Slot := ParseSlot(AStart.Trim);
      if Slot = 0 then
        raise Exception.Create('start must be yyyy-mm-dd hh:nn');
      B := FEngine.CancelBooking(Slot);
      Result := JSONText(TJSONObject.Create.AddPair('cancelled', BookingToJSON(B)));
    end);
end;

function TGarageMailTools.SetAppointment(AID: Integer; const AStart: string): string;
begin
  OnMain(
    function: string
    var
      Slot: TDateTime;
    begin
      Slot := 0;
      if AStart.Trim <> '' then
      begin
        Slot := ParseSlot(AStart.Trim);
        if Slot = 0 then
          raise Exception.Create('start must be yyyy-mm-dd hh:nn');
      end;
      FEngine.SetAppointment(FEngine.MailByID(AID), Slot);
      Result := '';
    end);
  Result := MailResult(AID);
end;

function TGarageMailTools.SyncCalendar: string;
var
  Note: string;
begin
  Note := OnMain(
    function: string
    begin
      Result := FEngine.SyncCalendar;
    end);
  if Note <> '' then
    Exit(JSONText(TJSONObject.Create.AddPair('note', Note)));
  WaitUntil(
    function: Boolean
    begin
      Result := not FEngine.CalendarPending;
    end, 170);
  Result := OnMain(
    function: string
    begin
      if FEngine.CalendarPending then
        Result := '{"note":"Waiting for the calendar consent in the browser on the server machine."}'
      else
        Result := JSONText(TJSONObject.Create.AddPair('result', FEngine.CalendarResult));
    end);
end;

function TGarageMailTools.NotifyOnCall(AID: Integer; const AMessage: string): string;
var
  Note: string;
begin
  Note := OnMain(
    function: string
    begin
      Result := FEngine.NotifyOnCall(FEngine.MailByID(AID), AMessage);
    end);
  if Note <> '' then
    Exit(JSONText(TJSONObject.Create.AddPair('sent', TJSONBool.Create(False)).AddPair('note', Note)));
  WaitUntil(
    function: Boolean
    begin
      Result := not FEngine.PushPending;
    end, 30);
  Result := OnMain(
    function: string
    begin
      Result := JSONText(TJSONObject.Create
        .AddPair('sent', TJSONBool.Create(FEngine.PushResult = 'delivered'))
        .AddPair('result', IfThen(FEngine.PushPending, 'no answer yet', FEngine.PushResult)));
    end);
end;

function TGarageMailTools.TranslateMail(AID: Integer): string;
var
  Note: string;
begin
  Note := OnMain(
    function: string
    begin
      Result := FEngine.Translate(FEngine.MailByID(AID));
    end);
  if Note <> '' then
    raise Exception.Create(Note);
  WaitUntil(
    function: Boolean
    begin
      Result := FEngine.TranslatingID <> AID;
    end, 60);
  Result := OnMain(
    function: string
    var
      M: TTriageMail;
    begin
      M := FEngine.MailByID(AID);
      if M.Translation = '' then
        raise Exception.Create('Translation failed: ' + FEngine.TranslateError);
      Result := JSONText(TJSONObject.Create
        .AddPair('source_language', M.SourceLanguage)
        .AddPair('target_language', FEngine.Settings.TargetLanguage)
        .AddPair('translation', M.Translation));
    end);
end;

{ Spam }

function TGarageMailTools.MarkSpam(AID: Integer; const AReason: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.MarkSpam(FEngine.MailByID(AID), AReason);
      Result := '';
    end);
  Result := MailResult(AID);
end;

function TGarageMailTools.MarkNotSpam(AID: Integer): string;
begin
  OnMain(
    function: string
    begin
      FEngine.MarkNotSpam(FEngine.MailByID(AID));
      Result := '';
    end);
  Result := MailResult(AID);
end;

function TGarageMailTools.DeleteSpam(AID: Integer): string;
var
  Count: Integer;
begin
  Count := StrToInt(OnMain(
    function: string
    begin
      Result := IntToStr(FEngine.QueueTrash(AID));
    end));
  WaitUntil(
    function: Boolean
    begin
      // Done when the mail(s) left the spam list, or the queue gave up on them
      if AID <> 0 then
        Result := not Assigned(FEngine.Spam.FindByID(AID)) or not FEngine.IsBusy
      else
        Result := (FEngine.Spam.Count = 0) or not FEngine.IsBusy;
    end, 60);
  Result := OnMain(
    function: string
    begin
      Result := JSONText(TJSONObject.Create
        .AddPair('requested', TJSONNumber.Create(Count))
        .AddPair('spam_left', TJSONNumber.Create(FEngine.Spam.Count)));
    end);
end;

{ Maintenance }

function TGarageMailTools.SetRoutingRule(const ADepartment, ABrand, AName, AEmail: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.SetRoutingRule(CheckDepartment(ADepartment), ABrand, AName, AEmail);
      Result := '';
    end);
  Result := GetRoutingTable;
end;

function TGarageMailTools.DeleteRoutingRule(const ADepartment, ABrand: string): string;
begin
  OnMain(
    function: string
    begin
      if not FEngine.DeleteRoutingRule(CheckDepartment(ADepartment), ABrand) then
        raise Exception.Create('There is no rule for this department and brand');
      Result := '';
    end);
  Result := GetRoutingTable;
end;

function TGarageMailTools.ReplaceRoutingTable(const ARules: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.ReplaceRouting(ARules);
      Result := '';
    end);
  Result := GetRoutingTable;
end;

function TGarageMailTools.ResetRoutingTable: string;
begin
  OnMain(
    function: string
    begin
      FEngine.ResetRouting;
      Result := '';
    end);
  Result := GetRoutingTable;
end;

function TGarageMailTools.UpdateSetting(const AName, AValue: string): string;
begin
  OnMain(
    function: string
    begin
      FEngine.SetSetting(AName, AValue);
      Result := '';
    end);
  Result := GetSettings;
end;

{ Prompts and resources }

function TGarageMailTools.TriageInboxPrompt: TTMSMCPPromptMessages;
begin
  Result := TTMSMCPPromptMessages.Create(nil);
  Result.AddUserMessage(
    'You are the mail triage assistant of Brightline Motors, a multi-brand car dealership and garage.' + sLineBreak +
    '1. Call get_status. If no mailbox is connected, call fetch_mails with source "demo"; otherwise fetch_mails.' + sLineBreak +
    '2. Call get_routing_table. For every mail with status "new", read it with get_mail and call triage_mail with ' +
    'the department (sales = new cars, accessories = parts, maintenance = service/repairs/breakdowns, finance = ' +
    'leasing/invoices, secondhand = used cars and trade-ins, other = anything else), the brand, the priority ' +
    '(urgent = broken down or safety issue) and a reply in the customer''s language that ends with [SIGNATURE]. ' +
    'Never promise prices, dates or stock. Use spam=true for scams and cold sales pitches.' + sLineBreak +
    '3. Save the replies with save_reply_drafts.' + sLineBreak +
    '4. For a breakdown or safety issue, call notify_on_call. Only book workshop slots (set_appointment) when I ask.' + sLineBreak +
    '5. Do not forward anything for real unless I ask; end with a short overview table per department.');
end;

function TGarageMailTools.HealthCheckPrompt: TTMSMCPPromptMessages;
begin
  Result := TTMSMCPPromptMessages.Create(nil);
  Result.AddUserMessage(
    'Check on the Brightline Motors mail triage server and keep it healthy.' + sLineBreak +
    '1. Call get_status and get_log. Report mailboxes that are not connected, the AI engine, and anything that failed.' + sLineBreak +
    '2. For mails with status "error", find the cause in get_mail / get_log. Retry them with run_triage when the ' +
    'cause was temporary; if a setting is wrong (missing API key, wrong model), tell me what to change before ' +
    'changing it with update_setting.' + sLineBreak +
    '3. Review list_spam: point out mails that look like real customers (mark_not_spam only after I agree).' + sLineBreak +
    '4. Check that every department in get_routing_table has a "*" fallback rule and that no handler address uses ' +
    'the .example domain; propose fixes, apply them with set_routing_rule after I agree.' + sLineBreak +
    '5. End with a short health report.');
end;

function TGarageMailTools.InboxResource: string;
begin
  Result := ListMails('', '', '', '');
end;

function TGarageMailTools.RoutingResource: string;
begin
  Result := GetRoutingTable;
end;

function TGarageMailTools.StatusResource: string;
begin
  Result := GetStatus;
end;

procedure TGarageMailTools.ValidateToken(Sender: TObject; const AToken, AResourceURI: string;
  var AValidation: TTMSMCPAccessTokenValidation);
begin
  // A shared team token. To accept tokens from your identity provider (Entra ID, Google,
  // Auth0, ...) validate the JWT here instead and list that server in AuthorizationServers.
  AValidation.Valid := (FToken <> '') and (AToken = FToken);
  AValidation.Subject := 'garage-team';
end;

end.
