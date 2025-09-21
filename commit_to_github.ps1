# GitHub Auto-Monitor Script - PowerShell Version
# Version: 1.5.8

param(
    [string]$Mode,
    [string]$CommitMessage,
    [switch]$Restarted
)

# Script configuration
$SCRIPT_VERSION = "1.5.9"
$script:script_restarted = $Restarted
$script:auto_mode = $false
$script:menu_selection = 1
$script:remote_changes_available = $false
$script:repo_status_line = ""
$script:repo_status_color = "Green"
$script:repo_name = ""
$script:current_branch = ""
$script:mods_file_count = 0
$script:settings_menu_selection = 1

# Settings configuration
$script:settings_file = "commit_settings.json"
$script:settings = @{
    auto_commit_interval = 60
    monitor_mods_folder = $true
    monitor_config_folder = $true
    show_file_counts = $true
    auto_lfs_large_files = $true
    server_folder_path = ""
}

# Set location to script directory
Set-Location $PSScriptRoot

# Console title
$Host.UI.RawUI.WindowTitle = "GitHub Auto-Monitor Script"

function Load-Settings {
    if (Test-Path $script:settings_file) {
        try {
            $loaded_settings = Get-Content $script:settings_file | ConvertFrom-Json
            $script:settings.auto_commit_interval = $loaded_settings.auto_commit_interval
            $script:settings.monitor_mods_folder = $loaded_settings.monitor_mods_folder
            $script:settings.monitor_config_folder = $loaded_settings.monitor_config_folder
            $script:settings.show_file_counts = $loaded_settings.show_file_counts
            $script:settings.auto_lfs_large_files = $loaded_settings.auto_lfs_large_files
            $script:settings.server_folder_path = $loaded_settings.server_folder_path
        }
        catch {
            Write-Host "Warning: Could not load settings file. Using defaults." -ForegroundColor Yellow
        }
    }
}

function Save-Settings {
    try {
        $script:settings | ConvertTo-Json | Set-Content $script:settings_file
    }
    catch {
        Write-Host "Error: Could not save settings file." -ForegroundColor Red
    }
}

function Get-ModsFileCount {
    if (Test-Path "mods") {
        $script:mods_file_count = (Get-ChildItem "mods" -File | Measure-Object).Count
    } else {
        $script:mods_file_count = 0
    }
}

