{ TMS AI Mail Desk - showcase demo
  Mailbox housekeeping after triage:
    - a forwarded mail leaves the inbox and is filed per department,
      Gmail: label "Triage/<Department>" (INBOX label removed)
      Outlook: folder "Triage" > "<Department>" (message moved)
    - deleted spam goes to the mailbox trash (recoverable), never deleted for good.

  The FNC cloud components have no API for creating labels / folders or moving
  messages, so the REST calls go through the component's own request pipeline
  and OAuth token. Each step runs when the previous one answers. }

unit uMailboxFiling;

interface

uses
  System.SysUtils, uTriageModel,
  {$IFDEF GARAGE_VCL}
  VCL.TMSFNCCloudBase, VCL.TMSFNCCloudGoogleGmail, VCL.TMSFNCCloudMicrosoftOutlookMail;
  {$ELSE}
  FMX.TMSFNCCloudBase, FMX.TMSFNCCloudGoogleGmail, FMX.TMSFNCCloudMicrosoftOutlookMail;
  {$ENDIF}

type
  TMailboxDoneProc = reference to procedure(ASuccess: Boolean; const AInfo: string);

const
  FilingRoot = 'Triage';

// 'Triage/Sales', ... : where a forwarded mail is filed
function FilingPath(AMail: TTriageMail): string;

procedure FileGmailMessage(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TMailboxDoneProc);
procedure FileOutlookMessage(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TMailboxDoneProc);
procedure TrashGmailMessage(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TMailboxDoneProc);
procedure TrashOutlookMessage(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TMailboxDoneProc);
// Id of the message in a Graph /move response (Outlook gives a moved message a new id)
function MovedMessageId(const AMoveResult: string): string;

implementation

uses
  System.JSON;

const
  GmailHost = 'https://www.googleapis.com';
  GraphHost = 'https://graph.microsoft.com';

type
  TApiDoneProc = reference to procedure(ASuccess: Boolean; const AResult: string);

function FilingPath(AMail: TTriageMail): string;
begin
  Result := FilingRoot + '/' + DepartmentNames[AMail.Department];
end;

procedure CallApi(ACloud: TTMSFNCCustomCloudBase; const AToken, AHost, APath, AQuery: string;
  AMethod: TTMSFNCCloudBaseRequestMethod; const APost: string; ADone: TApiDoneProc);
begin
  ACloud.Request.Clear;
  ACloud.Request.Host := AHost;
  ACloud.Request.Path := APath;
  ACloud.Request.Query := AQuery;
  ACloud.Request.Method := AMethod;
  ACloud.Request.PostData := APost;
  ACloud.Request.AddHeader('Authorization', 'Bearer ' + AToken);
  if APost <> '' then
    ACloud.Request.AddHeader('Content-Type', 'application/json');
  ACloud.Request.Name := 'MAILBOX';
  ACloud.ExecuteRequest(
    procedure(const ARequestResult: TTMSFNCCloudBaseRequestResult)
    begin
      ADone(ARequestResult.ResponseCode div 100 = 2, ARequestResult.ResultString);
    end);
end;

// Looks up AName in the JSON array AArrayName of AJson; returns the "id" or ''
function FindId(const AJson, AArrayName, ANameField, AName: string): string;
var
  V, Item: TJSONValue;
  Arr: TJSONArray;
begin
  Result := '';
  V := TJSONObject.ParseJSONValue(AJson);
  try
    if not (V is TJSONObject) then
      Exit;
    Arr := TJSONObject(V).GetValue(AArrayName) as TJSONArray;
    if Assigned(Arr) then
      for Item in Arr do
        if (Item is TJSONObject) and SameText(TJSONObject(Item).GetValue<string>(ANameField, ''), AName) then
          Exit(TJSONObject(Item).GetValue<string>('id', ''));
  finally
    V.Free;
  end;
end;

