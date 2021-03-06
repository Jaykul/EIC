<#
.SYNOPSIS
    Builds a SharePoint 2010/2013 Service Pack + Cumulative Update slipstreamed installation source.
.DESCRIPTION
    Starting from existing (user-provided) SharePoint 2010/2013 installation media/files (and optionally Office Web Apps media/files),
    the script can download the prerequisites, specified Service Pack and CU/PU packages for SharePoint/OWA, along with specified (optional) language packs, then extract them to a destination path structure.
    Uses the AutoSPSourceBuilder.XML file as the source of product information (URLs, builds, naming, etc.) and requires it to be present in the same folder as the AutoSPSourceBuilder.ps1 script.
.EXAMPLE
    AutoSPSourceBuilder.ps1 -UpdateLocation "C:\Users\brianl\Downloads\SP" -Destination "D:\SP\2010"
.EXAMPLE
    AutoSPSourceBuilder.ps1 -SourceLocation E: -Destination "C:\Source\SP\2010" -CumulativeUpdate "December 2011" -Languages fr-fr,es-es
.PARAMETER SourceLocation
    The location (path, drive letter, etc.) where the SharePoint binary files are located.
    You can specify a UNC path (\\server\share\SP\2010), a drive letter (E:) or a local/mapped folder (Z:\SP\2010).
    If you don't provide a value, the script will check every possible drive letter for a mounted DVD/ISO.
.PARAMETER Destination
    The file path for the final slipstreamed SP2010/SP2013 installation files.
    The default value is $env:SystemDrive\SP\2010 (so in most cases, C:\SP\2010).
.PARAMETER UpdateLocation
    The file path where the downloaded service pack and cumulative update files are located, or where they should be saved in case they need to be downloaded.
    The default value is the subfolder <Destination>\Updates (so, typically C:\SP\201x\Updates).
.PARAMETER GetPrerequisites
    Specifies whether to attempt to download all prerequisite files for the selected product, which can be subsequently used to perform an offline installation.
    The default value is $false.
.PARAMETER CumulativeUpdate
    The name of the cumulative update (CU) you'd like to integrate.
    The format should be e.g. "December 2011".
    If no value is provided, the script will prompt for a valid CU name.
.PARAMETER OWASourceLocation
    The location (path, drive letter, etc.) where the Office Web Apps binary files are located.
    You can specify a UNC path (\\server\share\SP\2010), a drive letter (E:) or a local/mapped folder (Z:\OWA).
    If no value is provided, the script will simply skip the OWA integration altogether.
.PARAMETER Languages
    A comma-separated list of languages (in the culture ID format, e.g. de-de,fr-fr) used to specify which language packs to download.
    If no languages are provided, the script will simply skip language pack integration altogether.
.LINK
    http://autospsourcebuilder.codeplex.com
    http://autospinstaller.codeplex.com
    http://www.toddklindt.com/sp2010builds
.NOTES
    Created by Brian Lalancette (@brianlala), 2012.
#>
param
(
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$SourceLocation,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$Destination = $env:SystemDrive+"\SP\2010",
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$UpdateLocation,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [Bool]$GetPrerequisites = $false,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$CumulativeUpdate,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$OWASourceLocation,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [Array]$Languages
)

