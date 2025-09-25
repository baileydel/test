param(
    [string]$Mode,
    [string]$CommitMessage
)

# Version tracking
$SCRIPT_VERSION = "1.5.7"

# Set console title
$Host.UI.RawUI.WindowTitle = "GitHub Script v$SCRIPT_VERSION"

# Initialize script variables
$script:menu_selection = 1
$script:remote_changes_available = $false
$script:need_remote = $false
$script:from_menu = $false
$script:auto_mode = $false
$script:conflict_selection = 1

# Check for restart flag to prevent infinite loops
$script_restarted = $args -contains "--restarted"
if ($script_restarted) {
    $args = $args | Where-Object { $_ -ne "--restarted" }
}

function Test-GitInstalled {
    try {
        git --version | Out-Null
    } catch {
        Write-Host "ERROR: Git is not installed or not found in PATH." -ForegroundColor Red
        Write-Host "Please install Git from: https://git-scm.com/download/win"
        Write-Host "Press any key to exit..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        exit 1
    }
}

function Initialize-Repository {
    if (-not (Test-Path ".git")) {
        Write-Host "No .git folder found. Initializing git repository..."
        git init
        git branch -M main
        Write-Host "Repository initialized successfully.`n"
        $script:need_remote = $true
    } elseif (-not (Test-Path ".git\config")) {
        Write-Host ".git folder exists but config is missing. Re-initializing..."
        git init
        git branch -M main
        Write-Host "Repository re-initialized successfully.`n"
        $script:need_remote = $true
    } else {
        git branch -M main 2>$null
        git config --get remote.origin.url 2>$null
        if ($LASTEXITCODE -ne 0) {
            $script:need_remote = $true
        } else {
            $script:need_remote = $false
        }
    }
}

function Show-RepositoryStatus {
    $current_branch = git branch --show-current
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        $repo_url = git config --get remote.origin.url
        $repo_name = $repo_url -replace "https://github.com/" -replace ".git"

        # Test if remote is actually accessible
        git ls-remote $repo_url 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Repository " -NoNewline
            Write-Host "ready" -ForegroundColor Green -NoNewline
            Write-Host " | Remote: $repo_name | Branch: $current_branch"
        } else {
            Write-Host "Repository " -NoNewline
            Write-Host "error" -ForegroundColor Red -NoNewline
            Write-Host " | Remote: $repo_name (invalid) | Branch: $current_branch"
            Write-Host "ERROR: Remote repository is not accessible. Please reconfigure with a valid GitHub URL.`n" -ForegroundColor Red
            $delete_git = Read-Host "Do you want to delete the .git folder and start fresh? (y/n)"
            if ($delete_git -eq "y" -or $delete_git -eq "Y") {
                Write-Host "Deleting .git folder..."
                Remove-Item -Recurse -Force .git
                Write-Host ".git folder deleted. Run the script again to start fresh."
            } else {
                Write-Host "You can manually run: git remote remove origin"
                Write-Host "Then run this script again to reconfigure."
            }
            Write-Host "`nPress any key to exit..."
            $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
            exit
        }
    } else {
        Write-Host "Repository " -NoNewline
        Write-Host "ready" -ForegroundColor Green -NoNewline
        Write-Host " | Remote: not configured | Branch: $current_branch"
    }
}

function Initialize-LFS {
    git lfs install --skip-repo 2>$null
    git lfs track "*.jar" 2>$null
    git lfs track "*.zip" 2>$null
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
                Write-Host "`nFound oversized files:"
                $file_mb = [math]::Round($file_size / 1MB, 1)
                Write-Host "  - $file ($file_mb MB)" -ForegroundColor Red
                Add-Content -Path ".gitignore" -Value "`n$file"
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
                Write-Host "Found oversized staged file: $file ($file_size bytes)"
                Add-Content -Path ".gitignore" -Value "`n$file"
                $oversized_found = $true
                $reset_needed = $true
            }
        }
    }

    if ($reset_needed) {
        Write-Host "Resetting staged changes due to oversized files..."
        git reset HEAD .
    }

    # Remove oversized files from tracking only if NOT tracked by LFS
    if ($oversized_found) {
        $tracked_files = git ls-files
        foreach ($file in $tracked_files) {
            if (Test-Path $file) {
                $file_size = (Get-Item $file).Length
                if ($file_size -gt $size_limit) {
                    $lfs_check = git lfs ls-files | Select-String $file
                    if (-not $lfs_check) {
                        git rm --cached $file 2>$null
                        Add-Content -Path ".gitignore" -Value "`n$file"
                    }
                }
            }
        }
    }
}

