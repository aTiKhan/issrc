program ISCC;
{$APPTYPE CONSOLE}

{
  Inno Setup
  Copyright (C) 1997-2014 Jordan Russell
  Portions by Martijn Laan
  For conditions of distribution and use, see LICENSE.TXT.

  Command-line compiler
}

{x$DEFINE STATICCOMPILER}
{ For debugging purposes, remove the 'x' to have it link the compiler code
  into this program and not depend on ISCmplr.dll. }

uses
  SafeDLLPath in 'SafeDLLPath.pas',
  Windows, SysUtils, Classes,
  {$IFDEF STATICCOMPILER} Compile, {$ENDIF}
  PathFunc, CmnFunc2, CompInt, FileClass, CompTypes;

{$R *.res}
{$R ISCC.manifest.res}

{$I VERSION.INC}

type
  PScriptLine = ^TScriptLine;
  TScriptLine = record
    LineText: String;
    Next: PScriptLine;
  end;

var
  StdOutHandle, StdErrHandle: THandle;
  ScriptFilename: String;
  Output, OutputPath, OutputFilename, SignTool: String;
  ScriptLines, NextScriptLine: PScriptLine;
  CurLine: String;
  StartTime, EndTime: DWORD;
  Quiet, ShowProgress, WantAbort: Boolean;
  SignTools: TStringList;
  ProgressPoint: TPoint;
  LastProgress, LastPercentage, LastRemaining, LastAverage: String;

procedure WriteToStdHandle(const H: THandle; S: AnsiString);
var
  BytesWritten: DWORD;
begin
  if Copy(S, 1, 1) <> #13 then S := S + #13#10;
  WriteFile(H, S[1], Length(S), BytesWritten, nil);
end;

procedure WriteStdOut(const S: String);
begin
  WriteToStdHandle(StdOutHandle, AnsiString(S));
end;

procedure WriteStdErr(const S: String);
begin
  WriteToStdHandle(StdErrHandle, AnsiString(S));
end;

function GetCursorPos: TPoint;
var
  CSBI: TConsoleScreenBufferInfo;
begin
  if not GetConsoleScreenBufferInfo(StdOutHandle, CSBI) then
    Exit;
  Result.X := CSBI.dwCursorPosition.X;
  Result.Y := CSBI.dwCursorPosition.Y;
end;

procedure SetCursorPos(const P: TPoint);
var
  Coords: TCoord;
  CSBI: TConsoleScreenBufferInfo;
begin
  if not GetConsoleScreenBufferInfo(StdOutHandle, CSBI) then
  if P.X < 0 then Exit;
  if P.Y < 0 then Exit;
  if P.X > CSBI.dwSize.X then Exit;
  if P.Y > CSBI.dwSize.Y then Exit;
  Coords.X := P.X;
  Coords.Y := P.Y;
  SetConsoleCursorPosition(StdOutHandle, Coords);
end;

procedure ClearProgress;
var
  lwWritten: DWORD;
  Coord: TCoord;
  CSBI: TConsoleScreenBufferInfo;
