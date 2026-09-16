Set-StrictMode -Version Latest

if ($null -eq ('CollectorOnPremNativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CollectorOnPremNativeMethods
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LogonUserW(
        string userName,
        string domain,
        IntPtr password,
        int logonType,
        int logonProvider,
        out SafeAccessTokenHandle token);
}
'@ -ErrorAction Stop
}

function Test-CollectorWindowsPlatform {
    [CmdletBinding()]
    param()

    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Resolve-CollectorADCredentialLogonName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$ADCredential
    )

    $credentialUserName = [string]$ADCredential.UserName
    if ([string]::IsNullOrWhiteSpace($credentialUserName)) {
        throw 'ADCredential must contain a non-empty user name.'
    }

    $separatorIndex = $credentialUserName.IndexOf('\')
    if ($separatorIndex -gt 0 -and $separatorIndex -lt ($credentialUserName.Length - 1)) {
        return [pscustomobject]@{
            userName = $credentialUserName.Substring($separatorIndex + 1)
            domain = $credentialUserName.Substring(0, $separatorIndex)
        }
    }

    # UPNs are passed as the user name with a null domain. Plain user names are
    # also passed with a null domain so callers can use the Windows default
    # account lookup behavior rather than the collector inventing a domain.
    [pscustomobject]@{
        userName = $credentialUserName
        domain = $null
    }
}

function New-CollectorADCredentialToken {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This helper only acquires an in-memory Windows access token for scoped read-only provider execution.')]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$ADCredential
    )

    if (-not (Test-CollectorWindowsPlatform)) {
        throw 'ADCredential is supported only on Windows because onprem-ad-gpo credential isolation requires Windows impersonation.'
    }

    $logonName = Resolve-CollectorADCredentialLogonName -ADCredential $ADCredential
    $passwordPointer = [IntPtr]::Zero
    $token = $null

    try {
        # LogonUserW requires a native Unicode password pointer. Marshal directly
        # from SecureString and zero/free the native buffer immediately after the
        # token request so no managed plaintext password string is created.
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($ADCredential.Password)

        # LOGON32_LOGON_NEW_CREDENTIALS (9) + LOGON32_PROVIDER_WINNT50 (3)
        # mirrors runas /netonly: local process identity is preserved while the
        # supplied credentials are used for outbound network authentication.
        $succeeded = [CollectorOnPremNativeMethods]::LogonUserW(
            [string]$logonName.userName,
            $logonName.domain,
            $passwordPointer,
            9,
            3,
            [ref]$token)

        if (-not $succeeded) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $win32Error = [ComponentModel.Win32Exception]::new($errorCode)
            throw ('Unable to establish alternate AD credential context. Win32 error {0}: {1}' -f $errorCode, $win32Error.Message)
        }

        if ($null -eq $token -or $token.IsInvalid -or $token.IsClosed) {
            throw 'Unable to establish alternate AD credential context because Windows returned an invalid access token.'
        }

        return $token
    }
    catch {
        if ($null -ne $token) {
            $token.Dispose()
        }
        throw
    }
    finally {
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer)
        }
    }
}

function Invoke-CollectorWindowsImpersonated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeAccessTokenHandle]$Token,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $output = [System.Collections.Generic.List[object]]::new()
    $scriptToInvoke = $ScriptBlock
    $action = [Action]{
        foreach ($item in @(& $scriptToInvoke)) {
            [void]$output.Add($item)
        }
    }

    [System.Security.Principal.WindowsIdentity]::RunImpersonated($Token, $action)
    return @($output.ToArray())
}

function Invoke-CollectorWithADCredential {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [System.Management.Automation.PSCredential]$ADCredential,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    if ($null -eq $ADCredential) {
        return @(& $ScriptBlock)
    }

    $token = New-CollectorADCredentialToken -ADCredential $ADCredential
    try {
        return @(Invoke-CollectorWindowsImpersonated -Token $token -ScriptBlock $ScriptBlock)
    }
    finally {
        $token.Dispose()
    }
}

Export-ModuleMember -Function 'Invoke-CollectorWithADCredential'