function Set-RemoteIfNeeded {
    if ($script:need_remote) {
        Write-Host "No remote origin configured. Setting up remote repository..."
        Write-Host "`n"

        do {
            $repo_url = Read-Host "Enter GitHub repository URL (https://github.com/username/repo.git)"

            # Validate URL format
            if ($repo_url -notmatch "github.com/") {
                Write-Host "Invalid URL format. Please use a GitHub repository URL."
                continue
            }

            # Test if repository exists and is accessible
            git ls-remote $repo_url 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error: Repository does not exist or is not accessible. Please check:"
                Write-Host "- Repository URL is correct"
                Write-Host "- Repository exists on GitHub"
                Write-Host "- You have access rights to the repository"
                continue
            }

            break
        } while ($true)

        git remote add origin $repo_url
        Write-Host "Remote origin added successfully.`n"
    }
}

function Test-RemoteChangesStatus {
    $script:remote_changes_available = $false
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        $current_branch = git branch --show-current
        git fetch origin 2>$null

        # Check if we have any commits and remote branch exists
        git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            git rev-parse "origin/$current_branch" 2>$null
            if ($LASTEXITCODE -eq 0) {
                # Check if there are changes available on remote
                git diff HEAD "origin/$current_branch" --quiet 2>$null
                if ($LASTEXITCODE -ne 0) {
                    $script:remote_changes_available = $true
                }
            }
        }
    }
}

function Test-RemoteChanges {
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        $current_branch = git branch --show-current
        git fetch origin 2>$null

        # Check if we have any commits in the local repository
        git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [OK] New repository - no remote comparison needed" -ForegroundColor Green
            return
        }

        # Check if remote branch exists
        git rev-parse "origin/$current_branch" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [OK] Remote branch origin/$current_branch not found - first push will create it" -ForegroundColor Yellow
            return
        }

        # Check if there are changes available on remote
        git diff HEAD "origin/$current_branch" --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [NOTICE] Remote changes available" -ForegroundColor Yellow
        } else {
            Write-Host "  [OK] Already up to date with remote" -ForegroundColor Green
        }
    } else {
        Write-Host "No remote origin configured. Skipping check."
    }
}

function Get-LatestChanges {
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        $current_branch = git branch --show-current
        git pull origin $current_branch --no-edit --allow-unrelated-histories 2>$null
    }
}

function Get-RepositoryStatusLine {
    # Get repository name from remote URL
    $repo_name = "local"
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        $repo_url = git config --get remote.origin.url
        if ($repo_url -match "github\.com[:/](.+)\.git") {
            $repo_name = $matches[1]
        } elseif ($repo_url -match "github\.com[:/](.+)") {
            $repo_name = $matches[1]
        }
    }

    # Get current branch
    $current_branch = git branch --show-current 2>$null
    if (-not $current_branch) {
        $current_branch = "unknown"
    }

    # Count file changes
    $status_output = git status --porcelain 2>$null
    $modified_count = 0
    $staged_count = 0
    $untracked_count = 0

    if ($status_output) {
        foreach ($line in $status_output) {
            if ($line -match "^M ") { $modified_count++ }
            elseif ($line -match "^ M") { $modified_count++ }
            elseif ($line -match "^A ") { $staged_count++ }
            elseif ($line -match "^\?\?") { $untracked_count++ }
            elseif ($line -match "^.M") { $modified_count++ }
        }
    }

    # Determine file status text
    $total_changes = $modified_count + $staged_count + $untracked_count
    if ($total_changes -eq 0) {
        $file_status = "clean"
    } else {
        $file_status = "$total_changes modified"
    }

    # Check sync status with remote
    $sync_status = "up to date"
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0) {
        git fetch origin 2>$null
        git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            git rev-parse "origin/$current_branch" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $ahead = (git rev-list --count HEAD..origin/$current_branch 2>$null)
                $behind = (git rev-list --count origin/$current_branch..HEAD 2>$null)

                if ($ahead -and $behind -and $ahead -gt 0 -and $behind -gt 0) {
                    $sync_status = "diverged"
                } elseif ($ahead -and $ahead -gt 0) {
                    $sync_status = "$ahead behind"
                } elseif ($behind -and $behind -gt 0) {
                    $sync_status = "$behind ahead"
                }
            } else {
                $sync_status = "no remote branch"
            }
        }
    } else {
        $sync_status = "no remote"
    }

    return "$repo_name | $current_branch | $file_status | $sync_status"
}

