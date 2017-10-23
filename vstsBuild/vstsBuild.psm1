# VSTS task states: Succeeded|SucceededWithIssues|Failed|Cancelled|Skipped
$succeededStateName = 'Succeeded'
$warningStateName = 'SucceededWithIssues'
$errorStateName = 'Failed'

# store the current state used by *-VstsTaskState and Write-VstsMessage
$script:taskstate = $succeededStateName

function Clear-VstsTaskState
{
    $script:taskstate = $succeededStateName
}

function Get-TempFolder
{
    $tempPath = [System.IO.Path]::GetTempPath()
    # Use the agent temp on VSTS which is cleanup between builds (the user temp is not)
    if($env:AGENT_TEMPDIRECTORY)
    {
        $tempPath = $env:AGENT_TEMPDIRECTORY
    }

    $tempFolder = Join-Path -Path $tempPath -ChildPath ([System.IO.Path]::GetRandomFileName())
    if(!(test-path $tempFolder))
    {
        $null = New-Item -Path $tempFolder -ItemType Directory
    }

    return $tempFolder
}

$script:AlternateStagingDirectory = $null
function Get-StagingDirectory
{
    # environment variable are documented here:
    # https://docs.microsoft.com/en-us/vsts/build-release/concepts/definitions/build/variables?tabs=batch
    if($env:BUILD_STAGINGDIRECTORY)
    {
        return $env:BUILD_STAGINGDIRECTORY
    }
    else {
        if(!$script:AlternateStagingDirectory)
        {
            Write-VstsInformation "Cannot find staging directory, logging environment"
            Get-ChildItem env: | ForEach-Object { Write-VstsInformation -message $_}
            $script:AlternateStagingDirectory = Get-TempFolder
        }
        return $script:AlternateStagingDirectory
    }
}

$script:publishedFiles = @()
# Publishes build artifacts 
function Invoke-VstsPublishBuildArtifact
{
    param(
        [parameter(Mandatory)]
        [string]$ArtifactPath,
        [string]$Bucket = 'release'
    )
    $ErrorActionPreference = 'Continue'
    $filter = Join-Path -Path $ArtifactPath -ChildPath '*'
    Write-VstsInformation -message "Publishing artifacts: $filter"

    # In VSTS, publish artifacts appropriately
    $files = Get-ChildItem -Path $filter -Recurse | Select-Object -ExpandProperty FullName
    $destinationPath = Join-Path (Get-StagingDirectory) -ChildPath $Bucket
    if(-not (Test-Path $destinationPath))
    {
        $null = New-Item -Path $destinationPath -ItemType Directory
    }

    foreach($fileName in $files)
    {
        # Only publish files once
        if($script:publishedFiles -inotcontains $fileName)
        {
            $leafFileName = $(Split-path -Path $FileName -Leaf)

            $extension = [System.io.path]::GetExtension($fileName)
            if($extension -ieq '.zip')
            {
                Expand-Archive -Path $fileName -DestinationPath (Join-Path $destinationPath -ChildPath $leafFileName)
            }

            Write-Host "##vso[artifact.upload containerfolder=results;artifactname=$leafFileName]$FileName"
            $script:publishedFiles += $fileName
        }
    }
}

function Write-VstsError {
    param(
        [Parameter(Mandatory=$true)]
        [Object]
        $Error,
        [ValidateSet("error","warning")]
        $Type = 'error'
    )

    $message = [string]::Empty
    $errorType = $Error.GetType().FullName
    $newLine = [System.Environment]::NewLine
    switch($errorType)
    {
        'System.Management.Automation.ErrorRecord'{
            $message = "{0}{2}`t{1}" -f $Error,$Error.ScriptStackTrace,$newLine
        }
        'System.Management.Automation.ParseException'{
            $message = "{0}{2}`t{1}" -f $Error,$Error.StackTrace,$newLine
        }
        'System.Management.Automation.Runspaces.RemotingErrorRecord'
        {
            $message = "{0}{2}`t{1}{2}`tOrigin: {2}" -f $Error,$Error.ScriptStackTrace,$Error.OriginInfo,$newLine
        }
        default
        {
            # Log any unknown error types we get so  we can improve logging.
            log "errorType: $errorType"
            $message =  $Error.ToString()
        }
    }
    $message.Split($newLine) | ForEach-Object {
        Write-VstsMessage -type $Type -message $PSItem
    }
}

# Log messages which potentially change job status
function Write-VstsMessage {
    param(
        [ValidateSet("error","warning")]
        $type = 'error',
        [String]
        $message
    )

    if($script:taskstate -ne $errorStateName -and $type -eq 'error')
    {
        $script:taskstate = $errorStateName
    }
    elseif($script:taskstate -eq $succeededStateName) {
        $script:taskstate = $warningStateName
    }

    # See VSTS documentation at https://github.com/Microsoft/vsts-tasks/blob/master/docs/authoring/commands.md
    # Log task message
    Write-Host "##vso[task.logissue type=$type]$message"
}

# Log informational messages
function Write-VstsInformation {
    param(
        [String]
        $message
    )

    Write-Host $message
}

function Write-VstsTaskState
{
    # See VSTS documentation at https://github.com/Microsoft/vsts-tasks/blob/master/docs/authoring/commands.md
    # Log task state
    Write-Host "##vso[task.complete result=$script:taskstate;]DONE"
}

Export-ModuleMember @(
    'Invoke-VstsPublishBuildArtifact'
    'Write-VstsError'
    'Write-VstsMessage'
    'Clear-VstsTaskState'
    'Write-VstsTaskState'
)