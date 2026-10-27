{ TMS AI Mail Desk - settings page
  Almost every setting lives on the triage server (get_settings /
  update_setting): mailboxes, AI service, dry run, alerts, translation,
  automation. "Save settings" sends what changed; "Connect" logs a mailbox in
  (connect_mailbox). Secrets never come back from the server:
  an empty field keeps the stored value.
  The server address and its token are the dashboard's own settings
  (dashboard.ini). The AI service and key are the assistant's too: a key
  saved here is handed to it (OnAPIKeySaved). }

unit uSettingsFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Edit, FMX.ListBox, FMX.Ani,
  FMX.Controls.Presentation;

type
  TAPIKeyEvent = procedure(const AService, AKey: string) of object;

  TfrSettings = class(TFrame)
    recSettingsCard: TRectangle;
    lblGmailHeader: TLabel;
    lblGmailHint: TLabel;
    lblGmailClientID: TLabel;
    edGmailClientID: TEdit;
    lblGmailSecret: TLabel;
    edGmailSecret: TEdit;
    lblOutlookHeader: TLabel;
    lblOutlookHint: TLabel;
    lblOutlookClientID: TLabel;
    edOutlookClientID: TEdit;
    lblOutlookSecret: TLabel;
    edOutlookSecret: TEdit;
    lblCallback: TLabel;
    edCallback: TEdit;
    lblAIHeader: TLabel;
    lblAIHint: TLabel;
    lblAIService: TLabel;
    cbAIService: TComboBox;
    lblAPIKey: TLabel;
    edAPIKey: TEdit;
    lblMaxMails: TLabel;
    edMaxMails: TEdit;
    btnSaveSettings: TRectangle;
    aniBtnSaveSettings: TFloatAnimation;
    btnSaveSettingsIcon: TLabel;
    btnSaveSettingsText: TLabel;
    lblSettingsInfo: TLabel;
    recAlertsCard: TRectangle;
    lblAlertsHeader: TLabel;
    lblAlertsHint: TLabel;
    lblPushoverToken: TLabel;
    edPushoverToken: TEdit;
    lblPushoverUser: TLabel;
    edPushoverUser: TEdit;
    lblAlertsEnabled: TLabel;
    swAlerts: TSwitch;
    lblCalendarHeader: TLabel;
    lblCalendarInfo: TLabel;
    lblTranslationHeader: TLabel;
    lblTranslationHint: TLabel;
    lblTargetLanguage: TLabel;
    edTargetLanguage: TEdit;
    lblTranslationInfo: TLabel;
    lblAutomationHeader: TLabel;
    lblAutomationHint: TLabel;
    lblAutoFetch: TLabel;
    edAutoFetch: TEdit;
    lblAutoTriage: TLabel;
    swAutoTriage: TSwitch;
    lblAutoDrafts: TLabel;
    swAutoDrafts: TSwitch;
    lblServerHeader: TLabel;
    lblServerURL: TLabel;
    edServerURL: TEdit;
    lblServerToken: TLabel;
    edServerToken: TEdit;
    btnConnectGmail: TRectangle;
    btnConnectGmailText: TLabel;
    aniBtnConnectGmail: TFloatAnimation;
    btnConnectOutlook: TRectangle;
    btnConnectOutlookText: TLabel;
    aniBtnConnectOutlook: TFloatAnimation;
    lblDryRun: TLabel;
    swDryRun: TSwitch;
    procedure btnSaveSettingsClick(Sender: TObject);
    procedure cbAIServiceChange(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
  private
    FUpdating: Boolean;
    FOnAPIKeySaved: TAPIKeyEvent;
  public
    constructor Create(AOwner: TComponent); override;
    // Shows the server's settings (Dashboard.Setting)
    procedure ShowSettings;
    // Shows the server address and token
    procedure ShowServer;
    // Shows whether Gmail and Outlook are connected (Dashboard.Mailbox)
    procedure ShowMailboxes;
    // The server accepted a new AI key: the assistant keeps a copy, as the
    // server never sends it back
    property OnAPIKeySaved: TAPIKeyEvent read FOnAPIKeySaved write FOnAPIKeySaved;
  end;

implementation

{$R *.fmx}

uses
  System.Math, System.StrUtils, System.JSON, System.Generics.Collections, uTriageModel, uEngineClient, uTheme,
  uDashboard;

// Local models need no key
function ServiceNeedsKey(const AService: string): Boolean;
begin
  Result := (AService <> '') and not SameText(AService, 'offline') and not SameText(AService, 'Ollama')
    and not SameText(AService, 'llama.cpp');
end;

constructor TfrSettings.Create(AOwner: TComponent);
begin
  inherited;
  FixComboFont(cbAIService);
end;

procedure TfrSettings.ShowSettings;
var
  Service: string;
  Arr: TJSONArray;
  I: Integer;

  procedure Secret(AEdit: TEdit; const AName: string);
  begin
    AEdit.Text := '';
    if Dashboard.Setting(AName) = 'set' then
      AEdit.TextPrompt := 'set (leave empty to keep)'
    else
      AEdit.TextPrompt := 'not set';
  end;

begin
  FUpdating := True;
  try
    // AI services as the server's TTMSMCPCloudAI offers them; the first item
    // (designed in uSettingsFrame.fmx) is the offline keyword engine
    Service := Dashboard.Setting('ai_service');
    cbAIService.BeginUpdate;
    try
      while cbAIService.Count > 1 do
        cbAIService.Items.Delete(1);
      if Dashboard.Settings.TryGetValue<TJSONArray>('ai_services', Arr) then
        for I := 0 to Arr.Count - 1 do
          if not SameText(Arr.Items[I].Value, 'offline') then
            cbAIService.Items.Add(Arr.Items[I].Value);
    finally
      cbAIService.EndUpdate;
    end;
    cbAIService.ItemIndex := Max(0, cbAIService.Items.IndexOf(Service));
    FixComboFont(cbAIService);
    edAPIKey.Enabled := ServiceNeedsKey(Service);
    Secret(edAPIKey, 'ai_api_key');

    edGmailClientID.Text := Dashboard.Setting('gmail_client_id');
    Secret(edGmailSecret, 'gmail_secret');
    edOutlookClientID.Text := Dashboard.Setting('outlook_client_id');
    Secret(edOutlookSecret, 'outlook_secret');
    edCallback.Text := Dashboard.Setting('callback_url');
    edMaxMails.Text := Dashboard.Setting('max_mails');
    Secret(edPushoverToken, 'pushover_token');
    Secret(edPushoverUser, 'pushover_user');
    swAlerts.IsChecked := Dashboard.SettingBool('alerts_enabled', False);
    edTargetLanguage.Text := Dashboard.Setting('target_language');
    edAutoFetch.Text := Dashboard.Setting('auto_fetch_minutes');
    swAutoTriage.IsChecked := Dashboard.SettingBool('auto_triage', False);
    swAutoDrafts.IsChecked := Dashboard.SettingBool('auto_drafts', False);
    swDryRun.IsChecked := Dashboard.SettingBool('dry_run', True);
  finally
    FUpdating := False;
  end;
end;

procedure TfrSettings.ShowServer;
begin
  edServerURL.Text := Dashboard.ServerURL;
  edServerToken.Text := Dashboard.ServerToken;
end;

procedure TfrSettings.ShowMailboxes;

  procedure Show(ALabel: TLabel; ASource: TMailSource);
  begin
    if Dashboard.Mailbox[ASource] = 'connected' then
      ALabel.Text := #$2713' Connected'
    else if Dashboard.Mailbox[ASource] = 'connecting' then
      ALabel.Text := 'Connecting...'
    else
      ALabel.Text := 'Connect';
  end;

begin
  Show(btnConnectGmailText, msGmail);
  Show(btnConnectOutlookText, msOutlook);
end;

procedure TfrSettings.btnConnectClick(Sender: TObject);
var
  Source: string;
begin
  // The server says what is missing (client ID, secret, callback URL); the
  // first login opens in a browser on the server machine
  Source := IfThen(Sender = btnConnectGmail, 'gmail', 'outlook');
  Dashboard.SetStatus('Connecting ' + Source + '... The first time, sign in in the browser on the server machine.');
  Dashboard.RunTool('connect_mailbox', TJSONObject.Create.AddPair('source', Source)
    .AddPair('interactive', TJSONBool.Create(True)));
end;

procedure TfrSettings.cbAIServiceChange(Sender: TObject);
begin
  if FUpdating or (cbAIService.ItemIndex < 0) then
    Exit;
  edAPIKey.Enabled := (cbAIService.ItemIndex > 0) and ServiceNeedsKey(cbAIService.Selected.Text);
  if cbAIService.Selected.Text <> Dashboard.Setting('ai_service') then
  begin
    // The key on the server belongs to the service that was selected
    edAPIKey.Text := '';
    edAPIKey.TextPrompt := 'enter the API key, then Save settings';
  end;
end;

procedure TfrSettings.btnSaveSettingsClick(Sender: TObject);
var
  Calls: TList<TToolCall>;
  Service, Key: string;

  procedure Put(const AName, AValue: string);
  begin
    Calls.Add(TToolCall.Create('update_setting', TJSONObject.Create.AddPair('name', AName).AddPair('value', AValue)));
  end;

  procedure PutChanged(const AName, AValue: string);
  begin
    if AValue.Trim <> Dashboard.Setting(AName) then
      Put(AName, AValue.Trim);
  end;

  procedure PutSecret(const AName, AValue: string);
  begin
    if AValue.Trim <> '' then
      Put(AName, AValue.Trim);
  end;

  procedure PutBool(const AName: string; AValue: Boolean);
  begin
    if Dashboard.SettingBool(AName, not AValue) <> AValue then
      Put(AName, BoolToStr(AValue, True).ToLower);
  end;

begin
  // The dashboard's own settings: where the server is
  Dashboard.SetServer(edServerURL.Text.Trim, edServerToken.Text.Trim);
  if not Dashboard.Online or not Assigned(Dashboard.Settings) then
  begin
    Dashboard.SetStatus('Server address saved. The other settings can be saved once the server answers.');
    Exit;
  end;

  // Everything else lives on the server: send what changed, one update_setting each
  Calls := TList<TToolCall>.Create;
  try
    if cbAIService.ItemIndex > 0 then
      Service := cbAIService.Selected.Text
    else
      Service := 'offline';
    PutChanged('ai_service', Service);
    Key := '';
    if edAPIKey.Enabled then
      Key := edAPIKey.Text.Trim;
    PutSecret('ai_api_key', Key);
    PutChanged('gmail_client_id', edGmailClientID.Text);
    PutSecret('gmail_secret', edGmailSecret.Text);
    PutChanged('outlook_client_id', edOutlookClientID.Text);
    PutSecret('outlook_secret', edOutlookSecret.Text);
    PutChanged('callback_url', edCallback.Text);
    PutChanged('max_mails', edMaxMails.Text);
    PutSecret('pushover_token', edPushoverToken.Text);
    PutSecret('pushover_user', edPushoverUser.Text);
    PutBool('alerts_enabled', swAlerts.IsChecked);
    PutChanged('target_language', edTargetLanguage.Text);
    PutChanged('auto_fetch_minutes', edAutoFetch.Text);
    PutBool('auto_triage', swAutoTriage.IsChecked);
    PutBool('auto_drafts', swAutoDrafts.IsChecked);
    PutBool('dry_run', swDryRun.IsChecked);
    if Calls.Count = 0 then
    begin
      Dashboard.SetStatus('Nothing changed.');
      Exit;
    end;
    Dashboard.SetStatus('Saving settings on the server...');
    Dashboard.Client.CallSequence(Calls.ToArray,
      procedure(AResult: TJSONValue; const AError: string)
      begin
        if AError = '' then
        begin
          Dashboard.SetStatus('Settings saved on the triage server.');
          if (Key <> '') and Assigned(FOnAPIKeySaved) then
            FOnAPIKeySaved(Service, Key);
        end
        else
        begin
          Dashboard.SetStatus('Settings: ' + AError);
          Dashboard.Log('Settings: ' + AError);
        end;
      end);
  finally
    Calls.Free;
  end;
end;

end.
