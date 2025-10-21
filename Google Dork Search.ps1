<# GoogleDorkSearch.ps1
   Google-colored UI version (light default + Google palette accents)
   Run:
     powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\GoogleDorkSearch.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------
# Ensure STA (WinForms)
# ---------------------------
try { $ap = [System.Threading.Thread]::CurrentThread.ApartmentState.ToString() } catch { $ap = 'Unknown' }
if ($ap -ne 'STA') {
    [System.Windows.Forms.MessageBox]::Show("Please run PowerShell with -STA.`nExample:`n  powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\GoogleDorkSearch.ps1","Requires STA",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    return
}
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------
# Determine a safe script folder (works for .ps1 and packaged EXE)
# ---------------------------
try {
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } elseif ($PSScriptRoot) {
        $scriptDir = $PSScriptRoot
    } else {
        $entry = [System.Reflection.Assembly]::GetEntryAssembly()
        if ($entry -ne $null) {
            $scriptDir = [System.IO.Path]::GetDirectoryName($entry.Location)
        } else {
            $scriptDir = [Environment]::GetFolderPath('MyDocuments')
        }
    }
} catch {
    $scriptDir = [Environment]::GetFolderPath('MyDocuments')
}

$historyFile = Join-Path -Path $scriptDir -ChildPath 'gds_history.txt'
$maxHistory = 10
$logFile = Join-Path $scriptDir 'gds_error.log'
$binFolder = Join-Path $scriptDir 'bin'

function Write-Log { param([string]$msg) try { $t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Add-Content -Path $logFile -Value "$t`t$msg" -ErrorAction SilentlyContinue } catch {} }

