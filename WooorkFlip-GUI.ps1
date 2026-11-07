
#requires -Version 7.0

# ------------------------------------------------------------
# Workspace Window GUI
# ------------------------------------------------------------

# WPF requires STA.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $pwshPath = (Get-Process -Id $PID).Path
    $arguments = '-NoProfile -STA -File "{0}"' -f $PSCommandPath

    Start-Process -FilePath $pwshPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden

    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

$script:RootPath = $PSScriptRoot
$script:EnginePath = Join-Path $RootPath 'WooorkFlip.ps1'
$script:XamlPath = Join-Path $RootPath 'WooorkFlip.xaml'
$script:WorkspacePath = Join-Path $RootPath 'workspaces'

if (-not (Test-Path -LiteralPath $script:EnginePath)) {
    throw "Engine not found: $script:EnginePath"
}

if (-not (Test-Path -LiteralPath $script:XamlPath)) {
    throw "XAML not found: $script:XamlPath"
}

# ------------------------------------------------------------
# Load XAML
# ------------------------------------------------------------

[xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$script:Window.Add_SourceInitialized({
    $helper = [System.Windows.Interop.WindowInteropHelper]::new(
        $script:Window
    )

    $script:WindowHandle = [long]$helper.Handle.ToInt64()

    Write-Host "[GUI] SourceInitialized"
    Write-Host "[GUI] WindowHandle: 0x$($script:WindowHandle.ToString('X'))"
})

# ------------------------------------------------------------
# Get controls
# ------------------------------------------------------------

$script:WorkspaceList = $script:Window.FindName('WorkspaceList')
$script:WorkspaceName = $script:Window.FindName('WorkspaceName')

$script:SaveButton = $script:Window.FindName('SaveButton')
$script:LoadButton = $script:Window.FindName('LoadButton')
$script:DeleteButton = $script:Window.FindName('DeleteButton')

$script:DetailPanel = $script:Window.FindName('DetailPanel')
$script:DetailName = $script:Window.FindName('DetailName')
$script:DetailCount = $script:Window.FindName('DetailCount')
$script:DetailSaved = $script:Window.FindName('DetailSaved')
$script:OutputBox = $script:Window.FindName('OutputBox')

$script:StatusText = $script:Window.FindName('StatusText')

# ------------------------------------------------------------
# Workspace information
# ------------------------------------------------------------

function Get-WorkspaceInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $filePath = Join-Path $script:WorkspacePath "$Name.json"

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return $null
    }

    try {
        $data = Get-Content -LiteralPath $filePath -Raw |
            ConvertFrom-Json -ErrorAction Stop

        $windowCount = @($data.windows).Count

        $savedAt = '—'

        foreach ($propertyName in @('savedAt', 'saved_at', 'timestamp')) {
            $property = $data.PSObject.Properties[$propertyName]

            if ($null -ne $property -and $property.Value) {
                $savedAt = [string]$property.Value
                break
            }
        }

        return [pscustomobject]@{
            Name        = $Name
            WindowCount = $windowCount
            SavedAt     = $savedAt
            FilePath    = $filePath
        }
    }
    catch {
        Write-Warning "Cannot read workspace '$Name': $_"
        return $null
    }
}

# ------------------------------------------------------------
# Update workspace list
# ------------------------------------------------------------

