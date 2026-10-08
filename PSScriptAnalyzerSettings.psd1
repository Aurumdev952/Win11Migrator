@{
    Severity     = @('Error')
    ExcludeRules = @(
        # Passwords typed into the wizard and the pairing-code password must become SecureStrings somewhere
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        # Test fixtures name fake computers
        'PSAvoidUsingComputerNameHardcoded'
    )
}
