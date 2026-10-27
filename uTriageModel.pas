{ TMS AI Mail Desk - showcase demo
  Shared data model: an incoming mail and the result of its triage. }

unit uTriageModel;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TMailSource = (msDemo, msGmail, msOutlook);

  TDepartment = (dpOther, dpSales, dpAccessories, dpMaintenance, dpFinance, dpSecondHand);

  TTriageStatus = (tsNew, tsQueued, tsAnalyzing, tsTriaged, tsForwarding, tsForwarded, tsSimulated, tsError, tsSpam);

  TReplyStatus = (rsNone, rsReady, rsCreating, rsCreated, rsSimulated, rsError);

  TTriageMail = class
  public
    ID: Integer;
    Source: TMailSource;
    SourceID: string;
    ThreadID: string;       // Gmail thread, used to thread the reply draft
    MessageIDHeader: string; // RFC 822 Message-ID, used for In-Reply-To
    FromName: string;
    FromEmail: string;
    Received: string;
    Subject: string;
    Body: string;       // plain text, used for the AI prompt and the preview
    HTMLBody: string;   // original HTML (if any), used when forwarding
    Department: TDepartment;
    Brand: string;
    Priority: string;
    Confidence: Integer;
    Summary: string;
    Reason: string;
    HandlerName: string;
    HandlerEmail: string;
    Engine: string;
    Status: TTriageStatus;
    StatusInfo: string;
    ReplyDraft: string;     // may contain the [SIGNATURE] placeholder
    ReplyStatus: TReplyStatus;
    ReplyInfo: string;
    DraftID: string;        // saved reply draft in the mailbox, updated when the reply is saved again
    DraftVia: TMailSource;  // mailbox that holds the draft
    AppointmentStart: TDateTime;  // suggested workshop slot, 0 = none
    AppointmentSynced: Boolean;
    CancelBookingStart: TDateTime; // existing booking the customer cancels or moves (triage result, applied once)
    Alerted: Boolean;             // urgent alert sent to the on-call mechanic
    Attachments: TArray<string>;  // local copies of image / PDF attachments
    AttachmentNotes: string;      // what the AI saw in the attachments
    HistoryInfo: string;          // earlier contact with this customer (SQLite)
    PreviousDepartment: TDepartment;
    PreviousHandlerName: string;  // handler of the last mail in the same department
    PreviousHandlerEmail: string;
    Translation: string;          // AI translation of the body, made on request
    SourceLanguage: string;
    IsSpam: Boolean;              // flagged by the triage, waits on the Spam page
    NotSpam: Boolean;             // a person said it is not spam: never flag again
    SpamReason: string;
    FiledIn: string;              // mailbox folder / label after forwarding, e.g. Triage/Sales
    function FromDisplay: string;
    function IsTriaged: Boolean;
  end;

  TTriageMailList = class(TObjectList<TTriageMail>)
  public
    function FindByID(AID: Integer): TTriageMail;
    function ContainsSourceID(ASource: TMailSource; const ASourceID: string): Boolean;
  end;

  // An appointment that was in the workshop planning before the triage
  // (phone or counter bookings): its hour is not free for a mail
  TWorkshopBooking = record
    Start: TDateTime;
    Customer: string;
    Vehicle: string;
    Job: string;
  end;

const
  // A workshop slot is one hour: the first starts at 08:00, the last at 16:00
  WorkshopFirstHour = 8;
  WorkshopLastHour = 16;

const
  DepartmentKeys: array[TDepartment] of string =
    ('other', 'sales', 'accessories', 'maintenance', 'finance', 'secondhand');
  // Order must match the filter chips in uInboxFrame.fmx (chip Tag = ordinal)
  DepartmentNames: array[TDepartment] of string =
    ('Reception', 'Sales', 'Accessories', 'Maintenance', 'Finance', 'Second-hand');
  SourceNames: array[TMailSource] of string =
    ('Demo', 'Gmail', 'Outlook');
  StatusNames: array[TTriageStatus] of string =
    ('New', 'Queued', 'Analyzing...', 'Triaged', 'Forwarding...', 'Forwarded', 'Forwarded (dry run)', 'Error', 'Spam');
  ReplyStatusNames: array[TReplyStatus] of string =
    ('', 'Ready', 'Saving...', 'Draft saved', 'Draft (simulated)', 'Error');

  SignaturePlaceholder = '[SIGNATURE]';
  CompanyName = 'Brightline Motors';

  PriorityLow = 'Low';
  PriorityNormal = 'Normal';
  PriorityHigh = 'High';
  PriorityUrgent = 'Urgent';

