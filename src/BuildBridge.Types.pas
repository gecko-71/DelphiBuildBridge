unit BuildBridge.Types;

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.IniFiles,
  System.SyncObjs;

type
  TMessageSeverity = (msError, msWarning, msHint, msInfo);

  TCompileMessage = record
    Severity: TMessageSeverity;
    FileName: string;
    Line: Integer;
    Column: Integer;
    Text: string;
    ErrorCode: string;
  end;

  TBuildStatus = (bsUnknown, bsSuccess, bsFailed, bsTimeout, bsError);

  TBuildRequest = record
    RequestId: string;
    ProjectPath: string;
    Config: string;
    Platform: string;
    OutputPath: string;
    TimeoutSeconds: Integer;
  end;

  TBuildResult = record
    RequestId: string;
    ProjectPath: string;
    Status: TBuildStatus;
    StartedAt: string;
    FinishedAt: string;
    DurationMs: Int64;
    ErrorCount: Integer;
    WarningCount: Integer;
    Messages: TArray<TCompileMessage>;
    FailureReason: string;
  end;

function SeverityToString(ASeverity: TMessageSeverity): string;
function StatusToString(AStatus: TBuildStatus): string;

function GetBridgeBaseDir: string;
function GetBridgeQueueDir: string;
function GetBridgeProcessingDir: string;
function GetBridgeResultDir: string;
function GetBridgeLogPath: string;
function GetBridgePollIntervalMs: Integer;
procedure EnsureBridgeDirectories;

procedure LogInfo(const AMessage: string);
procedure LogWarn(const AMessage: string);
procedure LogError(const AMessage: string);

implementation

var
  GLogLock: TCriticalSection = nil;

function SeverityToString(ASeverity: TMessageSeverity): string;
begin
  case ASeverity of
    msError: Result := 'error';
    msWarning: Result := 'warning';
    msHint: Result := 'hint';
    msInfo: Result := 'info';
  else
    Result := 'info';
  end;
end;

function StatusToString(AStatus: TBuildStatus): string;
begin
  case AStatus of
    bsSuccess: Result := 'success';
    bsFailed: Result := 'failed';
    bsTimeout: Result := 'timeout';
    bsError: Result := 'error';
  else
    Result := 'unknown';
  end;
end;

function GetBridgeBaseDir: string;
var
  IniPath: string;
  IniFile: TIniFile;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'delphi_build_bridge');
  IniPath := TPath.Combine(ExtractFilePath(GetModuleName(HInstance)), 'BuildBridge.ini');
  if TFile.Exists(IniPath) then
  begin
    IniFile := TIniFile.Create(IniPath);
    try
      Result := IniFile.ReadString('Paths', 'BaseDir', Result);
    finally
      IniFile.Free;
    end;
  end;
end;

function GetBridgeQueueDir: string;
begin
  Result := TPath.Combine(GetBridgeBaseDir, 'queue');
end;

function GetBridgeProcessingDir: string;
begin
  Result := TPath.Combine(GetBridgeQueueDir, 'processing');
end;

function GetBridgeResultDir: string;
begin
  Result := TPath.Combine(GetBridgeBaseDir, 'results');
end;

function GetBridgeLogPath: string;
begin
  Result := TPath.Combine(GetBridgeBaseDir, 'BuildBridge.log');
end;

function GetBridgePollIntervalMs: Integer;
var
  IniPath: string;
  IniFile: TIniFile;
begin
  Result := 500;
  IniPath := TPath.Combine(ExtractFilePath(GetModuleName(HInstance)), 'BuildBridge.ini');
  if TFile.Exists(IniPath) then
  begin
    IniFile := TIniFile.Create(IniPath);
    try
      Result := IniFile.ReadInteger('Watcher', 'PollIntervalMs', Result);
    finally
      IniFile.Free;
    end;
  end;
end;

procedure EnsureBridgeDirectories;
begin
  TDirectory.CreateDirectory(GetBridgeBaseDir);
  TDirectory.CreateDirectory(GetBridgeQueueDir);
  TDirectory.CreateDirectory(GetBridgeProcessingDir);
  TDirectory.CreateDirectory(GetBridgeResultDir);
end;

procedure WriteLog(const ALevel, AMessage: string);
var
  LogFile, Line: string;
begin
  if not Assigned(GLogLock) then
    Exit;

  GLogLock.Enter;
  try
    try
      LogFile := GetBridgeLogPath;
      TDirectory.CreateDirectory(ExtractFileDir(LogFile));
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' [' + ALevel + '] ' + AMessage + sLineBreak;
      TFile.AppendAllText(LogFile, Line, TEncoding.UTF8);
    except
    end;
  finally
    GLogLock.Leave;
  end;
end;

procedure LogInfo(const AMessage: string);
begin
  WriteLog('INFO', AMessage);
end;

procedure LogWarn(const AMessage: string);
begin
  WriteLog('WARN', AMessage);
end;

procedure LogError(const AMessage: string);
begin
  WriteLog('ERROR', AMessage);
end;

initialization
  GLogLock := TCriticalSection.Create;

finalization
  if Assigned(GLogLock) then
    FreeAndNil(GLogLock);

end.