function Initialize-GitEnvironment {
    # Load settings first
    Load-Settings

    # Count files in mods folder
    Get-ModsFileCount

    # Check if Git is installed
    try {
        git --version | Out-Null
    }
    catch {
        Write-Host "ERROR: Git is not installed or not found in PATH." -ForegroundColor Red
        Write-Host "Please install Git from: https://git-scm.com/download/win" -ForegroundColor Yellow
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    # Check if we have a local repository
    $repository_exists = $false
    if ((Test-Path ".git") -and (Test-Path ".git\config")) {
        $repository_exists = $true
        git branch -M main 2>$null
    } else {
        # Create new repository
        Write-Host "No .git folder found. Initializing git repository..." -ForegroundColor Yellow
        git init
        git branch -M main
        Write-Host "Repository initialized successfully." -ForegroundColor Green
        Write-Host ""

        # Set basic repository status for new repos
        $script:current_branch = git branch --show-current
        $script:repo_name = ""
        $script:repo_status_line = "Repository ready | Remote: not configured | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
        $script:repo_status_color = "Green"
        return # Don't check for remote on new repository
    }

    # If repository exists, check for remote
    if ($repository_exists) {
        try {
            git config --get remote.origin.url | Out-Null
        }
        catch {
            # No remote configured, prompt user
            Write-Host "No remote origin configured. Setting up remote repository..." -ForegroundColor Yellow
            Write-Host ""

            do {
                $repo_url = Read-Host "Enter GitHub repository URL (https://github.com/username/repo.git)"

                # Validate URL format
                if ($repo_url -notmatch "github\.com/") {
                    Write-Host "Invalid URL format. Please use a GitHub repository URL." -ForegroundColor Red
                    continue
                }

                # Test if repository exists and is accessible
                try {
                    git ls-remote $repo_url 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        git remote add origin $repo_url
                        Write-Host "Remote origin added successfully." -ForegroundColor Green
                        Write-Host ""
                        break
                    }
                    else {
                        Write-Host "Error: Repository does not exist or is not accessible. Please check:" -ForegroundColor Red
                        Write-Host "- Repository URL is correct" -ForegroundColor Yellow
                        Write-Host "- Repository exists on GitHub" -ForegroundColor Yellow
                        Write-Host "- You have access rights to the repository" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "Error testing repository accessibility." -ForegroundColor Red
                }
            } while ($true)
        }
    }

    # Initialize LFS
    git lfs install --skip-repo 2>$null | Out-Null
    git lfs track "*.jar" 2>$null | Out-Null
    git lfs track "*.zip" 2>$null | Out-Null

    # Test file sizes
    $size_limit = 52324403
    $oversized_found = $false
    $reset_needed = $false

    # Check untracked files
    $untracked_files = git ls-files --others --exclude-standard
    foreach ($file in $untracked_files) {
        if (Test-Path $file) {
            $file_size = (Get-Item $file).Length
            if ($file_size -gt $size_limit) {
                if (-not $oversized_found) {
                    Write-Host ""
                    Write-Host "Found oversized files:" -ForegroundColor Yellow
                }
                $file_mb = [math]::Round($file_size / 1048576, 2)
                Write-Host "  - $file ($file_mb MB)" -ForegroundColor Red
                Add-Content ".gitignore" "`n$file"
                $oversized_found = $true
            }
        }
    }

    # Check staged files
    $staged_files = git diff --cached --name-only 2>$null
    foreach ($file in $staged_files) {
        if (Test-Path $file) {
            $file_size = (Get-Item $file).Length
            if ($file_size -gt $size_limit) {
                Write-Host "Found oversized staged file: $file ($file_size bytes)" -ForegroundColor Red
                Add-Content ".gitignore" "`n$file"
                $oversized_found = $true
                $reset_needed = $true
            }
        }
    }

    if ($reset_needed) {
        Write-Host "Resetting staged changes due to oversized files..." -ForegroundColor Yellow
        git reset HEAD .
    }

    # Remove oversized files from tracking if not tracked by LFS
    if ($oversized_found) {
        $tracked_files = git ls-files
        foreach ($file in $tracked_files) {
            if (Test-Path $file) {
                $file_size = (Get-Item $file).Length
                if ($file_size -gt $size_limit) {
                    $lfs_files = git lfs ls-files
                    if ($lfs_files -notcontains $file) {
                        git rm --cached $file 2>$null | Out-Null
                        Add-Content ".gitignore" "`n$file"
                    }
                }
            }
        }
    }

    # Set repository status variables for menu display
    $script:current_branch = git branch --show-current
    try {
        $repo_url = git config --get remote.origin.url
        $script:repo_name = $repo_url -replace "https://github.com/", "" -replace "\.git$", ""
        $script:repo_status_line = "Repository ready | Remote: $($script:repo_name) | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
        $script:repo_status_color = "Green"
    }
    catch {
        $script:repo_name = ""
        $script:repo_status_line = "Repository ready | Remote: not configured | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
        $script:repo_status_color = "Green"
    }
}

function Show-RepositoryStatus {
    $script:current_branch = git branch --show-current

    try {
        $repo_url = git config --get remote.origin.url
        $script:repo_name = $repo_url -replace "https://github.com/", "" -replace "\.git$", ""

        # Test if remote is accessible
        git ls-remote $repo_url 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Repository " -NoNewline
            Write-Host "ready" -ForegroundColor Green -NoNewline
            Write-Host " | Remote: $($script:repo_name) | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
            $script:repo_status_line = "Repository ready | Remote: $($script:repo_name) | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
            $script:repo_status_color = "Green"
        }
        else {
            Write-Host "Repository " -NoNewline
            Write-Host "error" -ForegroundColor Red -NoNewline
            Write-Host " | Remote: $($script:repo_name) (invalid) | Branch: $($script:current_branch)"
            $script:repo_status_line = "Repository error | Remote: $($script:repo_name) (invalid) | Branch: $($script:current_branch)"
            $script:repo_status_color = "Red"
            Write-Host "ERROR: Remote repository is not accessible. Please reconfigure with a valid GitHub URL." -ForegroundColor Red
            Write-Host ""

            $delete_git = Read-Host "Do you want to delete the .git folder and start fresh? (y/n)"
            if ($delete_git -eq "y" -or $delete_git -eq "Y") {
                Write-Host "Deleting .git folder..." -ForegroundColor Yellow
                Remove-Item ".git" -Recurse -Force
                Write-Host ".git folder deleted. Run the script again to start fresh." -ForegroundColor Green
            }
            else {
                Write-Host "You can manually run: git remote remove origin" -ForegroundColor Yellow
                Write-Host "Then run this script again to reconfigure." -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            exit
        }
    }
    catch {
        Write-Host "Repository " -NoNewline
        Write-Host "ready" -ForegroundColor Green -NoNewline
        Write-Host " | Remote: not configured | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
        $script:repo_status_line = "Repository ready | Remote: not configured | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
        $script:repo_status_color = "Green"
    }
}

function Show-CachedStatus {
    if ($script:repo_status_color -eq "Green") {
        Write-Host "Repository " -NoNewline
        Write-Host "ready" -ForegroundColor Green -NoNewline
        Write-Host " | Remote: $($script:repo_name) | Branch: $($script:current_branch) | Mods: $($script:mods_file_count) files"
    }
    else {
        Write-Host "Repository " -NoNewline
        Write-Host "error" -ForegroundColor Red -NoNewline
        Write-Host " | Remote: $($script:repo_name) (invalid) | Branch: $($script:current_branch)"
    }

    # Check for local changes
    $has_local_changes = $false
    git diff --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $has_local_changes = $true }
    git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $has_local_changes = $true }

    # Show changes status
    Write-Host ""
    if ($has_local_changes -and $script:remote_changes_available) {
        Write-Host "Status: " -NoNewline
        Write-Host "Local changes" -ForegroundColor Yellow -NoNewline
        Write-Host " | " -NoNewline
        Write-Host "Remote changes available" -ForegroundColor Blue
    }
    elseif ($has_local_changes) {
        Write-Host "Status: " -NoNewline
        Write-Host "Local changes pending" -ForegroundColor Yellow
    }
    elseif ($script:remote_changes_available) {
        Write-Host "Status: " -NoNewline
        Write-Host "Remote changes available" -ForegroundColor Blue
    }
    else {
        Write-Host "Status: " -NoNewline
        Write-Host "Up to date" -ForegroundColor Green
    }
}