function IdOf(const AJson: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  V := TJSONObject.ParseJSONValue(AJson);
  try
    if V is TJSONObject then
      Result := TJSONObject(V).GetValue<string>('id', '');
  finally
    V.Free;
  end;
end;

function MovedMessageId(const AMoveResult: string): string;
begin
  Result := IdOf(AMoveResult);
end;

{ Gmail: label "Triage/<Department>" }

procedure GmailModify(AGmail: TTMSFNCCloudGoogleGmail; const AToken, AMsgId, ALabelId: string; ADone: TMailboxDoneProc);
begin
  // Add the department label and take the message out of the inbox
  CallApi(AGmail, AToken, GmailHost, '/gmail/v1/users/me/messages/' + AMsgId + '/modify', '', rmPOST,
    '{"addLabelIds":["' + ALabelId + '"],"removeLabelIds":["INBOX"]}',
    procedure(ASuccess: Boolean; const AResult: string)
    begin
      ADone(ASuccess, AResult);
    end);
end;

procedure FileGmailMessage(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TMailboxDoneProc);
var
  Token, MsgId, LabelName: string;
begin
  Token := AGmail.Authentication.AccessToken;
  MsgId := AMail.SourceID;
  LabelName := FilingPath(AMail);
  CallApi(AGmail, Token, GmailHost, '/gmail/v1/users/me/labels', '', rmGET, '',
    procedure(ASuccess: Boolean; const AResult: string)
    var
      LabelId: string;
      Post: TJSONObject;
    begin
      if not ASuccess then
      begin
        ADone(False, AResult);
        Exit;
      end;
      LabelId := FindId(AResult, 'labels', 'name', LabelName);
      if LabelId <> '' then
        GmailModify(AGmail, Token, MsgId, LabelId, ADone)
      else
      begin
        // First mail for this department: create the label ("Triage/Sales" nests under "Triage")
        Post := TJSONObject.Create;
        try
          Post.AddPair('name', LabelName);
          Post.AddPair('labelListVisibility', 'labelShow');
          Post.AddPair('messageListVisibility', 'show');
          CallApi(AGmail, Token, GmailHost, '/gmail/v1/users/me/labels', '', rmPOST, Post.ToJSON,
            procedure(ACreated: Boolean; const ALabel: string)
            begin
              if ACreated then
                GmailModify(AGmail, Token, MsgId, IdOf(ALabel), ADone)
              else
                ADone(False, ALabel);
            end);
        finally
          Post.Free;
        end;
      end;
    end);
end;

procedure TrashGmailMessage(AGmail: TTMSFNCCloudGoogleGmail; AMail: TTriageMail; ADone: TMailboxDoneProc);
begin
  CallApi(AGmail, AGmail.Authentication.AccessToken, GmailHost,
    '/gmail/v1/users/me/messages/' + AMail.SourceID + '/trash', '', rmPOST, '',
    procedure(ASuccess: Boolean; const AResult: string)
    begin
      ADone(ASuccess, AResult);
    end);
end;

{ Outlook (Microsoft Graph): folder "Triage" > "<Department>" }

// Finds the folder AName in AListPath, or creates it there; then calls ANext with its id
procedure OutlookEnsureFolder(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; const AToken, AListPath, AName: string;
  ADone: TMailboxDoneProc; ANext: TApiDoneProc);
begin
  CallApi(AOutlook, AToken, GraphHost, AListPath, '$top=100', rmGET, '',
    procedure(ASuccess: Boolean; const AResult: string)
    var
      Id: string;
    begin
      if not ASuccess then
      begin
        ADone(False, AResult);
        Exit;
      end;
      Id := FindId(AResult, 'value', 'displayName', AName);
      if Id <> '' then
        ANext(True, Id)
      else
        CallApi(AOutlook, AToken, GraphHost, AListPath, '', rmPOST, '{"displayName":"' + AName + '"}',
          procedure(ACreated: Boolean; const AFolder: string)
          begin
            if ACreated then
              ANext(True, IdOf(AFolder))
            else
              ADone(False, AFolder);
          end);
    end);
end;

procedure FileOutlookMessage(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TMailboxDoneProc);
var
  Token, MsgId, FolderName: string;
begin
  Token := AOutlook.Authentication.AccessToken;
  MsgId := AMail.SourceID;
  FolderName := DepartmentNames[AMail.Department];
  OutlookEnsureFolder(AOutlook, Token, '/v1.0/me/mailFolders', FilingRoot, ADone,
    procedure(ASuccess: Boolean; const ARootId: string)
    begin
      OutlookEnsureFolder(AOutlook, Token, '/v1.0/me/mailFolders/' + ARootId + '/childFolders', FolderName, ADone,
        procedure(AFound: Boolean; const AFolderId: string)
        begin
          CallApi(AOutlook, Token, GraphHost, '/v1.0/me/messages/' + MsgId + '/move', '', rmPOST,
            '{"destinationId":"' + AFolderId + '"}',
            procedure(AMoved: Boolean; const AResult: string)
            begin
              ADone(AMoved, AResult);
            end);
        end);
    end);
end;

procedure TrashOutlookMessage(AOutlook: TTMSFNCCloudMicrosoftOutlookMail; AMail: TTriageMail; ADone: TMailboxDoneProc);
begin
  // "deleteditems" is the well-known name of the Deleted Items folder
  CallApi(AOutlook, AOutlook.Authentication.AccessToken, GraphHost,
    '/v1.0/me/messages/' + AMail.SourceID + '/move', '', rmPOST, '{"destinationId":"deleteditems"}',
    procedure(ASuccess: Boolean; const AResult: string)
    begin
      ADone(ASuccess, AResult);
    end);
end;

end.