begin
  if ProgressPoint.X < 0 then
    Exit;

  if not GetConsoleScreenBufferInfo(StdOutHandle, CSBI) then
    Exit;

  Coord.X := ProgressPoint.X;
  Coord.Y := ProgressPoint.Y;

  FillConsoleOutputCharacter(StdOutHandle, #32, CSBI.dwSize.X, Coord, lwWritten);
end;

procedure WriteProgress(const S: String);
var
  CSBI: TConsoleScreenBufferInfo;
  Str: String;
begin
  if GetConsoleScreenBufferInfo(StdOutHandle, CSBI) then
  begin
    if Length(S) > CSBI.dwSize.X then
      Str := Copy(S, 1, CSBI.dwSize.X)
    else
      Str := Format('%-' + IntToStr(CSBI.dwSize.X) + 's', [S]);
  end
  else
    Str := S;

  WriteToStdHandle(StdOutHandle, AnsiString(Str));
end;

function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  { Abort gracefully when Ctrl+C/Break is pressed }
  WantAbort := True;
  Result := True;
end;

procedure ReadScriptLines(const F: TTextFileReader);
var
  LineNumber: Integer;
  PrevLine, L: PScriptLine;
begin
  LineNumber := 1;
  PrevLine := nil;
  while not F.Eof do begin
    New(L);
    try
      L.LineText := F.ReadLine;
      if Pos(#0, L.LineText) <> 0 then
        raise Exception.CreateFmt('Illegal null character on line %d', [LineNumber]); 
      L.Next := nil;
    except
      Dispose(L);
      raise;
    end;
    if Assigned(PrevLine) then
      PrevLine.Next := L
    else begin
      ScriptLines := L;
      NextScriptLine := L;
    end;
    PrevLine := L;
    Inc(LineNumber);
  end;
end;

procedure FreeScriptLines;
var
  L, NextLine: PScriptLine;
begin
  L := ScriptLines;
  ScriptLines := nil;
  NextScriptLine := nil;
  while Assigned(L) do begin
    NextLine := L.Next;
    Dispose(L);
    L := NextLine;
  end;
end;

function CompilerCallbackProc(Code: Integer; var Data: TCompilerCallbackData;
  AppData: Longint): Integer; stdcall;

  procedure PrintProgress(Code: Integer);
  var
    Pt: TPoint;
    Percentage, Remaining, Average: String;
    Progress: String;
  begin
    if (Code = iscbNotifyIdle) and (Data.CompressProgressMax > 0) and (Data.CompressProgress / Data.CompressProgressMax > 0) then
      Percentage := FormatFloat('[0.00%]', Data.CompressProgress / Data.CompressProgressMax * 100)
    else if LastPercentage <> '' then
      Percentage := LastPercentage
    else
      Percentage := '[N/A]';
    LastPercentage := Percentage;

    if (Code = iscbNotifyIdle) and (Data.SecondsRemaining > 0) then
      Remaining := FormatFloat('0', Data.SecondsRemaining) + ' s'
    else if LastRemaining <> '' then
      Remaining := LastRemaining
    else
      Remaining := 'N/A';
    LastRemaining := Remaining;
    if Length(Remaining) > 5 then
      Remaining := Remaining;

    if (Code = iscbNotifyIdle) and (Data.BytesCompressedPerSecond > 1024) then
      Average := FormatFloat('0.00', Data.BytesCompressedPerSecond / 1024) + ' kb/s'
    else if (Code = iscbNotifyIdle) and (Data.BytesCompressedPerSecond > 0) then
      Average := FormatFloat('0.00', Data.BytesCompressedPerSecond) + ' b/s'
    else if LastAverage <> '' then
      Average := LastAverage
    else
      Average := 'N/A';
    LastAverage := Average;

    Progress := Format('%s Used: %.0f s. ' + 'Remaining: %s. Average: %s.',
      [Percentage, (GetTickCount - StartTime) / 1000, Remaining, Average]);
    if LastProgress = Progress then
      Exit;

    Pt := GetCursorPos;

    if Pt.Y <= ProgressPoint.Y then
      Exit
    else if ProgressPoint.X < 0 then begin
      ProgressPoint := Pt;
      WriteStdOut('');
      Pt := GetCursorPos;
    end;

    SetCursorPos(ProgressPoint);
    WriteProgress(#13 + Progress);
    LastProgress := Progress;
    SetCursorPos(Pt);
  end;

var
  S: String;
begin
  if WantAbort then begin
    Result := iscrRequestAbort;
    Exit;
  end;
  Result := iscrSuccess;
  case Code of
    iscbReadScript: begin
        { Note: In Inno Setup 3.0.1 and later we can ignore Data.Reset since
          it is only True once (when reading the first line). }
        if Assigned(NextScriptLine) then begin
          CurLine := NextScriptLine.LineText;
          NextScriptLine := NextScriptLine.Next;
          Data.LineRead := PChar(CurLine);
        end;
      end;
    iscbNotifyStatus:
      if not Quiet then
        WriteStdOut(Data.StatusMsg)
      else if ShowProgress then
        PrintProgress(Code);
    iscbNotifySuccess: begin
        EndTime := GetTickCount;
        if not Quiet then begin
          WriteStdOut('');
          if Data.OutputExeFilename <> '' then begin
            WriteStdOut(Format('Successful compile (%.3f sec). ' +
              'Resulting Setup program filename is:',
              [(EndTime - StartTime) / 1000]));
            WriteStdOut(Data.OutputExeFilename);
          end else
            WriteStdOut(Format('Successful compile (%.3f sec). ' +
              'Output was disabled.',
              [(EndTime - StartTime) / 1000]));
        end
        else if ShowProgress then
          ClearProgress;
      end;
    iscbNotifyError:
      if Assigned(Data.ErrorMsg) then begin
        if ShowProgress then
          ClearProgress;
        S := 'Error';
        if Data.ErrorLine <> 0 then
          S := S + Format(' on line %d', [Data.ErrorLine]);
        if Assigned(Data.ErrorFilename) then
          S := S + ' in ' + Data.ErrorFilename
        else if ScriptFilename <> '' then
          S := S + ' in ' + ScriptFilename;
        S := S + ': ' + Data.ErrorMsg;
        WriteStdErr(S);
      end;
    iscbNotifyIdle:
      if ShowProgress then
        PrintProgress(Code);
  end;
end;

procedure ProcessCommandLine;

  procedure ShowBanner;
  begin
    WriteStdOut('Inno Setup 5 Command-Line Compiler');
    WriteStdOut('Copyright (C) 1997-2014 Jordan Russell. All rights reserved.');
    WriteStdOut('Portions Copyright (C) 2000-2014 Martijn Laan');
    WriteStdOut('');
  end;

  procedure ShowUsage;
  begin
    WriteStdErr('Usage:  iscc [options] scriptfile.iss');
    WriteStdErr('or to read from standard input:  iscc [options] -');
    WriteStdErr('Options:  /DO            Disable output (overrides Output)');
    WriteStdErr('          /EO            Enable output (overrides Output)');
    WriteStdErr('          /Oc:\path      Output files to specified path (overrides OutputDir)');
    WriteStdErr('          /Ffilename     Overrides OutputBaseFilename with the specified filename');
    WriteStdErr('          /Sname=command Sets a SignTool with the specified name and command');
    WriteStdErr('          /Q             Quiet compile (print error messages only)');
    WriteStdErr('          /Qp            Enable quiet compile while still displaying progress');
    WriteStdErr('          /?             Show this help screen');
  end;

var
  I: Integer;
  S: String;
begin
  for I := 1 to NewParamCount do begin
    S := NewParamStr(I);
    if (S = '') or (S[1] = '/') then begin
      if CompareText(Copy(S, 1, 2), '/Q') = 0 then
      begin
        Quiet := True;
        ShowProgress := CompareText(Copy(S, 3, MaxInt), 'P') = 0;
      end
      else if CompareText(Copy(S, 1, 3), '/DO') = 0 then
        Output := 'no'
      else if CompareText(Copy(S, 1, 3), '/EO') = 0 then
        Output := 'yes'
      else if CompareText(Copy(S, 1, 2), '/O') = 0 then
        OutputPath := Copy(S, 3, MaxInt)
      else if CompareText(Copy(S, 1, 2), '/F') = 0 then
        OutputFilename := Copy(S, 3, MaxInt)
      else if CompareText(Copy(S, 1, 2), '/S') = 0 then begin
        SignTool := Copy(S, 3, MaxInt);
        if Pos('=', SignTool) = 0 then begin
          ShowBanner;
          WriteStdErr('Invalid option: ' + S);
          Halt(1);
        end;
      end
      else if S = '/?' then begin
        ShowBanner;
        ShowUsage;
        Halt(1);
      end
      else begin
        ShowBanner;
        WriteStdErr('Unknown option: ' + S);
        Halt(1);
      end;
    end
    else begin
      { Not a switch; must be the script filename }
      if ScriptFilename <> '' then begin
        ShowBanner;
        WriteStdErr('You may not specify more than one script filename.');
        Halt(1);
      end;
      ScriptFilename := S;
    end;
  end;

  if ScriptFilename = '' then begin
    ShowBanner;
    ShowUsage;
    Halt(1);
  end;

  if not Quiet then
    ShowBanner;
end;

procedure Go;
var
  ScriptPath: String;
  ExitCode: Integer;
  Ver: PCompilerVersionInfo;
  F: TTextFileReader;
  Params: TCompileScriptParamsEx;
  Options: String;
  Res: Integer;
  I: Integer;
begin
  if ScriptFilename <> '-' then begin
    ScriptFilename := PathExpand(ScriptFilename);
    ScriptPath := PathExtractPath(ScriptFilename);
  end
  else begin
    { Read from standard input }
    ScriptFilename := '<stdin>';
    ScriptPath := GetCurrentDir;
  end;

  {$IFNDEF STATICCOMPILER}
  Ver := ISDllGetVersion;
  {$ELSE}
  Ver := ISGetVersion;
  {$ENDIF}
  if Ver.BinVersion < $05000500 then begin
    { 5.0.5 or later is required since we use TCompileScriptParamsEx }
    WriteStdErr('Incompatible compiler engine version.');
    Halt(1);
  end;

  SignTools := TStringList.Create;
  ProgressPoint.X := -1;
  ExitCode := 0;
  try
    if ScriptFilename <> '<stdin>' then
      F := TTextFileReader.Create(ScriptFilename, fdOpenExisting, faRead, fsRead)
    else
      F := TTextFileReader.CreateWithExistingHandle(GetStdHandle(STD_INPUT_HANDLE));
    try
      ReadScriptLines(F);
    finally
      F.Free;
    end;

    if not Quiet then begin
      WriteStdOut('Compiler engine version: ' + String(Ver.Title) + ' ' + String(Ver.Version));
      WriteStdOut('');
    end;

    FillChar(Params, SizeOf(Params), 0);
    Params.Size := SizeOf(Params);
    Params.SourcePath := PChar(ScriptPath);
    Params.CallbackProc := CompilerCallbackProc;
    Options := '';
    if Output <> '' then
      Options := Options + 'Output=' + Output + #0;
    if OutputPath <> '' then
      Options := Options + 'OutputDir=' + OutputPath + #0;
    if OutputFilename <> '' then
      Options := Options + 'OutputBaseFilename=' + OutputFilename + #0;

    ReadSignTools(SignTools);
    for I := 0 to SignTools.Count-1 do
      if (SignTool = '') or (Pos(UpperCase(SignTools.Names[I]) + '=', UpperCase(SignTool)) = 0) then
        Options := Options + AddSignToolParam(SignTools[I]);
    if SignTool <> '' then
      Options := Options + AddSignToolParam(SignTool);

    Params.Options := PChar(Options);

    StartTime := GetTickCount;
    {$IFNDEF STATICCOMPILER}
    Res := ISDllCompileScript(Params);
    {$ELSE}
    Res := ISCompileScript(Params, False);
    {$ENDIF}
    case Res of
      isceNoError: ;
      isceCompileFailure: begin
          ExitCode := 2;
          WriteStdErr('Compile aborted.');
        end;
    else
      ExitCode := 1;
      WriteStdErr(Format('Internal error: ISDllCompileScript returned ' +
        'unexpected result (%d).', [Res]));
    end;
  finally
    SignTools.Free;
    FreeScriptLines;
  end;
  if ExitCode <> 0 then
    Halt(ExitCode);
end;

begin
  StdOutHandle := GetStdHandle(STD_OUTPUT_HANDLE);
  StdErrHandle := GetStdHandle(STD_ERROR_HANDLE);
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
  try
    ProcessCommandLine;
    Go;
  except
    { Show a friendlier exception message. (By default, Delphi prints out
      the exception class and address.) }
    WriteStdErr(GetExceptMessage);
    Halt(2);
  end;
end.