function Initialize-LFS {
    git lfs install --skip-repo 2>$null | Out-Null
    git lfs track "*.jar" 2>$null | Out-Null
    git lfs track "*.zip" 2>$null | Out-Null
    Write-Host "  [OK] LFS tracking: *.jar, *.zip" -ForegroundColor Green
}

function Test-FileSizes {
    $size_limit = 52324403
    $oversized_found = $false
    $reset_needed = $false

    # Check untracked files
    $untracked_files = git ls-files --others --exclude-standard
    foreach ($file in $untracked_files) {
        if (Test-Path $file) {
            $file_size = (Get-Item $file).Length
            if ($file_size -gt $size_limit) {
                if (-not $oversized_found) {
                    Write-Host ""
                    Write-Host "Found oversized files:" -ForegroundColor Yellow
                }
                $file_mb = [math]::Round($file_size / 1048576, 2)
                Write-Host "  - $file ($file_mb MB)" -ForegroundColor Red
                Add-Content ".gitignore" "`n$file"
                $oversized_found = $true
            }
        }
    }

    # Check staged files
    $staged_files = git diff --cached --name-only 2>$null
    foreach ($file in $staged_files) {
        if (Test-Path $file) {
            $file_size = (Get-Item $file).Length
            if ($file_size -gt $size_limit) {
                Write-Host "Found oversized staged file: $file ($file_size bytes)" -ForegroundColor Red
                Add-Content ".gitignore" "`n$file"
                $oversized_found = $true
                $reset_needed = $true
            }
        }
    }

    if ($reset_needed) {
        Write-Host "Resetting staged changes due to oversized files..." -ForegroundColor Yellow
        git reset HEAD .
    }

    # Remove oversized files from tracking if not tracked by LFS
    if ($oversized_found) {
        $tracked_files = git ls-files
        foreach ($file in $tracked_files) {
            if (Test-Path $file) {
                $file_size = (Get-Item $file).Length
                if ($file_size -gt $size_limit) {
                    $lfs_files = git lfs ls-files
                    if ($lfs_files -notcontains $file) {
                        git rm --cached $file 2>$null | Out-Null
                        Add-Content ".gitignore" "`n$file"
                    }
                }
            }
        }
    }
}

