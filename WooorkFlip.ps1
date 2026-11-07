
[CmdletBinding()]
param(
    [ValidateSet('List', 'Save', 'Load', 'Delete', 'Minimize', 'Restore', 'Maximize', 'Focus')]
    [string]$Action = 'List',
    [string]$Handle,
    [string]$Name,
    [string]$ProcessName,
    [string]$Title,
    [string]$WorkspaceDirectory,
    [int]$ExcludeProcessId = 0,
    [long]$ExcludeHandle = 0
)

# UTF-8 output encoding
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspaceDirectory) {
    $WorkspaceDirectory = Join-Path $PSScriptRoot 'workspaces'
}

# Compile the small Win32 interop layer in memory.
if (-not ('WorkspaceSwitcher.Native' -as [type])) {
    $nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WorkspaceSwitcher
{
    public sealed class WindowInfo
    {
        public long Handle { get; set; }
        public uint ProcessId { get; set; }
        public string Title { get; set; }
        public string ClassName { get; set; }

        // Current window rectangle
        public int X { get; set; }
        public int Y { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }

        // Window state
        public string State { get; set; }

        // Normal (restored) window rectangle
        public int NormalX { get; set; }
        public int NormalY { get; set; }
        public int NormalWidth { get; set; }
        public int NormalHeight { get; set; }
    }

    public static class Native
    {
        private delegate bool EnumWindowsProc(
            IntPtr hWnd,
            IntPtr lParam
        );

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WINDOWPLACEMENT
        {
            public int Length;
            public int Flags;
            public int ShowCmd;
            public POINT MinPosition;
            public POINT MaxPosition;
            public RECT NormalPosition;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(
            EnumWindowsProc callback,
            IntPtr lParam
        );

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(
            IntPtr hWnd,
            StringBuilder text,
            int maxCount
        );

        [DllImport("user32.dll")]
        private static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(
            IntPtr hWnd,
            StringBuilder className,
            int maxCount
        );

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool IsZoomed(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(
            IntPtr hWnd,
            out RECT rect
        );

        [DllImport("user32.dll")]
        private static extern bool GetWindowPlacement(
            IntPtr hWnd,
            ref WINDOWPLACEMENT placement
        );

        [DllImport("user32.dll")]
        private static extern bool SetWindowPlacement(
            IntPtr hWnd,
            ref WINDOWPLACEMENT placement
        );

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(
            IntPtr hWnd,
            int command
        );

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(
            IntPtr hWnd,
            out uint processId
        );

        private static string GetWindowState(IntPtr hWnd)
        {
            if (IsIconic(hWnd))
                return "Minimized";

            if (IsZoomed(hWnd))
                return "Maximized";

            return "Normal";
        }

        public static List<WindowInfo> GetTopLevelWindows()
        {
            var results = new List<WindowInfo>();

            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                    return true;
                int length = GetWindowTextLength(hWnd);
                if (length <= 0)
                    return true;
                var title = new StringBuilder(length + 1);
                GetWindowText(hWnd, title, title.Capacity);
                if (String.IsNullOrWhiteSpace(title.ToString()))
                    return true;
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                var className = new StringBuilder(256);
                GetClassName(hWnd, className, className.Capacity);
                // Current window rectangle
                RECT rect;
                int x = 0, y = 0, width = 0, height = 0;
                if (GetWindowRect(hWnd, out rect))
                {
                    x = rect.Left;
                    y = rect.Top;
                    width = rect.Right - rect.Left;
                    height = rect.Bottom - rect.Top;
                }

                // Window state
                string state = GetWindowState(hWnd);

                // Normal (restored) window rectangle
                int normalX = 0;
                int normalY = 0;
                int normalWidth = 0;
                int normalHeight = 0;

                WINDOWPLACEMENT placement = new WINDOWPLACEMENT();
                placement.Length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));

                if (GetWindowPlacement(hWnd, ref placement))
                {
                    RECT normal = placement.NormalPosition;
                    normalX = x;
                    normalY = y;
                    normalWidth = width;
                    normalHeight = height;
                }

                results.Add(new WindowInfo
                {
                    Handle = hWnd.ToInt64(),
                    ProcessId = pid,
                    Title = title.ToString(),
                    ClassName = className.ToString(),

                    X = x,
                    Y = y,
                    Width = width,
                    Height = height,

                    State = state,

                    NormalX = normalX,
                    NormalY = normalY,
                    NormalWidth = normalWidth,
                    NormalHeight = normalHeight
                });

                return true;
            }, IntPtr.Zero);

            return results;
        }

        public static bool ApplyWindowPlacement(
            long handle,
            string state,
            int x,
            int y,
            int width,
            int height)
        {
            IntPtr hWnd = new IntPtr(handle);

            if (!IsWindow(hWnd)) return false;
            if (width <= 0 || height <= 0) return false;

            string targetState = (state ?? "Normal").ToLowerInvariant();

            int showCommand;
            switch (targetState)
            {
                case "minimized":
                    showCommand = 2; // SW_SHOWMINIMIZED
                    break;
                case "maximized":
                    showCommand = 3; // SW_SHOWMAXIMIZED
                    break;
                default:
                    showCommand = 1; // SW_SHOWNORMAL
                    break;
            }

            WINDOWPLACEMENT placement = new WINDOWPLACEMENT();
            placement.Length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            placement.Flags = 0;
            placement.ShowCmd = showCommand;
            placement.NormalPosition = new RECT
            {
                Left = x,
                Top = y,
                Right = x + width,
                Bottom = y + height
            };

            if (!SetWindowPlacement(hWnd, ref placement))
                return false;

            // Explicitly restore the window's visibility and state.
            ShowWindow(hWnd, showCommand);

            if (!IsWindow(hWnd))
                return false;

            if (targetState != "minimized" && !IsWindowVisible(hWnd))
                return false;

            return true;
        }
        // ShowWindow's return value reports the previous visibility state,
        // not success. IsWindow is checked first.
        public static bool ChangeWindowState(
            long handle,
            int command,
            bool bringToFront
        )
        {
            IntPtr hWnd = new IntPtr(handle);

            if (!IsWindow(hWnd))
                return false;

            ShowWindow(hWnd, command);

            if (bringToFront)
                SetForegroundWindow(hWnd);

            return true;
        }
    }
}
'@

    Add-Type -TypeDefinition $nativeSource -Language CSharp
}

