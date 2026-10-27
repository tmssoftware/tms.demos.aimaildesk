{ TMS AI Mail Desk - showcase demo
  Routing table: which person handles which department / car brand.
  A rule with Brand = '*' is the fallback for its department. }

unit uRouting;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, uTriageModel;

const
  AnyBrand = '*';
  OtherBrand = 'Other';

type
  TRoutingRule = class
  public
    Department: TDepartment;
    Brand: string;
    HandlerName: string;
    HandlerEmail: string;
  end;

  TRoutingTable = class
  private
    FRules: TObjectList<TRoutingRule>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Add(ADepartment: TDepartment; const ABrand, AName, AEmail: string): TRoutingRule;
    procedure LoadDefaults;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    // [{"department":"sales","brand":"Audi","name":"...","email":"..."}, ...]
    procedure LoadFromJSON(const AJson: string);
    function ToJSON: string;
    function Resolve(ADepartment: TDepartment; const ABrand: string): TRoutingRule;
    function Brands: TArray<string>;
    function NormalizeBrand(const ABrand: string): string;
    property Rules: TObjectList<TRoutingRule> read FRules;
  end;

implementation

uses
  System.JSON, System.IOUtils;

{ TRoutingTable }

constructor TRoutingTable.Create;
begin
  inherited;
  FRules := TObjectList<TRoutingRule>.Create(True);
end;

destructor TRoutingTable.Destroy;
begin
  FRules.Free;
  inherited;
end;

procedure TRoutingTable.Clear;
begin
  FRules.Clear;
end;

function TRoutingTable.Add(ADepartment: TDepartment; const ABrand, AName, AEmail: string): TRoutingRule;
begin
  Result := TRoutingRule.Create;
  Result.Department := ADepartment;
  Result.Brand := ABrand;
  Result.HandlerName := AName;
  Result.HandlerEmail := AEmail;
  FRules.Add(Result);
end;

procedure TRoutingTable.LoadDefaults;
const
  Domain = '@brightline-motors.example';
begin
  // Fictional multi-brand dealership. The .example domain is reserved,
  // so nothing gets delivered until you configure real addresses.
  Clear;
  Add(dpSales, 'Volkswagen', 'Lukas Peeters', 'lukas.peeters' + Domain);
  Add(dpSales, 'Audi', 'Sofie Janssens', 'sofie.janssens' + Domain);
  Add(dpSales, 'Skoda', 'Pieter Claes', 'pieter.claes' + Domain);
  Add(dpSales, 'Cupra', 'Emma Willems', 'emma.willems' + Domain);
  Add(dpSales, AnyBrand, 'Sales desk', 'sales' + Domain);

  Add(dpMaintenance, 'Volkswagen', 'Tom Maes (VW workshop)', 'workshop.vw' + Domain);
  Add(dpMaintenance, 'Skoda', 'Tom Maes (VW workshop)', 'workshop.vw' + Domain);
  Add(dpMaintenance, 'Audi', 'Nina Jacobs (Audi service)', 'service.audi' + Domain);
  Add(dpMaintenance, AnyBrand, 'Service planning', 'service' + Domain);

  Add(dpAccessories, AnyBrand, 'Jonas Wouters', 'parts' + Domain);
  Add(dpFinance, AnyBrand, 'Laura Mertens', 'finance' + Domain);
  Add(dpSecondHand, AnyBrand, 'Kevin Dubois', 'occasions' + Domain);
  Add(dpOther, AnyBrand, 'Reception', 'info' + Domain);
end;

procedure TRoutingTable.LoadFromFile(const AFileName: string);
begin
  LoadFromJSON(TFile.ReadAllText(AFileName, TEncoding.UTF8));
end;

procedure TRoutingTable.LoadFromJSON(const AJson: string);
var
  Root: TJSONValue;
  Item: TJSONValue;
  Obj: TJSONObject;
begin
  Root := TJSONObject.ParseJSONValue(AJson);
  try
    if not (Root is TJSONArray) then
      raise Exception.Create('The routing table must be a JSON array');
    // Validate everything before the current rules are replaced
    for Item in TJSONArray(Root) do
      if not (Item is TJSONObject) or (TJSONObject(Item).GetValue<string>('email', '').Trim = '') then
        raise Exception.Create('Every routing rule needs a department, brand, name and email');
    Clear;
    for Item in TJSONArray(Root) do
    begin
      Obj := Item as TJSONObject;
      Add(DepartmentFromKey(Obj.GetValue<string>('department', '')),
        Obj.GetValue<string>('brand', AnyBrand).Trim,
        Obj.GetValue<string>('name', '').Trim,
        Obj.GetValue<string>('email', '').Trim);
    end;
  finally
    Root.Free;
  end;
end;

procedure TRoutingTable.SaveToFile(const AFileName: string);
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(ToJSON);
  try
    TFile.WriteAllText(AFileName, V.Format(2), TEncoding.UTF8);
  finally
    V.Free;
  end;
end;

function TRoutingTable.ToJSON: string;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  R: TRoutingRule;
begin
  Arr := TJSONArray.Create;
  try
    for R in FRules do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('department', DepartmentKeys[R.Department]);
      Obj.AddPair('brand', R.Brand);
      Obj.AddPair('name', R.HandlerName);
      Obj.AddPair('email', R.HandlerEmail);
      Arr.AddElement(Obj);
    end;
    Result := Arr.ToJSON;
  finally
    Arr.Free;
  end;
end;

function TRoutingTable.Resolve(ADepartment: TDepartment; const ABrand: string): TRoutingRule;
var
  R: TRoutingRule;
begin
  // 1. exact department + brand
  for R in FRules do
    if (R.Department = ADepartment) and SameText(R.Brand, ABrand) then
      Exit(R);
  // 2. department fallback
  for R in FRules do
    if (R.Department = ADepartment) and (R.Brand = AnyBrand) then
      Exit(R);
  // 3. reception
  for R in FRules do
    if (R.Department = dpOther) and (R.Brand = AnyBrand) then
      Exit(R);
  Result := nil;
end;

function TRoutingTable.Brands: TArray<string>;
var
  L: TStringList;
  R: TRoutingRule;
begin
  L := TStringList.Create;
  try
    L.Sorted := True;
    L.Duplicates := dupIgnore;
    L.CaseSensitive := False;
    for R in FRules do
      if (R.Brand <> '') and (R.Brand <> AnyBrand) then
        L.Add(R.Brand);
    Result := L.ToStringArray;
  finally
    L.Free;
  end;
end;

function TRoutingTable.NormalizeBrand(const ABrand: string): string;
var
  B, Known: string;
begin
  B := ABrand.Trim;
  // common aliases / accents
  if SameText(B, 'VW') then
    B := 'Volkswagen'
  else if SameText(B, #$0160'koda') then
    B := 'Skoda';

  for Known in Brands do
    if SameText(Known, B) then
      Exit(Known);
  Result := OtherBrand;
end;

end.
