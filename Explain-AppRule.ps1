<#
.SYNOPSIS
    Says why a given application would be suppressed or listed, and which rule
    decided it.

.DESCRIPTION
    Offline. No credential, no network, no device - it asks the rules the same
    question the classifier asks, and shows its working.

    Built to answer "why is X not on my sheet?" in front of an audience. The
    classifier itself returns only the reason a match happened; this walks the
    same three stages in the same order and reports which one fired, what it
    matched on, and what the other stages saw.

    The order is the classifier's meaning, not a preference:

        1  Name       exact match on the normalized application name
        2  Publisher  exact match on the normalized publisher
        3  Pattern    regex against the raw application name

    First match wins. Anything unmatched is something a technician installs.

.PARAMETER Name
    One or more application names, as Absolute reports them. Accepts pipeline
    input.

.PARAMETER Publisher
    The publisher, when you want stage 2 to be meaningful. Without it, only
    stages 1 and 3 can match - which is itself worth demonstrating.

.PARAMETER Summary
    Print the shape of the rule set instead: counts by match type, by reason,
    and the cross-tab of the two.

.EXAMPLE
    .\Explain-AppRule.ps1 'Dell Digital Delivery' -Publisher 'Dell Products'

.EXAMPLE
    .\Explain-AppRule.ps1 '7-Zip 24.09 (x64)', 'Microsoft Teams', 'Bluebeam Revu 21'

.EXAMPLE
    .\Explain-AppRule.ps1 -Summary
#>
[CmdletBinding(DefaultParameterSetName = 'Explain')]
param(
    [Parameter(ParameterSetName = 'Explain', Position = 0, ValueFromPipeline)]
    [string[]]$Name,

    [Parameter(ParameterSetName = 'Explain')]
    [string]$Publisher,

    [Parameter(ParameterSetName = 'Summary')]
    [switch]$Summary,

    [string]$RulesCsv = "$PSScriptRoot\AppRules.csv",

    # One line per application instead of the full walk-through - for checking
    # a handful at once.
    [Parameter(ParameterSetName = 'Explain')]
    [switch]$Brief,

    # Return the result objects instead of printing them, so this can be
    # scripted - and so the tests can check it against the classifier itself
    # rather than against its own output.
    [Parameter(ParameterSetName = 'Explain')]
    [switch]$PassThru
)

