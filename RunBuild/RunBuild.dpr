program RunBuild;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  System.DateUtils,
  System.IniFiles;

type
  TOptions = record
    AppDir: string;
    ProjectPath: string;
    Config: string;
    Platform: string;
    BdsPath: string;
    TimeoutSeconds: Integer;
    Cleanup: Boolean;
    ShowHelp: Boolean;
  end;

function GetDefaultBdsPath: string;
var
  EnvBds: string;
  Candidate: string;
begin
  EnvBds := GetEnvironmentVariable('BDS');
  if EnvBds <> '' then
  begin
    Candidate := TPath.Combine(TPath.Combine(EnvBds, 'bin'), 'bds.exe');
    if TFile.Exists(Candidate) then
    begin
      Result := Candidate;
      Exit;
    end;
  end;

  Candidate := 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\bds.exe';
  if TFile.Exists(Candidate) then
  begin
    Result := Candidate;
    Exit;
  end;

  Result := '';
end;

function GetProjectsInDirectory(const ADir: string): TArray<string>;
begin
  if TDirectory.Exists(ADir) then
    Result := TDirectory.GetFiles(ADir, '*.dproj')
  else
    SetLength(Result, 0);
end;

procedure LoadIniConfig(const AAppDir: string; var AOpts: TOptions);
var
  IniPath: string;
  IniFile: TIniFile;
begin
  IniPath := TPath.Combine(AAppDir, 'RunBuild.ini');
  if not TFile.Exists(IniPath) then
    IniPath := TPath.Combine(AAppDir, 'BuildBridge.ini');

  if TFile.Exists(IniPath) then
  begin
    IniFile := TIniFile.Create(IniPath);
    try
      AOpts.ProjectPath := IniFile.ReadString('Build', 'Project', AOpts.ProjectPath);
      AOpts.Config := IniFile.ReadString('Build', 'Config', AOpts.Config);
      AOpts.Platform := IniFile.ReadString('Build', 'Platform', AOpts.Platform);
      AOpts.BdsPath := IniFile.ReadString('Build', 'BdsPath', AOpts.BdsPath);
      AOpts.TimeoutSeconds := IniFile.ReadInteger('Build', 'TimeoutSeconds', AOpts.TimeoutSeconds);
      AOpts.Cleanup := IniFile.ReadBool('Build', 'Cleanup', AOpts.Cleanup);
    finally
      IniFile.Free;
    end;
  end;
end;

function ParseCommandLine(out AOpts: TOptions): Boolean;
var
  I, K: Integer;
  Arg: string;
  FoundProjects: TArray<string>;