function Update-RemoteStatus {
    param(
        [switch]$ShowOutput,
        [switch]$ReturnErrorOnFail
    )

    $script:remote_changes_available = $false
    $script:remote_fetch_success = $false

    try {
        git config --get remote.origin.url | Out-Null
        $script:current_branch = git branch --show-current

        # Fetch from remote
        git fetch origin 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($ShowOutput) {
                Write-Host "  [ERROR] Cannot fetch from remote!" -ForegroundColor Red
            }
            if ($ReturnErrorOnFail) {
                return $false
            }
            return
        }

        $script:remote_fetch_success = $true

        # Check if we have any commits in the local repository
        try {
            git rev-parse HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                if ($ShowOutput) {
                    Write-Host "  [OK] New repository - no remote comparison needed" -ForegroundColor Green
                }
                return $true
            }
        }
        catch {
            if ($ShowOutput) {
                Write-Host "  [OK] New repository - no remote comparison needed" -ForegroundColor Green
            }
            return $true
        }

        # Check if remote branch exists
        try {
            git rev-parse "origin/$($script:current_branch)" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                if ($ShowOutput) {
                    Write-Host "  [OK] Remote branch origin/$($script:current_branch) not found - first push will create it" -ForegroundColor Yellow
                }
                return $true
            }
        }
        catch {
            if ($ShowOutput) {
                Write-Host "  [OK] Remote branch origin/$($script:current_branch) not found - first push will create it" -ForegroundColor Yellow
            }
            return $true
        }

        # Check if there are changes available on remote
        try {
            git diff HEAD "origin/$($script:current_branch)" --quiet 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $script:remote_changes_available = $true
                if ($ShowOutput) {
                    Write-Host "  [NOTICE] Remote changes available" -ForegroundColor Yellow
                }
            }
            else {
                if ($ShowOutput) {
                    Write-Host "  [OK] Already up to date with remote" -ForegroundColor Green
                }
            }
        }
        catch {
            if ($ShowOutput) {
                Write-Host "  [OK] Already up to date with remote" -ForegroundColor Green
            }
        }

        return $true
    }
    catch {
        if ($ShowOutput) {
            Write-Host "No remote origin configured. Skipping check." -ForegroundColor Yellow
        }
        return $false
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "GitHub Auto-Monitor Script v$SCRIPT_VERSION" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Current directory: $(Get-Location)"
    Write-Host ""

    # Show cached repository status
    Show-CachedStatus
    Write-Host ""
    Write-Host "Select an option:" -ForegroundColor White
    Write-Host ""

    # Menu options with highlighting
    if ($script:menu_selection -eq 1) {
        Write-Host "  > Commit Changes Now" -ForegroundColor Green
    } else {
        Write-Host "    Commit Changes Now"
    }

    if ($script:menu_selection -eq 2) {
        Write-Host "  > Auto-Monitor Mode" -ForegroundColor Green
    } else {
        Write-Host "    Auto-Monitor Mode"
    }

    if ($script:menu_selection -eq 3) {
        if ($script:remote_changes_available) {
            Write-Host "  > Pull Changes from Remote" -ForegroundColor Blue
        } else {
            Write-Host "  > Pull Changes from Remote" -ForegroundColor Green
        }
    } else {
        if ($script:remote_changes_available) {
            Write-Host "    Pull Changes from Remote" -ForegroundColor Blue
        } else {
            Write-Host "    Pull Changes from Remote"
        }
    }

    if ($script:menu_selection -eq 4) {
        Write-Host "  > Hard Reset to Remote" -ForegroundColor Red
    } else {
        Write-Host "    Hard Reset to Remote"
    }

    if ($script:menu_selection -eq 5) {
        Write-Host "  > Force Push to Remote" -ForegroundColor Red
    } else {
        Write-Host "    Force Push to Remote"
    }

    if ($script:menu_selection -eq 6) {
        Write-Host "  > Settings" -ForegroundColor Green
    } else {
        Write-Host "    Settings"
    }

    Write-Host ""
    Write-Host "Use UP/DOWN arrow keys to navigate, ENTER to select, ESC to exit" -ForegroundColor Gray
}

function Read-MenuKey {
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    switch ($key.VirtualKeyCode) {
        13 { return "ENTER" }  # Enter
        27 { return "ESC" }    # Escape
        38 { return "UP" }     # Up Arrow
        40 { return "DOWN" }   # Down Arrow
        default { return "OTHER" }
    }
}

function Start-MenuLoop {
    do {
        Show-Menu
        $key_input = Read-MenuKey

        switch ($key_input) {
            "ENTER" {
                return $script:menu_selection
            }
            "ESC" {
                exit
            }
            "UP" {
                $script:menu_selection--
                if ($script:menu_selection -lt 1) { $script:menu_selection = 6 }
            }
            "DOWN" {
                $script:menu_selection++
                if ($script:menu_selection -gt 6) { $script:menu_selection = 1 }
            }
        }
    } while ($true)
}

