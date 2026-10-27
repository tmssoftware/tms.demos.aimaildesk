{ TMS AI Mail Desk - showcase demo
  Prompt building and response parsing for TTMSMCPCloudAI (TMS AI Studio),
  plus a small keyword based fallback so the demo still works offline. }

unit uTriageAI;

interface

uses
  System.SysUtils, System.Classes, uTriageModel, uRouting;

const
  MaxBodyChars = 6000;

function BuildSystemPrompt(ARouting: TRoutingTable): string;
function BuildMailPrompt(AMail: TTriageMail; const AFreeSlots: string = ''; const ABookings: string = ''): string;
function ApplyAIResponse(AMail: TTriageMail; const AResponse: string; ARouting: TRoutingTable): Boolean;
procedure ApplyKeywordTriage(AMail: TTriageMail; ARouting: TRoutingTable);
procedure AssignHandler(AMail: TTriageMail; ARouting: TRoutingTable);
function AttachmentNames(AMail: TTriageMail): TArray<string>;
// Offline spam check (keyword score); sets IsSpam and SpamReason
procedure DetectSpam(AMail: TTriageMail);
// Translation on request, by the same AI service: system prompt, user prompt
// and the answer (sets Translation and SourceLanguage)
function BuildTranslateSystemPrompt(const ATargetLanguage: string): string;
function BuildTranslatePrompt(AMail: TTriageMail): string;
function ApplyTranslateResponse(AMail: TTriageMail; const AResponse: string): Boolean;

implementation

uses
  System.JSON, System.Math, System.StrUtils, System.RegularExpressions, uReplyDrafts;

function BuildSystemPrompt(ARouting: TRoutingTable): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('You are the email triage assistant of Brightline Motors, a multi-brand car dealership and garage.');
    SB.AppendLine('Customers write in English, Dutch, French or German. Classify every email into exactly ONE department:');
    SB.AppendLine('- sales: buying a NEW car, quotes, test drives, configuration, delivery of a new car order.');
    SB.AppendLine('- accessories: parts and accessories such as tow bars, roof boxes, floor mats, wheels/rims, charging cables, merchandise.');
    SB.AppendLine('- maintenance: servicing, repairs, inspections, warning lights, recalls, warranty repairs, tyre changes, breakdowns, workshop appointments.');
    SB.AppendLine('- finance: leasing, loans, financing offers, invoices, payments, refunds, insurance.');
    SB.AppendLine('- secondhand: buying or selling a USED / pre-owned car, trade-in valuations.');
    SB.AppendLine('- other: anything else (job applications, suppliers, general questions).');
    SB.AppendLine;
    SB.AppendLine('Brands we sell and service: ' + string.Join(', ', ARouting.Brands) + '.');
    SB.AppendLine('Use exactly one of these brand names, or "Other" when the brand is different or cannot be determined.');
    SB.AppendLine;
    SB.AppendLine('Priority: "urgent" = car broken down, safety issue or legal threat; "high" = complaint, customer waiting or deadline within days;');
    SB.AppendLine('"normal" = regular request; "low" = informational, newsletters, no action needed.');
    SB.AppendLine;
    SB.AppendLine('Reply with ONLY a JSON object (no markdown, no code fences) with exactly these fields:');
    SB.AppendLine('{"department":"sales|accessories|maintenance|finance|secondhand|other",');
    SB.AppendLine(' "brand":"<brand or Other>",');
    SB.AppendLine(' "priority":"low|normal|high|urgent",');
    SB.AppendLine(' "confidence":<integer 0-100>,');
    SB.AppendLine(' "summary":"<one short sentence in English for the handler>",');
    SB.AppendLine(' "reason":"<short explanation of the classification>",');
    SB.AppendLine(' "reply":"<draft reply to the customer>",');
    SB.AppendLine(' "appointment":"<YYYY-MM-DD HH:MM or empty>",');
    SB.AppendLine(' "cancel_booking":"<YYYY-MM-DD HH:MM or empty>",');
    SB.AppendLine(' "attachments":"<what the attached photos or documents show, or empty>",');
    SB.AppendLine(' "spam":true|false,');
    SB.AppendLine(' "spam_reason":"<why it is spam, or empty>"}');
    SB.AppendLine;
    SB.AppendLine('Rules for "spam": true for unsolicited bulk mail, phishing, scams, prize or lottery mails, crypto or');
    SB.AppendLine('investment offers and cold sales pitches to the dealership (SEO, marketing, leads). A real customer,');
    SB.AppendLine('supplier or job applicant is never spam, even when the mail is short or rude.');
    SB.AppendLine;
    SB.AppendLine('Rules for "attachments": describe what matters for the handler, e.g. warning lights on a dashboard photo,');
    SB.AppendLine('visible damage, or an invoice number, date and amount. Use them in the classification and priority.');
    SB.AppendLine('If "Earlier contact" is given, take it into account (e.g. a follow-up on an earlier repair).');
    SB.AppendLine;
    SB.AppendLine('Rules for "appointment": only for maintenance requests that need a workshop visit (not breakdowns),');
    SB.AppendLine('suggest a slot that matches the customer''s wishes: a weekday between 08:00 and 17:00, on or after the');
    SB.AppendLine('next working day after "Today". Pick it from "Free workshop slots" when given: every other hour is');
    SB.AppendLine('already booked. When the wished day or time is fully booked, take the free slot closest to the wish.');
    SB.AppendLine('Otherwise use an empty string.');
    SB.AppendLine;
    SB.AppendLine('Rules for "cancel_booking": the start of a booking from "Workshop bookings of this customer" that the');
    SB.AppendLine('customer cancels or asks to move; otherwise an empty string. When they ask to move it, also suggest');
    SB.AppendLine('the new slot in "appointment". The reply may confirm the cancellation.');
    SB.AppendLine;
    SB.AppendLine('Rules for "reply": write it in the SAME language as the customer email, max 120 words, friendly and professional.');
    SB.AppendLine('Address the customer by name, thank them, and say which team will follow up and what happens next.');
    SB.AppendLine('Never invent prices, dates, appointments, stock or availability. For breakdowns or safety issues,');
    SB.AppendLine('advise calling roadside assistance. Use \n for line breaks and end the reply with the line ' + SignaturePlaceholder);
    SB.AppendLine('instead of a name; it is replaced by the handler''s signature.');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function AttachmentNames(AMail: TTriageMail): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(AMail.Attachments));
  for I := 0 to High(AMail.Attachments) do
    Result[I] := ExtractFileName(AMail.Attachments[I]);