function DepartmentFromKey(const AKey: string): TDepartment;
function NormalizePriority(const AValue: string): string;
function HtmlToPlainText(const AHtml: string): string;
function HtmlEncode(const AText: string): string;
procedure SplitAddress(const AAddress: string; out AName, AEmail: string);
// 'yyyy-mm-dd hh:nn' -> TDateTime, 0 when invalid
function ParseSlot(const AValue: string): TDateTime;
// ASlot when a workshop job can start then, else the first workshop hour after it (weekdays only)
function NextWorkshopTime(ASlot: TDateTime): TDateTime;
// Handler signature that replaces [SIGNATURE] in a reply
function Signature(AMail: TTriageMail): string;
// The reply as the customer sees it: line breaks normalised, signature filled in
function RenderReply(AMail: TTriageMail): string;

implementation

uses
  System.RegularExpressions;

{ TTriageMail }

function TTriageMail.FromDisplay: string;
begin
  if FromName <> '' then
    Result := FromName + ' <' + FromEmail + '>'
  else
    Result := FromEmail;
end;

function TTriageMail.IsTriaged: Boolean;
begin
  Result := Status in [tsTriaged, tsForwarding, tsForwarded, tsSimulated];
end;

{ TTriageMailList }

function TTriageMailList.FindByID(AID: Integer): TTriageMail;
var
  M: TTriageMail;
begin
  for M in Self do
    if M.ID = AID then
      Exit(M);
  Result := nil;
end;

function TTriageMailList.ContainsSourceID(ASource: TMailSource; const ASourceID: string): Boolean;
var
  M: TTriageMail;
begin
  for M in Self do
    if (M.Source = ASource) and (M.SourceID = ASourceID) then
      Exit(True);
  Result := False;
end;

{ Helpers }

function CompactKey(const AValue: string): string;
var
  C: Char;
begin
  Result := '';
  for C in AValue.ToLower do
    if CharInSet(C, ['a'..'z']) then
      Result := Result + C;
end;

function DepartmentFromKey(const AKey: string): TDepartment;
var
  K: string;
  D: TDepartment;
begin
  K := CompactKey(AKey);
  for D := Low(TDepartment) to High(TDepartment) do
    if (K = DepartmentKeys[D]) or (K = CompactKey(DepartmentNames[D])) then
      Exit(D);

  // Be forgiving about synonyms an LLM might return
  if (K = 'service') or (K = 'workshop') or (K = 'repair') or (K = 'aftersales') then
    Result := dpMaintenance
  else if (K = 'parts') or (K = 'accessory') then
    Result := dpAccessories
  else if (K = 'used') or (K = 'usedcars') or (K = 'occasion') or (K = 'preowned') then
    Result := dpSecondHand
  else if (K = 'newcars') or (K = 'newcar') then
    Result := dpSales
  else if (K = 'leasing') or (K = 'accounting') or (K = 'billing') then
    Result := dpFinance
  else
    Result := dpOther;
end;

function NormalizePriority(const AValue: string): string;
var
  K: string;
begin
  K := CompactKey(AValue);
  if K = 'urgent' then
    Result := PriorityUrgent
  else if K = 'high' then
    Result := PriorityHigh
  else if K = 'low' then
    Result := PriorityLow
  else
    Result := PriorityNormal;
end;

function DecodeEntities(const AText: string): string;
var
  Match: TMatch;
