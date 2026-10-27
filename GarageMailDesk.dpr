program GarageMailDesk;

uses
  System.StartUpCopy,
  FMX.Forms,
  uMain in 'uMain.pas' {frmMain},
  uTriageModel in 'uTriageModel.pas',
  uRouting in 'uRouting.pas',
  uTheme in 'uTheme.pas',
  uMailJSON in 'uMailJSON.pas',
  uEngineClient in 'uEngineClient.pas',
  uDashboard in 'uDashboard.pas',
  uAssistantFrame in 'uAssistantFrame.pas' {frAssistant: TFrame},
  uInboxFrame in 'uInboxFrame.pas' {frInbox: TFrame},
  uBoardFrame in 'uBoardFrame.pas' {frBoard: TFrame},
  uWorkshopFrame in 'uWorkshopFrame.pas' {frWorkshop: TFrame},
  uRoutingFrame in 'uRoutingFrame.pas' {frRouting: TFrame},
  uSettingsFrame in 'uSettingsFrame.pas' {frSettings: TFrame},
  uSpamFrame in 'uSpamFrame.pas' {frSpam: TFrame};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
