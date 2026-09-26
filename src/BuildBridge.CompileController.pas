unit BuildBridge.CompileController;

interface

uses
  Winapi.Windows,
  Vcl.Forms,
  Vcl.Clipbrd,
  Vcl.Menus,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.DateUtils,
  System.Variants,
  System.RegularExpressions,
  System.Generics.Collections,
  System.JSON,
  ToolsAPI,
  BuildBridge.Types;

type
  TCompileController = class
  private
    FRegExWithLine: TRegEx;
    FRegExWithoutLine: TRegEx;
    function FindOrOpenProject(const AServices: IOTAModuleServices; const AProjectPath: string): IOTAProject;
    procedure ConfigureProjectTarget(const AProject: IOTAProject; const AConfig, APlatform: string);
    procedure SetEnvironmentShowProgress(const AValue: Boolean; out AOldValue: Variant; out AOptionName: string);
    procedure RestoreEnvironmentShowProgress(const AOldValue: Variant; const AOptionName: string);
    procedure TriggerViewAction(AForm: TCustomForm; const AMethodName, ACompName: string);
    function CollectMessagesFromView: TArray<TCompileMessage>;
    procedure ParseAndAddRawMessage(const AText: string; var AMessages: TList<TCompileMessage>);
    procedure WriteResultFile(const AOutputPath: string; const AResult: TBuildResult);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ProcessBuildRequest(const ARequest: TBuildRequest);
  end;

function CompileController: TCompileController;

implementation

type
  TNotifyMethod = procedure(Sender: TObject) of object;

var
  GCompileController: TCompileController = nil;

function CompileController: TCompileController;
begin
  if not Assigned(GCompileController) then
    GCompileController := TCompileController.Create;
  Result := GCompileController;
end;

constructor TCompileController.Create;
begin
  inherited Create;
  FRegExWithLine := TRegEx.Create('^\[(.*?)\s+(Error|Warning|Hint|Fatal(?:\s+Error)?)\]\s*(.*?)\((\d+)(?:,\s*(\d+))?\):\s*(?:([EWFH]\d+)\s+)?(.*)$', [roIgnoreCase]);
  FRegExWithoutLine := TRegEx.Create('^\[(.*?)\s+(Error|Warning|Hint|Fatal(?:\s+Error)?)\]\s*(?:([EWFH]\d+)\s+)?(.*)$', [roIgnoreCase]);
end;

destructor TCompileController.Destroy;
begin
  inherited Destroy;
end;

function TCompileController.FindOrOpenProject(const AServices: IOTAModuleServices; const AProjectPath: string): IOTAProject;
var
  I: Integer;
  ModIntf: IOTAModule;
  ProjIntf: IOTAProject;
begin
  Result := nil;

  for I := 0 to AServices.ModuleCount - 1 do
  begin
    ModIntf := AServices.Modules[I];
    if Assigned(ModIntf) and SameText(ModIntf.FileName, AProjectPath) then
    begin
      if Supports(ModIntf, IOTAProject, ProjIntf) then
      begin
        Result := ProjIntf;
        Exit;
      end;
    end;
  end;

  if not TFile.Exists(AProjectPath) then
    raise Exception.Create('Project file not found: ' + AProjectPath);

  ModIntf := AServices.OpenModule(AProjectPath);
  if Assigned(ModIntf) and Supports(ModIntf, IOTAProject, ProjIntf) then
    Result := ProjIntf
  else
    raise Exception.Create('Failed to open project: ' + AProjectPath);
end;

procedure TCompileController.ConfigureProjectTarget(const AProject: IOTAProject; const AConfig, APlatform: string);
begin
  try
    if APlatform <> '' then
      AProject.CurrentPlatform := APlatform;
    if AConfig <> '' then
      AProject.CurrentConfiguration := AConfig;
  except
    on E: Exception do
      LogWarn('Failed to set active build configuration: ' + E.Message);
  end;
end;

procedure TCompileController.SetEnvironmentShowProgress(const AValue: Boolean; out AOldValue: Variant; out AOptionName: string);
var
  Services: IOTAServices;
  EnvOpts: IOTAEnvironmentOptions;
  Names: TOTAOptionNameArray;
  I: Integer;