function Show-MenuDisplay {
    param($status_line)
    Clear-Host
    Write-Host "Current directory: $(Get-Location)"

    # Show cached repository status line
    Write-Host $status_line

    Write-Host "`nSelect an option:`n"

    switch ($script:menu_selection) {
        1 {
            Write-Host "  > Commit Changes Now" -ForegroundColor Green
            if ($script:remote_changes_available -eq $true) {
                Write-Host "    Pull Changes from Remote" -ForegroundColor Blue
            } else {
                Write-Host "    Pull Changes from Remote"
            }
            Write-Host "    Auto-Monitor Mode"
            Write-Host "    Hard Reset to Remote"
            Write-Host "    Force Push to Remote"
        }
        2 {
            Write-Host "    Commit Changes Now"
            if ($script:remote_changes_available -eq $true) {
                Write-Host "  > Pull Changes from Remote" -ForegroundColor Blue
            } else {
                Write-Host "  > Pull Changes from Remote" -ForegroundColor Cyan
            }
            Write-Host "    Auto-Monitor Mode"
            Write-Host "    Hard Reset to Remote"
            Write-Host "    Force Push to Remote"
        }
        3 {
            Write-Host "    Commit Changes Now"
            if ($script:remote_changes_available -eq $true) {
                Write-Host "    Pull Changes from Remote" -ForegroundColor Blue
            } else {
                Write-Host "    Pull Changes from Remote"
            }
            Write-Host "  > Auto-Monitor Mode" -ForegroundColor Green
            Write-Host "    Hard Reset to Remote"
            Write-Host "    Force Push to Remote"
        }
        4 {
            Write-Host "    Commit Changes Now"
            if ($script:remote_changes_available -eq $true) {
                Write-Host "    Pull Changes from Remote" -ForegroundColor Blue
            } else {
                Write-Host "    Pull Changes from Remote"
            }
            Write-Host "    Auto-Monitor Mode"
            Write-Host "  > Hard Reset to Remote" -ForegroundColor Red
            Write-Host "    Force Push to Remote"
        }
        5 {
            Write-Host "    Commit Changes Now"
            if ($script:remote_changes_available -eq $true) {
                Write-Host "    Pull Changes from Remote" -ForegroundColor Blue
            } else {
                Write-Host "    Pull Changes from Remote"
            }
            Write-Host "    Auto-Monitor Mode"
            Write-Host "    Hard Reset to Remote"
            Write-Host "  > Force Push to Remote" -ForegroundColor Red
        }
    }

    Write-Host "`nUse UP/DOWN arrow keys to navigate, ENTER to select, ESC to exit"
}

function Start-MenuLoop {
    param($status_line)
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        switch ($key.VirtualKeyCode) {
            13 { # ENTER
                Invoke-ProcessSelection
                break
            }
            27 { # ESC
                exit
            }
            38 { # UP
                if ($script:menu_selection -eq 1) { $script:menu_selection = 5 }
                elseif ($script:menu_selection -eq 2) { $script:menu_selection = 1 }
                elseif ($script:menu_selection -eq 3) { $script:menu_selection = 2 }
                elseif ($script:menu_selection -eq 4) { $script:menu_selection = 3 }
                elseif ($script:menu_selection -eq 5) { $script:menu_selection = 4 }
                Show-MenuDisplay $status_line
            }
            40 { # DOWN
                if ($script:menu_selection -eq 1) { $script:menu_selection = 2 }
                elseif ($script:menu_selection -eq 2) { $script:menu_selection = 3 }
                elseif ($script:menu_selection -eq 3) { $script:menu_selection = 4 }
                elseif ($script:menu_selection -eq 4) { $script:menu_selection = 5 }
                elseif ($script:menu_selection -eq 5) { $script:menu_selection = 1 }
                Show-MenuDisplay $status_line
            }
        }
    }
}

