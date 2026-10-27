{ TMS AI Mail Desk - showcase demo
  Auto-reply drafts: the reply text (from the AI or a template) is saved as a
  draft in the mailbox the mail arrived in, so a human can review and send it.

  Uses the draft API of the FNC Cloud Pack components:
    Gmail   : CreateReplyDraft (threaded via ThreadId + In-Reply-To/References)
    Outlook : CreateReplyDraft on the original message (Graph adds the quote),
              or CreateDraft for a new draft when the mail came from elsewhere
  Once saved, the draft id is kept on the mail (DraftID), so saving an edited
  reply again replaces the content of that draft with UpdateDraft instead of
  adding a second draft to the mailbox. }

unit uReplyDrafts;

interface

uses
  System.SysUtils, System.Classes, uTriageModel,
  // GARAGE_VCL: the MCP server (console) uses the VCL flavour of the FNC components
  {$IFDEF GARAGE_VCL}
  VCL.TMSFNCCloudBase, VCL.TMSFNCCloudOAuth, VCL.TMSFNCCloudGoogleGmail, VCL.TMSFNCCloudMicrosoftOutlookMail;
  {$ELSE}
  FMX.TMSFNCCloudBase, FMX.TMSFNCCloudOAuth, FMX.TMSFNCCloudGoogleGmail, FMX.TMSFNCCloudMicrosoftOutlookMail;
  {$ENDIF}

type
  // ADraftID: id of the saved draft in the mailbox ('' when unknown)
  // ADraftGone: the draft to update no longer exists (sent or deleted), so the
  //   caller clears AMail.DraftID and saves again to create a new one
  TDraftDoneProc = reference to procedure(ASuccess: Boolean; const AInfo, ADraftID: string; ADraftGone: Boolean);

function TemplateReply(AMail: TTriageMail): string;
function BuildReplySubject(AMail: TTriageMail): string;
function BuildReplyHtml(AMail: TTriageMail; AQuoteOriginal: Boolean = True): string;

// Creates the reply draft, or updates it when AMail.DraftID is set
procedure SaveGmailDraft(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TDraftDoneProc);
procedure SaveOutlookDraft(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TDraftDoneProc);

implementation

uses
  System.JSON;

{ Reply text }

function FirstName(AMail: TTriageMail): string;
begin
  Result := AMail.FromName.Trim;
  if Result.Contains(' ') then
    Result := Result.Substring(0, Result.IndexOf(' '));
end;

function TemplateReply(AMail: TTriageMail): string;
var
  Greeting, NextStep: string;
begin
  // Offline fallback (English). The AI writes the reply in the customer's language.
  if FirstName(AMail) <> '' then
    Greeting := 'Dear ' + FirstName(AMail) + ','
  else
    Greeting := 'Dear customer,';

  case AMail.Department of
    dpSales:
      NextStep := 'Our ' + AMail.Brand + ' sales advisor will contact you shortly with a personal offer and, if you wish, to plan a test drive.';
    dpAccessories:
      NextStep := 'Our parts department is checking availability and pricing for you and will get back to you shortly.';
    dpMaintenance:
      if AMail.Priority = PriorityUrgent then
        NextStep := 'We treat this as urgent: our workshop will call you back as soon as possible. ' +
          'If you are in an unsafe situation, please call roadside assistance right away.'
      else
        NextStep := 'Our workshop planning will contact you to schedule an appointment that suits you.';
    dpFinance:
      NextStep := 'Our finance department is looking into your question and will reply shortly.';
    dpSecondHand:
      NextStep := 'Our used-car specialist will contact you shortly.';
  else
    NextStep := 'We have passed your message on to the right colleague, who will get back to you soon.';
  end;

  Result := Greeting + sLineBreak + sLineBreak +
    'Thank you for your message regarding "' + AMail.Subject + '".' + sLineBreak +
    NextStep + sLineBreak + sLineBreak +
    'Kind regards,' + sLineBreak + SignaturePlaceholder;
end;

function BuildReplySubject(AMail: TTriageMail): string;
begin
  if AMail.Subject.StartsWith('re:', True) then
    Result := AMail.Subject
  else
    Result := 'Re: ' + AMail.Subject;
end;

function BuildReplyHtml(AMail: TTriageMail; AQuoteOriginal: Boolean): string;
var
  Original: string;