end;

function BuildMailPrompt(AMail: TTriageMail; const AFreeSlots, ABookings: string): string;
var
  Body: string;
begin
  Body := AMail.Body;
  if Body.Length > MaxBodyChars then
    Body := Body.Substring(0, MaxBodyChars) + sLineBreak + '[...truncated...]';

  Result :=
    'Classify the following customer email.' + sLineBreak +
    'Today: ' + FormatDateTime('yyyy-mm-dd (dddd)', Date, TFormatSettings.Invariant) + sLineBreak +
    'From: ' + AMail.FromDisplay + sLineBreak +
    'Date: ' + AMail.Received + sLineBreak +
    'Subject: ' + AMail.Subject + sLineBreak +
    'Body:' + sLineBreak + Body;
  if Length(AMail.Attachments) > 0 then
    Result := Result + sLineBreak + sLineBreak + 'Attachments (attached to this request): ' +
      string.Join(', ', AttachmentNames(AMail));
  if AMail.HistoryInfo <> '' then
    Result := Result + sLineBreak + sLineBreak + 'Earlier contact with this customer:' + sLineBreak + AMail.HistoryInfo;
  if AFreeSlots <> '' then
    Result := Result + sLineBreak + sLineBreak + 'Free workshop slots (one hour each):' + sLineBreak + AFreeSlots;
  if ABookings <> '' then
    Result := Result + sLineBreak + sLineBreak + 'Workshop bookings of this customer:' + sLineBreak + ABookings;
end;

function JsonStr(AObj: TJSONObject; const AName: string): string;
var
  V: TJSONValue;
begin
  V := AObj.GetValue(AName);
  if Assigned(V) and not (V is TJSONNull) then
    Result := V.Value.Trim
  else
    Result := '';
end;

function NextWorkingDay(ADate: TDateTime): TDateTime;
begin
  Result := Trunc(ADate) + 1;
  while DayOfWeek(Result) in [1, 7] do  // Sunday, Saturday
    Result := Result + 1;
end;

function ParseConfidence(const AValue: string): Integer;
var
  F: Double;
begin
  F := StrToFloatDef(AValue.Replace('%', ''), 0, TFormatSettings.Invariant);
  if (F > 0) and (F <= 1) and AValue.Contains('.') then
    F := F * 100;
  Result := EnsureRange(Round(F), 0, 100);
end;

// The JSON object in an AI answer, nil when there is none (the caller frees it)
function ParseAIObject(const AResponse: string): TJSONObject;
var
  P1, P2: Integer;
  V: TJSONValue;
begin
  Result := nil;
  // LLMs sometimes wrap JSON in ```json fences or add a sentence: take the outer object
  P1 := AResponse.IndexOf('{');
  P2 := AResponse.LastIndexOf('}');
  if (P1 < 0) or (P2 <= P1) then
    Exit;
  V := TJSONObject.ParseJSONValue(AResponse.Substring(P1, P2 - P1 + 1));
  if V is TJSONObject then
    Result := TJSONObject(V)
  else
    V.Free;
