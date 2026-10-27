{ TMS AI Mail Desk - workshop page
  The workshop appointments the triage suggested, in a TTMSFNCPlanner, between
  the bookings that were already in the planning (grey, fixed).
  Moving an appointment sets its new time on the server; "Sync to calendar"
  puts them in the Google / Outlook calendar. }

unit uWorkshopFrame;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Objects, FMX.Layouts, FMX.Ani,
  FMX.Controls.Presentation,
  FMX.TMSFNCTypes, FMX.TMSFNCUtils, FMX.TMSFNCGraphics, FMX.TMSFNCGraphicsTypes, FMX.TMSFNCCustomControl,
  FMX.TMSFNCPlannerBase, FMX.TMSFNCPlannerData, FMX.TMSFNCPlanner;

type
  TfrWorkshop = class(TFrame)
    layWorkshopTools: TLayout;
    btnSyncCalendar: TRectangle;
    aniBtnSyncCalendar: TFloatAnimation;
    btnSyncCalendarIcon: TLabel;
    btnSyncCalendarText: TLabel;
    lblWorkshopInfo: TLabel;
    recWorkshopCard: TRectangle;
    plWorkshop: TTMSFNCPlanner;
    procedure btnSyncCalendarClick(Sender: TObject);
    procedure plWorkshopAfterMoveItem(Sender: TObject; AItem: TTMSFNCPlannerItem;
      ANewStartTime, ANewEndTime: TDateTime; ANewPosition: Integer);
    procedure plWorkshopItemDblClick(Sender: TObject; AItem: TTMSFNCPlannerItem);
  public
    procedure Refresh;
  end;

implementation

{$R *.fmx}

uses
  System.JSON, System.DateUtils, uTriageModel, uMailJSON, uTheme, uDashboard;

procedure TfrWorkshop.Refresh;
var
  M: TTriageMail;
  B: TWorkshopBooking;
  Item: TTMSFNCPlannerItem;
  First: TDateTime;
  Colors: TBadgeColors;
begin
  // Show the week of the first upcoming appointment, else of the first upcoming booking
  First := 0;
  for M in Dashboard.Mails do
    if (M.AppointmentStart > 0) and ((First = 0) or (M.AppointmentStart < First)) then
      First := M.AppointmentStart;
  if First = 0 then
    for B in Dashboard.Bookings do
      if (B.Start >= Date) and ((First = 0) or (B.Start < First)) then
        First := B.Start;
  if First = 0 then
    First := Date;

  plWorkshop.BeginUpdate;
  try
    plWorkshop.ModeSettings.StartTime := StartOfTheWeek(First);
    plWorkshop.Items.Clear;
    // The existing bookings: grey and fixed, they only show which hours are taken
    for B in Dashboard.Bookings do
    begin
      Item := plWorkshop.AddOrUpdateItem(B.Start, IncHour(B.Start), 'Booked '#$00B7' ' + B.Customer,
        B.Vehicle + '<br>' + B.Job);
      Item.DataString := SlotToStr(B.Start);
      Item.Movable := False;
      Item.Sizeable := False;
      Item.Deletable := False;
      Item.Editable := False;
      Item.Rounding := 8;
      Item.Color := $FFF1F5F9;
      Item.TitleColor := Item.Color;
      Item.StrokeColor := $FFE2E8F0;
      Item.TitleStrokeColor := Item.StrokeColor;
      Item.TitleFontColor := Muted;
      Item.FontColor := $FF94A3B8;
      Item.SelectedColor := $FFE2E8F0;
      Item.SelectedTitleColor := Item.SelectedColor;
      Item.SelectedStrokeColor := Muted;
      Item.SelectedTitleStrokeColor := Muted;
      Item.SelectedTitleFontColor := Ink;
      Item.SelectedFontColor := Muted;
    end;
    for M in Dashboard.Mails do
      if M.AppointmentStart > 0 then
      begin
        Item := plWorkshop.AddOrUpdateItem(M.AppointmentStart, IncHour(M.AppointmentStart),
          M.Brand + ' '#$00B7' ' + M.FromName, M.Subject + '<br>'#$2192' ' + M.HandlerName);
        Item.DataInteger := M.ID;
        Item.Sizeable := False;
        Item.Deletable := False;
        Item.Editable := False;
        // A card in the department colour with an accent bar, like the board
        Colors := DepartmentColors[M.Department];
        Item.Rounding := 8;
        Item.Color := Colors.Fill;
        Item.TitleColor := Item.Color;
        Item.StrokeColor := Item.Color;
        Item.TitleStrokeColor := Item.Color;
        Item.TitleFontColor := Colors.Font;
        Item.FontColor := $FF334155;
        Item.SelectedColor := $FFDBEAFE;
        Item.SelectedTitleColor := Item.SelectedColor;
        Item.SelectedStrokeColor := Primary;
        Item.SelectedTitleStrokeColor := Primary;
        Item.SelectedTitleFontColor := $FF1E3A8A;
        Item.SelectedFontColor := Item.FontColor;
        Item.MarkType := [imtLeft];
        Item.MarkColor := Colors.Font;
        Item.MarkSizeLeft := 4;
        if M.AppointmentSynced then
          Item.Title := Item.Title + '  '#$E73E;   // check mark
      end;
  finally
    plWorkshop.EndUpdate;
  end;
  plWorkshop.TimeLine.ViewStart := Int(First) + EncodeTime(8, 0, 0, 0);
end;

procedure TfrWorkshop.plWorkshopAfterMoveItem(Sender: TObject; AItem: TTMSFNCPlannerItem;
  ANewStartTime, ANewEndTime: TDateTime; ANewPosition: Integer);
begin
  Dashboard.RunTool('set_appointment', IdArgs(AItem.DataInteger).AddPair('start', SlotToStr(ANewStartTime)),
    'Workshop appointment moved to ' + FormatDateTime('ddd dd/mm hh:nn', ANewStartTime) + '.');
end;

procedure TfrWorkshop.plWorkshopItemDblClick(Sender: TObject; AItem: TTMSFNCPlannerItem);
var
  Start: string;
begin
  // A double-click on an existing booking cancels it (the customer called off)
  if AItem.DataInteger <> 0 then
    Exit;
  Start := AItem.DataString;
  Confirm(Format('Cancel the workshop booking of %s?', [FormatDateTime('dddd dd/mm hh:nn', ParseSlot(Start))]),
    procedure
    begin
      Dashboard.RunTool('cancel_booking', TJSONObject.Create.AddPair('start', Start), 'Workshop booking cancelled.');
    end);
end;

procedure TfrWorkshop.btnSyncCalendarClick(Sender: TObject);
begin
  Dashboard.SetStatus('Syncing the workshop appointments to the calendar...');
  Dashboard.RunTool('sync_calendar', nil, '',
    procedure(AResult: TJSONValue)
    begin
      Dashboard.SetStatus(AResult.GetValue<string>('result', AResult.GetValue<string>('note', '')));
    end);
end;

end.