function Invoke-CommitProcess {
    param([string]$Message)

    # Prepare commit message
    if ([string]::IsNullOrEmpty($Message)) {
        $date = Get-Date -Format "ddd-MM-dd"
        $time = Get-Date -Format "HH:mm"
        $commit_message = "Auto commit $date $time"
    } else {
        $commit_message = $Message
    }

    # Get current branch name
    $script:current_branch = git branch --show-current

    # Add all files to staging
    git add .

    Write-Host ""
    Write-Host "Git Status:" -ForegroundColor Cyan
    git status --porcelain
    Write-Host ""

    # Check if there are changes to commit
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -m $commit_message
        Write-Host ""

        git push -u origin $script:current_branch
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Push failed. Attempting to pull and merge remote changes..." -ForegroundColor Yellow
            git pull origin $script:current_branch --no-edit --allow-unrelated-histories
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Merge failed. Please resolve conflicts manually." -ForegroundColor Red
            } else {
                Write-Host "Merge successful. Pushing again..." -ForegroundColor Green
                git push -u origin $script:current_branch
            }
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "Push failed! Check the error messages above." -ForegroundColor Red
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        Write-Host ""
        Write-Host "Commit completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "No changes to commit." -ForegroundColor Yellow
    }

    Write-Host "Press any key to return to menu..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Start-AutoMonitor {
    Initialize-LFS | Out-Null

    Write-Host "Auto-monitoring enabled. Checking for changes every minute..." -ForegroundColor Green
    Write-Host "Press ESC to stop monitoring." -ForegroundColor Yellow
    Write-Host ""

    do {
        $current_time = Get-Date -Format "HH:mm"

        Write-Host "[$current_time] Checking for remote changes..." -ForegroundColor Cyan
        Update-RemoteStatus -ShowOutput

        Test-FileSizes
        git add . 2>$null | Out-Null
        git diff --staged --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[$current_time] Local changes detected. Committing and pushing..." -ForegroundColor Yellow

            $date = Get-Date -Format "ddd-MM-dd"
            $commit_message = "Auto commit $date $current_time"

            git commit -m $commit_message 2>$null | Out-Null

            $script:current_branch = git branch --show-current
            git push -u origin $script:current_branch 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                git pull origin $script:current_branch --no-edit --allow-unrelated-histories 2>$null | Out-Null
                git push -u origin $script:current_branch 2>$null | Out-Null
            }

            Write-Host "[$current_time] Auto-commit completed!" -ForegroundColor Green
        } else {
            Write-Host "[$current_time] No local changes detected." -ForegroundColor Gray
        }

        # Check for ESC key press during 60 second wait
        for ($i = 1; $i -le 60; $i++) {
            Start-Sleep 1
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Escape') {
                    Write-Host ""
                    Write-Host "Auto-monitor stopped. Returning to menu..." -ForegroundColor Yellow
                    return
                }
            }
        }
    } while ($true)
}

