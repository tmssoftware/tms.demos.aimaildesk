{ TMS AI Mail Desk - showcase demo
  A mail as JSON, shared by the MCP server (tool results, inbox.json) and the
  dashboard app (state snapshots from the server). Enum values travel as
  stable lowercase keys, so the JSON is also readable for an LLM. }

unit uMailJSON;

interface

uses
  System.SysUtils, System.JSON, uTriageModel;

const
  StatusKeys: array[TTriageStatus] of string =
    ('new', 'queued', 'analyzing', 'triaged', 'forwarding', 'forwarded', 'dry_run', 'error', 'spam');
  ReplyStatusKeys: array[TReplyStatus] of string =
    ('none', 'ready', 'saving', 'saved', 'simulated', 'error');
  SourceKeys: array[TMailSource] of string =
    ('demo', 'gmail', 'outlook');

type
  // mjList: inbox listing (preview, no reply text)
  // mjFull: everything a person or an LLM needs to work on the mail
  // mjState: mjFull plus the fields that only matter to the server (HTML body, ids) for inbox.json
  TMailJSONDetail = (mjList, mjFull, mjState);

function MailToJSON(AMail: TTriageMail; ADetail: TMailJSONDetail): TJSONObject;
function MailFromJSON(AObj: TJSONObject): TTriageMail;

function BookingToJSON(const ABooking: TWorkshopBooking): TJSONObject;
function BookingFromJSON(AObj: TJSONObject): TWorkshopBooking;

function StatusFromKey(const AKey: string): TTriageStatus;
function ReplyStatusFromKey(const AKey: string): TReplyStatus;
function SourceFromKey(const AKey: string): TMailSource;

// 'yyyy-mm-dd hh:nn' (local time); '' for 0
function SlotToStr(AValue: TDateTime): string;

implementation

uses
  System.Generics.Collections;

function SlotToStr(AValue: TDateTime): string;
begin
  if AValue = 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', AValue);
end;

function BookingToJSON(const ABooking: TWorkshopBooking): TJSONObject;
begin
  Result := TJSONObject.Create
    .AddPair('start', SlotToStr(ABooking.Start))
    .AddPair('customer', ABooking.Customer)
    .AddPair('vehicle', ABooking.Vehicle)
    .AddPair('job', ABooking.Job);
end;

function BookingFromJSON(AObj: TJSONObject): TWorkshopBooking;
begin
  Result.Start := ParseSlot(AObj.GetValue<string>('start', ''));
  Result.Customer := AObj.GetValue<string>('customer', '');
  Result.Vehicle := AObj.GetValue<string>('vehicle', '');
  Result.Job := AObj.GetValue<string>('job', '');
end;

function StatusFromKey(const AKey: string): TTriageStatus;
begin
  for Result := Low(TTriageStatus) to High(TTriageStatus) do
    if SameText(StatusKeys[Result], AKey) then
      Exit;
  Result := tsNew;
end;

function ReplyStatusFromKey(const AKey: string): TReplyStatus;
begin
  for Result := Low(TReplyStatus) to High(TReplyStatus) do
    if SameText(ReplyStatusKeys[Result], AKey) then
      Exit;
  Result := rsNone;
end;

function SourceFromKey(const AKey: string): TMailSource;
begin
  for Result := Low(TMailSource) to High(TMailSource) do
    if SameText(SourceKeys[Result], AKey) then
      Exit;
  Result := msDemo;
end;

function MailToJSON(AMail: TTriageMail; ADetail: TMailJSONDetail): TJSONObject;
var
  Arr: TJSONArray;
  S: string;

  procedure Add(const AName, AValue: string);
  begin
    // Empty values are left out: shorter for the LLM, and the reader defaults them
    if AValue <> '' then
      Result.AddPair(AName, AValue);
  end;

begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AMail.ID));
  Result.AddPair('source', SourceKeys[AMail.Source]);
  Result.AddPair('from_name', AMail.FromName);
  Result.AddPair('from_email', AMail.FromEmail);
  Result.AddPair('received', AMail.Received);
  Result.AddPair('subject', AMail.Subject);
  Result.AddPair('status', StatusKeys[AMail.Status]);
  Add('status_info', AMail.StatusInfo);

  if ADetail = mjList then
    Result.AddPair('preview', Copy(AMail.Body, 1, 160))
  else
    Result.AddPair('body', AMail.Body);

  if AMail.IsTriaged or (ADetail = mjState) then
  begin
    Result.AddPair('department', DepartmentKeys[AMail.Department]);
    Add('brand', AMail.Brand);
    Add('priority', AMail.Priority);
    Result.AddPair('confidence', TJSONNumber.Create(AMail.Confidence));
    Add('handler_name', AMail.HandlerName);
    Add('handler_email', AMail.HandlerEmail);
    Add('summary', AMail.Summary);
    Result.AddPair('reply_status', ReplyStatusKeys[AMail.ReplyStatus]);
    Add('appointment', SlotToStr(AMail.AppointmentStart));
  end;

  if ADetail = mjList then
    Exit;

  Add('reason', AMail.Reason);
  Add('engine', AMail.Engine);
  Add('reply_info', AMail.ReplyInfo);
  if ADetail = mjState then
    Add('reply_draft', AMail.ReplyDraft)          // with the [SIGNATURE] placeholder
  else if AMail.IsTriaged then
    Add('reply_draft', RenderReply(AMail));       // as the customer will see it
  if AMail.AppointmentSynced then
    Result.AddPair('appointment_synced', TJSONBool.Create(True));
  if AMail.Alerted then
    Result.AddPair('alerted', TJSONBool.Create(True));
  if Length(AMail.Attachments) > 0 then
  begin
    Arr := TJSONArray.Create;
    for S in AMail.Attachments do
      if ADetail = mjState then
        Arr.Add(S)
      else
        Arr.Add(ExtractFileName(S));
    Result.AddPair('attachments', Arr);
  end;
  Add('attachment_notes', AMail.AttachmentNotes);
  Add('history', AMail.HistoryInfo);
  Add('translation', AMail.Translation);
  Add('source_language', AMail.SourceLanguage);
  if AMail.IsSpam or (AMail.Status = tsSpam) then
    Result.AddPair('is_spam', TJSONBool.Create(True));
  Add('spam_reason', AMail.SpamReason);
  if AMail.NotSpam then
    Result.AddPair('not_spam', TJSONBool.Create(True));
  Add('filed_in', AMail.FiledIn);

  if ADetail = mjState then
  begin
    Add('source_id', AMail.SourceID);
    Add('thread_id', AMail.ThreadID);
    Add('message_id', AMail.MessageIDHeader);
    if AMail.DraftID <> '' then
    begin
      Result.AddPair('draft_id', AMail.DraftID);
      Result.AddPair('draft_via', SourceKeys[AMail.DraftVia]);
    end;
    Add('html_body', AMail.HTMLBody);
    Add('previous_handler_name', AMail.PreviousHandlerName);
    Add('previous_handler_email', AMail.PreviousHandlerEmail);
    Result.AddPair('previous_department', DepartmentKeys[AMail.PreviousDepartment]);
  end;
end;

function MailFromJSON(AObj: TJSONObject): TTriageMail;
var
  Arr: TJSONArray;
  I: Integer;

  function Str(const AName: string): string;
  begin
    Result := AObj.GetValue<string>(AName, '');
  end;

begin
  Result := TTriageMail.Create;
  Result.ID := AObj.GetValue<Integer>('id', 0);
  Result.Source := SourceFromKey(Str('source'));
  Result.SourceID := Str('source_id');
  Result.ThreadID := Str('thread_id');
  Result.MessageIDHeader := Str('message_id');
  Result.FromName := Str('from_name');
  Result.FromEmail := Str('from_email');
  Result.Received := Str('received');
  Result.Subject := Str('subject');
  Result.Body := Str('body');
  if Result.Body = '' then
    Result.Body := Str('preview');
  Result.HTMLBody := Str('html_body');
  Result.Department := DepartmentFromKey(Str('department'));
  Result.Brand := Str('brand');
  Result.Priority := Str('priority');
  Result.Confidence := AObj.GetValue<Integer>('confidence', 0);
  Result.Summary := Str('summary');
  Result.Reason := Str('reason');
  Result.HandlerName := Str('handler_name');
  Result.HandlerEmail := Str('handler_email');
  Result.Engine := Str('engine');
  Result.Status := StatusFromKey(Str('status'));
  Result.StatusInfo := Str('status_info');
  Result.ReplyDraft := Str('reply_draft');
  Result.ReplyStatus := ReplyStatusFromKey(Str('reply_status'));
  Result.ReplyInfo := Str('reply_info');
  Result.DraftID := Str('draft_id');
  Result.DraftVia := SourceFromKey(Str('draft_via'));
  Result.AppointmentStart := ParseSlot(Str('appointment'));
  Result.AppointmentSynced := AObj.GetValue<Boolean>('appointment_synced', False);
  Result.Alerted := AObj.GetValue<Boolean>('alerted', False);
  if AObj.TryGetValue<TJSONArray>('attachments', Arr) then
  begin
    SetLength(Result.Attachments, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      Result.Attachments[I] := Arr.Items[I].Value;
  end;
  Result.AttachmentNotes := Str('attachment_notes');
  Result.HistoryInfo := Str('history');
  Result.PreviousDepartment := DepartmentFromKey(Str('previous_department'));
  Result.PreviousHandlerName := Str('previous_handler_name');
  Result.PreviousHandlerEmail := Str('previous_handler_email');
  Result.Translation := Str('translation');
  Result.SourceLanguage := Str('source_language');
  Result.IsSpam := AObj.GetValue<Boolean>('is_spam', False);
  Result.NotSpam := AObj.GetValue<Boolean>('not_spam', False);
  Result.SpamReason := Str('spam_reason');
  Result.FiledIn := Str('filed_in');
end;

end.
