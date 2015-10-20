########################
# FUNCTIONS
########################
function Install-Dnvm
{
    & where.exe dnvm 2>&1 | Out-Null
    if(($LASTEXITCODE -ne 0) -Or ((Test-Path Env:\APPVEYOR) -eq $true))
    {
        Write-Host "DNVM not found"
        &{$Branch='dev';iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/aspnet/Home/dev/dnvminstall.ps1'))}

        # Normally this happens automatically during install but AppVeyor has
        # an issue where you may need to manually re-run setup from within this process.
        if($env:DNX_HOME -eq $NULL)
        {
            Write-Host "Initial DNVM environment setup failed; running manual setup"
            $tempDnvmPath = Join-Path $env:TEMP "dnvminstall"
            $dnvmSetupCmdPath = Join-Path $tempDnvmPath "dnvm.ps1"
            & $dnvmSetupCmdPath setup
        }
    }
}

function Get-DnxVersion
{
    $globalJson = join-path $PSScriptRoot "global.json"
    $jsonData = Get-Content -Path $globalJson -Raw | ConvertFrom-JSON
    return $jsonData.sdk.version
}

function Restore-Packages
{
    param([string] $DirectoryName)
    & dnu restore ("""" + $DirectoryName + """")
}

function Build-Project
{
    param([string] $DirectoryName)
    & dnu build ("""" + $DirectoryName + """") --configuration Release; if($LASTEXITCODE -ne 0) { exit 1 }
}

function Package-Project
{
    param([string] $DirectoryName)
    & dnu pack ("""" + $DirectoryName + """") --configuration Release --out .\artifacts\packages; if($LASTEXITCODE -ne 0) { exit 1 }
}

function Publish-TestProject
{
    param([string] $DirectoryName, [int]$Index)

    # Publish to a numbered/indexed folder rather than the full test project name
    # because the package paths get long and start exceeding OS limitations.
    & dnu publish ("""" + $DirectoryName + """") --configuration Release --no-source --out .\artifacts\tests\$Index; if($LASTEXITCODE -ne 0) { exit 2 }
}

function Invoke-Tests
{
    Get-ChildItem .\artifacts\tests -Filter test.cmd -Recurse | ForEach-Object { & $_.FullName; if($LASTEXITCODE -ne 0) { exit 3 } }
}

function Remove-PathVariable
{
    param([string] $VariableToRemove)
    $path = [Environment]::GetEnvironmentVariable("PATH", "User")
    $newItems = $path.Split(';') | Where-Object { $_.ToString() -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "User")
    $path = [Environment]::GetEnvironmentVariable("PATH", "Process")
    $newItems = $path.Split(';') | Where-Object { $_.ToString() -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "Process")
}

########################
# THE BUILD!
########################

Push-Location $PSScriptRoot

$dnxVersion = Get-DnxVersion

# Clean
if(Test-Path .\artifacts) { Remove-Item .\artifacts -Force -Recurse }

# Remove the installed DNVM from the path and force use of
# per-user DNVM (which we can upgrade as needed without admin permissions)
Remove-PathVariable "*Program Files\Microsoft DNX\DNVM*"
Install-Dnvm

# Install DNX
dnvm install $dnxVersion -r CoreCLR -NoNative -Unstable
dnvm install $dnxVersion -r CLR -NoNative -Unstable
dnvm use $dnxVersion -r CLR

# Package restore
Get-ChildItem -Path . -Filter *.xproj -Recurse | ForEach-Object { dnu restore ("""" + $_.DirectoryName + """") }

# Set build number
$env:DNX_BUILD_VERSION = @{ $true = $env:APPVEYOR_BUILD_NUMBER; $false = 1}[$env:APPVEYOR_BUILD_NUMBER -ne $NULL];
Write-Host "Build number:" $env:DNX_BUILD_VERSION

# Build/package
Get-ChildItem -Path .\src -Filter *.xproj -Recurse | ForEach-Object { Package-Project $_.DirectoryName }
Get-ChildItem -Path .\samples -Filter *.xproj -Recurse | ForEach-Object { Build-Project $_.DirectoryName }

# Publish tests so we can test without recompiling
Get-ChildItem -Path .\test -Filter *.xproj -Exclude Autofac.Test.Scenarios.ScannedAssembly.xproj -Recurse | ForEach-Object -Begin { $TestIndex = 0 } -Process { Publish-TestProject -DirectoryName $_.DirectoryName -Index $TestIndex; $TestIndex++; }

# Test under CLR
Invoke-Tests

# Switch to Core CLR
dnvm use $dnxVersion -r CoreCLR

# Test under Core CLR
Invoke-Tests

Pop-Location
