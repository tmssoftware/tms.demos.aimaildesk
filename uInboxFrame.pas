{ TMS AI Mail Desk - inbox page
  The mails in a TTMSFNCDataGrid (columns and conditional formatting designed
  in uInboxFrame.fmx), with department chips and a search box as grid
  filters, KPI tiles, and the detail of the selected mail: the AI analysis
  with the original message, and the editable reply draft. Re-routing is done
  on the handler board or by the assistant.
  The AI assistant (uAssistantFrame, on the main form) filters the inbox and
  selects mails through FilterInbox and ShowMail. }

unit uInboxFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.JSON,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Layouts, FMX.Edit,
  FMX.Ani, FMX.Controls.Presentation, FMX.Memo.Types, FMX.ScrollBox, FMX.Memo,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCCustomComponent, FMX.TMSFNCDataGridCore, FMX.TMSFNCDataGridCell, FMX.TMSFNCDataGridData,
  FMX.TMSFNCDataGridRenderer, FMX.TMSFNCDataGrid, FMX.TMSFNCPDFIO, FMX.TMSFNCDataGridPDFIO,
  uTriageModel;

type
  TfrInbox = class(TFrame)
    layKpis: TLayout;
    kpiMails: TRectangle;
    kpiMailsIcon: TLabel;
    kpiMailsValue: TLabel;
    kpiMailsCaption: TLabel;
    kpiUrgent: TRectangle;
    kpiUrgentIcon: TLabel;
    kpiUrgentValue: TLabel;
    kpiUrgentCaption: TLabel;
    kpiTriaged: TRectangle;
    kpiTriagedIcon: TLabel;
    kpiTriagedValue: TLabel;
    kpiTriagedCaption: TLabel;
    kpiDrafts: TRectangle;
    kpiDraftsIcon: TLabel;
    kpiDraftsValue: TLabel;
    kpiDraftsCaption: TLabel;
    kpiForwarded: TRectangle;
    kpiForwardedIcon: TLabel;
    kpiForwardedValue: TLabel;
    kpiForwardedCaption: TLabel;
    layChips: TLayout;
    chipAll: TRectangle;
    aniChipAll: TFloatAnimation;
    chipAllText: TLabel;
    chipSales: TRectangle;
    aniChipSales: TFloatAnimation;
    chipSalesText: TLabel;
    chipAccessories: TRectangle;
    aniChipAccessories: TFloatAnimation;
    chipAccessoriesText: TLabel;
    chipMaintenance: TRectangle;
    aniChipMaintenance: TFloatAnimation;
    chipMaintenanceText: TLabel;
    chipFinance: TRectangle;
    aniChipFinance: TFloatAnimation;
    chipFinanceText: TLabel;
    chipSecondHand: TRectangle;
    aniChipSecondHand: TFloatAnimation;
    chipSecondHandText: TLabel;
    chipReception: TRectangle;
    aniChipReception: TFloatAnimation;
    chipReceptionText: TLabel;
    chipPriority: TRectangle;
    aniChipPriority: TFloatAnimation;
    chipPriorityText: TLabel;
    btnReport: TRectangle;
    aniBtnReport: TFloatAnimation;
    btnReportIcon: TLabel;
    btnReportText: TLabel;
    recSearch: TRectangle;
    lblSearchIcon: TLabel;
    edSearch: TEdit;
    btnClearSearch: TClearEditButton;
    recDetail: TRectangle;
    layDetailHeader: TLayout;
    recRouteBadge: TRectangle;
    lblDetailRoute: TLabel;
    layDetailTitle: TLayout;
    lblDetailSubject: TLabel;
    lblDetailFrom: TLabel;
    layDetailActions: TLayout;
    btnCreateDraft: TRectangle;
    aniBtnCreateDraft: TFloatAnimation;
    btnCreateDraftIcon: TLabel;
    btnCreateDraftText: TLabel;
    btnForwardSelected: TRectangle;
    aniBtnForwardSelected: TFloatAnimation;
    btnForwardSelectedIcon: TLabel;
    btnForwardSelectedText: TLabel;
    laySegments: TLayout;
    recSegments: TRectangle;
    segAnalysis: TRectangle;
    segAnalysisText: TLabel;
    segReply: TRectangle;
    segReplyText: TLabel;
    layDetailPages: TLayout;
    pageAnalysis: TLayout;
    memSummary: TMemo;
    pageReply: TLayout;
    memReply: TMemo;
    splDetail: TSplitter;
    recGridCard: TRectangle;
    grdMails: TTMSFNCDataGrid;
    TMSFNCDataGridPDFIO1: TTMSFNCDataGridPDFIO;
    tmrReply: TTimer;
    procedure ChipClick(Sender: TObject);
    procedure SegmentClick(Sender: TObject);
    procedure edSearchChangeTracking(Sender: TObject);
    procedure grdMailsSelectCell(Sender: TObject; AStartCell, AEndCell, AFocusedCell: TTMSFNCDataGridCellCoord);
    procedure btnCreateDraftClick(Sender: TObject);
    procedure btnForwardSelectedClick(Sender: TObject);
    procedure btnReportClick(Sender: TObject);
    procedure memReplyChangeTracking(Sender: TObject);
    procedure tmrReplyTimer(Sender: TObject);
    procedure layKpisResize(Sender: TObject);
  private
    FSelectedID: Integer;
    FDepartmentFilter: string;         // department name, '' = all
    FPriorityFilter: string;           // set by the assistant
    FUpdatingDetail: Boolean;
    FReplyDirty: Boolean;              // memReply edited, not sent to the server yet
    FReplyDirtyID: Integer;
    function RowOfMail(AMail: TTriageMail): Integer;
    function MailAtRow(ARow: Integer): TTriageMail;
    function SelectedMail: TTriageMail;
    procedure ReloadGrid;
    procedure UpdateCounts;
    procedure UpdateChips;
    procedure ApplyFilter;
    procedure SelectSegment(AIndex: Integer);
    procedure ShowDetail(AMail: TTriageMail);
  public
    constructor Create(AOwner: TComponent); override;
    // The assistant's tools: filter the grid, select a mail
    procedure FilterInbox(const ADepartmentKey, APriority, AText: string);
    function ShowMail(AID: Integer): Boolean;
    // Dashboard.Mails changed
    procedure MailsChanged;
    // Dashboard.Status changed: the triage engine
    procedure StatusChanged;
    // An edited reply draft goes to the server now instead of when typing pauses
    procedure SendReply;
  end;