begin
  AOptionName := '';
  AOldValue := Null;
  if Supports(BorlandIDEServices, IOTAServices, Services) then
  begin
    EnvOpts := Services.GetEnvironmentOptions;
    if Assigned(EnvOpts) then
    begin
      try
        Names := EnvOpts.GetOptionNames;
        for I := Low(Names) to High(Names) do
        begin
          if SameText(Names[I].Name, 'ShowCompilerProgress') or SameText(Names[I].Name, 'Show Compiler Progress') then
          begin
            AOptionName := Names[I].Name;
            Break;
          end;
        end;

        if AOptionName <> '' then
        begin
          AOldValue := EnvOpts.Values[AOptionName];
          EnvOpts.Values[AOptionName] := AValue;
          LogInfo('Temporarily changed ' + AOptionName + ' to ' + BoolToStr(AValue, True));
        end;
      except
        on E: Exception do
          LogWarn('Failed to access environment options: ' + E.Message);
      end;
    end;
  end;
end;

procedure TCompileController.RestoreEnvironmentShowProgress(const AOldValue: Variant; const AOptionName: string);
var
  Services: IOTAServices;
  EnvOpts: IOTAEnvironmentOptions;
begin
  if (AOptionName <> '') and (not VarIsNull(AOldValue)) then
  begin
    if Supports(BorlandIDEServices, IOTAServices, Services) then
    begin
      EnvOpts := Services.GetEnvironmentOptions;
      if Assigned(EnvOpts) then
      begin
        try
          EnvOpts.Values[AOptionName] := AOldValue;
          LogInfo('Restored ' + AOptionName + ' to original value');
        except
          on E: Exception do
            LogWarn('Failed to restore environment options: ' + E.Message);
        end;
      end;
    end;
  end;
end;

procedure TCompileController.TriggerViewAction(AForm: TCustomForm; const AMethodName, ACompName: string);
var
  M: TMethod;
  NotifyProc: TNotifyMethod;
  J: Integer;
  Comp: TComponent;
begin
  M.Data := AForm;
  M.Code := AForm.MethodAddress(AMethodName);
  if Assigned(M.Code) then
  begin
    TMethod(NotifyProc) := M;
    NotifyProc(AForm);
    Exit;
  end;

  for J := 0 to AForm.ComponentCount - 1 do
  begin
    Comp := AForm.Components[J];
    if SameText(Comp.Name, ACompName) or (Pos(UpperCase(ACompName), UpperCase(Comp.Name)) > 0) then
    begin
      if Comp is TMenuItem then
      begin
        TMenuItem(Comp).Click;
        Exit;
      end
      else if Comp is TBasicAction then
      begin
        TBasicAction(Comp).Execute;
        Exit;
      end;
    end;
  end;
end;

procedure TCompileController.ParseAndAddRawMessage(const AText: string; var AMessages: TList<TCompileMessage>);
var
  Match: TMatch;
  Msg: TCompileMessage;
  SevStr: string;
begin
  Match := FRegExWithLine.Match(AText);
  if Match.Success then
  begin
    SevStr := Match.Groups[2].Value.ToLower;
    if (SevStr = 'error') or (SevStr = 'fatal') or (SevStr = 'fatal error') then
      Msg.Severity := msError
    else if SevStr = 'warning' then
      Msg.Severity := msWarning
    else if SevStr = 'hint' then
      Msg.Severity := msHint
    else
      Msg.Severity := msInfo;

    Msg.FileName := Match.Groups[3].Value;
    Msg.Line := StrToIntDef(Match.Groups[4].Value, 0);
    Msg.Column := StrToIntDef(Match.Groups[5].Value, 0);
    Msg.ErrorCode := Match.Groups[6].Value;
    Msg.Text := Match.Groups[7].Value;

    AMessages.Add(Msg);
    Exit;
  end;

  Match := FRegExWithoutLine.Match(AText);
  if Match.Success then
  begin
    SevStr := Match.Groups[2].Value.ToLower;
    if (SevStr = 'error') or (SevStr = 'fatal') or (SevStr = 'fatal error') then
      Msg.Severity := msError
    else if SevStr = 'warning' then
      Msg.Severity := msWarning
    else if SevStr = 'hint' then
      Msg.Severity := msHint
    else
      Msg.Severity := msInfo;

    Msg.FileName := '';
    Msg.Line := 0;
    Msg.Column := 0;
    Msg.ErrorCode := Match.Groups[3].Value;
    Msg.Text := Match.Groups[4].Value;

    AMessages.Add(Msg);
  end;
