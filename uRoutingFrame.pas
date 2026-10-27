{ TMS AI Mail Desk - routing table page
  Who handles which department and brand. The grid is edited locally and
  saved to the server in one go (replace_routing_table); the server then
  re-routes the triaged mails that are not forwarded yet. }

unit uRoutingFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Layouts, FMX.Ani,
  FMX.Controls.Presentation,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCDataGridCore, FMX.TMSFNCDataGridCell, FMX.TMSFNCDataGridData, FMX.TMSFNCDataGridRenderer,
  FMX.TMSFNCDataGrid;

type
  TfrRouting = class(TFrame)
    layRoutingTools: TLayout;
    btnAddRule: TRectangle;
    aniBtnAddRule: TFloatAnimation;
    btnAddRuleIcon: TLabel;
    btnAddRuleText: TLabel;
    btnDeleteRule: TRectangle;
    aniBtnDeleteRule: TFloatAnimation;
    btnDeleteRuleIcon: TLabel;
    btnDeleteRuleText: TLabel;
    btnSaveRouting: TRectangle;
    aniBtnSaveRouting: TFloatAnimation;
    btnSaveRoutingIcon: TLabel;
    btnSaveRoutingText: TLabel;
    btnResetRouting: TRectangle;
    aniBtnResetRouting: TFloatAnimation;
    btnResetRoutingIcon: TLabel;
    btnResetRoutingText: TLabel;
    lblRoutingInfo: TLabel;
    recRoutingCard: TRectangle;
    grdRouting: TTMSFNCDataGrid;
    procedure btnAddRuleClick(Sender: TObject);
    procedure btnDeleteRuleClick(Sender: TObject);
    procedure btnSaveRoutingClick(Sender: TObject);
    procedure btnResetRoutingClick(Sender: TObject);
  private
    function GridJSON: string;
  public
    // Shows Dashboard.Routing (the server's table)
    procedure Refresh;
  end;

implementation

{$R *.fmx}

uses
  System.JSON, uTriageModel, uRouting, uDashboard;

const
  COL_DEPT  = 0;
  COL_BRAND = 1;
  COL_NAME  = 2;
  COL_EMAIL = 3;

procedure TfrRouting.Refresh;
var
  I, Row: Integer;
  R: TRoutingRule;
begin
  grdRouting.BeginUpdate;
  try
    grdRouting.RowCount := grdRouting.FixedRowCount + Dashboard.Routing.Rules.Count;
    for I := 0 to Dashboard.Routing.Rules.Count - 1 do
    begin
      R := Dashboard.Routing.Rules[I];
      Row := I + grdRouting.FixedRowCount;
      grdRouting.Cells[COL_DEPT, Row] := DepartmentNames[R.Department];
      grdRouting.Cells[COL_BRAND, Row] := R.Brand;
      grdRouting.Cells[COL_NAME, Row] := R.HandlerName;
      grdRouting.Cells[COL_EMAIL, Row] := R.HandlerEmail;
    end;
  finally
    grdRouting.EndUpdate;
  end;
end;

function TfrRouting.GridJSON: string;
var
  Row: Integer;
  Brand: string;
  Arr: TJSONArray;
begin
  Arr := TJSONArray.Create;
  try
    for Row := grdRouting.FixedRowCount to grdRouting.RowCount - 1 do
    begin
      if grdRouting.Strings[COL_EMAIL, Row].Trim = '' then
        Continue;
      Brand := grdRouting.Strings[COL_BRAND, Row].Trim;
      if Brand = '' then
        Brand := AnyBrand;
      Arr.AddElement(TJSONObject.Create
        .AddPair('department', DepartmentKeys[DepartmentFromKey(grdRouting.Strings[COL_DEPT, Row])])
        .AddPair('brand', Brand)
        .AddPair('name', grdRouting.Strings[COL_NAME, Row].Trim)
        .AddPair('email', grdRouting.Strings[COL_EMAIL, Row].Trim));
    end;
    Result := Arr.ToJSON;
  finally
    Arr.Free;
  end;
end;

procedure TfrRouting.btnAddRuleClick(Sender: TObject);
var
  R: Integer;
begin
  R := grdRouting.RowCount;
  grdRouting.RowCount := R + 1;
  grdRouting.Cells[COL_DEPT, R] := DepartmentNames[dpSales];
  grdRouting.Cells[COL_BRAND, R] := AnyBrand;
end;

procedure TfrRouting.btnDeleteRuleClick(Sender: TObject);
var
  R: Integer;
begin
  R := grdRouting.FocusedCell.Row;
  if (R >= grdRouting.FixedRowCount) and (R < grdRouting.RowCount) then
    grdRouting.DeleteRow(R);
end;

procedure TfrRouting.btnSaveRoutingClick(Sender: TObject);
begin
  Dashboard.ReloadRouting;
  Dashboard.RunTool('replace_routing_table', TJSONObject.Create.AddPair('rules', GridJSON),
    'Routing table saved on the server and applied.');
end;

procedure TfrRouting.btnResetRoutingClick(Sender: TObject);
begin
  Confirm('Restore the default routing table on the server?',
    procedure
    begin
      Dashboard.ReloadRouting;
      Dashboard.RunTool('reset_routing_table', nil, 'Default routing restored.');
    end);
end;

end.