implementation

{$R *.fmx}

uses
  System.IOUtils, uTheme, uDashboard;

const
  COL_SOURCE   = 0;
  COL_FROM     = 1;
  COL_SUBJECT  = 2;
  COL_DEPT     = 3;
  COL_BRAND    = 4;
  COL_PRIORITY = 5;
  COL_CONF     = 6;
  COL_HANDLER  = 7;
  COL_STATUS   = 8;
  COL_REPLY    = 9;

  Dot = '  '#$00B7'  ';
  Arrow = '   '#$2192'   ';

constructor TfrInbox.Create(AOwner: TComponent);
begin
  inherited;
  SelectSegment(0);
  UpdateChips;   // hides the priority chip until the assistant sets a priority filter
  ShowDetail(nil);
  UpdateCounts;
  layKpisResize(nil);
end;

// The five KPI tiles share the row equally, so none of them stretches on its own
procedure TfrInbox.layKpisResize(Sender: TObject);
var
  Tiles: array of TRectangle;
  Tile: TRectangle;
  W: Single;
begin
  Tiles := [kpiMails, kpiUrgent, kpiTriaged, kpiDrafts, kpiForwarded];
  W := layKpis.Width;
  for Tile in Tiles do
    W := W - Tile.Margins.Right;
  W := W / Length(Tiles);
  if W < 0 then
    W := 0;
  for Tile in Tiles do
    Tile.Width := W;
end;

{ Grid }

// Mails are added to Dashboard.Mails and to the grid in the same order, so the
// grid's real (storage) row = list index + fixed rows. Cells[] and the grid
// events use display rows, which follow the sort order.

function TfrInbox.RowOfMail(AMail: TTriageMail): Integer;
var
  Idx: Integer;
begin
  Idx := Dashboard.Mails.IndexOf(AMail);
  if Idx < 0 then
    Exit(-1);
  Result := grdMails.RealToDisplayRow(Idx + grdMails.FixedRowCount);
end;

function TfrInbox.MailAtRow(ARow: Integer): TTriageMail;
var
  Idx: Integer;