begin
  AOpts.AppDir := ExtractFilePath(ParamStr(0));
  if AOpts.AppDir = '' then
    AOpts.AppDir := GetCurrentDir;
  AOpts.AppDir := TPath.GetFullPath(AOpts.AppDir);

  AOpts.ProjectPath := '';
  AOpts.Config := 'Debug';
  AOpts.Platform := 'Win32';
  AOpts.BdsPath := '';
  AOpts.TimeoutSeconds := 300;
  AOpts.Cleanup := False;
  AOpts.ShowHelp := False;

  LoadIniConfig(AOpts.AppDir, AOpts);

  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if SameText(Arg, '-h') or SameText(Arg, '--help') or SameText(Arg, '/?') then
    begin
      AOpts.ShowHelp := True;
      Result := True;
      Exit;
    end
    else if SameText(Arg, '-p') or SameText(Arg, '--project') then
    begin
      Inc(I);
      if I <= ParamCount then
        AOpts.ProjectPath := ParamStr(I);
    end
    else if SameText(Arg, '-c') or SameText(Arg, '--config') then
    begin
      Inc(I);
      if I <= ParamCount then
        AOpts.Config := ParamStr(I);
    end
    else if SameText(Arg, '-t') or SameText(Arg, '--platform') then
    begin
      Inc(I);
      if I <= ParamCount then
        AOpts.Platform := ParamStr(I);
    end
    else if SameText(Arg, '-b') or SameText(Arg, '--bds') then
    begin
      Inc(I);
      if I <= ParamCount then
        AOpts.BdsPath := ParamStr(I);
    end
    else if SameText(Arg, '--timeout') then
    begin
      Inc(I);
      if I <= ParamCount then
        AOpts.TimeoutSeconds := StrToIntDef(ParamStr(I), 300);
    end
    else if SameText(Arg, '--cleanup') then
    begin
      AOpts.Cleanup := True;
    end
    else if (AOpts.ProjectPath = '') and (not Arg.StartsWith('-')) and (not Arg.StartsWith('/')) then
    begin
      AOpts.ProjectPath := Arg;
    end;
    Inc(I);
  end;

  if AOpts.ShowHelp then
  begin
    Result := True;
    Exit;
  end;

  if AOpts.ProjectPath = '' then
  begin
    FoundProjects := GetProjectsInDirectory(AOpts.AppDir);
    if Length(FoundProjects) = 1 then
      AOpts.ProjectPath := FoundProjects[0]
    else if Length(FoundProjects) > 1 then
    begin
      Writeln(ErrOutput, 'Error: Multiple .dproj files found in directory: ', AOpts.AppDir);
      for K := 0 to High(FoundProjects) do
        Writeln(ErrOutput, '  - ', ExtractFileName(FoundProjects[K]));
      Writeln(ErrOutput, '');
      Writeln(ErrOutput, 'Please specify which project to build:');
      Writeln(ErrOutput, '  RunBuild.exe <ProjectName.dproj>');
      Writeln(ErrOutput, '  or: RunBuild.exe -p <ProjectName.dproj>');
      Writeln(ErrOutput, 'Or specify the default project in RunBuild.ini:');
      Writeln(ErrOutput, '  [Build]');
      Writeln(ErrOutput, '  Project=' + ExtractFileName(FoundProjects[0]));
      Result := False;
      Exit;
    end
    else
    begin
      Writeln(ErrOutput, 'Error: No .dproj files found in directory: ', AOpts.AppDir);
      Writeln(ErrOutput, 'Please specify project file path: RunBuild.exe -p <path>');
      Result := False;
      Exit;
    end;
  end;

  if (not TPath.IsPathRooted(AOpts.ProjectPath)) then
    AOpts.ProjectPath := TPath.Combine(AOpts.AppDir, AOpts.ProjectPath);

  if (ExtractFileExt(AOpts.ProjectPath) = '') and TFile.Exists(AOpts.ProjectPath + '.dproj') then
    AOpts.ProjectPath := AOpts.ProjectPath + '.dproj';

  AOpts.ProjectPath := TPath.GetFullPath(AOpts.ProjectPath);

  if AOpts.BdsPath = '' then
    AOpts.BdsPath := GetDefaultBdsPath;

  Result := True;
end;

procedure PrintUsage(const AAppDir: string);
begin
  Writeln('Delphi Build Bridge Runner');
  Writeln('Directory: ', AAppDir);
  Writeln('Usage:');
  Writeln('  RunBuild.exe [ProjectName.dproj] [options]');
  Writeln('  (If only 1 .dproj exists in the directory, it is selected automatically)');
  Writeln('');
  Writeln('Options:');
  Writeln('  -p, --project <path>    Delphi project path or filename');
  Writeln('  -c, --config <name>     Build configuration (Debug/Release, default: Debug)');
  Writeln('  -t, --platform <name>   Target platform (Win32/Win64, default: Win32)');
  Writeln('  -b, --bds <path>        Path to bds.exe (optional if IDE is running)');
  Writeln('  --timeout <seconds>     Build timeout in seconds (default: 300)');
  Writeln('  --cleanup               Delete build result JSON and .done file when finished');
  Writeln('  -h, --help              Show this help message');
end;

function GetBridgeBaseDir: string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'delphi_build_bridge');
end;

function IsIDEReady(const ABaseDir: string): Boolean;
var
  Files: TArray<string>;
begin
  if not TDirectory.Exists(ABaseDir) then
  begin
    Result := False;
    Exit;
  end;
  Files := TDirectory.GetFiles(ABaseDir, 'ide_ready_*.flag');
  Result := Length(Files) > 0;
end;

