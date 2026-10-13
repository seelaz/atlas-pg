# Constrói dist/atlas-pg-linux-x64.tar.gz dentro do Docker.
# A imagem padrão é manylinux_2_28 (glibc 2.28). O vault do CentOS 7
# recusou o yum da manylinux2014, então o piso ficou 2.28.

param(
    [string]$Image = 'quay.io/pypa/manylinux_2_28_x86_64',
    [string]$GlibcFloor = '2.28'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'dist') | Out-Null

Write-Host "Imagem $Image (glibc $GlibcFloor)"
docker pull $Image
if ($LASTEXITCODE -ne 0) { throw "docker pull falhou ($LASTEXITCODE)" }

docker run --rm `
    -e "IMAGE_GLIBC=$GlibcFloor" `
    -v "${Root}:/work" `
    -w /work `
    $Image `
    bash -lc "sed -i 's/\r$//' /work/build-linux.sh && bash /work/build-linux.sh"
if ($LASTEXITCODE -ne 0) { throw "build linux falhou ($LASTEXITCODE)" }

$tar = Join-Path $Root 'dist\atlas-pg-linux-x64.tar.gz'
$hash = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLower()
Write-Host "SHA256 $hash"
Write-Host $tar
