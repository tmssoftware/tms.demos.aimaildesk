{ TMS AI Mail Desk - handler board page
  The triaged mails as cards on a TTMSFNCKanbanBoard, one column per
  department (column Tag = TDepartment, set in uBoardFrame.fmx). Dropping a
  card on another column re-routes the mail on the server. }

unit uBoardFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Controls.Presentation,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCKanbanBoard;

type
  TfrBoard = class(TFrame)
    lblBoardInfo: TLabel;
    recBoardCard: TRectangle;
    kbBoard: TTMSFNCKanbanBoard;
    lineBoard1: TRectangle;
    lineBoard2: TRectangle;
    lineBoard3: TRectangle;
    lineBoard4: TRectangle;
    lineBoard5: TRectangle;
    procedure kbBoardAfterDropItem(Sender: TObject; AFromColumn, AToColumn: TTMSFNCKanbanBoardColumn;
      AFromItem, AToItem: TTMSFNCKanbanBoardItem);
    procedure kbBoardResized(Sender: TObject);
  public
    procedure Refresh;
  end;

implementation

{$R *.fmx}

uses
  uTriageModel, uTheme, uDashboard;

procedure TfrBoard.Refresh;
var
  I: Integer;
  M: TTriageMail;
  Column: TTMSFNCKanbanBoardColumn;
  Item: TTMSFNCKanbanBoardItem;
begin
  kbBoard.BeginUpdate;
  try
    for I := 0 to kbBoard.Columns.Count - 1 do
      kbBoard.Columns[I].Items.Clear;
    for M in Dashboard.Mails do
    begin
      if not M.IsTriaged then
        Continue;
      Column := nil;
      for I := 0 to kbBoard.Columns.Count - 1 do
        if kbBoard.Columns[I].Tag = Ord(M.Department) then
          Column := kbBoard.Columns[I];
      if not Assigned(Column) then
        Continue;
      Item := Column.Items.Add;
      Item.DataInteger := M.ID;
      Item.Rounding := 10;
      // Items draw with their own colours, not the ItemsAppearance fonts
      Item.TitleColor := Ink;
      Item.TextColor := $FF334155;
      Item.SelectedTitleColor := Item.TitleColor;
      Item.SelectedTextColor := Item.TextColor;
      Item.Title := HtmlEncode(M.Subject);
      // FNC HTML: muted customer line, the handler, then status and an optional priority badge
      Item.Text := Format('<font color="%s">%s '#$00B7' %s</font><br>'#$2192' %s<br><font size="10" color="%s">%s '#$00B7' reply %s</font>',
        [HtmlColor($FF64748B), HtmlEncode(M.FromName), HtmlEncode(M.Brand), HtmlEncode(M.HandlerName),
         HtmlColor($FF94A3B8), StatusNames[M.Status], ReplyStatusNames[M.ReplyStatus].ToLower]);
      if (M.Priority = PriorityUrgent) or (M.Priority = PriorityHigh) then
      begin
        if M.Priority = PriorityUrgent then
          Item.MarkColor := $FFDC2626
        else
          Item.MarkColor := $FFEA580C;
        Item.MarkType := [kbmtLeft];
        Item.MarkSizeLeft := 5;
        Item.Text := Item.Text + Format('<br><font size="10" color="%s"><b>%s</b></font>',
          [HtmlColor(Item.MarkColor), M.Priority.ToUpper]);
      end;
    end;
    for I := 0 to kbBoard.Columns.Count - 1 do
      kbBoard.Columns[I].HeaderText := #$25CF'  ' + DepartmentNames[TDepartment(kbBoard.Columns[I].Tag)] +
        ' (' + kbBoard.Columns[I].Items.Count.ToString + ')';
  finally
    kbBoard.EndUpdate;
  end;
  // The column views are created at run time (not streamed) and rebuilt with
  // the items: no frame or lines inside the columns
  for I := 0 to kbBoard.Columns.Count - 1 do
  begin
    kbBoard.Columns[I].TableView.Stroke.Kind := gskNone;
    kbBoard.Columns[I].TableView.Fill.Kind := gfkNone;
    FlattenTreeView(kbBoard.Columns[I].TableView.TreeView);
  end;
end;

procedure TfrBoard.kbBoardResized(Sender: TObject);
var
  I: Integer;
  W, Spacing: Single;
  Lines: TArray<TRectangle>;
begin
  // Columns share the full width
  if kbBoard.Columns.Count = 0 then
    Exit;
  Spacing := kbBoard.ColumnsAppearance.Spacing;
  W := Int((kbBoard.Width - Spacing * (kbBoard.Columns.Count + 1)) / kbBoard.Columns.Count);
  if W < 180 then
    W := 180;
  kbBoard.BeginUpdate;
  try
    for I := 0 to kbBoard.Columns.Count - 1 do
      kbBoard.Columns[I].Width := W;
  finally
    kbBoard.EndUpdate;
  end;

  // A thin divider (designed in uBoardFrame.fmx, over the board) in the middle
  // of each gap between two columns
  Lines := [lineBoard1, lineBoard2, lineBoard3, lineBoard4, lineBoard5];
  for I := 0 to High(Lines) do
  begin
    Lines[I].Visible := I < kbBoard.Columns.Count - 1;
    Lines[I].SetBounds(kbBoard.Position.X + Spacing / 2 + (I + 1) * (W + Spacing), kbBoard.Position.Y + 8, 1,
      kbBoard.Height - 16);
  end;
end;

procedure TfrBoard.kbBoardAfterDropItem(Sender: TObject; AFromColumn, AToColumn: TTMSFNCKanbanBoardColumn;
  AFromItem, AToItem: TTMSFNCKanbanBoardItem);
var
  M: TTriageMail;
  Item: TTMSFNCKanbanBoardItem;
  Dept: TDepartment;
begin
  Item := AToItem;
  if not Assigned(Item) then
    Item := AFromItem;
  if not Assigned(Item) or not Assigned(AToColumn) then
    Exit;
  M := Dashboard.Mails.FindByID(Item.DataInteger);
  Dept := TDepartment(AToColumn.Tag);
  if not Assigned(M) or (M.Department = Dept) then
    Exit;
  // Dropping a card on another department re-routes the mail on the server;
  // the board shows the new state with the next update
  Dashboard.RunTool('reroute_mail', IdArgs(M.ID).AddPair('department', DepartmentKeys[Dept]),
    Format('#%d re-routed to %s.', [M.ID, DepartmentNames[Dept]]));
end;

end.