# ---------------------------
# Default (embedded) dorks - used as fallback
# ---------------------------
$DefaultDorks = @(
    @{Label='Exact phrase "{q}"'; Pattern='"{q}"'},
    @{Label='Any keyword {q} (no quotes)'; Pattern='{q}'},
    @{Label='All in text'; Pattern='allintext:"{q}"'},
    @{Label='In URL'; Pattern='inurl:{q}'},
    @{Label='Exact in URL (quoted)'; Pattern='inurl:"{q}"'},
    @{Label='Page title contains'; Pattern='intitle:"{q}"'},
    @{Label='All in title (multiple words)'; Pattern='allintitle:"{q}"'},
    @{Label='Index of (directory)'; Pattern='intitle:"index of" "{q}"'},

    @{Label='YouTube tutorials'; Pattern='site:youtube.com "{model}" repair OR tutorial OR "{error}"'},
    @{Label='XDA / developer forums'; Pattern='site:forum.xda-developers.com "{model}" OR "{model}" "{chip}"'},
    @{Label='GSMHosting forums'; Pattern='site:gsmhosting.com "{model}" OR "{model}" "{chip}" OR "{error}"'},
    @{Label='Reddit repair threads'; Pattern='site:reddit.com "{model}" repair OR "{error}"'},
    @{Label='GitHub projects / tools'; Pattern='site:github.com "{model}" OR "{chip}" repair OR tool'},
    @{Label='Google Drive shared files'; Pattern='site:drive.google.com "{model}" schematic OR "{model}" service manual'},

    @{Label='PDF files'; Pattern='filetype:pdf "{q}"'},
    @{Label='DOC / DOCX files'; Pattern='filetype:doc OR filetype:docx "{q}"'},
    @{Label='XLS / XLSX files'; Pattern='filetype:xls OR filetype:xlsx "{q}"'},
    @{Label='PPT / PPTX files'; Pattern='filetype:ppt OR filetype:pptx "{q}"'},
    @{Label='CSV or TXT files'; Pattern='filetype:csv OR filetype:txt "{q}"'},

    @{Label='Diagrams / schematics (images)'; Pattern='filetype:jpg OR filetype:png OR filetype:svg "{q} schematic" OR "{q} diagram" OR "{q}" "board view"'},
    @{Label='PCB / Boardview images'; Pattern='filetype:jpg OR filetype:png "{q}" "board view" OR "{q}" boardview'},
    @{Label='FPC / Flex cable diagrams'; Pattern='filetype:jpg OR filetype:png "{q}" FPC OR "flex cable" OR "flex cable diagram"'},
    @{Label='Schematics / diagrams (PDF/JPG)'; Pattern='filetype:pdf OR filetype:jpg "{q} schematic" OR "{q} diagram"'},
    @{Label='Block diagrams / flowcharts'; Pattern='filetype:pdf OR filetype:png "{q}" "block diagram" OR "{q}" "flowchart"'},

    @{Label='GitHub repos'; Pattern='site:github.com "{q}"'},
    @{Label='GitLab projects'; Pattern='site:gitlab.com "{q}"'},
    @{Label='Gists (GitHub)'; Pattern='site:gist.github.com "{q}"'},
    @{Label='Paste sites (Pastebin)'; Pattern='site:pastebin.com "{q}"'},
    @{Label='Google Drive shared files (duplicate)'; Pattern='site:drive.google.com "{q}"'},

    @{Label='Firmware files (zip/rar)'; Pattern='filetype:zip OR filetype:rar "{q} firmware"'},
    @{Label='ROMs / Stock Firmware'; Pattern='"{q}" ROM OR "Stock ROM" filetype:zip'},
    @{Label='Flash tools download'; Pattern='"{q}" flash tool download'},
    @{Label='Driver files (exe/inf)'; Pattern='filetype:exe OR filetype:inf "{q} driver"'},
    @{Label='Updates / patches (zip)'; Pattern='"{q}" update filetype:zip'},

    @{Label='PDF manuals / service manual'; Pattern='filetype:pdf "{q} service manual"'},
    @{Label='Datasheets'; Pattern='filetype:pdf "{q} datasheet"'},

    @{Label='XDA / Mobile forums'; Pattern='site:forum.xda-developers.com "{q}"'},
    @{Label='Tech / Computer forums'; Pattern='site:techsupportforum.com "{q}"'},
    @{Label='Stack Overflow questions'; Pattern='site:stackoverflow.com/questions "{q}"'},
    @{Label='Reddit repair / troubleshoot'; Pattern='site:reddit.com "{q}" repair OR troubleshoot'},
    @{Label='Blog guides / instructables'; Pattern='site:medium.com OR site:instructables.com "{q}" repair'},

    @{Label='In text (plain)'; Pattern='intext:{q}'},
    @{Label='In anchor text'; Pattern='inanchor:"{q}"'},
    @{Label='All in anchor (multiple words)'; Pattern='allinanchor:"{q}"'},
    @{Label='Proximity (within 5 words)'; Pattern='"{q}" AROUND(5) "{q2}"'},
    @{Label='Exclude term (use -term)'; Pattern='{q} -example'},
    @{Label='Combine multiple tokens (OR)'; Pattern='("{q}" OR "fbr-29" OR "fbr_29")'},
    @{Label='Combine tokens (AND)'; Pattern='"{q}" AND "{q2}"'}
)

