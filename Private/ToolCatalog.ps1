function Get-CargoAccelerationToolCatalog {
    <#
    .SYNOPSIS
    Returns CargoTools' curated Rust acceleration and diagnostics tool catalog.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Core', 'Deep', 'All')]
        [string]$Profile = 'Deep'
    )

    $tools = @(
        @{ Name = 'cargo-binstall'; Command = 'cargo-binstall'; Manager = 'CargoInstall'; Package = 'cargo-binstall'; Profile = 'Core'; Mandatory = $true; Install = 'cargo install cargo-binstall --locked'; Notes = 'Fast binary installer for Rust CLIs.' },
        @{ Name = 'cargo-nextest'; Command = 'cargo-nextest'; Manager = 'Binstall'; Package = 'cargo-nextest'; Profile = 'Core'; Mandatory = $false; Install = 'cargo binstall cargo-nextest --locked'; Notes = 'Preferred Rust test runner for larger suites.' },
        @{ Name = 'sccache'; Command = 'sccache'; Manager = 'Winget'; Package = 'Mozilla.sccache'; Profile = 'Core'; Mandatory = $true; Install = 'winget install -e --id Mozilla.sccache'; Notes = 'Compiler cache for Rust and native dependencies.' },
        @{ Name = 'ninja'; Command = 'ninja'; Manager = 'Winget'; Package = 'Ninja-build.Ninja'; Profile = 'Core'; Mandatory = $false; Install = 'winget install -e --id Ninja-build.Ninja'; Notes = 'Fast CMake generator backend.' },
        @{ Name = 'hyperfine'; Command = 'hyperfine'; Manager = 'Winget'; Package = 'sharkdp.hyperfine'; Profile = 'Core'; Mandatory = $false; Install = 'winget install -e --id sharkdp.hyperfine'; Notes = 'Repeatable command benchmark runner.' },
        @{ Name = 'bacon'; Command = 'bacon'; Manager = 'Binstall'; Package = 'bacon'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall bacon --locked'; Notes = 'Interactive Rust check/test UI.' },
        @{ Name = 'cargo-watch'; Command = 'cargo-watch'; Manager = 'Binstall'; Package = 'cargo-watch'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-watch --locked'; Notes = 'Simple watch-and-run workflow.' },
        @{ Name = 'cargo-expand'; Command = 'cargo-expand'; Manager = 'Binstall'; Package = 'cargo-expand'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-expand --locked'; Notes = 'Macro expansion diagnostics.' },
        @{ Name = 'cargo-edit'; Command = 'cargo-upgrade'; Manager = 'Binstall'; Package = 'cargo-edit'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-edit --locked'; Notes = 'Dependency edit and upgrade helpers.' },
        @{ Name = 'cargo-audit'; Command = 'cargo-audit'; Manager = 'Binstall'; Package = 'cargo-audit'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-audit --locked'; Notes = 'RustSec advisory checks.' },
        @{ Name = 'cargo-deny'; Command = 'cargo-deny'; Manager = 'Binstall'; Package = 'cargo-deny'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-deny --locked'; Notes = 'Advisory, license, source, and dependency policy checks.' },
        @{ Name = 'cargo-outdated'; Command = 'cargo-outdated'; Manager = 'Binstall'; Package = 'cargo-outdated'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-outdated --locked'; Notes = 'Dependency freshness checks.' },
        @{ Name = 'cargo-machete'; Command = 'cargo-machete'; Manager = 'Binstall'; Package = 'cargo-machete'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-machete --locked'; Notes = 'Fast unused dependency scan; expect false positives.' },
        @{ Name = 'cargo-msrv'; Command = 'cargo-msrv'; Manager = 'Binstall'; Package = 'cargo-msrv'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-msrv --locked'; Notes = 'Minimum supported Rust version checks.' },
        @{ Name = 'cargo-llvm-cov'; Command = 'cargo-llvm-cov'; Manager = 'Binstall'; Package = 'cargo-llvm-cov'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-llvm-cov --locked; rustup component add llvm-tools-preview'; Notes = 'Coverage wrapper with nextest support.' },
        @{ Name = 'llvm-tools-preview'; Command = 'rust-objdump'; Manager = 'RustupComponent'; Package = 'llvm-tools-preview'; Profile = 'Deep'; Mandatory = $false; Install = 'rustup component add llvm-tools-preview'; Notes = 'Rust LLVM tools used by cargo-llvm-cov and cargo-binutils.' },
        @{ Name = 'cargo-semver-checks'; Command = 'cargo-semver-checks'; Manager = 'Binstall'; Package = 'cargo-semver-checks'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-semver-checks --locked'; Notes = 'SemVer breakage checks for public APIs.' },
        @{ Name = 'cargo-hack'; Command = 'cargo-hack'; Manager = 'Binstall'; Package = 'cargo-hack'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-hack --locked'; Notes = 'Feature-combination matrix checks.' },
        @{ Name = 'cargo-bloat'; Command = 'cargo-bloat'; Manager = 'Binstall'; Package = 'cargo-bloat'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-bloat --locked'; Notes = 'Binary size attribution.' },
        @{ Name = 'cargo-show-asm'; Command = 'cargo-asm'; Manager = 'Binstall'; Package = 'cargo-show-asm'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-show-asm --locked'; Notes = 'Generated assembly diagnostics.' },
        @{ Name = 'cargo-mutants'; Command = 'cargo-mutants'; Manager = 'Binstall'; Package = 'cargo-mutants'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-mutants --locked'; Notes = 'Mutation testing.' },
        @{ Name = 'cargo-insta'; Command = 'cargo-insta'; Manager = 'Binstall'; Package = 'cargo-insta'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-insta --locked'; Notes = 'Snapshot test review tooling.' },
        @{ Name = 'cargo-make'; Command = 'cargo-make'; Manager = 'Binstall'; Package = 'cargo-make'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-make --locked'; Notes = 'Rust task runner.' },
        @{ Name = 'cargo-zigbuild'; Command = 'cargo-zigbuild'; Manager = 'Binstall'; Package = 'cargo-zigbuild'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-zigbuild --locked'; Notes = 'Cross-build helper; requires zig for use.' },
        @{ Name = 'cargo-udeps'; Command = 'cargo-udeps'; Manager = 'Binstall'; Package = 'cargo-udeps'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-udeps --locked'; Notes = 'Unused dependency scan; run with nightly.' },
        @{ Name = 'cargo-binutils'; Command = 'cargo-nm'; Manager = 'Binstall'; Package = 'cargo-binutils'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-binutils --locked; rustup component add llvm-tools-preview'; Notes = 'LLVM binutils wrappers for Rust artifacts.' },
        @{ Name = 'cargo-criterion'; Command = 'cargo-criterion'; Manager = 'Binstall'; Package = 'cargo-criterion'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-criterion --locked'; Notes = 'Criterion benchmark helper.' },
        @{ Name = 'cargo-about'; Command = 'cargo-about'; Manager = 'Binstall'; Package = 'cargo-about'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-about --locked'; Notes = 'License/about report generator.' },
        @{ Name = 'cargo-vet'; Command = 'cargo-vet'; Manager = 'Binstall'; Package = 'cargo-vet'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-vet --locked'; Notes = 'Supply-chain audit workflow.' },
        @{ Name = 'cargo-supply-chain'; Command = 'cargo-supply-chain'; Manager = 'Binstall'; Package = 'cargo-supply-chain'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-supply-chain --locked'; Notes = 'Dependency publisher/ownership inspection.' },
        @{ Name = 'cargo-sort'; Command = 'cargo-sort'; Manager = 'Binstall'; Package = 'cargo-sort'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-sort --locked'; Notes = 'Cargo.toml sorting.' },
        @{ Name = 'cargo-license'; Command = 'cargo-license'; Manager = 'Binstall'; Package = 'cargo-license'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-license --locked'; Notes = 'Dependency license inventory.' },
        @{ Name = 'cargo-careful'; Command = 'cargo-careful'; Manager = 'Binstall'; Package = 'cargo-careful'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-careful --locked'; Notes = 'Extra runtime checks; nightly-oriented.' },
        @{ Name = 'cargo-generate'; Command = 'cargo-generate'; Manager = 'Binstall'; Package = 'cargo-generate'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall cargo-generate --locked'; Notes = 'Project template generator.' },
        @{ Name = 'samply'; Command = 'samply'; Manager = 'Binstall'; Package = 'samply'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall samply --locked'; Notes = 'Interactive sampling profiler.' },
        @{ Name = 'flamegraph'; Command = 'cargo-flamegraph'; Manager = 'Binstall'; Package = 'flamegraph'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall flamegraph --locked'; Notes = 'Flamegraph profiler wrapper.' },
        @{ Name = 'watchexec'; Command = 'watchexec'; Manager = 'Binstall'; Package = 'watchexec-cli'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall watchexec-cli --locked'; Notes = 'General watch-and-run tool.' },
        @{ Name = 'just'; Command = 'just'; Manager = 'Binstall'; Package = 'just'; Profile = 'Deep'; Mandatory = $false; Install = 'cargo binstall just --locked'; Notes = 'Fast command runner.' },
        @{ Name = 'ripgrep'; Command = 'rg'; Manager = 'Winget'; Package = 'BurntSushi.ripgrep.MSVC'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id BurntSushi.ripgrep.MSVC'; Notes = 'Fast source search.' },
        @{ Name = 'fd'; Command = 'fd'; Manager = 'Winget'; Package = 'sharkdp.fd'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id sharkdp.fd'; Notes = 'Fast file finder.' },
        @{ Name = 'bat'; Command = 'bat'; Manager = 'Winget'; Package = 'sharkdp.bat'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id sharkdp.bat'; Notes = 'Syntax-aware file viewer.' },
        @{ Name = 'dust'; Command = 'dust'; Manager = 'Winget'; Package = 'bootandy.dust'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id bootandy.dust'; Notes = 'Fast disk usage explorer.' },
        @{ Name = 'procs'; Command = 'procs'; Manager = 'Winget'; Package = 'dalance.procs'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id dalance.procs'; Notes = 'Process viewer.' },
        @{ Name = 'eza'; Command = 'eza'; Manager = 'Winget'; Package = 'eza-community.eza'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id eza-community.eza'; Notes = 'Modern directory listing.' },
        @{ Name = 'zoxide'; Command = 'zoxide'; Manager = 'Winget'; Package = 'ajeetdsouza.zoxide'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id ajeetdsouza.zoxide'; Notes = 'Directory jumper; initialize shell profile only after measuring startup.' },
        @{ Name = 'mise'; Command = 'mise'; Manager = 'Winget'; Package = 'jdx.mise'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id jdx.mise'; Notes = 'Multi-language tool version manager; avoid heavy profile init.' },
        @{ Name = 'LLVM'; Command = 'C:\Program Files\LLVM\bin\lld-link.exe'; Manager = 'Winget'; Package = 'LLVM.LLVM'; Profile = 'Deep'; Mandatory = $false; Install = 'winget install -e --id LLVM.LLVM'; Notes = 'clang/lld toolchain; do not shadow MSVC globally.' },
        @{ Name = 'zig'; Command = 'zig'; Manager = 'Winget'; Package = 'zig.zig'; Profile = 'All'; Mandatory = $false; Install = 'winget install -e --id zig.zig'; Notes = 'Required by cargo-zigbuild; optional on Windows.' }
    )

    $allowedProfiles = switch ($Profile) {
        'Core' { @('Core') }
        'Deep' { @('Core', 'Deep') }
        default { @('Core', 'Deep', 'All') }
    }

    foreach ($tool in $tools) {
        if ($allowedProfiles -contains $tool.Profile) {
            [pscustomobject]$tool
        }
    }
}