begin
  Result :=
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937">' +
    HtmlEncode(RenderReply(AMail)).Replace(sLineBreak, '<br>', [rfReplaceAll]) +
    '</div>';
  if not AQuoteOriginal then
    Exit;

  if AMail.HTMLBody <> '' then
    Original := AMail.HTMLBody
  else
    Original := HtmlEncode(AMail.Body).Replace(#13#10, '<br>', [rfReplaceAll]).Replace(#10, '<br>', [rfReplaceAll]);

  Result := Result + '<br>' +
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#6b7280">On ' +
    HtmlEncode(AMail.Received) + ', ' + HtmlEncode(AMail.FromDisplay) + ' wrote:</div>' +
    '<blockquote style="margin:4px 0 0 4px;padding-left:10px;border-left:3px solid #d1d5db;color:#374151">' +
    Original + '</blockquote>';
end;

{ Gmail }

const
  // UpdateDraft on a draft that no longer exists (sent or deleted in the mailbox)
  HttpNotFound = 404;

procedure AddGmailHeader(AMessage: TTMSFNCCloudGoogleGmailMessage; const AName, AValue: string);
var
  Header: TTMSFNCCloudGoogleGmailHeader;
begin
  Header := TTMSFNCCloudGoogleGmailHeader.Create;
  Header.Name := AName;
  Header.Value := AValue;
  AMessage.Headers.Add(Header);
end;

procedure CreateGmailDraft(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TDraftDoneProc);
var
  Original: TTMSFNCCloudGoogleGmailMessage;
begin
  // The mail list may have been refreshed since triage, so the original is
  // rebuilt from what CreateReplyDraft needs: sender, subject, thread, Message-ID
  Original := TTMSFNCCloudGoogleGmailMessage.Create;
  try
    Original.From := AMail.FromEmail;
    Original.Subject := AMail.Subject;
    Original.ThreadId := AMail.ThreadID;
    if AMail.MessageIDHeader <> '' then
      AddGmailHeader(Original, 'Message-ID', AMail.MessageIDHeader);

    // Gmail does not quote the original itself, so the body includes it
    AGmail.CreateReplyDraft(Original, BuildReplyHtml(AMail), mtHTML,
      procedure(const AMessage: TTMSFNCCloudGoogleGmailMessage; const ARequestResult: TTMSFNCCloudBaseRequestResult)
      var
        DraftID: string;
      begin
        DraftID := '';
        if Assigned(AMessage) then
          DraftID := AMessage.DraftID;
        ADone(ARequestResult.Success, ARequestResult.ResultString, DraftID, False);
      end);
  finally
    // CreateReplyDraft copies what it needs into a new item of AGmail.Drafts
    Original.Free;
  end;
end;

procedure UpdateGmailDraft(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TDraftDoneProc);
var
  Draft: TTMSFNCCloudGoogleGmailMessage;
  DraftID: string;
begin
  // The message must live until the request completes, so it is an item of
  // AGmail.Drafts: the one CreateReplyDraft made, or a new one after a restart
  DraftID := AMail.DraftID;
  Draft := AGmail.FindDraft(DraftID);
  if not Assigned(Draft) then
  begin
    Draft := AGmail.Drafts.Add;
    Draft.DraftID := DraftID;
  end;

  // An update replaces the whole message, so everything CreateReplyDraft
  // filled in is set again: recipient, subject, thread, reply headers, body
  Draft.ToRecipients.Clear;
  Draft.ToRecipients.Add(AMail.FromEmail);
  Draft.CCRecipients.Clear;
  Draft.BCCRecipients.Clear;
  Draft.Subject := BuildReplySubject(AMail);
  Draft.ThreadId := AMail.ThreadID;
  Draft.Headers.Clear;
  if AMail.MessageIDHeader <> '' then
  begin
    AddGmailHeader(Draft, 'In-Reply-To', AMail.MessageIDHeader);
    AddGmailHeader(Draft, 'References', AMail.MessageIDHeader);
  end;
  Draft.Body := BuildReplyHtml(AMail);
  Draft.MessageType := mtHTML;

  AGmail.UpdateDraft(Draft,
    procedure(const AMessage: TTMSFNCCloudGoogleGmailMessage; const ARequestResult: TTMSFNCCloudBaseRequestResult)
    begin
      ADone(ARequestResult.Success, ARequestResult.ResultString, DraftID,
        not ARequestResult.Success and (ARequestResult.ResponseCode = HttpNotFound));
    end);
end;

procedure SaveGmailDraft(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TDraftDoneProc);
begin
  // Files is shared with SendMailMessage (forwarding): a draft would attach them
  AGmail.Files.Clear;
  if AMail.DraftID <> '' then
    UpdateGmailDraft(AGmail, AMail, ADone)
  else
    CreateGmailDraft(AGmail, AMail, ADone);
end;

{ Outlook (Microsoft Graph) }

function OutlookItemWithID(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; const AID: string;
  AStandAlone: Boolean): TTMSFNCCloudMicrosoftOutlookMailItem;
var
  IDObj: TJSONObject;
begin
  // ID is read-only, so a stand-in item gets it from JSON
  if AStandAlone then
    Result := TTMSFNCCloudMicrosoftOutlookMailItem.Create
  else
    Result := AOutlook.Drafts.Add;
  IDObj := TJSONObject.Create;
  try
    IDObj.AddPair('id', AID);
    Result.FromJSON(IDObj);
  finally
    IDObj.Free;
  end;
end;

procedure CreateOutlookDraft(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TDraftDoneProc);
var
  Original: TTMSFNCCloudMicrosoftOutlookMailItem;
  Recipients: TStringList;
  Done: TTMSFNCCloudMicrosoftOutlookMailDraftCallback;
begin
  Done :=
    procedure(const AMailItem: TTMSFNCCloudMicrosoftOutlookMailItem; const ARequestResult: TTMSFNCCloudBaseRequestResult)
    var
      DraftID: string;
    begin
      DraftID := '';
      if Assigned(AMailItem) then
        DraftID := AMailItem.ID;
      ADone(ARequestResult.Success, ARequestResult.ResultString, DraftID, False);
    end;

  if AMail.Source = msOutlook then
  begin
    // Threaded reply draft on the original message. Graph quotes the original
    // below the comment, so only the reply itself is passed.
    if AMail.SourceID = '' then
      raise Exception.Create('The original Outlook message is unknown');
    // Filing gives the message a new id (SourceID follows it), so the item in
    // Mails can be stale: the original is identified by SourceID only
    Original := OutlookItemWithID(AOutlook, AMail.SourceID, True);
    try
      AOutlook.CreateReplyDraft(Original, BuildReplyHtml(AMail, False), False, Done);
    finally
      Original.Free;
    end;
  end
  else
  begin
    // Mail from another source (demo inbox): new draft in the Drafts folder
    Recipients := TStringList.Create;
    try
      Recipients.Add(AMail.FromEmail);
      AOutlook.CreateDraft(BuildReplySubject(AMail), BuildReplyHtml(AMail), Recipients, nil, nil, mtHTML, nil, Done);
    finally
      Recipients.Free;
    end;
  end;
end;

procedure UpdateOutlookDraft(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TDraftDoneProc);
var
  Draft: TTMSFNCCloudMicrosoftOutlookMailItem;
  DraftID: string;
begin
  // The item must live until the request completes, so it is an item of
  // AOutlook.Drafts: the one the create made, or a new one after a restart
  DraftID := AMail.DraftID;
  Draft := AOutlook.FindDraft(DraftID);
  if not Assigned(Draft) then
    Draft := OutlookItemWithID(AOutlook, DraftID, False);

  // The PATCH always sends the recipient lists (an empty list removes them),
  // so the customer is set again; Cc and Bcc stay empty
  Draft.RecipientEmails.Clear;
  Draft.RecipientNames.Clear;
  Draft.RecipientEmails.Add(AMail.FromEmail);
  Draft.CcRecipientEmails.Clear;
  Draft.CcRecipientNames.Clear;
  Draft.BccRecipientEmails.Clear;
  Draft.BccRecipientNames.Clear;
  Draft.Subject := BuildReplySubject(AMail);
  // The new body replaces the quote Graph added to a reply draft, so it quotes the original itself
  Draft.Body := BuildReplyHtml(AMail);
  Draft.MailType := mtHTML;

  AOutlook.UpdateDraft(Draft,
    procedure(const AMailItem: TTMSFNCCloudMicrosoftOutlookMailItem; const ARequestResult: TTMSFNCCloudBaseRequestResult)
    begin
      ADone(ARequestResult.Success, ARequestResult.ResultString, DraftID,
        not ARequestResult.Success and (ARequestResult.ResponseCode = HttpNotFound));
    end);
end;

procedure SaveOutlookDraft(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TDraftDoneProc);
begin
  if AMail.DraftID <> '' then
    UpdateOutlookDraft(AOutlook, AMail, ADone)
  else
    CreateOutlookDraft(AOutlook, AMail, ADone);
end;

end.