begin
  Result := nil;
  if (ARow < grdMails.FixedRowCount) or (ARow >= grdMails.RowCount) then
    Exit;
  Idx := grdMails.DisplayToRealRow(ARow) - grdMails.FixedRowCount;
  if (Idx >= 0) and (Idx < Dashboard.Mails.Count) then
    Result := Dashboard.Mails[Idx];
end;

function TfrInbox.SelectedMail: TTriageMail;
begin
  Result := Dashboard.Mails.FindByID(FSelectedID);
end;

procedure TfrInbox.MailsChanged;
var
  Selected: TTriageMail;
  Row: Integer;
begin
  ReloadGrid;
  // Keep the selected mail selected, also when rows moved
  Selected := SelectedMail;
  if Assigned(Selected) then
  begin
    Row := RowOfMail(Selected);
    if (Row >= 0) and (grdMails.FocusedCell.Row <> Row) then
      grdMails.SelectCell(MakeCell(COL_SUBJECT, Row));
  end;
  ShowDetail(Selected);
end;

procedure TfrInbox.ReloadGrid;
var
  M: TTriageMail;
  R: Integer;
begin
  grdMails.BeginUpdate;
  try
    grdMails.RowCount := grdMails.FixedRowCount + Dashboard.Mails.Count;
    for M in Dashboard.Mails do
    begin
      R := RowOfMail(M);
      grdMails.Cells[COL_SOURCE, R] := SourceNames[M.Source];
      if M.FromName <> '' then
        grdMails.Cells[COL_FROM, R] := M.FromName
      else
        grdMails.Cells[COL_FROM, R] := M.FromEmail;
      grdMails.Cells[COL_SUBJECT, R] := M.Subject;
      // Routing columns stay empty until the mail is triaged
      if M.IsTriaged then
      begin
        grdMails.Cells[COL_DEPT, R] := DepartmentNames[M.Department];
        grdMails.Cells[COL_BRAND, R] := M.Brand;
        grdMails.Cells[COL_PRIORITY, R] := M.Priority;
        grdMails.Cells[COL_CONF, R] := M.Confidence;
        grdMails.Cells[COL_HANDLER, R] := M.HandlerName;
      end
      else
      begin
        grdMails.Cells[COL_DEPT, R] := '';
        grdMails.Cells[COL_BRAND, R] := '';
        grdMails.Cells[COL_PRIORITY, R] := '';
        grdMails.Cells[COL_CONF, R] := '';
        grdMails.Cells[COL_HANDLER, R] := '';
      end;
      grdMails.Cells[COL_STATUS, R] := StatusNames[M.Status];
      grdMails.Cells[COL_REPLY, R] := ReplyStatusNames[M.ReplyStatus];
    end;
  finally
    grdMails.EndUpdate;
  end;
  if (FDepartmentFilter <> '') or (FPriorityFilter <> '') or (edSearch.Text.Trim <> '') then
    ApplyFilter;
  UpdateCounts;
end;

procedure TfrInbox.UpdateCounts;
var
  M: TTriageMail;
  Triaged, Forwarded, Urgent, Drafts: Integer;
begin
  Triaged := 0;
  Forwarded := 0;
  Urgent := 0;
  Drafts := 0;
  for M in Dashboard.Mails do
  begin
    if M.IsTriaged then
      Inc(Triaged);
    if M.Status in [tsForwarded, tsSimulated] then
      Inc(Forwarded);
    if M.IsTriaged and (M.Priority = PriorityUrgent) then
      Inc(Urgent);
    if M.ReplyStatus in [rsCreated, rsSimulated] then
      Inc(Drafts);
  end;
  kpiMailsValue.Text := Dashboard.Mails.Count.ToString;
  kpiUrgentValue.Text := Urgent.ToString;
  kpiTriagedValue.Text := Triaged.ToString;
  kpiDraftsValue.Text := Drafts.ToString;
  kpiForwardedValue.Text := Forwarded.ToString;
end;

procedure TfrInbox.StatusChanged;
begin
  kpiTriagedCaption.Text := 'Triaged  -  ' + Dashboard.Status.GetValue<string>('engine', '');
end;

procedure TfrInbox.grdMailsSelectCell(Sender: TObject; AStartCell, AEndCell, AFocusedCell: TTMSFNCDataGridCellCoord);
begin
  ShowDetail(MailAtRow(AFocusedCell.Row));
end;

