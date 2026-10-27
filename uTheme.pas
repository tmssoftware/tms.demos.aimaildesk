{ TMS AI Mail Desk - shared look
  The colours of the app are designed in the .fmx files. This unit has what
  code needs on top of that: the department palette (grid badges, board
  headers, workshop appointments), a few helpers for the FNC controls, and the
  FMX style book with rounded inputs and thin scrollbars. }

unit uTheme;

interface

uses
  System.Classes, System.UITypes, FMX.Types, FMX.Controls, FMX.ListBox,
  FMX.TMSFNCTableView, uTriageModel;

type
  TBadgeColors = record
    Fill, Font: TAlphaColor;
  end;

const
  Ink = $FF0F172A;
  Muted = $FF64748B;
  Primary = $FF2563EB;

  // Same palette as the conditional formatting rules of the mail grid
  DepartmentColors: array[TDepartment] of TBadgeColors = (
    (Fill: $FFF1F5F9; Font: $FF475569),  // Reception
    (Fill: $FFEFF6FF; Font: $FF1D4ED8),  // Sales
    (Fill: $FFF5F3FF; Font: $FF6D28D9),  // Accessories
    (Fill: $FFFFF7ED; Font: $FFC2410C),  // Maintenance
    (Fill: $FFECFDF5; Font: $FF047857),  // Finance
    (Fill: $FFF0FDFA; Font: $FF0F766E)   // Second-hand
  );

// '#RRGGBB' for the FNC HTML engine
function HtmlColor(AColor: TAlphaColor): string;
// Chat and kanban columns are table views around an inner tree view: no frame or lines
procedure FlattenTreeView(ATree: TTMSFNCTreeViewTableView);
// Item font size of a combo box (call again after filling it)
procedure FixComboFont(ACombo: TComboBox);
// The Win10Modern FMX style (LightStyle.res) with rounded inputs and thin scrollbars
function AppStyleBook: TStyleBook;

implementation

{$R LightStyle.res}

uses
  System.SysUtils, System.Types, FMX.Objects, FMX.Forms, FMX.StdCtrls, FMX.Layouts, FMX.Ani, FMX.Graphics,
  FMX.TMSFNCGraphicsTypes;

function HtmlColor(AColor: TAlphaColor): string;
begin
  Result := '#' + IntToHex(AColor and $FFFFFF, 6);
end;

procedure FlattenTreeView(ATree: TTMSFNCTreeViewTableView);
begin
  ATree.Stroke.Kind := gskNone;
  ATree.Fill.Kind := gfkNone;
  ATree.ColumnsAppearance.TopStroke.Kind := gskNone;
  ATree.ColumnsAppearance.BottomStroke.Kind := gskNone;
  // The header corner above the (collapsed) scrollbar is filled with the default
  // column fill, which showed as a white dot above every board column
  ATree.ColumnsAppearance.FillEmptySpaces := False;
  ATree.GroupsAppearance.FillEmptySpaces := False;
end;

procedure FixComboFont(ACombo: TComboBox);
var
  I: Integer;
  Item: TListBoxItem;
begin
  // A combo box draws its selected item, so the item font decides the text size;
  // without this the style's font size is used, which is larger in the dark style
  for I := 0 to ACombo.Count - 1 do
  begin
    Item := ACombo.ListItems[I];
    Item.StyledSettings := Item.StyledSettings - [TStyledSetting.Size];
    Item.TextSettings.Font.Size := 13;
  end;
end;

{ Style book }

// Replaces a top-level style resource of a style book by ANew (same style name)
procedure ReplaceStyle(AStyle: TFmxObject; const AName: string; ANew: TFmxObject; AKeepChildren: Boolean);
var
  Old: TFmxObject;
begin
  Old := AStyle.FindStyleResource(AName);
  if not Assigned(Old) or not Assigned(Old.Parent) then
  begin
    ANew.Free;
    Exit;
  end;
  ANew.StyleName := AName;
  if AKeepChildren then
    while Old.ChildrenCount > 0 do
      Old.Children[0].Parent := ANew;
  Old.Parent.InsertObject(Old.Index, ANew);
  Old.Free;