end;

function ApplyAIResponse(AMail: TTriageMail; const AResponse: string; ARouting: TRoutingTable): Boolean;
var
  Obj: TJSONObject;
begin
  Obj := ParseAIObject(AResponse);
  Result := Assigned(Obj);
  if not Result then
    Exit;
  try
    AMail.Department := DepartmentFromKey(JsonStr(Obj, 'department'));
    AMail.Brand := ARouting.NormalizeBrand(JsonStr(Obj, 'brand'));
    AMail.Priority := NormalizePriority(JsonStr(Obj, 'priority'));
    AMail.Confidence := ParseConfidence(JsonStr(Obj, 'confidence'));
    AMail.Summary := JsonStr(Obj, 'summary');
    AMail.Reason := JsonStr(Obj, 'reason');
    AssignHandler(AMail, ARouting);
    AMail.ReplyDraft := JsonStr(Obj, 'reply');
    if AMail.ReplyDraft = '' then
      AMail.ReplyDraft := TemplateReply(AMail);
    AMail.ReplyStatus := rsReady;
    AMail.AppointmentStart := ParseSlot(JsonStr(Obj, 'appointment'));
    AMail.CancelBookingStart := ParseSlot(JsonStr(Obj, 'cancel_booking'));
    AMail.AttachmentNotes := JsonStr(Obj, 'attachments');
    AMail.IsSpam := SameText(JsonStr(Obj, 'spam'), 'true') and not AMail.NotSpam;
    AMail.SpamReason := JsonStr(Obj, 'spam_reason');
  finally
    Obj.Free;
  end;
end;

