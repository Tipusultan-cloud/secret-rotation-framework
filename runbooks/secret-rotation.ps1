param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$LocalUserName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$SecretName
)

$ErrorActionPreference = "Stop"
$newPassword = $null

try {

    # ============================================================
    # STEP 1 - AUTHENTICATE TO AZURE USING MANAGED IDENTITY
    # ============================================================

    Write-Output "========================================"
    Write-Output "[INFO] Secret rotation started"
    Write-Output "[INFO] VM: $VMName"
    Write-Output "[INFO] Account: $LocalUserName"
    Write-Output "========================================"

    Write-Output "[INFO] Authenticating to Azure..."

    Disable-AzContextAutosave -Scope Process | Out-Null

    $AzureContext = (Connect-AzAccount -Identity).Context

    Set-AzContext `
        -SubscriptionId $AzureContext.Subscription.Id `
        -DefaultProfile $AzureContext | Out-Null

    Write-Output "[SUCCESS] Azure authentication successful."


    # ============================================================
    # STEP 2 - VALIDATE LINUX USERNAME
    # ============================================================

    Write-Output "[INFO] Validating username..."

    if ($LocalUserName -notmatch '^[a-z_][a-z0-9_-]*[$]?$') {
        throw "Invalid Linux username: $LocalUserName"
    }

    Write-Output "[SUCCESS] Username validation successful."


    # ============================================================
    # STEP 3 - GENERATE NEW RANDOM PASSWORD
    # ============================================================

    Write-Output "[INFO] Generating new password..."

    $length = 24

    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower   = "abcdefghijkmnopqrstuvwxyz"
    $numbers = "23456789"

    # Avoid characters that can cause unnecessary shell/password
    # policy issues in this POC.
    $special = "!@#%_-"

    $allCharacters = $upper + $lower + $numbers + $special

    # Guarantee at least one character from each category.
    $characters = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $numbers[(Get-Random -Maximum $numbers.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )

    while ($characters.Count -lt $length) {

        $randomCharacter = $allCharacters[
            (Get-Random -Maximum $allCharacters.Length)
        ]

        $characters += $randomCharacter
    }

    # Shuffle the password characters.
    $newPassword = -join (
        $characters |
        Sort-Object { Get-Random }
    )

    Write-Output "[SUCCESS] New password generated successfully."

    # IMPORTANT:
    # Never print $newPassword to Automation job output.


    # ============================================================
    # STEP 4 - ENCODE PASSWORD FOR TRANSFER TO LINUX VM
    # ============================================================

    Write-Output "[INFO] Preparing password for VM operation..."

    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes(
        $newPassword
    )

    $passwordBase64 = [Convert]::ToBase64String(
        $passwordBytes
    )

    Write-Output "[SUCCESS] Password prepared."


    # ============================================================
    # STEP 5 - CREATE LINUX SCRIPT
    # ============================================================

    Write-Output "[INFO] Preparing Linux password rotation command..."

    $linuxScript = @"
set -e

USERNAME='$LocalUserName'
PASSWORD_B64='$passwordBase64'

# Verify that the local Linux user exists.

if ! id "`$USERNAME" >/dev/null 2>&1
then
    echo "ERROR: Local Linux user does not exist."
    exit 1
fi


# Decode password.

PASSWORD=`$(printf '%s' "`$PASSWORD_B64" | base64 --decode)


# Change local Linux account password.

printf '%s:%s\n' "`$USERNAME" "`$PASSWORD" | sudo chpasswd


# Remove plaintext password variable.

unset PASSWORD
unset PASSWORD_B64


echo "Local Linux account password updated successfully."

exit 0
"@

    Write-Output "[SUCCESS] Linux command prepared."


    # ============================================================
    # STEP 6 - RUN COMMAND ON AZURE LINUX VM
    # ============================================================

    Write-Output "[INFO] Updating password on Linux VM..."

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId "RunShellScript" `
        -ScriptString $linuxScript


    # ============================================================
    # STEP 7 - CHECK VM OPERATION
    # ============================================================

    if ($result.Status -ne "Succeeded") {

        throw "Linux VM password update failed."
    }

    Write-Output "[SUCCESS] Linux VM local account password updated."


    # ============================================================
    # STEP 8 - CONVERT PASSWORD FOR KEY VAULT
    # ============================================================

    Write-Output "[INFO] Preparing Key Vault secret..."

    $securePassword = ConvertTo-SecureString `
        $newPassword `
        -AsPlainText `
        -Force


    # ============================================================
    # STEP 9 - UPDATE AZURE KEY VAULT
    # ============================================================

    Write-Output "[INFO] Updating Azure Key Vault..."

    $secretResult = Set-AzKeyVaultSecret `
        -VaultName $KeyVaultName `
        -Name $SecretName `
        -SecretValue $securePassword

    if (-not $secretResult) {

        throw "Key Vault secret update failed."
    }

    Write-Output "[SUCCESS] Azure Key Vault secret updated."


    # ============================================================
    # STEP 10 - SUCCESS LOG
    # ============================================================

    Write-Output ""
    Write-Output "========================================"
    Write-Output "SECRET ROTATION SUCCESSFUL"
    Write-Output "========================================"

    Write-Output "VM:       $VMName"
    Write-Output "Account:  $LocalUserName"
    Write-Output "KeyVault: $KeyVaultName"
    Write-Output "Secret:   $SecretName"

    Write-Output "========================================"

}
catch {

    # ============================================================
    # FAILURE HANDLING
    # ============================================================

    Write-Error "[FAILED] Secret rotation failed: $($_.Exception.Message)"

    throw
}
finally {

    # ============================================================
    # CLEAN UP SENSITIVE VARIABLES
    # ============================================================

    Remove-Variable newPassword `
        -ErrorAction SilentlyContinue

    Remove-Variable passwordBase64 `
        -ErrorAction SilentlyContinue

    Remove-Variable passwordBytes `
        -ErrorAction SilentlyContinue

    Remove-Variable securePassword `
        -ErrorAction SilentlyContinue

    Remove-Variable linuxScript `
        -ErrorAction SilentlyContinue
}