procedure EnsureIDERunning(const ABaseDir, ABdsPath, AProjectPath: string; const ATimeoutSeconds: Integer);
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  Deadline: TDateTime;
begin
  if IsIDEReady(ABaseDir) then
    Exit;

  if (ABdsPath = '') or (not TFile.Exists(ABdsPath)) then
    raise Exception.Create('Delphi IDE is not running and valid bds.exe path was not found.');

  Writeln('Launching Delphi IDE: ', ABdsPath);
  ZeroMemory(@SI, SizeOf(SI));
  SI.cb := SizeOf(SI);
  ZeroMemory(@PI, SizeOf(PI));

  CmdLine := '"' + ABdsPath + '" -pj"' + AProjectPath + '"';
  UniqueString(CmdLine);

  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI) then
    raise Exception.Create('Failed to launch Delphi IDE: ' + SysErrorMessage(GetLastError));

  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);

  Writeln('Waiting for Delphi IDE readiness flag...');
  Deadline := IncSecond(Now, ATimeoutSeconds);
  while Now < Deadline do
  begin
    if IsIDEReady(ABaseDir) then
    begin
      Writeln('Delphi IDE is ready.');
      Exit;
    end;
    Sleep(500);
  end;

  raise Exception.Create('Delphi IDE failed to report readiness within timeout period.');
end;

function GenerateRequestId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := GUIDToString(G);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
end;

procedure SubmitBuildRequest(const ABaseDir, AProjectPath, AConfig, APlatform: string;
  const ATimeoutSeconds: Integer; out ARequestId, AResultPath: string);
var
  QueueDir: string;
  ResultDir: string;
  ReqObj: TJSONObject;
  TmpPath: string;
  FinalPath: string;
begin
  QueueDir := TPath.Combine(ABaseDir, 'queue');
  ResultDir := TPath.Combine(ABaseDir, 'results');
  TDirectory.CreateDirectory(QueueDir);
  TDirectory.CreateDirectory(ResultDir);

  ARequestId := GenerateRequestId;
  AResultPath := TPath.Combine(ResultDir, ARequestId + '.json');

  ReqObj := TJSONObject.Create;
  try
    ReqObj.AddPair('requestId', ARequestId);
    ReqObj.AddPair('projectPath', AProjectPath);
    ReqObj.AddPair('config', AConfig);
    ReqObj.AddPair('platform', APlatform);
    ReqObj.AddPair('outputPath', AResultPath);
    ReqObj.AddPair('timeoutSeconds', TJSONNumber.Create(ATimeoutSeconds));

    TmpPath := TPath.Combine(QueueDir, ARequestId + '.trigger.json.tmp');
    FinalPath := TPath.Combine(QueueDir, ARequestId + '.trigger.json');

    TFile.WriteAllText(TmpPath, ReqObj.ToJSON, TEncoding.UTF8);
    if TFile.Exists(FinalPath) then
      TFile.Delete(FinalPath);
    TFile.Move(TmpPath, FinalPath);
  finally
    ReqObj.Free;
  end;
end;

function WaitForBuildResult(const AResultPath: string; const ATimeoutSeconds: Integer): string;
var
  DonePath: string;
  Deadline: TDateTime;
begin
  DonePath := AResultPath + '.done';
  Deadline := IncSecond(Now, ATimeoutSeconds);
  while Now < Deadline do
  begin
    if TFile.Exists(DonePath) and TFile.Exists(AResultPath) then
    begin
      Result := TFile.ReadAllText(AResultPath, TEncoding.UTF8);
      Exit;
    end;
    Sleep(250);
  end;
  raise Exception.CreateFmt('Build result not received within %d seconds.', [ATimeoutSeconds]);
end;

function PrintResults(const AJsonText: string): Boolean;
var
  Val: TJSONValue;
  Obj: TJSONObject;
  StatusStr: string;
  DurMs: Int64;
  ErrCount, WarnCount: Integer;
  ReasonStr: string;
  MessagesArr: TJSONArray;
  I: Integer;
  MsgVal: TJSONValue;
  MsgObj: TJSONObject;
  SevStr, FileStr, CodeStr, TextStr: string;
  LineNum, ColNum: Integer;
