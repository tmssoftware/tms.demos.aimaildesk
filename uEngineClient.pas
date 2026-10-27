{ TMS AI Mail Desk - dashboard
  Connection of the dashboard app to the triage server (GarageMailMCP.exe).
  The server is the system; the app only shows and controls it, through the
  same MCP tools an LLM uses.

  MCP over Streamable HTTP, stateless (protocol 2026-07-28): every tool call
  is one POST with the protocol version and client capabilities in _meta, so
  there is no session to keep. A background thread polls get_dashboard_state
  about once a second; it returns the full state only when the server's
  version changed. Commands run in their own task, so a slow one (an
  interactive mailbox login) never holds up the view or other commands.
  Results come back on the main thread. }

unit uEngineClient;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs, System.Generics.Collections,
  System.Net.HttpClient, System.Net.URLClient;

type
  // AResult (nil on error) belongs to the client and is freed after the call
  TToolDone = reference to procedure(AResult: TJSONValue; const AError: string);
  TStateEvent = procedure(AState: TJSONObject) of object;
  TOfflineEvent = procedure(const AReason: string) of object;

  TToolCall = record
    Tool: string;
    Args: TJSONObject;
    class function Create(const ATool: string; AArgs: TJSONObject = nil): TToolCall; static;
  end;

  TEngineClient = class
  private
    FLock: TCriticalSection;
    FURL, FToken: string;
    FSinceVersion, FLogSince: Int64;
    FBusy: Boolean;
    FWake: TEvent;
    FPoller: TThread;
    FStopping: Boolean;
    FOnState: TStateEvent;
    FOnOffline: TOfflineEvent;
    FRunning: Integer;
    procedure PollLoop;
    // Each call captures its own parameter: a closure over a loop variable would
    // see the next iteration's value by the time the main thread runs it
    procedure DeliverState(AState: TJSONValue);
    procedure DeliverOffline(const AReason: string);
    function Endpoint(out AURL, AToken: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const AURL, AToken: string);
    // Start following the server; the first poll returns the full state
    procedure Start;
    // Takes ownership of AArgs. ADone runs on the main thread.
    procedure Call(const ATool: string; AArgs: TJSONObject = nil; const ADone: TToolDone = nil);
    // Runs the calls one after the other, stops at the first error. ADone gets the last result.
    procedure CallSequence(const ACalls: TArray<TToolCall>; const ADone: TToolDone = nil);
    // Poll right away instead of waiting for the next tick
    procedure Refresh;
    // Next poll returns the full state again (after reconnecting)
    procedure Resync;
    property OnState: TStateEvent read FOnState write FOnState;
    property OnOffline: TOfflineEvent read FOnOffline write FOnOffline;
  end;

// Blocking tool call; raises on any error. Returns the tool's JSON result (caller frees).
function CallTool(AHttp: THTTPClient; const AURL, AToken, ATool: string; AArgs: TJSONObject): TJSONValue;

// %APPDATA%\TMSGarageMailDesk, shared with the server when both run on this machine
function LocalDataDir: string;

implementation

uses
  System.IOUtils, System.Threading;

const
  ProtocolVersion = '2026-07-28';

function LocalDataDir: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'TMSGarageMailDesk');
  ForceDirectories(Result);
end;

class function TToolCall.Create(const ATool: string; AArgs: TJSONObject): TToolCall;
begin
  Result.Tool := ATool;
  Result.Args := AArgs;
end;

function NewHttp(AResponseTimeout: Integer): THTTPClient;
begin
  Result := THTTPClient.Create;
  Result.ConnectionTimeout := 4000;
  Result.ResponseTimeout := AResponseTimeout;
  Result.ContentType := 'application/json';
  Result.Accept := 'application/json, text/event-stream';
end;

function CallTool(AHttp: THTTPClient; const AURL, AToken, ATool: string; AArgs: TJSONObject): TJSONValue;
var
  Req, Params, Meta, Info: TJSONObject;
  Body: TStringStream;
  Resp: IHTTPResponse;
  Root, Content: TJSONValue;
  Res, Err: TJSONObject;
  Text, Item: string;
  I: Integer;
  IsError: Boolean;