begin
  Result := AText;
  for Match in TRegEx.Matches(AText, '&#(\d+);') do
    Result := Result.Replace(Match.Value, Char(StrToIntDef(Match.Groups[1].Value, 32)), [rfReplaceAll]);
  Result := Result
    .Replace('&nbsp;', ' ', [rfReplaceAll, rfIgnoreCase])
    .Replace('&lt;', '<', [rfReplaceAll, rfIgnoreCase])
    .Replace('&gt;', '>', [rfReplaceAll, rfIgnoreCase])
    .Replace('&quot;', '"', [rfReplaceAll, rfIgnoreCase])
    .Replace('&#39;', '''', [rfReplaceAll])
    .Replace('&euro;', #$20AC, [rfReplaceAll, rfIgnoreCase])
    .Replace('&amp;', '&', [rfReplaceAll, rfIgnoreCase]);
end;

function HtmlToPlainText(const AHtml: string): string;
var
  S: string;
  Lines: TStringList;
  I: Integer;
begin
  S := TRegEx.Replace(AHtml, '<(style|script|head)[^>]*>.*?</\1>', '', [roIgnoreCase, roSingleLine]);
  S := TRegEx.Replace(S, '<br\s*/?>|</p>|</div>|</tr>|</li>|</h\d>', sLineBreak, [roIgnoreCase]);
  S := TRegEx.Replace(S, '<[^>]+>', '');
  S := DecodeEntities(S);

  Lines := TStringList.Create;
  try
    Lines.Text := S;
    for I := Lines.Count - 1 downto 0 do
    begin
      Lines[I] := Lines[I].Trim;
      // collapse runs of empty lines
      if (Lines[I] = '') and ((I = Lines.Count - 1) or (Lines[I + 1] = '')) then
        Lines.Delete(I);
    end;
    Result := Lines.Text.Trim;
  finally
    Lines.Free;
  end;
end;

function HtmlEncode(const AText: string): string;
begin
  Result := AText
    .Replace('&', '&amp;', [rfReplaceAll])
    .Replace('<', '&lt;', [rfReplaceAll])
    .Replace('>', '&gt;', [rfReplaceAll])
    .Replace('"', '&quot;', [rfReplaceAll]);
end;

procedure SplitAddress(const AAddress: string; out AName, AEmail: string);
var
  P1, P2: Integer;
begin
  P1 := AAddress.LastIndexOf('<');
  P2 := AAddress.LastIndexOf('>');
  if (P1 >= 0) and (P2 > P1) then
  begin
    AEmail := AAddress.Substring(P1 + 1, P2 - P1 - 1).Trim;
    AName := AAddress.Substring(0, P1).Trim.DeQuotedString('"').Trim;
  end
  else
  begin
    AEmail := AAddress.Trim;
    AName := '';
  end;
end;

function ParseSlot(const AValue: string): TDateTime;
var
  FS: TFormatSettings;
begin
  FS := TFormatSettings.Invariant;
  FS.ShortDateFormat := 'yyyy-mm-dd';
  FS.DateSeparator := '-';
  FS.ShortTimeFormat := 'hh:nn';
  FS.TimeSeparator := ':';
  if not TryStrToDateTime(AValue, Result, FS) then
    Result := 0;
end;

function NextWorkshopTime(ASlot: TDateTime): TDateTime;
const
  HalfMinute = 1 / 2880;
var
  Day, Time: TDateTime;
begin
  Day := Int(ASlot);
  Time := ASlot - Day;
  if Time < EncodeTime(WorkshopFirstHour, 0, 0, 0) then
    Time := EncodeTime(WorkshopFirstHour, 0, 0, 0)
  else if Time > EncodeTime(WorkshopLastHour, 0, 0, 0) + HalfMinute then
  begin
    Day := Day + 1;
    Time := EncodeTime(WorkshopFirstHour, 0, 0, 0);
  end;
  while DayOfWeek(Day) in [1, 7] do  // Sunday, Saturday
  begin
    Day := Day + 1;
    Time := EncodeTime(WorkshopFirstHour, 0, 0, 0);
  end;
  Result := Day + Time;
end;

function Signature(AMail: TTriageMail): string;
begin
  if (AMail.HandlerName <> '') and (AMail.Department <> dpOther) then
    Result := AMail.HandlerName + sLineBreak + DepartmentNames[AMail.Department] + ' - ' + CompanyName
  else
    Result := DepartmentNames[dpOther] + ' - ' + CompanyName;
end;

function RenderReply(AMail: TTriageMail): string;
begin
  // Normalise line breaks (JSON \n) and fill in the signature of the current handler
  Result := AMail.ReplyDraft.Replace(#13#10, #10, [rfReplaceAll]).Replace(#10, sLineBreak, [rfReplaceAll]);
  Result := Result.Replace(SignaturePlaceholder, Signature(AMail), [rfReplaceAll]);
end;

end.