function ConvertFrom-WindowHandle {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $normalized = $Value.Trim()

    if ($normalized.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(2)
    }

    try {return [Convert]::ToInt64($normalized, 16)}
    catch {throw "Invalid window handle '$Value'. Use the hexadecimal handle shown by List, for example 0x0000000000123456."}
}

# ------------------------------------------------------------
# Start application
# ------------------------------------------------------------

function Start-WorkspaceApplication {
    param(
        [Parameter(Mandatory)]
        [string]$ProcessPath,

        [string]$LaunchFile
    )

    # Windows Terminal special handling
    if ($ProcessPath -match 'WindowsTerminal\.exe$') {
        # Avoid starting Windows Terminal repeatedly
        $running = Get-Process -Name WindowsTerminal `
            -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host "Windows Terminal is already running."
            return $true
        }
        try {
            Start-Process `
                -FilePath "$env:WINDIR\explorer.exe" `
                -ArgumentList 'shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'
            Write-Host "Started Windows Terminal."
            return $true
        }
        catch {
            Write-Warning "Failed to start Windows Terminal: $_"
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $ProcessPath -PathType Leaf)) {
        Write-Warning "Application not found: $ProcessPath"
        return $false
    }

    # Open a specific file when launchFile is specified.
    if (-not [string]::IsNullOrWhiteSpace($LaunchFile)) {
        if (-not (Test-Path -LiteralPath $LaunchFile -PathType Leaf)) {
            Write-Warning "Launch file not found: $LaunchFile"
            return $false
        }

        $quotedFile = '"' + $LaunchFile + '"'

        Start-Process `
            -FilePath $ProcessPath `
            -ArgumentList $quotedFile

        Write-Host "Started with file: $LaunchFile"
        return $true
    }

    # Start application.
    Start-Process -FilePath $ProcessPath

    Write-Host "Started application: $ProcessPath"
    return $true
}

# ------------------------------------------------------------
# List
# ------------------------------------------------------------

if ($Action -in @('List', 'Save')) {
    $windows = [WorkspaceSwitcher.Native]::GetTopLevelWindows()

    # Filter Save targets
    if ($Action -eq 'Save') {

        # System processes that should not be saved
        $excludedProcesses = @(
            'SystemSettings'
            'ApplicationFrameHost'
            'Microsoft.CmdPal.UI'
            'TextInputHost'
            'NVIDIA Overlay'
        )

        $windows = @(
            $windows | Where-Object {

                # Exclude WooorkFlip GUI
                if ([long]$_.Handle -eq $ExcludeHandle) {
                    return $false
                }

                # Exclude minimized windows
                if ($_.State -eq 'Minimized') {
                    return $false
                }

                # Exclude desktop window
                if ($_.ClassName -in @('Progman', 'WorkerW')) {
                    return $false
                }

                # Get owning process name
                try {
                    $processName = (
                        Get-Process -Id $_.ProcessId -ErrorAction Stop
                    ).ProcessName
                }
                catch {
                    return $false
                }

                # Exclude system processes
                if ($processName -in $excludedProcesses) {
                    return $false
                }

                return $true
            }
        )

        Write-Host "[SAVE] Excluded GUI, minimized and system windows."
        Write-Host "[SAVE] Windows to save: $($windows.Count)"
    }

    $items = foreach ($window in $windows) {
        $procName = '(unknown)'
        $procPath = $null

        try {
            $process = Get-Process -Id $window.ProcessId -ErrorAction Stop
            $procName = $process.ProcessName
            try {
                $procPath = $process.Path
            }
            catch {
                # Path may be unavailable due to access restrictions.
            }
        }
        catch {
            # The process may have exited.
        }

        # Apply search filters only to List
        if ($Action -eq 'List') {

            if ($ProcessName -and $procName -notlike "*$ProcessName*") {
                continue
            }

            if ($Title -and $window.Title -notlike "*$Title*") {
                continue
            }
        }

        [pscustomobject]@{
            Handle       = ('0x{0:X16}' -f $window.Handle)
            Process      = $procName
            ProcessPath  = $procPath
            PID          = $window.ProcessId
            Title        = $window.Title
            Class        = $window.ClassName
            State        = $window.State
            NormalX      = $window.NormalX
            NormalY      = $window.NormalY
            NormalWidth  = $window.NormalWidth
            NormalHeight = $window.NormalHeight
        }
    }

    # ------------------------------------------------------------
    # Save workspace
    # ------------------------------------------------------------

    if ($Action -eq 'Save') {

        if (-not $Name) {
            throw "The -Name parameter is required. Example: -Action Save -Name Keyboard"
        }

        if ($Name -notmatch '^[\w.-]+$') {
            throw "Invalid workspace name. Use letters, numbers, Japanese characters, underscores, hyphens or dots."
        }

        if (-not $items) {
            Write-Host ""
            Write-Host "[DEBUG] Save filter results"
            Write-Host "Windows count : $(@($windows).Count)"
            Write-Host "Items count   : $(@($items).Count)"
            Write-Host "ProcessName   : '$ProcessName'"
            Write-Host "Title         : '$Title'"

            $items | Format-Table Process, Title, State -AutoSize
            throw "No windows matched the specified filters."
        }

        # Create storage directory if necessary
        if (-not (Test-Path $WorkspaceDirectory)) {
            New-Item -ItemType Directory -Path $WorkspaceDirectory -Force |
                Out-Null
        }

        $workspacePath = Join-Path $WorkspaceDirectory "$Name.json"

        # ------------------------------------------------------------
        # Get open Office documents
        # ------------------------------------------------------------

        if (-not ([System.Management.Automation.PSTypeName]'OfficeRotHelper').Type) {
            Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;

        public static class OfficeRotHelper
        {
            [DllImport("oleaut32.dll", PreserveSig = true)]
            private static extern int GetActiveObject(
                ref Guid rclsid,
                IntPtr reserved,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppunk
            );

            public static object GetObject(string progId)
            {
                Type type = Type.GetTypeFromProgID(progId);

                if (type == null)
                    return null;

                Guid clsid = type.GUID;
                object obj;

                int hr = GetActiveObject(ref clsid, IntPtr.Zero, out obj);

                if (hr < 0)
                    Marshal.ThrowExceptionForHR(hr);

                return obj;
            }
        }
'@
}

        $officeApps = @{
            POWERPNT = $null
            EXCEL    = $null
            WINWORD  = $null
        }

        $officeProgIds = @{
            POWERPNT = 'PowerPoint.Application'
            EXCEL    = 'Excel.Application'
            WINWORD  = 'Word.Application'
        }
        Write-Host "Office connection loop: $(Get-Date -Format 'HH:mm:ss.fff')"
        foreach ($processName in $officeProgIds.Keys) {
            try {
                $officeApps[$processName] = [OfficeRotHelper]::GetObject(
                    $officeProgIds[$processName]
                )

                if ($officeApps[$processName]) {
                    # Write-Host "Connected to $processName."
                }
                else {
                    # Write-Host "$processName is not running."
                }
            }
            catch {
                # Write-Host "Not running: $processName"
            }
        }
        $savedWindows = @(
            foreach ($windowItem in $items) {

                $launchFile = $null
                $documents = $null

                switch ($windowItem.Process) {
                    'POWERPNT' {
                        if ($officeApps.POWERPNT) {
                            $documents = $officeApps.POWERPNT.Presentations
                        }
                    }
                    'EXCEL' {
                        if ($officeApps.EXCEL) {
                            $documents = $officeApps.EXCEL.Workbooks
                        }
                    }
                    'WINWORD' {
                        if ($officeApps.WINWORD) {
                            $documents = $officeApps.WINWORD.Documents
                        }
                    }
                }
                if ($documents) {
                    foreach ($document in $documents) {
                        try {
                            # Ignore unsaved Office documents.
                            if (-not $document.Path) {
                                continue
                            }
                            $fileName = [IO.Path]::GetFileName(
                                $document.FullName
                            )

                            if (
                                $windowItem.Title.IndexOf(
                                    $fileName,
                                    [StringComparison]::OrdinalIgnoreCase
                                ) -ge 0
                            ) {
                                $launchFile = $document.FullName
                                break
                            }
                        }
                        catch {
                            # Unsaved documents may not have a valid FullName.
                        }
                    }
                }

                [ordered]@{
                    process      = $windowItem.Process
                    processPath  = $windowItem.ProcessPath
                    handle       = $windowItem.Handle
                    launchFile   = $launchFile
                    title        = $windowItem.Title
                    class        = $windowItem.Class
                    state        = $windowItem.State

                    normalX      = $windowItem.NormalX
                    normalY      = $windowItem.NormalY
                    normalWidth  = $windowItem.NormalWidth
                    normalHeight = $windowItem.NormalHeight
                }
            }
        )
        $workspace = [ordered]@{
            schemaVersion = 1
            name          = $Name
            savedAt       = (Get-Date).ToString('o')
            windows       = $savedWindows
        }

        $json = ConvertTo-Json -InputObject $workspace -Depth 6

        Set-Content `
            -LiteralPath $workspacePath `
            -Value $json `
            -Encoding utf8

        Write-Host "Workspace '$Name' saved successfully."
        Write-Host "Windows : $($savedWindows.Count)"
        Write-Host "File    : $workspacePath"

        return
    }

    $items | Sort-Object Process, Title | Format-Table -AutoSize
    return
}

