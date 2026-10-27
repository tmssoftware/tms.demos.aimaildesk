{ TMS AI Mail Desk - dashboard
  A car dealership / garage receives all customer mail in shared Gmail and
  Outlook mailboxes. The triage itself runs in the triage server
  (MCPServer\GarageMailMCP.exe): it fetches the mails, lets an LLM classify
  them and write a reply (TMS AI Studio), routes them to a handler, saves the
  replies as drafts and forwards the mails (TMS FNC Cloud Pack). Everything
  the server does is an MCP tool, so an LLM can run and maintain it remotely.

  This app is the dashboard over that server. Where to find what:
    uMain            this window: sidebar, toolbar, status line, theme
    uDashboard       the connection to the server and its state (mails, settings, ...)
    uTheme           department colours, FNC helpers, the FMX style book
    uInboxFrame      inbox page: mail grid, filters, mail detail
    uAssistantFrame  AI assistant panel, always on the right (MCP client)
    uBoardFrame      handler board (kanban)
    uWorkshopFrame   workshop appointments (planner)
    uRoutingFrame    routing table
    uSettingsFrame   settings
    uSpamFrame       spam review
  Every page is a frame, designed in its own .fmx; this form hosts them. }

unit uMain;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Objects, FMX.Layouts,
  FMX.Ani, FMX.Controls.Presentation, FMX.Memo.Types, FMX.ScrollBox, FMX.Memo,
  uInboxFrame, uBoardFrame, uWorkshopFrame, uRoutingFrame, uSettingsFrame, uSpamFrame, uAssistantFrame;

type
  TfrmMain = class(TForm)
    recBackground: TRectangle;
    recSidebar: TRectangle;
    lblLogo: TLabel;
    navInbox: TRectangle;
    navInboxIcon: TLabel;
    navInboxText: TLabel;
    navBoard: TRectangle;
    navBoardIcon: TLabel;
    navBoardText: TLabel;
    navWorkshop: TRectangle;
    navWorkshopIcon: TLabel;
    navWorkshopText: TLabel;
    navSpam: TRectangle;
    navSpamIcon: TLabel;
    navSpamText: TLabel;
    navRouting: TRectangle;
    navRoutingIcon: TLabel;
    navRoutingText: TLabel;
    navSettings: TRectangle;
    navSettingsIcon: TLabel;
    navSettingsText: TLabel;
    navLog: TRectangle;
    navLogIcon: TLabel;
    navLogText: TLabel;
    lblSidebarBrand: TLabel;
    layContent: TLayout;
    layTopBar: TLayout;
    layTitle: TLayout;
    lblPageTitle: TLabel;
    lblPageSubtitle: TLabel;
    btnGetMail: TRectangle;
    btnGetMailIcon: TLabel;
    btnGetMailText: TLabel;
    btnTriage: TRectangle;
    btnTriageIcon: TLabel;
    btnTriageText: TLabel;
    btnForwardAll: TRectangle;
    btnForwardAllIcon: TLabel;
    btnForwardAllText: TLabel;
    layStatus: TLayout;
    pbProgress: TProgressBar;
    lblStatus: TLabel;
    layPages: TLayout;
    frInbox: TfrInbox;
    frBoard: TfrBoard;
    frWorkshop: TfrWorkshop;
    frRouting: TfrRouting;
    frSettings: TfrSettings;
    pageLog: TLayout;
    recLogCard: TRectangle;
    memLog: TMemo;
    frSpam: TfrSpam;
    frAssistant: TfrAssistant;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure NavClick(Sender: TObject);
    procedure btnGetMailClick(Sender: TObject);
    procedure btnTriageClick(Sender: TObject);
    procedure btnForwardAllClick(Sender: TObject);
  private
    FPage: Integer;
    FRefreshQueued: Boolean;
    procedure SelectPage(AIndex: Integer);
    // the assistant's tools that steer the dashboard
    procedure AssistantFilterInbox(const ADepartmentKey, APriority, AText: string);
    function AssistantShowMail(AID: Integer): Boolean;
    procedure RequestPageRefresh;
    procedure QueuedPageRefresh;
    procedure ForwardAll;
    // following the server (Dashboard events)
    procedure DashboardLogLine(const AText: string);
    procedure DashboardStatusText(const AText: string);
    procedure DashboardOnline(Sender: TObject);
    procedure DashboardOffline(Sender: TObject);
    procedure DashboardSettingsChanged(Sender: TObject);
    procedure DashboardRoutingChanged(Sender: TObject);
    procedure DashboardStatusChanged(Sender: TObject);
    procedure DashboardMailsChanged(Sender: TObject);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.fmx}

