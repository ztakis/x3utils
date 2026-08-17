<#
.SYNOPSIS
  Build both web entry points into one deploy tree for the x3utils-web Pages
  project: the desktop web app at / and the phone build at /m/.

.DESCRIPTION
  Flutter always writes to build/web and overwrites it, so each entry point is
  built in turn and copied out into a staging tree:

      <OutDir>/        lib/main.dart          --base-href /
      <OutDir>/m/      lib/main_mobile.dart   --base-href /m/

  Two separately compiled bundles. They load no JavaScript in common, so one
  cannot break the other at runtime.

  They are NOT smaller than each other. main_mobile.dart reaches the shared
  widget tree through HomeScreen, and the Android/desktop split inside it is a
  runtime flag, which tree-shaking cannot remove. Measured 2026-08-17: / is
  2.86 MB and /m/ is 2.88 MB, so the phone bundle is the whole desktop app plus
  its own entry point. That is the cost of one shared tree; shrinking it would
  need a compile-time split and would reintroduce the duplication the shared
  tree exists to remove.

  Service workers: each build registers one scoped to its own base href, so the
  /m/ worker cannot claim / and the two caches stay separate. That is also why
  --base-href must be passed rather than editing index.html afterwards.

  Deploying is opt-in. Without -Deploy this only produces the tree.

  Deploy uses the global wrangler if one is installed (it is, on this machine)
  and falls back to npx otherwise. There is no package.json here, so npx would
  resolve to the same global binary anyway.

.EXAMPLE
  ./tool/build_web.ps1
  Build both into build/web-deploy and stop.

.EXAMPLE
  ./tool/build_web.ps1 -Deploy
  Build both, then publish to the x3utils-web Pages project via wrangler.
#>

[CmdletBinding()]
param(
    # Staging tree. Relative paths resolve against the Flutter project root.
    [string]$OutDir = 'build/web-deploy',

    # Publish to Cloudflare Pages after a successful build.
    [switch]$Deploy,

    # Pages branch. Anything other than the production branch publishes to a
    # PREVIEW url (<branch>.<project>.pages.dev) and leaves the live site alone.
    # Defaults to a preview so -Deploy can never replace production by accident;
    # publishing for real takes -Branch main, typed deliberately.
    [string]$Branch = 'mobile-preview',

    # Pages project. Matches .wrangler/cache/pages.json.
    [string]$ProjectName = 'x3utils-web'
)

$ErrorActionPreference = 'Stop'

# tool/ lives directly under the Flutter project root.
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if (-not (Test-Path 'pubspec.yaml')) {
        throw "Not a Flutter project root: $projectRoot"
    }

    $staging = if ([System.IO.Path]::IsPathRooted($OutDir)) {
        $OutDir
    } else {
        Join-Path $projectRoot $OutDir
    }

    # Refuse to empty something that is not ours. A stale staging tree must be
    # cleared (an orphaned file from a previous build would otherwise ship), but
    # -Recurse -Force on an operator-supplied path deserves a guard.
    if (Test-Path $staging) {
        if (-not (Test-Path (Join-Path $staging 'flutter_bootstrap.js')) -and
            (Get-ChildItem -Force $staging | Measure-Object).Count -gt 0) {
            throw "$staging is not empty and does not look like a previous web build. Refusing to delete it."
        }
        Remove-Item -Recurse -Force $staging
    }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    function Build-Target {
        param(
            [Parameter(Mandatory)][string]$Target,
            [Parameter(Mandatory)][string]$BaseHref,
            [Parameter(Mandatory)][string]$Destination,
            [Parameter(Mandatory)][string]$Label
        )

        Write-Host ''
        Write-Host "==> $Label  ($Target -> $BaseHref)" -ForegroundColor Cyan

        # build/web is reused by both builds; clear it so nothing from the
        # previous entry point survives into this one's output.
        if (Test-Path 'build/web') { Remove-Item -Recurse -Force 'build/web' }

        flutter build web -t $Target --base-href $BaseHref
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build web failed for $Target (exit $LASTEXITCODE)"
        }
        if (-not (Test-Path 'build/web/index.html')) {
            throw "flutter build web reported success but produced no index.html for $Target"
        }

        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Copy-Item -Path 'build/web/*' -Destination $Destination -Recurse -Force
    }

    # Desktop web first: it owns the root, so the phone build is copied into a
    # subdirectory of an already-populated tree rather than the other way round.
    Build-Target -Target 'lib/main.dart' `
                 -BaseHref '/' `
                 -Destination $staging `
                 -Label 'Desktop web'

    Build-Target -Target 'lib/main_mobile.dart' `
                 -BaseHref '/m/' `
                 -Destination (Join-Path $staging 'm') `
                 -Label 'Phone web'

    $rootJs = Join-Path $staging 'main.dart.js'
    $phoneJs = Join-Path $staging 'm/main.dart.js'
    Write-Host ''
    Write-Host 'Built:' -ForegroundColor Green
    foreach ($pair in @(@('/', $rootJs), @('/m/', $phoneJs))) {
        if (Test-Path $pair[1]) {
            $mb = [math]::Round((Get-Item $pair[1]).Length / 1MB, 2)
            Write-Host ("  {0,-4} {1} MB  {2}" -f $pair[0], $mb, $pair[1])
        }
    }
    Write-Host ''
    Write-Host "Staging tree: $staging"

    if ($Deploy) {
        $isProduction = $Branch -eq 'main'
        Write-Host ''
        if ($isProduction) {
            Write-Host "==> PRODUCTION deploy to '$ProjectName' (branch $Branch)" -ForegroundColor Red
            Write-Host "    This replaces https://$ProjectName.pages.dev, which the README links." -ForegroundColor Red
        } else {
            Write-Host "==> Preview deploy to '$ProjectName' (branch $Branch)" -ForegroundColor Cyan
            Write-Host "    Production is untouched." -ForegroundColor DarkGray
        }
        # Prefer the global install; fall back to npx on a machine without one.
        $deployArgs = @(
            'pages', 'deploy', $staging,
            '--project-name', $ProjectName,
            '--branch', $Branch
        )
        if (Get-Command wrangler -ErrorAction SilentlyContinue) {
            wrangler @deployArgs
        } else {
            npx wrangler @deployArgs
        }
        if ($LASTEXITCODE -ne 0) {
            throw "wrangler pages deploy failed (exit $LASTEXITCODE)"
        }
        Write-Host ''
        Write-Host 'Phone build is at the deployed url + /m/' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host 'Not deployed. To publish a PREVIEW (production untouched):' -ForegroundColor Yellow
        Write-Host '  ./tool/build_web.ps1 -Deploy'
        Write-Host 'To replace the live site:'
        Write-Host '  ./tool/build_web.ps1 -Deploy -Branch main'
        Write-Host 'or serve locally for a phone test:'
        Write-Host "  python -m http.server 8000 --bind 0.0.0.0 --directory `"$staging`""
    }
}
finally {
    Pop-Location
}