# ---------------------------
# Dynamic Dork loader (bin\)
# ---------------------------
function Load-DorksFromBin {
    param(
        [string]$BinFolder
    )
    $dorks = @()

    try {
        if (-not (Test-Path $BinFolder)) {
            New-Item -Path $BinFolder -ItemType Directory -Force | Out-Null
        }

        $jsonPath = Join-Path $BinFolder 'dorks.json'
        $txtPath  = Join-Path $BinFolder 'dorks.txt'

        if (Test-Path $jsonPath) {
            try {
                $txt = Get-Content -Path $jsonPath -Raw -ErrorAction Stop
                $parsed = ConvertFrom-Json -InputObject $txt -ErrorAction Stop
                foreach ($p in $parsed) {
                    if ($p.Label -and $p.Pattern) {
                        $dorks += @{ Label = [string]$p.Label; Pattern = [string]$p.Pattern }
                    }
                }
                if ($dorks.Count -gt 0) { Write-Log "Loaded $($dorks.Count) dorks from dorks.json"; return $dorks }
            } catch {
                Write-Log "Failed parsing dorks.json: $($_.Exception.Message)"
            }
        }

        if (Test-Path $txtPath) {
            try {
                $lines = Get-Content -Path $txtPath -ErrorAction Stop
                foreach ($line in $lines) {
                    $ln = $line.Trim()
                    if (-not $ln -or $ln.StartsWith('#')) { continue }
                    # Expect: Label|Pattern
                    $parts = $ln -split '\|' , 2
                    if ($parts.Count -ge 2) {
                        $label = $parts[0].Trim()
                        $pattern = $parts[1].Trim()
                        if ($label -and $pattern) {
                            $dorks += @{ Label = $label; Pattern = $pattern }
                        }
                    } else {
                        Write-Log "Skipping malformed dork line: $ln"
                    }
                }
                if ($dorks.Count -gt 0) { Write-Log "Loaded $($dorks.Count) dorks from dorks.txt"; return $dorks }
            } catch {
                Write-Log "Failed reading dorks.txt: $($_.Exception.Message)"
            }
        }

    } catch {
        Write-Log "Load-DorksFromBin error: $($_.Exception.Message)"
    }

    # fallback: return empty -> caller will apply DefaultDorks
    return $dorks
}

# Try to load dorks from bin; fallback to default
$Loaded = Load-DorksFromBin -BinFolder $binFolder
if ($Loaded -and $Loaded.Count -gt 0) {
    $Dorks = $Loaded
} else {
    $Dorks = $DefaultDorks
    Write-Log "Using embedded default dorks (no valid external dorks found)."
}

# ---------------------------
# Google palette + colors
# ---------------------------
$gBlue   = [System.Drawing.Color]::FromArgb(66,133,244)
$gRed    = [System.Drawing.Color]::FromArgb(219,68,55)
$gYellow = [System.Drawing.Color]::FromArgb(244,180,0)
$gGreen  = [System.Drawing.Color]::FromArgb(15,157,88)
$bgWhite = [System.Drawing.Color]::FromArgb(250,250,250)
$textDark= [System.Drawing.Color]::FromArgb(34,34,34)
$inputBg = [System.Drawing.Color]::White
$darkBg  = [System.Drawing.Color]::FromArgb(24,26,27)
$darkText= [System.Drawing.Color]::FromArgb(230,230,230)

# ---------------------------
# Themes
# ---------------------------
$themes = @{
    GoogleLight = @{
        FormBack = $bgWhite; Fore = $textDark; Accent = $gBlue; BtnText = [System.Drawing.Color]::White; InputBg = $inputBg
    }
    Dark = @{
        FormBack = $darkBg; Fore = $darkText; Accent = $gGreen; BtnText = [System.Drawing.Color]::Black; InputBg = [System.Drawing.Color]::FromArgb(40,44,48)
    }
}
$currentTheme = 'GoogleLight'

# ---------------------------
# Build UI
# ---------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Google Dork Search by drox-Ph-Ceb'
$form.Size = New-Object System.Drawing.Size(820,440)
$form.StartPosition = 'CenterScreen'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ShowIcon = $false
$form.ShowInTaskbar = $true
$form.KeyPreview = $true

# Logo (Google colors)
$logoColors = @($gBlue,$gRed,$gYellow,$gGreen)
for ($i = 0; $i -lt $logoColors.Count; $i++) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(12,12)
    $p.Location = New-Object System.Drawing.Point([int](18 + ($i*16)),18)
    $p.BackColor = $logoColors[$i]
    $form.Controls.Add($p)
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Google Dork Search'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(95,12)
$form.Controls.Add($lblTitle)