function Show-Menu {
    $script:menu_selection = 1
    # Get repository status once when menu loads
    $status_line = Get-RepositoryStatusLine
    Show-MenuDisplay $status_line
    Start-MenuLoop $status_line
}

function Invoke-ProcessSelection {
    switch ($script:menu_selection) {
        1 {
            $script:auto_mode = $false
            $script:from_menu = $true
            Start-MainScript
        }
        2 {
            Write-Host "`nPull changes mode selected.`n"
            Start-PullRemoteChanges
        }
        3 {
            $script:auto_mode = $true
            Write-Host "Auto-monitoring enabled. Checking for changes every minute..."
            Write-Host "Press ESC to stop monitoring.`n"
            Start-AutoMonitor
        }
        4 {
            Write-Host "`nHard reset mode selected.`n"
            Start-HardResetLocal
        }
        5 {
            Write-Host "`nForce push mode selected.`n"
            Start-ForcePushMode
        }
    }
}

function Start-MainScript {
    # Skip setup display when coming from menu
    if (-not $script:from_menu) {
        Write-Host "GitHub Script v$SCRIPT_VERSION"
        Test-GitInstalled
        Initialize-Repository
        Set-RemoteIfNeeded
        Show-RepositoryStatus
        Get-LatestChanges
        Initialize-LFS
        Test-FileSizes
    } else {
        # Just do essential checks without display
        Test-GitInstalled | Out-Null
        Initialize-Repository | Out-Null
        Set-RemoteIfNeeded | Out-Null
        Test-RemoteChanges | Out-Null
        Initialize-LFS | Out-Null
        Test-FileSizes | Out-Null
    }

    # Prepare commit message
    if (-not $CommitMessage -or $CommitMessage -eq "") {
        $mydate = Get-Date -Format "ddd-MM-dd"
        $mytime = Get-Date -Format "HH:mm"
        $commit_message = "Auto commit $mydate $mytime"
        $auto_generated = $true
    } else {
        $commit_message = $CommitMessage
        $auto_generated = $false
    }

    # Add all files to staging (excluding those now in .gitignore)
    git add .

    Write-Host "`nGit Status:"
    git status --porcelain
    Write-Host "`n"

    # Check if there are changes to commit
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Changes to be committed:"
        git diff --staged --name-only
        Write-Host "`n"

        $confirm_commit = Read-Host "Do you want to commit these changes? (y/n)"
        if ($confirm_commit -ne "y" -and $confirm_commit -ne "Y") {
            Write-Host "Commit cancelled."
            Write-Host "Press any key to return to menu..."
            $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
            Show-Menu
            return
        }

        git commit -m $commit_message
        Write-Host "`n"

        $current_branch = git branch --show-current
        git push -u origin $current_branch
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Push failed. Attempting to pull and merge remote changes..."
            git pull origin $current_branch --no-edit --allow-unrelated-histories
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Merge failed. Please resolve conflicts manually."
            } else {
                Write-Host "Merge successful. Pushing again..."
                git push -u origin $current_branch
            }
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "`nPush failed! Check the error messages above."
            Write-Host "Press any key to exit..."
            $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
            return
        }

        Write-Host "`nCommit completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "No changes to commit."
    }

    Write-Host "Press any key to return to menu..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Show-Menu
}