begin {
    $module = Join-Path $PSScriptRoot 'AppFilter.psm1'
    if (-not (Test-Path $module))   { throw "Cannot find AppFilter.psm1 next to this script." }
    if (-not (Test-Path $RulesCsv)) { throw "Cannot find rules file: $RulesCsv" }

    Import-Module $module -Force -ErrorAction Stop
    $rules = Import-AppRule -Path $RulesCsv

    function Get-Explanation {
        <#
            Mirrors Get-AppClassification exactly - same three stages, same
            order, same first-match-wins - but records what every stage saw
            rather than only the winner.

            If the classifier's order ever changes, this has to change with
            it. A test asserts the two agree on their verdict.
        #>
        param([string]$AppName, [string]$AppPublisher)

        $nameKey = ConvertTo-NormalizedAppName $AppName
        $pubKey  = ConvertTo-NormalizedPublisher $AppPublisher
        $matched = ''

        $stages = New-Object System.Collections.Generic.List[object]
        $winner = $null

        # 1. Name
        if ($nameKey -and $rules.Names.TryGetValue($nameKey, [ref]$matched)) {
            $stages.Add([pscustomobject]@{ Stage='1 Name'; Hit=$true; Detail="rule '$nameKey'"; Reason=$matched })
            $winner = $stages[$stages.Count - 1]
        } else {
            $detail = "no rule for '$nameKey'"
            if (-not $nameKey) { $detail = 'no name to match on' }
            $stages.Add([pscustomobject]@{ Stage='1 Name'; Hit=$false; Detail=$detail; Reason=$null })
        }

        # 2. Publisher
        $matched = ''
        if (-not $winner -and $pubKey -and $rules.Publishers.TryGetValue($pubKey, [ref]$matched)) {
            $stages.Add([pscustomobject]@{ Stage='2 Publisher'; Hit=$true; Detail="rule '$pubKey'"; Reason=$matched })
            $winner = $stages[$stages.Count - 1]
        } elseif (-not $winner) {
            $detail = "no rule for '$pubKey'"
            if (-not $pubKey) { $detail = 'no publisher given - stage skipped' }
            $stages.Add([pscustomobject]@{ Stage='2 Publisher'; Hit=$false; Detail=$detail; Reason=$null })
        }

        # 3. Pattern
        if (-not $winner) {
            $hit = $null
            foreach ($r in $rules.Patterns) {
                if ($AppName -match $r.Pattern) { $hit = $r; break }
            }
            if ($hit) {
                $stages.Add([pscustomobject]@{ Stage='3 Pattern'; Hit=$true; Detail="pattern '$($hit.Pattern)'"; Reason=$hit.Reason })
                $winner = $stages[$stages.Count - 1]
            } else {
                $stages.Add([pscustomobject]@{ Stage='3 Pattern'; Hit=$false
                                               Detail="none of $($rules.Patterns.Count) patterns matched"; Reason=$null })
            }
        }

        # Which later stages WOULD have matched, had an earlier one not won.
        # This is the ordering doing visible work, and the thing people ask
        # about once they understand the cascade.
        $alsoWould = @()
        if ($winner) {
            $m2 = ''
            if ($winner.Stage -ne '2 Publisher' -and $pubKey -and $rules.Publishers.TryGetValue($pubKey, [ref]$m2)) {
                $alsoWould += "stage 2 would also have matched publisher '$pubKey' ($m2)"
            }
            if ($winner.Stage -ne '3 Pattern') {
                foreach ($r in $rules.Patterns) {
                    if ($AppName -match $r.Pattern) {
                        $alsoWould += "stage 3 would also have matched pattern '$($r.Pattern)' ($($r.Reason))"
                        break
                    }
                }
            }
        }

        [pscustomobject]@{
            AppName     = $AppName
            Publisher   = $AppPublisher
            NameKey     = $nameKey
            PublisherKey= $pubKey
            Stages      = $stages
            Winner      = $winner
            AlsoWould   = $alsoWould
            Reason      = $(if ($winner) { $winner.Reason } else { $null })
            Verdict     = $(if ($winner) { 'SUPPRESSED' } else { 'INSTALL' })
        }
    }

    $collected = New-Object System.Collections.Generic.List[string]
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Explain' -and $Name) {
        foreach ($n in $Name) { $collected.Add($n) }
    }
}

