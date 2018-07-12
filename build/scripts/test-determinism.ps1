[CmdletBinding(PositionalBinding=$false)]
param ( [string]$bootstrapDir = "",
        [switch]$debugDeterminism = $false,
        [string]$altRootDrive = "q:")

Set-StrictMode -version 2.0
$ErrorActionPreference = "Stop"

### Variables available to the entire script.

# List of binary names that should be skipped because they have a known issue that
# makes them non-deterministic.  
$script:skipList = @()

# Location that deterministic error information should be written to. 
[string]$script:errorDir = ""
[string]$script:errorDirLeft = ""
[string]$script:errorDirRight = ""

function Run-Build([string]$rootDir, [switch]$restore = $false, [string]$logFile = $null) {
    Push-Location $rootDir
    try {

        # Clean out the previous run
        Write-Host "Cleaning the Binaries"
        Exec-Console $msbuild "/nologo /v:m /nodeReuse:false /t:clean Roslyn.sln" 

        if ($restore) {
            Write-Host "Restoring the packages"
            Restore-Project $dotnet "Roslyn.sln"
        }

        $args = "/nologo /v:m /nodeReuse:false /m /p:DebugDeterminism=true /p:BootstrapBuildPath=$script:bootstrapDir /p:Features=`"debug-determinism`" /p:UseRoslynAnalyzers=false /p:DeployExtension=false Roslyn.sln"
        if ($logFile -ne $null) {
            $logFile = Join-Path $logDir $logFile
            $args += " /bl:$logFile"
        }

        Write-Host "Building the Solution"
        Exec-Console $msbuild $args
    }
    finally {
        Pop-Location
    }
}

function Get-ObjDir([string]$rootDir) { 
    return Join-Path $rootDir "Binaries\Obj"
}

# Return all of the files that need to be processed for determinism under the given
# directory.
function Get-FilesToProcess([string]$rootDir) {
    $objDir = Get-ObjDir $rootDir
    foreach ($item in Get-ChildItem -re -in *.dll,*.exe,*.pdb,*.sourcelink.json $objDir) {
        $fileFullName = $item.FullName 
        $fileName = Split-Path -leaf $fileFullName

        if ($skipList.Contains($fileName)) {
            continue;
        }

        $fileId = $fileFullName.Substring($objDir.Length).Replace("\", ".")
        $fileHash = (Get-FileHash $fileFullName -algorithm MD5).Hash

        $data = @{}
        $data.Hash = $fileHash
        $data.Content = [IO.File]::ReadAllBytes($fileFullName)
        $data.FileId = $fileId
        $data.FileName = $fileName
        $data.FileFullName = $fileFullName
        Write-Output $data
    }
}

# This will build up the map of all of the binaries and their respective hashes.
function Record-Binaries([string]$rootDir) {
    Write-Host "Recording file hashes"

    $map = @{ }
    foreach ($fileData in Get-FilesToProcess $rootDir) { 
        Write-Host "`t$($fileData.FileName) = $($fileData.Hash)"
        $map[$fileData.FileId] = $fileData
    }
    return $map
}

# This is a sanity check to ensure that we're actually putting the right entries into
# the core data map. Essentially to ensure things like if we change our directory layout 
# that this test fails beacuse we didn't record the binaries we intended to record. 
function Test-MapContents($dataMap) { 

    # Sanity check to ensure we didn't return a false positive because we failed
    # to examine any binaries.
    if ($dataMap.Count -lt 40) {
        throw "Didn't find the expected count of binaries"
    }

    # Test for some well known binaries
    $list = @(
        "Microsoft.CodeAnalysis.dll",
        "Microsoft.CodeAnalysis.CSharp.dll",
        "Microsoft.CodeAnalysis.Workspaces.dll",
        "Microsoft.VisualStudio.LanguageServices.Implementation.dll")

    foreach ($fileName in $list) { 
        $found = $false
        foreach ($value in $dataMap.Values) { 
            if ($value.FileName -eq $fileName) { 
                $found = $true
                break;
            }
        }

        if (-not $found) { 
            throw "Did not find the expected binary $fileName"
        }
    }
}

