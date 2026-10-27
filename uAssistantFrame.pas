{ TMS AI Mail Desk - the AI assistant panel
  mcpAssistant (TTMSMCPClient, TMS AI Studio) connects to the triage server
  over MCP, reads its tools (tools/list) and hands them to its built-in
  TTMSMCPCloudAI. The model can then do everything the server offers: look at
  the inbox, triage, re-route, retry errors, review spam, edit the routing
  table and the settings. Three tools of its own, defined at design time in
  uAssistantFrame.fmx, steer the dashboard (filter_inbox, show_mail,
  show_page); the page that hosts the panel handles them through the
  OnFilterInbox, OnShowMail and OnShowPage events.
  Actions that change or send things are confirmed by the user
  (OnBeforeUseTool). The panel sits on the main form and is always shown.
  The assistant uses the AI service and key of the Settings page: the key
  is read from the server's key store when the server runs on this machine,
  else from the copy the Settings page hands over when it saves a key
  (StoreAPIKey, assistant.cfg, encrypted). }

unit uAssistantFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.JSON,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Layouts,
  FMX.Controls.Presentation,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCChat,
  TMS.MCP.CustomComponent, TMS.MCP.CloudBase, TMS.MCP.CloudAI, TMS.MCP.Client, TMS.MCP.Client.Connection;

type
  TShowPageEvent = procedure(APage: Integer) of object;
  TFilterInboxEvent = procedure(const ADepartmentKey, APriority, AText: string) of object;
  TShowMailEvent = function(AID: Integer): Boolean of object;

  TfrAssistant = class(TFrame)
    recAssistant: TRectangle;
    layAssistantHeader: TLayout;
    lblAssistantTitle: TLabel;
    lblAssistantHint: TLabel;
    chatAssistant: TTMSFNCChat;
    mcpAssistant: TTMSMCPClient;
    procedure chatAssistantAfterSendButtonMessage(Sender: TObject; var AItem: TTMSFNCChatItem);
    procedure AssistantBeforeUseTool(Sender: TObject; AToolName: string; AParam: TJSONObject; var AAllow: Boolean);
    procedure AssistantExecuted(Sender: TObject; AResponse: string; AHttpStatusCode: Integer; AHttpResult: string);
    procedure AssistantFilterInbox(Sender: TObject; Args: TJSONObject; var Result: string);
    procedure AssistantShowMail(Sender: TObject; Args: TJSONObject; var Result: string);
    procedure AssistantShowPage(Sender: TObject; Args: TJSONObject; var Result: string);
  private
    FServer: TTMSMCPClientServerItem;
    FBusy: Boolean;
    FToolRunning: Boolean;             // a server tool call of the assistant is waited for
    FReconnect: Boolean;               // reconnect once the current question is answered
    FCloseWhenDone: Boolean;
    FHistory: TStringList;
    FOnShowPage: TShowPageEvent;
    FOnFilterInbox: TFilterInboxEvent;
    FOnShowMail: TShowMailEvent;
    function FindService(const AName: string; AToolCalling: Boolean; out AService: TTMSMCPCloudAIService): Boolean;
    function LoadKey(AService: TTMSMCPCloudAIService): string;
    procedure ToolsListed(Sender: TObject);
    procedure HookServerTools;
    procedure ServerTool(Sender: TObject; Args: TJSONObject; var Result: string);
    procedure CloseMainForm;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // (Re)connects to the triage server the dashboard follows
    procedure Connect;
    // Shows the AI service of the Settings page in the title
    procedure ShowService;
    // Keeps a copy of the AI key saved on the Settings page (the server never sends it back)
    procedure StoreAPIKey(const AService, AKey: string);
    // True while the assistant waits for a server tool: the app cannot close then
    property ToolRunning: Boolean read FToolRunning;
    // Close the main form once the current tool call returned
    property CloseWhenDone: Boolean read FCloseWhenDone write FCloseWhenDone;
    property OnShowPage: TShowPageEvent read FOnShowPage write FOnShowPage;
    property OnFilterInbox: TFilterInboxEvent read FOnFilterInbox write FOnFilterInbox;
    property OnShowMail: TShowMailEvent read FOnShowMail write FOnShowMail;
  end;

implementation

{$R *.fmx}

uses
  System.StrUtils, System.TypInfo, System.IOUtils, FMX.DialogService.Sync,
  uEngineClient, uTheme, uDashboard;