function Update-WorkspaceList {
    param(
        [string]$SelectName
    )

    $script:WorkspaceList.Items.Clear()

    if (-not (Test-Path -LiteralPath $script:WorkspacePath)) {
        New-Item -ItemType Directory `
            -Path $script:WorkspacePath `
            -Force | Out-Null
    }

    $files = Get-ChildItem `
        -LiteralPath $script:WorkspacePath `
        -Filter '*.json' `
        -File |
        Sort-Object Name

    foreach ($file in $files) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        [void]$script:WorkspaceList.Items.Add($name)
    }

    if ($SelectName -and
        $script:WorkspaceList.Items.Contains($SelectName)) {

        $script:WorkspaceList.SelectedItem = $SelectName
    }
    elseif ($script:WorkspaceList.Items.Count -gt 0) {
        $script:WorkspaceList.SelectedIndex = 0
    }

    Update-WorkspaceDetails
}

# ------------------------------------------------------------
# Update detail panel
# ------------------------------------------------------------

function Update-WorkspaceDetails {

    $name = [string]$script:WorkspaceList.SelectedItem

    if ([string]::IsNullOrWhiteSpace($name)) {
        $script:DetailName.Text = 'No workspace selected'
        $script:DetailCount.Text = 'Windows: —'
        $script:DetailSaved.Text = 'Saved: —'
        return
    }

    $info = Get-WorkspaceInfo -Name $name

    if ($null -eq $info) {
        return
    }

    $script:DetailName.Text = $info.Name
    $script:DetailCount.Text = "Windows: $($info.WindowCount)"
    $script:DetailSaved.Text = "Saved: $($info.SavedAt)"
}

# ------------------------------------------------------------
# Change layout
# ------------------------------------------------------------

function Set-Layout {
    $script:Window.Width = 800
    $script:DetailPanel.Visibility = 'Visible'
}

# ------------------------------------------------------------
# Execute WooorkFlip.ps1
# ------------------------------------------------------------


function Start-WorkspaceEngine {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Save', 'Load', 'Delete')]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [long]$ExcludeHandle
    )

    $stdoutFile = Join-Path $env:TEMP (
        'WooorkFlip-' + [guid]::NewGuid().ToString() + '.out'
    )
    $stderrFile = Join-Path $env:TEMP (
        'WooorkFlip-' + [guid]::NewGuid().ToString() + '.err'
    )

    try {
        $arguments = '-NoProfile -STA -File "{0}" -Action {1} -Name "{2}" -ExcludeHandle {3}' -f `
            $script:EnginePath, $Action, $Name, $ExcludeHandle

        $process = Start-Process `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -ErrorAction Stop

        return [pscustomobject]@{
            Process    = $process
            Action     = $Action
            Name       = $Name
            StdoutFile = $stdoutFile
            StderrFile = $stderrFile
        }
    }
    catch {
        Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Complete-WorkspaceEngine {
    if ($null -eq $script:CurrentOperation) {
        return
    }

    $operation = $script:CurrentOperation

    if (-not $operation.Process.HasExited) {
        return
    }

    $script:OperationTimer.Stop()

    try {
        $output = ''

        if (Test-Path $operation.StdoutFile) {
            $output += Get-Content $operation.StdoutFile -Raw
        }

        if (Test-Path $operation.StderrFile) {
            $errorOutput = Get-Content $operation.StderrFile -Raw
            if ($errorOutput) {
                $output += "`r`n--- Errors ---`r`n$errorOutput"
            }
        }

        $script:OutputBox.Text = $output

        if ($operation.Process.ExitCode -eq 0) {
            $script:StatusText.Text = "$($operation.Action) completed: $($operation.Name)"
            $script:StatusText.Foreground = [System.Windows.Media.Brushes]::Green

            Update-WorkspaceList -SelectName $operation.Name

            # Restore GUI window after Load
            Write-Host "[GUI] Before restore: $($script:Window.WindowState)"
            if ($operation.Action -eq 'Load') {
                $script:Window.WindowState = [System.Windows.WindowState]::Normal
                $script:Window.Show()
                $script:Window.Activate()
            }
            Write-Host "[GUI] After restore: $($script:Window.WindowState)"
        }
        else {
            $script:StatusText.Text = "$($operation.Action) failed: $($operation.Name)"
            $script:StatusText.Foreground = [System.Windows.Media.Brushes]::Red

            [System.Windows.MessageBox]::Show(
                $output,
                "$($operation.Action) failed",
                'OK',
                'Error'
            ) | Out-Null
        }
    }
    finally {
        Remove-Item $operation.StdoutFile, $operation.StderrFile `
            -Force -ErrorAction SilentlyContinue

        $operation.Process.Dispose()
        $script:CurrentOperation = $null

        $script:SaveButton.IsEnabled = $true
        $script:LoadButton.IsEnabled = $true
        $script:DeleteButton.IsEnabled = $true
    }
}