function Start-AutoMonitor {
    Test-GitInstalled
    Initialize-Repository
    Initialize-LFS | Out-Null
    Set-RemoteIfNeeded

    while ($true) {
        $current_time = Get-Date -Format "HH:mm"

        Write-Host "[$current_time] Checking for remote changes..."
        Test-RemoteChanges

        Test-FileSizes
        git add . 2>$null
        git diff --staged --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[$current_time] Local changes detected. Committing and pushing..."

            $mydate = Get-Date -Format "ddd-MM-dd"
            $commit_message = "Auto commit $mydate $current_time"

            git commit -m $commit_message 2>$null

            $current_branch = git branch --show-current
            git push -u origin $current_branch 2>$null
            if ($LASTEXITCODE -ne 0) {
                git pull origin $current_branch --no-edit --allow-unrelated-histories 2>$null
                git push -u origin $current_branch 2>$null
            }

            Write-Host "[$current_time] Auto-commit completed!"
        } else {
            Write-Host "[$current_time] No local changes detected."
        }

        # Check for ESC key press during 60 second wait
        for ($i = 1; $i -le 60; $i++) {
            Start-Sleep -Seconds 1
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Escape') {
                    Write-Host "`nAuto-monitor stopped. Returning to menu..."
                    Show-Menu
                    return
                }
            }
        }
    }
}

function Start-PullRemoteChanges {
    Test-GitInstalled
    Initialize-Repository
    Initialize-LFS | Out-Null
    Set-RemoteIfNeeded

    Clear-Host
    Write-Host "GitHub Script v$SCRIPT_VERSION - Pull Changes Mode"
    Write-Host "================================================================="
    Write-Host "`n"

    # Check if remote is configured
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot pull from remote without a configured origin."
        Write-Host "Please configure a remote first."
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    $current_branch = git branch --show-current
    git fetch origin 2>$null

    # Check if we have any commits in the local repository
    git rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "New repository - no remote comparison needed" -ForegroundColor Green
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    # Check if remote branch exists
    git rev-parse "origin/$current_branch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Remote branch origin/$current_branch not found" -ForegroundColor Yellow
        Write-Host "First push will create it."
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    # Check if there are changes to pull
    git diff HEAD "origin/$current_branch" --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Remote changes detected:" -ForegroundColor Yellow
        Write-Host "`n"

        # Show what changes are available
        Write-Host "Changes available from remote:"
        git log HEAD..origin/$current_branch --oneline --max-count=5
        Write-Host "`n"

        $confirm_pull = Read-Host "Do you want to pull these changes? (y/n)"
        if ($confirm_pull -ne "y" -and $confirm_pull -ne "Y") {
            Write-Host "Pull cancelled."
            Write-Host "`nPress any key to return to menu..."
            $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
            Show-Menu
            return
        }

        Write-Host "`nPulling updates:" -ForegroundColor Yellow
        Write-Host "`n"

        # Check for uncommitted local changes that would prevent pull
        git diff --quiet
        $diff_result = $LASTEXITCODE
        git diff --cached --quiet
        $cached_diff_result = $LASTEXITCODE
        $local_changes = ($diff_result -ne 0) -or ($cached_diff_result -ne 0)
        if ($local_changes) {
            Write-Host "`nUncommitted local changes detected:" -ForegroundColor Yellow
            Write-Host "========================"
            git status --porcelain
            Write-Host "`nStashing uncommitted changes before pull..."
            git stash push -m "Auto-stash before manual pull"
            $stash_created = $true
        } else {
            $stash_created = $false
        }

        git pull origin $current_branch --no-edit --allow-unrelated-histories --stat

        # Restore stashed changes and check for conflicts
        if ($stash_created) {
            Write-Host "`nRestoring stashed changes..."
            git stash pop 2>$null
            # Check if stash pop created conflicts
            $conflict_files = git ls-files --unmerged
            if ($conflict_files) {
                Write-Host "`nCONFLICTS from restoring local changes!" -ForegroundColor Red
                Write-Host "`nConflicted files:"
                $conflict_files | ForEach-Object { Write-Host "  - $_" }
                Write-Host "`n"
                Start-ConflictResolutionMenu
                return
            }
        }

        # Check if pull resulted in merge conflicts
        $conflict_files = git ls-files --unmerged
        if ($conflict_files) {
            Write-Host "`nMERGE CONFLICTS DETECTED!" -ForegroundColor Red
            Write-Host "`n"
            Write-Host "Conflicted files:"
            $conflict_files | ForEach-Object { Write-Host "  - $_" }
            Write-Host "`n"
            Start-ConflictResolutionMenu
            return
        }

        Write-Host "`nPull completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "Already up to date with remote" -ForegroundColor Green
    }

    Write-Host "`nPress any key to return to menu..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Show-Menu
}