const
  KeysPassword = 'tms-garage-mail-dashboard';
  // The server's own key store, when the server runs on this machine (uTriageEngine)
  ServerKeysFileName = 'aikeys.cfg';
  ServerKeysPassword = 'tms-garage-mail-triage';
  // Server tools the assistant does not need: the dashboard's own plumbing
  HiddenTools: array[0..0] of string = ('get_dashboard_state');
  // Server tools that change or send things: the user confirms each call
  ConfirmTools: array[0..10] of string = ('forward_mails', 'delete_spam', 'mark_spam', 'archive_forwarded',
    'set_routing_rule', 'delete_routing_rule', 'replace_routing_table', 'reset_routing_table',
    'update_setting', 'connect_mailbox', 'cancel_booking');
  Pages: array[0..6] of string = ('inbox', 'board', 'workshop', 'routing', 'settings', 'activity', 'spam');
  MaxTurns = 6;
  Hint = 'Ask or instruct: "urgent Audi mails?", "retry the failed mails"';
  Dot = '  '#$00B7'  ';

type
  // TreeView (the chat's message list) is protected in the chat
  TChatAccess = class(TTMSFNCChat);

function KeysFile: string;
begin
  Result := TPath.Combine(LocalDataDir, 'assistant.cfg');
end;

// The key of aiClaude is APIKeys.Claude, of aiOpenAI APIKeys.OpenAI, ...
function KeyName(AService: TTMSMCPCloudAIService): string;
begin
  Result := Copy(GetEnumName(TypeInfo(TTMSMCPCloudAIService), Ord(AService)), 3, MaxInt);
end;

function GetKey(AKeys: TTMSMCPCloudAIAPIKeys; AService: TTMSMCPCloudAIService): string;
begin
  if IsPublishedProp(AKeys, KeyName(AService)) then
    Result := GetStrProp(AKeys, KeyName(AService))
  else
    Result := 'local'; // Ollama, llama.cpp: no key
end;

procedure SetKey(AKeys: TTMSMCPCloudAIAPIKeys; AService: TTMSMCPCloudAIService; const AKey: string);
begin
  if IsPublishedProp(AKeys, KeyName(AService)) then
    SetStrProp(AKeys, KeyName(AService), AKey);
end;

{ Setup }

constructor TfrAssistant.Create(AOwner: TComponent);
begin
  inherited;
  FHistory := TStringList.Create;
  // Not published by the client, so not in the .fmx: the system prompt and the
  // values of the enum parameters of the dashboard's own tools
  mcpAssistant.LLM.SystemRole.Text :=
    'You are the assistant in the dashboard of the mail triage system of Brightline Motors, a multi-brand car ' +
    'dealership and garage. Staff ask you about the customer mails and ask you to run and maintain the system. ' +
    'The triage server''s tools give you everything: the inbox (list_mails, get_mail, get_status), triage ' +
    '(run_triage, triage_mail, reroute_mail), reply drafts, forwarding, the workshop, spam, the routing table, the ' +
    'settings and the activity log. Look before you act, and use the tools rather than guessing. Forward for real ' +
    'or delete only when the user asks for it; the user confirms those actions. ' +
    'filter_inbox, show_mail and show_page change what the dashboard shows: when the answer is a set of mails, ' +
    'filter the inbox to them. Answer briefly, in the language of the question, and say what you did.';
  mcpAssistant.Tools[0].Parameters[0].Enum.CommaText := 'sales,accessories,maintenance,finance,secondhand,other';
  mcpAssistant.Tools[0].Parameters[1].Enum.CommaText := 'urgent,high,normal,low';
  mcpAssistant.Tools[2].Parameters[0].Enum.CommaText := string.Join(',', Pages);

  // The chat's look is designed in the .fmx; its message list (an inner tree
  // view) and send button are not published, so they are set here
  FlattenTreeView(TChatAccess(chatAssistant).TreeView);
  chatAssistant.SendButton.Bitmaps.Clear;
  chatAssistant.SendButton.Text := 'Send';
  chatAssistant.SendButton.Width := 64;
  chatAssistant.SendButton.Font.Color := TAlphaColors.White;
  chatAssistant.SendButton.Font.Style := [TFontStyle.fsBold];
  chatAssistant.SendButton.Appearance.Rounding := 8;
  chatAssistant.SendButton.Appearance.ShowInnerStroke := False;   // no second outline inside the pill
  chatAssistant.SendButton.Appearance.NormalFill.Color := Primary;
  chatAssistant.SendButton.Appearance.NormalStroke.Color := Primary;
  chatAssistant.SendButton.Appearance.HoverFill.Color := $FF1D4ED8;
  chatAssistant.SendButton.Appearance.HoverStroke.Color := $FF1D4ED8;
  chatAssistant.SendButton.Appearance.DownFill.Color := $FF1E40AF;
  chatAssistant.SendButton.Appearance.DownStroke.Color := $FF1E40AF;