function Start-WorkspaceOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Save', 'Load', 'Delete')]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $script:OutputBox.Text = ''
    $script:ProgressDots = 0

    $script:StatusText.Text = "$Action in progress: $Name"
    $script:StatusText.Foreground = [System.Windows.Media.Brushes]::Orange

    $script:OperationTimer.Start()

    if ($null -ne $script:CurrentOperation) {
        return
    }

    try {
        # Get GUI window handle immediately before engine launch
        $helper = [System.Windows.Interop.WindowInteropHelper]::new(
            $script:Window
        )

        $script:WindowHandle = [long]$helper.Handle.ToInt64()

        Write-Host ""
        Write-Host "========== GUI OPERATION =========="
        Write-Host "[GUI] Action       : $Action"
        Write-Host "[GUI] Name         : $Name"
        Write-Host "[GUI] WindowHandle : 0x$($script:WindowHandle.ToString('X'))"
        Write-Host "[GUI] WindowState  : $($script:Window.WindowState)"
        Write-Host "==================================="

        if ($script:WindowHandle -eq 0) {
            throw "Could not obtain GUI window handle."
        }

        # Start engine
        $script:CurrentOperation = Start-WorkspaceEngine `
            -Action $Action `
            -Name $Name `
            -ExcludeHandle $script:WindowHandle

        $script:SaveButton.IsEnabled = $false
        $script:LoadButton.IsEnabled = $false
        $script:DeleteButton.IsEnabled = $false
        $script:OutputBox.Text = ''

        $script:StatusText.Text = "$Action in progress: $Name"
        $script:StatusText.Foreground = [System.Windows.Media.Brushes]::Orange

        $script:OperationTimer.Start()
    }
    catch {
        $script:CurrentOperation = $null
        $script:SaveButton.IsEnabled = $true
        $script:LoadButton.IsEnabled = $true
        $script:DeleteButton.IsEnabled = $true

        $script:StatusText.Text = "$Action could not be started"

        Write-Host "[GUI] ERROR: $($_.Exception.Message)"

        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Workspace Window',
            'OK',
            'Error'
        ) | Out-Null
    }
}

# ------------------------------------------------------------
# Validate workspace name
# ------------------------------------------------------------

function Test-WorkspaceName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        return $false
    }

    return $true
}

# ------------------------------------------------------------
# Selection changed
# ------------------------------------------------------------

$script:WorkspaceList.Add_SelectionChanged({
    $name = [string]$script:WorkspaceList.SelectedItem

    if ($name) {
        $script:WorkspaceName.Text = $name
    }

    Update-WorkspaceDetails
})


# ------------------------------------------------------------
# Save
# ------------------------------------------------------------

$script:SaveButton.Add_Click({

    $name = $script:WorkspaceName.Text.Trim()

    if (-not (Test-WorkspaceName -Name $name)) {
        [System.Windows.MessageBox]::Show(
            'Enter a valid workspace name.',
            'Workspace Window',
            'OK',
            'Warning'
        ) | Out-Null

        return
    }

    $filePath = Join-Path $script:WorkspacePath "$name.json"

    if (Test-Path -LiteralPath $filePath -PathType Leaf) {

        $answer = [System.Windows.MessageBox]::Show(
            "Overwrite workspace '$name'?",
            'Confirm Save',
            'YesNo',
            'Question'
        )

        if ($answer -ne 'Yes') {
            return
        }
    }

    Start-WorkspaceOperation -Action Save -Name $name
})

# ------------------------------------------------------------
# Load
# ------------------------------------------------------------

$script:LoadButton.Add_Click({

    $name = [string]$script:WorkspaceList.SelectedItem

    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show(
            'Select a workspace first.',
            'Workspace Window',
            'OK',
            'Warning'
        ) | Out-Null

        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Load workspace '$name'?",
        'Confirm Load',
        'YesNo',
        'Question'
    )

    if ($answer -ne 'Yes') {
        return
    }

    $script:StatusText.Text = "Loading '$name'..."
    Start-WorkspaceOperation -Action Load -Name $name
})

# ------------------------------------------------------------
# Delete
# ------------------------------------------------------------

$script:DeleteButton.Add_Click({

    $name = [string]$script:WorkspaceList.SelectedItem

    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show(
            'Select a workspace first.',
            'Workspace Window',
            'OK',
            'Warning'
        ) | Out-Null

        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Delete workspace '$name' permanently?`n`nThis operation cannot be undone.",
        'Confirm Delete',
        'YesNo',
        'Warning'
    )

    if ($answer -ne 'Yes') {
        return
    }

    Start-WorkspaceOperation -Action Delete -Name $name
})

# ------------------------------------------------------------
# Background operation timer
# ------------------------------------------------------------

$script:CurrentOperation = $null

$script:OperationTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:OperationTimer.Interval = [TimeSpan]::FromMilliseconds(300)

$script:OperationTimer.Add_Tick({

    if ($null -ne $script:CurrentOperation) {
        $script:ProgressDots = ($script:ProgressDots % 3) + 1

        $status = "$($script:CurrentOperation.Action) in progress: $($script:CurrentOperation.Name)"

        $script:StatusText.Text = $status + ('.' * $script:ProgressDots)
    }

    Complete-WorkspaceEngine
})

# ------------------------------------------------------------
# Initialize
# ------------------------------------------------------------

Update-WorkspaceList
Set-Layout

$script:StatusText.Text = 'Ready'

# ------------------------------------------------------------
# Show window
# ------------------------------------------------------------

$null = $script:Window.ShowDialog()
