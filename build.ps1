# Monta dist/atlas-pg-win-x64.zip: PostgreSQL 17.9 (binários EDB) + pgvector 0.8.7.
# Exige Visual Studio 2022 com as ferramentas C++ x64 e PowerShell 7.

$ErrorActionPreference = 'Stop'

$PgZipName = 'postgresql-17.9-2-windows-x64-binaries.zip'
$PgUrl = "https://get.enterprisedb.com/postgresql/$PgZipName"
$PgVersion = '17.9'
$VectorVersion = '0.8.7'
$VectorUrl = "https://github.com/pgvector/pgvector/archive/refs/tags/v$VectorVersion.tar.gz"
$Vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'

$Root = $PSScriptRoot
$Cache = Join-Path $Root '.cache'
$PgZip = Join-Path $Cache $PgZipName
$Extract = Join-Path $Cache 'pgsql-full'
$PgRoot = Join-Path $Extract 'pgsql'
$VectorTar = Join-Path $Cache "pgvector-$VectorVersion.tar.gz"
$VectorSrc = Join-Path $Cache "pgvector-$VectorVersion"
$Stage = Join-Path $Cache 'stage'
$Dist = Join-Path $Root 'dist'
$OutZip = Join-Path $Dist 'atlas-pg-win-x64.zip'

New-Item -ItemType Directory -Force -Path $Cache, $Dist | Out-Null

function Invoke-Checked([string]$Label, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label falhou (código $LASTEXITCODE)"
    }
}

if (-not (Test-Path $Vcvars)) {
    throw "Não achei o vcvars64.bat em $Vcvars"
}

if (-not (Test-Path $PgZip) -or (Get-Item $PgZip).Length -lt 300MB) {
    Write-Host "Baixando $PgZipName"
    Invoke-Checked 'download do PostgreSQL' { curl.exe -L --fail --retry 3 -o $PgZip $PgUrl }
}

$postgresExe = Join-Path $PgRoot 'bin\postgres.exe'
if (-not (Test-Path $postgresExe)) {
    Write-Host "Extraindo bin, lib, include e share"
    New-Item -ItemType Directory -Force -Path $Extract | Out-Null
    Invoke-Checked 'extrair PostgreSQL' {
        tar.exe -xf $PgZip -C $Extract pgsql/bin pgsql/lib pgsql/include pgsql/share
    }
}

$versionText = & $postgresExe -V
if ($versionText -notmatch [regex]::Escape($PgVersion)) {
    throw "postgres -V devolveu '$versionText', esperava $PgVersion"
}
Write-Host $versionText

if (-not (Test-Path (Join-Path $VectorSrc 'Makefile.win'))) {
    Write-Host "Baixando pgvector $VectorVersion"
    Invoke-Checked 'download do pgvector' { curl.exe -L --fail --retry 3 -o $VectorTar $VectorUrl }
    Invoke-Checked 'extrair pgvector' { tar.exe -xf $VectorTar -C $Cache }
}

Write-Host "Compilando pgvector $VectorVersion"
$nmake = Join-Path $VectorSrc 'build-nmake.cmd'
@(
    '@echo off'
    "call `"$Vcvars`""
    "if errorlevel 1 exit /b 1"
    "set `"PGROOT=$PgRoot`""
    "cd /d `"$VectorSrc`""
    'nmake /F Makefile.win'
    'if errorlevel 1 exit /b 1'
    'nmake /F Makefile.win install'
    'if errorlevel 1 exit /b 1'
) | Set-Content -Path $nmake -Encoding ascii
Invoke-Checked 'nmake pgvector' { cmd.exe /c $nmake }

$required = @(
    'lib\vector.dll'
    'share\extension\vector.control'
    'share\extension\vector--0.8.7.sql'
    'share\extension\unaccent--1.1.sql'
    'share\extension\pgcrypto--1.3.sql'
    'share\extension\btree_gist--1.6--1.7.sql'
    'share\extension\pg_trgm--1.5--1.6.sql'
    'share\extension\postgres_fdw--1.0--1.1.sql'
    'share\tsearch_data\portuguese.stop'
)
foreach ($rel in $required) {
    if (-not (Test-Path (Join-Path $PgRoot $rel))) {
        throw "Prefixo sem $rel"
    }
}
foreach ($pair in @(
        @{ File = 'share\extension\btree_gist.control'; Version = '1.7' }
        @{ File = 'share\extension\pg_trgm.control'; Version = '1.6' }
        @{ File = 'share\extension\pgcrypto.control'; Version = '1.3' }
        @{ File = 'share\extension\postgres_fdw.control'; Version = '1.1' }
        @{ File = 'share\extension\unaccent.control'; Version = '1.1' }
        @{ File = 'share\extension\vector.control'; Version = '0.8.7' }
    )) {
    $text = Get-Content (Join-Path $PgRoot $pair.File) -Raw
    if ($text -notmatch "default_version\s*=\s*'$([regex]::Escape($pair.Version))'") {
        throw "$($pair.File) não está na versão $($pair.Version)"
    }
}

if (Test-Path $Stage) {
    Remove-Item -Recurse -Force $Stage
}
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
$robo = @('/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XF', '*.pdb', '*.lib', '*.exp')
foreach ($dir in @('bin', 'lib', 'share')) {
    & robocopy.exe (Join-Path $PgRoot $dir) (Join-Path $Stage $dir) @robo | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy de $dir falhou (código $LASTEXITCODE)"
    }
}
@(
    'atlas-pg windows-x64'
    "postgresql $PgVersion ($PgZipName)"
    "pgvector $VectorVersion"
) | Set-Content -Path (Join-Path $Stage 'VERSION.txt') -Encoding utf8
Copy-Item (Join-Path $Root 'COPYRIGHT') (Join-Path $Stage 'COPYRIGHT')

if (Test-Path $OutZip) {
    Remove-Item -Force $OutZip
}
Write-Host "Compactando $OutZip"
Invoke-Checked 'zip' { tar.exe -a -c -f $OutZip -C $Stage . }
$hash = (Get-FileHash -Algorithm SHA256 $OutZip).Hash.ToLower()
Write-Host "SHA256 $hash"
Write-Host "DONE $OutZip"