{ Filters: department chips, search box and the assistant's priority }

procedure TfrInbox.ChipClick(Sender: TObject);
begin
  // Chip Tag = TDepartment ordinal, -1 = all departments, -2 = clear the priority filter
  if TFmxObject(Sender).Tag = -2 then
    FPriorityFilter := ''
  else if TFmxObject(Sender).Tag < 0 then
    FDepartmentFilter := ''
  else
    FDepartmentFilter := DepartmentNames[TDepartment(TFmxObject(Sender).Tag)];
  UpdateChips;
  ApplyFilter;
end;

procedure TfrInbox.edSearchChangeTracking(Sender: TObject);
begin
  ApplyFilter;
end;

procedure TfrInbox.UpdateChips;
var
  Chip: TRectangle;
begin
  for Chip in [chipAll, chipSales, chipAccessories, chipMaintenance, chipFinance, chipSecondHand, chipReception] do
    if ((Chip.Tag < 0) and (FDepartmentFilter = '')) or
      ((Chip.Tag >= 0) and (DepartmentNames[TDepartment(Chip.Tag)] = FDepartmentFilter)) then
    begin
      Chip.Fill.Color := Ink;
      Chip.Stroke.Color := Chip.Fill.Color;
      TLabel(FindComponent(Chip.Name + 'Text')).TextSettings.FontColor := TAlphaColors.White;
    end
    else
    begin
      Chip.Fill.Color := TAlphaColors.White;
      Chip.Stroke.Color := $FFE2E8F0;
      TLabel(FindComponent(Chip.Name + 'Text')).TextSettings.FontColor := $FF334155;
    end;

  // Removable chip for the priority filter of the assistant
  chipPriority.Visible := FPriorityFilter <> '';
  chipPriority.Fill.Color := Ink;
  chipPriority.Stroke.Color := chipPriority.Fill.Color;
  chipPriorityText.Text := FPriorityFilter + '  '#$2715;
end;

procedure TfrInbox.ApplyFilter;
const
  SearchColumns: array[0..5] of Integer = (COL_FROM, COL_SUBJECT, COL_BRAND, COL_HANDLER, COL_DEPT, COL_SOURCE);

  procedure AddFilter(AColumn: Integer; const ACondition: string; AContains: Boolean;
    AOperation: TTMSFNCDataGridDataFilterOperation);
  var
    F: TTMSFNCDataGridDataFilterData;
  begin
    F := grdMails.Filter.Add;
    F.Column := AColumn;
    F.Condition := ACondition;
    if AContains then
    begin
      // gftContains with the expression method is a plain case-insensitive substring
      // test, so characters like * or ! in the search text are not special
      F.&Type := gftContains;
      F.Method := gfmExpression;
      F.CaseSensitive := False;
    end
    else
    begin
      F.&Type := gftEqual;
      F.Method := gfmLiteral;   // exact match
    end;
    if grdMails.Filter.Count = 1 then
      F.Operation := gfoNONE
    else
      F.Operation := AOperation;
  end;

var
  Search: string;
  Col: Integer;
begin
  // The grid evaluates filter rules left to right, so this gives
  //   (From OR Subject OR Brand OR Handler OR Department OR Source contains <search>)
  //   AND Department = <chip> AND Priority = <assistant's priority filter>
  Search := edSearch.Text.Trim;
  grdMails.BeginUpdate;
  try
    grdMails.ClearFilter;
    if Search <> '' then
      for Col in SearchColumns do
        AddFilter(Col, Search, True, gfoOR);
    if FDepartmentFilter <> '' then
      AddFilter(COL_DEPT, FDepartmentFilter, False, gfoAND);
    if FPriorityFilter <> '' then
      AddFilter(COL_PRIORITY, FPriorityFilter, False, gfoAND);
    if grdMails.Filter.Count > 0 then
      grdMails.ApplyFilter;
  finally
    grdMails.EndUpdate;
  end;
end;

procedure TfrInbox.FilterInbox(const ADepartmentKey, APriority, AText: string);
var
  Dept: TDepartment;
begin
  // DepartmentFromKey falls back to Reception for anything it does not know;
  // for a filter, a value like "all" or "any" means no department filter
  FDepartmentFilter := '';
  if ADepartmentKey.Trim <> '' then
  begin
    Dept := DepartmentFromKey(ADepartmentKey);
    if (Dept <> dpOther) or SameText(ADepartmentKey.Trim, DepartmentKeys[dpOther]) or
      SameText(ADepartmentKey.Trim, DepartmentNames[dpOther]) then
      FDepartmentFilter := DepartmentNames[Dept];
  end;
  if APriority <> '' then
    FPriorityFilter := NormalizePriority(APriority)
  else
    FPriorityFilter := '';
  edSearch.Text := AText;
  UpdateChips;
  ApplyFilter;
end;

function TfrInbox.ShowMail(AID: Integer): Boolean;
var
  M: TTriageMail;
  Row: Integer;
begin
  M := Dashboard.Mails.FindByID(AID);
  Result := Assigned(M);
  if not Result then
    Exit;
  // Clear filters that would hide it
  FilterInbox('', '', '');
  Row := RowOfMail(M);
  if Row >= 0 then
    grdMails.SelectCell(MakeCell(COL_SUBJECT, Row));
  ShowDetail(M);
end;

{ Detail of the selected mail }

procedure TfrInbox.SegmentClick(Sender: TObject);
begin
  SelectSegment(TFmxObject(Sender).Tag);
end;

procedure TfrInbox.SelectSegment(AIndex: Integer);
var
  Seg: TRectangle;
begin
  // Segment and detail page Tag: 0 = AI analysis, 1 = reply draft (set at design time)
  pageAnalysis.Visible := AIndex = pageAnalysis.Tag;
  pageReply.Visible := AIndex = pageReply.Tag;
  for Seg in [segAnalysis, segReply] do
    if Seg.Tag = AIndex then
    begin
      Seg.Fill.Color := TAlphaColors.White;
      TLabel(FindComponent(Seg.Name + 'Text')).TextSettings.Font.Style := [TFontStyle.fsBold];
    end
    else
    begin
      Seg.Fill.Color := $FFF1F5F9;
      TLabel(FindComponent(Seg.Name + 'Text')).TextSettings.Font.Style := [];
    end;
end;

// Only a changed text is set: the detail is refreshed with every server update,
// which must not reset the scroll position or the selection in a memo
procedure SetMemoText(AMemo: TMemo; const AText: string);
begin
  if AMemo.Text <> AText then
    AMemo.Text := AText;
end;

procedure TfrInbox.ShowDetail(AMail: TTriageMail);
var
  Info: string;
  Colors: TBadgeColors;
begin
  // An edited reply of another mail goes to the server first
  if FReplyDirty and (not Assigned(AMail) or (AMail.ID <> FReplyDirtyID)) then
    SendReply;
  FUpdatingDetail := True;
  try
    // Saving and forwarding need the triage result
    layDetailActions.Enabled := Assigned(AMail) and AMail.IsTriaged;
    if not Assigned(AMail) then
    begin
      FSelectedID := 0;
      lblDetailSubject.Text := 'Select a mail';
      lblDetailFrom.Text := 'The AI analysis, the original message and the reply draft appear here.';
      lblDetailRoute.Text := 'Not triaged yet';
      recRouteBadge.Fill.Color := DepartmentColors[dpOther].Fill;
      lblDetailRoute.TextSettings.FontColor := DepartmentColors[dpOther].Font;
      memSummary.Lines.Clear;
      memReply.Lines.Clear;
      Exit;
    end;

    FSelectedID := AMail.ID;
    lblDetailSubject.Text := AMail.Subject;
    lblDetailFrom.Text := AMail.FromDisplay + Dot + AMail.Received + Dot + 'via ' + SourceNames[AMail.Source];

    if AMail.IsTriaged then
    begin
      Colors := DepartmentColors[AMail.Department];
      lblDetailRoute.Text := DepartmentNames[AMail.Department] + ' / ' + AMail.Brand + Arrow + AMail.HandlerName;
      Info := AMail.Summary + sLineBreak + sLineBreak +
        'Why: ' + AMail.Reason + sLineBreak + sLineBreak +
        Format('Priority: %s    Confidence: %d%%    Engine: %s', [AMail.Priority, AMail.Confidence, AMail.Engine]) + sLineBreak +
        'Handler: ' + AMail.HandlerName + ' <' + AMail.HandlerEmail + '>';
      // Keep what the user is typing; the server has it once typing pauses
      if not FReplyDirty then
        SetMemoText(memReply, RenderReply(AMail));
      memReply.ReadOnly := False;
    end
    else
    begin
      Colors := DepartmentColors[dpOther];
      lblDetailRoute.Text := StatusNames[AMail.Status];
      Info := 'Not triaged yet. Click "Triage with AI".';
      SetMemoText(memReply, 'The reply draft is written during triage.');
      memReply.ReadOnly := True;
    end;
    recRouteBadge.Fill.Color := Colors.Fill;
    lblDetailRoute.TextSettings.FontColor := Colors.Font;

    if AMail.StatusInfo <> '' then
      Info := Info + sLineBreak + sLineBreak + 'Forwarding: ' + AMail.StatusInfo;
    if AMail.ReplyInfo <> '' then
      Info := Info + sLineBreak + 'Reply draft: ' + AMail.ReplyInfo;
    if AMail.FiledIn <> '' then
      Info := Info + sLineBreak + 'Mailbox: moved out of the inbox to ' + AMail.FiledIn;
    if AMail.AppointmentStart > 0 then
      Info := Info + sLineBreak + 'Workshop: ' + FormatDateTime('dddd d mmmm hh:nn', AMail.AppointmentStart);
    if AMail.Alerted then
      Info := Info + sLineBreak + 'Urgent alert sent to the on-call mechanic';
    if AMail.AttachmentNotes <> '' then
      Info := Info + sLineBreak + sLineBreak + 'Attachments: ' + AMail.AttachmentNotes
    else if Length(AMail.Attachments) > 0 then
      Info := Info + sLineBreak + sLineBreak + 'Attachments: ' + string.Join(', ', AMail.Attachments);
    if AMail.HistoryInfo <> '' then
      Info := Info + sLineBreak + sLineBreak + 'Earlier contact:' + sLineBreak + AMail.HistoryInfo;
    // The original, and a translation when one was asked for (translate_mail, e.g. by the assistant)
    Info := Info + sLineBreak + sLineBreak + '--- Original message ---' + sLineBreak + AMail.Body;
    if AMail.Translation <> '' then
      Info := Info + sLineBreak + sLineBreak + '--- AI translation ---' + sLineBreak + AMail.Translation;

    SetMemoText(memSummary, Info);
  finally
    FUpdatingDetail := False;
  end;
end;

{ Actions on the selected mail }

procedure TfrInbox.memReplyChangeTracking(Sender: TObject);
var
  M: TTriageMail;
begin
  if FUpdatingDetail then
    Exit;
  M := SelectedMail;
  if not Assigned(M) or not M.IsTriaged then
    Exit;
  // The edited text replaces the AI draft (signature already filled in); it goes
  // to the server once typing pauses
  FReplyDirty := True;
  FReplyDirtyID := M.ID;
  tmrReply.Enabled := False;
  tmrReply.Enabled := True;
end;

procedure TfrInbox.tmrReplyTimer(Sender: TObject);
begin
  SendReply;
end;

procedure TfrInbox.SendReply;
begin
  tmrReply.Enabled := False;
  if not FReplyDirty then
    Exit;
  FReplyDirty := False;
  Dashboard.RunTool('update_reply', IdArgs(FReplyDirtyID).AddPair('text', memReply.Text));
end;

// Both buttons are only enabled for a triaged mail (ShowDetail); the status
// line shows the result as the server logs it

procedure TfrInbox.btnCreateDraftClick(Sender: TObject);
begin
  SendReply;
  Dashboard.RunTool('save_reply_drafts', IdArgs(FSelectedID));
end;

procedure TfrInbox.btnForwardSelectedClick(Sender: TObject);
begin
  SendReply;
  Dashboard.RunTool('forward_mails', IdArgs(FSelectedID).AddPair('confirm_send', TJSONBool.Create(True)));
end;

{ Toolbar }

procedure TfrInbox.btnReportClick(Sender: TObject);
var
  FileName: string;
begin
  FileName := TPath.Combine(TPath.GetDocumentsPath, 'GarageMailDesk-' + FormatDateTime('yyyy-mm-dd-hhnn', Now) + '.pdf');
  TMSFNCDataGridPDFIO1.Options.Header := 'Brightline Motors - mail triage report ' + FormatDateTime('dd/mm/yyyy hh:nn', Now);
  TMSFNCDataGridPDFIO1.Save(FileName);
  Dashboard.Log('Report saved: ' + FileName);
  Dashboard.SetStatus('PDF report saved to ' + FileName);
end;

end.