function Start-HardResetLocal {
    Test-GitInstalled
    Initialize-Repository

    Write-Host "GitHub Script v$SCRIPT_VERSION - Hard Reset Mode"
    Write-Host "================================================================"
    Write-Host "`nWARNING: This will PERMANENTLY DELETE all local changes!" -ForegroundColor Red
    Write-Host "Your local repository will be reset to match the remote exactly." -ForegroundColor Yellow
    Write-Host "`nWhat will happen:"
    Write-Host "  1. All uncommitted changes will be lost"
    Write-Host "  2. All local commits not on remote will be lost"
    Write-Host "  3. Working directory will match remote branch exactly"
    Write-Host "`n"

    # Check if remote is configured
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot perform hard reset without a remote repository."
        Write-Host "Please configure a remote first."
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    # Check if remote is accessible
    git fetch origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Cannot fetch from remote!" -ForegroundColor Red
        Write-Host "Remote repository is not accessible or does not exist."
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    # Determine which branch to reset to
    $current_branch = git branch --show-current
    git rev-parse "origin/$current_branch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Try main branch if current branch doesn't exist on remote
        git rev-parse "origin/main" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $reset_branch = "main"
            Write-Host "Note: Current branch ($current_branch) not found on remote." -ForegroundColor Yellow
            Write-Host "Will reset to origin/main instead."
        } else {
            # Try master branch
            git rev-parse "origin/master" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $reset_branch = "master"
                Write-Host "Note: Current branch ($current_branch) not found on remote." -ForegroundColor Yellow
                Write-Host "Will reset to origin/master instead."
            } else {
                Write-Host "ERROR: No suitable remote branch found!" -ForegroundColor Red
                Write-Host "Cannot determine which remote branch to reset to."
                Write-Host "`n"
                Write-Host "Press any key to return to menu..."
                $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
                Show-Menu
                return
            }
        }
    } else {
        $reset_branch = $current_branch
    }

    Write-Host "`nReady to reset to origin/$reset_branch!" -ForegroundColor Cyan
    Write-Host "`n"
    $confirm = Read-Host "Type 'RESET' to confirm (anything else cancels)"

    if ($confirm -ne "RESET") {
        Write-Host "`nReset cancelled."
        Write-Host "`n"
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    Write-Host "`nPerforming hard reset..."
    Write-Host "`n"

    # Abort any ongoing merge/rebase
    git merge --abort 2>$null
    git rebase --abort 2>$null

    # Clean working directory
    Write-Host "Cleaning working directory..."
    git clean -fd
    git reset --hard HEAD

    # Switch to target branch and reset
    Write-Host "Switching to $reset_branch branch..."
    git checkout $reset_branch 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating $reset_branch branch from origin/$reset_branch..."
        git checkout -b $reset_branch "origin/$reset_branch"
    }

    # Hard reset to remote
    Write-Host "Resetting to origin/$reset_branch..."
    git reset --hard "origin/$reset_branch"

    # Clean any remaining untracked files
    git clean -fd

    Write-Host "`nHard reset completed successfully!" -ForegroundColor Green
    Write-Host "Local repository now matches origin/$reset_branch!" -ForegroundColor Green
    Write-Host "`nRepository status:"
    $status = git status --porcelain
    if (-not $status) {
        Write-Host "  Working directory is clean"
    } else {
        git status --porcelain
    }

    Write-Host "`nPress any key to return to menu..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Show-Menu
}