end;

destructor TfrAssistant.Destroy;
begin
  if Assigned(FServer) then
    try
      FServer.Stop;
    except
      // the server may be gone already
    end;
  FHistory.Free;
  inherited;
end;

{ AI service and key: those of the Settings page }

function TfrAssistant.FindService(const AName: string; AToolCalling: Boolean;
  out AService: TTMSMCPCloudAIService): Boolean;
var
  Services: TStrings;
  I: Integer;
begin
  // The server names its services as TTMSMCPCloudAI lists them; Objects[] holds the ordinal
  Services := mcpAssistant.LLM.GetServices(AToolCalling);
  I := Services.IndexOf(AName);
  Result := I >= 0;
  if Result then
    AService := TTMSMCPCloudAIService(NativeInt(Services.Objects[I]));
end;

function TfrAssistant.LoadKey(AService: TTMSMCPCloudAIService): string;
var
  ServerKeys: string;
begin
  // Read at every question, so a key changed since (on Settings, or by an LLM
  // with update_setting) is used right away. A server on this machine: its
  // own key store holds the key set on Settings
  ServerKeys := TPath.Combine(LocalDataDir, ServerKeysFileName);
  if TFile.Exists(ServerKeys) then
  begin
    mcpAssistant.APIKeys.LoadFromFile(ServerKeys, ServerKeysPassword);
    Result := GetKey(mcpAssistant.APIKeys, AService);
    if Result <> '' then
      Exit;
  end;
  // A remote server: the copy the Settings page handed over when it saved the key
  Result := '';
  if TFile.Exists(KeysFile) then
  begin
    mcpAssistant.APIKeys.LoadFromFile(KeysFile, KeysPassword);
    Result := GetKey(mcpAssistant.APIKeys, AService);
  end;
end;

procedure TfrAssistant.StoreAPIKey(const AService, AKey: string);
var
  Service: TTMSMCPCloudAIService;
begin
  if not FindService(AService, False, Service) then
    Exit;
  if TFile.Exists(KeysFile) then
    mcpAssistant.APIKeys.LoadFromFile(KeysFile, KeysPassword);
  SetKey(mcpAssistant.APIKeys, Service, AKey);
  // Stored encrypted by the AI component itself
  mcpAssistant.APIKeys.SaveToFile(KeysFile, KeysPassword);
end;

procedure TfrAssistant.ShowService;
var
  Name: string;
begin
  Name := Dashboard.Setting('ai_service');
  if (Name = '') or SameText(Name, 'offline') then
    lblAssistantTitle.Text := 'Assistant'
  else
    lblAssistantTitle.Text := 'Assistant' + Dot + Name;
end;

{ Connection to the triage server }

procedure TfrAssistant.Connect;
begin
  // Not in the middle of a question: that would drop the tools it is using
  if FBusy then
  begin
    FReconnect := True;
    Exit;
  end;
  FReconnect := False;
  if Assigned(FServer) then
  begin
    try
      FServer.Stop;
    except
      // a server that went away
    end;
    mcpAssistant.Servers.Clear;
  end;
  FServer := mcpAssistant.Servers.Add;
  FServer.TransportType := ttHTTP;   // before OAuth: changing it recreates the transport
  FServer.URL := Dashboard.ServerURL;
  FServer.OAuth.Authentication.AccessToken := Dashboard.ServerToken;   // "Authorization: Bearer <token>"
  FServer.OnGetToolsList := ToolsListed;
  try
    FServer.Start;   // server/discover, then tools/list
  except
    on E: Exception do
      Dashboard.Log('Assistant: cannot connect to the triage server: ' + E.Message);
  end;
end;