uses
  System.Math, System.StrUtils, System.JSON, uTheme, uDashboard;

const
  PageTitles: array[0..6] of string = ('Inbox', 'Handler board', 'Workshop', 'Routing table', 'Settings',
    'Activity', 'Spam');
  PageSubtitles: array[0..6] of string = (
    'Brightline Motors  -  AI mail triage',
    'Triaged mails per department',
    'Suggested workshop appointments',
    'Who handles which department and brand',
    'Server, mailboxes, AI and automation',
    'Activity log of the triage server',
    'Flagged by the triage, waiting for review');
  PageInbox = 0;
  PageBoard = 1;
  PageWorkshop = 2;

{ ------------------------------------------------------------------------- }
{ Setup                                                                     }
{ ------------------------------------------------------------------------- }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  // Standard FMX controls: the Win10Modern style with rounded inputs
  StyleBook := AppStyleBook;
  frAssistant.OnShowPage := SelectPage;
  frAssistant.OnFilterInbox := AssistantFilterInbox;
  frAssistant.OnShowMail := AssistantShowMail;
  // The assistant uses the AI service and key of the Settings page
  frSettings.OnAPIKeySaved := frAssistant.StoreAPIKey;
  frRouting.Refresh;
  SelectPage(PageInbox);

  // Follow the triage server
  Dashboard.OnLogLine := DashboardLogLine;
  Dashboard.OnStatusText := DashboardStatusText;
  Dashboard.OnOnline := DashboardOnline;
  Dashboard.OnOffline := DashboardOffline;
  Dashboard.OnSettingsChanged := DashboardSettingsChanged;
  Dashboard.OnRoutingChanged := DashboardRoutingChanged;
  Dashboard.OnStatusChanged := DashboardStatusChanged;
  Dashboard.OnMailsChanged := DashboardMailsChanged;
  Dashboard.Start;
  frSettings.ShowServer;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  // First: no more server callbacks into a half-destroyed form
  FreeAndNil(Dashboard);
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // The assistant's tool call is still on the stack: close once it returns
  CanClose := not frAssistant.ToolRunning;
  if not CanClose then
  begin
    frAssistant.CloseWhenDone := True;
    lblStatus.Text := 'Closing once the assistant''s current step is done...';
  end;
end;

{ ------------------------------------------------------------------------- }
{ Pages                                                                     }
{ ------------------------------------------------------------------------- }

procedure TfrmMain.NavClick(Sender: TObject);
begin
  // Nav item Tag = page index
  SelectPage(TFmxObject(Sender).Tag);
end;

procedure TfrmMain.SelectPage(AIndex: Integer);
var
  Nav: TRectangle;
  I: Integer;
begin
  FPage := AIndex;
  // Page Tag = page index (set at design time)
  for I := 0 to layPages.ChildrenCount - 1 do
    if layPages.Children[I] is TControl then
      TControl(layPages.Children[I]).Visible := layPages.Children[I].Tag = AIndex;
  lblPageTitle.Text := PageTitles[AIndex];
  lblPageSubtitle.Text := PageSubtitles[AIndex];
  case AIndex of
    PageBoard: frBoard.Refresh;
    PageWorkshop: frWorkshop.Refresh;
  end;
  for Nav in [navInbox, navBoard, navWorkshop, navSpam, navRouting, navSettings, navLog] do
    if Nav.Tag = AIndex then
    begin
      Nav.Fill.Color := $FF1E293B;
      TLabel(FindComponent(Nav.Name + 'Text')).TextSettings.FontColor := TAlphaColors.White;
    end
    else
    begin
      Nav.Fill.Color := $FF0F172A;
      TLabel(FindComponent(Nav.Name + 'Text')).TextSettings.FontColor := $FF94A3B8;
    end;
end;