function Start-ForcePushMode {
    Write-Host "GitHub Script v$SCRIPT_VERSION - Force Push Mode"
    Write-Host "=============================================================="
    Write-Host "`nWARNING: This will FORCEFULLY OVERWRITE the remote repository!" -ForegroundColor Red
    Write-Host "Remote will be reset to match your local changes exactly." -ForegroundColor Yellow
    Write-Host "`nWhat will happen:"
    Write-Host "  1. All local changes will be committed"
    Write-Host "  2. Remote repository will be force-pushed to match local"
    Write-Host "  3. Any remote changes not in local will be LOST FOREVER"
    Write-Host "`n"

    Test-GitInstalled
    Initialize-Repository
    Set-RemoteIfNeeded

    # Check if remote is configured
    git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: No remote origin configured!" -ForegroundColor Red
        Write-Host "Cannot perform force push without a remote repository."
        Write-Host "Press any key to exit..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        exit 1
    }

    Write-Host "`n"
    $confirm = Read-Host "Type 'FORCE' to confirm force push (anything else cancels)"

    if ($confirm -ne "FORCE") {
        Write-Host "`nForce push cancelled."
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    Write-Host "`nPerforming force push..."
    Write-Host "`n"

    # Add all changes
    Write-Host "Adding all local changes..."
    git add .

    # Check if there are changes to commit
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Committing all local changes..."
        $mydate = Get-Date -Format "ddd-MM-dd"
        $mytime = Get-Date -Format "HH:mm"
        git commit -m "Force push commit $mydate $mytime"
    } else {
        Write-Host "No new changes to commit."
    }

    # Get current branch
    $current_branch = git branch --show-current

    Write-Host "Force pushing to origin/$current_branch..."
    git push origin $current_branch --force

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nForce push failed! Check the error messages above." -ForegroundColor Red
        Write-Host "Press any key to return to menu..."
        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
        Show-Menu
        return
    }

    Write-Host "`nForce push completed successfully!" -ForegroundColor Green
    Write-Host "Remote repository now matches your local changes exactly!" -ForegroundColor Green

    Write-Host "`nPress any key to return to menu..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Show-Menu
}

function Show-ConflictMenuDisplay {
    Clear-Host
    Write-Host "Conflict Resolution"
    Write-Host "=================="
    Write-Host "`nConflicted files:"
    $conflict_files = git ls-files --unmerged | ForEach-Object { ($_ -split '\s+')[3] } | Sort-Object -Unique
    foreach ($file in $conflict_files) {
        Write-Host "  - $file"
    }
    Write-Host "`n"
    Write-Host "Git status:"
    git status --porcelain | Where-Object { $_ -match "^(UU|AA|DD|AU|UA)" }
    Write-Host "`nChoose how to resolve conflicts:"
    Write-Host "`n"

    # Option 1
    if ($script:conflict_selection -eq 1) {
        Write-Host "  > Keep Remote Version (from GitHub)" -ForegroundColor Green
    } else {
        Write-Host "    Keep Remote Version (from GitHub)"
    }

    # Option 2
    if ($script:conflict_selection -eq 2) {
        Write-Host "  > Keep Local Version (your changes)" -ForegroundColor Green
    } else {
        Write-Host "    Keep Local Version (your changes)"
    }

    # Option 3
    if ($script:conflict_selection -eq 3) {
        Write-Host "  > Manual Resolution (exit to resolve manually)" -ForegroundColor Yellow
    } else {
        Write-Host "    Manual Resolution (exit to resolve manually)"
    }

    Write-Host "`nUse UP/DOWN arrow keys to navigate, ENTER to select, ESC to exit"
}

function Start-ConflictMenuLoop {
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        switch ($key.VirtualKeyCode) {
            13 { # ENTER
                Invoke-ProcessConflictSelection
                return
            }
            27 { # ESC
                Show-Menu
                return
            }
            38 { # UP
                if ($script:conflict_selection -eq 1) {
                    $script:conflict_selection = 3
                } elseif ($script:conflict_selection -eq 2) {
                    $script:conflict_selection = 1
                } else {
                    $script:conflict_selection = 2
                }
                Show-ConflictMenuDisplay
            }
            40 { # DOWN
                if ($script:conflict_selection -eq 1) {
                    $script:conflict_selection = 2
                } elseif ($script:conflict_selection -eq 2) {
                    $script:conflict_selection = 3
                } else {
                    $script:conflict_selection = 1
                }
                Show-ConflictMenuDisplay
            }
        }
    }
}

