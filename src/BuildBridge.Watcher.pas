unit BuildBridge.Watcher;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.JSON,
  Winapi.Windows,
  BuildBridge.Types,
  BuildBridge.CompileController;

type
  TTriggerWatcher = class(TThread)
  private
    FQueueDir: string;
    FProcessingDir: string;
    FPollIntervalMs: Integer;
    FWakeEvent: TEvent;
    function ParseRequestFile(const AFilePath: string; out ARequest: TBuildRequest): Boolean;
    procedure HandleTriggerFile(const AFilePath: string);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure WakeUp;
  end;

procedure Register;

implementation

var
  GWatcherThread: TTriggerWatcher = nil;
  GReadyFlagPath: string = '';

procedure CreateReadyFlag;
var
  Pid: DWORD;
  BaseDir: string;
begin
  Pid := GetCurrentProcessId;
  BaseDir := GetBridgeBaseDir;
  TDirectory.CreateDirectory(BaseDir);
  GReadyFlagPath := TPath.Combine(BaseDir, 'ide_ready_' + IntToStr(Pid) + '.flag');
  try
    TFile.WriteAllText(GReadyFlagPath, 'PID=' + IntToStr(Pid), TEncoding.UTF8);
    LogInfo('Ready flag created at: ' + GReadyFlagPath);
  except
    on E: Exception do
      LogError('Failed to create ready flag: ' + E.Message);
  end;
end;

procedure RemoveReadyFlag;
begin
  if (GReadyFlagPath <> '') and TFile.Exists(GReadyFlagPath) then
  begin
    try
      TFile.Delete(GReadyFlagPath);
      LogInfo('Ready flag removed');
    except
    end;
  end;
end;

constructor TTriggerWatcher.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWakeEvent := TEvent.Create(nil, False, False, '');
  EnsureBridgeDirectories;
  FQueueDir := GetBridgeQueueDir;
  FProcessingDir := GetBridgeProcessingDir;
  FPollIntervalMs := GetBridgePollIntervalMs;
end;

destructor TTriggerWatcher.Destroy;
begin
  FWakeEvent.Free;
  inherited Destroy;
end;

procedure TTriggerWatcher.WakeUp;
begin
  if Assigned(FWakeEvent) then
    FWakeEvent.SetEvent;
end;

function TTriggerWatcher.ParseRequestFile(const AFilePath: string; out ARequest: TBuildRequest): Boolean;
var
  Content: string;
  JsonVal: TJSONValue;
  JsonObj: TJSONObject;
begin
  Result := False;
  ARequest := Default(TBuildRequest);
  try
    Content := TFile.ReadAllText(AFilePath, TEncoding.UTF8);
    JsonVal := TJSONObject.ParseJSONValue(Content);
    if not Assigned(JsonVal) then
      Exit;
    try
      if not (JsonVal is TJSONObject) then
        Exit;
      JsonObj := TJSONObject(JsonVal);

      ARequest.RequestId := JsonObj.GetValue<string>('requestId', '');
      ARequest.ProjectPath := JsonObj.GetValue<string>('projectPath', '');
      ARequest.Config := JsonObj.GetValue<string>('config', 'Debug');
      ARequest.Platform := JsonObj.GetValue<string>('platform', 'Win32');
      ARequest.OutputPath := JsonObj.GetValue<string>('outputPath', '');
      ARequest.TimeoutSeconds := JsonObj.GetValue<Integer>('timeoutSeconds', 300);

      Result := (ARequest.RequestId <> '') and (ARequest.ProjectPath <> '') and (ARequest.OutputPath <> '');
    finally
      JsonVal.Free;
    end;
  except
    on E: Exception do
    begin
      LogError('Exception parsing request JSON (' + AFilePath + '): ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure TTriggerWatcher.HandleTriggerFile(const AFilePath: string);
var
  FileName, ProcessingPath: string;
  BuildReq: TBuildRequest;
  ParseSuccess: Boolean;
begin
  FileName := ExtractFileName(AFilePath);
  ProcessingPath := TPath.Combine(FProcessingDir, FileName);

  try
    if TFile.Exists(ProcessingPath) then
      TFile.Delete(ProcessingPath);
    TFile.Move(AFilePath, ProcessingPath);
  except
    on E: Exception do
    begin
      LogError('Failed to move file to processing directory: ' + E.Message);
      Exit;
    end;
  end;

  ParseSuccess := ParseRequestFile(ProcessingPath, BuildReq);
  if not ParseSuccess then
  begin
    LogError('Malformed trigger request in ' + FileName);
    try
      if TFile.Exists(ProcessingPath) then
        TFile.Delete(ProcessingPath);
    except
    end;
    Exit;
  end;

  LogInfo('Enqueuing build request: ' + BuildReq.RequestId);
  TThread.Queue(nil,
    procedure
    begin
      try
        CompileController.ProcessBuildRequest(BuildReq);
      finally
        try
          if TFile.Exists(ProcessingPath) then
            TFile.Delete(ProcessingPath);
        except
        end;
      end;
    end);
end;

procedure TTriggerWatcher.Execute;
var
  Files: TArray<string>;
  FilePath: string;
begin
  LogInfo('TriggerWatcher thread started');
  while not Terminated do
  begin
    try
      if TDirectory.Exists(FQueueDir) then
      begin
        Files := TDirectory.GetFiles(FQueueDir, '*.trigger.json');
        for FilePath in Files do
        begin
          if Terminated then
            Break;
          HandleTriggerFile(FilePath);
        end;
      end;
    except
      on E: Exception do
        LogError('Error during queue scan: ' + E.Message);
    end;

    FWakeEvent.WaitFor(FPollIntervalMs);
  end;
  LogInfo('TriggerWatcher thread terminated');
end;

procedure Register;
begin
  LogInfo('Registering DelphiBuildBridge package');
  EnsureBridgeDirectories;

  if not Assigned(GWatcherThread) then
  begin
    GWatcherThread := TTriggerWatcher.Create;
    GWatcherThread.Start;
  end;

  CreateReadyFlag;
  LogInfo('DelphiBuildBridge registered and listening for triggers');
end;

initialization

finalization
  RemoveReadyFlag;

  if Assigned(GWatcherThread) then
  begin
    try
      GWatcherThread.Terminate;
      GWatcherThread.WakeUp;
      GWatcherThread.WaitFor;
      FreeAndNil(GWatcherThread);
    except
    end;
  end;

end.