#Region Pause Function
# ===================================================================================
# Func: Pause
# Desc: Wait for user to press a key - normally used after an error has occured or input is required
# ===================================================================================
Function Pause($action, $key)
{
    # From http://www.microsoft.com/technet/scriptcenter/resources/pstips/jan08/pstip0118.mspx
    if ($key -eq "any" -or ([string]::IsNullOrEmpty($key)))
    {
        $actionString = "Press any key to $action..."
        Write-Host $actionString
        $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    else
    {
        $actionString = "Enter `"$key`" to $action"
        $continue = Read-Host -Prompt $actionString
        if ($continue -ne $key) {pause $action $key}

    }
}
#EndRegion

# First check if we are running this under an elevated session. Pulled from the script at http://gallery.technet.microsoft.com/scriptcenter/1b5df952-9e10-470f-ad7c-dc2bdc2ac946
If (!([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning " - You must run this script under an elevated PowerShell prompt. Launch an elevated PowerShell prompt by right-clicking the PowerShell shortcut and selecting `"Run as Administrator`"."
    break
}

# Then check if we are running Server 2012 or Windows 8
if (!((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($Languages.Count -gt 0))
{
    Write-Warning "You should be running Windows Server 2012 or Windows 8 (minimum) to get the full functionality of this script."
    Write-Host -ForegroundColor Yellow " - Some features (e.g. image extraction) may not work otherwise."
    Pause "proceed if you are sure this is OK, or Ctrl-C to exit" "y"
}

$oldTitle = $Host.UI.RawUI.WindowTitle
$Host.UI.RawUI.WindowTitle = " -- AutoSPSourceBuilder --"
$0 = $myInvocation.MyCommand.Definition
$dp0 = [System.IO.Path]::GetDirectoryName($0)

Write-Host -ForegroundColor Green " -- AutoSPSourceBuilder SharePoint Update Slipstreaming Utility --"

[xml]$xml = (Get-Content -Path "$dp0\AutoSPSourceBuilder.xml")

#Region Functions
Function WriteLine
{
    Write-Host -ForegroundColor White "--------------------------------------------------------------"
}

Function DownloadPackage ($url, $ExpandedFile, $DestinationFolder, $destinationFile)
{
    $ExpandedFileExists = $false
    $file = $url.Split('/')[-1]
    If (!$destinationFile) {$destinationFile = $file}
    If (!$expandedFile) {$expandedFile = $file}
    Try
    {
        # Check if destination file or its expanded version already exists
        If (Test-Path "$DestinationFolder\$expandedFile") # Check if the expanded file is already there
        {
            Write-Host "  - File $expandedFile exists, skipping download."
            $expandedFileExists = $true
        }
        ElseIf (($file -eq $destinationFile) -and (Test-Path "$DestinationFolder\$file") -and !((Get-Item $file -ErrorAction SilentlyContinue).Mode -eq "d----")) # Check if the packed downloaded file is already there (in case of a CU or Prerequisite)
        {
            Write-Host "  - File $file exists, skipping download."
            If (!($file –like "*.zip"))
            {
                # Give the CU package a .zip extension so we can work with it like a compressed folder
                Rename-Item -Path "$DestinationFolder\$file" -NewName ($file+".zip") -Force -ErrorAction SilentlyContinue
            }
        }
        ElseIf (Test-Path "$DestinationFolder\$destinationFile") # Check if the packed downloaded file is already there (in case of a CU)
        {
            Write-Host "  - File $destinationFile exists, skipping download."
        }
        Else # Go ahead and download the missing package
        {
            # Begin download
            Import-Module BitsTransfer
            $job = Start-BitsTransfer -Asynchronous -Source $url -Destination "$DestinationFolder\$destinationFile" -DisplayName "Downloading `'$file`' to $DestinationFolder\$destinationFile" -Priority Foreground -Description "From $url..." -RetryInterval 60 -RetryTimeout 3600 -ErrorVariable err
            Write-Host "  - Connecting..." -NoNewline
            while ($job.JobState -eq "Connecting")
            {
                Write-Host "." -NoNewline
                Start-Sleep -Milliseconds 500
            }
            Write-Host "."
            If ($err) {Throw ""}
            Write-Host "  - Downloading $file..."
            while ($job.JobState -ne "Transferred")
            {
                $percentDone = "{0:N2}" -f $($job.BytesTransferred / $job.BytesTotal * 100) + "% - $($job.JobState)"
                Write-Host $percentDone -NoNewline
                Start-Sleep -Milliseconds 500
                $backspaceCount = (($percentDone).ToString()).Length
                for ($count = 0; $count -le $backspaceCount; $count++) {Write-Host "`b `b" -NoNewline}
                if ($job.JobState -like "*Error")
                {
                    Write-Host "  - An error occurred downloading $file, retrying..."
                    Resume-BitsTransfer -BitsJob $job -Asynchronous | Out-Null
                }
            }
            Write-Host "  - Completing transfer..."
            Complete-BitsTransfer -BitsJob $job
            Write-Host " - Done!"
        }
    }
    Catch
    {
        Write-Warning " - An error occurred downloading `'$file`'"
        $errorWarning = $true
        break
    }
}

Function Expand-Zip ($InputFile, $DestinationFolder)
{
    $Shell = New-Object -ComObject Shell.Application
    $fileZip = $Shell.Namespace($InputFile)
    $Location = $Shell.Namespace($DestinationFolder)
    $Location.Copyhere($fileZip.items())
}

Function Read-Log()
{
    $log = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | Where-Object {$_.Name -like "opatchinstall*.log"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
    If ($log -eq $null)
    {
        Write-Host `n
        Throw " - Could not find extraction log file!"
    }
    # Get error(s) from log
    $lastError = $log | select-string -SimpleMatch -Pattern "OPatchInstall: The extraction of the files failed" | Select-Object -Last 1
    If ($lastError)
    {
        Write-Host `n
        Write-Warning $lastError.Line
        $errorWarning = $true
        Invoke-Item $log.FullName
        Throw " - Review the log file and try to correct any error conditions."
    }
    Remove-Variable -Name log
}

Function Remove-ReadOnlyAttribute ($Path)
{
    ForEach ($item in (Get-ChildItem -File -Path $Path -Recurse -ErrorAction SilentlyContinue))
    {
        $attributes = @((Get-ItemProperty -Path $item.FullName).Attributes)
        If ($attributes -match "ReadOnly")
        {
            # Set the file to just have the 'Archive' attribute
            Write-Host "  - Removing Read-Only attribute from file: $item"
            Set-ItemProperty -Path $item.FullName -Name Attributes -Value "Archive"
        }
    }
}

# ====================================================================================
# Func: EnsureFolder
# Desc: Checks for the existence and validity of a given path, and attempts to create if it doesn't exist.
# From: Modified from patch 9833 at http://autospinstaller.codeplex.com/SourceControl/list/patches by user timiun
# ====================================================================================
Function EnsureFolder ($Path)
{
        If (!(Test-Path -Path $Path -PathType Container))
        {
            Write-Host -ForegroundColor White " - $Path doesn't exist; creating..."
            Try
            {
                New-Item -Path $Path -ItemType Directory | Out-Null
            }
            Catch
            {
                Write-Warning " - $($_.Exception.Message)"
                Throw " - Could not create folder $Path!"
                $errorWarning = $true
            }
        }
}

#EndRegion

#Region Determine product version and languages requested
if ($SourceLocation)
{
    $sourceDir = $SourceLocation.TrimEnd("\\")
    Write-Host " - Checking for $sourceDir\Setup.exe and $sourceDir\PrerequisiteInstaller.exe..."
    $sourceFound = ((Test-Path -Path "$sourceDir\Setup.exe") -and (Test-Path -Path "$sourceDir\PrerequisiteInstaller.exe"))
}
# Inspired by http://vnucleus.com/2011/08/alphabet-range-sequences-in-powershell-and-a-usage-example/
while (!$sourceFound)
{
    foreach ($driveLetter in 68..90) # Letters from D-Z
    {
        # Check for the SharePoint DVD in all possible drive letters
        $sourceDir = "$([char]$driveLetter):"
        Write-Host " - Checking for $sourceDir\Setup.exe and $sourceDir\PrerequisiteInstaller.exe..."
        $sourceFound = ((Test-Path -Path "$sourceDir\Setup.exe") -and (Test-Path -Path "$sourceDir\PrerequisiteInstaller.exe"))
        If ($sourceFound -or $driveLetter -ge 90) {break}
    }
    break
}
if (!$sourceFound)
{
    Write-Warning " - The correct SharePoint source files/media were not found!"
    Write-Warning " - Please insert/mount the correct media, or specify a valid path."
    $errorWarning = $true
    break
    Pause "exit"
    exit
}
else
{
    Write-Host " - Source found in $sourceDir."
    $spVer,$null = (Get-Item -Path "$sourceDir\setup.exe").VersionInfo.ProductVersion -split "\."
    If (!$sourceDir) {Write-Warning " - Cannot determine version of SharePoint setup binaries."; $errorWarning = $true; break; Pause "exit"; exit}
    # Create a hash table with 'wave' to product year mappings
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spYear = $spYears.$spVer
    Write-Host " - SharePoint $spYear detected."
    If ($spYear -eq "2013")
    {
        $Destination = $Destination -replace "2010","2013"
        $installerVer = (Get-Command "$sourceDir\setup.dll").FileVersionInfo.ProductVersion
        $null,$null,[int]$build,$null = $installerVer -split "\."
        If ($build -ge 4569) # SP2013 SP1
        {
            $sp2013SP1 = $true
            Write-Host "  - Service Pack 1 detected."
        }
    }
    $Destination = $Destination.TrimEnd("\")
    # Ensure the Destination has the year at the end of the path, in case we forgot to type it in when/if prompted
    if (!($Destination -like "*$spYear"))
    {
        $Destination = $Destination+"\"+$spYear
    }
    if ([string]::IsNullOrEmpty($UpdateLocation))
    {
        $UpdateLocation = $Destination+"\Updates"
    }
    if ($Languages.Count -gt 0)
    {
        # Remove any spaces or quotes and ensure each one is split out
        [array]$languages = $Languages -replace ' ','' -split "," ## -replace '"',''
        Write-Host " - Languages requested:"
        foreach ($language in $Languages)
        {
            Write-Host "  - $language"
        }
    }
    else {Write-Host " - No languages requested."}
}
#EndRegion

$spNode = $xml.Products.Product | Where-Object {$_.Name -eq "SP$spYear"}
$owaNode = $xml.Products.Product | Where-Object {$_.Name -eq "OfficeWebApps$spYear"}
# Figure out which CU we want, but only if there are any available
[array]$spCuNodes = $spNode.CumulativeUpdates.ChildNodes | Where-Object {$_.NodeType -ne "Comment"}
if ((!([string]::IsNullOrEmpty($CumulativeUpdate))) -and !($spNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $CumulativeUpdate}))
{
    Write-Warning " - Invalid entry for Cumulative Update: `"$CumulativeUpdate`""
    Remove-Variable -Name CumulativeUpdate
}
While (([string]::IsNullOrEmpty($CumulativeUpdate)) -and (($spCuNodes).Count -ge 1))
{
    Write-Host " - Available Cumulative Updates:"
    foreach ($cuName in $spNode.CumulativeUpdates.CumulativeUpdate.Name | Select-Object -Unique)
    {
        Write-Host "  - "$cuName
    }
    $CumulativeUpdate = Read-Host -Prompt " - Please type the name of an available CU"
}
[array]$spCU = $spNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $CumulativeUpdate}
$spCUName = $spCU[0].Name
$spCUBuild = $spCU[0].Build
[array]$owaCU = $owaNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $spCUName}
if (!([string]::IsNullOrEmpty($owaCU)))
{
    $owaCUName = $owaCU[0].Name
    $owaCUBuild = $owaCU[0].Build
}
if ($spYear -eq "2010") # For SP2010 service packs
{
    # Get the service pack required, based on the sp* value in the CU URL - the URL will refer to the *upcoming* service pack and not the service pack required to apply the CU...
    if ($spCU[0].Url -like "*sp2*" -and $CumulativeUpdate -ne "August 2013" -and $CumulativeUpdate -ne "October 2013") # As we would probably want SP2 if we are installing the June or August 2013 CU for SP2010
    {
        $spServicePack = $spNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq "SP1"}
    }
    elseif ($spCU[0].Url -like "*sp3*" -or $CumulativeUpdate -eq "August 2013" -or $CumulativeUpdate -eq "October 2013") # We probably want SP2 if we are installing the August or October 2013 CU for SP2010
    {
        $spServicePack = $spNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq "SP2"}
    }
}
elseif ($spYear -eq "2013") # For SP2013 service packs
{
    if ($sp2013SP1)
    {
        $spServicePack = $spNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq "SP1"}
    }
}
$owaServicePack = $owaNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq $spServicePack.Name} # To match the chosen SharePoint service pack

#Region SharePoint Source Binaries
if (!($sourceDir -eq "$Destination\SharePoint"))
{
    WriteLine
    Write-Host " - (Robo-)copying files from $sourceDir to $Destination\SharePoint..."
    Start-Process -FilePath robocopy.exe -ArgumentList "`"$sourceDir`" `"$Destination\SharePoint`" /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
    Write-Host " - Done copying original files to $Destination\SharePoint."
    WriteLine
}
#EndRegion

#Region SharePoint Prerequisites
If ($GetPrerequisites)
{
    WriteLine
    $spPrerequisiteNode = $spNode.Prerequisites
    foreach ($prerequisite in $spPrerequisiteNode.Prerequisite)
    {
        Write-Host " - Getting prerequisite `"$($prerequisite.Name)`"..."
        # Because MS added a newer WcfDataServices.exe (yes, with the same filename) to the prerequisites list with SP2013 SP1, we need a special case here to ensure it's downloaded with a different name
        if ($prerequisite.Name -eq "Microsoft WCF Data Services 5.6")
        {
            DownloadPackage -Url $($prerequisite.Url) -ExpandedFile "WcfDataServices56.exe" -DestinationFolder "$Destination\SharePoint\PrerequisiteInstallerFiles" -DestinationFile "WcfDataServices56.exe"
        }
        else
        {
            DownloadPackage -Url $($prerequisite.Url) -DestinationFolder "$Destination\SharePoint\PrerequisiteInstallerFiles"
        }
    }
    WriteLine
}
#EndRegion

#Region Download & slipstream SharePoint Service Pack
If ($spServicePack -and ($spYear -ne "2013")) # Exclude SharePoint 2013 service packs as slipstreaming support has changed
{
    if ($spServicePack.Name -eq "SP1" -and $spYear -eq "2010") {$spMspCount = 40} # Service Pack 1 should have 40 .msp files
    if ($spServicePack.Name -eq "SP2" -and $spYear -eq "2010") {$spMspCount = 47} # Service Pack 2 should have 47 .msp files
    else {$spMspCount = 0}
    WriteLine
    # Check if a SharePoint service pack already appears to be included in the source
    If ((Get-ChildItem "$sourceDir\Updates" -Filter *.msp).Count -lt $spMspCount) # Checking for specific number of MSP patch files in the \Updates folder
    {
        Write-Host " - $($spServicePack.Name) seems to be missing, or incomplete in $sourceDir\; downloading..."
        # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
        $spServicePackSubfolder = $spServicePack.Build+" ("+$spServicePack.Name+")"
        EnsureFolder "$UpdateLocation\$spServicePackSubfolder"
        DownloadPackage -Url $($spServicePack.Url) -DestinationFolder "$UpdateLocation\$spServicePackSubfolder"
        Remove-ReadOnlyAttribute -Path "$Destination\SharePoint\Updates"
        # Extract SharePoint service pack patch files
        Write-Host " - Extracting SharePoint $($spServicePack.Name) patch files..." -NoNewline
        $spServicePackExpandedFile = $($spServicePack.Url).Split('/')[-1]
        Start-Process -FilePath "$UpdateLocation\$spServicePackSubfolder\$spServicePackExpandedFile" -ArgumentList "/extract:`"$Destination\SharePoint\Updates`" /passive" -Wait -NoNewWindow
        Read-Log
        Write-Host "done!"
    }
    Else {Write-Host " - $($spServicePack.Name) appears to be already slipstreamed into the SharePoint binary source location."}

    ## Extract SharePoint w/SP1 files (future functionality?)
    ## Start-Process -FilePath "$UpdateLocation\en_sharepoint_server_2010_with_service_pack_1_x64_759775.exe" -ArgumentList "/extract:$Destination\SharePoint /passive" -NoNewWindow -Wait -NoNewWindow
    WriteLine
}
#EndRegion

#Region Download & slipstream March PU for SharePoint 2013
# Since the March 2013 PU for SharePoint 2013 is considered the baseline build for all patches going forward (prior to SP1), we need to download and extract it if we are looking for a SP2013 CU dated March 2013 or later
If ($spCU -and $spCU[0].Name -ne "December 2012" -and $spYear -eq "2013" -and !$sp2013SP1)
{
    WriteLine
    $march2013PU = $spNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq "March 2013"}
    Write-Host " - Getting SharePoint $spYear baseline update $($march2013PU.Name) PU:"
    $march2013PUFile = $($march2013PU.Url).Split('/')[-1]
    if ($march2013PU.Url -like "*zip.exe")
    {
        $march2013PUFileIsZip = $true
        $march2013PUFile += ".zip"
    }
    # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
    $updateSubfolder = $march2013PU.Build+" ("+$march2013PU.Name+")"
    EnsureFolder "$UpdateLocation\$updateSubfolder"
    DownloadPackage -Url $($march2013PU.Url) -ExpandedFile $($march2013PU.ExpandedFile) -DestinationFolder "$UpdateLocation\$updateSubfolder" -destinationFile $march2013PUFile
    # Expand PU executable to $UpdateLocation\$updateSubfolder
    If (!(Test-Path "$UpdateLocation\$updateSubfolder\$($march2013PU.ExpandedFile)") -and $march2013PUFileIsZip) # Ensure the expanded file isn't already there, and the PU is a zip
    {
        $march2013PUFileZipPath = Join-Path -Path "$UpdateLocation\$updateSubfolder" -ChildPath $march2013PUFile
        Write-Host " - Expanding $($march2013PU.Name) Public Update (single file)..."
        # Remove any pre-existing hotfix.txt file so we aren't prompted to replace it by Expand-Zip and cause our script to pause
        if (Test-Path -Path "$UpdateLocation\$updateSubfolder\hotfix.txt" -ErrorAction SilentlyContinue)
        {
            Remove-Item -Path "$UpdateLocation\$updateSubfolder\hotfix.txt" -Confirm:$false -ErrorAction SilentlyContinue
        }
        Expand-Zip -InputFile $march2013PUFileZipPath -DestinationFolder "$UpdateLocation\$updateSubfolder"
    }
    Remove-ReadOnlyAttribute -Path "$Destination\SharePoint\Updates"
    $march2013PUTempFolder = "$Destination\SharePoint\Updates\March2013PU_TEMP"
    # Remove any existing .xml or .msp files
    foreach ($existingItem in (Get-ChildItem -Path $march2013PUTempFolder -ErrorAction SilentlyContinue))
    {
        $existingItem | Remove-Item -Force -Confirm:$false
    }
    # Extract SharePoint PU files to $march2013PUTempFolder
    Write-Host " - Extracting $($march2013PU.Name) Public Update patch files..." -NoNewline
    Start-Process -FilePath "$UpdateLocation\$updateSubfolder\$($march2013PU.ExpandedFile)" -ArgumentList "/extract:`"$march2013PUTempFolder`" /passive" -Wait -NoNewWindow
    Read-Log
    Write-Host "done!"
    # Now that we have a supported way to slispstream BOTH the March 2013 PU as well as a subsequent CU (per http://blogs.technet.com/b/acasilla/archive/2014/03/09/slipstream-sharepoint-2013-with-march-pu-cu.aspx), let's make it happen.
    Write-Host " - Processing $($march2013PU.Name) Public Update patch files (to allow slipstreaming with a later CU)..." -NoNewline
    # Grab every file except for the eula.txt (or any other text files) and any pre-existing renamed files
    foreach ($item in (Get-ChildItem -Path "$march2013PUTempFolder" | Where-Object {$_.Name -notlike "*.txt" -and $_.Name -notlike "_*SP0"}))
    {
        $prefix,$extension = $item -split "\."
        $newName = "_$prefix-SP0.$extension"
        if (Test-Path -Path "$march2013PUTempFolder\$newName")
        {
            Remove-Item -Path "$march2013PUTempFolder\$newName" -Force -Confirm:$false
        }
        Rename-Item -Path "$($item.FullName)" -NewName $newName -ErrorAction Inquire
    }
    # Move March 2013 PU files up into \Updates folder
    foreach ($item in (Get-ChildItem -Path "$march2013PUTempFolder"))
    {
        $item | Move-Item -Destination "$Destination\SharePoint\Updates" -Force
    }
    Remove-Item -Path $march2013PUTempFolder -Force -Confirm:$false
    Write-Host "done!"    
    WriteLine
}

#EndRegion

#Region Download & slipstream SharePoint CU
If ($spCU)
{
    if ($spServicePack -and ($spCU.Url -like "*`/$($spServicePack.Name)`/*")) # New; only get the CU if its URL doesn't contain the service pack we already have as it will likely be older
    {
        Write-Host " - The $($spCU.Name) appears to be older than the SharePoint $spYear service pack or binaries, skipping."
        # Mark that the CU, although requested, has been skipped for the reason above. Used so that the output .txt file report remains accurate.
        $spCUSkipped = $true
    }
    else
    {
        WriteLine
        foreach ($spCUpackage in $spCU)
        {
            $spCUFile = $($spCUPackage.Url).Split('/')[-1]
            Write-Host " - Getting SharePoint $spYear $($spCUName) CU file ($spCUFile):"
            if ($spCUPackage.Url -like "*zip.exe")
            {
                $spCuFileIsZip = $true
                $spCuFile += ".zip"
            }
            # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
            $updateSubfolder = $spCUBuild+" ("+$spCUName+")"
            EnsureFolder "$UpdateLocation\$updateSubfolder"
            DownloadPackage -Url $($spCUPackage.Url) -ExpandedFile $($spCUPackage.ExpandedFile) -DestinationFolder "$UpdateLocation\$updateSubfolder" -destinationFile $spCuFile
            # Expand CU executable to $UpdateLocation\$updateSubfolder
            If (!(Test-Path "$UpdateLocation\$updateSubfolder\$($spCUPackage.ExpandedFile)") -and $spCuFileIsZip) # Ensure the expanded file isn't already there, and the CU is a zip
            {
                $spCuFileZipPath = Join-Path -Path "$UpdateLocation\$updateSubfolder" -ChildPath $spCuFile
                Write-Host " - Expanding $spCuFile Cumulative Update (single file)..."
                # Remove any pre-existing hotfix.txt file so we aren't prompted to replace it by Expand-Zip and cause our script to pause
                if (Test-Path -Path "$UpdateLocation\$updateSubfolder\hotfix.txt" -ErrorAction SilentlyContinue)
                {
                    Remove-Item -Path "$UpdateLocation\$updateSubfolder\hotfix.txt" -Confirm:$false -ErrorAction SilentlyContinue
                }
                Expand-Zip -InputFile $spCuFileZipPath -DestinationFolder "$UpdateLocation\$updateSubfolder"
            }
            Remove-ReadOnlyAttribute -Path "$Destination\SharePoint\Updates"
            # Extract SharePoint CU files to $Destination\SharePoint\Updates (but only if the source file is an .exe)
            if ($spCUPackage.ExpandedFile -like "*.exe")
            {
                # Assuming this is the the "launcher" package and the only one with an .exe extension. This is to differentiate from the ubersrv*.cab files included recently as part of CUs
                $spCULauncher = $spCUPackage.ExpandedFile
            }
        }
        if ($spCULauncher) # Now that all packages have been downloaded we can call the launcher .exe to extract the CU
        {
            Write-Host -ForegroundColor Cyan " - NOTE: Recent updates can take a VERY long time to extract, be patient!"
            Write-Host " - Extracting $($spCUName) Cumulative Update patch files..." -NoNewline
            Start-Process -FilePath "$UpdateLocation\$updateSubfolder\$spCULauncher" -ArgumentList "/extract:`"$Destination\SharePoint\Updates`" /passive" -Wait -NoNewWindow
            Read-Log
            Write-Host "done!"
        }
        WriteLine
    }
}
#EndRegion

#Region Office Web Apps
if ($OWASourceLocation)
{
    if ($owaServicePack.Name -eq "SP1" -and $spYear -eq "2010") {$owaMspCount = 16}
    if ($owaServicePack.Name -eq "SP2" -and $spYear -eq "2010") {$owaMspCount = 32}
    else {$owaMspCount = 0}
    # Create a hash table with some directories to look for to confirm the valid presence of the OWA binaries. Not perfect.
    $owaTestDirs = @{"2010" = "XLSERVERWAC.en-us"; "2013" = "wacservermui.en-us"}
    ##if ($spYear -eq "2010") {$owaTestDir = "XLSERVERWAC.en-us"}
    ##elseif ($spYear -eq "2013") {$owaTestDir = "wacservermui.en-us"}

    WriteLine
    # Download Office Web Apps?

    # Download Office Web Apps 2013 Prerequisites

    If ($GetPrerequisites -and $spYear -eq "2013")
    {
        WriteLine
        $owaPrerequisiteNode = $owaNode.Prerequisites
        New-Item -ItemType Directory -Name "PrerequisiteInstallerFiles" -Path "$Destination\OfficeWebApps" -ErrorAction SilentlyContinue | Out-Null
        foreach ($prerequisite in $owaPrerequisiteNode.Prerequisite)
        {
            Write-Host " - Getting OWA prerequisite `"$($prerequisite.Name)`"..."
            DownloadPackage -Url $($prerequisite.Url) -DestinationFolder "$Destination\OfficeWebApps\PrerequisiteInstallerFiles"
        }
        WriteLine
    }

    # Extract Office Web Apps files to $Destination\OfficeWebApps

    $sourceDirOWA = $OWASourceLocation
    Write-Host " - Checking for $sourceDirOWA\$($owaTestDirs.$spYear)\..."
    $sourceFoundOWA = (Test-Path -Path "$sourceDirOWA\$($owaTestDirs.$spYear)")
    if (!$sourceFoundOWA)
    {
        Write-Warning " - The correct Office Web Apps source files/media were not found!"
        Write-Warning " - Please specify a valid path."
        $errorWarning = $true
        break
        Pause "exit"
        exit
    }
    else
    {
        Write-Host " - Source found in $sourceDirOWA."
    }
    if (!($sourceDirOWA -eq "$Destination\OfficeWebApps"))
    {
        Write-Host " - (Robo-)copying files from $sourceDirOWA to $Destination\OfficeWebApps..."
        Start-Process -FilePath robocopy.exe -ArgumentList "`"$sourceDirOWA`" `"$Destination\OfficeWebApps`" /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
        Write-Host " - Done copying original files to $Destination\OfficeWebApps."
    }

    if (!([string]::IsNullOrEmpty($owaServicePack.Name)))
    {
        # Check if OWA SP already appears to be included in the source
        if ((Get-ChildItem "$sourceDirOWA\Updates" -Filter *.msp).Count -lt $owaMspCount) # Checking for ($owaMspCount) MSP patch files in the \Updates folder
        {
            Write-Host " - OWA $($owaServicePack.Name) seems to be missing or incomplete in $sourceDirOWA; downloading..."
            # Download Office Web Apps service pack
            Write-Host " - Getting Office Web Apps $($owaServicePack.Name):"
            # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
            $owaServicePackSubfolder = $owaServicePack.Build+" ("+$owaServicePack.Name+")"
            EnsureFolder "$UpdateLocation\$owaServicePackSubfolder"
            DownloadPackage -Url $($owaServicePack.Url) -DestinationFolder "$UpdateLocation\$owaServicePackSubfolder"
            Remove-ReadOnlyAttribute -Path "$Destination\OfficeWebApps\Updates"
            # Extract Office Web Apps service pack files to $Destination\OfficeWebApps\Updates
            Write-Host " - Extracting Office Web Apps $($owaServicePack.Name) patch files..." -NoNewline
            $owaServicePackExpandedFile = $($owaServicePack.Url).Split('/')[-1]
            Start-Process -FilePath "$UpdateLocation\$owaServicePackSubfolder\$owaServicePackExpandedFile" -ArgumentList "/extract:`"$Destination\OfficeWebApps\Updates`" /passive" -Wait -NoNewWindow
            Read-Log
            Write-Host "done!"
        }
        else {Write-Host " - OWA $($owaServicePack.Name) appears to be already slipstreamed into the SharePoint binary source location."}
    }
    else {Write-Host " - No OWA service packs are available or applicable for this version."}
    if (!([string]::IsNullOrEmpty($owaCU))) # Only attempt this if we actually have a CU for OWA that matches the SP revision
    {
        # Download Office Web Apps CU
        foreach ($owaCUPackage in $owaCU)
        {
            Write-Host " - Getting Office Web Apps $($owaCUName) CU:"
            $owaCuFileZip = $($owaCUPackage.Url).Split('/')[-1] +".zip"
            # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
            $owaUpdateSubfolder = $owaCUBuild+" ("+$owaCUName+")"
            EnsureFolder "$UpdateLocation\$owaUpdateSubfolder"
            DownloadPackage -Url $($owaCUPackage.Url) -ExpandedFile $($owaCUPackage.ExpandedFile) -DestinationFolder "$UpdateLocation\$owaUpdateSubfolder" -destinationFile $owaCuFileZip

            # Expand Office Web Apps CU executable to $UpdateLocation\$owaUpdateSubfolder
            If (!(Test-Path "$UpdateLocation\$owaUpdateSubfolder\$($owaCUPackage.ExpandedFile)")) # Check if the expanded file is already there
            {
                $owaCuFileZipPath = Join-Path -Path "$UpdateLocation\$owaUpdateSubfolder" -ChildPath $owaCuFileZip
                Write-Host " - Expanding OWA Cumulative Update (single file)..."
                EnsureFolder "$UpdateLocation\$owaUpdateSubfolder"
                # Remove any pre-existing hotfix.txt file so we aren't prompted to replace it by Expand-Zip and cause our script to pause
                if (Test-Path -Path "$UpdateLocation\$owaUpdateSubfolder\hotfix.txt" -ErrorAction SilentlyContinue)
                {
                    Remove-Item -Path "$UpdateLocation\$owaUpdateSubfolder\hotfix.txt" -Confirm:$false -ErrorAction SilentlyContinue
                }
                Expand-Zip -InputFile $owaCuFileZipPath -DestinationFolder "$UpdateLocation\$owaUpdateSubfolder"
            }

            Remove-ReadOnlyAttribute -Path "$Destination\OfficeWebApps\Updates"
            # Extract Office Web Apps CU files to $Destination\OfficeWebApps\Updates
            Write-Host " - Extracting Office Web Apps Cumulative Update patch files..." -NoNewline
            Start-Process -FilePath "$UpdateLocation\$owaUpdateSubfolder\$($owaCUPackage.ExpandedFile)" -ArgumentList "/extract:`"$Destination\OfficeWebApps\Updates`" /passive" -Wait -NoNewWindow
            Write-Host "done!"
        }
    }
    elseif (!([string]::IsNullOrEmpty($spCU))) {Write-Host " - There is no $($spCUName) CU for Office Web Apps available, skipping."}
    else {Write-Host " - No OWA cumulative updates are available or applicable for this version."}
    WriteLine
}
#EndRegion

#Region Download & slipstream Language Packs
If ($Languages.Count -gt 0)
{
    $lpNode = $spNode.LanguagePacks
    ForEach ($language in $Languages)
    {
        WriteLine
        $spLanguagePack = $lpNode.LanguagePack | Where-Object {$_.Name -eq $language}
        If (!$spLanguagePack)
        {
            Write-Warning " - Language Pack `"$language`" invalid, or not found - skipping."
        }
        if ([string]::IsNullOrEmpty($spLanguagePack.Url))
        {
            Write-Warning " - There is no download URL for Language Pack `"$language`" yet - skipping. You may need to download it manually from MSDN/Technet."
        }
        Else
        {
            [array]$validLanguages += $language
            # Download the language pack
            if ($spver -eq "14")
            {
                $lpDestinationFile = $($spLanguagePack.Url).Split('/')[-1] -replace ".exe","_$language.exe"
            }
            else
            {
                $lpDestinationFile = $($spLanguagePack.Url).Split('/')[-1] -replace ".img","_$language.img"
            }
            Write-Host " - Getting SharePoint $spYear Language Pack ($language):"
            # Set the subfolder name for easy update build & name identification, for example, "15.0.4481.1005 (March 2013)"
            $spLanguagePackSubfolder = $spLanguagePack.Name
            EnsureFolder "$UpdateLocation\$spLanguagePackSubfolder"
            DownloadPackage -Url $($spLanguagePack.Url) -DestinationFolder "$UpdateLocation\$spLanguagePackSubfolder" -DestinationFile $lpDestinationFile
            Remove-ReadOnlyAttribute -Path "$Destination\LanguagePacks\$language"
            # Extract the language pack to $Destination\LanguagePacks\xx-xx (where xx-xx is the culture ID of the language pack, for example fr-fr)
            if ($lpDestinationFile -match ".img$")
            {
                # Mount the ISO/IMG file ($UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile) and robo-copy the files to $Destination\LanguagePacks\$language
                Write-Host " - Mounting language pack disk image..." -NoNewline
                Mount-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile" -StorageType ISO
                $isoDrive = (Get-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile" | Get-Volume).DriveLetter + ":"
                Write-Host "Done."

                # Copy files
                Write-Host " - (Robo-)copying language pack files from $isoDrive to $Destination\LanguagePacks\$language"
                Start-Process -FilePath robocopy.exe -ArgumentList "`"$isoDrive`" `"$Destination\LanguagePacks\$language`" /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
                Write-Host " - Done copying language pack files to $Destination\LanguagePacks\$language."
                # Dismount the ISO/IMG
                Dismount-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile"
            }
            else
            {
                Write-Host " - Extracting Language Pack files ($language)..." -NoNewline
                Start-Process -FilePath "$UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile" -ArgumentList "/extract:`"$Destination\LanguagePacks\$language`" /quiet" -Wait -NoNewWindow
                Write-Host "done!"
            }
            [array]$lpSpNodes = $splanguagePack.ServicePacks.ChildNodes | Where-Object {$_.NodeType -ne "Comment"}
            if (($lpSpNodes).Count -ge 1 -and $spServicePack)
            {
                # Download service pack for the language pack
                $lpServicePack = $spLanguagePack.ServicePacks.ServicePack | Where-Object {$_.Name -eq $spServicePack.Name} # To match the chosen SharePoint service pack
                $lpServicePackDestinationFile = $($lpServicePack.Url).Split('/')[-1]
                Write-Host " - Getting SharePoint $spYear Language Pack $($lpServicePack.Name) ($language):"
                EnsureFolder "$UpdateLocation\$spLanguagePackSubfolder"
                DownloadPackage -Url $($lpServicePack.Url) -DestinationFolder "$UpdateLocation\$spLanguagePackSubfolder" -DestinationFile $lpServicePackDestinationFile
                Remove-ReadOnlyAttribute -Path "$Destination\LanguagePacks\$language\Updates"
                # Extract each language pack to $Destination\LanguagePacks\xx-xx (where xx-xx is the culture ID of the language pack, for example fr-fr)
                if ($lpServicePackDestinationFile -match ".img$")
                {
                    # Mount the ISO/IMG file ($UpdateLocation\$spLanguagePackSubfolder\$lpDestinationFile) and robo-copy the files to $Destination\LanguagePacks\$language
                    Write-Host " - Mounting language pack service pack disk image..." -NoNewline
                    Mount-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpServicePackDestinationFile" -StorageType ISO
                    $isoDrive = (Get-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpServicePackDestinationFile" | Get-Volume).DriveLetter + ":"
                    Write-Host "Done."

                    # Copy files
                    Write-Host " - (Robo-)copying language pack service pack files from $isoDrive to $Destination\LanguagePacks\$language"
                    Start-Process -FilePath robocopy.exe -ArgumentList "`"$isoDrive`" `"$Destination\LanguagePacks\$language`" /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
                    Write-Host " - Done copying language pack service pack files to $Destination\LanguagePacks\$language."
                    # Dismount the ISO/IMG
                    Dismount-DiskImage -ImagePath "$UpdateLocation\$spLanguagePackSubfolder\$lpServicePackDestinationFile"
                }
                else
                {
                    Write-Host " - Extracting Language Pack $($lpServicePack.Name) files ($language)..." -NoNewline
                    Start-Process -FilePath "$UpdateLocation\$spLanguagePackSubfolder\$lpServicePackDestinationFile" -ArgumentList "/extract:`"$Destination\LanguagePacks\$language\Updates`" /quiet" -Wait -NoNewWindow
                    Write-Host "done!"
                }
            }
        }
        If ($spCU -and (Test-Path -Path "$Destination\LanguagePacks\$language\Updates"))
        {
            # Copy matching culture files from $Destination\SharePoint\Updates folder (e.g. spsmui-fr-fr.msp) to $Destination\LanguagePacks\$language\Updates
            Write-Host " - Updating $Destination\LanguagePacks\$language with the $($spCUName) SharePoint CU..."
            ForEach ($patch in (Get-ChildItem -Path $Destination\SharePoint\Updates -Filter *$language*))
            {
                Copy-Item -Path $patch.FullName -Destination "$Destination\LanguagePacks\$language\Updates" -Force
            }
        }
        WriteLine
    }
}
#EndRegion

#Region Create labeled ISO?
#WriteLine
#WriteLine
#EndRegion

#Region Wrap Up
WriteLine
Write-Host " - Adding a label file `"_SLIPSTREAMED.txt`"..."
Set-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "This media source directory has been slipstreamed with:" -Force
Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value `n -Force
Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "- SharePoint $spYear" -Force
If (!([string]::IsNullOrEmpty($spServicePack)))
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $($spServicePack.Name) for SharePoint $spYear" -Force
}
If (!([string]::IsNullOrEmpty($march2013PU)))
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $($march2013PU.Name) Public Update for SharePoint $spYear" -Force
}
If (!([string]::IsNullOrEmpty($spCU)) -and !$spCUSkipped)
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $($spCUName) Cumulative Update for SharePoint $spYear" -Force
}
If ($GetPrerequisites)
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - Prerequisite software for SharePoint $spYear" -Force
}
If ($validLanguages.Count -gt 0) # Add the language packs to the txt file only if they were actually valid
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "- Language Packs:" -Force
    ForEach ($language in $validLanguages)
    {
        Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $language" -Force
    }
}
If (!([string]::IsNullOrEmpty($OWASourceLocation)))
{
    Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "- Office Web Apps $spYear" -Force
    if (!([string]::IsNullOrEmpty($owaPrerequisiteNode)))
    {
        Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - Prerequisite software for Office Web Apps $spYear" -Force
    }
    if (!([string]::IsNullOrEmpty($owaServicePack)))
    {
        Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $($owaServicePack.Name) for Office Web Apps $spYear" -Force
    }
    if (!([string]::IsNullOrEmpty($owaCU)))
    {
        Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value " - $($owaCUName) Cumulative Update for Office Web Apps $spYear" -Force
    }
}
Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value `n -Force
Add-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "Using AutoSPSourceBuilder (http://autospsourcebuilder.codeplex.com)." -Force
If ($errorWarning)
{
    Write-Host -ForegroundColor Yellow " - At least one non-trivial error was encountered."
    Write-Host -ForegroundColor Yellow " - Your SharePoint installation source could therefore be incomplete."
    Write-Host -ForegroundColor Yellow " - You should re-run this script until there are no more errors."
}
Write-Host " - Done!"
Write-Host " - Review the output and check your source location integrity carefully."
Start-Sleep -Seconds 5
Invoke-Item -Path $Destination
WriteLine
Pause "exit"
$Host.UI.RawUI.WindowTitle = $oldTitle
#EndRegion