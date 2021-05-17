unit packages;

{$mode objfpc}{$H+}

interface

type
  TPaths = record
    // Search path for units (OtherUnitFiles)
    UnitPath:    String;
    // Search path for includes (IncludeFiles)
    IncludePath: String;
    // Additional sources, not passed to compiler (SrcFiles)
    SrcPath:     String;
  end;

  TPackage = class;

  TDependency = record
    // Name of the package, e.g. 'LCLBase'
    Name: String;

    // Projects may hardcode a path to a package. If a path was hardcoded, Path
    // will contain the expanded path, otherwise will be empty string.
    Path: String;

    // Whether the hardcoded path should take precedence over a global package
    // of the same name. Currently we only use the hardcoded Path if Prefer is
    // true.
    Prefer: Boolean;

    // Once we have resolved the dependency, we cache a reference to the package
    // here:
    Package: TPackage;
  end;

  { TPackage }

  TPackage = class
    // Name of the package / project
    //Name: String;

    // Home directory of the package / project
    Dir: String;

    // Valid: True if the package was found, False otherwise. If False, this
    // is a dummy object whose only purpose is to prevent us from trying to load
    // a non-existing package multiple times.
    Valid: Boolean;

    // The search path resolution process involves several stages:
    // 0. Compile all 1st party search paths defined in the package file and
    //    store them in "Paths".
    // 1. Resolve the dependencies (find file name for a given package name)
    // 2. Compile the search paths for all dependencies and add them to our own
    //    search paths (Resolved Paths)
    // 3. Announce the search paths for the package home directory to
    //    CodeToolBoss.

    DidResolveDependencies: Boolean; // True after step 1 is completed
    DidResolvePaths: Boolean;        // True after step 2 is completed
    Configured: Boolean;             // True after step 3 is completed

    Visited: Boolean; // Temporary flag while guessing dependencies.

    // Expanded (i.e. absolute) 1st-degree search paths for this package
    Paths: TPaths;

    // List of dependencies of this package
    Dependencies: array of TDependency;

    // List of packages requiring this package
    // (only 1st degree dependencies)
    RequiredBy: array of TPackage;

    // Search paths including dependencies
    ResolvedPaths: TPaths;

    constructor Create;
  end;

  // Get package or project information from a file. The file must end in .lpk
  // if it is a package, or .lpi if it is a project.
  // Results are cached. If the file could not be loaded, the Valid member of
  // the result will be set to False.
  function GetPackageOrProject(const FileName: String): TPackage;

  // Get the location of a global package by its name.
  // E.g. 'LCLBase'  -> '/Applications/Lazarus/lcl/lclbase.lpk'
  function LookupGlobalPackage(const Name: String): String;

implementation

uses
  Classes, SysUtils, contnrs, FileUtil, DOM, XMLRead, LazFileUtils, 
  general, udebug;

var
  PkgNameToPath: TFPStringHashTable;
  // Path -> TPackage
  PkgCache: TFPObjectHashTable;

procedure PopulateGlobalPackages;
var
  Files: TStringList;
  FileName, Name: String;
begin
  Files := TStringList.Create;
  try
    FindAllFiles(Files, '/Applications/Lazarus/components', '*.lpk');
    FindAllFiles(Files, '/Applications/Lazarus/lcl', '*.lpk');
    for FileName in Files do
    begin
      Name := ExtractFileNameOnly(FileName);
      PkgNameToPath[UpperCase(Name)] := FileName;
    end;
  finally
    Files.Free;
  end;
end;

