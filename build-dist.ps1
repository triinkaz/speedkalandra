<#
.SYNOPSIS
    Prepara distribuicao limpa do SpeedKalandra sem dados pessoais.

.DESCRIPTION
    Copia o projeto pra um diretorio destino excluindo:
      - speedkalandra.ini         (config pessoal)
      - data/personal_bests.ini   (PBs do usuario)
      - data/speedkalandra.log    (log de execucao)
      - data/runs/                (historico de runs - formato novo)
      - data/run_state.ini        (state de run em andamento, se houver)
      - runs/                     (historico legado CSV na raiz)
      - debug/                    (Client.txt e dumps de diagnostico)
      - BKP/, _LIXEIRA/           (backups e arquivos removidos)
      - .git/, .vscode/, etc      (metadata de dev)
      - *.bak, *.tmp, *.swp, *~   (arquivos temporarios)
      - este proprio script + build-dist.bat
    
    Opcionalmente compila pra .exe via Ahk2Exe e gera um .zip.

.PARAMETER DestDir
    Diretorio destino. Default: ..\SpeedKalandra-dist (irmao do projeto).

.PARAMETER Compile
    Switch. Se passado, compila speedkalandra.ahk pra .exe via Ahk2Exe.
    Procura o compiler em paths padrao da install do AutoHotkey.

.PARAMETER Zip
    Switch. Se passado, cria <DestDir>.zip no final.

.PARAMETER Force
    Switch. Sobrescreve DestDir sem perguntar.

.EXAMPLE
    .\build-dist.ps1
    Copia tudo limpo pra ..\SpeedKalandra-dist e pergunta antes de sobrescrever.

.EXAMPLE
    .\build-dist.ps1 -Compile -Zip -Force
    Build completo: copia, compila .exe, zipa, sem perguntar.

.EXAMPLE
    .\build-dist.ps1 -DestDir "C:\temp\sk-release" -Zip
    Especifica destino custom e gera zip.
#>

