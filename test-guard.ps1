# Extracts Test-SafeToDelete from janitor.ps1 via AST and asserts it refuses
# every dangerous path and accepts every intended one. Read-only: nothing is deleted.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$src = 'D:\opes-clean\tools\janitor\janitor.ps1'
$cfgPath = 'D:\opes-clean\tools\janitor\janitor.config.json'

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "parse errors in $src" }

foreach ($fn in @('Test-SafeToDelete','Expand-PathToken')) {
    $def = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn
    }, $true) | Select-Object -First 1
    if (-not $def) { throw "function $fn not found" }
    Invoke-Expression $def.Extent.Text
}

$cfg       = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allowed   = @($cfg.allowedPrefixes | ForEach-Object { Expand-PathToken $_ })
$protected = @($cfg.protectedPaths  | ForEach-Object { Expand-PathToken $_ })

$u = $env:USERPROFILE

# expected = $true means "engine is allowed to clear this directory's contents"
$cases = @(
    @{ Path = 'C:\';                              Expect = $false; Why = 'drive root' }
    @{ Path = 'D:\';                              Expect = $false; Why = 'drive root' }
    @{ Path = 'C:\Windows';                       Expect = $false; Why = 'too shallow + not allowlisted' }
    @{ Path = 'C:\Users';                         Expect = $false; Why = 'too shallow' }
    @{ Path = $u;                                 Expect = $false; Why = 'profile root, not allowlisted' }
    @{ Path = "$u\Desktop";                       Expect = $false; Why = 'protected' }
    @{ Path = "$u\Documents";                     Expect = $false; Why = 'protected' }
    @{ Path = "$u\Downloads";                     Expect = $false; Why = 'outside allowlist' }
    @{ Path = "$u\blobs";                         Expect = $false; Why = 'outside allowlist' }
    @{ Path = 'C:\Program Files';                 Expect = $false; Why = 'outside allowlist' }
    @{ Path = 'D:\opes-clean';                    Expect = $false; Why = 'outside allowlist' }
    @{ Path = "$u\.ssh";                          Expect = $false; Why = 'protected' }
    @{ Path = 'C:\Windows\Temp';                  Expect = $true;  Why = 'allowlisted' }
    @{ Path = "$env:LOCALAPPDATA\Temp";           Expect = $true;  Why = 'allowlisted' }
    @{ Path = "$env:LOCALAPPDATA\Yarn";           Expect = $true;  Why = 'allowlisted' }
    @{ Path = "$u\.cache\puppeteer";              Expect = $true;  Why = 'allowlisted' }
)

$pass = 0; $fail = 0; $skip = 0
Write-Host ''
Write-Host '  RESULT  EXPECT  GOT     PATH' -ForegroundColor Cyan
Write-Host '  ------  ------  ------  --------------------------------------------------'

foreach ($c in $cases) {
    if (-not (Test-Path -LiteralPath $c.Path)) {
        Write-Host ('  SKIP    {0,-6}  {1,-6}  {2}  (does not exist)' -f $c.Expect, '-', $c.Path) -ForegroundColor DarkGray
        $skip++
        continue
    }
    $reason = ''
    $got = Test-SafeToDelete -Path $c.Path -AllowedPrefixes $allowed -ProtectedPaths $protected -Reason ([ref]$reason)
    $ok = ($got -eq $c.Expect)
    if ($ok) { $pass++ } else { $fail++ }
    $tag   = if ($ok) { 'PASS  ' } else { 'FAIL  ' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('  {0}  {1,-6}  {2,-6}  {3}' -f $tag, $c.Expect, $got, $c.Path) -ForegroundColor $color
    if (-not $ok) { Write-Host ("          reason given: $reason") -ForegroundColor Red }
}

Write-Host ''
Write-Host ("  pass=$pass  fail=$fail  skip=$skip") -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($fail) { exit 1 }
exit 0
