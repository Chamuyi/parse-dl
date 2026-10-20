# 生成 C++/WinRT 投影（Windows App SDK 的 MicaController / DesktopAcrylicController）
#
# 为什么需要这一步：NuGet 包只提供 .winmd 元数据，不提供 C++ 头文件。
# C++/WinRT 的头必须用 SDK 自带的 cppwinrt.exe 从元数据生成。
#
# 产物落在 windows/winrt_projection/（已在 windows/.gitignore 里排除，不入库）。
# 幂等：投影已存在且四个关键类型都在就直接跳过，不重复生成。
$ErrorActionPreference = 'Stop'

# 脚本位于 windows/ 下，产物也要落在 windows/winrt_projection/（CMake 从这里取）。
$root   = $PSScriptRoot
$outDir = Join-Path $root 'winrt_projection'
$wasdk  = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.windowsappsdk\1.7.250606001'
$sdkBin = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\cppwinrt.exe'
$winmd  = 'C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.26100.0\Windows.winmd'

function Test-Projection {
    param([string]$dir)
    $required = @(
        'winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h',
        'winrt/Microsoft.UI.Dispatching.h',
        'winrt/Windows.UI.Composition.Desktop.h',
        'winrt/Microsoft.UI.Composition.Interop.h'
    )
    foreach ($rel in $required) {
        if (-not (Test-Path (Join-Path $dir $rel))) { return $false }
    }
    return $true
}

if (Test-Projection $outDir) {
    Write-Host "[gen_winrt_projection] projection already present, skipping"
    exit 0
}

if (-not (Test-Path $sdkBin)) {
    Write-Error "cppwinrt.exe not found at $sdkBin"
    exit 1
}
if (-not (Test-Path $wasdk)) {
    Write-Error "Windows App SDK NuGet package not found at $wasdk"
    exit 1
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$inputs = @(
    (Join-Path $wasdk 'lib\uap10.0.17763\Microsoft.UI.winmd'),
    (Join-Path $wasdk 'lib\uap10.0.17763\Microsoft.Foundation.winmd'),
    (Join-Path $wasdk 'lib\uap10.0.17763\Microsoft.Graphics.winmd')
)
$args = @()
foreach ($i in $inputs) { $args += '-input'; $args += $i }
$args += '-reference'; $args += $winmd
$args += '-output';    $args += $outDir

Write-Host "[gen_winrt_projection] running cppwinrt..."
& $sdkBin @args
if ($LASTEXITCODE -ne 0) {
    Write-Error "cppwinrt failed with exit code $LASTEXITCODE"
    exit 1
}

# 自检：四个关键类型必须真的生成出来，否则后面的编译会以难懂的方式失败。
$checks = @{
    'MicaController'            = 'winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h'
    'DesktopAcrylicController'  = 'winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h'
    'MicaKind'                  = 'winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h'
    'DesktopAcrylicKind'        = 'winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h'
}
foreach ($name in $checks.Keys) {
    $file = Join-Path $outDir $checks[$name]
    if (-not (Select-String -Path $file -Pattern $name -SimpleMatch -Quiet)) {
        Write-Error "projection self-check failed: $name missing from $file"
        exit 1
    }
}

Write-Host "[gen_winrt_projection] done -> $outDir"