procedure TfrAssistant.ToolsListed(Sender: TObject);
begin
  // Runs before the client turns the tools into AI tools
  Dashboard.Log(Format('Assistant: connected to the triage server over MCP (%d tools)', [FServer.GetTools.Count]));
  // Once they are AI tools, they get our handler
  TThread.ForceQueue(nil, HookServerTools);
end;

procedure TfrAssistant.HookServerTools;
var
  I: Integer;
  Tool: TTMSMCPCloudAITool;
begin
  // The client waits for a server tool on the main thread, which freezes the
  // dashboard while a tool waits for a mailbox or an AI service. Call the
  // server tools ourselves instead (ServerTool). The AI component copies the
  // tools when it starts a question, so this runs before each one.
  if not Assigned(FServer) then
    Exit;
  for I := mcpAssistant.Tools.Count - 1 downto 0 do
  begin
    Tool := mcpAssistant.Tools[I];
    // OpenAI strict mode demands every parameter in "required"; the server's
    // tools have optional parameters, so leave strict off
    Tool.StrictParams := False;
    if MatchText(Tool.Name, HiddenTools) then
      mcpAssistant.Tools.Delete(I)
    else if Assigned(mcpAssistant.Servers.GetByToolName(Tool.Name)) then
      Tool.OnExecute := ServerTool;
  end;
end;

procedure TfrAssistant.ServerTool(Sender: TObject; Args: TJSONObject; var Result: string);
var
  ToolName, Answer: string;
  Allow, Done: Boolean;
  CallArgs: TJSONObject;
begin
  ToolName := (Sender as TTMSMCPCloudAITool).Name;
  Allow := True;
  AssistantBeforeUseTool(mcpAssistant, ToolName, Args, Allow);
  if not Allow then
  begin
    Result := mcpAssistant.ToolDeniedMessage;
    Exit;
  end;

  // The same stateless call the dashboard makes; it runs in its own task
  Done := False;
  Answer := '';
  CallArgs := nil;
  if Assigned(Args) then
    CallArgs := Args.Clone as TJSONObject;
  Dashboard.Client.Call(ToolName, CallArgs,
    procedure(AResult: TJSONValue; const AError: string)
    begin
      if AError <> '' then
        Answer := 'Error: ' + AError
      else if AResult is TJSONString then
        Answer := TJSONString(AResult).Value
      else if Assigned(AResult) then
        Answer := AResult.ToJSON;
      Done := True;
    end);

  // The AI component needs the answer before it returns: wait for it, but keep
  // the dashboard alive (repaints, clicks, server polls) in the meantime
  FToolRunning := True;
  try
    while not Done do
    begin
      Application.ProcessMessages;
      if not Done then
        CheckSynchronize(15);   // runs the queued result; sleeps up to 15 ms when there is none
    end;
  finally
    FToolRunning := False;
  end;
  Result := Answer;
  if FCloseWhenDone then
    TThread.ForceQueue(nil, CloseMainForm);
end;

procedure TfrAssistant.CloseMainForm;
begin
  Application.MainForm.Close;
end;

procedure TfrAssistant.AssistantBeforeUseTool(Sender: TObject; AToolName: string; AParam: TJSONObject;
  var AAllow: Boolean);
var
  Args: string;
