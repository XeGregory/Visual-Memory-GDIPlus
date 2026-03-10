object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'Jeu de m'#233'moire'
  ClientHeight = 424
  ClientWidth = 462
  Color = clBtnFace
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnResize = FormResize
  TextHeight = 15
  object PaintBox1: TPaintBox
    Left = 0
    Top = 0
    Width = 462
    Height = 424
    Align = alClient
    OnMouseDown = PaintBox1MouseDown
    OnMouseMove = PaintBox1MouseMove
    OnMouseUp = PaintBox1MouseUp
    OnPaint = PaintBox1Paint
    ExplicitLeft = 120
    ExplicitTop = 96
    ExplicitWidth = 105
    ExplicitHeight = 105
  end
  object TimerFade: TTimer
    OnTimer = TimerFadeTimer
    Left = 40
    Top = 24
  end
end