function BuildTranslateSystemPrompt(const ATargetLanguage: string): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('You translate customer emails for the staff of Brightline Motors, a car dealership and garage.');
    SB.AppendLine('Translate the email the user sends into ' + ATargetLanguage + ' (a language name, or a code such as EN-GB).');
    SB.AppendLine('Keep the meaning, the tone, names, numbers, licence plates, dates and the paragraphs. Translate only;');
    SB.AppendLine('do not answer, summarize or comment on the email. An email already in that language comes back unchanged.');
    SB.AppendLine;
    SB.AppendLine('Reply with ONLY a JSON object (no markdown, no code fences) with exactly these fields:');
    SB.AppendLine('{"source_language":"<English name of the language the email is written in>",');
    SB.AppendLine(' "translation":"<the translated email, \n for line breaks>"}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BuildTranslatePrompt(AMail: TTriageMail): string;
begin
  Result := AMail.Body;
  if Result.Length > MaxBodyChars then
    Result := Result.Substring(0, MaxBodyChars) + sLineBreak + '[...truncated...]';
end;

function ApplyTranslateResponse(AMail: TTriageMail; const AResponse: string): Boolean;
var
  Obj: TJSONObject;
begin
  Obj := ParseAIObject(AResponse);
  if Assigned(Obj) then
    try
      AMail.Translation := JsonStr(Obj, 'translation');
      AMail.SourceLanguage := JsonStr(Obj, 'source_language');
    finally
      Obj.Free;
    end
  else
  begin
    // Some models ignore the format and answer with the plain translation
    AMail.Translation := AResponse.Trim;
    AMail.SourceLanguage := '';
  end;
  Result := AMail.Translation <> '';
end;

procedure AssignHandler(AMail: TTriageMail; ARouting: TRoutingTable);
var
  R: TRoutingRule;
begin
  R := ARouting.Resolve(AMail.Department, AMail.Brand);
  if Assigned(R) then
  begin
    AMail.HandlerName := R.HandlerName;
    AMail.HandlerEmail := R.HandlerEmail;
  end
  else
  begin
    AMail.HandlerName := '';
    AMail.HandlerEmail := '';
  end;
end;

{ Offline fallback }

const
  Keywords: array[TDepartment] of string = (
    { other }       'vacancy|application|apply|my cv|sollicit|job|newsletter|unsubscribe',
    { sales }       'new car|probefahrt|angebot|neuen|quote|quotation|test drive|testrit|offerte|configur|order a|bestellen|nieuwe wagen|nouvelle voiture|essai',
    { accessories } 'accessor|roof box|dakkoffer|floor mat|matten|tow bar|towbar|trekhaak|charging cable|laadkabel|rims|velgen|wheels|parts|onderdel|pi'#$00E8'ces',
    { maintenance } 'service|maintenance|onderhoud|entretien|repair|herstel|r'#$00E9'paration|brake|remmen|inspection|keuring|warning light|lampje|appointment|afspraak|tyre|tire|banden|recall|noise|geluid|breakdown|panne|garage',
    { finance }     'leasing| lease|financ|loan|lening|invoice|factuur|facture|payment|betaling|paiement|insurance|verzekering|refund|terugbetaling',
    { secondhand }  'used car|second-hand|second hand|tweedehands|occasion|pre-owned|trade-in|trade in|inruil|reprise|sell my|buy used|mijn wagen verkopen|occasion stock'
  );

function CountHits(const AText, AKeywordList: string): Integer;
var
  K: string;
begin
  Result := 0;
  if AKeywordList = '' then
    Exit;
  for K in AKeywordList.Split(['|']) do
    if AText.Contains(K) then
      Inc(Result);
end;

procedure ApplyKeywordTriage(AMail: TTriageMail; ARouting: TRoutingTable);
var
  Text, Brand: string;
  D, Best: TDepartment;
  Hits, BestHits: Integer;
begin
  Text := (AMail.Subject + ' ' + AMail.Body).ToLower;

  Best := dpOther;
  BestHits := 0;
  for D := Low(TDepartment) to High(TDepartment) do
  begin
    Hits := CountHits(Text, Keywords[D]);
    if Hits > BestHits then
    begin
      Best := D;
      BestHits := Hits;
    end;
  end;
  AMail.Department := Best;

  AMail.Brand := OtherBrand;
  if Text.Contains('vw ') or Text.Contains('vw.') then
    AMail.Brand := 'Volkswagen';
  for Brand in ARouting.Brands do
    if Text.Contains(Brand.ToLower) then
    begin
      AMail.Brand := Brand;
      Break;
    end;
  if Text.Contains(#$0161'koda') then
    AMail.Brand := ARouting.NormalizeBrand('Skoda');

  if (CountHits(Text, 'broken down|panne|stranded|pech|accident|lawyer|advocaat|avocat') > 0) then
    AMail.Priority := PriorityUrgent
  else if (CountHits(Text, 'urgent|asap|dringend|complaint|klacht|plainte|disappointed|ontevreden') > 0) then
    AMail.Priority := PriorityHigh
  else
    AMail.Priority := PriorityNormal;

  AMail.Confidence := Min(90, 30 + BestHits * 15);
  AMail.Summary := AMail.Subject;
  AMail.Reason := Format('Keyword match (%d hits) - configure an AI service for real understanding.', [BestHits]);
  AssignHandler(AMail, ARouting);
  AMail.ReplyDraft := TemplateReply(AMail);
  AMail.ReplyStatus := rsReady;
  if Length(AMail.Attachments) > 0 then
    AMail.AttachmentNotes := Format('%d attachment(s): %s - configure an AI service to analyse them.',
      [Length(AMail.Attachments), string.Join(', ', AttachmentNames(AMail))]);
  // Offline: maintenance visits get the next working day at 09:00
  if (AMail.Department = dpMaintenance) and (AMail.Priority <> PriorityUrgent) then
    AMail.AppointmentStart := NextWorkingDay(Date) + EncodeTime(9, 0, 0, 0)
  else
    AMail.AppointmentStart := 0;
  DetectSpam(AMail);
end;

const
  // Phrases typical for scams, prize mails and cold pitches; two or more hits = spam
  SpamPhrases = 'you have won|you''ve won|winner|congratulations|lottery|prize|claim your|gift card|' +
    'bitcoin|crypto|investment opportunity|guaranteed return|wire transfer|processing fee|' +
    'seo|backlinks|page 1 of google|first page of google|lead generation|marketing agency|' +
    'click here|limited time offer|act now|100% free|unsubscribe|verify your account|password expired';

procedure DetectSpam(AMail: TTriageMail);
var
  Text, K, Found: string;
  Hits: Integer;
begin
  AMail.IsSpam := False;
  AMail.SpamReason := '';
  if AMail.NotSpam then
    Exit;
  Text := (AMail.Subject + ' ' + AMail.Body).ToLower;
  Hits := 0;
  Found := '';
  // Whole words only: "seo" must not match "Seoul", "prize" not "prized"
  for K in SpamPhrases.Split(['|']) do
    if TRegEx.IsMatch(Text, '(?<![\p{L}\p{N}])' + TRegEx.Escape(K) + '(?![\p{L}\p{N}])') then
    begin
      Inc(Hits);
      if Found <> '' then
        Found := Found + ', ';
      Found := Found + '"' + K + '"';
    end;
  if Hits >= 2 then
  begin
    AMail.IsSpam := True;
    AMail.SpamReason := 'Typical spam phrases: ' + Found;
  end;
end;

end.