# ------------------------------------------------------------
# Load workspace
# ------------------------------------------------------------

if ($Action -eq 'Load') {

    if (-not $Name) {
        throw "The -Name parameter is required. Example: -Action Load -Name Keyboard"
    }

    if ($Name -notmatch '^[\w.-]+$') {
        throw "Invalid workspace name."
    }

    $workspacePath = Join-Path $WorkspaceDirectory "$Name.json"

    if (-not (Test-Path -LiteralPath $workspacePath)) {
        throw "Workspace '$Name' was not found: $workspacePath"
    }

    $workspace = Get-Content `
        -LiteralPath $workspacePath `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json

    # Exclude minimized windows from saved workspace
    $workspace.windows = @(
        $workspace.windows | Where-Object {
            $_.state -ne 'Minimized'
        }
    )

    if ($workspace.schemaVersion -ne 1) {
        throw "Unsupported workspace schema version: $($workspace.schemaVersion)"
    }

    Write-Host ""
    Write-Host "Workspace : $($workspace.name)"
    Write-Host "Saved at  : $($workspace.savedAt)"
    Write-Host "Windows   : $($workspace.windows.Count)"
    Write-Host ""

    # ------------------------------------------------------------
    # Start missing applications
    # ------------------------------------------------------------

    Write-Host "Checking windows..."

    # Get current windows
    $currentWindows = @(
        [WorkspaceSwitcher.Native]::GetTopLevelWindows()
    )

    # Exclude the WooorkFlip GUI itself.
    if ($ExcludeHandle -ne 0) {
        $currentWindows = @(
            $currentWindows | Where-Object {
                [long]$_.Handle -ne $ExcludeHandle
            }
        )
    }

    # Track windows already matched.
    $usedHandles = @{}

    foreach ($savedWindow in $workspace.windows) {

        $processPath = $savedWindow.processPath

        # Older workspace files may not contain launchFile.
        if ($null -eq $savedWindow.PSObject.Properties['launchFile']) {
            $savedWindow | Add-Member `
                -NotePropertyName launchFile `
                -NotePropertyValue $null
        }

        if ([string]::IsNullOrWhiteSpace($processPath)) {
            continue
        }

        $matched = $false

        foreach ($window in $currentWindows) {

            $handleKey = ([long]$window.Handle).ToString()

            if ($usedHandles.ContainsKey($handleKey)) {
                continue
            }

            try {
                $process = Get-Process -Id $window.ProcessId -ErrorAction Stop

                if (
                    $process.ProcessName -eq $savedWindow.process -and
                    $process.Path -ieq $processPath -and
                    $window.ClassName -eq $savedWindow.class
                ) {
                    $usedHandles[$handleKey] = $true
                    $matched = $true
                    break
                }
            }
            catch {
                continue
            }
        }

        if ($matched) {
            Write-Host "[FOUND] $($savedWindow.process): $($savedWindow.title)"
            continue
        }

        Write-Host "[MISSING] $($savedWindow.process): $($savedWindow.title)"

        if (
            -not [string]::IsNullOrWhiteSpace($savedWindow.launchFile) -and
            (Test-Path -LiteralPath $savedWindow.launchFile -PathType Leaf)
        ) {
            Start-WorkspaceApplication `
                -ProcessPath $processPath `
                -LaunchFile $savedWindow.launchFile
        }
        else {
            Start-WorkspaceApplication -ProcessPath $processPath
        }
    }

    # Wait for missing windows to appear.
    Write-Host "Waiting for windows..."

    $waitSeconds = 10
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    $missingWindows = @()

    do {
        Start-Sleep -Milliseconds 500

        $currentWindows = @(
            [WorkspaceSwitcher.Native]::GetTopLevelWindows()
        )

        if ($ExcludeHandle -ne 0) {
            $currentWindows = @(
                $currentWindows | Where-Object {
                    [long]$_.Handle -ne $ExcludeHandle
                }
            )
        }

        $usedHandles = @{}
        $missingWindows = @()

        foreach ($savedWindow in $workspace.windows) {

            $found = $false

            foreach ($window in $currentWindows) {

                $handleKey = ([long]$window.Handle).ToString()

                if ($usedHandles.ContainsKey($handleKey)) {
                    continue
                }

                try {
                    $process = Get-Process -Id $window.ProcessId -ErrorAction Stop

                    if (
                        $process.ProcessName -eq $savedWindow.process -and
                        $process.Path -ieq $savedWindow.processPath -and
                        $window.ClassName -eq $savedWindow.class
                    ) {
                        $usedHandles[$handleKey] = $true
                        $found = $true
                        break
                    }
                }
                catch {
                    continue
                }
            }

            if (-not $found) {
                $missingWindows += $savedWindow
            }
        }

    } while (
        $missingWindows.Count -gt 0 -and
        (Get-Date) -lt $deadline
    )

    Write-Host "Window startup wait completed."
    Write-Host "Missing windows: $($missingWindows.Count)"

    # Get current windows
    $currentWindows = @(
        [WorkspaceSwitcher.Native]::GetTopLevelWindows()
    )

    # Exclude the WooorkFlip GUI itself.
    if ($ExcludeHandle -ne 0) {
        $currentWindows = @(
            $currentWindows | Where-Object {
                [long]$_.Handle -ne $ExcludeHandle
            }
        )
    }

    $currentItems = foreach ($window in $currentWindows) {

        $processName = '(unknown)'
        $processPath = $null

        try {
            $process = Get-Process -Id $window.ProcessId -ErrorAction Stop
            $processName = $process.ProcessName

            try {
                $processPath = $process.Path
            }
            catch {
                # Process path may be unavailable.
            }
        }
        catch {
            continue
        }

        [pscustomobject]@{
            Window      = $window
            Process     = $processName
            ProcessPath = $processPath
            Title       = $window.Title
            Class       = $window.ClassName
            Used        = $false
        }
    }

    # Restore windows
    foreach ($saved in $workspace.windows) {

        # Match process, path and class
        $candidates = @(
            $currentItems | Where-Object {
                -not $_.Used -and
                $_.Process -eq $saved.process -and
                $_.Class -eq $saved.class -and
                $_.ProcessPath -and
                $_.ProcessPath -ieq $saved.processPath
            }
        )

        # Read saved HWND
        $savedHandle = 0L

        if (-not [string]::IsNullOrWhiteSpace([string]$saved.handle)) {
            try {
                $handleText = ([string]$saved.handle).Trim()

                if ($handleText.StartsWith('0x')) {
                    $handleText = $handleText.Substring(2)
                }

                $savedHandle = [Convert]::ToInt64($handleText, 16)
            }
            catch {
                $savedHandle = 0L
            }
        }

        # Prefer exact HWND match
        $target = $null

        if ($savedHandle -ne 0) {
            $target = $candidates |
                Where-Object {
                    [long]$_.Window.Handle -eq $savedHandle
                } |
                Select-Object -First 1
        }

        # Fallback: prefer exact title match
        if (-not $target) {
            $target = $candidates |
                Where-Object {
                    $_.Title -eq $saved.title
                } |
                Select-Object -First 1
        }

        # Final fallback: use an unused window
        if (-not $target) {
            $target = $candidates | Select-Object -First 1
        }

        if (-not $target) {

            [pscustomobject]@{
                Process = $saved.process
                Title   = $saved.title
                Result  = 'Not found'
                Detail  = 'No matching window'
            }

            continue
        }

        # Mark window as used
        $target.Used = $true

        # Validate saved size
        if (
            [int]$saved.normalWidth -le 0 -or
            [int]$saved.normalHeight -le 0
        ) {
            [pscustomobject]@{
                Process = $saved.process
                Title   = $saved.title
                Result  = 'Failed'
                Detail  = 'Invalid saved window size'
            }

            continue
        }

        # Apply saved placement only when necessary
        $current = $target.Window

        $sameState = $current.State -eq $saved.state

        $samePosition = (
            $current.NormalX -eq [int]$saved.normalX -and
            $current.NormalY -eq [int]$saved.normalY -and
            $current.NormalWidth -eq [int]$saved.normalWidth -and
            $current.NormalHeight -eq [int]$saved.normalHeight
        )

        if ($saved.process -eq 'WindowsTerminal') {
            $success = $true
            Write-Host "[SKIP] WindowsTerminal placement"
        }
        elseif ($sameState -and $samePosition) {
            $success = $true
            Write-Host "[SKIP] Already in saved state: $($saved.process)"
        }
        else {
            $handle = [long]$current.Handle
            Write-Host "[BEFORE] Process=$($saved.process) Handle=0x$('{0:X}' -f $handle) State=$($current.State)"
            $success = [WorkspaceSwitcher.Native]::ApplyWindowPlacement(
                $handle,
                [string]$saved.state,
                [int]$saved.normalX,
                [int]$saved.normalY,
                [int]$saved.normalWidth,
                [int]$saved.normalHeight
            )
            Write-Host "[AFTER] Process=$($saved.process) ApplyResult=$success"
        }

        [pscustomobject]@{
            Process = $saved.process
            Title   = $saved.title
            Result  = $(if ($success) { 'Restored' } else { 'Failed' })
            Detail  = $saved.state
        }
    }

    # DEBUG
    Write-Host "[DEBUG] ExcludeHandle = 0x$($ExcludeHandle.ToString('X'))"
    Write-Host "[DEBUG] Current windows:"
    foreach ($item in $currentItems) {
        Write-Host (
            "[DEBUG] Handle=0x{0:X} Used={1} Process={2} Title={3}" -f `
            [long]$item.Window.Handle,
            $item.Used,
            $item.Process,
            $item.Window.Title
        )
    }

    # ------------------------------------------------------------
    # Minimize windows not included in the workspace
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Minimizing windows not in workspace..."

    # Write-Host "[DEBUG] ExcludeHandle = 0x$($ExcludeHandle.ToString('X'))"

    $unmatchedWindows = @(
        $currentItems | Where-Object {
            -not $_.Used -and
            [long]$_.Window.Handle -ne $ExcludeHandle
        }
    )

    foreach ($item in $unmatchedWindows) {

        $handle = [long]$item.Window.Handle

        # Final safety check
        if ($handle -eq $ExcludeHandle) {
            Write-Warning "[MINIMIZE] Skipped excluded GUI handle."
            continue
        }

        Write-Host (
            "[MINIMIZE] Handle=0x{0:X} Process={1} Title={2}" -f `
            $handle,
            $item.Process,
            $item.Window.Title
        )

        [void][WorkspaceSwitcher.Native]::ChangeWindowState(
            $handle,
            6,
            $false
        )
    }

    # Write-Host "Minimized: $($unmatchedWindows.Count)"

    # Display results
    # Write-Host "Restore results:"
    # $results |
    #     Format-Table Process, Result, Title, Detail -AutoSize
    # $restored = @($results | Where-Object Result -eq 'Restored').Count
    # $notFound = @($results | Where-Object Result -eq 'Not found').Count
    # $failed = @($results | Where-Object Result -eq 'Failed').Count
    # Write-Host ""
    # Write-Host "Restored : $restored"
    # Write-Host "Not found: $notFound"
    # Write-Host "Failed   : $failed"

    return
    }


