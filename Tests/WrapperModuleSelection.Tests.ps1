#Requires -Version 5.1

BeforeDiscovery {
    $policyCases = foreach ($shell in @('Core', 'Desktop')) {
        foreach ($scenario in @('clean', 'helper-local', 'same-path-version', 'foreign-module', 'foreign-function', 'foreign-alias', 'missing-manifest', 'malformed-manifest', 'missing-export')) {
            @{ Shell=$shell; Scenario=$scenario }
        }
    }
}

BeforeAll {
    $script:SelectionRoot = Split-Path -Parent $PSScriptRoot
    $script:SelectionHelper = Join-Path $script:SelectionRoot 'wrappers/_WrapperHelpers.psm1'
    $script:SelectionHelperHash = (Get-FileHash -LiteralPath $script:SelectionHelper).Hash
    $script:SelectionProbe = Join-Path $TestDrive 'selection-probe.ps1'
    $script:SelectionEncoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($script:SelectionProbe, @'
param([string]$HelperPath, [string]$Directory, [string]$Scenario, [string]$ReceiptPath, [string]$RepositoryRoot, [string]$Wrapper)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility -Global -ErrorAction Stop
$global:PSModuleAutoLoadingPreference = 'None'
$names = @('Invoke-CargoWrapper','Invoke-CargoRoute','Invoke-CargoWsl','Invoke-CargoDocker','Invoke-CargoMacos','Invoke-RustAnalyzerWrapper')
$encoding = [Text.UTF8Encoding]::new($false)
function Write-ModuleFixture {
    param([string]$Root, [string]$Version, [string]$Marker, [switch]$MissingExport)
    [void][IO.Directory]::CreateDirectory($Root)
    $exportNames = if ($MissingExport) { @($names | Where-Object { $_ -ne 'Invoke-RustAnalyzerWrapper' }) } else { $names }
    $source = @($exportNames | ForEach-Object { "function $_ { '$Marker' }" }) -join "`r`n"
    $source += "`r`nExport-ModuleMember -Function @(" + (($exportNames | ForEach-Object { "'$_'" }) -join ',') + ")`r`n"
    [IO.File]::WriteAllText((Join-Path $Root 'CargoTools.psm1'), $source, $encoding)
    $manifest = "@{RootModule='CargoTools.psm1';ModuleVersion='$Version';GUID='d8e7945e-15ab-48de-b0fb-e9cd659571ac';FunctionsToExport=@(" + (($exportNames | ForEach-Object { "'$_'" }) -join ',') + ");AliasesToExport=@();CmdletsToExport=@();VariablesToExport=@()}"
    [IO.File]::WriteAllText((Join-Path $Root 'CargoTools.psd1'), $manifest, $encoding)
}
function Read-CallerExports {
    foreach ($name in $names) {
        # Reject an invisible export before an ordinary missing-command lookup
        # can enumerate installed modules or slow application PATH entries.
        $visible = Get-Command $name -CommandType Function,Alias -ErrorAction SilentlyContinue
        if (-not $visible) { [pscustomobject]@{Name=$name;Type='Missing';Module=$null;Version=$null;Path=$null;Value=$null}; continue }
        $command = Get-Command $name -ErrorAction Stop
        [pscustomobject]@{Name=$name;Type=$command.CommandType.ToString();Module=$command.ModuleName;Version=$command.Module.Version.ToString();Path=$command.Module.Path;Value=(& $name)}
    }
}
if ($Wrapper) {
    $env:CARGOTOOLS_MANIFEST = Join-Path $RepositoryRoot 'CargoTools.psd1'
    $helper = Import-Module $HelperPath -Force -PassThru
    $selected = Import-CargoToolsResilient
    if (-not $selected) { throw 'Top-level control did not admit the actual source module.' }
    $exports = @(foreach ($name in $names) { $command=Get-Command $name -ErrorAction Stop; [pscustomobject]@{Name=$name;Path=$command.Module.Path;Version=$command.Module.Version.ToString()} })
    [IO.File]::WriteAllText($ReceiptPath, ([pscustomobject]@{Selected=$selected;Exports=$exports;PowerShell=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Depth 5), $encoding)
    $manifestPath = Join-Path $Directory 'Cargo.toml'
    if ($Scenario -eq 'native-failure') { $manifestPath = Join-Path $Directory 'absent.toml' }
    # These actual wrapper calls use --raw inside CargoTools, retaining module
    # selection while avoiding environment/preflight/build/cache side effects.
    & (Join-Path $RepositoryRoot ('wrappers/' + $Wrapper + '.ps1')) --raw --offline pkgid --manifest-path $manifestPath
    exit $LASTEXITCODE
}
$selectedRoot = Join-Path $Directory 'selected'
# Policy cases exercise import custody only. Native controls above require the
# actual rustup application; this sentinel throws if policy code executes it.
function global:rustup { throw 'The module-selection policy fixture must not execute Rust tooling.' }
Write-ModuleFixture -Root $selectedRoot -Version '0.9.0' -Marker 'new-export-v09'
$env:CARGOTOOLS_MANIFEST = Join-Path $selectedRoot 'CargoTools.psd1'
$helper = Import-Module $HelperPath -Force -PassThru
$sentinelBefore = $null
switch ($Scenario) {
    'helper-local' { & $helper { param($manifest) Import-Module $manifest -Scope Local } $env:CARGOTOOLS_MANIFEST }
    'same-path-version' {
        Write-ModuleFixture -Root $selectedRoot -Version '0.8.0' -Marker 'old-export-v08'
        Import-Module $env:CARGOTOOLS_MANIFEST -Global
        Write-ModuleFixture -Root $selectedRoot -Version '0.9.0' -Marker 'new-export-v09'
    }
    'foreign-module' {
        $foreignRoot = Join-Path $Directory 'foreign'
        Write-ModuleFixture -Root $foreignRoot -Version '0.9.0' -Marker 'foreign-module-sentinel'
        Import-Module (Join-Path $foreignRoot 'CargoTools.psd1') -Global
        $sentinelBefore = (Get-Module CargoTools).Path
    }
    'foreign-function' { function global:Invoke-CargoWrapper { 'foreign-function-sentinel' }; $sentinelBefore = Invoke-CargoWrapper }
    'foreign-alias' {
        Import-Module $env:CARGOTOOLS_MANIFEST -Global
        function global:Invoke-SelectionSentinel { 'foreign-alias-sentinel' }
        Set-Alias -Name Invoke-CargoWrapper -Value Invoke-SelectionSentinel -Scope Global
        $sentinelBefore = Invoke-CargoWrapper
    }
    'missing-manifest' { $env:CARGOTOOLS_MANIFEST = Join-Path $Directory 'absent.psd1' }
    'malformed-manifest' {
        $env:CARGOTOOLS_MANIFEST = Join-Path $Directory 'malformed.psd1'
        [IO.File]::WriteAllText($env:CARGOTOOLS_MANIFEST, '@{ broken =', $encoding)
    }
    'missing-export' { Write-ModuleFixture -Root $selectedRoot -Version '0.9.0' -Marker 'new-export-v09' -MissingExport }
}
$accepted = Import-CargoToolsResilient
$exports = @()
if ($Scenario -in @('clean','helper-local','same-path-version','foreign-module')) { $exports = @(Read-CallerExports) }
$sentinelAfter = $null
$sentinelType = $null
if ($Scenario -in @('foreign-function','foreign-alias')) { $sentinelAfter=Invoke-CargoWrapper; $sentinelType=(Get-Command Invoke-CargoWrapper).CommandType.ToString() }
if ($Scenario -eq 'foreign-module') { $sentinelAfter=(Get-Module CargoTools).Path }
[IO.File]::WriteAllText($ReceiptPath, ([pscustomobject]@{Scenario=$Scenario;Accepted=$accepted;Exports=$exports;Loaded=@(Get-Module CargoTools -All | Select-Object Path,Version);SelectedRoot=$selectedRoot;SentinelBefore=$sentinelBefore;SentinelAfter=$sentinelAfter;SentinelType=$sentinelType;PowerShell=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Depth 7), $encoding)
'@, $script:SelectionEncoding)

    function Invoke-SelectionChild {
        param([string]$Shell, [string]$Scenario, [string]$Wrapper)
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($directory)
        $receipt = Join-Path $directory 'receipt.json'
        if ($Wrapper) {
            [void][IO.Directory]::CreateDirectory((Join-Path $directory 'src'))
            [IO.File]::WriteAllText((Join-Path $directory 'Cargo.toml'), "[package]`nname = `"selection_fixture`"`nversion = `"0.1.0`"`nedition = `"2021`"`n", $script:SelectionEncoding)
            [IO.File]::WriteAllText((Join-Path $directory 'src/lib.rs'), 'pub fn fixture() {}', $script:SelectionEncoding)
            [IO.File]::WriteAllText((Join-Path $directory 'Cargo.lock'), "version = 4`n[[package]]`nname = `"selection_fixture`"`nversion = `"0.1.0`"`n", $script:SelectionEncoding)
        }
        $executable = if ($Shell -eq 'Desktop') { Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe' } else { (Get-Command pwsh -ErrorAction Stop).Source }
        $values = @($script:SelectionProbe, $script:SelectionHelper, $directory, $Scenario, $receipt, $script:SelectionRoot, $Wrapper)
        $quoted = @($values | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
        # A -Command host maps unsuccessful script $? to 1 unless its outer
        # command explicitly propagates the script's native exit code.
        $command = '& ' + $quoted[0] + ' -HelperPath ' + $quoted[1] + ' -Directory ' + $quoted[2] + ' -Scenario ' + $quoted[3] + ' -ReceiptPath ' + $quoted[4] + ' -RepositoryRoot ' + $quoted[5] + ' -Wrapper ' + $quoted[6] + '; exit $LASTEXITCODE'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $executable
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded
        $start.WorkingDirectory = $directory
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $output = $process.StandardOutput.ReadToEndAsync()
            $errorOutput = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                if (-not $process.WaitForExit(5000)) { throw 'Exact selection fixture child termination was not confirmed.' }
                throw 'Selection fixture child exceeded its 30-second test guard.'
            }
            $observation = if (Test-Path -LiteralPath $receipt) { Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json } else { $null }
            [pscustomobject]@{ExitCode=$process.ExitCode;Observation=$observation;Output=$output.GetAwaiter().GetResult();ErrorOutput=$errorOutput.GetAwaiter().GetResult()}
        } finally { $process.Dispose() }
    }
}

AfterAll { (Get-FileHash -LiteralPath $script:SelectionHelper).Hash | Should -BeExactly $script:SelectionHelperHash }

Describe 'Wrapper selection admits the exact caller-visible module in fresh shells' -Tag 'Unit', 'FreshProcess' {
    It 'qualifies <Scenario> in <Shell>' -ForEach $policyCases {
        $result = Invoke-SelectionChild -Shell $Shell -Scenario $Scenario
        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.ErrorOutput)
        $observation = $result.Observation
        $observation | Should -Not -BeNullOrEmpty
        if ($Scenario -in @('clean','helper-local')) {
            $observation.Accepted | Should -BeTrue
            $observation.Exports.Count | Should -Be 6
            foreach ($command in $observation.Exports) {
                $command.Type | Should -BeExactly 'Function'
                $command.Module | Should -BeExactly 'CargoTools'
                $command.Version | Should -BeExactly '0.9.0'
                $command.Path | Should -BeExactly (Join-Path $observation.SelectedRoot 'CargoTools.psm1')
                $command.Value | Should -BeExactly 'new-export-v09'
            }
        } else {
            $observation.Accepted | Should -BeFalse
            if ($Scenario -eq 'same-path-version') {
                $observation.Exports.Count | Should -Be 6
                foreach ($command in $observation.Exports) { $command.Version | Should -BeExactly '0.8.0'; $command.Value | Should -BeExactly 'old-export-v08' }
            }
            if ($Scenario -in @('missing-manifest','malformed-manifest')) { @($observation.Loaded).Count | Should -Be 0 }
            if ($Scenario -in @('foreign-module','foreign-function','foreign-alias')) { $observation.SentinelAfter | Should -BeExactly $observation.SentinelBefore }
            if ($Scenario -eq 'foreign-module') { foreach ($command in $observation.Exports) { $command.Value | Should -BeExactly 'foreign-module-sentinel' } }
            if ($Scenario -eq 'foreign-alias') { $observation.SentinelType | Should -BeExactly 'Alias' }
            if ($Scenario -eq 'foreign-function') { $observation.SentinelType | Should -BeExactly 'Function' }
        }
    }
}

Describe 'Actual top-level wrappers retain native offline exit codes with source selection' -Tag 'Integration', 'NativeOffline' {
    It 'qualifies <Wrapper> with <Scenario>' -ForEach @(
        @{Wrapper='cargo';Scenario='native-success';Expected=0}
        @{Wrapper='cargo';Scenario='native-failure';Expected=101}
        @{Wrapper='cargo-route';Scenario='native-success';Expected=0}
        @{Wrapper='cargo-route';Scenario='native-failure';Expected=101}
    ) {
        $result = Invoke-SelectionChild -Shell Core -Scenario $Scenario -Wrapper $Wrapper
        $result.ExitCode | Should -Be $Expected -Because ($result.Output + $result.ErrorOutput)
        $result.Observation.Selected | Should -BeTrue
        $result.Observation.Exports.Count | Should -Be 6
        foreach ($command in $result.Observation.Exports) {
            $command.Path | Should -BeExactly (Join-Path $script:SelectionRoot 'CargoTools.psm1')
            $command.Version | Should -BeExactly '0.9.0'
        }
        if ($Expected -eq 0) { $result.Output | Should -Match 'selection_fixture@0.1.0' }
        else { $result.ErrorOutput | Should -Match 'absent.toml' }
    }
}

BeforeDiscovery {
    $outerChildCases=foreach($shell in @('Core','Desktop')) {
        foreach($wrapper in @('cargo','cargo-route')) {
            foreach($flag in @('--help','--version','--diagnose','--llm','--no-wrapper','--json-output','')) {
                @{Shell=$shell;Wrapper=$wrapper;Flag=$flag}
            }
        }
    }
    $outerHostCases=foreach($shell in @('Core','Desktop')) {
        foreach($wrapper in @('cargo','cargo-route')) {
            foreach($flag in @('--help','--no-wrapper')) { @{Shell=$shell;Wrapper=$wrapper;Flag=$flag} }
        }
    }
}

Describe 'Outer wrapper transfers child flags only after the Cargo separator' -Tag 'Unit','FreshProcess' {
    BeforeAll {
        $script:OuterHelper=Import-Module $script:SelectionHelper -Force -PassThru
        $script:OuterProbe=Join-Path $TestDrive 'outer-probe.ps1'
        [IO.File]::WriteAllText($script:OuterProbe,@'
param([string]$HelperPath,[string]$RepositoryRoot,[string]$Directory,[string]$Wrapper,[string]$Flag,[bool]$HostFlag)
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility -Global
$encoding=[Text.UTF8Encoding]::new($false)
$wrapperRoot=Join-Path $Directory 'wrappers'
$moduleRoot=Join-Path $Directory 'module'
[void][IO.Directory]::CreateDirectory($wrapperRoot)
[void][IO.Directory]::CreateDirectory($moduleRoot)
foreach($name in @('cargo.ps1','cargo-route.ps1')) {
    [IO.File]::Copy((Join-Path $RepositoryRoot ('wrappers/'+$name)),(Join-Path $wrapperRoot $name))
}
[IO.File]::Copy($HelperPath,(Join-Path $wrapperRoot '_WrapperHelpers.psm1'))
$env:PCAI_OUTER_RECEIPT=Join-Path $Directory 'route.json'
$moduleSource=@"
function Invoke-CargoRoute {
    param([string[]]`$ArgumentList)
    [IO.File]::WriteAllText(`$env:PCAI_OUTER_RECEIPT,([pscustomobject]@{Route='module';Arguments=@(`$ArgumentList)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
    '{"route":"module"}'
    return 0
}
function Invoke-CargoWrapper { return 0 }
function Invoke-CargoWsl { return 0 }
function Invoke-CargoDocker { return 0 }
function Invoke-CargoMacos { return 0 }
function Invoke-RustAnalyzerWrapper { return 0 }
Export-ModuleMember -Function Invoke-CargoRoute,Invoke-CargoWrapper,Invoke-CargoWsl,Invoke-CargoDocker,Invoke-CargoMacos,Invoke-RustAnalyzerWrapper
"@
[IO.File]::WriteAllText((Join-Path $moduleRoot 'CargoTools.psm1'),$moduleSource,$encoding)
[IO.File]::WriteAllText((Join-Path $moduleRoot 'CargoTools.psd1'),"@{RootModule='CargoTools.psm1';ModuleVersion='0.9.0';GUID='d8e7945e-15ab-48de-b0fb-e9cd659571ac';FunctionsToExport=@('*');AliasesToExport=@();CmdletsToExport=@();VariablesToExport=@()}",$encoding)
$env:CARGOTOOLS_MANIFEST=Join-Path $moduleRoot 'CargoTools.psd1'
$env:CARGO_RAW=$null
$env:PCAI_OUTER_NATIVE=Join-Path $Directory 'native.cmd'
[IO.File]::WriteAllText($env:PCAI_OUTER_NATIVE,"@echo off`r`necho {`"route`":`"raw`"}`r`nexit /b 0`r`n",[Text.ASCIIEncoding]::new())
function global:rustup {
    [IO.File]::WriteAllText($env:PCAI_OUTER_RECEIPT,([pscustomobject]@{Route='raw';Arguments=@($args)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    & $env:PCAI_OUTER_NATIVE
    $global:LASTEXITCODE=$LASTEXITCODE
}
# Diagnostic controls stay read-only and never contact the shared cache server.
function global:sccache { 'Cache hits 0'; $global:LASTEXITCODE=0 }
$global:LASTEXITCODE=0
$tokens=if($HostFlag){@($Flag,'run','--','child')}else{@('run','--',$Flag)}
& (Join-Path $wrapperRoot ($Wrapper+'.ps1')) @tokens
exit $LASTEXITCODE
'@,$script:SelectionEncoding)
        function Invoke-OuterWrapperChild {
            param([string]$Shell,[string]$Wrapper,[string]$Flag,[bool]$HostFlag=$false)
            $directory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($directory)
            $executable=if($Shell -eq 'Desktop'){Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'}else{(Get-Command pwsh -ErrorAction Stop).Source}
            $values=@($script:OuterProbe,$script:SelectionHelper,$script:SelectionRoot,$directory,$Wrapper,$Flag)
            $quoted=@($values|ForEach-Object {"'"+([string]$_).Replace("'","''")+"'"})
            $command='& '+$quoted[0]+' -HelperPath '+$quoted[1]+' -RepositoryRoot '+$quoted[2]+' -Directory '+$quoted[3]+' -Wrapper '+$quoted[4]+' -Flag '+$quoted[5]+' -HostFlag '+[string]$(if($HostFlag){'$true'}else{'$false'})+'; exit $LASTEXITCODE'
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=$executable
            $start.Arguments='-NoLogo -NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $start.WorkingDirectory=$directory
            $start.UseShellExecute=$false
            $start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            $process=[Diagnostics.Process]::new()
            $process.StartInfo=$start
            try {
                [void]$process.Start()
                $output=$process.StandardOutput.ReadToEndAsync()
                $errorOutput=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(30000)) {
                    $process.Kill()
                    if(-not $process.WaitForExit(5000)){throw 'Exact outer fixture child termination was not confirmed.'}
                    throw 'Outer wrapper fixture exceeded its 30-second test guard.'
                }
                $receipt=Join-Path $directory 'route.json'
                $observation=if(Test-Path -LiteralPath $receipt){Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json}else{$null}
                $copyHashes=@(foreach($name in @('cargo.ps1','cargo-route.ps1')) {
                    [pscustomobject]@{Name=$name;Original=(Get-FileHash (Join-Path $script:SelectionRoot ('wrappers/'+$name))).Hash;Copy=(Get-FileHash (Join-Path $directory ('wrappers/'+$name))).Hash}
                })
                [pscustomobject]@{ExitCode=$process.ExitCode;Observation=$observation;Output=$output.GetAwaiter().GetResult();ErrorOutput=$errorOutput.GetAwaiter().GetResult();CopyHashes=$copyHashes}
            }finally{$process.Dispose()}
        }
    }

    It 'keeps child <Flag> through actual <Wrapper> in <Shell>' -ForEach $outerChildCases {
        $result=Invoke-OuterWrapperChild -Shell $Shell -Wrapper $Wrapper -Flag $Flag
        $result.ExitCode|Should -Be 0 -Because ($result.Output+$result.ErrorOutput)
        $result.Observation|Should -Not -BeNullOrEmpty
        $result.Observation.Route|Should -BeExactly 'module'
        @($result.Observation.Arguments)|Should -Be @('run','--',$Flag)
        $result.Output|Should -Match '"route":"module"'
        $result.Output|Should -Not -Match '"phase":"start"|WRAPPER FLAGS|CargoTools wrapper/'
        $result.ErrorOutput|Should -Not -Match '"phase":"start"'
        foreach($copy in $result.CopyHashes){$copy.Copy|Should -BeExactly $copy.Original}
    }

    It 'honors host <Flag> before the separator through <Wrapper> in <Shell>' -ForEach $outerHostCases {
        $result=Invoke-OuterWrapperChild -Shell $Shell -Wrapper $Wrapper -Flag $Flag -HostFlag $true
        $result.ExitCode|Should -Be 0 -Because ($result.Output+$result.ErrorOutput)
        if($Flag -eq '--help') {
            $result.Observation.Route|Should -BeExactly 'raw'
            @($result.Observation.Arguments)|Should -Be @('run','stable','cargo','help','run')
            $result.Output|Should -Match 'WRAPPER FLAGS'
        }else {
            $result.Observation.Route|Should -BeExactly 'raw'
            @($result.Observation.Arguments)|Should -Be @('run','stable','cargo','run','--','child')
        }
    }

    It 'recognizes host <Flag> before the separator without consuming a matching child flag' -ForEach @(
        @{Flag='--help';Field='HelpRequested'}
        @{Flag='--version';Field='VersionRequested'}
        @{Flag='--diagnose';Field='DiagnoseRequested'}
        @{Flag='--llm';Field='LlmMode'}
        @{Flag='--no-wrapper';Field='NoWrapper'}
        @{Flag='--json-output';Field='LlmMode'}
    ) {
        $ctx=& $script:OuterHelper {param($tokens) Get-WrapperContext -InvocationArgs $tokens} @($Flag,'run','--',$Flag)
        $ctx.$Field|Should -BeTrue
        @($ctx.PassThrough)|Should -Be @('run','--',$Flag)
    }
}
