$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-GpuPlacement.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "FAIL: $Message (expected $Expected, got $Actual)" }
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw "FAIL: $Message was accepted" }
    catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
}

$csv = @'
0, GPU-af64da72-8fa1-a3c0-69e5-b2fd0861cc77, NVIDIA GeForce RTX 3090, 24576 MiB, 8.6, 00000000:0A:00.0
1, GPU-b8890b7e-599c-52c4-eff8-29d1db053715, NVIDIA GeForce RTX 3090, 24576 MiB, 8.6, 00000000:0B:00.0
bad, GPU-wrong, no card, N/A, N/A, N/A
'@
$cards = @(Convert-StrataGpuPlacementCsv $csv)
Assert-Equal $cards.Count 2 'only valid CUDA inventory rows should be returned'
Assert-Equal $cards[1].Index 1 'GPU index should be parsed'
Assert-Equal $cards[1].MemoryMiB 24576 'VRAM should be parsed'
Assert-Equal $cards[1].ComputeCapability 8.6 'compute capability should be parsed'
Assert-Equal $cards[1].BusId '00000000:0B:00.0' 'PCI bus should be parsed'

$windowsLocation = Convert-StrataGpuPciBusIdToWindowsLocation '00000000:21:00.0'
Assert-Equal $windowsLocation.Text 'PCI 总线 33、设备 0、功能 0' 'PCI location should use Windows decimal values'
Assert-Equal $windowsLocation.Bus 33 'hexadecimal bus 21 should become decimal 33'
Assert-Equal (Convert-StrataGpuPciBusIdToWindowsLocation '00000000:4B:00.0').Text 'PCI 总线 75、设备 0、功能 0' 'second GPU bus should use decimal 75'
Assert-Equal (Convert-StrataGpuPciBusIdToWindowsLocation '00000001:4B:02.1').Text 'PCI 段 1、总线 75、设备 2、功能 1' 'nonzero PCI segment should remain visible'
if ($null -ne (Convert-StrataGpuPciBusIdToWindowsLocation 'invalid')) { throw 'FAIL: malformed PCI address was formatted' }

$build = [pscustomobject]@{ cuda = '13.0'; archs = @(75,86,89,120); ptx = $true }
if (-not (Test-StrataCudaPlacementBuild -Build $build -Cards $cards)) { throw 'FAIL: installed CUDA engine should accept RTX 3090s' }
if (Test-StrataCudaPlacementBuild -Build ([pscustomobject]@{hip='7'}) -Cards $cards) { throw 'FAIL: HIP engine must not offer NVIDIA placement' }

$legacy = [pscustomobject]@{ gpu = @(0,1); layer_split = '20'; sampling = [pscustomobject]@{temperature=0.6} }
$display = @(Get-StrataGpuPlacementRoles -Config $legacy -Cards $cards)
Assert-Equal $display[0].Role 'helper' 'first legacy GPU should be Helper'
Assert-Equal $display[1].Role 'main' 'last legacy GPU should be Main'
Assert-Equal $legacy.layer_split '20' 'display projection must not rewrite config'

$roles = @{0='helper';1='main'}
$edited = Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $cards -Roles $roles -Build $build
Assert-Equal ($edited.gpu -join ',') '0,1' 'split must use both cards in stage order'
Assert-Equal $edited.gpu_roles.'0' 'helper' 'Helper role must be saved'
Assert-Equal $edited.gpu_roles.'1' 'main' 'Main role must be saved'
Assert-Equal $edited.gpu_order 'as_given' 'engine must preserve explicit stage order'
Assert-Equal $edited.layer_split 'auto' 'new placement must reset stale manual split'
Assert-Equal $edited.sampling.temperature 0.6 'unrelated settings must survive'
Assert-Equal ($legacy.gpu -join ',') '0,1' 'original config must remain unchanged'
Assert-Equal $legacy.layer_split '20' 'original manual split must remain unchanged'
Assert-Equal $edited.gpu_cards.'0' 'RTX 3090|00000000:0A:00.0' 'saved card fingerprint should include the PCI bus'
Assert-StrataGpuPlacementIdentity -Config $edited -Cards $cards
$renumbered = @($cards[1],$cards[0])
$renumbered[0] = [pscustomobject]@{Index=0;Uuid=$cards[1].Uuid;Name=$cards[1].Name;MemoryMiB=24576;ComputeCapability=8.6;BusId=$cards[1].BusId}
$renumbered[1] = [pscustomobject]@{Index=1;Uuid=$cards[0].Uuid;Name=$cards[0].Name;MemoryMiB=24576;ComputeCapability=8.6;BusId=$cards[0].BusId}
Assert-Rejected { Assert-StrataGpuPlacementIdentity -Config $edited -Cards $renumbered } 'renumbered cards on next launch'
Assert-StrataGpuPlacementIdentity -Config $legacy -Cards $renumbered
$upstream = $edited | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$upstream.gpu_cards.'0' = 'RTX 3090'
$upstream.gpu_cards.'1' = 'RTX 3090|0000:0B:00.0'
Assert-StrataGpuPlacementIdentity -Config $upstream -Cards $cards

$single = Set-StrataGpuPlacementConfig -Config $edited -Cards $cards -CurrentCards $cards -Roles @{0='main';1='off'} -Build $build
Assert-Equal $single.gpu 0 'single card must use scalar legacy GPU field'
if ($single.PSObject.Properties['layer_split']) { throw 'FAIL: single-card config kept a stale layer split' }

Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $cards -Roles @{0='helper';1='off'} -Build $build } 'no Main'
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $cards -Roles @{0='main';1='main'} -Build $build } 'two Main cards'
$changed = @($cards[0],([pscustomobject]@{Index=1;Uuid='GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name=$cards[1].Name;MemoryMiB=24576;ComputeCapability=8.6;BusId=$cards[1].BusId}))
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $changed -Roles $roles -Build $build } 'changed GPU UUID'
$small = @($cards[0],([pscustomobject]@{Index=1;Uuid=$cards[1].Uuid;Name=$cards[1].Name;MemoryMiB=6144;ComputeCapability=8.6;BusId=$cards[1].BusId}))
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $small -CurrentCards $small -Roles @{0='main';1='helper'} -Build $build } '6 GiB Helper'
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $cards -Roles $roles -Build ([pscustomobject]@{hip='7'}) } 'wrong engine backend'
$older = @($cards[0],$cards[1],([pscustomobject]@{Index=2;Uuid='GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='NVIDIA GeForce GTX 1080';MemoryMiB=8192;ComputeCapability=6.1;BusId='00000000:0C:00.0'}))
if (-not (Test-StrataCudaPlacementBuild -Build $build -Cards $older)) { throw 'FAIL: an unused older card disabled placement for supported cards' }
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $older -CurrentCards $older -Roles @{0='helper';1='main';2='helper'} -Build $build } 'unsupported Helper'
Assert-Rejected { Set-StrataGpuPlacementConfig -Config $legacy -Cards $cards -CurrentCards $cards -Roles @{0='main';99='off'} -Build $build } 'role for unknown card'

'PASS: GPU placement inventory, legacy roles, config writes and guards'