function Invoke-PullRemoteChanges {
    Initialize-LFS | Out-Null

    Clear-Host
    Write-Host "GitHub Auto-Monitor Script v$SCRIPT_VERSION - Pull Changes Mode" -ForegroundColor Cyan
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""

    # Check if remote is configured
    try {
        git config --get remote.origin.url | Out-Null
    }
    catch {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot pull from remote without a configured origin." -ForegroundColor Yellow
        Write-Host "Please configure a remote first." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $fetch_success = Update-RemoteStatus -ReturnErrorOnFail
    if (-not $fetch_success) {
        Write-Host "New repository - no remote comparison needed" -ForegroundColor Green
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    # Check if we have any commits in the local repository
    try {
        git rev-parse HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "New repository - no remote comparison needed" -ForegroundColor Green
            Write-Host ""
            Write-Host "Press any key to return to menu..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
    }
    catch {
        Write-Host "New repository - no remote comparison needed" -ForegroundColor Green
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    # Check if remote branch exists
    try {
        git rev-parse "origin/$($script:current_branch)" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Remote branch origin/$($script:current_branch) not found" -ForegroundColor Yellow
            Write-Host "First push will create it." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Press any key to return to menu..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
    }
    catch {
        Write-Host "Remote branch origin/$($script:current_branch) not found" -ForegroundColor Yellow
        Write-Host "First push will create it." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    # Check if there are changes to pull
    git diff HEAD "origin/$($script:current_branch)" --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Remote changes detected - pulling updates:" -ForegroundColor Yellow
        Write-Host ""

        # Check for uncommitted local changes
        $has_changes = $false
        git diff --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { $has_changes = $true }
        git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { $has_changes = $true }

        if ($has_changes) {
            Write-Host ""
            Write-Host "Uncommitted local changes detected:" -ForegroundColor Yellow
            Write-Host "========================" -ForegroundColor Yellow
            git status --porcelain
            Write-Host ""
            Write-Host "Stashing uncommitted changes before pull..." -ForegroundColor Yellow
            git stash push -m "Auto-stash before manual pull"
            $stash_created = $true
        } else {
            $stash_created = $false
        }

        git pull origin $script:current_branch --no-edit --allow-unrelated-histories --stat

        # Restore stashed changes
        if ($stash_created) {
            Write-Host ""
            Write-Host "Restoring stashed changes..." -ForegroundColor Yellow
            git stash pop 2>$null | Out-Null
        }

        Write-Host ""
        Write-Host "Pull completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "Already up to date with remote" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Press any key to return to menu..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Invoke-HardReset {
    Clear-Host
    Write-Host "Hard Reset Mode" -ForegroundColor Cyan
    Write-Host "===============" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WARNING: This will PERMANENTLY DELETE all local changes!" -ForegroundColor Red
    Write-Host "Your local repository will be reset to match the remote exactly." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "What will happen:" -ForegroundColor White
    Write-Host "  1. All uncommitted changes will be lost" -ForegroundColor Yellow
    Write-Host "  2. All local commits not on remote will be lost" -ForegroundColor Yellow
    Write-Host "  3. Working directory will match remote branch exactly" -ForegroundColor Yellow
    Write-Host ""

    # Check if remote is configured
    try {
        git config --get remote.origin.url | Out-Null
    }
    catch {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot perform hard reset without a remote repository." -ForegroundColor Yellow
        Write-Host "Please configure a remote first." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    # Check if remote is accessible
    $fetch_success = Update-RemoteStatus -ReturnErrorOnFail
    if (-not $fetch_success) {
        Write-Host "ERROR: Cannot fetch from remote!" -ForegroundColor Red
        Write-Host "Remote repository is not accessible or does not exist." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    # Determine which branch to reset to
    $script:current_branch = git branch --show-current
    try {
        git rev-parse "origin/$($script:current_branch)" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $reset_branch = $script:current_branch
        }
        else {
            # Try main branch
            git rev-parse "origin/main" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $reset_branch = "main"
                Write-Host "Note: Current branch ($($script:current_branch)) not found on remote." -ForegroundColor Yellow
                Write-Host "Will reset to origin/main instead." -ForegroundColor Yellow
            }
            else {
                # Try master branch
                git rev-parse "origin/master" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $reset_branch = "master"
                    Write-Host "Note: Current branch ($($script:current_branch)) not found on remote." -ForegroundColor Yellow
                    Write-Host "Will reset to origin/master instead." -ForegroundColor Yellow
                }
                else {
                    Write-Host "ERROR: No suitable remote branch found!" -ForegroundColor Red
                    Write-Host "Cannot determine which remote branch to reset to." -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Press any key to return to menu..."
                    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                    return
                }
            }
        }
    }
    catch {
        Write-Host "ERROR: Unable to determine remote branch!" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    Write-Host "Ready to reset to origin/$reset_branch!" -ForegroundColor Cyan
    Write-Host ""
    $confirm = Read-Host "Type 'RESET' to confirm (anything else cancels)"

    if ($confirm -ne "RESET") {
        Write-Host ""
        Write-Host "Reset cancelled." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    Write-Host "Performing hard reset..." -ForegroundColor Yellow
    Write-Host ""

    # Abort any ongoing merge/rebase
    git merge --abort 2>$null | Out-Null
    git rebase --abort 2>$null | Out-Null

    # Clean working directory
    Write-Host "Cleaning working directory..." -ForegroundColor Yellow
    git clean -f -d
    git reset --hard HEAD

    # Switch to target branch and reset
    Write-Host "Switching to $reset_branch branch..." -ForegroundColor Yellow
    git checkout $reset_branch 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating $reset_branch branch from origin/$reset_branch..." -ForegroundColor Yellow
        git checkout -b $reset_branch "origin/$reset_branch"
    }

    # Hard reset to remote
    Write-Host "Resetting to origin/$reset_branch..." -ForegroundColor Yellow
    git reset --hard "origin/$reset_branch"

    # Clean any remaining untracked files
    git clean -f -d

    Write-Host ""
    Write-Host "Hard reset completed successfully!" -ForegroundColor Green
    Write-Host "Local repository now matches origin/$reset_branch!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Repository status:" -ForegroundColor Cyan
    $status = git status --porcelain
    if ([string]::IsNullOrEmpty($status)) {
        Write-Host "  Working directory is clean" -ForegroundColor Green
    } else {
        Write-Host "  No changes - repository is clean" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Press any key to return to menu..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-SettingsMenu {
    Clear-Host
    Write-Host "GitHub Auto-Monitor Script v$SCRIPT_VERSION - Settings" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Current Settings:" -ForegroundColor White
    Write-Host ""

    # Setting options with highlighting
    if ($script:settings_menu_selection -eq 1) {
        Write-Host "  > Auto-commit interval: $($script:settings.auto_commit_interval) seconds" -ForegroundColor Green
    } else {
        Write-Host "    Auto-commit interval: $($script:settings.auto_commit_interval) seconds"
    }

    if ($script:settings_menu_selection -eq 2) {
        $status = if ($script:settings.monitor_mods_folder) { "Enabled" } else { "Disabled" }
        Write-Host "  > Monitor mods folder: $status" -ForegroundColor Green
    } else {
        $status = if ($script:settings.monitor_mods_folder) { "Enabled" } else { "Disabled" }
        Write-Host "    Monitor mods folder: $status"
    }

    if ($script:settings_menu_selection -eq 3) {
        $status = if ($script:settings.monitor_config_folder) { "Enabled" } else { "Disabled" }
        Write-Host "  > Monitor config folder: $status" -ForegroundColor Green
    } else {
        $status = if ($script:settings.monitor_config_folder) { "Enabled" } else { "Disabled" }
        Write-Host "    Monitor config folder: $status"
    }

    if ($script:settings_menu_selection -eq 4) {
        $status = if ($script:settings.show_file_counts) { "Enabled" } else { "Disabled" }
        Write-Host "  > Show file counts: $status" -ForegroundColor Green
    } else {
        $status = if ($script:settings.show_file_counts) { "Enabled" } else { "Disabled" }
        Write-Host "    Show file counts: $status"
    }

    if ($script:settings_menu_selection -eq 5) {
        $status = if ($script:settings.auto_lfs_large_files) { "Enabled" } else { "Disabled" }
        Write-Host "  > Auto-LFS large files: $status" -ForegroundColor Green
    } else {
        $status = if ($script:settings.auto_lfs_large_files) { "Enabled" } else { "Disabled" }
        Write-Host "    Auto-LFS large files: $status"
    }

    if ($script:settings_menu_selection -eq 6) {
        Write-Host "  > Save Settings" -ForegroundColor Yellow
    } else {
        Write-Host "    Save Settings"
    }

    if ($script:settings_menu_selection -eq 7) {
        Write-Host "  > Back to Main Menu" -ForegroundColor Yellow
    } else {
        Write-Host "    Back to Main Menu"
    }

    Write-Host ""
    Write-Host "Use UP/DOWN arrows to navigate, ENTER to select/toggle, ESC to exit" -ForegroundColor Gray
}

function Start-SettingsLoop {
    do {
        Show-SettingsMenu
        $key_input = Read-MenuKey

        switch ($key_input) {
            "ENTER" {
                switch ($script:settings_menu_selection) {
                    1 {
                        # Auto-commit interval
                        $new_interval = Read-Host "Enter auto-commit interval in seconds (current: $($script:settings.auto_commit_interval))"
                        if ($new_interval -match "^\d+$" -and [int]$new_interval -gt 0) {
                            $script:settings.auto_commit_interval = [int]$new_interval
                        }
                    }
                    2 {
                        # Toggle monitor mods folder
                        $script:settings.monitor_mods_folder = -not $script:settings.monitor_mods_folder
                    }
                    3 {
                        # Toggle monitor config folder
                        $script:settings.monitor_config_folder = -not $script:settings.monitor_config_folder
                    }
                    4 {
                        # Toggle show file counts
                        $script:settings.show_file_counts = -not $script:settings.show_file_counts
                    }
                    5 {
                        # Toggle auto-LFS large files
                        $script:settings.auto_lfs_large_files = -not $script:settings.auto_lfs_large_files
                    }
                    6 {
                        # Save settings
                        Save-Settings
                        Write-Host ""
                        Write-Host "Settings saved successfully!" -ForegroundColor Green
                        Start-Sleep 2
                    }
                    7 {
                        # Back to main menu
                        return
                    }
                }
            }
            "ESC" {
                return
            }
            "UP" {
                $script:settings_menu_selection--
                if ($script:settings_menu_selection -lt 1) { $script:settings_menu_selection = 7 }
            }
            "DOWN" {
                $script:settings_menu_selection++
                if ($script:settings_menu_selection -gt 7) { $script:settings_menu_selection = 1 }
            }
        }
    } while ($true)
}

function Invoke-ForcePush {
    Write-Host "GitHub Auto-Monitor Script v$SCRIPT_VERSION - Force Push Mode" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WARNING: This will FORCEFULLY OVERWRITE the remote repository!" -ForegroundColor Red
    Write-Host "Remote will be reset to match your local changes exactly." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "What will happen:" -ForegroundColor White
    Write-Host "  1. All local changes will be committed" -ForegroundColor Yellow
    Write-Host "  2. Remote repository will be force-pushed to match local" -ForegroundColor Yellow
    Write-Host "  3. Any remote changes not in local will be LOST FOREVER" -ForegroundColor Red
    Write-Host ""

    # Check if remote is configured
    try {
        git config --get remote.origin.url | Out-Null
    }
    catch {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot perform force push without a remote repository." -ForegroundColor Yellow
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    Write-Host ""
    $confirm = Read-Host "Type 'FORCE' to confirm force push (anything else cancels)"

    if ($confirm -ne "FORCE") {
        Write-Host ""
        Write-Host "Force push cancelled." -ForegroundColor Yellow
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    Write-Host "Performing force push..." -ForegroundColor Yellow
    Write-Host ""

    # Add all changes
    Write-Host "Adding all local changes..." -ForegroundColor Yellow
    git add .

    # Check if there are changes to commit
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Committing all local changes..." -ForegroundColor Yellow
        $date = Get-Date -Format "ddd-MM-dd"
        $time = Get-Date -Format "HH:mm"
        git commit -m "Force push commit $date $time"
    } else {
        Write-Host "No new changes to commit." -ForegroundColor Gray
    }

    # Get current branch
    $script:current_branch = git branch --show-current

    Write-Host "Force pushing to origin/$($script:current_branch)..." -ForegroundColor Yellow
    git push origin $script:current_branch --force

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Force push failed! Check the error messages above." -ForegroundColor Red
        Write-Host "Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    Write-Host "Force push completed successfully!" -ForegroundColor Green
    Write-Host "Remote repository now matches your local changes exactly!" -ForegroundColor Green

    Write-Host ""
    Write-Host "Press any key to return to menu..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Main script execution
switch ($Mode.ToLower()) {
    "auto" {
        $script:auto_mode = $true
        Write-Host "GitHub Auto-Monitor Script v$SCRIPT_VERSION" -ForegroundColor Cyan
        Write-Host "==========================" -ForegroundColor Cyan
        Start-AutoMonitor
    }
    "commit" {
        $script:auto_mode = $false
        Write-Host "Current directory: $(Get-Location)"
        Write-Host ""
        Show-RepositoryStatus
        Update-RemoteStatus -ShowOutput
        Initialize-LFS | Out-Null
        Test-FileSizes | Out-Null
        Invoke-CommitProcess -Message $CommitMessage
    }
    "force-push" {
        $script:auto_mode = $false
        Write-Host "Current directory: $(Get-Location)"
        Write-Host ""
        Invoke-ForcePush
    }
    default {
        # Interactive menu mode
        Initialize-GitEnvironment
        Update-RemoteStatus -ShowOutput

        do {
            $selection = Start-MenuLoop

            switch ($selection) {
                1 {
                    # Commit Changes Now
                    $script:auto_mode = $false
                    Update-RemoteStatus | Out-Null
                    Invoke-CommitProcess
                }
                2 {
                    # Auto-Monitor Mode
                    $script:auto_mode = $true
                    Start-AutoMonitor
                }
                3 {
                    # Pull Changes from Remote
                    Invoke-PullRemoteChanges
                }
                4 {
                    # Hard Reset to Remote
                    Invoke-HardReset
                }
                5 {
                    # Force Push to Remote
                    Invoke-ForcePush
                }
                6 {
                    # Settings
                    Start-SettingsLoop
                }
            }
        } while ($true)
    }
}