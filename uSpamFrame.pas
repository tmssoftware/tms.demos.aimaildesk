{ TMS AI Mail Desk - spam page
  The mails the triage flagged as spam, waiting for review: put one back in
  the inbox, or delete it (mailbox mails go to the trash of their mailbox). }

unit uSpamFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Layouts, FMX.Ani,
  FMX.Controls.Presentation, FMX.Memo.Types, FMX.ScrollBox, FMX.Memo,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCDataGridCore, FMX.TMSFNCDataGridCell, FMX.TMSFNCDataGridData, FMX.TMSFNCDataGridRenderer,
  FMX.TMSFNCDataGrid,
  uTriageModel;

type
  TfrSpam = class(TFrame)
    laySpamTools: TLayout;
    btnNotSpam: TRectangle;
    aniBtnNotSpam: TFloatAnimation;
    btnNotSpamIcon: TLabel;
    btnNotSpamText: TLabel;
    btnDeleteSpam: TRectangle;
    aniBtnDeleteSpam: TFloatAnimation;
    btnDeleteSpamIcon: TLabel;
    btnDeleteSpamText: TLabel;
    btnDeleteAllSpam: TRectangle;
    aniBtnDeleteAllSpam: TFloatAnimation;
    btnDeleteAllSpamIcon: TLabel;
    btnDeleteAllSpamText: TLabel;
    lblSpamInfo: TLabel;
    recSpamPreview: TRectangle;
    memSpamBody: TMemo;
    recSpamCard: TRectangle;
    grdSpam: TTMSFNCDataGrid;
    procedure btnNotSpamClick(Sender: TObject);
    procedure btnDeleteSpamClick(Sender: TObject);
    procedure btnDeleteAllSpamClick(Sender: TObject);
    procedure grdSpamSelectCell(Sender: TObject; AStartCell, AEndCell, AFocusedCell: TTMSFNCDataGridCellCoord);
  private
    function SelectedSpam: TTriageMail;
  public
    // Shows Dashboard.Spam
    procedure Refresh;
  end;

implementation

{$R *.fmx}

uses
  uDashboard;

procedure TfrSpam.Refresh;
var
  I, Row: Integer;
  M: TTriageMail;
begin
  grdSpam.BeginUpdate;
  try
    grdSpam.RowCount := grdSpam.FixedRowCount + Dashboard.Spam.Count;
    for I := 0 to Dashboard.Spam.Count - 1 do
    begin
      M := Dashboard.Spam[I];
      Row := I + grdSpam.FixedRowCount;
      grdSpam.Cells[0, Row] := SourceNames[M.Source];
      grdSpam.Cells[1, Row] := M.FromDisplay;
      grdSpam.Cells[2, Row] := M.Subject;
      grdSpam.Cells[3, Row] := M.SpamReason;
      grdSpam.Cells[4, Row] := M.Received;
    end;
  finally
    grdSpam.EndUpdate;
  end;
  if SelectedSpam = nil then
    memSpamBody.Lines.Clear;
end;

function TfrSpam.SelectedSpam: TTriageMail;
var
  Idx: Integer;
begin
  Result := nil;
  Idx := grdSpam.DisplayToRealRow(grdSpam.FocusedCell.Row) - grdSpam.FixedRowCount;
  if (Idx >= 0) and (Idx < Dashboard.Spam.Count) then
    Result := Dashboard.Spam[Idx];
end;

procedure TfrSpam.grdSpamSelectCell(Sender: TObject; AStartCell, AEndCell, AFocusedCell: TTMSFNCDataGridCellCoord);
var
  M: TTriageMail;
begin
  M := SelectedSpam;
  if Assigned(M) then
    memSpamBody.Text := M.FromDisplay + sLineBreak + M.Subject + sLineBreak + sLineBreak + M.Body
  else
    memSpamBody.Lines.Clear;
end;

procedure TfrSpam.btnNotSpamClick(Sender: TObject);
var
  M: TTriageMail;
begin
  M := SelectedSpam;
  if Assigned(M) then
    Dashboard.RunTool('mark_not_spam', IdArgs(M.ID), 'Back in the inbox. Click "Triage with AI" to classify it.');
end;

procedure TfrSpam.btnDeleteSpamClick(Sender: TObject);
var
  M: TTriageMail;
begin
  M := SelectedSpam;
  if Assigned(M) then
    Dashboard.RunTool('delete_spam', IdArgs(M.ID), 'Spam deleted (mailbox mails go to the trash of their mailbox).');
end;

procedure TfrSpam.btnDeleteAllSpamClick(Sender: TObject);
begin
  if Dashboard.Spam.Count > 0 then
    Confirm(Format('Delete all %d spam mails? Mails from Gmail or Outlook go to the trash of that mailbox.',
      [Dashboard.Spam.Count]),
      procedure
      begin
        Dashboard.RunTool('delete_spam', nil, 'Spam list cleared.');
      end);
end;

end.
