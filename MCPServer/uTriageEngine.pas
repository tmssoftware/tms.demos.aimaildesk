{ TMS AI Mail Desk - triage engine
  The whole mail triage as one object without any UI: the inbox, the spam
  list, the routing table, the settings, the work queues and every action.
  The MCP server (uMailTools.pas) exposes it as tools, so an LLM can run and
  maintain the system remotely; the GarageMailDesk app is a dashboard that
  shows and controls it through the same MCP tools.

  Threading: everything in here runs on the main thread. The cloud components
  deliver their results there (TThread.Queue / Synchronize, pumped by the main
  loop in GarageMailMCP.dpr); the MCP tools marshal their calls there with
  TThread.Synchronize. Work that waits for a mailbox or an AI service is queued
  and continues in the component events, like it did in the app.

  Every change bumps Version, so a client can poll for changes cheaply. }

unit uTriageEngine;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.JSON,
  VCL.TMSFNCCloudBase, VCL.TMSFNCCloudOAuth, VCL.TMSFNCCloudGoogleGmail,
  VCL.TMSFNCCloudMicrosoftOutlookMail, VCL.TMSFNCCloudGoogleCalendar,
  VCL.TMSFNCCloudMicrosoftOutlookCalendar, VCL.TMSFNCCloudPushOver,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error, FireDAC.Stan.Def, FireDAC.Stan.Async,
  FireDAC.Stan.Pool, FireDAC.Stan.Param, FireDAC.Phys.Intf, FireDAC.Phys, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.ExprFuncs, FireDAC.UI.Intf,
  FireDAC.ConsoleUI.Wait, FireDAC.DApt, FireDAC.DApt.Intf, FireDAC.DatS, FireDAC.Comp.Client,
  FireDAC.Comp.DataSet, Data.DB,
  TMS.MCP.CloudBase, TMS.MCP.CloudAI,
  uTriageModel, uRouting;