function Start-ConflictResolutionMenu {
    $script:conflict_selection = 1
    Show-ConflictMenuDisplay
    Start-ConflictMenuLoop
}

function Invoke-ProcessConflictSelection {
    switch ($script:conflict_selection) {
        1 { Resolve-RemoteConflicts }
        2 { Resolve-LocalConflicts }
        3 { Resolve-ManualConflicts }
        default {
            Write-Host "ERROR: Invalid selection"
            Show-Menu
        }
    }
}

function Resolve-RemoteConflicts {
    Write-Host "`nKeeping remote version (from GitHub)..."
    Write-Host "`n"

    # Handle delete/modify conflicts by accepting remote deletions
    $conflict_files = git ls-files --unmerged | ForEach-Object { ($_ -split '\s+')[3] } | Sort-Object -Unique
    foreach ($file in $conflict_files) {
        Write-Host "Resolving conflict for: $file"
        git rm $file 2>$null
        git checkout origin/HEAD -- $file 2>$null
    }
    git add .
    git commit -m "Resolve conflicts by keeping remote version"
    Write-Host "Conflicts resolved using remote version!" -ForegroundColor Green
    Complete-ConflictResolution
}

function Resolve-LocalConflicts {
    Write-Host "`nKeeping local version (your changes)..."
    Write-Host "`n"

    # Handle delete/modify conflicts by keeping local changes
    $conflict_files = git ls-files --unmerged | ForEach-Object { ($_ -split '\s+')[3] } | Sort-Object -Unique
    foreach ($file in $conflict_files) {
        Write-Host "Resolving conflict for: $file"
        git add $file
    }
    git commit -m "Resolve conflicts by keeping local version"
    Write-Host "Conflicts resolved using local version!" -ForegroundColor Green
    Complete-ConflictResolution
}

function Resolve-ManualConflicts {
    Write-Host "`nManual resolution selected. Returning to menu..."
    Write-Host "`n"
    Write-Host "Please resolve conflicts manually, then run the script again." -ForegroundColor Yellow
    Show-Menu
}

function Complete-ConflictResolution {
    Write-Host "`nPress any key to return to menu..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Show-Menu
}

function Start-SetupAndMenu {
    Write-Host "GitHub Script v$SCRIPT_VERSION"
    Test-GitInstalled
    Initialize-Repository
    Set-RemoteIfNeeded
    Show-RepositoryStatus
    Test-RemoteChanges
    Test-RemoteChangesStatus
    Initialize-LFS
    Test-FileSizes
    Write-Host "`n"
    Show-Menu
}

# Main script logic
# Parse command line arguments
switch ($Mode) {
    "--auto" {
        $auto_mode = $true
        Write-Host "GitHub Script v$SCRIPT_VERSION"
        Write-Host "=========================="
        Write-Host "Auto-monitoring enabled. Checking for changes every minute..."
        Write-Host "Press ESC to stop monitoring."
        Write-Host "`n"
        Start-AutoMonitor
    }
    "--commit" {
        $auto_mode = $false
        Write-Host "Current directory: $(Get-Location)"
        Write-Host "`n"
        Start-MainScript
    }
    "--force-push" {
        $auto_mode = $false
        Write-Host "Current directory: $(Get-Location)"
        Write-Host "`n"
        Start-ForcePushMode
    }
    default {
        if ($Mode -and $Mode -ne "") {
            # Custom commit message provided
            $auto_mode = $false
            Write-Host "Current directory: $(Get-Location)"
            Write-Host "`n"
            Start-MainScript
        } else {
            # Run setup steps then show interactive menu
            Start-SetupAndMenu
        }
    }
}

# Check if script was updated and restart if needed
$current_branch = git branch --show-current 2>$null
if ($current_branch) {
    $script_updated = git diff HEAD "origin/$current_branch" --name-only 2>$null | Select-String "commit_to_github.ps1"
    if ($script_updated -and -not $script_restarted) {
        Write-Host "`n"
        Write-Host "Script updated! Restarting with new version..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        & "$PSCommandPath" --restarted @args
        exit
    } elseif ($script_restarted) {
        Write-Host "  [OK] Script restarted with latest version" -ForegroundColor Green
    }
}