end {

    # ---------------------------------------------------------------- summary
    if ($Summary) {
        $rows = @(Import-Csv $RulesCsv | Where-Object { $_.Rule })
        $active = @($rows | Where-Object { -not $_.Active -or $_.Active.Trim() -match '^(yes|true|1)$' })

        Write-Host ""
        Write-Host "Rule set: $RulesCsv" -ForegroundColor Cyan
        Write-Host ("  {0} rows, {1} active" -f $rows.Count, $active.Count)
        Write-Host ""
        Write-Host "  Loaded into the classifier:" -ForegroundColor Cyan
        Write-Host ("    {0,-4} name rules       matched on the normalized application name" -f $rules.Names.Count)
        Write-Host ("    {0,-4} publisher rules  matched on the normalized publisher" -f $rules.Publishers.Count)
        Write-Host ("    {0,-4} pattern rules    regex against the raw application name" -f $rules.Patterns.Count)

        # Rows and loaded keys can differ, and the gap looks like a bug unless
        # it is named: two rules whose names normalize to the same key are one
        # key. That is the normalizer working, not a loss - the rules are a
        # set - but nobody should have to work that out from two numbers that
        # disagree.
        $nameRows = @($active | Where-Object { -not $_.MatchType -or $_.MatchType.Trim() -eq 'Name' })
        if ($nameRows.Count -ne $rules.Names.Count) {
            $byKey = @{}
            foreach ($row in $nameRows) {
                $k = ConvertTo-NormalizedAppName $row.Rule
                if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object System.Collections.Generic.List[string] }
                $byKey[$k].Add($row.Rule)
            }
            Write-Host ""
            Write-Host ("    {0} name rows collapse to {1} keys - {2} collision(s), which is the" -f
                        $nameRows.Count, $rules.Names.Count, ($nameRows.Count - $rules.Names.Count)) -ForegroundColor DarkGray
            Write-Host  "    normalizer doing its job. The rules are a set, so nothing is lost:" -ForegroundColor DarkGray
            foreach ($k in $byKey.Keys) {
                if ($byKey[$k].Count -gt 1) {
                    Write-Host ("      '{0}'" -f $k) -ForegroundColor DarkGray
                    foreach ($orig in $byKey[$k]) { Write-Host ("        <- {0}" -f $orig) -ForegroundColor DarkGray }
                }
            }
        }

        Write-Host ""
        Write-Host "  Match type x reason:" -ForegroundColor Cyan
        $active | Group-Object MatchType, Reason | Sort-Object Name | ForEach-Object {
            $parts = $_.Name -split ',\s*'
            Write-Host ("    {0,-10} x {1,-22} {2,4}" -f $parts[0], $parts[1], $_.Count)
        }
        Write-Host ""
        Write-Host "  Provenance (Source column):" -ForegroundColor Cyan
        $active | Group-Object Source | Sort-Object Count -Descending | ForEach-Object {
            $label = $_.Name
            if (-not $label) { $label = '(blank)' }
            Write-Host ("    {0,-22} {1,4}" -f $label, $_.Count)
        }
        Write-Host ""
        return
    }

    # ---------------------------------------------------------------- explain
    if ($collected.Count -eq 0) {
        Write-Host ""
        Write-Host "Give it an application name, or -Summary for the shape of the rule set." -ForegroundColor Yellow
        Write-Host "  .\Explain-AppRule.ps1 'Dell Digital Delivery' -Publisher 'Dell Products'"
        Write-Host ""
        return
    }

    $results = foreach ($n in $collected) { Get-Explanation -AppName $n -AppPublisher $Publisher }

    if ($PassThru) { return $results }

    if ($Brief) {
        $results |
            Select-Object @{ n='Application'; e={ $_.AppName } },
                          @{ n='Matched at'; e={ if ($_.Winner) { $_.Winner.Stage } else { '-' } } },
                          @{ n='Reason';     e={ if ($_.Reason) { $_.Reason } else { '-' } } },
                          @{ n='Verdict';    e={ $_.Verdict } } |
            Format-Table -AutoSize
        return
    }

    foreach ($r in $results) {
        Write-Host ""
        $head = $r.AppName
        if ($r.Publisher) { $head = "$head   (publisher: $($r.Publisher))" }
        Write-Host $head -ForegroundColor Cyan
        Write-Host ("  normalized name       {0}" -f $r.NameKey)
        if ($r.Publisher) {
            Write-Host ("  normalized publisher  {0}" -f $r.PublisherKey)
        }
        Write-Host ""

        foreach ($s in $r.Stages) {
            if ($s.Hit) {
                Write-Host ("  {0,-12}  MATCH   {1}  ->  {2}" -f $s.Stage, $s.Detail, $s.Reason) -ForegroundColor Green
            } else {
                Write-Host ("  {0,-12}  -       {1}" -f $s.Stage, $s.Detail) -ForegroundColor DarkGray
            }
        }

        foreach ($a in $r.AlsoWould) {
            Write-Host ("                        ({0}, but stage {1} won first)" -f $a, $r.Winner.Stage.Substring(0,1)) -ForegroundColor DarkGray
        }

        Write-Host ""
        if ($r.Verdict -eq 'SUPPRESSED') {
            Write-Host ("  VERDICT   suppressed - {0}" -f $r.Reason) -ForegroundColor Yellow
            Write-Host  "            not on the install sheet; listed under Suppressed applications"
        } else {
            Write-Host  "  VERDICT   INSTALL" -ForegroundColor Green
            Write-Host  "            no rule claimed it, so a technician installs it by hand"
        }
    }
    Write-Host ""
}