[CmdletBinding()]
param(
    [string]$DestDir = "",
    [switch]$Compile,
    [switch]$Zip,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ============================================================
# Resolve paths
# ============================================================

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$SourceDir = $ScriptDir.TrimEnd('\','/')

if (-not $DestDir) {
    $parent = Split-Path -Parent $SourceDir
    $DestDir = Join-Path $parent "SpeedKalandra-dist"
}
$DestDir = $DestDir.TrimEnd('\','/')

# Sanity check: source deve ter speedkalandra.ahk
$entryPoint = Join-Path $SourceDir "speedkalandra.ahk"
if (-not (Test-Path $entryPoint)) {
    Write-Error "Nao achei speedkalandra.ahk em '$SourceDir'.`nRode este script de DENTRO da pasta do projeto SpeedKalandra."
    exit 1
}

# Bloqueio defensivo: dest nao pode ser igual nem ancestor do source
$sourceFull = (Resolve-Path $SourceDir).Path.TrimEnd('\','/')
$destResolvedAttempt = $DestDir
if (-not (Test-Path $DestDir)) {
    # Resolve absoluto manualmente se nao existe
    if (-not [System.IO.Path]::IsPathRooted($DestDir)) {
        $destResolvedAttempt = Join-Path (Get-Location).Path $DestDir
    }
}
else {
    $destResolvedAttempt = (Resolve-Path $DestDir).Path
}
$destFull = $destResolvedAttempt.TrimEnd('\','/')

if ($destFull -ieq $sourceFull) {
    Write-Error "DestDir nao pode ser igual ao SourceDir."
    exit 1
}
if ($sourceFull.StartsWith($destFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "DestDir nao pode ser ancestor do SourceDir (apagaria o projeto)."
    exit 1
}

Write-Host ""
Write-Host "=== SpeedKalandra :: Build Dist ===" -ForegroundColor Cyan
Write-Host "Source : $SourceDir" -ForegroundColor Gray
Write-Host "Dest   : $DestDir" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Limpa dest se existir
# ============================================================

if (Test-Path $DestDir) {
    if (-not $Force) {
        $resp = Read-Host "Dest '$DestDir' ja existe. Sobrescrever? [s/N]"
        if ($resp -notmatch '^[sSyY]') {
            Write-Host "Abortado pelo usuario." -ForegroundColor Yellow
            exit 0
        }
    }
    Write-Host "Removendo dest existente..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force -LiteralPath $DestDir
}

New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

# ============================================================
# Regras de exclusao
# ============================================================

# Diretorios excluidos recursivamente. Match contra caminho RELATIVO
# (ex: "_LIXEIRA", "data\runs"). Comparacao case-insensitive.
$ExcludeDirs = @(
    "_LIXEIRA",
    "BKP",
    "debug",
    "runs",                 # historico legado CSV na raiz
    "data\runs",            # historico novo do RunHistoryRepository
    ".git",
    ".vscode",
    ".idea",
    "node_modules",
    "SpeedKalandra-dist"    # caso o user rode aqui dentro
)

# Arquivos especificos (caminhos relativos ao source)
$ExcludeFiles = @(
    "speedkalandra.ini",
    "data\personal_bests.ini",
    "data\personal_bests.ini.bak",
    "data\speedkalandra.log",
    "data\run_state.ini",
    "speedkalandra_zones.txt",
    "build-dist.ps1",       # este proprio script
    "build-dist.bat",       # wrapper
    ".gitignore",
    ".gitattributes",
    # v17.15.2: docs dev-only (~263KB economizados no dist).
    # README-DIST.txt gerado mais abaixo cobre o user final.
    "ARCHITECTURE.md",
    "AUDITORIA-PRODUCAO.md",
    "README.md",
    "src_v2\README.md"
)

# Patterns de filename (qualquer lugar). Match contra Name do file.
$ExcludePatterns = @(
    "*.bak",
    "*.tmp",
    "*.swp",
    "*~",
    "*.log",                # cobre debug/*.log e qualquer outro
    "Client*.txt"           # logs do PoE2 que o user possa ter copiado
)

# ============================================================
# Helpers
# ============================================================

function Test-IsExcludedDir {
    param([string]$relPath)
    foreach ($exDir in $ExcludeDirs) {
        $exDirNorm = $exDir.Replace('/', '\')
        # Match exato OU prefixo + separador
        if ($relPath -ieq $exDirNorm) { return $true }
        if ($relPath.StartsWith($exDirNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-IsExcludedFile {
    param([string]$relPath, [string]$fileName)
    
    # Match exato no path
    foreach ($exFile in $ExcludeFiles) {
        if ($relPath -ieq $exFile.Replace('/', '\')) { return $true }
    }
    
    # Match em pattern de filename
    foreach ($pattern in $ExcludePatterns) {
        if ($fileName -like $pattern) { return $true }
    }
    
    return $false
}

# ============================================================
# Copia arquivos
# ============================================================

Write-Host "Copiando arquivos (filtrando dados pessoais)..." -ForegroundColor Green

$copied = 0
$skipped = 0
$skippedSamples = @()

Get-ChildItem -Path $SourceDir -Recurse -File | ForEach-Object {
    $file = $_
    $relPath = $file.FullName.Substring($SourceDir.Length).TrimStart('\','/')
    
    # Verifica se esta dentro de um dir excluido
    $relDir = Split-Path -Parent $relPath
    if ($relDir -and (Test-IsExcludedDir -relPath $relDir)) {
        $script:skipped++
        if ($script:skippedSamples.Count -lt 5) {
            $script:skippedSamples += $relPath
        }
        return
    }
    
    # Verifica arquivo especifico ou pattern
    if (Test-IsExcludedFile -relPath $relPath -fileName $file.Name) {
        $script:skipped++
        if ($script:skippedSamples.Count -lt 5) {
            $script:skippedSamples += $relPath
        }
        return
    }
    
    # Copia preservando estrutura
    $destFile = Join-Path $DestDir $relPath
    $destSubDir = Split-Path -Parent $destFile
    if ($destSubDir -and -not (Test-Path $destSubDir)) {
        New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
    $script:copied++
}

Write-Host "  Copiados : $copied arquivos" -ForegroundColor Gray
Write-Host "  Filtrados: $skipped arquivos" -ForegroundColor Gray
if ($skippedSamples.Count -gt 0) {
    Write-Host "  Exemplos filtrados:" -ForegroundColor DarkGray
    foreach ($s in $skippedSamples) {
        Write-Host "    - $s" -ForegroundColor DarkGray
    }
}
Write-Host ""

# ============================================================
# Garante estrutura minima de data/
# ============================================================

$dataDir = Join-Path $DestDir "data"
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
# data/runs/ - garante existencia (RunHistoryRepository cria se faltar mas seguro garantir)
$runsDir = Join-Path $dataDir "runs"
if (-not (Test-Path $runsDir)) {
    New-Item -ItemType Directory -Path $runsDir -Force | Out-Null
    # Cria .keep pra preservar dir no zip
    New-Item -ItemType File -Path (Join-Path $runsDir ".keep") -Force | Out-Null
}

# ============================================================
# README de distribuicao
# ============================================================

$distReadme = Join-Path $DestDir "README-DIST.txt"
$readmeContent = @"
SpeedKalandra - PoE2 Speedrun Tracker
======================================

FIRST RUN:
1. Install AutoHotkey v2: https://www.autohotkey.com/
2. Run speedkalandra.ahk (double-click)
   - If compiled, run SpeedKalandra.exe instead
3. Configure the path to PoE2's Client.txt in Settings (tray icon)
   Typical: C:\Program Files (x86)\Grinding Gear Games\Path of Exile 2\logs\Client.txt

DEFAULT HOTKEYS:
   Ctrl+3        Toggle timer (pause/resume run)
   Ctrl+Alt+N    New run (cancels current)
   Ctrl+Alt+F    Finalize run (saves to history, updates PB)
   Ctrl+5        Reset (cancels current without saving)
   Ctrl+Alt+P    Run plot
   Ctrl+Alt+S    Settings
   F8            Toggle overlay
   Ctrl+F9       Toggle Micro mode

COMPACT OVERLAY:
   LINE 1: Act N . Zone Name . zone_time / total_time
            (timers green when under PB, red when over)
   LINE 2: Lv X . Area Y | XP | PB zone_time / run_time  (teal)
   LINE 3: stacked bar Map/Loading/Town
   Right side: 3 vendor regex buttons (V1/V2/V3, click with Ctrl)

OVERLAY INTERACTION:
   Hold Ctrl to interact with the overlay (drag, resize, click
   buttons). Without Ctrl, clicks pass through to the game.

PERSISTED DATA (created on first run):
   speedkalandra.ini             configuration
   data/personal_bests.ini       PBs per zone + full run
   data/runs/{runId}.ini         history of finalized runs
   data/speedkalandra.log        execution log

Enjoy!
"@
$readmeContent | Out-File -FilePath $distReadme -Encoding UTF8
Write-Host "README-DIST.txt criado." -ForegroundColor Gray

# ============================================================
# Compilacao opcional via Ahk2Exe
# ============================================================

if ($Compile) {
    Write-Host ""
    Write-Host "Compilando .ahk -> .exe via Ahk2Exe..." -ForegroundColor Green
    
    # --- Localiza o Ahk2Exe.exe ---
    $ahk2exePaths = @(
        "$env:ProgramFiles\AutoHotkey\Compiler\Ahk2Exe.exe",
        "$env:ProgramFiles\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\Compiler\Ahk2Exe.exe"
    )
    
    $ahk2exe = $null
    foreach ($p in $ahk2exePaths) {
        if (Test-Path $p) {
            $ahk2exe = $p
            break
        }
    }
    
    # --- Localiza o base file (AutoHotkey64.exe do AHK v2) ---
    # Ahk2Exe precisa de um "base file" pra empacotar o .exe. Pra AHK v2
    # eh o AutoHotkey64.exe (64-bit) ou AutoHotkey32.exe (32-bit) da
    # install do AutoHotkey. Sem isso o Ahk2Exe abre GUI pedindo pra
    # configurar default. Passamos via /base pra ser explicito.
    $baseFilePaths = @(
        # AHK v2 64-bit (preferido)
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey64.exe",
        # AHK v2 32-bit fallback
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey32.exe"
    )
    
    $baseFile = $null
    foreach ($p in $baseFilePaths) {
        if (Test-Path $p) {
            $baseFile = $p
            break
        }
    }
    
    if (-not $ahk2exe) {
        Write-Warning "Ahk2Exe.exe nao encontrado nos paths padrao da install do AutoHotkey."
        Write-Warning "Compile manualmente: clique direito em speedkalandra.ahk -> Compile Script"
    }
    elseif (-not $baseFile) {
        Write-Warning "AutoHotkey64.exe (base file) nao encontrado nos paths padrao."
        Write-Warning "Verifique se o AutoHotkey v2 esta instalado em paths padrao."
        Write-Warning "Alternativamente, abra o Ahk2Exe GUI e configure a base default."
    }
    else {
        $ahkInput  = Join-Path $DestDir "speedkalandra.ahk"
        $exeOutput = Join-Path $DestDir "SpeedKalandra.exe"
        
        Write-Host "  Compiler : $ahk2exe" -ForegroundColor Gray
        Write-Host "  Base file: $baseFile" -ForegroundColor Gray
        Write-Host "  Input    : $ahkInput" -ForegroundColor Gray
        Write-Host "  Output   : $exeOutput" -ForegroundColor Gray
        
        # Ahk2Exe args: /in <input> /out <output> /base <ahk_exe>
        & $ahk2exe /in $ahkInput /out $exeOutput /base $baseFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Ahk2Exe retornou exit code $LASTEXITCODE. Verifique se compilou OK."
        }
        elseif (Test-Path $exeOutput) {
            $exeSize = [Math]::Round((Get-Item $exeOutput).Length / 1MB, 2)
            Write-Host "Compilado OK: $exeOutput ($exeSize MB)" -ForegroundColor Green
        }
        else {
            Write-Warning "Compilacao terminou sem exit code mas .exe nao foi criado."
        }
    }
}

# ============================================================
# Zip opcional
# ============================================================

if ($Zip) {
    Write-Host ""
    Write-Host "Criando zip..." -ForegroundColor Green
    
    $zipPath = "$DestDir.zip"
    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    
    # Compress-Archive aceita wildcard pra incluir conteudo do dir (nao o dir mesmo)
    Compress-Archive -Path "$DestDir\*" -DestinationPath $zipPath -CompressionLevel Optimal
    
    if (Test-Path $zipPath) {
        $zipSize = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host "Zip criado: $zipPath ($zipSize MB)" -ForegroundColor Green
    }
}

# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host "=== Build concluido ===" -ForegroundColor Cyan
Write-Host "Dest: $DestDir" -ForegroundColor White

$totalFiles = (Get-ChildItem -Path $DestDir -Recurse -File).Count
$totalSize  = [Math]::Round(((Get-ChildItem -Path $DestDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
Write-Host "Arquivos: $totalFiles | Tamanho: $totalSize MB" -ForegroundColor Gray
Write-Host ""
