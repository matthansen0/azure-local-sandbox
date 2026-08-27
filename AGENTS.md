# Agent notes

Working notes for anyone, human or agent, changing this repository or driving a real
deployment. The [README](README.md) explains what the project builds; this file records what
the first real paid deployment actually taught us.

Everything below was learned on 2026-08-26 during the first end-to-end run on licensed media.
That run reached a deployed two-node Azure Local cluster with all 35 validation checks
passing, but only after nine distinct defects were found and fixed.

## Entry points

| Task | Command |
|---|---|
| Provision the Azure host | `scripts/Deploy.ps1 -Mode Deploy -Location centralus -AzureLocalLocation eastus` |
| Guided in-VM setup | `scripts/Start-SandboxSetup.ps1` (desktop shortcut "Azure Local Sandbox Setup") |
| Unattended in-VM setup | `scripts/Invoke-SandboxDeployment.ps1` |
| Validate an existing lab | `scripts/Test-SandboxDeployment.ps1` |
| Diagnose a stuck cloud deployment | `scripts/Get-AzureLocalDeploymentStatus.ps1` |
| Refresh in-VM source from GitHub | `scripts/Update-SandboxSource.ps1` |

There is no `Launch-SandboxSetup.ps1`. The wizard is `Start-SandboxSetup.ps1`, and its
`-Mode Deploy` runs validation *and* deployment in one unattended pass.

## Repository checks

```powershell
Install-Module Pester -RequiredVersion 6.0.1 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
./tests/Invoke-Tests.ps1                    # needs bicep on PATH and network access
./tests/Invoke-Tests.ps1 -Offline -SkipBicep
```

`Invoke-Tests.ps1` fails the build on a *single* PSScriptAnalyzer warning. Run it before
pushing. Two traps that have already bitten:

- A parameter read only inside a function that closes over it is reported as
  `PSReviewUnusedParameter`. Resolve such values at script scope instead.
- `Architecture.Tests.ps1` asserts against script *source text*. A stale comment or a
  `SuppressMessageAttribute` justification string can pass or fail a test on its own. Tests
  that assert on code strip comment lines first.

## Environment facts

- The in-VM scripts run under **Windows PowerShell 5.1**, elevated. Not `pwsh`.
- In-VM Azure authentication is the host's **system-assigned managed identity**
  (`az login --identity` / `Connect-AzAccount -Identity`). No interactive login is needed
  anywhere in the deployment.
- State lives in `C:\AzureLocalSandbox\State\*.json`, parent images on `V:\VHDs`, staged
  source in `C:\AzureLocalSandbox\Source`.
- Stages are resumable and are skipped on their recorded phase. See
  [STAGE-CONTRACT.md](docs/STAGE-CONTRACT.md).
- **Never reboot the outer host mid-deployment.** It stops every nested guest and a running
  Azure Local deployment cannot recover.

## Measured timings

From the first successful run on `Standard_E32s_v6`. The two Azure-side stages are executed
by the Azure Local service and cannot be shortened.

| Phase | Measured |
|---|---|
| `Deploy.ps1` host provisioning, bootstrap, one reboot | ~12 min |
| Preflight | ~3 min |
| Images (both VHDX parents) | ~10 min |
| NestedVMs + GuestDisks + LevelOne | ~65 min |
| ManagementPlane | ~25-30 min cold |
| ArcRegistration | ~7 min |
| Validation | ~39 min |
| Deployment | ~2 h 29 min |
| FinalValidation | ~2 min |

End to end from launching the wizard: **roughly 5 hours**, plus ISO download time.

## Logging and diagnostics

Start here when a run has failed and the console is gone.

| Artefact | Path |
|---|---|
| Orchestrator transcript, one per run | `C:\AzureLocalSandbox\Logs\sandbox-deployment-<yyyyMMdd-HHmmss>.log` |
| Structured failure record | `C:\AzureLocalSandbox\State\last-error.json` |
| Host bootstrap transcript | `C:\AzureLocalSandbox\Logs\Bootstrap.log` |
| DISM image apply | `C:\AzureLocalSandbox\Logs\dism-apply-*.log` |
| Stage progress markers | `C:\AzureLocalSandbox\State\*.json` |
| Azure Local LCM logs, on a node | `C:\CloudDeployment\Logs\CloudDeployment*.log` |

`last-error.json` carries the message, exception type, the failing file and line, the script stack
trace, and the transcript path. It is deleted on a successful run, so if it exists it describes the
most recent failure.

Two things to know before trusting a transcript:

- **A Windows PowerShell 5.1 transcript does not record the information stream.** `Write-Information`
  is invisible to it even with `-InformationAction Continue`, and so is `$InformationPreference`.
  Since every `Write-Step` in this repository is a `Write-Information`, the orchestrator appends
  `6>&1` to the stage action and to each sub-script call to merge that stream into output, which
  *is* recorded. Keep that redirection on any new call, or the log silently loses its narration.
- **A terminating error reaches the host only after `Stop-Transcript` has run.** The orchestrator
  therefore catches, records the failure, and rethrows, so the reason lands in the log rather than
  after the end of it.

## Running the checks locally

`bicep` is not on `PATH` on the sandbox host, so the full suite needs the pinned build:

```powershell
$exe = "$env:TEMP\bicep.exe"
Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://github.com/Azure/bicep/releases/download/v0.45.15/bicep-win-x64.exe' `
    -OutFile $exe
./tests/Invoke-Tests.ps1 -BicepExecutable $exe
```

That is 56 tests. `-Offline -SkipBicep` drops to 47 and skips template compilation, so use the full
form before pushing.

`$env:TEMP` on this host resolves to a per-session `...\Temp\2`, which a child `powershell.exe`
does not share. Pass absolute paths when handing a script to another process.

## Failure modes already fixed

Do not reintroduce these. Each one cost real time to find.

1. **PSGallery needs TLS 1.2.** .NET 4.x defaults to SSL3/TLS1.0 under Windows PowerShell
   5.1, so the NuGet provider bootstrap fails silently on a clean Server 2025 host. Every
   `Install-NuGetProvider` helper sets TLS 1.2 first, then re-checks that the provider is
   really installed and throws if it is not.
2. **Never let PowerShellGet prompt inside a guest.** If the NuGet provider is missing,
   `Install-Module` raises an interactive prompt. Nothing can answer it over PowerShell
   Direct and the run deadlocks indefinitely; this cost 96 minutes of silent hang. Gallery
   installs inside a guest therefore run in a **background job**. A job that prompts does not
   fail: it parks in the `Blocked` state, and `Wait-Job` then raises
   `BlockedJobsDeadlockWithWaitJob` immediately instead of waiting out the timeout. Handle
   `Blocked` explicitly, because it is the signal that the provider bootstrap failed.
   A job that ends on a terminating error exposes it **only** through
   `$job.ChildJobs[].JobStateInfo.Reason`; `Receive-Job` and `$job.ChildJobs[].Error` both
   come back empty, which is how an earlier version produced a bare "failed:" with no detail.
3. **`?` is a legal character in a PowerShell variable name.** `"$name?api-version=..."`
   parses as `$name?api`. Use `"${name}?api-version=..."`.
4. **Variables are case-insensitive.** A loop variable `$worker` collides with a parameter
   `[ValidateSet(...)][string]$Worker` and assignment then fails validation. Do not shadow a
   validated parameter with a differently-cased local.

   The same trap applies to *any* assignment into a parameter carrying a `Validate*`
   attribute, because the attribute is enforced on every later assignment at script scope.
   `Deploy.ps1` assigned an unresolved service principal id straight into a GUID-patterned
   parameter, so the explanatory `throw` underneath it was unreachable. Resolve into a local,
   check it, then assign. Assignment inside a *function* creates an unguarded local and is
   safe. `tests/Architecture.Tests.ps1` does not catch this; an AST scan for assignments to
   guarded parameters does.
5. **Run `bcdboot` from the host, not the applied image.** Launching
   `<mount>:\Windows\System32\bcdboot.exe` resolves side-by-side dependencies against the live
   system root and terminates with `0xC0E90002` before writing any output.
6. **Convert ISO media in-process, one at a time.** A VHDX mounted from a `Start-Job` worker,
   or two conversions running concurrently, drives the virtual disk into
   `ERROR_VHD_INVALID_STATE` (`0xC03A001C`) about 30 seconds into the DISM apply. Symptoms are
   FilterManager event ID 3 plus DISM `0x80070015`. Foreground conversion is reliable;
   sequential conversion costs only a few extra minutes.
7. **Node credentials change twice.** This trips up any check that reaches the nodes:
   - Before Azure Local runs: local `Administrator` works.
   - After **validate**: nodes are domain-joined to `jumpstart.local`, so an unqualified
     `Administrator` authenticates against AD. Use `.\Administrator`.
   - After **deploy**: the Azure Local security baseline **disables the local administrator
     account**. Only `JUMPSTART\Administrator` works.

   `Test-SandboxDeployment.ps1` therefore tries the local credential then the domain
   credential. `Get-AzureLocalDeploymentStatus.ps1` has always qualified with `.\`.

   Qualifying the credential has a sharp edge. `Deploy-AzureLocal.ps1` sends
   `localAdminUserName = $LocalCredential.UserName` to Azure as a deployment parameter, so it
   must **not** be normalised there. Guards of the form
   `if ($LocalAdministratorCredential.UserName -ne 'Administrator')` also have to strip the
   `.\` prefix before comparing, or they reject the credential they were just handed.
8. **`Get-AzResource` cannot resolve `Microsoft.AzureStackHCI/clusters` by
   `-ResourceType` plus `-Name`.** It returns nothing and a healthy cluster reads as
   `NotFound`. Look the cluster up by full `-ResourceId`.
9. **Deployment moves the node management IP onto a SET team vNIC**
   (`vManagement(compute_management)`). `FABRIC` still exists but carries no IPv4 DNS, so
   `Get-DnsClientServerAddress -InterfaceAlias 'FABRIC'` raises a *terminating* CIM error
   rather than returning nothing. Scan all IPv4 adapters instead of naming one.

## Credential handling

- The three nested credentials are `Administrator`, `JUMPSTART\Administrator`, and
  `LocalBoxDeployUser`. All need 14+ characters.
- Credentials are intended to stay **in memory only** and never be written to state files.
- They live in the PowerShell session that started the run. If that terminal is closed or
  cleaned up, they are gone and a long run cannot be resumed without re-entering them. This
  happened twice during the first deployment.
- If a run must survive terminal loss, `Export-Clixml` produces a DPAPI-encrypted file
  readable only by the same user on the same machine. Delete it as soon as the run finishes.
- Do **not** paste a multi-line block whose first line is `Read-Host`. PowerShell feeds the
  *second line* to the prompt as the password. Prompt first, then paste the rest, or use
  `Get-Credential`.
- An agent is not permitted to run a password prompt on the operator's behalf, so the operator
  has to type it. `Get-Credential | Export-Clixml` is the least error-prone route because it
  works from any terminal and survives a session being cleaned up.

## Cost and containment

- ~$3.90/hour running, ~$1.70/hour deallocated (disk only). Deallocate when idle, delete the
  resource group when finished.
- A key vault is soft-deleted for 30 days and its name is derived from subscription plus
  resource group, so a rebuilt group collides with its own previous vault. Preflight reports
  this and prints the purge command; `-PurgeSoftDeletedKeyVault` handles it automatically.
- **Check for foreign data collection rules after deploying.** Subscription policy or
  Defender auto-provisioning can attach DCRs owned by another resource group to the host and
  both nodes, billing this lab's telemetry, including Sentinel security events, to a workspace
  the sandbox does not own. See [monitoring containment](docs/TECHNICAL.md#monitoring-containment).

## Still unproven

The first successful run applied fixes while it was in flight, so no single clean pass has been
observed end to end. A second round of local QA on 2026-08-27 closed most of the gap without
spending anything: the repository suite, the host readiness gate, the Azure preflight gate, and the
full 35 check validation were all run against the live environment on the shipped code, and the
pure functions were unit tested by extracting them from source. That QA found four more defects,
two of them in the fixes themselves, including an Arc stage guard that would have failed every
fresh run.

What a fresh deployment still has to prove:

- `Register-AzureLocalNodes.ps1` end to end. Its guard is unit tested but the script has not
  executed since it changed.
- `Start-SandboxSetup.ps1`. Its parameter contract against the orchestrator is verified statically
  and its helpers return values that satisfy their guarded targets, but the prompts and the image
  index picker have never been driven.
- The cold PSGallery bootstrap on a freshly promoted domain controller. The original failure was
  environmental. The code can no longer hang; worst case it stops within fifteen minutes and names
  the cause.

Nothing else in the repository is known to be untested against a real run.

## Handoff checklist

If you are picking this up after a failure:

1. Read `C:\AzureLocalSandbox\State\last-error.json` for the message, file, line, and stack trace.
2. Open the transcript it points at for the full narration of the run.
3. Compare `C:\AzureLocalSandbox\State\*.json` against [STAGE-CONTRACT.md](docs/STAGE-CONTRACT.md)
   to see which stage to resume from. Completed stages are skipped automatically.
4. Credentials are gone with the session. Ask the operator to run
   `Get-Credential -UserName 'Administrator' | Export-Clixml 'C:\AzureLocalSandbox\State\lab.cred'`,
   load it, and delete it when the run finishes.
5. Re-run `scripts/Invoke-SandboxDeployment.ps1` with the same arguments. It resumes.