# Pattern label & combo
$lblPattern = New-Object System.Windows.Forms.Label
$lblPattern.Text = 'Choose dork pattern:'
$lblPattern.AutoSize = $true
$lblPattern.Location = New-Object System.Drawing.Point(19,48)
$form.Controls.Add($lblPattern)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.Location = New-Object System.Drawing.Point(18,82)
$combo.Size = New-Object System.Drawing.Size(560,28)
$combo.DropDownStyle = 'DropDownList'
$form.Controls.Add($combo)

$note = New-Object System.Windows.Forms.Label
$note.Text = "For Donation: Gcash 09451035299"
$note.AutoSize = $true
$note.Font = New-Object System.Drawing.Font("Segoe UI",8,[System.Drawing.FontStyle]::Italic)
$note.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#FFFF00")
$note.Location = New-Object System.Drawing.Point(600,365)
$form.Controls.Add($note)

# Term + paste
$lblTerm = New-Object System.Windows.Forms.Label
$lblTerm.Text = 'Search term / token:'
$lblTerm.AutoSize = $true
$lblTerm.Location = New-Object System.Drawing.Point(18,120)
$form.Controls.Add($lblTerm)

$txtTerm = New-Object System.Windows.Forms.TextBox
$txtTerm.Location = New-Object System.Drawing.Point(18,140)
$txtTerm.Size = New-Object System.Drawing.Size(480,26)
$form.Controls.Add($txtTerm)