begin
  Result := False;
  Val := TJSONObject.ParseJSONValue(AJsonText);
  if not Assigned(Val) then
  begin
    Writeln(ErrOutput, 'Error: Failed to parse result JSON.');
    Exit;
  end;

  try
    if not (Val is TJSONObject) then
    begin
      Writeln(ErrOutput, 'Error: Unexpected JSON structure.');
      Exit;
    end;

    Obj := TJSONObject(Val);
    StatusStr := Obj.GetValue<string>('status', 'unknown');
    DurMs := Obj.GetValue<Int64>('durationMs', 0);
    ErrCount := Obj.GetValue<Integer>('errorCount', 0);
    WarnCount := Obj.GetValue<Integer>('warningCount', 0);
    ReasonStr := Obj.GetValue<string>('failureReason', '');

    Writeln('');
    Writeln('============================================================');
    Writeln(' Delphi Build Bridge - Compilation Results');
    Writeln('============================================================');
    Writeln('Status:       ', UpperCase(StatusStr));
    Writeln('Duration:     ', DurMs, ' ms');
    Writeln('Errors:       ', ErrCount);
    Writeln('Warnings:     ', WarnCount);
    if ReasonStr <> '' then
      Writeln('Failure:      ', ReasonStr);
    Writeln('------------------------------------------------------------');

    MessagesArr := Obj.GetValue<TJSONArray>('messages', nil);
    if Assigned(MessagesArr) and (MessagesArr.Count > 0) then
    begin
      Writeln('Compiler Messages:');
      for I := 0 to MessagesArr.Count - 1 do
      begin
        MsgVal := MessagesArr.Items[I];
        if MsgVal is TJSONObject then
        begin
          MsgObj := TJSONObject(MsgVal);
          SevStr := MsgObj.GetValue<string>('severity', 'info');
          FileStr := MsgObj.GetValue<string>('file', '');
          LineNum := MsgObj.GetValue<Integer>('line', 0);
          ColNum := MsgObj.GetValue<Integer>('column', 0);
          CodeStr := MsgObj.GetValue<string>('code', '');
          TextStr := MsgObj.GetValue<string>('text', '');

          if FileStr <> '' then
            Write(ExtractFileName(FileStr), '(', LineNum, ',', ColNum, '): ');

          Write('[', UpperCase(SevStr), '] ');
          if CodeStr <> '' then
            Write(CodeStr, ' ');
          Writeln(TextStr);
        end;
      end;
      Writeln('============================================================');
    end
    else
    begin
      Writeln('No compiler messages.');
      Writeln('============================================================');
    end;

    Result := SameText(StatusStr, 'success');
  finally
    Val.Free;
  end;
end;

procedure CleanupFiles(const AResultPath: string);
var
  DonePath: string;
begin
  if AResultPath = '' then
    Exit;
  DonePath := AResultPath + '.done';
  try
    if TFile.Exists(AResultPath) then
      TFile.Delete(AResultPath);
  except
  end;
  try
    if TFile.Exists(DonePath) then
      TFile.Delete(DonePath);
  except
  end;
end;

var
  Opts: TOptions;
  BaseDir: string;
  RequestId: string;
  ResultPath: string;
  JsonContent: string;
  BuildSuccess: Boolean;
begin
  try
    if not ParseCommandLine(Opts) then
    begin
      ExitCode := 2;
      Exit;
    end;

    if Opts.ShowHelp then
    begin
      PrintUsage(Opts.AppDir);
      ExitCode := 0;
      Exit;
    end;

    if not TFile.Exists(Opts.ProjectPath) then
    begin
      Writeln(ErrOutput, 'Error: Project file not found in ', Opts.AppDir);
      Writeln(ErrOutput, 'Path: ', Opts.ProjectPath);
      ExitCode := 2;
      Exit;
    end;

    BaseDir := GetBridgeBaseDir;
    EnsureIDERunning(BaseDir, Opts.BdsPath, Opts.ProjectPath, 60);

    Writeln('Project:  ', ExtractFileName(Opts.ProjectPath));
    Writeln('Folder:   ', ExtractFilePath(Opts.ProjectPath));
    Writeln('Config:   ', Opts.Config, ' | Platform: ', Opts.Platform);

    SubmitBuildRequest(BaseDir, Opts.ProjectPath, Opts.Config, Opts.Platform,
      Opts.TimeoutSeconds, RequestId, ResultPath);

    Writeln('Build in progress (RequestId: ', RequestId, ')...');
    try
      JsonContent := WaitForBuildResult(ResultPath, Opts.TimeoutSeconds);
      BuildSuccess := PrintResults(JsonContent);
      if BuildSuccess then
        ExitCode := 0
      else
        ExitCode := 1;
    finally
      if Opts.Cleanup then
        CleanupFiles(ResultPath);
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'Infrastructure error: ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