end;

function TCompileController.CollectMessagesFromView: TArray<TCompileMessage>;
var
  I: Integer;
  Form: TCustomForm;
  OldClipboard, ClipText: string;
  Lines: TArray<string>;
  Line: string;
  MsgList: TList<TCompileMessage>;
begin
  Form := nil;
  for I := 0 to Screen.CustomFormCount - 1 do
  begin
    if SameText(Screen.CustomForms[I].ClassName, 'TMessageViewForm') then
    begin
      Form := Screen.CustomForms[I];
      Break;
    end;
  end;

  if not Assigned(Form) then
  begin
    LogWarn('TMessageViewForm not found in Screen.CustomForms');
    Exit(nil);
  end;

  MsgList := TList<TCompileMessage>.Create;
  try
    OldClipboard := '';
    try
      if Clipboard.HasFormat(CF_TEXT) then
        OldClipboard := Clipboard.AsText;
    except
    end;

    Clipboard.Open;
    try
      Clipboard.Clear;
    finally
      Clipboard.Close;
    end;

    TriggerViewAction(Form, 'EditSelectAllClick', 'SelectAll');
    TriggerViewAction(Form, 'EditCopyItemClick', 'Copy');

    if Clipboard.HasFormat(CF_TEXT) then
    begin
      ClipText := Clipboard.AsText;
      LogInfo('Extracted ' + IntToStr(Length(ClipText)) + ' characters from MessageViewForm clipboard');
      if ClipText <> '' then
      begin
        Lines := ClipText.Split([#13#10, #10, #13]);
        for Line in Lines do
        begin
          if Trim(Line) <> '' then
            ParseAndAddRawMessage(Trim(Line), MsgList);
        end;
      end;
    end
    else
      LogWarn('Clipboard empty after Copy command');

    try
      if OldClipboard <> '' then
        Clipboard.AsText := OldClipboard;
    except
    end;

    Result := MsgList.ToArray;
  finally
    MsgList.Free;
  end;
end;

procedure TCompileController.WriteResultFile(const AOutputPath: string; const AResult: TBuildResult);
var
  RootObj, MsgObj: TJSONObject;
  MsgArr: TJSONArray;
  Msg: TCompileMessage;
  JsonContent: string;
  OutDir, TmpPath, DonePath: string;
begin
  RootObj := TJSONObject.Create;
  try
    RootObj.AddPair('requestId', AResult.RequestId);
    RootObj.AddPair('projectPath', AResult.ProjectPath);
    RootObj.AddPair('status', StatusToString(AResult.Status));
    RootObj.AddPair('startedAt', AResult.StartedAt);
    RootObj.AddPair('finishedAt', AResult.FinishedAt);
    RootObj.AddPair('durationMs', TJSONNumber.Create(AResult.DurationMs));
    RootObj.AddPair('errorCount', TJSONNumber.Create(AResult.ErrorCount));
    RootObj.AddPair('warningCount', TJSONNumber.Create(AResult.WarningCount));
    if AResult.FailureReason <> '' then
      RootObj.AddPair('failureReason', AResult.FailureReason);

    MsgArr := TJSONArray.Create;
    for Msg in AResult.Messages do
    begin
      MsgObj := TJSONObject.Create;
      MsgObj.AddPair('severity', SeverityToString(Msg.Severity));
      MsgObj.AddPair('file', Msg.FileName);
      MsgObj.AddPair('line', TJSONNumber.Create(Msg.Line));
      MsgObj.AddPair('column', TJSONNumber.Create(Msg.Column));
      MsgObj.AddPair('code', Msg.ErrorCode);
      MsgObj.AddPair('text', Msg.Text);
      MsgArr.AddElement(MsgObj);
    end;
    RootObj.AddPair('messages', MsgArr);

    JsonContent := RootObj.Format(2);
  finally
    RootObj.Free;
  end;

  OutDir := ExtractFileDir(AOutputPath);
  if (OutDir <> '') and (not TDirectory.Exists(OutDir)) then
    TDirectory.CreateDirectory(OutDir);

  TmpPath := AOutputPath + '.tmp';
  DonePath := AOutputPath + '.done';

  try
    TFile.WriteAllText(TmpPath, JsonContent, TEncoding.UTF8);
    if TFile.Exists(AOutputPath) then
      TFile.Delete(AOutputPath);
    TFile.Move(TmpPath, AOutputPath);
    TFile.WriteAllText(DonePath, '', TEncoding.UTF8);
    LogInfo('Result successfully written to ' + AOutputPath);
  except
    on E: Exception do
    begin
      LogError('Failed to write result file: ' + E.Message);
      raise;
    end;
  end;
end;

procedure TCompileController.ProcessBuildRequest(const ARequest: TBuildRequest);
var
  ModuleServices: IOTAModuleServices;
  MessageServices: IOTAMessageServices;
  Project: IOTAProject;
  Builder: IOTAProjectBuilder;
  ResultRecord: TBuildResult;
  Stopwatch: TStopwatch;
  BuildSuccess: Boolean;
  OldProgressVal: Variant;
  ProgressOptionName: string;
  FallbackMsg: TCompileMessage;
  Msg: TCompileMessage;
begin
  ResultRecord.RequestId := ARequest.RequestId;
  ResultRecord.ProjectPath := ARequest.ProjectPath;
  ResultRecord.StartedAt := DateToISO8601(Now, False);
  ResultRecord.Status := bsUnknown;
  ResultRecord.FailureReason := '';
  ResultRecord.ErrorCount := 0;
  ResultRecord.WarningCount := 0;
  ResultRecord.Messages := nil;
  
  Stopwatch := TStopwatch.StartNew;
  LogInfo('Starting build for request ' + ARequest.RequestId + ' (' + ARequest.ProjectPath + ')');

  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
      raise Exception.Create('Open Tools API IOTAModuleServices unavailable');

    if Supports(BorlandIDEServices, IOTAMessageServices, MessageServices) then
    begin
      try
        MessageServices.ClearAllMessages;
        LogInfo('Cleared all messages from IDE message buffer');
      except
        on E: Exception do
          LogWarn('Failed to clear messages: ' + E.Message);
      end;
    end;

    Project := FindOrOpenProject(ModuleServices, ARequest.ProjectPath);
    ConfigureProjectTarget(Project, ARequest.Config, ARequest.Platform);

    Builder := Project.ProjectBuilder;
    if not Assigned(Builder) then
      raise Exception.Create('ProjectBuilder interface unavailable for project');

    SetEnvironmentShowProgress(False, OldProgressVal, ProgressOptionName);
    try
      BuildSuccess := Builder.BuildProject(cmOTABuild, False, True);
    finally
      RestoreEnvironmentShowProgress(OldProgressVal, ProgressOptionName);
    end;

    ResultRecord.Messages := CollectMessagesFromView;
    for Msg in ResultRecord.Messages do
    begin
      if Msg.Severity = msError then
        Inc(ResultRecord.ErrorCount)
      else if Msg.Severity = msWarning then
        Inc(ResultRecord.WarningCount);
    end;

    if (not BuildSuccess) and (ResultRecord.ErrorCount = 0) then
    begin
      FallbackMsg.Severity := msError;
      FallbackMsg.FileName := ARequest.ProjectPath;
      FallbackMsg.Line := 0;
      FallbackMsg.Column := 0;
      FallbackMsg.ErrorCode := 'E_BUILD_FAILED';
      FallbackMsg.Text := 'Build failed in Delphi IDE (see IDE Messages window for details)';
      
      SetLength(ResultRecord.Messages, Length(ResultRecord.Messages) + 1);
      ResultRecord.Messages[High(ResultRecord.Messages)] := FallbackMsg;
      Inc(ResultRecord.ErrorCount);
    end;

    if BuildSuccess and (ResultRecord.ErrorCount = 0) then
      ResultRecord.Status := bsSuccess
    else
      ResultRecord.Status := bsFailed;

  except
    on E: Exception do
    begin
      ResultRecord.Status := bsError;
      ResultRecord.FailureReason := E.Message;
      LogError('Build failed with exception: ' + E.Message);
    end;
  end;

  Stopwatch.Stop;
  ResultRecord.DurationMs := Stopwatch.ElapsedMilliseconds;
  ResultRecord.FinishedAt := DateToISO8601(Now, False);

  try
    WriteResultFile(ARequest.OutputPath, ResultRecord);
  except
    on E: Exception do
      LogError('Failed to serialize build result: ' + E.Message);
  end;
end;

initialization

finalization
  if Assigned(GCompileController) then
    FreeAndNil(GCompileController);

end.
