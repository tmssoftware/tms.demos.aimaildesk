{ TMS AI Mail Desk - showcase demo
  Mail plumbing shared by the FMX app and the MCP server: where the shared
  settings live, mapping FNC Cloud Pack mail items to TTriageMail, and the
  forward message. The MCP server is a console app and defines GARAGE_VCL to
  use the VCL flavour of the (identical) FNC components. }

unit uMailSources;

interface

uses
  System.SysUtils, uTriageModel,
  {$IFDEF GARAGE_VCL}
  VCL.TMSFNCCloudGoogleGmail, VCL.TMSFNCCloudMicrosoftOutlookMail;
  {$ELSE}
  FMX.TMSFNCCloudGoogleGmail, FMX.TMSFNCCloudMicrosoftOutlookMail;
  {$ENDIF}

// %APPDATA%\TMSGarageMailDesk: settings.ini, routing.json, OAuth tokens
function AppDataDir: string;

function MailFromGmail(AMessage: TTMSFNCCloudGoogleGmailMessage): TTriageMail;
function MailFromOutlook(AItem: TTMSFNCCloudMicrosoftOutlookMailItem): TTriageMail;

function BuildForwardSubject(AMail: TTriageMail): string;
function BuildForwardHtml(AMail: TTriageMail): string;

implementation

uses
  System.IOUtils, System.StrUtils,
  {$IFDEF GARAGE_VCL}VCL.TMSFNCCloudOAuth{$ELSE}FMX.TMSFNCCloudOAuth{$ENDIF};

function AppDataDir: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'TMSGarageMailDesk');
  ForceDirectories(Result);
end;

function MailFromGmail(AMessage: TTMSFNCCloudGoogleGmailMessage): TTriageMail;
var
  H: Integer;
begin
  Result := TTriageMail.Create;
  Result.Source := msGmail;
  Result.SourceID := AMessage.ID;
  Result.ThreadID := AMessage.ThreadId;
  for H := 0 to AMessage.Headers.Count - 1 do
    if SameText(AMessage.Headers[H].Name, 'Message-ID') then
      Result.MessageIDHeader := AMessage.Headers[H].Value;
  SplitAddress(AMessage.From, Result.FromName, Result.FromEmail);
  Result.Received := AMessage.Date;
  Result.Subject := AMessage.Subject;
  Result.HTMLBody := AMessage.HTMLBody;
  Result.Body := AMessage.Body.Trim;
  if Result.Body = '' then
    Result.Body := HtmlToPlainText(AMessage.HTMLBody);
  if Result.Body = '' then
    Result.Body := AMessage.Snippet;
end;

function MailFromOutlook(AItem: TTMSFNCCloudMicrosoftOutlookMailItem): TTriageMail;
begin
  Result := TTriageMail.Create;
  Result.Source := msOutlook;
  Result.SourceID := AItem.ID;
  Result.FromName := AItem.FromName;
  Result.FromEmail := AItem.FromEmail;
  Result.Received := FormatDateTime('yyyy-mm-dd hh:nn', AItem.ReceivedDateTime);
  Result.Subject := AItem.Subject;
  if AItem.MailType = mtHTML then
  begin
    Result.HTMLBody := AItem.Body;
    Result.Body := HtmlToPlainText(AItem.Body);
  end
  else
    Result.Body := AItem.Body.Trim;
end;

function BuildForwardSubject(AMail: TTriageMail): string;
begin
  Result := Format('FW: [%s/%s] %s', [DepartmentNames[AMail.Department], AMail.Brand, AMail.Subject]);
  if AMail.Priority = PriorityUrgent then
    Result := '[URGENT] ' + Result;
end;

function BuildForwardHtml(AMail: TTriageMail): string;

  function Row(const ALabel, AValue: string): string;
  begin
    Result := '<tr><td style="padding:2px 12px 2px 0;color:#57606a"><b>' + ALabel + '</b></td><td>' + HtmlEncode(AValue) + '</td></tr>';
  end;

  function Optional(const ALabel, AValue: string): string;
  begin
    if AValue <> '' then
      Result := Row(ALabel, AValue)
    else
      Result := '';
  end;

var
  Original, Translated: string;
begin
  Translated := '';
  if AMail.Translation <> '' then
    Translated := '<p><b>Translation (' + IfThen(AMail.SourceLanguage <> '', 'from ' + HtmlEncode(AMail.SourceLanguage) + ', ', '') +
      'AI)</b><br>' +
      HtmlEncode(AMail.Translation).Replace(#13#10, '<br>').Replace(#10, '<br>') + '</p>';
  if AMail.HTMLBody <> '' then
    Original := AMail.HTMLBody
  else
    Original := HtmlEncode(AMail.Body).Replace(#13#10, '<br>').Replace(#10, '<br>');

  Result :=
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:13px">' +
    '<table style="border-left:4px solid #2563eb;background:#f6f8fa;padding:8px 12px;margin-bottom:16px">' +
    '<tr><td colspan="2" style="padding-bottom:6px"><b>Routed to you by TMS AI Mail Desk</b></td></tr>' +
    Row('Department', DepartmentNames[AMail.Department]) +
    Row('Brand', AMail.Brand) +
    Row('Priority', AMail.Priority) +
    Row('Confidence', AMail.Confidence.ToString + '%') +
    Row('Summary', AMail.Summary) +
    Row('Reason', AMail.Reason) +
    Row('Reply draft', ReplyStatusNames[AMail.ReplyStatus]) +
    Optional('Attachments', AMail.AttachmentNotes) +
    Optional('Earlier contact', AMail.HistoryInfo) +
    '</table>' +
    Translated +
    '<p>---------- Forwarded message ----------<br>' +
    'From: ' + HtmlEncode(AMail.FromDisplay) + '<br>' +
    'Date: ' + HtmlEncode(AMail.Received) + '<br>' +
    'Subject: ' + HtmlEncode(AMail.Subject) + '</p>' +
    '</div>' + Original;
end;

end.
