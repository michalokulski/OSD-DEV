@{
    Severity = @('Warning', 'Error')

    ExcludeRules = @(
        # Interactive console tools — Write-Host is correct for colored output
        'PSAvoidUsingWriteHost'

        # Params used inside functions, PSSA can't trace across scopes
        'PSReviewUnusedParameter'

        # Established API names (Ensure-*, Refresh-*, Upgrade-*, Trigger-*)
        'PSUseApprovedVerbs'

        # Internal functions, not exported cmdlets
        'PSUseShouldProcessForStateChangingFunctions'

        # Intentional module overrides (Write-Log, Install-Package)
        'PSAvoidOverwritingBuiltInCmdlets'

        # False positive — Install-Package is our wrapper function
        'PSUseCmdletCorrectly'

        # Plural nouns are intentional API design (e.g. Test-AdminPrivileges)
        'PSUseSingularNouns'
    )
}