begin
  Meta := TJSONObject.Create;
  Meta.AddPair('io.modelcontextprotocol/protocolVersion', ProtocolVersion);
  Meta.AddPair('io.modelcontextprotocol/clientCapabilities', TJSONObject.Create);
  Info := TJSONObject.Create;
  Info.AddPair('name', 'GarageMailDesk dashboard');
  Info.AddPair('version', '2.0');
  Meta.AddPair('io.modelcontextprotocol/clientInfo', Info);
  Params := TJSONObject.Create;
  Params.AddPair('name', ATool);
  if Assigned(AArgs) then
    Params.AddPair('arguments', AArgs.Clone as TJSONObject)
  else
    Params.AddPair('arguments', TJSONObject.Create);
  Params.AddPair('_meta', Meta);
  Req := TJSONObject.Create;
  Req.AddPair('jsonrpc', '2.0');
  Req.AddPair('id', TJSONNumber.Create(1));
  Req.AddPair('method', 'tools/call');
  Req.AddPair('params', Params);
  Body := TStringStream.Create(Req.ToJSON, TEncoding.UTF8);
  try
    Resp := AHttp.Post(AURL, Body, nil, [
      TNetHeader.Create('Authorization', 'Bearer ' + AToken),
      TNetHeader.Create('MCP-Protocol-Version', ProtocolVersion)]);
  finally
    Body.Free;
    Req.Free;
  end;

  if Resp.StatusCode = 401 then
    raise Exception.Create('The server did not accept the token (Settings > Triage server)');
  if Resp.StatusCode div 100 <> 2 then
    raise Exception.CreateFmt('HTTP %d from the server: %s', [Resp.StatusCode, Copy(Resp.ContentAsString(TEncoding.UTF8), 1, 200)]);

  Text := Resp.ContentAsString(TEncoding.UTF8);
  // An SSE-framed answer: the JSON is on the "data:" line
  if Text.StartsWith('event:') or Text.StartsWith('data:') then
    for Item in Text.Split([#10]) do
      if Item.StartsWith('data:') then
        Text := Item.Substring(5).Trim;

  Root := TJSONObject.ParseJSONValue(Text);
  try
    if not (Root is TJSONObject) then
      raise Exception.Create('The server sent an answer that is not JSON');
    if TJSONObject(Root).TryGetValue<TJSONObject>('error', Err) then
      raise Exception.Create(Err.GetValue<string>('message', 'Unknown error'));
    if not TJSONObject(Root).TryGetValue<TJSONObject>('result', Res) then
      raise Exception.Create('The server sent no result');
    IsError := Res.GetValue<Boolean>('isError', False);
    Text := '';
    if Res.TryGetValue<TJSONValue>('content', Content) and (Content is TJSONArray) then
      for I := 0 to TJSONArray(Content).Count - 1 do
        Text := Text + TJSONArray(Content).Items[I].GetValue<string>('text', '');
  finally
    Root.Free;
  end;

  if IsError then
  begin
    // "Error executing tool x: Tool execution error: <message>": keep the message
    I := Text.LastIndexOf('error: ');
    if I >= 0 then
      Text := Text.Substring(I + 7);
    raise Exception.Create(Text);
  end;
  Result := TJSONObject.ParseJSONValue(Text);
  if not Assigned(Result) then
    Result := TJSONString.Create(Text);
end;

{ TEngineClient }

constructor TEngineClient.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
end;

destructor TEngineClient.Destroy;
begin
  FStopping := True;
  FWake.SetEvent;
  if Assigned(FPoller) then
  begin
    FPoller.WaitFor;
    FPoller.Free;
  end;
  // Give running commands a moment; closing the app never waits for a slow server
  for var I := 1 to 100 do
    if TInterlocked.CompareExchange(FRunning, 0, 0) = 0 then
      Break
    else
      Sleep(20);
  // Results that were queued for the main thread must not run after this
  TThread.RemoveQueuedEvents(nil);
  // A command that is still running uses these when it ends: then they stay
  if TInterlocked.CompareExchange(FRunning, 0, 0) = 0 then
  begin
    FWake.Free;
    FLock.Free;
  end;
  inherited;
end;

procedure TEngineClient.Configure(const AURL, AToken: string);
begin
  FLock.Enter;
  try
    FURL := AURL.Trim;
    FToken := AToken.Trim;
    FSinceVersion := -1;
    FLogSince := 0;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TEngineClient.Endpoint(out AURL, AToken: string): Boolean;
begin
  FLock.Enter;
  try
    AURL := FURL;
    AToken := FToken;
  finally
    FLock.Leave;
  end;
  Result := AURL <> '';
end;

procedure TEngineClient.Start;
begin
  if Assigned(FPoller) then
    Exit;
  FPoller := TThread.CreateAnonymousThread(PollLoop);
  FPoller.FreeOnTerminate := False;
  FPoller.Start;
end;

procedure TEngineClient.Refresh;
begin
  FWake.SetEvent;
end;

procedure TEngineClient.Resync;
begin
  FLock.Enter;
  try
    FSinceVersion := -1;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TEngineClient.PollLoop;
var
  Http: THTTPClient;
  URL, Token, LastURL: string;
  Args: TJSONObject;
  State: TJSONValue;
  Arr: TJSONArray;
  Delay: Cardinal;
  WasOffline: Boolean;
begin
  Http := NewHttp(15000);
  WasOffline := False;
  try
    while not FStopping do
    begin
      Delay := 1000;
      if Endpoint(URL, Token) then
      begin
        if URL <> LastURL then
          WasOffline := False;
        LastURL := URL;
        Args := TJSONObject.Create;
        FLock.Enter;
        try
          Args.AddPair('since_version', TJSONNumber.Create(FSinceVersion));
          Args.AddPair('log_since', TJSONNumber.Create(FLogSince));
        finally
          FLock.Leave;
        end;
        try
          try
            State := CallTool(Http, URL, Token, 'get_dashboard_state', Args);
          finally
            Args.Free;
          end;
          if State is TJSONObject then
          begin
            FLock.Enter;
            try
              // Only move on when the server is still the one we asked
              if URL = FURL then
              begin
                FSinceVersion := State.GetValue<Int64>('version', FSinceVersion);
                if TJSONObject(State).TryGetValue<TJSONArray>('log', Arr) and (Arr.Count > 0) then
                  FLogSince := Arr.Items[Arr.Count - 1].GetValue<Int64>('seq', FLogSince);
                FBusy := State.GetValue<Boolean>('status.work.busy', FBusy);
              end;
            finally
              FLock.Leave;
            end;
            WasOffline := False;
            DeliverState(State);
          end
          else
            State.Free;
          // Follow running work more closely
          if FBusy then
            Delay := 400;
        except
          on E: Exception do
          begin
            // Report once, then keep trying quietly; the next success resyncs
            if not WasOffline then
            begin
              WasOffline := True;
              DeliverOffline(E.Message);
            end;
            FLock.Enter;
            try
              FSinceVersion := -1;
            finally
              FLock.Leave;
            end;
            Delay := 3000;
          end;
        end;
      end;
      FWake.WaitFor(Delay);
    end;
  finally
    Http.Free;
  end;
end;

procedure TEngineClient.DeliverState(AState: TJSONValue);
begin
  TThread.Queue(nil,
    procedure
    begin
      try
        if Assigned(FOnState) and not FStopping then
          FOnState(TJSONObject(AState));
      finally
        AState.Free;
      end;
    end);
end;

procedure TEngineClient.DeliverOffline(const AReason: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnOffline) and not FStopping then
        FOnOffline(AReason);
    end);
end;

procedure TEngineClient.Call(const ATool: string; AArgs: TJSONObject; const ADone: TToolDone);
begin
  CallSequence([TToolCall.Create(ATool, AArgs)], ADone);
end;

procedure TEngineClient.CallSequence(const ACalls: TArray<TToolCall>; const ADone: TToolDone);
var
  URL, Token: string;
  Calls: TArray<TToolCall>;
begin
  Calls := ACalls;
  if not Endpoint(URL, Token) then
  begin
    for var C in Calls do
      C.Args.Free;
    if Assigned(ADone) then
      ADone(nil, 'Set the triage server URL on Settings first');
    Exit;
  end;
  TInterlocked.Increment(FRunning);
  TTask.Run(
    procedure
    var
      Http: THTTPClient;
      Res: TJSONValue;
      Err: string;
      I: Integer;
    begin
      Res := nil;
      Err := '';
      Http := NewHttp(200000);  // tools that wait for a login or a mailbox take a while
      try
        for I := 0 to High(Calls) do
        begin
          FreeAndNil(Res);
          try
            Res := CallTool(Http, URL, Token, Calls[I].Tool, Calls[I].Args);
          except
            on E: Exception do
            begin
              Err := E.Message;
              Break;
            end;
          end;
        end;
      finally
        Http.Free;
        for I := 0 to High(Calls) do
          Calls[I].Args.Free;
      end;
      // Show the effect right away
      FWake.SetEvent;
      TInterlocked.Decrement(FRunning);
      TThread.Queue(nil,
        procedure
        begin
          try
            if Assigned(ADone) then
              ADone(Res, Err);
          finally
            Res.Free;
          end;
        end);
    end);
end;

end.
