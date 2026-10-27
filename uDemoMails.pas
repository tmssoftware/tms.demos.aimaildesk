{ TMS AI Mail Desk - showcase demo
  A set of realistic, multilingual sample mails so the demo can be shown
  without connecting a real Gmail / Outlook mailbox. }

unit uDemoMails;

interface

uses
  System.SysUtils, uTriageModel;

procedure LoadDemoMails(AList: TTriageMailList; var ANextID: Integer);
function DemoAttachment(const AFileName: string): string;

implementation

uses
  System.IOUtils;

type
  TDemoMail = record
    FromName, FromEmail, Received, Subject, Body: string;
  end;

const
  DemoMails: array[0..14] of TDemoMail = (
    (FromName: 'Marc Verbeke'; FromEmail: 'marc.verbeke@example.com'; Received: '2026-10-13 07:42';
     Subject: 'Quote for a new ID.4 Pro';
     Body: 'Hello,'#13#10#13#10'I am interested in a new Volkswagen ID.4 Pro in Kings Red with the Infotainment package. ' +
           'Could you send me a quote including delivery time? I would also like to know if you have one in stock for a test drive.'#13#10#13#10'Kind regards,'#13#10'Marc'),

    (FromName: 'Ellen De Smet'; FromEmail: 'ellen.desmet@example.com'; Received: '2026-10-13 07:55';
     Subject: 'Car broken down on the E40!!';
     Body: 'Hi, my Audi A6 Avant (plate 1-ABC-123) just broke down on the E40 near Aalter. Engine warning light came on and it lost all power. ' +
           'I am standing on the hard shoulder with two kids. Can you send a tow truck or tell me what to do? Please call me back asap: 0470 12 34 56.'),

    (FromName: 'Jan Peeters'; FromEmail: 'jan.peeters@example.com'; Received: '2026-10-13 08:03';
     Subject: 'Trekhaak voor mijn Skoda Kodiaq';
     Body: 'Goedemorgen,'#13#10#13#10'Ik zou graag een afneembare trekhaak laten plaatsen op mijn Skoda Kodiaq (2024). ' +
           'Wat kost dat inclusief montage en hoe snel kunnen jullie dat doen? Ik heb hem nodig voor een fietsendrager tegen eind oktober.'#13#10#13#10'Groeten,'#13#10'Jan'),

    (FromName: 'Camille Dubois'; FromEmail: 'camille.dubois@example.com'; Received: '2026-10-13 08:17';
     Subject: 'Question concernant mon contrat de leasing';
     Body: 'Bonjour,'#13#10#13#10'Mon contrat de leasing pour la Cupra Formentor se termine en janvier. ' +
           'Quelles sont mes options : prolonger le contrat, racheter le v'#$00E9'hicule ou passer '#$00E0' un nouveau leasing ? ' +
           'Pouvez-vous m''envoyer une simulation de la valeur r'#$00E9'siduelle ?'#13#10#13#10'Cordialement,'#13#10'Camille Dubois'),

    (FromName: 'Thomas Wouters'; FromEmail: 'thomas.wouters@example.com'; Received: '2026-10-13 08:31';
     Subject: 'Selling my 2018 Golf';
     Body: 'Hi there, I want to sell my 2018 Volkswagen Golf 1.5 TSI, 86.000 km, full service history at your garage. ' +
           'Do you buy used cars directly? What would you offer for it? I am not necessarily buying a new car from you.'),

    (FromName: 'Sarah Claes'; FromEmail: 'sarah.claes@example.com'; Received: '2026-10-13 08:46';
     Subject: 'Afspraak onderhoud Polo';
     Body: 'Hallo,'#13#10#13#10'Mijn VW Polo (2021, 45.000 km) is toe aan een onderhoudsbeurt. Bij het remmen hoor ik ook een piepend geluid. ' +
           'Kan ik volgende week dinsdag of woensdag binnenbrengen? Graag ook een vervangwagen indien mogelijk.'#13#10#13#10'Bedankt,'#13#10'Sarah'),

    (FromName: 'Pieter Jacobs'; FromEmail: 'pieter.jacobs@example.com'; Received: '2026-10-13 09:02';
     Subject: 'Test drive Q6 e-tron this Saturday?';
     Body: 'Good morning, is it possible to book a test drive with the Audi Q6 e-tron this Saturday morning? ' +
           'We are considering replacing our current car and want to compare it with the Q4. Thanks, Pieter'),

    (FromName: 'Nathalie Maes'; FromEmail: 'nathalie.maes@example.com'; Received: '2026-10-13 09:15';
     Subject: 'Invoice 2026-1043 charged twice - complaint';
     Body: 'Hello,'#13#10#13#10'I noticed that invoice 2026-1043 for the service of my Skoda Octavia was charged TWICE on my credit card (2 x 389,50 EUR). ' +
           'This is the second time this happens. I expect a refund this week, otherwise I will contact my bank.'#13#10#13#10'Nathalie Maes'),

    (FromName: 'Lukas Becker'; FromEmail: 'lukas.becker@example.com'; Received: '2026-10-13 09:28';
     Subject: 'Probefahrt Cupra Born';
     Body: 'Guten Tag,'#13#10#13#10'ich interessiere mich f'#$00FC'r einen neuen Cupra Born mit der 79 kWh Batterie. ' +
           'K'#$00F6'nnte ich n'#$00E4'chste Woche eine Probefahrt machen und ein Angebot erhalten?'#13#10#13#10'Mit freundlichen Gr'#$00FC#$00DF'en,'#13#10'Lukas Becker'),

    (FromName: 'Hanne Willems'; FromEmail: 'hanne.willems@example.com'; Received: '2026-10-13 09:40';
     Subject: 'Looking for a used Octavia Combi';
     Body: 'Hi, we are looking for a pre-owned Skoda Octavia Combi, preferably diesel or hybrid, max 80.000 km and under 20.000 EUR. ' +
           'Do you have anything like that in your occasion stock? Thanks!'),

    (FromName: 'Youssef El Amrani'; FromEmail: 'youssef.elamrani@example.com'; Received: '2026-10-13 10:05';
     Subject: 'Application: car mechanic';
     Body: 'Dear sir/madam, I saw your vacancy for an experienced car mechanic and would like to apply. ' +
           'I have 6 years of experience at a VW group dealer. Please find my CV attached. Best regards, Youssef'),

    (FromName: 'Koen Mertens'; FromEmail: 'koen.mertens@example.com'; Received: '2026-10-13 10:21';
     Subject: 'Do you also service Toyota?';
     Body: 'Hello, I recently moved nearby and drive a Toyota Yaris Hybrid. It needs its yearly service and new tyres. ' +
           'Do you also service other brands, and what would it cost?'),

    (FromName: 'Lies Van den Broeck'; FromEmail: 'lies.vandenbroeck@example.com'; Received: '2026-10-13 10:37';
     Subject: 'Winter wheels for Audi Q4';
     Body: 'Hi, I would like a complete set of winter wheels (rims + tyres) for my Audi Q4 Sportback 45 e-tron, 19 inch if possible. ' +
           'Can you give me a price, and do you also offer storage for my summer wheels?'),

    // Two spam mails for the spam filter
    (FromName: 'Prize Department'; FromEmail: 'claims@lucky-draw-winners.example'; Received: '2026-10-13 10:44';
     Subject: 'Congratulations! You have won a Tesla Model Y';
     Body: 'Dear valued customer, you have been selected as the WINNER of our monthly lottery. ' +
           'Claim your prize today: click here and pay the small processing fee of 49 EUR with a gift card. ' +
           'Limited time offer, act now!'),

    (FromName: 'RankBoost Agency'; FromEmail: 'growth@rank-boost.example'; Received: '2026-10-13 10:52';
     Subject: 'Get your dealership on page 1 of Google';
     Body: 'Hi team, our SEO experts guarantee your dealership on the first page of Google within 30 days. ' +
           'High quality backlinks and lead generation for car dealers. Limited time offer: 50% off this month. ' +
           'Reply YES to get started. To unsubscribe, reply STOP.')
  );

procedure LoadDemoMails(AList: TTriageMailList; var ANextID: Integer);
var
  D: TDemoMail;
  M: TTriageMail;
begin
  for D in DemoMails do
  begin
    if AList.ContainsSourceID(msDemo, D.Subject) then
      Continue;
    M := TTriageMail.Create;
    M.ID := ANextID;
    Inc(ANextID);
    M.Source := msDemo;
    M.SourceID := D.Subject;
    M.FromName := D.FromName;
    M.FromEmail := D.FromEmail;
    M.Received := D.Received;
    M.Subject := D.Subject;
    M.Body := D.Body;
    M.Status := tsNew;
    // Two demo mails carry an attachment for the AI to look at
    if D.FromEmail = 'ellen.desmet@example.com' then
      M.Attachments := [DemoAttachment('dashboard.jpg')]
    else if D.FromEmail = 'nathalie.maes@example.com' then
      M.Attachments := [DemoAttachment('invoice-2026-1043.pdf')];
    AList.Add(M);
  end;
end;

function DemoAttachment(const AFileName: string): string;
var
  Dir: string;
  I: Integer;
begin
  // DemoAttachments lives in the project folder: next to the dashboard exe, one level above the MCP server exe
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to 3 do
  begin
    Result := TPath.Combine(TPath.Combine(Dir, 'DemoAttachments'), AFileName);
    if TFile.Exists(Result) then
      Exit;
    Dir := TPath.GetDirectoryName(ExcludeTrailingPathDelimiter(Dir));
  end;
  Result := '';
end;

end.