procedure TfrmMain.AssistantFilterInbox(const ADepartmentKey, APriority, AText: string);
begin
  frInbox.FilterInbox(ADepartmentKey, APriority, AText);
  SelectPage(PageInbox);
end;

function TfrmMain.AssistantShowMail(AID: Integer): Boolean;
begin
  Result := frInbox.ShowMail(AID);
  if Result then
    SelectPage(PageInbox);
end;

procedure TfrmMain.RequestPageRefresh;
begin
  // Board and workshop are rebuilt once after a batch of changes, and only when visible
  if FRefreshQueued or not (FPage in [PageBoard, PageWorkshop]) then
    Exit;
  FRefreshQueued := True;
  TThread.ForceQueue(nil, QueuedPageRefresh);
end;

procedure TfrmMain.QueuedPageRefresh;
begin
  FRefreshQueued := False;
  case FPage of
    PageBoard: frBoard.Refresh;
    PageWorkshop: frWorkshop.Refresh;
  end;
end;

{ ------------------------------------------------------------------------- }
{ Following the triage server                                               }
{ ------------------------------------------------------------------------- }

procedure TfrmMain.DashboardLogLine(const AText: string);
begin
  memLog.Lines.Add(AText);
  memLog.GoToTextEnd;
end;

procedure TfrmMain.DashboardStatusText(const AText: string);
begin
  lblStatus.Text := AText;
end;

procedure TfrmMain.DashboardOnline(Sender: TObject);
begin
  // The assistant connects to the same server over MCP
  frAssistant.Connect;
end;

procedure TfrmMain.DashboardOffline(Sender: TObject);
begin
  frSettings.ShowMailboxes;
  pbProgress.Visible := False;
  // The server may have created its token on its first start
  frSettings.ShowServer;
end;

procedure TfrmMain.DashboardSettingsChanged(Sender: TObject);
begin
  frSettings.ShowSettings;
  frAssistant.ShowService;
end;

procedure TfrmMain.DashboardRoutingChanged(Sender: TObject);
begin
  frRouting.Refresh;
end;

procedure TfrmMain.DashboardStatusChanged(Sender: TObject);
var
  Total: Integer;
begin
  frSettings.ShowMailboxes;
  frInbox.StatusChanged;
  // One progress bar for all the work the server is doing
  Total := Dashboard.Status.GetValue<Integer>('work.batch_total', 0);
  pbProgress.Visible := Dashboard.Status.GetValue<Boolean>('work.busy', False) and (Total > 0);
  pbProgress.Max := Max(1, Total);
  pbProgress.Value := Dashboard.Status.GetValue<Integer>('work.batch_done', 0);
end;

procedure TfrmMain.DashboardMailsChanged(Sender: TObject);
begin
  frInbox.MailsChanged;
  frSpam.Refresh;
  if Dashboard.Spam.Count > 0 then
    navSpamText.Text := Format('Spam (%d)', [Dashboard.Spam.Count])
  else
    navSpamText.Text := 'Spam';
  RequestPageRefresh;
end;

{ ------------------------------------------------------------------------- }
{ Toolbar: every button is an MCP tool call; the status line shows the      }
{ tool's note and then what the server does (its activity log)              }
{ ------------------------------------------------------------------------- }

procedure TfrmMain.btnGetMailClick(Sender: TObject);
begin
  // Without a connected mailbox (Settings) the server loads its demo inbox
  Dashboard.RunTool('fetch_mails', TJSONObject.Create.AddPair('source',
    IfThen(Dashboard.AnyMailboxConnected, 'all', 'demo')));
end;

procedure TfrmMain.btnTriageClick(Sender: TObject);
begin
  Dashboard.RunTool('run_triage', nil);
end;

procedure TfrmMain.ForwardAll;
begin
  Dashboard.RunTool('forward_mails', TJSONObject.Create.AddPair('confirm_send', TJSONBool.Create(True)));
end;

procedure TfrmMain.btnForwardAllClick(Sender: TObject);
begin
  // With dry run off (Settings) this sends real mail
  if Dashboard.SettingBool('dry_run', True) then
    ForwardAll
  else
    Confirm('Dry run is off: forward every triaged mail to its handler now?', ForwardAll);
end;

end.