# ------------------------------------------------------------
# Delete workspace
# ------------------------------------------------------------

if ($Action -eq 'Delete') {

    if (-not $Name) {
        throw "The -Name parameter is required. Example: -Action Delete -Name Keyboard"
    }

    if ($Name -notmatch '^[\w\.-]+$') {
        throw "Invalid workspace name."
    }

    $workspacePath = Join-Path $WorkspaceDirectory "$Name.json"

    if (-not (Test-Path -LiteralPath $workspacePath -PathType Leaf)) {
        throw "Workspace '$Name' was not found: $workspacePath"
    }

    Remove-Item -LiteralPath $workspacePath -Force -ErrorAction Stop

    Write-Host "Workspace '$Name' deleted successfully."
    Write-Host "File : $workspacePath"

    return
}

# ------------------------------------------------------------
# Window operation
# ------------------------------------------------------------

if (-not $Handle) {
    throw "The -Handle parameter is required for Action '$Action'. First run: .\WooorkFlip.ps1 -Action List"
}

$handleValue = ConvertFrom-WindowHandle -Value $Handle

$command = switch ($Action) {
    'Minimize' { 6 } # SW_MINIMIZE
    'Restore'  { 9 } # SW_RESTORE
    'Maximize' { 3 } # SW_MAXIMIZE
    'Focus'    { 9 } # SW_RESTORE, then request foreground
}

$bringToFront = $Action -ne 'Minimize'

$ok = [WorkspaceSwitcher.Native]::ChangeWindowState(
    $handleValue,
    $command,
    $bringToFront
)

if (-not $ok) {
    throw "Window handle $Handle is no longer valid. Run -Action List again."
}

Write-Host "$Action requested for window $Handle."

if ($Action -eq 'Focus') {
    Write-Host 'Windows may deny foreground activation in some situations; if so, the window may restore without taking focus.'
}