end;

function AppStyleBook: TStyleBook;
const
  InputFill = TAlphaColors.White;
  InputStroke = $FFCBD5E1;
  InputFocus = Primary;
  Inputs: array[0..2] of string = ('editstyle', 'memostyle', 'comboboxstyle');
  Arrows: array[0..3] of string = ('scrollbarleftbutton', 'scrollbarrightbutton', 'scrollbartopbutton', 'scrollbarbottombutton');
  Tracks: array[0..1] of string = ('scrollbarhtrackstyle', 'scrollbarvtrackstyle');
  Thumbs: array[0..1] of string = ('hthumbstyle', 'vthumbstyle');
var
  Res: TResourceStream;
  StyleName: string;
  Root, Old, Content: TFmxObject;
  Rect: TRectangle;
  Anim: TColorAnimation;
begin
  Result := TStyleBook.Create(Application);
  Res := TResourceStream.Create(HInstance, 'LIGHTSTYLE', RT_RCDATA);
  try
    Result.LoadFromStream(Res);
  finally
    Res.Free;
  end;

  // Replace the bitmap 'background' of edits, memos and combo boxes by a rounded
  // rectangle; its children (memo content, scrollbars, combo arrow) move along
  for StyleName in Inputs do
  begin
    Root := Result.Style.FindStyleResource(StyleName);
    if not Assigned(Root) then
      Continue;
    Old := Root.FindStyleResource('background');
    if not (Old is TControl) then
      Continue;
    Rect := TRectangle.Create(nil);
    Rect.StyleName := 'background';
    Rect.Align := TAlignLayout.Contents;
    Rect.Padding := TControl(Old).Padding;
    Rect.HitTest := False;
    Rect.XRadius := 8;
    Rect.YRadius := 8;
    Rect.Fill.Color := InputFill;
    Rect.Stroke.Color := InputStroke;
    while Old.ChildrenCount > 0 do
      Old.Children[0].Parent := Rect;
    Root.InsertObject(Old.Index, Rect);
    Old.Free;
    // Room between the rounded border and the text
    Content := Root.FindStyleResource('content');
    if Content is TControl then
      TControl(Content).Margins.Left := TControl(Content).Margins.Left + 6;
    // Blue outline while the input has focus, like the selected cards
    Anim := TColorAnimation.Create(Rect);
    Anim.Parent := Rect;
    Anim.PropertyName := 'Stroke.Color';
    Anim.StartValue := InputStroke;
    Anim.StopValue := InputFocus;
    Anim.Duration := 0.15;
    Anim.Trigger := 'IsFocused=true';
    Anim.TriggerInverse := 'IsFocused=false';
  end;

  // Scrollbars (grids, memos, lists): no arrow buttons, an invisible track and a
  // thin rounded thumb that turns blue on hover, instead of the grey bitmaps
  for StyleName in Arrows do
    ReplaceStyle(Result.Style, StyleName, TLayout.Create(nil), False);
  for StyleName in Tracks do
    ReplaceStyle(Result.Style, StyleName, TLayout.Create(nil), True);
  for StyleName in Thumbs do
  begin
    Root := TLayout.Create(nil);
    Rect := TRectangle.Create(Root);
    Rect.Parent := Root;
    Rect.Align := TAlignLayout.Client;
    Rect.Margins.Rect := TRectF.Create(3, 3, 3, 3);
    Rect.HitTest := False;
    Rect.XRadius := 3;
    Rect.YRadius := 3;
    Rect.Stroke.Kind := TBrushKind.None;
    Rect.Fill.Color := InputStroke;
    Anim := TColorAnimation.Create(Rect);
    Anim.Parent := Rect;
    Anim.PropertyName := 'Fill.Color';
    Anim.StartValue := InputStroke;
    Anim.StopValue := InputFocus;
    Anim.Duration := 0.15;
    Anim.Trigger := 'IsMouseOver=true';
    Anim.TriggerInverse := 'IsMouseOver=false';
    ReplaceStyle(Result.Style, StyleName, Root, False);
  end;
end;

end.