procedure LoadPackageOrProject(const FileName: String);
var
  Doc: TXMLDocument;
  Root: TDomNode;
  Package: TPackage;

  function GetAdditionalPaths(SearchPaths: TDomNode; const What: String): String;
  var
    Node: TDomNode;
    Segments: TStringArray;
    S, Segment, AbsSegment: String;
  begin
    Result := '';

    Node := SearchPaths.FindNode(What);
    if Assigned(Node) then
      Node := Node.Attributes.GetNamedItem('Value');
    if not Assigned(Node) then
      Exit;

    S := Node.NodeValue;
    Segments := S.Split([';'], TStringSplitOptions.ExcludeEmpty);

    for Segment in Segments do
    begin
      AbsSegment := CreateAbsolutePath(Segment, Package.Dir);
      Result     := Result + ';' + AbsSegment;
    end;
  end;

  procedure LoadPaths;
  var
    CompilerOptions, SearchPaths: TDomNode;
  begin
    Package.Paths.IncludePath := Package.Dir;
    Package.Paths.UnitPath    := Package.Dir;


    CompilerOptions := Root.FindNode('CompilerOptions');
    if not Assigned(CompilerOptions) then
      Exit;

    SearchPaths := CompilerOptions.FindNode('SearchPaths');
    if not Assigned(SearchPaths) then
      Exit;

    Package.Paths.IncludePath := MergePaths([Package.Paths.IncludePath, GetAdditionalPaths(SearchPaths, 'IncludeFiles')]);
    Package.Paths.UnitPath    := MergePaths([Package.Paths.UnitPath, GetAdditionalPaths(SearchPaths, 'OtherUnitFiles')]);
    Package.Paths.SrcPath     := GetAdditionalPaths(SearchPaths, 'SrcPath');
  end;

  procedure LoadDeps;
  var
    Deps, Item, Name, Path, Prefer: TDomNode;
    Dep: TDependency;
    i, DepCount: integer;
  begin
    if UpperCase(ExtractFileExt(FileName)) = '.LPK' then
      Deps := Root.FindNode('RequiredPkgs')
    else
      Deps := Root.FindNode('RequiredPackages');

    if not Assigned(Deps) then
      Exit;

    DepCount := 0;
    SetLength(Package.Dependencies, Deps.ChildNodes.Count);

    for i := 0 to Deps.ChildNodes.Count - 1 do
    begin
      Item := Deps.ChildNodes.Item[i];

      Name := Item.FindNode('PackageName');
      if not Assigned(Name) then
        continue;

      Name := Name.Attributes.GetNamedItem('Value');
      if not Assigned(Name) then
        continue;

      Dep.Name := Name.NodeValue; 
      Dep.Prefer := False;
      Dep.Package := nil;

      Path := Item.FindNode('DefaultFilename');
      if Assigned(Path) then
      begin
        Prefer := Path.Attributes.GetNamedItem('Prefer');
        Path   := Path.Attributes.GetNamedItem('Value');

        Dep.Prefer := Assigned(Prefer) and (Prefer.NodeValue = 'True');
        if Assigned(Path) then
          Dep.Path := CreateAbsolutePath(Path.NodeValue, Package.Dir);

        DebugLog('HARDCODED DEP %s in %s', [Dep.Name, Dep.Path]);
        DebugLog('  Dir: %s, Rel: %s', [Package.Dir, Path.NodeValue]);
      end;

      Package.Dependencies[DepCount] := Dep;
      Inc(DepCount);
    end;
  end;

begin
  if Assigned(PkgCache[FileName]) then
    Exit;

  Package := TPackage.Create;
  Package.Valid := False;
  Package.Dir := ExtractFilePath(FileName);

  PkgCache[FileName] := Package;

  try
    try
      ReadXMLFile(doc, filename);

      Root := Doc.DocumentElement;
      if Root.NodeName <> 'CONFIG' then
        Exit;

      if UpperCase(ExtractFileExt(FileName)) = '.LPK' then
        Root := Root.FindNode('Package')
      else
        Root := Root.FindNode('ProjectOptions');


      if not Assigned(Root) then
        Exit;

      LoadPaths;
      LoadDeps;

      Package.Valid := True;
    except on E:Exception do
      // swallow
      DebugLog('Error loading %s: %s', [FileName, E.Message]);
    end;
  finally
    if Assigned(doc) then
      FreeAndNil(doc);
  end;
end;

function GetPackageOrProject(const FileName: String): TPackage;
begin
  Result := TPackage(PkgCache[FileName]);
  if not Assigned(Result) then
  begin
    LoadPackageOrProject(FileName);
    Result := TPackage(PkgCache[FileName]);
  end;
end;

function LookupGlobalPackage(const Name: String): String;
begin
  Result := PkgNameToPath[UpperCase(Name)];
end;

{ TPackage }

constructor TPackage.Create;
begin
  Valid      := False;
  Configured := False;
  DidResolvePaths   := False;
  DidResolveDependencies := False;
end;

initialization

PkgNameToPath := TFPStringHashTable.Create;
PkgCache      := TFPObjectHashTable.Create;
PopulateGlobalPackages;


end.