type
  TLogEntry = record
    Seq: Int64;
    Time: TDateTime;
    Text: string;
  end;

  TSettingKind = (skString, skSecret, skInteger, skBoolean);

  TEngineSettings = record
    GmailClientID, GmailSecret: string;
    OutlookClientID, OutlookSecret: string;
    CallbackURL: string;
    MaxMails: Integer;
    DryRun: Boolean;
    AIService: string;          // a name from TTMSMCPCloudAI.GetServices, '' = offline keyword rules
    PushoverToken, PushoverUser: string;
    AlertsEnabled: Boolean;
    TargetLanguage: string;     // translations: a language name or code, for the AI service
    AutoFetchMinutes: Integer;  // 0 = off
    AutoTriage: Boolean;        // triage new mails as soon as they are fetched
    AutoDrafts: Boolean;        // save the reply draft as soon as a mail is triaged
  end;

  TTriageEngine = class
  private
    FMails: TTriageMailList;
    FSpam: TTriageMailList;
    FBookings: TList<TWorkshopBooking>;   // existing workshop planning, saved with the inbox
    FRouting: TRoutingTable;
    FSettings: TEngineSettings;
    FNextID: Integer;
    FVersion: Int64;
    FLog: TList<TLogEntry>;
    FLogSeq: Int64;
    FStatusText: string;
    FDataDir: string;
    FStateDirty: Boolean;
    FLastSave: TDateTime;
    FLastFetch: TDateTime;
    FLastError: string;
    // queues: one request per kind at a time, the mail ID is the queue item
    FTriageQueue, FDraftQueue, FForwardQueue, FTrashQueue: TQueue<Integer>;
    FActiveTriageID, FActiveDraftID, FActiveForwardID, FActiveTrashID: Integer;
    FActiveDraftVia: TMailSource;
    FActiveDraftUpdate: Boolean;  // the active request updates an existing draft
    FBatchTotal, FBatchDone: Integer;
    FDraftSuccess, FDraftGone, FMailboxSuccess: Boolean;
    FDraftInfo, FDraftResultID, FMailboxInfo: string;
    // mailboxes
    FConnected: array[TMailSource] of Boolean;
    FConnecting: array[TMailSource] of TDateTime;
    FFetchPending: Integer;
    FAttachmentsPending: Integer;
    FTriageAfterFetch: Boolean;
    FPendingGmailMessage: TTMSFNCCloudGoogleGmailMessage;
    // calendar, alerts, translation
    FCalendarPending: Boolean;
    FCalendarResult: string;
    FPushPending: Boolean;
    FPushResult: string;
    FTranslatingID: Integer;
    FTranslateError: string;
    // components
    FGmail: TTMSFNCCloudGoogleGmail;
    FOutlook: TTMSFNCCloudMicrosoftOutlookMail;
    FGCalendar: TTMSFNCCloudGoogleCalendar;
    FOCalendar: TTMSFNCCloudMicrosoftOutlookCalendar;
    FPushOver: TTMSFNCCloudPushOver;
    FAI: TTMSMCPCloudAI;
    FTranslator: TTMSMCPCloudAI;    // same service as FAI, apart from the triage queue
    FDB: TFDConnection;
    FQuery: TFDQuery;
    procedure Changed;
    function SettingsFile: string;
    function RoutingFile: string;
    function APIKeysFile: string;
    function StateFile: string;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure LoadState;
    procedure SaveState;
    procedure LoadRouting;
    procedure RoutingChanged;
    function UseAI: Boolean;
    function SelectedService(out AService: TTMSMCPCloudAIService): Boolean;
    function ServiceAPIKey: string;
    procedure SetupCloud(ACloud: TTMSFNCCustomCloudOAuth; const ATokenFile, AClientID, ASecret: string);
    procedure StartBatch(ACount: Integer);
    procedure StepBatch;
    // mail
    procedure AddMail(AMail: TTriageMail);
    procedure MoveToSpam(AMail: TTriageMail);
    procedure AfterTriage(AMail: TTriageMail);
    procedure SendUrgentAlert(AMail: TTriageMail);
    function MailboxFor(AMail: TTriageMail): TMailSource;
    procedure ProcessNextTriage;
    procedure ProcessNextDraft;
    procedure FinishDraft;
    procedure ProcessNextForward;
    procedure FinishForward(ASuccess: Boolean; const AInfo: string);
    procedure QueuedNextForward;
    procedure QueuedStartFiling;
    procedure QueuedFileDone;
    procedure ProcessNextTrash;
    procedure QueuedTrashDone;
    procedure QueuedNextTriage;
    procedure QueueTriageMail(AMail: TTriageMail);
    procedure QueueDraftMail(AMail: TTriageMail);
    procedure QueueForwardMail(AMail: TTriageMail);
    procedure SyncCalendarItems;
    procedure SeedBookings;
    function SlotTaken(AStart: TDateTime; AMail: TTriageMail): Boolean;
    function NextFreeSlot(AStart: TDateTime; AMail: TTriageMail): TDateTime;
    function FreeSlotsText(AMail: TTriageMail): string;
    function CustomerBookings(AMail: TTriageMail): TArray<TWorkshopBooking>;
    function BookingsText(AMail: TTriageMail): string;
    procedure KeywordCancellation(AMail: TTriageMail);
    // history (SQLite)
    procedure OpenHistory;
    procedure SeedHistory;
    procedure LookupHistory(AMail: TTriageMail);
    procedure ApplyCustomerHistory(AMail: TTriageMail);
    procedure SaveHistory(AMail: TTriageMail);
    // component events
    procedure GmailConnected(Sender: TObject);
    procedure GmailGetMails(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure GmailGetMailsComplete(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure GmailSendMessage(Sender: TObject; const AMessage: TTMSFNCCloudGoogleGmailMessage;
      const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure GmailGetAttachment(Sender: TObject; const AMessage: TTMSFNCCloudGoogleGmailMessage;
      const AAttachment: TTMSFNCCloudGoogleGmailMessageAttachment; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure OutlookConnected(Sender: TObject);
    procedure OutlookGetMails(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure OutlookSendMessage(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure OutlookGetAttachments(Sender: TObject; const AMail: TTMSFNCCloudMicrosoftOutlookMailItem;
      const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure GCalendarConnected(Sender: TObject);
    procedure GCalendarAdded(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult;
      const ACalendarItem: TTMSFNCCloudGoogleCalendarItem);
    procedure OCalendarConnected(Sender: TObject);
    procedure OCalendarGetCalendars(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure OCalendarAdded(Sender: TObject; const AItem: TTMSFNCCloudMicrosoftOutlookCalendarItem;
      const ARequestResult: TTMSFNCCloudBaseRequestResult);
    procedure PushSuccess(Sender: TObject);
    procedure PushError(Sender: TObject; AErrorMessage: string; AErrorCode: Integer);
    procedure TranslatorExecuted(Sender: TObject; AResponse: TTMSMCPCloudAIResponse; AHttpStatusCode: Integer;
      AHttpResult: string);
    procedure AIExecuted(Sender: TObject; AResponse: TTMSMCPCloudAIResponse; AHttpStatusCode: Integer;
      AHttpResult: string);
  public
    constructor Create;
    destructor Destroy; override;

    // Called by the main loop a few times per second: automation and saving
    procedure Tick;
    procedure Log(const AText: string);
    procedure SetStatus(const AText: string);

    function FindMail(AID: Integer): TTriageMail;     // inbox or spam, nil when unknown
    function MailByID(AID: Integer): TTriageMail;     // raises for an unknown id
    function IsConnected(ASource: TMailSource): Boolean;
    function IsConnecting(ASource: TMailSource): Boolean;
    function IsFetching: Boolean;
    function IsTriaging: Boolean;
    function IsBusy: Boolean;
    function EngineName: string;
    function AIServices: TArray<string>;

    // mailboxes
    function ConnectMailbox(ASource: TMailSource; AInteractive: Boolean): string;
    function FetchMails(const ASource: string; AMax: Integer): string;
    function LoadDemo: Integer;
    // triage
    function QueueTriage(AID: Integer): Integer;
    procedure RecordTriage(AMail: TTriageMail; ADepartment: TDepartment; const ABrand, APriority, ASummary,
      AReply: string);
    procedure Reroute(AMail: TTriageMail; ADepartment: TDepartment; const ABrand, AEngine: string);
    procedure UpdateReply(AMail: TTriageMail; const AText: string);
    // drafts and forwarding
    function QueueDrafts(AID: Integer): Integer;
    function QueueForwards(AID: Integer; AConfirmSend: Boolean): Integer;
    function ArchiveForwarded: Integer;
    // workshop, alerts, translation
    procedure SetAppointment(AMail: TTriageMail; AStart: TDateTime);
    // Removes the existing booking that starts at AStart (raises when there is none)
    function CancelBooking(AStart: TDateTime): TWorkshopBooking;
    function SyncCalendar: string;
    function NotifyOnCall(AMail: TTriageMail; const AMessage: string): string;
    function Translate(AMail: TTriageMail): string;
    // spam
    procedure MarkSpam(AMail: TTriageMail; const AReason: string);
    procedure MarkNotSpam(AMail: TTriageMail);
    function QueueTrash(AID: Integer): Integer;
    // routing
    procedure SetRoutingRule(ADepartment: TDepartment; const ABrand, AName, AEmail: string);
    function DeleteRoutingRule(ADepartment: TDepartment; const ABrand: string): Boolean;
    procedure ReplaceRouting(const AJson: string);
    procedure ResetRouting;
    // settings
    function SettingsJSON: TJSONObject;
    procedure SetSetting(const AName, AValue: string);
    // history
    function CustomerHistory(const AEmail: string): TJSONArray;

    // JSON views
    function StatusJSON: TJSONObject;
    function LogJSON(ASince: Int64; ALimit: Integer): TJSONArray;
    function WorkshopJSON: TJSONArray;
    function BookingsJSON: TJSONArray;

    property Mails: TTriageMailList read FMails;
    property Spam: TTriageMailList read FSpam;
    property Routing: TRoutingTable read FRouting;
    property Settings: TEngineSettings read FSettings;
    property Version: Int64 read FVersion;
    property LogSeq: Int64 read FLogSeq;
    property ActiveTriageID: Integer read FActiveTriageID;
    property ActiveDraftID: Integer read FActiveDraftID;
    property ActiveForwardID: Integer read FActiveForwardID;
    property TranslatingID: Integer read FTranslatingID;
    property TranslateError: string read FTranslateError;
    property CalendarPending: Boolean read FCalendarPending;
    property CalendarResult: string read FCalendarResult;
    property PushPending: Boolean read FPushPending;
    property PushResult: string read FPushResult;
  end;

const
  SettingNames: array[0..18] of string = (
    'ai_service', 'ai_api_key', 'ai_model', 'max_mails', 'dry_run',
    'auto_fetch_minutes', 'auto_triage', 'auto_drafts',
    'alerts_enabled', 'pushover_token', 'pushover_user',
    'target_language',
    'gmail_client_id', 'gmail_secret', 'outlook_client_id', 'outlook_secret', 'callback_url',
    'mcp_port', 'data_folder');

implementation

uses
  System.IOUtils, System.IniFiles, System.Math, System.DateUtils, System.StrUtils, System.Hash,
  System.RegularExpressions,
  uMailJSON, uTriageAI, uReplyDrafts, uDemoMails, uMailSources, uMailboxFiling;

const
  APIKeysPassword = 'tms-garage-mail-triage';
  MaxLogEntries = 1000;
  ConnectTimeoutSec = 180;

type
  // Authentication, PersistTokens and Connect live in the shared OAuth base class
  TOAuthAccess = class(TTMSFNCCustomCloudOAuth);

// Photos and PDFs are sent to the AI together with the mail
function IsAIAttachment(const AFileName: string): Boolean;
begin
  Result := MatchText(ExtractFileExt(AFileName), ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.pdf']);
end;

// Primary key of a mail in the customer history
function HistoryKey(AMail: TTriageMail): string;
begin
  Result := SourceNames[AMail.Source] + ':' + AMail.SourceID;
end;

function AttachmentPath(const ADataDir, ASourceID, AFileName: string): string;
var
  Name: string;
  Ch: Char;
begin
  // Mail IDs can be long and contain '/' (Outlook): use a hash as the folder name
  Result := TPath.Combine(TPath.Combine(ADataDir, 'attachments'), THashMD5.GetHashString(ASourceID));
  ForceDirectories(Result);
  Name := AFileName;
  for Ch in TPath.GetInvalidFileNameChars do
    Name := Name.Replace(Ch, '_');
  Result := TPath.Combine(Result, Name);
end;

function GetServiceKey(AKeys: TTMSMCPCloudAIAPIKeys; AService: TTMSMCPCloudAIService): string;
begin
  case AService of
    aiOpenAI: Result := AKeys.OpenAI;
    aiGemini: Result := AKeys.Gemini;
    aiGrok: Result := AKeys.Grok;
    aiClaude: Result := AKeys.Claude;
    aiPerplexity: Result := AKeys.Perplexity;
    aiMistral: Result := AKeys.Mistral;
    aiDeepSeek: Result := AKeys.DeepSeek;
    aiOpenRouter: Result := AKeys.OpenRouter;
  else
    Result := ''; // local models (Ollama, llama.cpp) need no key
  end;
end;

procedure SetServiceKey(AKeys: TTMSMCPCloudAIAPIKeys; AService: TTMSMCPCloudAIService; const AKey: string);
begin
  case AService of
    aiOpenAI: AKeys.OpenAI := AKey;
    aiGemini: AKeys.Gemini := AKey;
    aiGrok: AKeys.Grok := AKey;
    aiClaude: AKeys.Claude := AKey;
    aiPerplexity: AKeys.Perplexity := AKey;
    aiMistral: AKeys.Mistral := AKey;
    aiDeepSeek: AKeys.DeepSeek := AKey;
    aiOpenRouter: AKeys.OpenRouter := AKey;
  end;
end;

function ServiceNeedsKey(AService: TTMSMCPCloudAIService): Boolean;
begin
  Result := not (AService in [aiOllama, aiLlamaCpp]);
end;

function GetServiceModel(AAI: TTMSMCPCloudAI; AService: TTMSMCPCloudAIService): string;
begin
  case AService of
    aiOpenAI: Result := AAI.Settings.OpenAIModel;
    aiGemini: Result := AAI.Settings.GeminiModel;
    aiGrok: Result := AAI.Settings.GrokModel;
    aiClaude: Result := AAI.Settings.ClaudeModel;
    aiPerplexity: Result := AAI.Settings.PerplexityModel;
    aiMistral: Result := AAI.Settings.MistralModel;
    aiDeepSeek: Result := AAI.Settings.DeepSeekModel;
    aiOpenRouter: Result := AAI.Settings.OpenRouterModel;
    aiOllama: Result := AAI.Settings.OllamaModel;
  else
    Result := '';
  end;
end;

procedure SetServiceModel(AAI: TTMSMCPCloudAI; AService: TTMSMCPCloudAIService; const AModel: string);
begin
  case AService of
    aiOpenAI: AAI.Settings.OpenAIModel := AModel;
    aiGemini: AAI.Settings.GeminiModel := AModel;
    aiGrok: AAI.Settings.GrokModel := AModel;
    aiClaude: AAI.Settings.ClaudeModel := AModel;
    aiPerplexity: AAI.Settings.PerplexityModel := AModel;
    aiMistral: AAI.Settings.MistralModel := AModel;
    aiDeepSeek: AAI.Settings.DeepSeekModel := AModel;
    aiOpenRouter: AAI.Settings.OpenRouterModel := AModel;
    aiOllama: AAI.Settings.OllamaModel := AModel;
  else
    raise Exception.Create('This AI service has no model setting');
  end;
end;

function ParseBool(const AValue: string): Boolean;
begin
  Result := MatchText(AValue.Trim, ['true', '1', 'yes', 'on']);
  if not Result and not MatchText(AValue.Trim, ['false', '0', 'no', 'off']) then
    raise Exception.Create('Expected true or false');
end;

{ ------------------------------------------------------------------------- }
{ Setup                                                                     }
{ ------------------------------------------------------------------------- }

constructor TTriageEngine.Create;
begin
  inherited;
  FMails := TTriageMailList.Create(True);
  FSpam := TTriageMailList.Create(True);
  FBookings := TList<TWorkshopBooking>.Create;
  FRouting := TRoutingTable.Create;
  FLog := TList<TLogEntry>.Create;
  FTriageQueue := TQueue<Integer>.Create;
  FDraftQueue := TQueue<Integer>.Create;
  FForwardQueue := TQueue<Integer>.Create;
  FTrashQueue := TQueue<Integer>.Create;
  FNextID := 1;
  FDataDir := AppDataDir;

  FGmail := TTMSFNCCloudGoogleGmail.Create(nil);
  FGmail.OnConnected := GmailConnected;
  FGmail.OnGetMails := GmailGetMails;
  FGmail.OnGetMailsComplete := GmailGetMailsComplete;
  FGmail.OnSendMessage := GmailSendMessage;
  FGmail.OnGetAttachment := GmailGetAttachment;

  FOutlook := TTMSFNCCloudMicrosoftOutlookMail.Create(nil);
  FOutlook.OnConnected := OutlookConnected;
  FOutlook.OnGetMails := OutlookGetMails;
  FOutlook.OnSendMessage := OutlookSendMessage;
  FOutlook.OnGetAttachments := OutlookGetAttachments;

  FGCalendar := TTMSFNCCloudGoogleCalendar.Create(nil);
  FGCalendar.OnConnected := GCalendarConnected;
  FGCalendar.OnAddCalendarItem := GCalendarAdded;
  FOCalendar := TTMSFNCCloudMicrosoftOutlookCalendar.Create(nil);
  FOCalendar.OnConnected := OCalendarConnected;
  FOCalendar.OnGetCalendars := OCalendarGetCalendars;
  FOCalendar.OnAddCalendarItem := OCalendarAdded;

  FPushOver := TTMSFNCCloudPushOver.Create(nil);
  FPushOver.OnPushSucces := PushSuccess;
  FPushOver.OnPushError := PushError;

  FAI := TTMSMCPCloudAI.Create(nil);
  FAI.OnExecuted := AIExecuted;
  FTranslator := TTMSMCPCloudAI.Create(nil);
  FTranslator.OnExecuted := TranslatorExecuted;

  FDB := TFDConnection.Create(nil);
  FDB.Params.Values['DriverID'] := 'SQLite';
  FDB.Params.Values['LockingMode'] := 'Normal';
  FDB.LoginPrompt := False;
  FQuery := TFDQuery.Create(nil);
  FQuery.Connection := FDB;

  LoadRouting;
  LoadSettings;
  OpenHistory;
  LoadState;
  Log('Data folder: ' + FDataDir);

  // Reconnect the mailboxes with the saved tokens (no login page needed)
  ConnectMailbox(msGmail, False);
  ConnectMailbox(msOutlook, False);
  SetStatus('Ready.');
end;

destructor TTriageEngine.Destroy;
begin
  if FStateDirty then
    SaveState;
  FPendingGmailMessage.Free;
  FQuery.Free;
  FDB.Free;
  FTranslator.Free;
  FAI.Free;
  FPushOver.Free;
  FOCalendar.Free;
  FGCalendar.Free;
  FOutlook.Free;
  FGmail.Free;
  FTrashQueue.Free;
  FForwardQueue.Free;
  FDraftQueue.Free;
  FTriageQueue.Free;
  FLog.Free;
  FRouting.Free;
  FBookings.Free;
  FSpam.Free;
  FMails.Free;
  inherited;
end;

procedure TTriageEngine.Changed;
begin
  Inc(FVersion);
  FStateDirty := True;
end;

procedure TTriageEngine.Log(const AText: string);
var
  E: TLogEntry;
begin
  Inc(FLogSeq);
  E.Seq := FLogSeq;
  E.Time := Now;
  E.Text := AText;
  FLog.Add(E);
  if FLog.Count > MaxLogEntries then
    FLog.DeleteRange(0, FLog.Count - MaxLogEntries);
  Inc(FVersion);
  // Also on the console of the server
  WriteLn(ErrOutput, FormatDateTime('hh:nn:ss', E.Time) + '  ' + AText);
end;

procedure TTriageEngine.SetStatus(const AText: string);
begin
  FStatusText := AText;
  Inc(FVersion);
end;

function TTriageEngine.SettingsFile: string;
begin
  Result := TPath.Combine(FDataDir, 'settings.ini');
end;

function TTriageEngine.RoutingFile: string;
begin
  Result := TPath.Combine(FDataDir, 'routing.json');
end;

function TTriageEngine.APIKeysFile: string;
begin
  Result := TPath.Combine(FDataDir, 'aikeys.cfg');
end;

function TTriageEngine.StateFile: string;
begin
  Result := TPath.Combine(FDataDir, 'inbox.json');
end;

procedure TTriageEngine.LoadSettings;
var
  Ini: TMemIniFile;
  Svc: TTMSMCPCloudAIService;
  Model: string;
begin
  if TFile.Exists(APIKeysFile) then
    FAI.APIKeys.LoadFromFile(APIKeysFile, APIKeysPassword);

  Ini := TMemIniFile.Create(SettingsFile);
  try
    FSettings.GmailClientID := Ini.ReadString('Gmail', 'ClientID', '');
    FSettings.GmailSecret := Ini.ReadString('Gmail', 'Secret', '');
    FSettings.OutlookClientID := Ini.ReadString('Outlook', 'ClientID', '');
    FSettings.OutlookSecret := Ini.ReadString('Outlook', 'Secret', '');
    FSettings.CallbackURL := Ini.ReadString('OAuth', 'CallbackURL', 'http://127.0.0.1:8888');
    FSettings.MaxMails := Ini.ReadInteger('Mail', 'MaxMails', 25);
    FSettings.DryRun := Ini.ReadBool('Mail', 'DryRun', True);
    FSettings.PushoverToken := Ini.ReadString('Alerts', 'PushoverToken', '');
    FSettings.PushoverUser := Ini.ReadString('Alerts', 'PushoverUser', '');
    FSettings.AlertsEnabled := Ini.ReadBool('Alerts', 'Enabled', False);
    FSettings.TargetLanguage := Ini.ReadString('Translation', 'TargetLanguage', 'EN-GB');
    FSettings.AIService := Ini.ReadString('AI', 'Service', '');
    FSettings.AutoFetchMinutes := Ini.ReadInteger('Automation', 'FetchMinutes', 0);
    FSettings.AutoTriage := Ini.ReadBool('Automation', 'Triage', False);
    FSettings.AutoDrafts := Ini.ReadBool('Automation', 'Drafts', False);
    // The app stored 'Offline keyword rules (no AI)' as the offline choice
    if (FSettings.AIService <> '') and (IndexText(FSettings.AIService, AIServices) < 0) then
      FSettings.AIService := '';
    if SelectedService(Svc) then
    begin
      FAI.Service := Svc;
      Model := Ini.ReadString('AI', 'Model.' + FSettings.AIService, '');
      if Model <> '' then
        SetServiceModel(FAI, Svc, Model);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TTriageEngine.SaveSettings;
var
  Ini: TMemIniFile;
  Svc: TTMSMCPCloudAIService;
begin
  Ini := TMemIniFile.Create(SettingsFile);
  try
    Ini.WriteString('Gmail', 'ClientID', FSettings.GmailClientID);
    Ini.WriteString('Gmail', 'Secret', FSettings.GmailSecret);
    Ini.WriteString('Outlook', 'ClientID', FSettings.OutlookClientID);
    Ini.WriteString('Outlook', 'Secret', FSettings.OutlookSecret);
    Ini.WriteString('OAuth', 'CallbackURL', FSettings.CallbackURL);
    Ini.WriteInteger('Mail', 'MaxMails', FSettings.MaxMails);
    Ini.WriteBool('Mail', 'DryRun', FSettings.DryRun);
    Ini.WriteString('Alerts', 'PushoverToken', FSettings.PushoverToken);
    Ini.WriteString('Alerts', 'PushoverUser', FSettings.PushoverUser);
    Ini.WriteBool('Alerts', 'Enabled', FSettings.AlertsEnabled);
    // Translations moved from DeepL to the AI service: drop the old key
    Ini.DeleteKey('Translation', 'DeepLKey');
    Ini.WriteString('Translation', 'TargetLanguage', FSettings.TargetLanguage);
    Ini.WriteString('AI', 'Service', FSettings.AIService);
    if SelectedService(Svc) and (GetServiceModel(FAI, Svc) <> '') then
      Ini.WriteString('AI', 'Model.' + FSettings.AIService, GetServiceModel(FAI, Svc));
    Ini.WriteInteger('Automation', 'FetchMinutes', FSettings.AutoFetchMinutes);
    Ini.WriteBool('Automation', 'Triage', FSettings.AutoTriage);
    Ini.WriteBool('Automation', 'Drafts', FSettings.AutoDrafts);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
  // API keys are stored encrypted by the AI component itself
  FAI.APIKeys.SaveToFile(APIKeysFile, APIKeysPassword);
end;

procedure TTriageEngine.LoadRouting;
begin
  if TFile.Exists(RoutingFile) then
  begin
    try
      FRouting.LoadFromFile(RoutingFile);
    except
      on E: Exception do
      begin
        Log('Could not read the routing table, using defaults: ' + E.Message);
        FRouting.LoadDefaults;
      end;
    end;
  end
  else
    FRouting.LoadDefaults;
end;

procedure TTriageEngine.LoadState;
var
  Root: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONValue;

  procedure LoadList(AList: TTriageMailList; const AName: string);
  var
    Arr: TJSONArray;
    Item: TJSONValue;
    M: TTriageMail;
  begin
    if not TJSONObject(Root).TryGetValue<TJSONArray>(AName, Arr) then
      Exit;
    for Item in Arr do
      if Item is TJSONObject then
      begin
        M := MailFromJSON(TJSONObject(Item));
        // Work that was in progress when the server stopped starts over
        case M.Status of
          tsQueued, tsAnalyzing: M.Status := tsNew;
          tsForwarding: M.Status := tsTriaged;
        end;
        if M.ReplyStatus = rsCreating then
          M.ReplyStatus := rsReady;
        AList.Add(M);
        FNextID := Max(FNextID, M.ID + 1);
      end;
  end;

begin
  // The inbox survives a restart of the server
  if not TFile.Exists(StateFile) then
  begin
    SeedBookings;
    Exit;
  end;
  try
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(StateFile, TEncoding.UTF8));
    try
      if Root is TJSONObject then
      begin
        LoadList(FMails, 'mails');
        LoadList(FSpam, 'spam');
        FNextID := Max(FNextID, TJSONObject(Root).GetValue<Integer>('next_id', 1));
        if TJSONObject(Root).TryGetValue<TJSONArray>('bookings', Arr) then
        begin
          for Item in Arr do
            if Item is TJSONObject then
              FBookings.Add(BookingFromJSON(TJSONObject(Item)));
        end
        else
          SeedBookings;
      end;
    finally
      Root.Free;
    end;
    Log(Format('Inbox restored: %d mail(s), %d spam', [FMails.Count, FSpam.Count]));
  except
    on E: Exception do
      Log('Could not restore the inbox: ' + E.Message);
  end;
end;

procedure TTriageEngine.SaveState;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  M: TTriageMail;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('next_id', TJSONNumber.Create(FNextID));
    Arr := TJSONArray.Create;
    for M in FMails do
      Arr.AddElement(MailToJSON(M, mjState));
    Root.AddPair('mails', Arr);
    Arr := TJSONArray.Create;
    for M in FSpam do
      Arr.AddElement(MailToJSON(M, mjState));
    Root.AddPair('spam', Arr);
    Root.AddPair('bookings', BookingsJSON);
    // Write to a temporary file first, so a crash never leaves half a file
    TFile.WriteAllText(StateFile + '.tmp', Root.ToJSON, TEncoding.UTF8);
    if TFile.Exists(StateFile) then
      TFile.Delete(StateFile);
    TFile.Move(StateFile + '.tmp', StateFile);
    FStateDirty := False;
    FLastSave := Now;
  except
    on E: Exception do
    begin
      FLastSave := Now; // retry later, not on every tick
      Log('Could not save the inbox: ' + E.Message);
    end;
  end;
  Root.Free;
end;

procedure TTriageEngine.Tick;
begin
  // Save the inbox at most every two seconds
  if FStateDirty and (SecondsBetween(Now, FLastSave) >= 2) then
    SaveState;

  // A connect that never answered (login page closed, no network) gives up
  if (FConnecting[msGmail] > 0) and (SecondsBetween(Now, FConnecting[msGmail]) > ConnectTimeoutSec) then
  begin
    FConnecting[msGmail] := 0;
    Log('Gmail: no answer to the connect request');
    Changed;
  end;
  if (FConnecting[msOutlook] > 0) and (SecondsBetween(Now, FConnecting[msOutlook]) > ConnectTimeoutSec) then
  begin
    FConnecting[msOutlook] := 0;
    Log('Outlook: no answer to the connect request');
    Changed;
  end;

  // Automation: fetch on a schedule, then triage once the attachments are in
  if (FSettings.AutoFetchMinutes > 0) and (FFetchPending = 0)
    and (FConnected[msGmail] or FConnected[msOutlook])
    and (MinutesBetween(Now, FLastFetch) >= FSettings.AutoFetchMinutes) then
  begin
    Log('Automatic fetch');
    FetchMails('all', 0);
  end;
  if FTriageAfterFetch and (FFetchPending = 0) and (FAttachmentsPending = 0) then
  begin
    FTriageAfterFetch := False;
    if QueueTriage(0) > 0 then
      Log('Automatic triage of the new mails');
  end;
end;

procedure TTriageEngine.StartBatch(ACount: Integer);
begin
  // One progress figure for all queued work: it starts over when everything is done
  if not IsBusy then
  begin
    FBatchTotal := 0;
    FBatchDone := 0;
  end;
  Inc(FBatchTotal, ACount);
  Inc(FVersion);
end;

procedure TTriageEngine.StepBatch;
begin
  Inc(FBatchDone);
  SetStatus(Format('Processing %d / %d ...', [Min(FBatchDone, FBatchTotal), FBatchTotal]));
end;

function TTriageEngine.IsBusy: Boolean;
begin
  Result := (FTriageQueue.Count > 0) or (FActiveTriageID <> 0) or (FDraftQueue.Count > 0) or (FActiveDraftID <> 0)
    or (FForwardQueue.Count > 0) or (FActiveForwardID <> 0) or (FTrashQueue.Count > 0) or (FActiveTrashID <> 0);
end;

function TTriageEngine.IsFetching: Boolean;
begin
  Result := (FFetchPending > 0) or (FAttachmentsPending > 0);
end;

function TTriageEngine.IsTriaging: Boolean;
begin
  Result := (FTriageQueue.Count > 0) or (FActiveTriageID <> 0);
end;

function TTriageEngine.FindMail(AID: Integer): TTriageMail;
begin
  Result := FMails.FindByID(AID);
  if not Assigned(Result) then
    Result := FSpam.FindByID(AID);
end;

function TTriageEngine.MailByID(AID: Integer): TTriageMail;
begin
  Result := FindMail(AID);
  if not Assigned(Result) then
    raise Exception.CreateFmt('Unknown mail id %d: call list_mails or list_spam for the ids', [AID]);
end;

{ ------------------------------------------------------------------------- }
{ AI service                                                                }
{ ------------------------------------------------------------------------- }

function TTriageEngine.AIServices: TArray<string>;
var
  Services: TStringList;
  I: Integer;
begin
  // GetServices returns the list owned by the component: Objects[] holds the service ordinal
  Services := FAI.GetServices;
  SetLength(Result, Services.Count);
  for I := 0 to Services.Count - 1 do
    Result[I] := Services[I];
end;

function TTriageEngine.SelectedService(out AService: TTMSMCPCloudAIService): Boolean;
var
  Services: TStringList;
  I: Integer;
begin
  Result := False;
  if FSettings.AIService = '' then
    Exit;
  Services := FAI.GetServices;
  I := Services.IndexOf(FSettings.AIService);
  if I < 0 then
    Exit;
  AService := TTMSMCPCloudAIService(NativeInt(Services.Objects[I]));
  Result := True;
end;

function TTriageEngine.UseAI: Boolean;
var
  Svc: TTMSMCPCloudAIService;
begin
  Result := SelectedService(Svc);
end;

function TTriageEngine.ServiceAPIKey: string;
var
  Svc: TTMSMCPCloudAIService;
begin
  if SelectedService(Svc) then
    Result := GetServiceKey(FAI.APIKeys, Svc)
  else
    Result := '';
end;

function TTriageEngine.EngineName: string;
begin
  if UseAI then
    Result := FSettings.AIService
  else
    Result := 'offline rules';
end;

{ ------------------------------------------------------------------------- }
{ Mailboxes                                                                 }
{ ------------------------------------------------------------------------- }

function TTriageEngine.IsConnected(ASource: TMailSource): Boolean;
begin
  Result := FConnected[ASource];
end;

function TTriageEngine.IsConnecting(ASource: TMailSource): Boolean;
begin
  Result := FConnecting[ASource] > 0;
end;

procedure TTriageEngine.SetupCloud(ACloud: TTMSFNCCustomCloudOAuth; const ATokenFile, AClientID, ASecret: string);
var
  Cloud: TOAuthAccess;
begin
  Cloud := TOAuthAccess(ACloud);
  Cloud.PersistTokens.Key := TPath.Combine(FDataDir, ATokenFile);
  Cloud.LoadTokens;
  Cloud.Authentication.ClientID := AClientID.Trim;
  Cloud.Authentication.Secret := ASecret.Trim;
  Cloud.Authentication.CallBackURL := FSettings.CallbackURL.Trim;
end;

function TTriageEngine.ConnectMailbox(ASource: TMailSource; AInteractive: Boolean): string;
var
  Cloud: TOAuthAccess;
begin
  case ASource of
    msGmail:
      begin
        SetupCloud(FGmail, 'gmail.ini', FSettings.GmailClientID, FSettings.GmailSecret);
        Cloud := TOAuthAccess(FGmail);
        if (FSettings.GmailClientID = '') or (FSettings.GmailSecret = '') then
          Exit('Set gmail_client_id and gmail_secret first (update_setting).');
      end;
    msOutlook:
      begin
        SetupCloud(FOutlook, 'outlook.ini', FSettings.OutlookClientID, FSettings.OutlookSecret);
        Cloud := TOAuthAccess(FOutlook);
        if FSettings.OutlookClientID = '' then
          Exit('Set outlook_client_id (and outlook_secret) first (update_setting).');
      end;
  else
    Exit('Only gmail and outlook are mailboxes.');
  end;
  if FSettings.CallbackURL = '' then
    Exit('Set callback_url first (update_setting).');

  // Without saved tokens Connect opens the login page in a browser on the
  // machine that runs this server; only do that when asked for
  if (Cloud.Authentication.AccessToken = '') and not AInteractive then
    Exit(SourceNames[ASource] + ' has no saved login: connect it once interactively.');

  FConnected[ASource] := False;
  FConnecting[ASource] := Now;
  Changed;
  if Cloud.Authentication.AccessToken = '' then
    Log(SourceNames[ASource] + ': waiting for the login in the browser on the server machine')
  else
    Log(SourceNames[ASource] + ': connecting with the saved login');
  Cloud.Connect;
  Result := '';
end;

procedure TTriageEngine.GmailConnected(Sender: TObject);
begin
  FGmail.SaveTokens;
  FConnected[msGmail] := True;
  FConnecting[msGmail] := 0;
  Log('Connected to Gmail.');
  Changed;
end;

procedure TTriageEngine.OutlookConnected(Sender: TObject);
begin
  FOutlook.SaveTokens;
  FConnected[msOutlook] := True;
  FConnecting[msOutlook] := 0;
  Log('Connected to Outlook.');
  Changed;
end;

function TTriageEngine.LoadDemo: Integer;
var
  Demo: TTriageMailList;
  M: TTriageMail;
  Count: Integer;
begin
  // Load into a temporary non-owning list first so duplicates are skipped
  Demo := TTriageMailList.Create(False);
  try
    for M in FMails do
      Demo.Add(M);
    for M in FSpam do
      Demo.Add(M);
    Count := Demo.Count;
    LoadDemoMails(Demo, FNextID);
    Result := Demo.Count - Count;
    while Demo.Count > Count do
    begin
      AddMail(Demo[Count]);
      Demo.Delete(Count);
    end;
  finally
    Demo.Free;
  end;
  Log(Format('Demo inbox loaded: %d new mail(s).', [Result]));
  if (Result > 0) and FSettings.AutoTriage then
    QueueTriage(0);
end;

function TTriageEngine.FetchMails(const ASource: string; AMax: Integer): string;
var
  Src: string;
begin
  Src := ASource.Trim.ToLower;
  if Src = '' then
    Src := 'all';
  if AMax <= 0 then
    AMax := FSettings.MaxMails;
  if Src = 'demo' then
    Exit(Format('%d demo mail(s) added', [LoadDemo]));

  Result := '';
  FLastFetch := Now;
  if (Src = 'gmail') or (Src = 'all') then
    if FConnected[msGmail] then
    begin
      Inc(FFetchPending);
      SetStatus('Fetching Gmail inbox...');
      FGmail.GetMails('INBOX', AMax, False);
    end
    else if Src = 'gmail' then
      Result := 'Gmail is not connected (connect_mailbox). ';
  if (Src = 'outlook') or (Src = 'all') then
    if FConnected[msOutlook] then
    begin
      Inc(FFetchPending);
      SetStatus('Fetching Outlook inbox...');
      FOutlook.GetMails('Inbox', AMax);
    end
    else if Src = 'outlook' then
      Result := Result + 'Outlook is not connected (connect_mailbox). ';
  if (Src = 'all') and (FFetchPending = 0) then
    Result := 'No mailbox is connected: connect_mailbox first, or fetch source "demo". ';
  if FSettings.AutoTriage and (FFetchPending > 0) then
    FTriageAfterFetch := True;
  Result := Result.Trim;
  Changed;
end;

procedure TTriageEngine.AddMail(AMail: TTriageMail);
begin
  LookupHistory(AMail);
  FMails.Add(AMail);
  Changed;
end;

procedure TTriageEngine.GmailGetMails(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
begin
  // An empty inbox (or a failed request) never fires OnGetMailsComplete
  if not ARequestResult.Success or not ARequestResult.ResultString.Contains('"messages"') then
  begin
    if not ARequestResult.Success then
      Log('Gmail: fetching mails failed: ' + Copy(ARequestResult.ResultString, 1, 200))
    else
      Log('Gmail: 0 new mail(s).');
    FFetchPending := Max(0, FFetchPending - 1);
    Changed;
  end;
end;

procedure TTriageEngine.GmailGetMailsComplete(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
var
  I, J, Added: Integer;
  GM: TTMSFNCCloudGoogleGmailMessage;
  M: TTriageMail;
begin
  Added := 0;
  for I := 0 to FGmail.Mails.Count - 1 do
  begin
    GM := FGmail.Mails[I];
    if FMails.ContainsSourceID(msGmail, GM.ID) or FSpam.ContainsSourceID(msGmail, GM.ID) then
      Continue;
    M := MailFromGmail(GM);
    M.ID := FNextID;
    Inc(FNextID);
    AddMail(M);
    Inc(Added);
    // Photos and PDFs go to the AI together with the mail
    for J := 0 to GM.Attachments.Count - 1 do
      if IsAIAttachment(GM.Attachments[J].FileName) then
      begin
        Inc(FAttachmentsPending);
        FGmail.GetAttachment(GM.Attachments[J]);
      end;
  end;
  FFetchPending := Max(0, FFetchPending - 1);
  Log(Format('Gmail: %d new mail(s).', [Added]));
  SetStatus(Format('Gmail: %d new mail(s) fetched.', [Added]));
  Changed;
end;

procedure TTriageEngine.OutlookGetMails(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
var
  I, Added: Integer;
  OM: TTMSFNCCloudMicrosoftOutlookMailItem;
  M: TTriageMail;
begin
  FFetchPending := Max(0, FFetchPending - 1);
  Changed;
  if not ARequestResult.Success then
  begin
    Log('Outlook: fetching mails failed: ' + Copy(ARequestResult.ResultString, 1, 200));
    Exit;
  end;

  Added := 0;
  for I := 0 to FOutlook.Mails.Count - 1 do
  begin
    OM := FOutlook.Mails[I];
    if FMails.ContainsSourceID(msOutlook, OM.ID) or FSpam.ContainsSourceID(msOutlook, OM.ID) then
      Continue;
    M := MailFromOutlook(OM);
    M.ID := FNextID;
    Inc(FNextID);
    AddMail(M);
    Inc(Added);
    if OM.HasAttachments then
    begin
      Inc(FAttachmentsPending);
      FOutlook.GetAttachments(OM);
    end;
  end;
  Log(Format('Outlook: %d new mail(s).', [Added]));
  SetStatus(Format('Outlook: %d new mail(s) fetched.', [Added]));
end;

procedure TTriageEngine.GmailGetAttachment(Sender: TObject; const AMessage: TTMSFNCCloudGoogleGmailMessage;
  const AAttachment: TTMSFNCCloudGoogleGmailMessageAttachment; const ARequestResult: TTMSFNCCloudBaseRequestResult);
var
  Path: string;
  M: TTriageMail;
begin
  FAttachmentsPending := Max(0, FAttachmentsPending - 1);
  if not ARequestResult.Success then
  begin
    Log('Gmail: could not download ' + AAttachment.FileName);
    Exit;
  end;
  Path := AttachmentPath(FDataDir, AMessage.ID, AAttachment.FileName);
  AAttachment.SaveToFile(Path);
  for M in FMails do
    if (M.Source = msGmail) and (M.SourceID = AMessage.ID) then
      M.Attachments := M.Attachments + [Path];
  Changed;
end;

procedure TTriageEngine.OutlookGetAttachments(Sender: TObject; const AMail: TTMSFNCCloudMicrosoftOutlookMailItem;
  const ARequestResult: TTMSFNCCloudBaseRequestResult);
var
  I: Integer;
  Path: string;
  M: TTriageMail;
begin
  FAttachmentsPending := Max(0, FAttachmentsPending - 1);
  if not ARequestResult.Success then
    Exit;
  for I := 0 to AMail.Attachments.Count - 1 do
    if IsAIAttachment(AMail.Attachments[I].Name) then
    begin
      Path := AttachmentPath(FDataDir, AMail.ID, AMail.Attachments[I].Name);
      AMail.Attachments[I].SaveToFile(Path);
      for M in FMails do
        if (M.Source = msOutlook) and (M.SourceID = AMail.ID) then
          M.Attachments := M.Attachments + [Path];
    end;
  Changed;
end;

function TTriageEngine.MailboxFor(AMail: TTriageMail): TMailSource;
begin
  // Use the mailbox the mail came from. Demo mails use the first connected
  // mailbox; msDemo as result means: nothing connected, simulate.
  Result := AMail.Source;
  if Result = msDemo then
  begin
    if FConnected[msGmail] then
      Result := msGmail
    else if FConnected[msOutlook] then
      Result := msOutlook;
  end;
  if ((Result = msGmail) and not FConnected[msGmail]) or ((Result = msOutlook) and not FConnected[msOutlook]) then
    Result := msDemo;
end;

{ ------------------------------------------------------------------------- }
{ Triage                                                                    }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.QueueTriageMail(AMail: TTriageMail);
begin
  AMail.Status := tsQueued;
  AMail.StatusInfo := '';
  FTriageQueue.Enqueue(AMail.ID);
end;

function TTriageEngine.QueueTriage(AID: Integer): Integer;
var
  M: TTriageMail;
begin
  // AID = 0: every new mail and every mail that failed; otherwise that one mail (again)
  if UseAI and ServiceNeedsKey(FAI.Service) and (ServiceAPIKey = '') then
    raise Exception.CreateFmt('No API key for %s: set ai_api_key (Settings page), or set ai_service to "offline"', [FSettings.AIService]);

  // The routing table may have changed: rebuild the system prompt each batch
  FAI.SystemRole.Text := BuildSystemPrompt(FRouting);
  Result := 0;
  if AID <> 0 then
  begin
    M := FMails.FindByID(AID);
    if not Assigned(M) then
    begin
      if Assigned(FSpam.FindByID(AID)) then
        raise Exception.Create('This mail is on the spam list: call mark_not_spam first');
      raise Exception.CreateFmt('Unknown mail id %d', [AID]);
    end;
    if M.Status in [tsQueued, tsAnalyzing, tsForwarding] then
      raise Exception.Create('This mail is being processed, try again in a moment');
    if M.Status = tsForwarded then
      raise Exception.Create('This mail was already forwarded');
    QueueTriageMail(M);
    Result := 1;
  end
  else
    for M in FMails do
      if M.Status in [tsNew, tsError] then
      begin
        QueueTriageMail(M);
        Inc(Result);
      end;

  if Result = 0 then
    Exit;
  Log(Format('Triaging %d mail(s) with %s...', [Result, EngineName]));
  StartBatch(Result);
  Changed;
  ProcessNextTriage;
end;

procedure TTriageEngine.ProcessNextTriage;
var
  M: TTriageMail;
  Path: string;
begin
  if FActiveTriageID <> 0 then
    Exit;

  while FTriageQueue.Count > 0 do
  begin
    M := FMails.FindByID(FTriageQueue.Dequeue);
    if not Assigned(M) or (M.Status <> tsQueued) then
      Continue;

    if not UseAI then
    begin
      ApplyKeywordTriage(M, FRouting);
      M.Engine := 'Keyword rules (offline)';
      M.Status := tsTriaged;
      if M.IsSpam then
        MoveToSpam(M)
      else
      begin
        ApplyCustomerHistory(M);
        KeywordCancellation(M);
        AfterTriage(M);
      end;
      StepBatch;
      Changed;
      Continue;
    end;

    // One request at a time: the mail ID travels along as the request id
    M.Status := tsAnalyzing;
    Changed;
    FActiveTriageID := M.ID;
    FAI.Context.Text := BuildMailPrompt(M, FreeSlotsText(M), BookingsText(M));
    // Photos and PDFs travel with the request; the model describes them in "attachments".
    // ClearFiles only forgets uploaded file IDs: the files AddFile collected must go
    // too, or every later mail is sent with the attachments of the earlier ones
    FAI.ClearFiles;
    FAI.Files.Clear;
    for Path in M.Attachments do
      if TFile.Exists(Path) then
        FAI.AddFile(Path, FileExtToFileType(Path));
    try
      FAI.Execute(M.ID.ToString);
      Exit; // continues in AIExecuted
    except
      on E: Exception do
      begin
        FActiveTriageID := 0;
        M.Status := tsError;
        M.StatusInfo := E.Message;
        FLastError := Format('#%d triage: %s', [M.ID, E.Message]);
        Log('AI error: ' + E.Message);
        StepBatch;
        Changed;
      end;
    end;
  end;

  SetStatus('Triage finished.');
end;

procedure TTriageEngine.AIExecuted(Sender: TObject; AResponse: TTMSMCPCloudAIResponse; AHttpStatusCode: Integer;
  AHttpResult: string);
var
  M: TTriageMail;
  ID: Integer;
begin
  ID := FActiveTriageID;
  if Assigned(AResponse) then
    ID := StrToIntDef(AResponse.Id, ID);
  M := FMails.FindByID(ID);

  if Assigned(M) then
  begin
    if (AHttpStatusCode div 100 = 2) and Assigned(AResponse)
      and ApplyAIResponse(M, AResponse.Content.Text, FRouting) then
    begin
      M.Engine := EngineName;
      if AResponse.ServiceModel <> '' then
        M.Engine := M.Engine + ' (' + AResponse.ServiceModel + ')';
      M.Status := tsTriaged;
      if M.IsSpam then
        MoveToSpam(M)
      else
      begin
        ApplyCustomerHistory(M);
        Log(Format('#%d %s -> %s / %s (%d%%)', [M.ID, M.Subject, DepartmentNames[M.Department], M.Brand, M.Confidence]));
        AfterTriage(M);
      end;
    end
    else
    begin
      M.Status := tsError;
      if (AHttpStatusCode div 100 = 2) and Assigned(AResponse) then
        M.StatusInfo := 'Could not parse AI answer: ' + Copy(AResponse.Content.Text, 1, 300)
      else
        M.StatusInfo := Format('HTTP %d: %s', [AHttpStatusCode, Copy(AHttpResult, 1, 300)]);
      FLastError := Format('#%d triage: %s', [M.ID, M.StatusInfo]);
      Log(Format('#%d error: %s', [M.ID, M.StatusInfo]));
    end;
  end;

  FActiveTriageID := 0;
  StepBatch;
  Changed;
  // Start the next request outside of this event handler
  TThread.ForceQueue(nil, QueuedNextTriage);
end;

procedure TTriageEngine.QueuedNextTriage;
begin
  ProcessNextTriage;
end;

procedure TTriageEngine.AfterTriage(AMail: TTriageMail);
var
  B: TWorkshopBooking;
begin
  // The customer cancelled or moved one of their bookings: free its hour first.
  // Only a booking of this customer, whatever the triage came up with
  if AMail.CancelBookingStart > 0 then
  begin
    for B in CustomerBookings(AMail) do
      if Abs(B.Start - AMail.CancelBookingStart) < 1 / 2880 then
      begin
        CancelBooking(B.Start);
        AMail.Reason := Trim(AMail.Reason + Format(' Cancelled the existing booking of %s (%s).',
          [FormatDateTime('ddd dd/mm hh:nn', B.Start), B.Vehicle]));
      end;
    AMail.CancelBookingStart := 0;
  end;

  // Keep suggested workshop slots apart from each other and from the bookings
  if AMail.AppointmentStart > 0 then
    AMail.AppointmentStart := NextFreeSlot(AMail.AppointmentStart, AMail);

  if (AMail.Priority = PriorityUrgent) and not AMail.Alerted then
    SendUrgentAlert(AMail);
  SaveHistory(AMail);
  if FSettings.AutoDrafts and (AMail.ReplyStatus in [rsReady, rsError]) then
    QueueDrafts(AMail.ID);
  Changed;
end;

procedure TTriageEngine.SendUrgentAlert(AMail: TTriageMail);
var
  Text: string;
begin
  AMail.Alerted := True;
  Text := AMail.Summary + sLineBreak + AMail.FromDisplay + sLineBreak + 'Handler: ' + AMail.HandlerName;
  if FSettings.AlertsEnabled and (FSettings.PushoverToken <> '') and (FSettings.PushoverUser <> '') then
  begin
    FPushOver.APIKey := FSettings.PushoverToken;
    FPushOver.PushMessage(FSettings.PushoverUser, 'URGENT: ' + AMail.Subject, Text);
    Log(Format('#%d urgent alert sent to the on-call mechanic', [AMail.ID]));
  end
  else
    Log(Format('#%d [simulated] urgent alert: %s (set alerts_enabled, pushover_token and pushover_user to send it)',
      [AMail.ID, AMail.Subject]));
end;

procedure TTriageEngine.RecordTriage(AMail: TTriageMail; ADepartment: TDepartment; const ABrand, APriority,
  ASummary, AReply: string);
begin
  // The classification of an MCP client's model
  if FSpam.Contains(AMail) then
    raise Exception.Create('This mail is on the spam list: call mark_not_spam first');
  if AMail.Status in [tsAnalyzing, tsForwarding] then
    raise Exception.Create('This mail is being processed, try again in a moment');
  AMail.IsSpam := False;
  AMail.Department := ADepartment;
  AMail.Brand := FRouting.NormalizeBrand(ABrand);
  AMail.Priority := NormalizePriority(APriority);
  AMail.Summary := ASummary;
  AMail.Reason := 'Classified by the MCP client';
  AMail.Engine := 'MCP client';
  AMail.Confidence := 100;
  AssignHandler(AMail, FRouting);
  if AReply.Trim <> '' then
    AMail.ReplyDraft := AReply
  else
    AMail.ReplyDraft := TemplateReply(AMail);
  AMail.ReplyStatus := rsReady;
  if AMail.Department <> dpMaintenance then
    AMail.AppointmentStart := 0;
  AMail.Status := tsTriaged;
  AMail.StatusInfo := '';
  ApplyCustomerHistory(AMail);
  Log(Format('#%d %s -> %s / %s (MCP client)', [AMail.ID, AMail.Subject, DepartmentNames[AMail.Department], AMail.Brand]));
  AfterTriage(AMail);
end;

procedure TTriageEngine.Reroute(AMail: TTriageMail; ADepartment: TDepartment; const ABrand, AEngine: string);
begin
  // A person (dashboard) or the MCP client moves a mail to another department / brand
  if FSpam.Contains(AMail) then
    raise Exception.Create('This mail is on the spam list: call mark_not_spam first');
  if AMail.Status in [tsAnalyzing, tsForwarding] then
    raise Exception.Create('This mail is being processed, try again in a moment');
  AMail.Department := ADepartment;
  if ABrand <> '' then
    AMail.Brand := FRouting.NormalizeBrand(ABrand)
  else if AMail.Brand = '' then
    AMail.Brand := OtherBrand;
  if AMail.Priority = '' then
    AMail.Priority := PriorityNormal;
  AssignHandler(AMail, FRouting);
  if AMail.Department <> dpMaintenance then
    AMail.AppointmentStart := 0;   // only workshop visits keep an appointment
  AMail.Confidence := 100;
  AMail.Engine := AEngine;
  if AMail.Reason = '' then
    AMail.Reason := 'Classified manually.';
  if AMail.ReplyDraft = '' then
  begin
    AMail.ReplyDraft := TemplateReply(AMail);
    AMail.ReplyStatus := rsReady;
  end;
  if not AMail.IsTriaged then
    AMail.Status := tsTriaged;
  Log(Format('#%d re-routed to %s / %s -> %s', [AMail.ID, DepartmentNames[AMail.Department], AMail.Brand, AMail.HandlerName]));
  AfterTriage(AMail);
end;

procedure TTriageEngine.UpdateReply(AMail: TTriageMail; const AText: string);
begin
  if not AMail.IsTriaged then
    raise Exception.Create('Triage the mail first');
  if AMail.ReplyStatus = rsCreating then
    raise Exception.Create('The draft is being saved, try again in a moment');
  // The edited text replaces the AI draft; [SIGNATURE] is still filled in when present
  AMail.ReplyDraft := AText;
  AMail.ReplyStatus := rsReady;
  AMail.ReplyInfo := '';
  Changed;
end;

{ ------------------------------------------------------------------------- }
{ Reply drafts                                                              }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.QueueDraftMail(AMail: TTriageMail);
begin
  AMail.ReplyStatus := rsCreating;
  AMail.ReplyInfo := '';
  FDraftQueue.Enqueue(AMail.ID);
end;

function TTriageEngine.QueueDrafts(AID: Integer): Integer;
var
  M: TTriageMail;
begin
  Result := 0;
  if AID <> 0 then
  begin
    M := MailByID(AID);
    if not M.IsTriaged or (M.ReplyDraft = '') then
      raise Exception.Create('Triage the mail first');
    if M.ReplyStatus = rsCreating then
      Exit;
    QueueDraftMail(M);
    Result := 1;
  end
  else
    for M in FMails do
      if M.IsTriaged and (M.ReplyDraft <> '') and (M.ReplyStatus in [rsReady, rsError]) then
      begin
        QueueDraftMail(M);
        Inc(Result);
      end;
  if Result = 0 then
    Exit;
  StartBatch(Result);
  Changed;
  ProcessNextDraft;
end;

procedure TTriageEngine.ProcessNextDraft;
var
  M: TTriageMail;
  Done: TDraftDoneProc;
begin
  if FActiveDraftID <> 0 then
    Exit;

  Done :=
    procedure(ASuccess: Boolean; const AInfo, ADraftID: string; ADraftGone: Boolean)
    begin
      FDraftSuccess := ASuccess;
      FDraftInfo := AInfo;
      FDraftResultID := ADraftID;
      FDraftGone := ADraftGone;
      TThread.ForceQueue(nil, FinishDraft);
    end;

  while FDraftQueue.Count > 0 do
  begin
    M := FMails.FindByID(FDraftQueue.Dequeue);
    if not Assigned(M) or (M.ReplyStatus <> rsCreating) then
      Continue;

    // A saved draft is updated in the mailbox that holds it, as long as that
    // mailbox is connected; otherwise a new draft goes to the current mailbox
    FActiveDraftVia := MailboxFor(M);
    if (M.DraftID <> '') and (M.DraftVia <> FActiveDraftVia) and FConnected[M.DraftVia] then
      FActiveDraftVia := M.DraftVia;
    if FActiveDraftVia = msDemo then
    begin
      M.ReplyStatus := rsSimulated;
      M.ReplyInfo := 'No mailbox connected, draft not saved.';
      Log(Format('#%d [simulated] reply draft to %s', [M.ID, M.FromEmail]));
      StepBatch;
      Changed;
      Continue;
    end;

    if M.DraftVia <> FActiveDraftVia then
      M.DraftID := '';
    FActiveDraftUpdate := M.DraftID <> '';
    FActiveDraftID := M.ID;
    try
      case FActiveDraftVia of
        msGmail: SaveGmailDraft(FGmail, M, Done);
        msOutlook: SaveOutlookDraft(FOutlook, M, Done);
      end;
      Exit; // continues in FinishDraft
    except
      on E: Exception do
      begin
        FActiveDraftID := 0;
        M.ReplyStatus := rsError;
        M.ReplyInfo := E.Message;
        FLastError := Format('#%d draft: %s', [M.ID, E.Message]);
        StepBatch;
        Changed;
      end;
    end;
  end;
end;

procedure TTriageEngine.FinishDraft;
var
  M: TTriageMail;
begin
  M := FMails.FindByID(FActiveDraftID);
  FActiveDraftID := 0;
  if Assigned(M) and FDraftGone and (M.ReplyStatus = rsCreating) then
  begin
    // The draft was sent or deleted in the mailbox: save the reply as a new
    // draft. Same mail, same batch step, so no StepBatch here.
    M.DraftID := '';
    Log(Format('#%d reply draft no longer in %s, saving a new one', [M.ID, SourceNames[FActiveDraftVia]]));
    FDraftQueue.Enqueue(M.ID);
    Changed;
    ProcessNextDraft;
    Exit;
  end;
  if Assigned(M) then
  begin
    if FDraftSuccess then
    begin
      M.ReplyStatus := rsCreated;
      if FDraftResultID <> '' then
      begin
        M.DraftID := FDraftResultID;
        M.DraftVia := FActiveDraftVia;
      end;
      if FActiveDraftUpdate then
      begin
        M.ReplyInfo := 'Draft updated in the ' + SourceNames[FActiveDraftVia] + ' Drafts folder.';
        Log(Format('#%d reply draft updated in %s', [M.ID, SourceNames[FActiveDraftVia]]));
      end
      else
      begin
        M.ReplyInfo := 'Saved in the ' + SourceNames[FActiveDraftVia] + ' Drafts folder.';
        Log(Format('#%d reply draft saved in %s', [M.ID, SourceNames[FActiveDraftVia]]));
      end;
    end
    else
    begin
      M.ReplyStatus := rsError;
      M.ReplyInfo := Copy(FDraftInfo, 1, 300);
      FLastError := Format('#%d draft: %s', [M.ID, M.ReplyInfo]);
      Log(Format('#%d reply draft failed: %s', [M.ID, M.ReplyInfo]));
    end;
  end;
  StepBatch;
  Changed;
  ProcessNextDraft;
end;

{ ------------------------------------------------------------------------- }
{ Forwarding and filing                                                     }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.QueueForwardMail(AMail: TTriageMail);
begin
  AMail.Status := tsForwarding;
  AMail.StatusInfo := '';
  FForwardQueue.Enqueue(AMail.ID);
end;

function TTriageEngine.QueueForwards(AID: Integer; AConfirmSend: Boolean): Integer;
var
  M: TTriageMail;
  Real: Boolean;
begin
  // Mails are only really sent when dry run is off AND the caller confirmed it
  Real := AConfirmSend and not FSettings.DryRun;
  Result := 0;
  if AID <> 0 then
  begin
    M := MailByID(AID);
    if FSpam.Contains(M) then
      raise Exception.Create('This mail is on the spam list and is not forwarded');
    if not M.IsTriaged or (M.HandlerEmail = '') then
      raise Exception.Create('Triage the mail first');
    if M.Status = tsForwarding then
      Exit;
    if M.Status = tsForwarded then
      raise Exception.Create('This mail was already forwarded');
    QueueForwardMail(M);
    Result := 1;
  end
  else
    for M in FMails do
      if (M.Status in [tsTriaged, tsSimulated]) and (M.HandlerEmail <> '') then
      begin
        QueueForwardMail(M);
        Inc(Result);
      end;
  if Result = 0 then
    Exit;
  // The queue remembers per mail whether it is a dry run
  for M in FMails do
    if M.Status = tsForwarding then
      M.StatusInfo := IfThen(Real, '', 'dry run');
  StartBatch(Result);
  Changed;
  ProcessNextForward;
end;

procedure TTriageEngine.ProcessNextForward;
var
  M: TTriageMail;
  Via: TMailSource;
  Recipients: TStringList;
  Path: string;
begin
  if FActiveForwardID <> 0 then
    Exit;

  while FForwardQueue.Count > 0 do
  begin
    M := FMails.FindByID(FForwardQueue.Dequeue);
    if not Assigned(M) or (M.Status <> tsForwarding) then
      Continue;

    Via := MailboxFor(M);
    if (M.StatusInfo = 'dry run') or (Via = msDemo) then
    begin
      M.Status := tsSimulated;
      M.StatusInfo := 'Would be sent to ' + M.HandlerName + ' <' + M.HandlerEmail + '>: ' + BuildForwardSubject(M);
      if M.Source in [msGmail, msOutlook] then
        M.StatusInfo := M.StatusInfo + ', then moved out of the inbox to ' + FilingPath(M);
      Log(Format('#%d [dry run] -> %s <%s>', [M.ID, M.HandlerName, M.HandlerEmail]));
      StepBatch;
      Changed;
      Continue;
    end;

    M.StatusInfo := '';
    FActiveForwardID := M.ID;
    try
      case Via of
        msGmail:
          begin
            FreeAndNil(FPendingGmailMessage);
            FPendingGmailMessage := TTMSFNCCloudGoogleGmailMessage.Create;
            FPendingGmailMessage.ToRecipients.Add(M.HandlerEmail);
            FPendingGmailMessage.Subject := BuildForwardSubject(M);
            FPendingGmailMessage.Body := BuildForwardHtml(M);
            FPendingGmailMessage.MessageType := mtHTML;
            FGmail.Files.Clear;
            for Path in M.Attachments do
              FGmail.Files.Add.&File := Path;
            FGmail.SendMailMessage(FPendingGmailMessage);
          end;
        msOutlook:
          begin
            Recipients := TStringList.Create;
            try
              Recipients.Add(M.HandlerEmail);
              FOutlook.SendMailMessage(BuildForwardSubject(M), BuildForwardHtml(M), Recipients, nil, nil, mtHTML);
            finally
              Recipients.Free;
            end;
          end;
      end;
      Exit; // continues in the OnSendMessage events
    except
      on E: Exception do
      begin
        FActiveForwardID := 0;
        M.Status := tsError;
        M.StatusInfo := 'Forward failed: ' + E.Message;
        FLastError := Format('#%d %s', [M.ID, M.StatusInfo]);
        StepBatch;
        Changed;
      end;
    end;
  end;
end;

procedure TTriageEngine.GmailSendMessage(Sender: TObject; const AMessage: TTMSFNCCloudGoogleGmailMessage;
  const ARequestResult: TTMSFNCCloudBaseRequestResult);
begin
  FinishForward(ARequestResult.Success, ARequestResult.ResultString);
end;

procedure TTriageEngine.OutlookSendMessage(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
begin
  FinishForward(ARequestResult.Success, ARequestResult.ResultString);
end;

procedure TTriageEngine.FinishForward(ASuccess: Boolean; const AInfo: string);
var
  M: TTriageMail;
begin
  M := FMails.FindByID(FActiveForwardID);
  FActiveForwardID := 0;
  if Assigned(M) then
  begin
    if ASuccess then
    begin
      M.Status := tsForwarded;
      M.StatusInfo := 'Sent to ' + M.HandlerName + ' <' + M.HandlerEmail + '>';
      Log(Format('#%d forwarded to %s', [M.ID, M.HandlerEmail]));
      // Take the original out of the inbox: label / folder per department. This runs
      // inside the component's send event, so start the filing request afterwards
      if M.Source in [msGmail, msOutlook] then
      begin
        FActiveForwardID := M.ID;
        Changed;
        TThread.ForceQueue(nil, QueuedStartFiling);
        Exit;
      end;
    end
    else
    begin
      M.Status := tsError;
      M.StatusInfo := 'Forward failed: ' + Copy(AInfo, 1, 300);
      FLastError := Format('#%d %s', [M.ID, M.StatusInfo]);
      Log(Format('#%d forward failed: %s', [M.ID, M.StatusInfo]));
    end;
  end;
  StepBatch;
  Changed;
  TThread.ForceQueue(nil, QueuedNextForward);
end;

procedure TTriageEngine.QueuedNextForward;
begin
  FreeAndNil(FPendingGmailMessage);
  ProcessNextForward;
end;

procedure TTriageEngine.QueuedStartFiling;
var
  M: TTriageMail;
  Done: TMailboxDoneProc;
begin
  M := FMails.FindByID(FActiveForwardID);
  if not Assigned(M) then
  begin
    FActiveForwardID := 0;
    StepBatch;
    QueuedNextForward;
    Exit;
  end;
  Done :=
    procedure(AOk: Boolean; const AInfo: string)
    begin
      FMailboxSuccess := AOk;
      FMailboxInfo := AInfo;
      TThread.ForceQueue(nil, QueuedFileDone);
    end;
  if M.Source = msGmail then
    FileGmailMessage(FGmail, M, Done)
  else
    FileOutlookMessage(FOutlook, M, Done);
end;

procedure TTriageEngine.QueuedFileDone;
var
  M: TTriageMail;
begin
  // Filing after a forward: the mail left the inbox for Triage/<Department>
  M := FMails.FindByID(FActiveForwardID);
  FActiveForwardID := 0;
  if Assigned(M) then
  begin
    if FMailboxSuccess then
    begin
      M.FiledIn := FilingPath(M);
      M.StatusInfo := M.StatusInfo + '; moved out of the inbox to ' + M.FiledIn;
      // Graph gives a moved message a new id: later calls (reply draft) need it
      if (M.Source = msOutlook) and (MovedMessageId(FMailboxInfo) <> '') then
        M.SourceID := MovedMessageId(FMailboxInfo);
      Log(Format('#%d moved to %s in %s', [M.ID, M.FiledIn, SourceNames[M.Source]]));
    end
    else
      Log(Format('#%d forwarded, but could not move it to %s: %s', [M.ID, FilingPath(M), Copy(FMailboxInfo, 1, 200)]));
  end;
  StepBatch;
  Changed;
  QueuedNextForward;
end;

function TTriageEngine.ArchiveForwarded: Integer;
var
  I: Integer;
begin
  // Forwarded mails are done: they live on in the mailbox and the customer history
  Result := 0;
  for I := FMails.Count - 1 downto 0 do
    if FMails[I].Status = tsForwarded then
    begin
      FMails.Delete(I);
      Inc(Result);
    end;
  if Result > 0 then
  begin
    Log(Format('%d forwarded mail(s) archived', [Result]));
    Changed;
  end;
end;

{ ------------------------------------------------------------------------- }
{ Workshop and calendar                                                     }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.SetAppointment(AMail: TTriageMail; AStart: TDateTime);
begin
  if AStart = 0 then
  begin
    AMail.AppointmentStart := 0;
    AMail.AppointmentSynced := False;
    Log(Format('#%d workshop appointment removed', [AMail.ID]));
    Changed;
    Exit;
  end;
  if not AMail.IsTriaged or (AMail.Department <> dpMaintenance) then
    raise Exception.Create('Only triaged maintenance mails get a workshop slot');
  // A taken slot, or one outside the workshop hours, moves to the next free hour
  AStart := NextFreeSlot(AStart, AMail);
  AMail.AppointmentStart := AStart;
  AMail.AppointmentSynced := False;
  Log(Format('#%d workshop appointment set to %s', [AMail.ID, FormatDateTime('ddd dd/mm hh:nn', AStart)]));
  Changed;
end;

procedure TTriageEngine.SeedBookings;
type
  THours = set of WorkshopFirstHour..WorkshopLastHour;
  TBookingSample = record
    Customer, Vehicle, Job: string;
  end;
const
  // Booked hours per weekday (Monday..Friday): busy until the end of next
  // week, with Tuesday and Wednesday full, and quieter the week after
  BusyWeek: array[1..5] of THours = (
    [8, 9, 10, 11, 13, 14, 16],
    [8..16],
    [8..16],
    [8, 10, 11, 13, 14, 15],
    [8, 9, 11, 13, 15]);
  QuietWeek: array[1..5] of THours = ([9, 13], [8, 10, 14], [9, 11, 15], [8, 13], [10, 14]);
  Samples: array[0..15] of TBookingSample = (
    (Customer: 'Wim Goossens'; Vehicle: 'VW Golf (1-KMT-482)'; Job: 'Annual service'),
    (Customer: 'An Vermeersch'; Vehicle: 'Audi A4 (1-RDB-115)'; Job: 'Brake pads front'),
    (Customer: 'Geert Hermans'; Vehicle: 'Skoda Octavia (2-FHL-903)'; Job: 'Winter tyres'),
    (Customer: 'Isabelle Leroy'; Vehicle: 'Cupra Formentor (1-ZPA-337)'; Job: 'Inspection preparation'),
    (Customer: 'Tom Lemmens'; Vehicle: 'VW Tiguan (1-GVX-760)'; Job: 'Timing belt'),
    (Customer: 'Katrien Smets'; Vehicle: 'Audi Q3 (2-BNK-218)'; Job: 'Airco service'),
    (Customer: 'Mohamed Benali'; Vehicle: 'Skoda Kodiaq (1-TJW-594)'; Job: 'Warning light diagnosis'),
    (Customer: 'Els Van Damme'; Vehicle: 'VW Polo (1-HCE-071)'; Job: 'Oil change'),
    (Customer: 'Frank Michiels'; Vehicle: 'Audi e-tron (2-LQS-846)'; Job: 'Recall: software update'),
    (Customer: 'Julie Aerts'; Vehicle: 'VW ID.4 (1-WEP-329)'; Job: 'Annual service'),
    (Customer: 'Stijn Coppens'; Vehicle: 'Skoda Fabia (1-NUY-652)'; Job: 'Battery replacement'),
    (Customer: 'Marie Lambrecht'; Vehicle: 'Audi A6 Avant (2-CXR-407)'; Job: 'Winter tyres'),
    (Customer: 'Kris Desmet'; Vehicle: 'Cupra Born (1-SDF-118)'; Job: 'Windscreen repair'),
    (Customer: 'Nadia Bouzid'; Vehicle: 'VW T-Roc (1-PLM-985)'; Job: 'Brake fluid and discs'),
    (Customer: 'Dries Willaert'; Vehicle: 'VW Passat (1-AQZ-264)'; Job: 'Annual service'),
    (Customer: 'Leen Maertens'; Vehicle: 'Skoda Superb (2-JTB-531)'; Job: 'Exhaust noise check'));
var
  Day, WeekStart: TDateTime;
  Hour, Next: Integer;
  Hours: THours;
  EmmaBooked: Boolean;
  B: TWorkshopBooking;
begin
  // A workshop that is already partly booked, from the next working day on,
  // so not every wish of a customer fits
  FBookings.Clear;
  WeekStart := StartOfTheWeek(Date);
  Day := Int(NextWorkshopTime(Int(Date) + 1));
  Next := 0;
  EmmaBooked := False;
  while Day < WeekStart + 21 do
  begin
    if Day < WeekStart + 14 then
      Hours := BusyWeek[DayOfTheWeek(Day)]
    else
      Hours := QuietWeek[DayOfTheWeek(Day)];
    for Hour := WorkshopFirstHour to WorkshopLastHour do
    begin
      B.Start := Day + EncodeTime(Hour, 0, 0, 0);
      // The test mailer has Emma Janssens cancel her service of "this Thursday at 9:00"
      if not EmmaBooked and (DayOfTheWeek(Day) = DayThursday) and (Hour = 9) then
      begin
        B.Customer := 'Emma Janssens';
        B.Vehicle := 'Audi A3 (2-XYZ-789)';
        B.Job := 'Service';
        EmmaBooked := True;
      end
      else if Hour in Hours then
      begin
        B.Customer := Samples[Next mod Length(Samples)].Customer;
        B.Vehicle := Samples[Next mod Length(Samples)].Vehicle;
        B.Job := Samples[Next mod Length(Samples)].Job;
        Inc(Next);
      end
      else
        Continue;
      FBookings.Add(B);
    end;
    Day := Int(NextWorkshopTime(Day + 1));
  end;
  Log(Format('Workshop planning: %d existing booking(s) added', [FBookings.Count]));
  Changed;
end;

function TTriageEngine.SlotTaken(AStart: TDateTime; AMail: TTriageMail): Boolean;
const
  // Two one-hour jobs overlap when they start less than an hour apart
  Overlap = 1 / 24 - 1 / 2880;
var
  M: TTriageMail;
  B: TWorkshopBooking;
begin
  Result := True;
  for B in FBookings do
    if Abs(B.Start - AStart) < Overlap then
      Exit;
  for M in FMails do
    if (M <> AMail) and (M.AppointmentStart > 0) and (Abs(M.AppointmentStart - AStart) < Overlap) then
      Exit;
  Result := False;
end;

function TTriageEngine.NextFreeSlot(AStart: TDateTime; AMail: TTriageMail): TDateTime;
var
  I: Integer;
begin
  Result := NextWorkshopTime(AStart);
  for I := 1 to 24 * 365 do  // never loops forever
  begin
    if not SlotTaken(Result, AMail) then
      Exit;
    Result := NextWorkshopTime(IncHour(Result));
  end;
end;

function TTriageEngine.FreeSlotsText(AMail: TTriageMail): string;
var
  Day, Slot: TDateTime;
  I, Hour: Integer;
  Hours: string;
begin
  // The free hours of the next two working weeks, for the AI's appointment suggestion
  Result := '';
  Day := Int(NextWorkshopTime(Int(Date) + 1));
  for I := 1 to 10 do
  begin
    Hours := '';
    for Hour := WorkshopFirstHour to WorkshopLastHour do
    begin
      Slot := Day + EncodeTime(Hour, 0, 0, 0);
      if not SlotTaken(Slot, AMail) then
      begin
        if Hours <> '' then
          Hours := Hours + ', ';
        Hours := Hours + FormatDateTime('hh:nn', Slot);
      end;
    end;
    if Hours = '' then
      Hours := 'fully booked';
    Result := Result + FormatDateTime('yyyy-mm-dd (dddd)', Day, TFormatSettings.Invariant) + ': ' + Hours + sLineBreak;
    Day := Int(NextWorkshopTime(Day + 1));
  end;
end;

function TTriageEngine.CustomerBookings(AMail: TTriageMail): TArray<TWorkshopBooking>;
var
  B: TWorkshopBooking;
  Text, Plate: string;
begin
  // Upcoming bookings of the sender: by full name, or by the number plate in the mail
  // (test mails all come from one account, so the address says nothing)
  Result := nil;
  Text := (AMail.FromName + ' ' + AMail.Subject + ' ' + AMail.Body).ToLower;
  for B in FBookings do
    if B.Start >= Now then
    begin
      Plate := '';
      if B.Vehicle.Contains('(') then
        Plate := B.Vehicle.Substring(B.Vehicle.IndexOf('(') + 1).Replace(')', '').Trim.ToLower;
      if Text.Contains(B.Customer.ToLower) or ((Plate <> '') and Text.Contains(Plate)) then
        Result := Result + [B];
    end;
end;

function TTriageEngine.BookingsText(AMail: TTriageMail): string;
var
  B: TWorkshopBooking;
begin
  Result := '';
  for B in CustomerBookings(AMail) do
    Result := Result + FormatDateTime('yyyy-mm-dd hh:nn (dddd)', B.Start, TFormatSettings.Invariant) + ': ' +
      B.Customer + ', ' + B.Vehicle + ', ' + B.Job + sLineBreak;
end;

procedure TTriageEngine.KeywordCancellation(AMail: TTriageMail);
const
  CancelWords = 'cancel|annul|afzeg|verzet|verplaats|reschedul|d'#$00E9'plac|deplac';
var
  Own: TArray<TWorkshopBooking>;
begin
  // Offline: a mail about cancelling or moving, from a customer with exactly one booking
  Own := CustomerBookings(AMail);
  if (Length(Own) = 1) and TRegEx.IsMatch(AMail.Subject + ' ' + AMail.Body, CancelWords, [roIgnoreCase]) then
    AMail.CancelBookingStart := Own[0].Start;
end;

function TTriageEngine.CancelBooking(AStart: TDateTime): TWorkshopBooking;
var
  I: Integer;
begin
  for I := 0 to FBookings.Count - 1 do
    if Abs(FBookings[I].Start - AStart) < 1 / 2880 then
    begin
      Result := FBookings[I];
      FBookings.Delete(I);
      Log(Format('Workshop booking of %s cancelled: %s, %s', [FormatDateTime('ddd dd/mm hh:nn', Result.Start),
        Result.Customer, Result.Vehicle]));
      Changed;
      Exit;
    end;
  raise Exception.CreateFmt('There is no workshop booking at %s', [SlotToStr(AStart)]);
end;

function TTriageEngine.SyncCalendar: string;
var
  M: TTriageMail;
  Pending: Integer;
begin
  if FCalendarPending then
    Exit('A calendar sync is already running.');
  Pending := 0;
  for M in FMails do
    if (M.AppointmentStart > 0) and not M.AppointmentSynced then
      Inc(Pending);
  if Pending = 0 then
    Exit('No new workshop appointments to sync.');

  FCalendarResult := '';
  // Same app registration as the mailbox; the calendar asks for its own consent once
  // (a browser on the server machine), after that the saved tokens are used
  if FConnected[msGmail] then
  begin
    SetupCloud(FGCalendar, 'gcalendar.ini', FSettings.GmailClientID, FSettings.GmailSecret);
    FCalendarPending := True;
    FGCalendar.Connect;
  end
  else if FConnected[msOutlook] then
  begin
    SetupCloud(FOCalendar, 'ocalendar.ini', FSettings.OutlookClientID, FSettings.OutlookSecret);
    FCalendarPending := True;
    FOCalendar.Connect;
  end
  else
  begin
    Log(Format('[simulated] %d workshop appointment(s) would be added to the calendar', [Pending]));
    Exit('No mailbox connected: appointments go to the calendar of the connected mailbox.');
  end;
  Changed;
  Result := '';
end;

procedure TTriageEngine.SyncCalendarItems;
var
  M: TTriageMail;
  Count: Integer;
  GItem: TTMSFNCCloudGoogleCalendarItem;
  OItem: TTMSFNCCloudMicrosoftOutlookCalendarItem;
begin
  Count := 0;
  for M in FMails do
    if (M.AppointmentStart > 0) and not M.AppointmentSynced then
    begin
      if FConnected[msGmail] then
      begin
        GItem := FGCalendar.Items.Add;
        GItem.CalendarID := 'primary';
        GItem.Summary := 'Workshop: ' + M.Brand + ' - ' + M.FromName;
        GItem.Description := M.Subject + sLineBreak + M.Summary + sLineBreak + M.FromDisplay;
        GItem.StartTime := M.AppointmentStart;
        GItem.EndTime := IncHour(M.AppointmentStart);
        FGCalendar.Add(GItem);
      end
      else
      begin
        OItem := FOCalendar.Items.Add;
        OItem.CalendarID := FOCalendar.Calendars[0].ID;
        OItem.Summary := 'Workshop: ' + M.Brand + ' - ' + M.FromName;
        OItem.Description := M.Subject + sLineBreak + M.Summary + sLineBreak + M.FromDisplay;
        OItem.StartTime := M.AppointmentStart;
        OItem.EndTime := IncHour(M.AppointmentStart);
        FOCalendar.Add(OItem);
      end;
      M.AppointmentSynced := True;
      Inc(Count);
    end;
  FCalendarPending := False;
  FCalendarResult := Format('%d appointment(s) sent to the calendar', [Count]);
  Log(FCalendarResult);
  Changed;
end;

procedure TTriageEngine.GCalendarConnected(Sender: TObject);
begin
  FGCalendar.SaveTokens;
  SyncCalendarItems;
end;

procedure TTriageEngine.GCalendarAdded(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult;
  const ACalendarItem: TTMSFNCCloudGoogleCalendarItem);
begin
  if ARequestResult.Success then
    Log('Google Calendar: added ' + ACalendarItem.Summary)
  else
    Log('Google Calendar: adding failed: ' + Copy(ARequestResult.ResultString, 1, 200));
end;

procedure TTriageEngine.OCalendarConnected(Sender: TObject);
begin
  FOCalendar.SaveTokens;
  FOCalendar.GetCalendars;  // continues in OCalendarGetCalendars
end;

procedure TTriageEngine.OCalendarGetCalendars(Sender: TObject; const ARequestResult: TTMSFNCCloudBaseRequestResult);
begin
  if FOCalendar.Calendars.Count = 0 then
  begin
    FCalendarPending := False;
    FCalendarResult := 'Outlook Calendar: no calendar found';
    Log(FCalendarResult);
    Changed;
    Exit;
  end;
  SyncCalendarItems;
end;

procedure TTriageEngine.OCalendarAdded(Sender: TObject; const AItem: TTMSFNCCloudMicrosoftOutlookCalendarItem;
  const ARequestResult: TTMSFNCCloudBaseRequestResult);
begin
  if ARequestResult.Success then
    Log('Outlook Calendar: added ' + AItem.Summary)
  else
    Log('Outlook Calendar: adding failed: ' + Copy(ARequestResult.ResultString, 1, 200));
end;

{ ------------------------------------------------------------------------- }
{ Alerts and translation                                                    }
{ ------------------------------------------------------------------------- }

function TTriageEngine.NotifyOnCall(AMail: TTriageMail; const AMessage: string): string;
var
  Text: string;
begin
  Text := AMessage.Trim;
  if Text = '' then
    Text := AMail.Summary + sLineBreak + AMail.FromDisplay + sLineBreak + 'Handler: ' + AMail.HandlerName;
  AMail.Alerted := True;
  Changed;
  if not FSettings.AlertsEnabled or (FSettings.PushoverToken = '') or (FSettings.PushoverUser = '') then
  begin
    Log(Format('#%d [simulated] on-call alert: %s', [AMail.ID, AMail.Subject]));
    Exit('Alerts are not set up (alerts_enabled, pushover_token, pushover_user): simulated.');
  end;
  FPushPending := True;
  FPushResult := '';
  FPushOver.APIKey := FSettings.PushoverToken;
  FPushOver.PushMessage(FSettings.PushoverUser, 'URGENT: ' + AMail.Subject, Text);
  Log(Format('#%d on-call alert sent', [AMail.ID]));
  Result := '';
end;

procedure TTriageEngine.PushSuccess(Sender: TObject);
begin
  FPushPending := False;
  FPushResult := 'delivered';
  SetStatus('Urgent alert delivered.');
end;

procedure TTriageEngine.PushError(Sender: TObject; AErrorMessage: string; AErrorCode: Integer);
begin
  FPushPending := False;
  FPushResult := Format('failed (%d): %s', [AErrorCode, AErrorMessage]);
  FLastError := 'Alert ' + FPushResult;
  Log('Urgent alert ' + FPushResult);
end;

function TTriageEngine.Translate(AMail: TTriageMail): string;
var
  Svc: TTMSMCPCloudAIService;
begin
  // Only on request (translate_mail): never part of the triage itself
  if AMail.Translation <> '' then
    Exit('');
  if not SelectedService(Svc) then
    Exit('Translations use the AI service: set ai_service first (update_setting).');
  if ServiceNeedsKey(Svc) and (ServiceAPIKey = '') then
    Exit(Format('No API key for %s: set ai_api_key first (update_setting).', [FSettings.AIService]));
  if FTranslatingID <> 0 then
    Exit('Another translation is running, try again in a moment.');

  // A component of its own, so a translation neither waits for nor disturbs the
  // triage queue; it takes the service, key and model of the triage
  FTranslator.Service := Svc;
  SetServiceKey(FTranslator.APIKeys, Svc, GetServiceKey(FAI.APIKeys, Svc));
  if GetServiceModel(FAI, Svc) <> '' then
    SetServiceModel(FTranslator, Svc, GetServiceModel(FAI, Svc));
  FTranslator.SystemRole.Text := BuildTranslateSystemPrompt(FSettings.TargetLanguage);
  FTranslator.Context.Text := BuildTranslatePrompt(AMail);
  FTranslatingID := AMail.ID;
  FTranslateError := '';
  try
    FTranslator.Execute(AMail.ID.ToString);
  except
    on E: Exception do
    begin
      FTranslatingID := 0;
      Exit('Translation: ' + E.Message);
    end;
  end;
  Log(Format('#%d translating into %s with %s...', [AMail.ID, FSettings.TargetLanguage, EngineName]));
  Changed;
  Result := '';
end;

procedure TTriageEngine.TranslatorExecuted(Sender: TObject; AResponse: TTMSMCPCloudAIResponse; AHttpStatusCode: Integer;
  AHttpResult: string);
var
  M: TTriageMail;
begin
  M := FindMail(FTranslatingID);
  FTranslatingID := 0;
  if Assigned(M) then
  begin
    if (AHttpStatusCode div 100 = 2) and Assigned(AResponse)
      and ApplyTranslateResponse(M, AResponse.Content.Text) then
      Log(Format('#%d translated from %s', [M.ID, IfThen(M.SourceLanguage <> '', M.SourceLanguage, '?')]))
    else
    begin
      if (AHttpStatusCode div 100 = 2) and Assigned(AResponse) then
        FTranslateError := 'empty AI answer'
      else
        FTranslateError := Format('HTTP %d: %s', [AHttpStatusCode, Copy(AHttpResult, 1, 200)]);
      FLastError := Format('#%d translation: %s', [M.ID, FTranslateError]);
      Log(FLastError);
    end;
  end;
  Changed;
end;

{ ------------------------------------------------------------------------- }
{ Spam                                                                      }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.MoveToSpam(AMail: TTriageMail);
begin
  AMail.Status := tsSpam;
  AMail.IsSpam := True;
  AMail.ReplyDraft := '';
  AMail.ReplyStatus := rsNone;
  AMail.DraftID := '';
  AMail.AppointmentStart := 0;
  FMails.Extract(AMail);
  FSpam.Add(AMail);
  Log(Format('#%d %s -> Spam (%s)', [AMail.ID, AMail.Subject, AMail.SpamReason]));
  Changed;
end;

procedure TTriageEngine.MarkSpam(AMail: TTriageMail; const AReason: string);
begin
  if FSpam.Contains(AMail) then
    Exit;
  if AMail.Status in [tsAnalyzing, tsForwarding] then
    raise Exception.Create('This mail is being processed, try again in a moment');
  if AMail.Status = tsForwarded then
    raise Exception.Create('This mail was already forwarded');
  AMail.NotSpam := False;
  AMail.SpamReason := AReason;
  if AMail.SpamReason = '' then
    AMail.SpamReason := 'Marked as spam manually';
  MoveToSpam(AMail);
end;

procedure TTriageEngine.MarkNotSpam(AMail: TTriageMail);
begin
  if not FSpam.Contains(AMail) then
    raise Exception.Create('This mail is not on the spam list');
  // Back to the inbox as a new mail; it is never flagged again
  AMail.NotSpam := True;
  AMail.IsSpam := False;
  AMail.SpamReason := '';
  AMail.Status := tsNew;
  FSpam.Extract(AMail);
  FMails.Add(AMail);
  Log(Format('#%d %s: not spam, back in the inbox', [AMail.ID, AMail.Subject]));
  Changed;
  if FSettings.AutoTriage then
    QueueTriage(AMail.ID);
end;

function TTriageEngine.QueueTrash(AID: Integer): Integer;
var
  M: TTriageMail;
begin
  Result := 0;
  if AID <> 0 then
  begin
    M := FSpam.FindByID(AID);
    if not Assigned(M) then
      raise Exception.Create('Only mails on the spam list can be deleted');
    FTrashQueue.Enqueue(M.ID);
    Result := 1;
  end
  else
    for M in FSpam do
    begin
      FTrashQueue.Enqueue(M.ID);
      Inc(Result);
    end;
  if Result = 0 then
    Exit;
  StartBatch(Result);
  if FActiveTrashID = 0 then
    ProcessNextTrash;
end;

procedure TTriageEngine.ProcessNextTrash;
var
  M: TTriageMail;
  Done: TMailboxDoneProc;
begin
  Done :=
    procedure(AOk: Boolean; const AInfo: string)
    begin
      FMailboxSuccess := AOk;
      FMailboxInfo := AInfo;
      TThread.ForceQueue(nil, QueuedTrashDone);
    end;
  while FTrashQueue.Count > 0 do
  begin
    M := FSpam.FindByID(FTrashQueue.Dequeue);
    if not Assigned(M) then
      Continue;
    FActiveTrashID := M.ID;
    // Mailbox mails go to its trash (recoverable); demo mails are only removed here
    if (M.Source = msGmail) and FConnected[msGmail] then
      TrashGmailMessage(FGmail, M, Done)
    else if (M.Source = msOutlook) and FConnected[msOutlook] then
      TrashOutlookMessage(FOutlook, M, Done)
    else
    begin
      FMailboxSuccess := M.Source = msDemo;
      if FMailboxSuccess then
        FMailboxInfo := ''
      else
        FMailboxInfo := 'connect ' + SourceNames[M.Source] + ' first, the mail stays on the spam list';
      // Queued like the mailbox requests: no recursion through QueuedTrashDone
      TThread.ForceQueue(nil, QueuedTrashDone);
    end;
    Exit;
  end;
end;

procedure TTriageEngine.QueuedTrashDone;
var
  M: TTriageMail;
begin
  M := FSpam.FindByID(FActiveTrashID);
  FActiveTrashID := 0;
  if Assigned(M) then
  begin
    if FMailboxSuccess then
    begin
      if M.Source = msDemo then
        Log(Format('#%d spam deleted: %s', [M.ID, M.Subject]))
      else
        Log(Format('#%d spam moved to the %s trash: %s', [M.ID, SourceNames[M.Source], M.Subject]));
      FSpam.Remove(M);
    end
    else
    begin
      FLastError := Format('#%d trash: %s', [M.ID, Copy(FMailboxInfo, 1, 200)]);
      Log(Format('#%d could not move to the trash: %s', [M.ID, Copy(FMailboxInfo, 1, 200)]));
    end;
  end;
  StepBatch;
  Changed;
  ProcessNextTrash;
end;

{ ------------------------------------------------------------------------- }
{ Routing                                                                   }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.RoutingChanged;
var
  M: TTriageMail;
begin
  FRouting.SaveToFile(RoutingFile);
  // Re-resolve handlers for mails that are triaged but not yet forwarded
  for M in FMails do
    if M.Status in [tsTriaged, tsSimulated] then
    begin
      M.Brand := FRouting.NormalizeBrand(M.Brand);
      AssignHandler(M, FRouting);
    end;
  Changed;
end;

procedure TTriageEngine.SetRoutingRule(ADepartment: TDepartment; const ABrand, AName, AEmail: string);
var
  R: TRoutingRule;
  Brand: string;
begin
  if AEmail.Trim = '' then
    raise Exception.Create('A routing rule needs the handler''s email address');
  Brand := ABrand.Trim;
  if Brand = '' then
    Brand := AnyBrand;
  for R in FRouting.Rules do
    if (R.Department = ADepartment) and SameText(R.Brand, Brand) then
    begin
      R.HandlerName := AName.Trim;
      R.HandlerEmail := AEmail.Trim;
      Log(Format('Routing: %s / %s -> %s <%s>', [DepartmentNames[ADepartment], Brand, R.HandlerName, R.HandlerEmail]));
      RoutingChanged;
      Exit;
    end;
  FRouting.Add(ADepartment, Brand, AName.Trim, AEmail.Trim);
  Log(Format('Routing: new rule %s / %s -> %s <%s>', [DepartmentNames[ADepartment], Brand, AName.Trim, AEmail.Trim]));
  RoutingChanged;
end;

function TTriageEngine.DeleteRoutingRule(ADepartment: TDepartment; const ABrand: string): Boolean;
var
  I: Integer;
  Brand: string;
begin
  Brand := ABrand.Trim;
  if Brand = '' then
    Brand := AnyBrand;
  for I := 0 to FRouting.Rules.Count - 1 do
    if (FRouting.Rules[I].Department = ADepartment) and SameText(FRouting.Rules[I].Brand, Brand) then
    begin
      FRouting.Rules.Delete(I);
      Log(Format('Routing: rule %s / %s deleted', [DepartmentNames[ADepartment], Brand]));
      RoutingChanged;
      Exit(True);
    end;
  Result := False;
end;

procedure TTriageEngine.ReplaceRouting(const AJson: string);
begin
  FRouting.LoadFromJSON(AJson);
  Log(Format('Routing table replaced: %d rule(s)', [FRouting.Rules.Count]));
  RoutingChanged;
end;

procedure TTriageEngine.ResetRouting;
begin
  FRouting.LoadDefaults;
  Log('Routing table reset to the defaults');
  RoutingChanged;
end;

{ ------------------------------------------------------------------------- }
{ Settings                                                                  }
{ ------------------------------------------------------------------------- }

function TTriageEngine.SettingsJSON: TJSONObject;
var
  Svc: TTMSMCPCloudAIService;
  Arr: TJSONArray;
  S: string;
  Ini: TMemIniFile;

  procedure Secret(const AName, AValue: string);
  begin
    // Secrets never leave the server; only whether they are set
    if AValue <> '' then
      Result.AddPair(AName, 'set')
    else
      Result.AddPair(AName, 'not set');
  end;

begin
  Result := TJSONObject.Create;
  if FSettings.AIService = '' then
    Result.AddPair('ai_service', 'offline')
  else
    Result.AddPair('ai_service', FSettings.AIService);
  Arr := TJSONArray.Create;
  Arr.Add('offline');
  for S in AIServices do
    Arr.Add(S);
  Result.AddPair('ai_services', Arr);
  if SelectedService(Svc) then
  begin
    if ServiceNeedsKey(Svc) then
      Secret('ai_api_key', GetServiceKey(FAI.APIKeys, Svc));
    Result.AddPair('ai_model', GetServiceModel(FAI, Svc));
  end;
  Result.AddPair('max_mails', TJSONNumber.Create(FSettings.MaxMails));
  Result.AddPair('dry_run', TJSONBool.Create(FSettings.DryRun));
  Result.AddPair('auto_fetch_minutes', TJSONNumber.Create(FSettings.AutoFetchMinutes));
  Result.AddPair('auto_triage', TJSONBool.Create(FSettings.AutoTriage));
  Result.AddPair('auto_drafts', TJSONBool.Create(FSettings.AutoDrafts));
  Result.AddPair('alerts_enabled', TJSONBool.Create(FSettings.AlertsEnabled));
  Secret('pushover_token', FSettings.PushoverToken);
  Secret('pushover_user', FSettings.PushoverUser);
  Result.AddPair('target_language', FSettings.TargetLanguage);
  Result.AddPair('gmail_client_id', FSettings.GmailClientID);
  Secret('gmail_secret', FSettings.GmailSecret);
  Result.AddPair('outlook_client_id', FSettings.OutlookClientID);
  Secret('outlook_secret', FSettings.OutlookSecret);
  Result.AddPair('callback_url', FSettings.CallbackURL);
  Ini := TMemIniFile.Create(SettingsFile);
  try
    Result.AddPair('mcp_port', TJSONNumber.Create(Ini.ReadInteger('MCPServer', 'Port', 8787)));
  finally
    Ini.Free;
  end;
  Result.AddPair('data_folder', FDataDir);
end;

procedure TTriageEngine.SetSetting(const AName, AValue: string);
var
  Name, Value: string;
  Svc: TTMSMCPCloudAIService;
  N: Integer;
begin
  Name := AName.Trim.ToLower;
  Value := AValue.Trim;
  if Name = 'ai_service' then
  begin
    if SameText(Value, 'offline') or (Value = '') then
      FSettings.AIService := ''
    else
    begin
      N := IndexText(Value, AIServices);
      if N < 0 then
        raise Exception.Create('Unknown AI service; get_settings lists ai_services');
      FSettings.AIService := AIServices[N];
      SelectedService(Svc);
      FAI.Service := Svc;
    end;
  end
  else if Name = 'ai_api_key' then
  begin
    if not SelectedService(Svc) then
      raise Exception.Create('Select an AI service first (ai_service)');
    SetServiceKey(FAI.APIKeys, Svc, Value);
  end
  else if Name = 'ai_model' then
  begin
    if not SelectedService(Svc) then
      raise Exception.Create('Select an AI service first (ai_service)');
    if Value = '' then
      raise Exception.Create('ai_model needs a model name');
    SetServiceModel(FAI, Svc, Value);
  end
  else if Name = 'max_mails' then
  begin
    N := StrToIntDef(Value, -1);
    if (N < 1) or (N > 500) then
      raise Exception.Create('max_mails must be 1..500');
    FSettings.MaxMails := N;
  end
  else if Name = 'dry_run' then
    FSettings.DryRun := ParseBool(Value)
  else if Name = 'auto_fetch_minutes' then
  begin
    N := StrToIntDef(Value, -1);
    if (N < 0) or (N > 1440) then
      raise Exception.Create('auto_fetch_minutes must be 0 (off) .. 1440');
    FSettings.AutoFetchMinutes := N;
  end
  else if Name = 'auto_triage' then
    FSettings.AutoTriage := ParseBool(Value)
  else if Name = 'auto_drafts' then
    FSettings.AutoDrafts := ParseBool(Value)
  else if Name = 'alerts_enabled' then
    FSettings.AlertsEnabled := ParseBool(Value)
  else if Name = 'pushover_token' then
    FSettings.PushoverToken := Value
  else if Name = 'pushover_user' then
    FSettings.PushoverUser := Value
  else if Name = 'target_language' then
  begin
    if Value = '' then
      raise Exception.Create('target_language needs a language, e.g. English or EN-GB');
    FSettings.TargetLanguage := Value;
  end
  else if Name = 'gmail_client_id' then
    FSettings.GmailClientID := Value
  else if Name = 'gmail_secret' then
    FSettings.GmailSecret := Value
  else if Name = 'outlook_client_id' then
    FSettings.OutlookClientID := Value
  else if Name = 'outlook_secret' then
    FSettings.OutlookSecret := Value
  else if Name = 'callback_url' then
    FSettings.CallbackURL := Value
  else if MatchText(Name, ['mcp_port', 'data_folder']) then
    raise Exception.Create(Name + ' is read-only: change it in settings.ini on the server and restart it')
  else
    raise Exception.Create('Unknown setting; get_settings lists them');
  SaveSettings;
  // Never log secrets
  if MatchText(Name, ['ai_api_key', 'pushover_token', 'pushover_user', 'gmail_secret', 'outlook_secret']) then
    Log('Setting changed: ' + Name)
  else
    Log(Format('Setting changed: %s = %s', [Name, Value]));
  Inc(FVersion);
end;

{ ------------------------------------------------------------------------- }
{ Customer history (SQLite): earlier contact and returning customers       }
{ ------------------------------------------------------------------------- }

procedure TTriageEngine.OpenHistory;
begin
  try
    FDB.Params.Values['Database'] := TPath.Combine(FDataDir, 'history.db');
    FDB.Open;
    FDB.ExecSQL('CREATE TABLE IF NOT EXISTS history (source_id TEXT PRIMARY KEY, email TEXT, name TEXT, ' +
      'received TEXT, subject TEXT, department INTEGER, brand TEXT, handler_name TEXT, handler_email TEXT, ' +
      'priority TEXT, summary TEXT)');
    if FDB.ExecSQLScalar('SELECT COUNT(*) FROM history') = 0 then
      SeedHistory;
  except
    on E: Exception do
      Log('Customer history not available: ' + E.Message);
  end;
end;

procedure TTriageEngine.SeedHistory;

  procedure Add(const AEmail, AName, AReceived, ASubject: string; ADepartment: TDepartment;
    const ABrand, ASummary: string);
  var
    Rule: TRoutingRule;
  begin
    Rule := FRouting.Resolve(ADepartment, ABrand);
    if Assigned(Rule) then
      FDB.ExecSQL('INSERT INTO history VALUES (:s, :e, :n, :r, :subj, :d, :b, :hn, :he, :p, :sum)',
        ['history:' + AEmail + ':' + AReceived, AEmail, AName, AReceived, ASubject, Ord(ADepartment), ABrand,
         Rule.HandlerName, Rule.HandlerEmail, PriorityNormal, ASummary]);
  end;

begin
  // A few earlier contacts of the demo customers
  Add('nathalie.maes@example.com', 'Nathalie Maes', '2026-07-02 14:20', 'Wrong amount on invoice 2026-0871',
    dpFinance, 'Skoda', 'Labour was charged twice on the Octavia service; 95,00 EUR credited.');
  Add('sarah.claes@example.com', 'Sarah Claes', '2026-03-18 09:05', 'Polo: winterbanden wisselen',
    dpMaintenance, 'Volkswagen', 'Winter tyres fitted on the Polo, summer tyres in storage.');
  Add('pieter.jacobs@example.com', 'Pieter Jacobs', '2026-09-12 16:40', 'Quote for an ID.5 GTX',
    dpSales, 'Volkswagen', 'Received a quote for an ID.5 GTX and decided to wait; asked to be contacted for EV news.');
  Log('Customer history created with demo data: ' + FDB.Params.Values['Database']);
end;

procedure TTriageEngine.LookupHistory(AMail: TTriageMail);
var
  Line: string;
begin
  AMail.HistoryInfo := '';
  if not FDB.Connected or (AMail.FromEmail = '') then
    Exit;
  FQuery.Open('SELECT received, department, subject, handler_name, summary FROM history ' +
    'WHERE lower(email) = lower(:e) AND source_id <> :s ORDER BY received DESC LIMIT 3',
    [AMail.FromEmail, HistoryKey(AMail)]);
  try
    while not FQuery.Eof do
    begin
      Line := Format('%s  %s: %s (%s)', [Copy(FQuery.Fields[0].AsString, 1, 10),
        DepartmentNames[TDepartment(EnsureRange(FQuery.Fields[1].AsInteger, 0, Ord(High(TDepartment))))],
        FQuery.Fields[2].AsString, FQuery.Fields[3].AsString]);
      if FQuery.Fields[4].AsString <> '' then
        Line := Line + ' - ' + FQuery.Fields[4].AsString;
      if AMail.HistoryInfo <> '' then
        AMail.HistoryInfo := AMail.HistoryInfo + sLineBreak;
      AMail.HistoryInfo := AMail.HistoryInfo + Line;
      FQuery.Next;
    end;
  finally
    FQuery.Close;
  end;
end;

procedure TTriageEngine.ApplyCustomerHistory(AMail: TTriageMail);
var
  Rule: TRoutingRule;
  Email, Received: string;
begin
  // A returning customer goes to the person who handled the last mail of the same
  // department, as long as that person still handles that department
  if not FDB.Connected then
    Exit;
  FQuery.Open('SELECT handler_email, received FROM history WHERE lower(email) = lower(:e) ' +
    'AND department = :d AND source_id <> :s ORDER BY received DESC LIMIT 1',
    [AMail.FromEmail, Ord(AMail.Department), HistoryKey(AMail)]);
  try
    if FQuery.IsEmpty then
      Exit;
    Email := FQuery.Fields[0].AsString;
    Received := Copy(FQuery.Fields[1].AsString, 1, 10);
  finally
    FQuery.Close;
  end;

  for Rule in FRouting.Rules do
    if (Rule.Department = AMail.Department) and SameText(Rule.HandlerEmail, Email) then
    begin
      AMail.PreviousDepartment := AMail.Department;
      AMail.PreviousHandlerName := Rule.HandlerName;
      AMail.PreviousHandlerEmail := Rule.HandlerEmail;
      if not SameText(AMail.HandlerEmail, Rule.HandlerEmail) then
      begin
        AMail.HandlerName := Rule.HandlerName;
        AMail.HandlerEmail := Rule.HandlerEmail;
        AMail.Reason := Format('%s Returning customer: kept with %s, who handled the earlier contact on %s.',
          [AMail.Reason, Rule.HandlerName, Received]).Trim;
      end;
      Exit;
    end;
end;

procedure TTriageEngine.SaveHistory(AMail: TTriageMail);
begin
  if not FDB.Connected or not AMail.IsTriaged then
    Exit;
  try
    FDB.ExecSQL('INSERT OR REPLACE INTO history VALUES (:s, :e, :n, :r, :subj, :d, :b, :hn, :he, :p, :sum)',
      [HistoryKey(AMail), AMail.FromEmail, AMail.FromName, AMail.Received, AMail.Subject, Ord(AMail.Department),
       AMail.Brand, AMail.HandlerName, AMail.HandlerEmail, AMail.Priority, AMail.Summary]);
  except
    on E: Exception do
      Log('Could not save customer history: ' + E.Message);
  end;
end;

function TTriageEngine.CustomerHistory(const AEmail: string): TJSONArray;
begin
  Result := TJSONArray.Create;
  if not FDB.Connected then
    Exit;
  FQuery.Open('SELECT received, department, brand, subject, handler_name, handler_email, priority, summary ' +
    'FROM history WHERE lower(email) = lower(:e) ORDER BY received DESC LIMIT 20', [AEmail.Trim]);
  try
    while not FQuery.Eof do
    begin
      Result.AddElement(TJSONObject.Create
        .AddPair('received', FQuery.Fields[0].AsString)
        .AddPair('department', DepartmentKeys[TDepartment(EnsureRange(FQuery.Fields[1].AsInteger, 0, Ord(High(TDepartment))))])
        .AddPair('brand', FQuery.Fields[2].AsString)
        .AddPair('subject', FQuery.Fields[3].AsString)
        .AddPair('handler', FQuery.Fields[4].AsString + ' <' + FQuery.Fields[5].AsString + '>')
        .AddPair('priority', FQuery.Fields[6].AsString)
        .AddPair('summary', FQuery.Fields[7].AsString));
      FQuery.Next;
    end;
  finally
    FQuery.Close;
  end;
end;

{ ------------------------------------------------------------------------- }
{ JSON views                                                                }
{ ------------------------------------------------------------------------- }

function TTriageEngine.StatusJSON: TJSONObject;
var
  M: TTriageMail;
  D: TDepartment;
  Counts: array[TDepartment] of Integer;
  Untriaged, Urgent, Errors, Drafts, Forwarded, Appointments: Integer;
  Obj: TJSONObject;

  function MailboxState(ASource: TMailSource): string;
  begin
    if FConnected[ASource] then
      Result := 'connected'
    else if FConnecting[ASource] > 0 then
      Result := 'connecting'
    else
      Result := 'not connected';
  end;

begin
  FillChar(Counts, SizeOf(Counts), 0);
  Untriaged := 0;
  Urgent := 0;
  Errors := 0;
  Drafts := 0;
  Forwarded := 0;
  Appointments := 0;
  for M in FMails do
  begin
    if M.IsTriaged then
      Inc(Counts[M.Department])
    else
      Inc(Untriaged);
    if M.IsTriaged and (M.Priority = PriorityUrgent) then
      Inc(Urgent);
    if (M.Status = tsError) or (M.ReplyStatus = rsError) then
      Inc(Errors);
    if M.ReplyStatus in [rsCreated, rsSimulated] then
      Inc(Drafts);
    if M.Status in [tsForwarded, tsSimulated] then
      Inc(Forwarded);
    if M.AppointmentStart > 0 then
      Inc(Appointments);
  end;

  Result := TJSONObject.Create;
  Result.AddPair('version', TJSONNumber.Create(FVersion));
  Result.AddPair('status_text', FStatusText);
  Result.AddPair('engine', EngineName);
  Result.AddPair('dry_run', TJSONBool.Create(FSettings.DryRun));
  Obj := TJSONObject.Create;
  Obj.AddPair('gmail', MailboxState(msGmail));
  Obj.AddPair('outlook', MailboxState(msOutlook));
  Result.AddPair('mailboxes', Obj);

  Result.AddPair('total', TJSONNumber.Create(FMails.Count));
  Result.AddPair('not_triaged', TJSONNumber.Create(Untriaged));
  Result.AddPair('urgent', TJSONNumber.Create(Urgent));
  Result.AddPair('errors', TJSONNumber.Create(Errors));
  Result.AddPair('drafts_saved', TJSONNumber.Create(Drafts));
  Result.AddPair('forwarded', TJSONNumber.Create(Forwarded));
  Result.AddPair('appointments', TJSONNumber.Create(Appointments));
  Result.AddPair('spam', TJSONNumber.Create(FSpam.Count));
  Obj := TJSONObject.Create;
  for D := Low(TDepartment) to High(TDepartment) do
    Obj.AddPair(DepartmentKeys[D], TJSONNumber.Create(Counts[D]));
  Result.AddPair('per_department', Obj);

  Obj := TJSONObject.Create;
  Obj.AddPair('fetching', TJSONBool.Create(IsFetching));
  Obj.AddPair('triage', TJSONNumber.Create(FTriageQueue.Count + Ord(FActiveTriageID <> 0)));
  Obj.AddPair('drafts', TJSONNumber.Create(FDraftQueue.Count + Ord(FActiveDraftID <> 0)));
  Obj.AddPair('forward', TJSONNumber.Create(FForwardQueue.Count + Ord(FActiveForwardID <> 0)));
  Obj.AddPair('trash', TJSONNumber.Create(FTrashQueue.Count + Ord(FActiveTrashID <> 0)));
  Obj.AddPair('busy', TJSONBool.Create(IsBusy or IsFetching));
  Obj.AddPair('batch_done', TJSONNumber.Create(Min(FBatchDone, FBatchTotal)));
  Obj.AddPair('batch_total', TJSONNumber.Create(FBatchTotal));
  Result.AddPair('work', Obj);

  Obj := TJSONObject.Create;
  Obj.AddPair('fetch_minutes', TJSONNumber.Create(FSettings.AutoFetchMinutes));
  Obj.AddPair('triage', TJSONBool.Create(FSettings.AutoTriage));
  Obj.AddPair('drafts', TJSONBool.Create(FSettings.AutoDrafts));
  if FLastFetch > 0 then
    Obj.AddPair('last_fetch', FormatDateTime('yyyy-mm-dd hh:nn:ss', FLastFetch));
  Result.AddPair('automation', Obj);
  if FLastError <> '' then
    Result.AddPair('last_error', FLastError);
end;

function TTriageEngine.LogJSON(ASince: Int64; ALimit: Integer): TJSONArray;
var
  I, First: Integer;
begin
  Result := TJSONArray.Create;
  if ALimit <= 0 then
    ALimit := 100;
  First := FLog.Count;
  while (First > 0) and (FLog[First - 1].Seq > ASince) and (FLog.Count - First < ALimit) do
    Dec(First);
  for I := First to FLog.Count - 1 do
    Result.AddElement(TJSONObject.Create
      .AddPair('seq', TJSONNumber.Create(FLog[I].Seq))
      .AddPair('time', FormatDateTime('yyyy-mm-dd hh:nn:ss', FLog[I].Time))
      .AddPair('text', FLog[I].Text));
end;

function TTriageEngine.WorkshopJSON: TJSONArray;
var
  M: TTriageMail;
  B: TWorkshopBooking;
begin
  Result := TJSONArray.Create;
  for M in FMails do
    if M.AppointmentStart > 0 then
      Result.AddElement(TJSONObject.Create
        .AddPair('id', TJSONNumber.Create(M.ID))
        .AddPair('start', SlotToStr(M.AppointmentStart))
        .AddPair('customer', M.FromDisplay)
        .AddPair('brand', M.Brand)
        .AddPair('subject', M.Subject)
        .AddPair('handler', M.HandlerName)
        .AddPair('synced_to_calendar', TJSONBool.Create(M.AppointmentSynced)));
  // The workshop planning that already existed: these hours are not free
  for B in FBookings do
    if B.Start >= Date then
      Result.AddElement(BookingToJSON(B).AddPair('existing_booking', TJSONBool.Create(True)));
end;

function TTriageEngine.BookingsJSON: TJSONArray;
var
  B: TWorkshopBooking;
begin
  Result := TJSONArray.Create;
  for B in FBookings do
    Result.AddElement(BookingToJSON(B));
end;

end.
