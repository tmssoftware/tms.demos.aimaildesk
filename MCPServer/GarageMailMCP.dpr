{ TMS AI Mail Desk - MCP server
  The mail triage system itself: the engine (uTriageEngine.pas) owns the inbox,
  the routing, the settings and all the work, and every part of it is an MCP
  tool (uMailTools.pas). An LLM runs and maintains it through these tools;
  the GarageMailDesk app is a dashboard that shows and controls it through
  the same tools. See README.md.

    GarageMailMCP.exe                     Streamable HTTP on port 8787 (settings.ini, [MCPServer] Port),
                                          for the dashboard, Claude Code, n8n, a team ...;
                                          protected by a bearer token ([MCPServer] Token)
    GarageMailMCP.exe --http [port]       the same, on another port

  Every client, Claude Desktop included, connects over HTTP to the one running
  server, so they all share the same inbox. }

program GarageMailMCP;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.IniFiles,
  System.IOUtils,
  TMS.MCP.Attributes.Server,
  TMS.MCP.Prompts,
  TMS.MCP.Resources,
  TMS.MCP.Transport.StreamableHTTP,
  uMailTools in 'uMailTools.pas',
  uTriageEngine in 'uTriageEngine.pas',
  uTriageModel in '..\uTriageModel.pas',
  uRouting in '..\uRouting.pas',
  uTriageAI in '..\uTriageAI.pas',
  uReplyDrafts in '..\uReplyDrafts.pas',
  uDemoMails in '..\uDemoMails.pas',
  uMailSources in '..\uMailSources.pas',
  uMailboxFiling in '..\uMailboxFiling.pas',
  uMailJSON in '..\uMailJSON.pas';

var
  Terminated: Boolean;

function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  // Ctrl+C or closing the console: leave the main loop, so the inbox is saved
  Terminated := True;
  Result := True;
end;

function CreateServer(ATools: TGarageMailTools): TTMSMCPAttributedServer;
begin
  // Turns the [TTMSMCPTool] methods into an MCP server
  Result := TTMSMCPServerFactory.CreateFromObject(ATools);
  Result.ServerName := 'ai-mail-desk';
  Result.ServerVersion := '2.0';
  Result.Prompts.RegisterPrompt('triage_inbox',
    'Triage the dealership inbox: classify every mail, route it and prepare reply drafts.',
    function(const Args: array of TValue): TTMSMCPPromptMessages
    begin
      Result := ATools.TriageInboxPrompt;
    end);
  Result.Prompts.RegisterPrompt('health_check',
    'Check on the triage server: connections, errors, spam and routing, and fix what is wrong.',
    function(const Args: array of TValue): TTMSMCPPromptMessages
    begin
      Result := ATools.HealthCheckPrompt;
    end);

  // Read-only context a client can attach without a tool call
  Result.Resources.RegisterDirectResource('inbox', 'garage://inbox',
    'The inbox with the triage state of every mail', 'application/json',
    function(const URI: string): TTMSMCPResourceContent
    begin
      Result := TTMSMCPResourceContent.FromText(URI, 'application/json', ATools.InboxResource);
    end);
  Result.Resources.RegisterDirectResource('routing', 'garage://routing',
    'Departments, brands and the handler routing rules', 'application/json',
    function(const URI: string): TTMSMCPResourceContent
    begin
      Result := TTMSMCPResourceContent.FromText(URI, 'application/json', ATools.RoutingResource);
    end);
  Result.Resources.RegisterDirectResource('status', 'garage://status',
    'Connections, counts, running work and automation of the triage server', 'application/json',
    function(const URI: string): TTMSMCPResourceContent
    begin
      Result := TTMSMCPResourceContent.FromText(URI, 'application/json', ATools.StatusResource);
    end);
end;

function SwitchValue(const AName: string): string;
var
  I: Integer;
begin
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I).TrimLeft(['-', '/']), AName) and not ParamStr(I + 1).StartsWith('-') then
      Exit(ParamStr(I + 1));
  Result := '';
end;

var
  Engine: TTriageEngine;
  Tools: TGarageMailTools;
  Server: TTMSMCPAttributedServer;
  HTTP: TTMSMCPStreamableHTTPTransport;
  Ini: TMemIniFile;
  Port: Integer;

begin
  Server := nil;
  Engine := nil;
  Tools := nil;
  try
    try
      SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
      Engine := TTriageEngine.Create;
      Tools := TGarageMailTools.Create(Engine);

      Ini := TMemIniFile.Create(TPath.Combine(AppDataDir, 'settings.ini'));
      try
        Port := StrToIntDef(SwitchValue('http'), Ini.ReadInteger('MCPServer', 'Port', 8787));
        Tools.Token := Ini.ReadString('MCPServer', 'Token', '');
        if Tools.Token = '' then
        begin
          // First start: create the team token
          Tools.Token := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '').ToLower;
          Ini.WriteString('MCPServer', 'Token', Tools.Token);
          Ini.UpdateFile;
        end;
      finally
        Ini.Free;
      end;

      Server := CreateServer(Tools);
      HTTP := TTMSMCPStreamableHTTPTransport.Create(Server, Port);
      // Clients get a 401 with the protected-resource metadata (OAuth discovery)
      // until they send "Authorization: Bearer <token>"
      HTTP.RequireBearerAuthentication := True;
      HTTP.OnValidateAccessToken := Tools.ValidateToken;
      Server.Transport := HTTP;
      Server.Start;
      WriteLn(Format('AI Mail Desk MCP server on http://localhost:%d/mcp', [Port]));
      WriteLn('Bearer token: see [MCPServer] Token in ' + TPath.Combine(AppDataDir, 'settings.ini'));

      // The engine and the cloud components live on this thread: tools reach it
      // with TThread.Synchronize, the components with TThread.Queue
      while not Terminated do
      begin
        CheckSynchronize(100);
        Engine.Tick;
      end;
      WriteLn('Stopping...');
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'Error: ' + E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    if Assigned(Server) then
      Server.Stop;
    Server.Free;
    Tools.Free;
    Engine.Free;   // saves the inbox
  end;
end.
