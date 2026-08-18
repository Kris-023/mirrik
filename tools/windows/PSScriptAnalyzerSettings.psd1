@{
    # Rules this project answers "yes, on purpose" to. Without this file every run buries
    # its findings under 30 known ones, and then nobody reads the list at all - which is
    # how a real finding gets missed.
    #
    # Run it over the installer and both benches (paths relative to the repo root):
    #   Invoke-ScriptAnalyzer -Path install.ps1 -Settings tools/windows/PSScriptAnalyzerSettings.psd1
    #
    # A note if you get parse errors from tools/windows/test-install.ps1: Windows PowerShell 5.1
    # reads a UTF-8 file without a BOM as ANSI, and that file has a few non-ASCII
    # characters in it. They are not real errors - hand the analyzer decoded text instead:
    #   Invoke-ScriptAnalyzer -ScriptDefinition (Get-Content -Raw -Encoding UTF8 <file>)
    ExcludeRules = @(
        # These are installers and test benches talking to a person at a terminal, in
        # colour. Write-Output would put that text into the pipeline, which is exactly
        # what we do not want.
        'PSAvoidUsingWriteHost',

        # -WhatIf/-Confirm belong to cmdlets in a module. install.ps1 is a script that
        # asks its own questions and has -Uninstall as its undo.
        'PSUseShouldProcessForStateChangingFunctions',

        # A plural noun rule for exported cmdlets. These functions are private helpers in
        # a single file and read better as they are.
        'PSUseSingularNouns',

        # The empty catches are deliberate and each one is commented: a graphics adapter
        # that cannot be queried, a version that cannot be read, a shortcut that will not
        # open. Every one of them carries on rather than failing the install over a
        # question nobody needs answered.
        'PSAvoidUsingEmptyCatchBlock',

        # The test driver replaces Windows-only functions with stubs, and a stub has to
        # carry the same parameters as the real thing even when it ignores them.
        'PSReviewUnusedParameter',

        # Same reason: the stubs deliberately shadow real commands, that is the whole
        # mechanism the Linux bench runs on.
        'PSAvoidOverwritingBuiltInCmdlets',

        # And again: a stub for Get-CimInstance hands back whatever shape the real one
        # would, which is not something an [OutputType] attribute would make clearer.
        'PSUseOutputTypeCorrectly'
    )
}