begin
  if Assigned(AParam) then
    Args := AParam.ToJSON
  else
    Args := '{}';
  AAllow := not MatchText(AToolName, HiddenTools);
  // Reading is fine; anything that changes or sends things needs a yes
  if AAllow and MatchText(AToolName, ConfirmTools) then
    AAllow := TDialogServiceSync.MessageDialog(Format('The assistant wants to call %s with %s.' + sLineBreak +
      sLineBreak + 'Allow this?', [AToolName, Args]), TMsgDlgType.mtConfirmation,
      [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0) = mrYes;
  if AAllow then
    Dashboard.Log('Assistant: ' + AToolName + ' ' + Args)
  else
    Dashboard.Log('Assistant: ' + AToolName + ' not allowed');
  Dashboard.SetStatus('Assistant: ' + AToolName + '...');
end;

{ Questions and answers }

procedure TfrAssistant.chatAssistantAfterSendButtonMessage(Sender: TObject; var AItem: TTMSFNCChatItem);
var
  Question, Prompt, ServiceName: string;
  Service: TTMSMCPCloudAIService;
begin
  Question := AItem.Text.Trim;
  if Question = '' then
    Exit;
  if FBusy then
  begin
    chatAssistant.AddMessage('One moment, I am still working on the previous question.', 'Assistant', cmlLeft, False);
    Exit;
  end;
  if not Dashboard.Online or not Assigned(FServer) or not FServer.IsRunning then
  begin
    chatAssistant.AddMessage('I am not connected to the triage server yet. Is GarageMailMCP.exe running?',
      'Assistant', cmlLeft, False);
    if Dashboard.Online then
      Connect;
    Exit;
  end;
  // The AI service and key of the Settings page (the service comes from the server)
  ServiceName := Dashboard.Setting('ai_service');
  if not FindService(ServiceName, True, Service) then
  begin
    chatAssistant.AddMessage('I need an AI service that can call tools (OpenAI, Claude, Gemini, Mistral, ...). ' +
      'Pick one on the Settings page, enter its API key and click Save settings.', 'Assistant', cmlLeft, False);
    Exit;
  end;
  if LoadKey(Service) = '' then
  begin
    chatAssistant.AddMessage(Format('I have no API key for %s. Enter it on the Settings page and click Save settings.',
      [ServiceName]), 'Assistant', cmlLeft, False);
    Exit;
  end;

  // The client re-creates the server's tools when they change: drop the ones the
  // assistant does not need and route the rest past the blocking client call
  HookServerTools;

  // The AI component sends one prompt: give it the last turns of the conversation
  Prompt := Question;
  if FHistory.Count > 0 then
    Prompt := 'Conversation so far:' + sLineBreak + FHistory.Text + sLineBreak + 'New question: ' + Question;
  FHistory.Add('User: ' + Question);
  mcpAssistant.Service := Service;
  FBusy := True;
  lblAssistantHint.Text := 'Working...';
  mcpAssistant.Execute(Prompt);
end;

procedure TfrAssistant.AssistantExecuted(Sender: TObject; AResponse: string; AHttpStatusCode: Integer;
  AHttpResult: string);
var
  Answer: string;
begin
  FBusy := False;
  lblAssistantHint.Text := Hint;
  if AHttpStatusCode div 100 = 2 then
    Answer := AResponse.Trim
  else
    Answer := Format('The AI service returned HTTP %d: %s', [AHttpStatusCode, Copy(AHttpResult, 1, 200)]);
  if Answer = '' then
    Answer := 'Done.';
  chatAssistant.AddMessage(Answer, 'Assistant', cmlLeft, False);
  FHistory.Add('Assistant: ' + Answer.Replace(sLineBreak, ' '));
  while FHistory.Count > 2 * MaxTurns do
    FHistory.Delete(0);
  Dashboard.SetStatus('Assistant: done.');
  // Show the effect of what it did right away
  Dashboard.Client.Refresh;
  if FReconnect and Dashboard.Online then
    Connect;
end;

{ The assistant's own tools: they steer the dashboard }

procedure TfrAssistant.AssistantFilterInbox(Sender: TObject; Args: TJSONObject; var Result: string);
var
  Dept, Prio, Text: string;
begin
  Dept := '';
  Prio := '';
  Text := '';
  if Assigned(Args) then
  begin
    Args.TryGetValue<string>('department', Dept);
    Args.TryGetValue<string>('priority', Prio);
    Args.TryGetValue<string>('text', Text);
  end;
  if Assigned(FOnFilterInbox) then
    FOnFilterInbox(Dept, Prio, Text.Trim);
  Result := Format('{"shown":true,"department":"%s","priority":"%s","text":%s}',
    [Dept, Prio, TJSONString.Create(Text.Trim).ToJSON]);
end;

procedure TfrAssistant.AssistantShowMail(Sender: TObject; Args: TJSONObject; var Result: string);
begin
  if Assigned(Args) and Assigned(FOnShowMail) and FOnShowMail(Args.GetValue<Integer>('id', 0)) then
    Result := '{"shown":true}'
  else
    Result := '{"shown":false,"note":"Not in the inbox (spam mails are on the spam page)"}';
end;

procedure TfrAssistant.AssistantShowPage(Sender: TObject; Args: TJSONObject; var Result: string);
var
  I: Integer;
begin
  I := -1;
  if Assigned(Args) then
    I := IndexText(Args.GetValue<string>('page', ''), Pages);
  if (I < 0) or not Assigned(FOnShowPage) then
  begin
    Result := '{"shown":false}';
    Exit;
  end;
  FOnShowPage(I);
  Result := '{"shown":true}';
end;

end.
