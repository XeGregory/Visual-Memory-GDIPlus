unit Unit1;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls,
  GDIPAPI, GDIPOBJ, Types, Math, System.Generics.Collections;

type
  TPressedButton = (pbNone, pbStart, pbCheck, pbReplay);

  TForm1 = class(TForm)
    PaintBox1: TPaintBox;
    TimerFade: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure PaintBox1Paint(Sender: TObject);
    procedure PaintBox1MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBox1MouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBox1MouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure TimerFadeTimer(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FGdiPlusToken: ULONG_PTR;

    // grille
    FRows, FCols: Integer;
    FCellSize: Integer;
    FOffsetX, FOffsetY: Integer;
    Grid: array of array of Boolean;
    Pattern: array of array of Boolean;
    ShowPattern: Boolean;
    ShowPatternAlpha: Integer;
    DisplayMs: Integer;

    // layout boutons
    RStart, RCheck, RReplay, RStatus: TRect;
    PressedButton: TPressedButton;
    HoverButton: TPressedButton;

    // interaction
    HoverRow, HoverCol: Integer;
    Score: Integer;
    FStatusText: string;

    // progression / niveaux
    FLevel: Integer;
    FPatternCount: Integer;
    MaxPatternCount: Integer;
    FJustLeveled: Boolean;

    // helpers
    procedure InitGrid(ARows, ACols: Integer);
    procedure ClearGrid;
    procedure GeneratePatternCount(Count: Integer);
    function IsPatternReproduced: Boolean;
    procedure StartRound;
    procedure LevelUp;
    procedure UpdateLayout;
    procedure DrawRoundedRect(g: TGPGraphics; const R: TRect; Radius: Single;
      Brush: TGPSolidBrush; Pen: TGPPen);
    procedure DrawButton(g: TGPGraphics; const R: TRect; const Caption: string;
      Pressed, Hover: Boolean);
    function FlatColor(const AHex: string; AAlpha: Byte = 255): TGPColor;
    function PtInRectInflated(const R: TRect; const P: TPoint;
      Margin: Integer = 2): Boolean;
    procedure ReplayPattern;
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

{ -------------------- Utilitaires -------------------- }
function HexToInt(const H: string): Integer;
begin
  Result := StrToInt('$' + H);
end;

function TForm1.FlatColor(const AHex: string; AAlpha: Byte): TGPColor;
var
  R, g, b: Integer;
begin
  R := HexToInt(Copy(AHex, 1, 2)) and $FF;
  g := HexToInt(Copy(AHex, 3, 2)) and $FF;
  b := HexToInt(Copy(AHex, 5, 2)) and $FF;
  Result := MakeColor(AAlpha, R, g, b);
end;

function TForm1.PtInRectInflated(const R: TRect; const P: TPoint;
  Margin: Integer): Boolean;
var
  R2: TRect;
begin
  R2 := Rect(R.Left - Margin, R.Top - Margin, R.Right + Margin,
    R.Bottom + Margin);
  Result := PtInRect(R2, P);
end;

{ -------------------- Init / cleanup GDI+ -------------------- }
procedure TForm1.FormCreate(Sender: TObject);
var
  StartupInput: TGdiplusStartupInput;
  Status: TStatus;
begin
  Randomize;

  // Initialisation GDI+
  StartupInput.GdiplusVersion := 1;
  StartupInput.DebugEventCallback := nil;
  StartupInput.SuppressBackgroundThread := False;
  StartupInput.SuppressExternalCodecs := False;
  FGdiPlusToken := 0;
  Status := GdiplusStartup(FGdiPlusToken, @StartupInput, nil);
  if Status <> Ok then
    raise Exception.CreateFmt('GDI+ initialization failed (code %d)',
      [Integer(Status)]);

  DoubleBuffered := True;

  // titre du formulaire (en français)
  Self.Caption := 'Jeu de mémoire';

  // paramètres du jeu
  FRows := 6;
  FCols := 6;
  MaxPatternCount := Min(FRows * FCols, 20); // sécurité
  // progression initiale : niveau 1, 2 cases à mémoriser
  FLevel := 1;
  FPatternCount := 2;
  DisplayMs := 900;

  InitGrid(FRows, FCols);
  ClearGrid;

  ShowPattern := False;
  ShowPatternAlpha := 0;

  HoverRow := -1;
  HoverCol := -1;
  Score := 0;
  FStatusText := Format('Niveau %d - %d cases - clique Démarrer',
    [FLevel, FPatternCount]);

  // initialisation du drapeau
  FJustLeveled := False;

  TimerFade.Enabled := False;
  TimerFade.Interval := 30;

  PressedButton := pbNone;
  HoverButton := pbNone;

  UpdateLayout;
  PaintBox1.Invalidate;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if FGdiPlusToken <> 0 then
    GdiplusShutdown(FGdiPlusToken);
end;

{ -------------------- Grille -------------------- }
procedure TForm1.InitGrid(ARows, ACols: Integer);
var
  i: Integer;
begin
  SetLength(Grid, ARows);
  SetLength(Pattern, ARows);
  for i := 0 to ARows - 1 do
  begin
    SetLength(Grid[i], ACols);
    SetLength(Pattern[i], ACols);
  end;
end;

procedure TForm1.ClearGrid;
var
  i, j: Integer;
begin
  for i := 0 to FRows - 1 do
    for j := 0 to FCols - 1 do
      Grid[i][j] := False;
end;

{ Génère un motif composé d'exactement Count cases allumées (aléatoire, sans doublons) }
procedure TForm1.GeneratePatternCount(Count: Integer);
var
  total, i, idx: Integer;
  indices: TList<Integer>;
  R, c: Integer;
begin
  total := FRows * FCols;
  if Count <= 0 then
    Count := 1;
  if Count > total then
    Count := total;

  // reset pattern
  for R := 0 to FRows - 1 do
    for c := 0 to FCols - 1 do
      Pattern[R][c] := False;

  // liste d'indices 0..total-1
  indices := TList<Integer>.Create;
  try
    for i := 0 to total - 1 do
      indices.Add(i);
    // shuffle (Fisher-Yates)
    for i := total - 1 downto 1 do
    begin
      idx := Random(i + 1);
      // swap indices[i] <-> indices[idx]
      if idx <> i then
        indices.Exchange(i, idx);
    end;
    // prendre les Count premiers
    for i := 0 to Count - 1 do
    begin
      idx := indices[i];
      R := idx div FCols;
      c := idx mod FCols;
      Pattern[R][c] := True;
    end;
  finally
    indices.Free;
  end;
end;

function TForm1.IsPatternReproduced: Boolean;
var
  i, j: Integer;
begin
  for i := 0 to FRows - 1 do
    for j := 0 to FCols - 1 do
      if Grid[i][j] <> Pattern[i][j] then
        Exit(False);
  Result := True;
end;

{ Démarre un round en utilisant FPatternCount et DisplayMs }
procedure TForm1.StartRound;
begin
  ClearGrid;
  GeneratePatternCount(FPatternCount);
  ShowPattern := True;
  ShowPatternAlpha := 255;
  // ajuster la durée d'affichage selon le niveau (plus le niveau est élevé, plus c'est court)
  DisplayMs := Max(300, 900 - (FLevel - 1) * 50);
  TimerFade.Interval := 30;
  TimerFade.Enabled := True;
  FStatusText := Format('Niveau %d - Observe %d cases',
    [FLevel, FPatternCount]);

  // réinitialiser le drapeau : nouveau round, on peut de nouveau valider
  FJustLeveled := False;

  PaintBox1.Invalidate;
end;

{ Appelé quand le joueur réussit un motif }
procedure TForm1.LevelUp;
begin
  Inc(FLevel);
  // augmenter le nombre de cases progressivement
  if FPatternCount < MaxPatternCount then
    Inc(FPatternCount);
  Inc(Score);
  FStatusText := Format('Bravo ! Niveau %d — %d cases',
    [FLevel, FPatternCount]);

  // indiquer qu'on vient de passer de niveau
  FJustLeveled := True;

  PaintBox1.Invalidate;
end;

{ -------------------- Layout et positions boutons -------------------- }
procedure TForm1.UpdateLayout;
var
  Margin, availableW, availableH, gridW, gridH, btnW, btnH, spaceBelow, statusH,
    statusGap, totalBtnW, startX, availableHeightForGrid: Integer;
  maxBtnW: Integer;
begin
  Margin := 12;
  statusH := 28; // hauteur réservée pour le texte de statut en haut
  statusGap := 10; // marge entre le texte de statut et la grille

  // zone disponible dans le PaintBox (on réserve statusH + statusGap en haut)
  availableW := Max(0, PaintBox1.Width - Margin * 2);
  availableH := Max(0, PaintBox1.Height - Margin * 2 - statusH - statusGap);

  // taille initiale d'une cellule (maximale)
  if FCols > 0 then
    FCellSize := Max(10, availableW div FCols)
  else
    FCellSize := 24;

  // calcule la hauteur nécessaire pour la grille
  gridW := FCellSize * FCols;
  gridH := FCellSize * FRows;

  // espace réservé pour les boutons (hauteur)
  btnW := 120;
  btnH := 36;
  spaceBelow := btnH + Margin * 2;

  // si la grille + boutons dépasse la hauteur disponible, réduire FCellSize
  if (gridH + spaceBelow) > availableH then
  begin
    FCellSize := Max(8, (availableH - spaceBelow) div FRows);
    gridW := FCellSize * FCols;
    gridH := FCellSize * FRows;
  end;

  // centrer la grille horizontalement
  FOffsetX := Max(8, (PaintBox1.Width - gridW) div 2);

  // centrer verticalement la grille dans l'espace restant entre statut et boutons
  availableHeightForGrid := availableH - spaceBelow;
  if availableHeightForGrid < 0 then
    availableHeightForGrid := 0;
  // position Y de la grille = top margin + statusH + statusGap + centering offset
  FOffsetY := Margin + statusH + statusGap +
    Max(0, (availableHeightForGrid - gridH) div 2);

  // adapter la largeur des boutons si la grille est étroite
  maxBtnW := Max(80, gridW div 3); // bouton minimum 80, sinon 1/3 de la grille
  if btnW > maxBtnW then
    btnW := maxBtnW;

  // positionner les boutons centrés sous la grille (trois boutons)
  // espacement entre boutons = Margin
  totalBtnW := btnW * 3 + Margin * 2;
  // largeur totale des trois boutons + espaces
  startX := FOffsetX + Max(0, (gridW - totalBtnW) div 2);

  RStart := Rect(startX, FOffsetY + gridH + Margin, startX + btnW,
    FOffsetY + gridH + Margin + btnH);
  RCheck := Rect(startX + btnW + Margin, FOffsetY + gridH + Margin,
    startX + btnW + Margin + btnW, FOffsetY + gridH + Margin + btnH);
  RReplay := Rect(startX + (btnW + Margin) * 2, FOffsetY + gridH + Margin,
    startX + (btnW + Margin) * 2 + btnW, FOffsetY + gridH + Margin + btnH);

  // zone statut (au dessus de la grille, largeur = largeur de la grille)
  RStatus := Rect(FOffsetX, Margin, FOffsetX + gridW, Margin + statusH);

  PaintBox1.Invalidate;
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  UpdateLayout;
end;

{ -------------------- Dessin utilitaires -------------------- }
procedure TForm1.DrawRoundedRect(g: TGPGraphics; const R: TRect; Radius: Single;
  Brush: TGPSolidBrush; Pen: TGPPen);
var
  rF: TGPRectF;
  gpPath: TGPGraphicsPath;
begin
  rF.X := R.Left;
  rF.Y := R.Top;
  rF.Width := R.Right - R.Left;
  rF.Height := R.Bottom - R.Top;

  gpPath := TGPGraphicsPath.Create;
  try
    gpPath.AddArc(rF.X, rF.Y, Radius * 2, Radius * 2, 180, 90);
    gpPath.AddArc(rF.X + rF.Width - Radius * 2, rF.Y, Radius * 2,
      Radius * 2, 270, 90);
    gpPath.AddArc(rF.X + rF.Width - Radius * 2, rF.Y + rF.Height - Radius * 2,
      Radius * 2, Radius * 2, 0, 90);
    gpPath.AddArc(rF.X, rF.Y + rF.Height - Radius * 2, Radius * 2,
      Radius * 2, 90, 90);
    gpPath.CloseFigure;
    g.FillPath(Brush, gpPath);
    if Assigned(Pen) then
      g.DrawPath(Pen, gpPath);
  finally
    gpPath.Free;
  end;
end;

procedure TForm1.DrawButton(g: TGPGraphics; const R: TRect;
  const Caption: string; Pressed, Hover: Boolean);
var
  clrBg, clrEdge, clrText: TGPColor;
  brushBg, brushText: TGPSolidBrush;
  penEdge: TGPPen;
  gpRectF: TGPRectF;
  font: TGPFont;
  fmt: TGPStringFormat;
begin
  if Pressed then
    clrBg := FlatColor('16A085', 255)
  else if Hover then
    clrBg := FlatColor('48C9B0', 255)
  else
    clrBg := FlatColor('2ECC71', 255);

  clrEdge := FlatColor('27AE60', 255);
  clrText := MakeColor(255, 255, 255, 255);

  brushBg := TGPSolidBrush.Create(clrBg);
  brushText := TGPSolidBrush.Create(clrText);
  penEdge := TGPPen.Create(clrEdge, 1);

  try
    DrawRoundedRect(g, R, 6, brushBg, penEdge);

    gpRectF.X := R.Left;
    gpRectF.Y := R.Top;
    gpRectF.Width := R.Right - R.Left;
    gpRectF.Height := R.Bottom - R.Top;

    // police agrandie pour les boutons
    font := TGPFont.Create('Segoe UI', 14, FontStyleBold, UnitPixel);
    fmt := TGPStringFormat.Create;
    try
      fmt.SetAlignment(StringAlignmentCenter);
      fmt.SetLineAlignment(StringAlignmentCenter);
      g.DrawString(Caption, -1, font, gpRectF, fmt, brushText);
    finally
      fmt.Free;
      font.Free;
    end;
  finally
    penEdge.Free;
    brushBg.Free;
    brushText.Free;
  end;
end;

{ -------------------- Timer fondu -------------------- }
procedure TForm1.TimerFadeTimer(Sender: TObject);
begin
  if not ShowPattern then
  begin
    TimerFade.Enabled := False;
    Exit;
  end;

  Dec(ShowPatternAlpha, 25);
  if ShowPatternAlpha <= 0 then
  begin
    ShowPatternAlpha := 0;
    ShowPattern := False;
    TimerFade.Enabled := False;
    FStatusText := Format('Niveau %d - Reproduis %d cases',
      [FLevel, FPatternCount]);
  end;
  PaintBox1.Invalidate;
end;

{ -------------------- Interaction souris et boutons -------------------- }
procedure TForm1.PaintBox1MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  col, row: Integer;
  pt: TPoint;
  prevHoverBtn: TPressedButton;
begin
  pt := Point(X, Y);

  prevHoverBtn := HoverButton;
  if PtInRectInflated(RStart, pt, 2) then
    HoverButton := pbStart
  else if PtInRectInflated(RCheck, pt, 2) then
    HoverButton := pbCheck
  else if PtInRectInflated(RReplay, pt, 2) then
    HoverButton := pbReplay
  else
    HoverButton := pbNone;

  // hover grille
  col := (X - FOffsetX) div FCellSize;
  row := (Y - FOffsetY) div FCellSize;
  if (col >= 0) and (col < FCols) and (row >= 0) and (row < FRows) then
  begin
    if (row <> HoverRow) or (col <> HoverCol) then
    begin
      HoverRow := row;
      HoverCol := col;
      PaintBox1.Invalidate;
    end;
  end
  else
  begin
    if (HoverRow <> -1) or (HoverCol <> -1) then
    begin
      HoverRow := -1;
      HoverCol := -1;
      PaintBox1.Invalidate;
    end;
  end;

  if prevHoverBtn <> HoverButton then
    PaintBox1.Invalidate;
end;

procedure TForm1.PaintBox1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  pt: TPoint;
  col, row: Integer;
begin
  pt := Point(X, Y);

  // bouton Démarrer
  if PtInRectInflated(RStart, pt, 2) then
  begin
    PressedButton := pbStart;
    PaintBox1.Invalidate;
    Exit;
  end;

  // bouton Vérifier
  if PtInRectInflated(RCheck, pt, 2) then
  begin
    PressedButton := pbCheck;
    PaintBox1.Invalidate;
    Exit;
  end;

  // bouton Revoir
  if PtInRectInflated(RReplay, pt, 2) then
  begin
    PressedButton := pbReplay;
    PaintBox1.Invalidate;
    Exit;
  end;

  // grille
  if ShowPattern then
    Exit;
  col := (X - FOffsetX) div FCellSize;
  row := (Y - FOffsetY) div FCellSize;
  if (col < 0) or (col >= FCols) or (row < 0) or (row >= FRows) then
    Exit;

  // basculer l'état de la case
  Grid[row][col] := not Grid[row][col];

  // NE PAS vérifier immédiatement ici ; l'utilisateur doit cliquer sur "Vérifier"
  FStatusText := Format('Niveau %d - Clique Vérifier pour valider', [FLevel]);

  PaintBox1.Invalidate;
end;

procedure TForm1.PaintBox1MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  pt: TPoint;
begin
  pt := Point(X, Y);

  // relâchement sur Démarrer
  if (PressedButton = pbStart) and PtInRectInflated(RStart, pt, 2) then
    StartRound;

  // relâchement sur Vérifier
  if (PressedButton = pbCheck) and PtInRectInflated(RCheck, pt, 2) then
  begin
    if ShowPattern then
      FStatusText := 'Attends que le motif disparaisse'
    else if IsPatternReproduced then
    begin
      // si on vient déjà de passer de niveau, ignorer les clics répétés
      if not FJustLeveled then
      begin
        LevelUp;
      end
      else
      begin
        // message informatif : déjà validé
        FStatusText := 'Déjà validé. Clique Démarrer pour continuer';
      end;
    end
    else
      FStatusText := 'Raté. Essaie encore';
  end;

  // relâchement sur Revoir
  if (PressedButton = pbReplay) and PtInRectInflated(RReplay, pt, 2) then
  begin
    if ShowPattern then
      FStatusText := 'Le motif est déjà affiché'
    else
      ReplayPattern;
  end;

  // annuler l'état pressé
  PressedButton := pbNone;
  PaintBox1.Invalidate;
end;

{ -------------------- Dessin principal (flat UI) -------------------- }
procedure TForm1.PaintBox1Paint(Sender: TObject);
var
  g: TGPGraphics;
  brushOn, brushOff, brushHover, brushShadow: TGPSolidBrush;
  penBorder: TGPPen;
  R, c, X, Y: Integer;
  clrOn, clrOff, clrBorder, clrHover, clrShadow: TGPColor;
  alphaFactor: Single;
  cellBrush: TGPSolidBrush;
  rectShadow: TGPRectF;
  statusText: string;
  gridW, textW, tx, ty, textH: Integer;
  brushStatusBg: TGPSolidBrush;
  penStatusEdge: TGPPen;
  statusRect: TRect;
begin
  g := TGPGraphics.Create(PaintBox1.Canvas.Handle);
  try
    g.SetSmoothingMode(SmoothingModeAntiAlias);

    // palette flat
    clrOn := FlatColor('2ECC71', 255); // vert flat
    clrOff := FlatColor('ECF0F1', 255); // gris clair flat
    clrBorder := FlatColor('95A5A6', 255); // gris bordure
    clrHover := FlatColor('27AE60', 160); // hover semi
    clrShadow := MakeColor(80, 0, 0, 0); // ombre

    brushOn := TGPSolidBrush.Create(clrOn);
    brushOff := TGPSolidBrush.Create(clrOff);
    brushHover := TGPSolidBrush.Create(clrHover);
    brushShadow := TGPSolidBrush.Create(clrShadow);
    penBorder := TGPPen.Create(clrBorder, 1);

    try
      g.Clear(MakeColor(255, 255, 255, 255));

      // statut (fond léger arrondi) - dessiné avant la grille pour éviter recouvrement
      PaintBox1.Canvas.font.Name := 'Segoe UI';
      PaintBox1.Canvas.font.Size := 11;
      PaintBox1.Canvas.font.Color := clBlack;
      PaintBox1.Canvas.Brush.Style := bsClear;

      statusText := Format('Niveau %d   %s   Score: %d',
        [FLevel, FStatusText, Score]);

      // zone de statut (RStatus) : dessiner un fond arrondi léger
      statusRect := RStatus;
      // si RStatus est vide (par ex. si gridW = 0), fallback
      if statusRect.Right <= statusRect.Left then
        statusRect := Rect(12, 12, PaintBox1.Width - 12, 12 + 28);

      brushStatusBg := TGPSolidBrush.Create(MakeColor(230, 255, 255, 255));
      // fond très léger
      penStatusEdge := TGPPen.Create(MakeColor(200, 240, 240, 240), 0.5);

      try
        DrawRoundedRect(g, statusRect, 6, brushStatusBg, penStatusEdge);
      finally
        penStatusEdge.Free;
        brushStatusBg.Free;
      end;

      // ombre sous la grille
      rectShadow.X := FOffsetX - 6;
      rectShadow.Y := FOffsetY - 6;
      rectShadow.Width := FCellSize * FCols + 12;
      rectShadow.Height := FCellSize * FRows + 12;
      g.FillRectangle(brushShadow, rectShadow.X, rectShadow.Y, rectShadow.Width,
        rectShadow.Height);

      // cases
      for R := 0 to FRows - 1 do
      begin
        for c := 0 to FCols - 1 do
        begin
          X := FOffsetX + c * FCellSize;
          Y := FOffsetY + R * FCellSize;

          if ShowPattern then
          begin
            alphaFactor := ShowPatternAlpha / 255;
            if Pattern[R][c] then
            begin
              cellBrush := TGPSolidBrush.Create
                (MakeColor(Round(255 * alphaFactor), 46, 204, 113));
              try
                g.FillRectangle(cellBrush, X + 1, Y + 1, FCellSize - 2,
                  FCellSize - 2);
              finally
                cellBrush.Free;
              end;
            end
            else
              g.FillRectangle(brushOff, X + 1, Y + 1, FCellSize - 2,
                FCellSize - 2);
          end
          else
          begin
            if Grid[R][c] then
              g.FillRectangle(brushOn, X + 1, Y + 1, FCellSize - 2,
                FCellSize - 2)
            else
              g.FillRectangle(brushOff, X + 1, Y + 1, FCellSize - 2,
                FCellSize - 2);
          end;

          if (R = HoverRow) and (c = HoverCol) and (not ShowPattern) then
            g.FillRectangle(brushHover, X + 3, Y + 3, FCellSize - 6,
              FCellSize - 6);

          g.DrawRectangle(penBorder, X + 1, Y + 1, FCellSize - 2,
            FCellSize - 2);
        end;
      end;

      // boutons dessinés dans le PaintBox
      DrawButton(g, RStart, 'Démarrer', PressedButton = pbStart,
        HoverButton = pbStart);
      DrawButton(g, RCheck, 'Vérifier', PressedButton = pbCheck,
        HoverButton = pbCheck);
      DrawButton(g, RReplay, 'Revoir', PressedButton = pbReplay,
        HoverButton = pbReplay);

      // statut centré au-dessus de la grille (texte)
      gridW := FCellSize * FCols;
      textW := PaintBox1.Canvas.TextWidth(statusText);
      textH := PaintBox1.Canvas.TextHeight(statusText);
      tx := FOffsetX + Max(0, (gridW - textW) div 2);
      // centrer verticalement dans RStatus
      ty := RStatus.Top + Max(0, (RStatus.Bottom - RStatus.Top - textH) div 2);
      PaintBox1.Canvas.TextOut(tx, ty, statusText);

    finally
      penBorder.Free;
      brushOn.Free;
      brushOff.Free;
      brushHover.Free;
      brushShadow.Free;
    end;
  finally
    g.Free;
  end;
end;

{ -------------------- Replay Pattern -------------------- }
procedure TForm1.ReplayPattern;
begin
  if (FPatternCount <= 0) then
  begin
    FStatusText := 'Aucun motif à revoir. Clique Démarrer d''abord';
    Exit;
  end;

  ShowPattern := True;
  ShowPatternAlpha := 255;
  DisplayMs := Max(300, 900 - (FLevel - 1) * 50);
  TimerFade.Interval := 30;
  TimerFade.Enabled := True;
  FStatusText := Format('Niveau %d - Observe à nouveau %d cases',
    [FLevel, FPatternCount]);

  PaintBox1.Invalidate;
end;

end.