function Test-Build([string]$rootDir, $dataMap, [string]$logFile, [switch]$restore = $false) {
    Run-Build $rootDir -logFile $logFile -restore:$restore

    $errorList = @()
    $allGood = $true

    Write-Host "Testing the binaries"
    foreach ($fileData in Get-FilesToProcess $rootDir) {
        $fileId = $fileData.FileId
        $fileName = $fileData.FileName
        $fileFullName = $fileData.FileFullName

        if (-not $dataMap.Contains($fileId)) {
            Write-Host "ERROR! Missing entry in map $fileId->$fileFullName"
            $allGood = $false
            continue
        }

        $oldfileData = $datamap[$fileId]
        if ($fileData.Hash -ne $oldFileData.Hash) { 
            Write-Host "`tERROR! $fileName contents don't match"
            $allGood = $false
            $errorList += $fileName

            # Save out the original and baseline so Jenkins will archive them for investigation
            [IO.File]::WriteAllBytes((Join-Path $errorDirLeft $fileName), $oldFileData.Content)
            Copy-Item $fileFullName (Join-Path $errorDirRight $fileName)
            continue
        }

        Write-Host "`tVerified $fileName"
    }

    if (-not $allGood) {
        Write-Host "Determinism failed for the following binaries:"
        foreach ($name in $errorList) {
            Write-Host "`t$name"
        }

        Write-Host "Archiving failure information"
        $logDir = Join-Path $repoDir "Binaries\Debug\Logs"
        Create-Directory $logDir
        $zipFile = Join-Path $logDir "determinism.zip"
        Add-Type -Assembly "System.IO.Compression.FileSystem";
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:errorDir, $zipFile, "Fastest", $true);

        Write-Host "Please send $zipFile to compiler team for analysis"
        exit 1
    }
}

function Run-Test() {
    $rootDir = $repoDir

    # Run the initial build so that we can populate the maps
    Run-Build $repoDir -logFile "initial.binlog"
    $dataMap = Record-Binaries $repoDir
    Test-MapContents $dataMap

    # Run a test against the source in the same directory location
    Test-Build -rootDir $repoDir -dataMap $dataMap -logFile "test1.binlog"

    # Run another build in a different source location and verify that path mapping 
    # allows the build to be identical.  To do this we'll copy the entire source 
    # tree under the Binaries\q directory and run a build from there.
    $alt
    Exec-Command "subst" "$altRootDrive $repoDir"
    try {
        $altRootDir = "$($altRootDrive)\"
        Test-Build -rootDir $altRootDir -dataMap $dataMap -logFile "test2.binlog" -restore
    }
    finally {
        Exec-Command "subst" "$altRootDrive /d"
    }
}

try {
    . (Join-Path $PSScriptRoot "build-utils.ps1")

    # Create all of the logging directories
    $configDir = Join-Path $binariesDir "Debug"
    $logDir = Join-Path $configDir "Logs"
    $errorDir = Join-Path $binariesDir "Determinism"
    $errorDirLeft = Join-Path $errorDir "Left"
    $errorDirRight = Join-Path $errorDir "Right"
    Create-Directory $logDir
    Create-Directory $errorDirLeft
    Create-Directory $errorDirRight

    $dotnet = Ensure-DotnetSdk
    $msbuild = Ensure-MSBuild
    if (($bootstrapDir -eq "") -or (-not ([IO.Path]::IsPathRooted($script:bootstrapDir)))) {
        Write-Host "The bootstrap build path must be absolute"
        exit 1
    }

    Run-Test
    exit 0
}
catch {
    Write-Host $_
    Write-Host $_.Exception
    Write-Host $_.ScriptStackTrace
    exit 1
}
finally {
    Write-Host "Stopping VBCSCompiler"
    Get-Process VBCSCompiler -ErrorAction SilentlyContinue | Stop-Process
    Write-Host "Stopped VBCSCompiler"
}