$btnPaste = New-Object System.Windows.Forms.Button
$btnPaste.Text = 'Paste'
$btnPaste.Location = New-Object System.Drawing.Point(506,140)
$btnPaste.Size = New-Object System.Drawing.Size(72,26)
$btnPaste.Tag = 'Accent'
# Make yellow visible across themes:
$btnPaste.FlatStyle = 'Flat'
$btnPaste.UseVisualStyleBackColor = $false
$btnPaste.BackColor = $gYellow
$btnPaste.ForeColor = [System.Drawing.Color]::Black
$btnPaste.FlatAppearance.BorderSize = 0
$btnPaste.Add_Click({
    try {
        $clip = [System.Windows.Forms.Clipboard]::GetText()
        if ($clip -ne $null -and $clip.Trim() -ne '') { $txtTerm.Text = $clip }
    } catch {
        Write-Log "Clipboard paste failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Cannot access clipboard: $($_.Exception.Message)","Clipboard error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})
$form.Controls.Add($btnPaste)

# Query preview (read-only)
$lblPreview = New-Object System.Windows.Forms.Label
$lblPreview.Text = 'Query preview:'
$lblPreview.Location = New-Object System.Drawing.Point(18,176)
$form.Controls.Add($lblPreview)

$txtPreview = New-Object System.Windows.Forms.TextBox
$txtPreview.Location = New-Object System.Drawing.Point(18,196)
$txtPreview.Size = New-Object System.Drawing.Size(560,28)
$txtPreview.ReadOnly = $true
$form.Controls.Add($txtPreview)

# Accent button factory
function New-AccentButton($text,$x,$y,$w=120,$h=36,$color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($w,$h)
    $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Tag = 'Accent'
    # keep Accent colors visible:
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderSize = 0
    return $b
}

$btnSearch = New-AccentButton 'Search Google' 18 240 140 40 $gBlue; $form.Controls.Add($btnSearch)
$btnCopy   = New-AccentButton 'Copy Query'   168 240 120 40 $gGreen; $form.Controls.Add($btnCopy)
$btnClear  = New-AccentButton 'Clear History' 298 240 120 40 $gYellow; $btnClear.ForeColor = [System.Drawing.Color]::Black; $form.Controls.Add($btnClear)
$btnClose  = New-AccentButton 'Close'        428 240 120 40 $gRed; $form.Controls.Add($btnClose)

# Theme toggle + history placed up (after removing custom)
$chkTheme = New-Object System.Windows.Forms.CheckBox
$chkTheme.Location = New-Object System.Drawing.Point(600,50)
$chkTheme.Text = 'Dark theme (toggle)'
$chkTheme.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($chkTheme)

$lblHistory = New-Object System.Windows.Forms.Label
$lblHistory.Text = 'History (click to reuse):'
$lblHistory.Location = New-Object System.Drawing.Point(600,105)
$form.Controls.Add($lblHistory)

$lstHistory = New-Object System.Windows.Forms.ComboBox
$lstHistory.Location = New-Object System.Drawing.Point(600,138)
$lstHistory.Size = New-Object System.Drawing.Size(200,28)
$lstHistory.DropDownStyle = 'DropDownList'
$form.Controls.Add($lstHistory)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = 'Tip: selected pattern uses {q} for the token. History saved to gds_history.txt. External dorks: bin\dorks.json or bin\dorks.txt'
$lblInfo.Location = New-Object System.Drawing.Point(18,300)
$lblInfo.Size = New-Object System.Drawing.Size(760,18)
$form.Controls.Add($lblInfo)

# ---------------------------
# Build Query (flexible)
# - Supports {q}, {q2}, {model}, {chip}, {error}
# - Pipe syntax: token1|token2|token3... (preserves spaces inside tokens)
# - If no pipe present and multiple words are entered, splits on whitespace:
#     q = first word
#     q2 = second word (if present, else q)
#     model = full original input (preserves multi-word model as single value)
# - Use pipe when you need placeholders to contain spaces.
# ---------------------------
function Build-Query {
    param(
        [string]$term,
        [string]$pattern
    )

    try {
        if (-not $pattern) { return '' }
        if (-not $term) { $term = '' }

        # Trim
        $term = $term.Trim()

        $parts = @()

        if ($term -match '\|') {
            # Pipe-specified tokens — preserve spaces inside tokens
            $parts = $term -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        } elseif ($term -ne '') {
            # No pipe: if there are multiple whitespace-separated words, split into words
            # Keep fullTerm for model mapping (preserve spaces)
            $words = $term -split '\s+' | Where-Object { $_ -ne '' }
            if ($words.Count -le 1) {
                $parts = ,$term
            } else {
                # Map words as tokens (each word becomes a token). This allows the second word to populate {q2}
                $parts = $words
            }
        }

        # Prepare mapping for placeholders with sensible defaults
        if ($parts.Count -eq 0) {
            $vals = @{ q=''; q2=''; model=''; chip=''; error='' }
        }
        elseif ($parts.Count -eq 1) {
            # Single token: use it for q and q2; but set model to full original input (keeps multi-word model)
            $vals = @{
                q     = $parts[0]
                q2    = $parts[0]
                model = $term    # full input (useful for multi-word model names)
                chip  = $parts[0]
                error = $parts[0]
            }
        }
        else {
            # Multiple tokens: map from parts (first = q, second = q2, third = model if present...)
            $vals = @{
                q     = ($parts[0] -as [string])
                q2    = (if ($parts.Count -ge 2) { $parts[1] } else { $parts[0] })
                model = (if ($parts.Count -ge 3) { $parts[2] } else { $term }) # default model = full term
                chip  = (if ($parts.Count -ge 4) { $parts[3] } else { $parts[0] })
                error = (if ($parts.Count -ge 5) { $parts[4] } else { $parts[0] })
            }
        }

        # Escape values for regex replacement
        $escaped = @{ }
        foreach ($k in $vals.Keys) { $escaped[$k] = [Regex]::Escape([string]$vals[$k]) }

        $result = $pattern
        # Replace known placeholders
        $result = $result -replace '\{q\}',      $escaped['q']
        $result = $result -replace '\{q2\}',     $escaped['q2']
        $result = $result -replace '\{model\}',  $escaped['model']
        $result = $result -replace '\{chip\}',   $escaped['chip']
        $result = $result -replace '\{error\}',  $escaped['error']

        # Remove any other unreplaced placeholders like {something}
        $result = [Regex]::Replace($result, '\{\s*[^\}]+\s*\}', '')

        return $result
    } catch {
        Write-Log "Build-Query failed: $($_.Exception.Message)"
        return ($pattern -replace '\{q\}',$term)
    }
}


# ---------------------------
# History functions (safe)
# ---------------------------
function Load-History {
    try {
        $lstHistory.Items.Clear()
        if (-not (Test-Path $historyFile)) { return }
        $lines = Get-Content $historyFile | Where-Object { $_ -and $_.Trim() -ne "" }
        foreach ($l in $lines) { [void]$lstHistory.Items.Add($l) }
        if ($lstHistory.Items.Count -gt 0) { $lstHistory.SelectedIndex = 0 }
    } catch {
        Write-Log "Load-History failed: $($_.Exception.Message)"
    }
}

function Save-History($term) {
    if (-not $term) { return }
    try {
        $lines = @()
        if (Test-Path $historyFile) {
            $lines = Get-Content $historyFile | Where-Object { $_ -and $_ -ne $term }
        }
        $lines = ,$term + $lines
        if ($lines.Count -gt $maxHistory) { $lines = $lines[0..($maxHistory-1)] }
        $lines | Set-Content $historyFile -Force
        Load-History
    } catch {
        Write-Log "Save-History failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Failed to save history: $($_.Exception.Message)","Warning",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

# ---------------------------
# Populate dorks safely (from $Dorks loaded earlier)
# ---------------------------
foreach ($d in $Dorks) {
    try { [void]$combo.Items.Add($d.Label) } catch { Write-Log "Add dork item failed: $($_.Exception.Message)" }
}
if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 } else { $combo.SelectedIndex = -1 }

# ---------------------------
# Update preview logic (safe against -1 index)
# ---------------------------
$updatePreview = {
    try {
        $pattern = ''
        if ($combo.SelectedIndex -ge 0 -and $combo.SelectedIndex -lt $Dorks.Count) {
            $pattern = $Dorks[$combo.SelectedIndex].Pattern
        }
        $term = $txtTerm.Text.Trim()
        $txtPreview.Text = Build-Query -term $term -pattern $pattern
    } catch {
        Write-Log "updatePreview failed: $($_.Exception.Message)"
    }
}

# Wire events
$combo.Add_SelectedIndexChanged({
    try {
        $updatePreview.Invoke()
        $txtTerm.Focus()
    } catch {
        Write-Log "combo SelectedIndexChanged handler failed: $($_.Exception.Message)"
    }
})

$txtTerm.Add_TextChanged($updatePreview)

# Enter key triggers the search
$handlerEnter = {
    param($s,$e)
    try {
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            $btnSearch.PerformClick()
        }
    } catch {
        Write-Log "handlerEnter failed: $($_.Exception.Message)"
    }
}
$txtTerm.Add_KeyDown($handlerEnter)

# History selection
$lstHistory.Add_SelectedIndexChanged({
    try {
        if ($lstHistory.SelectedIndex -ge 0) { $txtTerm.Text = $lstHistory.SelectedItem }
    } catch { Write-Log "lstHistory selection failed: $($_.Exception.Message)" }
})

# Copy preview
$btnCopy.Add_Click({
    try { [Windows.Forms.Clipboard]::SetText($txtPreview.Text); [System.Windows.Forms.MessageBox]::Show('Query copied to clipboard.','Copied',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null } catch { Write-Log "Copy failed: $($_.Exception.Message)" }
})

# Clear history
$btnClear.Add_Click({
    try { if (Test-Path $historyFile) { Remove-Item $historyFile -Force } Load-History } catch { Write-Log "Clear history failed: $($_.Exception.Message)" }
})

# Close
$btnClose.Add_Click({ try { $form.Close() } catch { Write-Log "Close failed: $($_.Exception.Message)" } })

# Search action (requires only term)
$btnSearch.Add_Click({
    try {
        $term = $txtTerm.Text.Trim()
        $pattern = ''
        if ($combo.SelectedIndex -ge 0 -and $combo.SelectedIndex -lt $Dorks.Count) { $pattern = $Dorks[$combo.SelectedIndex].Pattern }
        if (-not $term) {
            [Windows.Forms.MessageBox]::Show('Please enter a search term (token).','Missing query',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $query = Build-Query -term $term -pattern $pattern
        Start-Process "https://www.google.com/search?q=$([uri]::EscapeDataString($query))"
        if ($term) { Save-History $term }
    } catch {
        Write-Log "Search click failed: $($_.Exception.Message)`n$($_.Exception.StackTrace)"
        [System.Windows.Forms.MessageBox]::Show("Search failed: $($_.Exception.Message)","Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

# Theme toggle apply function
function Apply-Theme($name) {
    try {
        $p = $themes[$name]
        if (-not $p) { return }
        $form.BackColor = $p.FormBack
        foreach ($c in $form.Controls) {
            switch ($c.GetType().Name) {
                'Label' { $c.ForeColor = $p.Fore }
                'TextBox' { $c.BackColor = $p.InputBg; $c.ForeColor = $p.Fore }
                'ComboBox' { $c.BackColor = $p.InputBg; $c.ForeColor = $p.Fore }
                'Button' {
                    if ($c.Tag -eq 'Accent') {
                        # keep accent colors as-is but ensure readable text
                        $c.ForeColor = [System.Drawing.Color]::White
                    } else {
                        try { $c.BackColor = [System.Drawing.Color]::FromArgb(230,230,230); $c.ForeColor = $p.Fore } catch {}
                    }
                }
                'CheckBox' { $c.ForeColor = $p.Fore }
            }
        }
    } catch {
        Write-Log "Apply-Theme failed: $($_.Exception.Message)"
    }
}

$chkTheme.Add_CheckedChanged({
    try {
        $currentTheme = if ($chkTheme.Checked) { 'Dark' } else { 'GoogleLight' }
        Apply-Theme $currentTheme
    } catch { Write-Log "chkTheme handler failed: $($_.Exception.Message)" }
})

# ---------------------------
# Global exception handling & safe start
# ---------------------------
try {
    [void][System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException( [System.Threading.ThreadExceptionEventHandler]{
        param($sender,$e)
        $text = "UI Thread Exception: $($e.Exception.GetType().FullName) - $($e.Exception.Message)`n$($e.Exception.StackTrace)"
        Write-Log $text
        [System.Windows.Forms.MessageBox]::Show($text,"Application error - UI thread",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    })
    [System.AppDomain]::CurrentDomain.add_UnhandledException( [System.UnhandledExceptionEventHandler]{
        param($sender,$e)
        $ex = $e.ExceptionObject
        $text = "Unhandled Exception: $($ex.GetType().FullName) - $($ex.Message)`n$($ex.StackTrace)"
        Write-Log $text
        try { [System.Windows.Forms.MessageBox]::Show($text,"Application error - Unhandled",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {}
    })
} catch {
    Write-Log "Global exception handler registration failed: $($_.Exception.Message)"
}

# ---------------------------
# Init + show UI (wrapped)
# ---------------------------
try {
    Load-History
    Apply-Theme $currentTheme
    $updatePreview.Invoke()
    [void]$form.ShowDialog()
} catch {
    $err = $_.Exception
    $text = "Startup Exception: $($err.GetType().FullName) - $($err.Message)`n$($err.StackTrace)"
    Write-Log $text
    try { [System.Windows.Forms.MessageBox]::Show($text,"Startup error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {}
}

Write-Log "Application exited normally."
# End of script
