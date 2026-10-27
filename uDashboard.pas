{ TMS AI Mail Desk - the dashboard's view of the triage server
  The triage itself runs in the triage server (MCPServer\GarageMailMCP.exe).
  TDashboard follows it: uEngineClient polls get_dashboard_state, and every
  change is kept here (mails, spam, routing table, settings, status) and
  announced with an event, so the pages can show it. Commands go to the server
  with RunTool: the same MCP tools an LLM uses.

  There is one TDashboard, the global Dashboard. It exists from the start
  (the pages use it while the main form loads); the main form starts it in
  FormCreate and frees it first in FormDestroy.
  It also keeps the dashboard's own settings (dashboard.ini): where the server
  is, its token, the theme and the assistant's AI service. }

unit uDashboard;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  uTriageModel, uRouting, uEngineClient;

type
  TTextEvent = procedure(const AText: string) of object;

  TDashboard = class
  private
    FClient: TEngineClient;
    FMails: TTriageMailList;
    FSpam: TTriageMailList;
    FBookings: TArray<TWorkshopBooking>;   // workshop planning that existed before the triage
    FRouting: TRoutingTable;
    FSettings: TJSONObject;            // last get_settings of the server
    FStatus: TJSONObject;              // last get_status of the server
    FSettingsJSON: string;
    FRoutingJSON: string;
    FMailbox: array[TMailSource] of string;    // connected / connecting / not connected
    FOnline: Boolean;
    FServerURL: string;
    FServerToken: string;
    FTokenFromServer: Boolean;         // token read from the server's own settings.ini
    FOnLogLine: TTextEvent;
    FOnStatusText: TTextEvent;
    FOnOnline: TNotifyEvent;
    FOnOffline: TNotifyEvent;
    FOnSettingsChanged: TNotifyEvent;
    FOnRoutingChanged: TNotifyEvent;
    FOnStatusChanged: TNotifyEvent;
    FOnMailsChanged: TNotifyEvent;
    procedure ServerState(AState: TJSONObject);
    procedure ServerOffline(const AReason: string);
    function GetMailbox(ASource: TMailSource): string;
  public
    constructor Create;
    destructor Destroy; override;
    // Reads dashboard.ini and starts following the server
    procedure Start;
    // Another server address or token (saved in dashboard.ini)
    procedure SetServer(const AURL, AToken: string);

    // The dashboard's own settings
    class function SettingsFile: string;
    class function LocalSetting(const ASection, AName, ADefault: string): string;
    class procedure SaveLocalSetting(const ASection, AName, AValue: string);

    // The server's settings ('set' for a secret that has a value)
    function Setting(const AName: string): string;
    function SettingBool(const AName: string; ADefault: Boolean): Boolean;
    function AnyMailboxConnected: Boolean;

    // A tool call. The status line shows the error, or else ASuccess or the
    // tool's own "note"; what the server then does shows as its log arrives.
    // AOnResult runs on success.
    procedure RunTool(const ATool: string; AArgs: TJSONObject; const ASuccess: string = '';
      const AOnResult: TProc<TJSONValue> = nil);
    // The next state shows the routing table again, also when it did not change
    procedure ReloadRouting;
    procedure Log(const AText: string);
    procedure SetStatus(const AText: string);

    property Client: TEngineClient read FClient;
    property Mails: TTriageMailList read FMails;
    property Spam: TTriageMailList read FSpam;
    property Bookings: TArray<TWorkshopBooking> read FBookings;
    property Routing: TRoutingTable read FRouting;
    property Settings: TJSONObject read FSettings;   // nil until the server answered
    property Status: TJSONObject read FStatus;       // nil until the server answered
    property Mailbox[ASource: TMailSource]: string read GetMailbox;
    property Online: Boolean read FOnline;
    property ServerURL: string read FServerURL;
    property ServerToken: string read FServerToken;

    property OnLogLine: TTextEvent read FOnLogLine write FOnLogLine;
    property OnStatusText: TTextEvent read FOnStatusText write FOnStatusText;
    property OnOnline: TNotifyEvent read FOnOnline write FOnOnline;
    property OnOffline: TNotifyEvent read FOnOffline write FOnOffline;
    property OnSettingsChanged: TNotifyEvent read FOnSettingsChanged write FOnSettingsChanged;
    property OnRoutingChanged: TNotifyEvent read FOnRoutingChanged write FOnRoutingChanged;
    property OnStatusChanged: TNotifyEvent read FOnStatusChanged write FOnStatusChanged;
    property OnMailsChanged: TNotifyEvent read FOnMailsChanged write FOnMailsChanged;
  end;

// {"id": AID}
function IdArgs(AID: Integer): TJSONObject;
// Asks a Yes/No question; AOnYes runs on Yes
procedure Confirm(const AQuestion: string; const AOnYes: TProc);

var
  Dashboard: TDashboard;

implementation

uses
  System.IOUtils, System.IniFiles, System.UITypes, FMX.Dialogs, FMX.DialogService, uMailJSON;

function IdArgs(AID: Integer): TJSONObject;
begin
  Result := TJSONObject.Create.AddPair('id', TJSONNumber.Create(AID));
end;

procedure Confirm(const AQuestion: string; const AOnYes: TProc);
begin
  TDialogService.MessageDialog(AQuestion, TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
    TMsgDlgBtn.mbNo, 0,
    procedure(const AResult: TModalResult)
    begin
      if AResult = mrYes then
        AOnYes;
    end);
end;

// When the server runs on this machine, its settings.ini is in the same folder
function SharedServerSetting(const AName: string): string;
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(TPath.Combine(LocalDataDir, 'settings.ini'));
  try
    Result := Ini.ReadString('MCPServer', AName, '');
  finally
    Ini.Free;
  end;
end;

constructor TDashboard.Create;
begin
  inherited;
  FMails := TTriageMailList.Create(True);
  FSpam := TTriageMailList.Create(True);
  FRouting := TRoutingTable.Create;
  // Until the server answers, the routing grid shows the default table
  FRouting.LoadDefaults;
  FClient := TEngineClient.Create;
  FClient.OnState := ServerState;
  FClient.OnOffline := ServerOffline;
end;

destructor TDashboard.Destroy;
begin
  // First: no more server callbacks
  FClient.Free;
  FStatus.Free;
  FSettings.Free;
  FSpam.Free;
  FRouting.Free;
  FMails.Free;
  inherited;
end;

{ Dashboard settings }

class function TDashboard.SettingsFile: string;
begin
  Result := TPath.Combine(LocalDataDir, 'dashboard.ini');
end;

class function TDashboard.LocalSetting(const ASection, AName, ADefault: string): string;
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(SettingsFile);
  try
    Result := Ini.ReadString(ASection, AName, ADefault);
  finally
    Ini.Free;
  end;
end;

class procedure TDashboard.SaveLocalSetting(const ASection, AName, AValue: string);
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(SettingsFile);
  try
    // An empty value removes the key
    if AValue = '' then
      Ini.DeleteKey(ASection, AName)
    else
      Ini.WriteString(ASection, AName, AValue);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TDashboard.Start;
begin
  FServerURL := LocalSetting('Server', 'URL', '');
  if FServerURL = '' then
    FServerURL := Format('http://localhost:%d/mcp', [StrToIntDef(SharedServerSetting('Port'), 8787)]);
  FServerToken := LocalSetting('Server', 'Token', '');
  FTokenFromServer := FServerToken = '';
  if FTokenFromServer then
    FServerToken := SharedServerSetting('Token');
  FClient.Configure(FServerURL, FServerToken);
  FClient.Start;
  Log('Dashboard settings: ' + SettingsFile);
  SetStatus('Connecting to the triage server at ' + FServerURL + ' ...');
end;

procedure TDashboard.SetServer(const AURL, AToken: string);
begin
  if (AURL = FServerURL) and (AToken = FServerToken) then
    Exit;
  FTokenFromServer := FTokenFromServer and (AToken = FServerToken);
  FServerURL := AURL;
  FServerToken := AToken;
  SaveLocalSetting('Server', 'URL', FServerURL);
  // A token that came from the server's own settings.ini is not copied
  if FTokenFromServer then
    SaveLocalSetting('Server', 'Token', '')
  else
    SaveLocalSetting('Server', 'Token', FServerToken);
  FSettingsJSON := '';
  FRoutingJSON := '';
  FClient.Configure(FServerURL, FServerToken);
  // The next answer of the new server counts as coming online (reconnects the assistant)
  FOnline := False;
  Log('Triage server: ' + FServerURL);
end;

{ Following the server }

procedure TDashboard.ServerState(AState: TJSONObject);
var
  Arr: TJSONArray;
  Item: TJSONValue;
  Obj: TJSONObject;
begin
  if not FOnline then
  begin
    FOnline := True;
    Log('Connected to the triage server at ' + FServerURL);
    if Assigned(FOnOnline) then
      FOnOnline(Self);
  end;

  // The server's activity log arrives with every poll; its last line is the status
  if AState.TryGetValue<TJSONArray>('log', Arr) and (Arr.Count > 0) then
  begin
    if Assigned(FOnLogLine) then
      for Item in Arr do
        FOnLogLine(Copy(Item.GetValue<string>('time', ''), 12, 8) + '  ' + Item.GetValue<string>('text', ''));
    SetStatus(Arr.Items[Arr.Count - 1].GetValue<string>('text', ''));
  end;

  if not AState.GetValue<Boolean>('changed', False) then
    Exit;

  // Settings and routing only when they changed, so edits on those pages survive polls
  if AState.TryGetValue<TJSONObject>('settings', Obj) and (Obj.ToJSON <> FSettingsJSON) then
  begin
    FSettingsJSON := Obj.ToJSON;
    FSettings.Free;
    FSettings := Obj.Clone as TJSONObject;
    if Assigned(FOnSettingsChanged) then
      FOnSettingsChanged(Self);
  end;
  if AState.TryGetValue<TJSONArray>('routing', Arr) and (Arr.ToJSON <> FRoutingJSON) then
  begin
    FRoutingJSON := Arr.ToJSON;
    FRouting.LoadFromJSON(FRoutingJSON);
    if Assigned(FOnRoutingChanged) then
      FOnRoutingChanged(Self);
  end;
  if AState.TryGetValue<TJSONObject>('status', Obj) then
  begin
    FStatus.Free;
    FStatus := Obj.Clone as TJSONObject;
    FMailbox[msGmail] := FStatus.GetValue<string>('mailboxes.gmail', '');
    FMailbox[msOutlook] := FStatus.GetValue<string>('mailboxes.outlook', '');
    if Assigned(FOnStatusChanged) then
      FOnStatusChanged(Self);
  end;

  FMails.Clear;
  if AState.TryGetValue<TJSONArray>('mails', Arr) then
    for Item in Arr do
      if Item is TJSONObject then
        FMails.Add(MailFromJSON(TJSONObject(Item)));
  FSpam.Clear;
  if AState.TryGetValue<TJSONArray>('spam', Arr) then
    for Item in Arr do
      if Item is TJSONObject then
        FSpam.Add(MailFromJSON(TJSONObject(Item)));
  FBookings := nil;
  if AState.TryGetValue<TJSONArray>('bookings', Arr) then
    for Item in Arr do
      if Item is TJSONObject then
        FBookings := FBookings + [BookingFromJSON(TJSONObject(Item))];
  if Assigned(FOnMailsChanged) then
    FOnMailsChanged(Self);
end;

procedure TDashboard.ServerOffline(const AReason: string);
var
  Token: string;
begin
  FOnline := False;
  FMailbox[msGmail] := '';
  FMailbox[msOutlook] := '';
  SetStatus('The triage server does not answer at ' + FServerURL + '. Start MCPServer\GarageMailMCP.exe, ' +
    'or check Settings > Triage server.');
  Log('Triage server: ' + AReason);
  // The server creates its token on its first start: pick it up
  if FTokenFromServer then
  begin
    Token := SharedServerSetting('Token');
    if (Token <> '') and (Token <> FServerToken) then
    begin
      FServerToken := Token;
      FClient.Configure(FServerURL, FServerToken);
    end;
  end;
  if Assigned(FOnOffline) then
    FOnOffline(Self);
end;

function TDashboard.Setting(const AName: string): string;
begin
  Result := '';
  if Assigned(FSettings) then
    Result := FSettings.GetValue<string>(AName, '');
end;

function TDashboard.SettingBool(const AName: string; ADefault: Boolean): Boolean;
begin
  Result := ADefault;
  if Assigned(FSettings) then
    Result := FSettings.GetValue<Boolean>(AName, ADefault);
end;

function TDashboard.GetMailbox(ASource: TMailSource): string;
begin
  Result := FMailbox[ASource];
end;

function TDashboard.AnyMailboxConnected: Boolean;
begin
  Result := (FMailbox[msGmail] = 'connected') or (FMailbox[msOutlook] = 'connected');
end;

{ Commands }

procedure TDashboard.RunTool(const ATool: string; AArgs: TJSONObject; const ASuccess: string;
  const AOnResult: TProc<TJSONValue>);
begin
  FClient.Call(ATool, AArgs,
    procedure(AResult: TJSONValue; const AError: string)
    begin
      if AError <> '' then
      begin
        SetStatus(AError);
        Log(ATool + ': ' + AError);
        Exit;
      end;
      if ASuccess <> '' then
        SetStatus(ASuccess)
      else if (AResult is TJSONObject) and (AResult.GetValue<string>('note', '') <> '') then
        SetStatus(AResult.GetValue<string>('note', ''));
      if Assigned(AOnResult) then
        AOnResult(AResult);
    end);
end;

procedure TDashboard.ReloadRouting;
begin
  FRoutingJSON := '';
end;

procedure TDashboard.Log(const AText: string);
begin
  if Assigned(FOnLogLine) then
    FOnLogLine(FormatDateTime('hh:nn:ss', Now) + '  ' + AText);
end;

procedure TDashboard.SetStatus(const AText: string);
begin
  if Assigned(FOnStatusText) then
    FOnStatusText(AText);
end;

initialization
  Dashboard := TDashboard.Create;

finalization
  FreeAndNil(Dashboard);

end.
