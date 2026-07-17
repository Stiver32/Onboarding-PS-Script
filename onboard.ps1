try {
    $cred = Get-Credential
    $server = "ExampleDC.com"
    $disabledOU = "OU=ExampleDisabledUserOU,OU=ExampleUsersOU,OU=ExampleManagedUsersOU,DC=ExampleDC.com,DC=com"

    Write-Host "Are you onboarding (on) or offboarding (off)?" -ForegroundColor Cyan
    $operation = (Read-Host "Enter operation").ToLower()

    ###### OFFBOARDING ###########
    if ($operation -eq "off") {
        $username = Read-Host "What user is being offboarded? (enter username)"

        try {
            $adUser = Get-ADUser -Identity $username -Properties DisplayName -Server $server -Credential $cred
        }
        catch {
            Write-Host "User '$username' not found." -ForegroundColor Red
            exit
        }

        Write-Host "Found user: $($adUser.DisplayName)" -ForegroundColor Green
        $confirm = (Read-Host "Confirm offboarding this user? (Y/N)").ToUpper()
        if ($confirm -ne "Y") { Write-Host "Aborted."; exit }

        # remove from all groups
        try {
            $groups = Get-ADPrincipalGroupMembership $username -Server $server -Credential $cred |
            Where-Object { $_.Name -ne "Domain Users" }
            $groups | ForEach-Object {
                Remove-ADGroupMember -Identity $_ -Members $username -Confirm:$false -Server $server -Credential $cred
            }
            Write-Host "Removed from all groups." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to remove groups: $_" -ForegroundColor Red
        }

        #Clear phone number
        try {
            Set-ADUser -Identity $username -Clear telephoneNumber -Server $server -Credential $cred
            Write-Host "Phone number cleared." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to clear phone number: $_" -ForegroundColor Red
        }

        # Disable account
        try {
            Disable-ADAccount -Identity $username -Server $server -Credential $cred
            Write-Host "Account disabled." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to disable account: $_" -ForegroundColor Red
        }

        # Move to Disabled OU
        try {
            $dn = (Get-ADUser -Identity $username -Server $server -Credential $cred).DistinguishedName
            Move-ADObject -Identity $dn -TargetPath $disabledOU -Server $server -Credential $cred
            Write-Host "Moved to Disabled OU." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to move to Disabled OU: $_" -ForegroundColor Red
        }

        Write-Host "Offboarding complete for '$username'." -ForegroundColor Green
    }

    ###### END OFFBOARDING ###########

    ###### ONBOARDING ###########
    elseif ($operation -eq "on") {

        # FIRST NAME VALIDATION
        do {
            $firstName = Read-Host "Please enter user's first name"
            if ([string]::IsNullOrWhiteSpace($firstName)) {
                Write-Host "Invalid input" -ForegroundColor Red
                $validInput = $false
            }
            else {
                $firstName = $firstName.Substring(0, 1).ToUpper() + $firstName.Substring(1).ToLower()
                $validInput = $true
            }
        } while (-not $validInput)

        # LAST NAME VALIDATION
        do {
            $lastName = Read-Host "Please enter user's last name"
            if ([string]::IsNullOrWhiteSpace($lastName)) {
                Write-Host "Invalid input" -ForegroundColor Red
                $validInput = $false
            }
            else {
                $lastName = $lastName.Substring(0, 1).ToUpper() + $lastName.Substring(1).ToLower()
                $validInput = $true
            }
        } while (-not $validInput)

        # USERNAME GENERATION + UNIQUENESS CHECK
        $username = $firstName.ToLower() + "." + $lastName.ToLower()
        Write-Host "Generated username: $username"

        $validUsername = $false
        while (-not $validUsername) {
            $exists = $null
            try {
                $exists = Get-ADUser -Filter "SamAccountName -eq '$username'" -Server $server -Credential $cred
            }
            catch {
                Write-Host "Could not query AD: $_" -ForegroundColor Red
                exit
            }

            if ($exists) {
                Write-Host "Username '$username' already exists." -ForegroundColor Yellow
                do {
                    $username = Read-Host "Please enter a username manually"
                    if ([string]::IsNullOrWhiteSpace($username)) {
                        Write-Host "Username cannot be blank." -ForegroundColor Red
                    }
                } while ([string]::IsNullOrWhiteSpace($username))
            }
            else {
                Write-Host "Username '$username' is available." -ForegroundColor Green
                $validUsername = $true
            }
        }

        # PHONE NUMBER LOGIC
        do {
            $hasPhone = (Read-Host "Does user have a telephone number? (Y/N)").ToUpper()
            if ($hasPhone -eq "Y") {
                $telephoneNum = Read-Host "Please enter telephone number"
                $confirmation = (Read-Host "Is '$telephoneNum' correct? (Y/N)").ToUpper()
                $validInput = ($confirmation -eq "Y")
            }
            elseif ($hasPhone -eq "N") {
                Write-Host "Skipping phone step..."
                $telephoneNum = $null
                $validInput = $true
            }
            else {
                Write-Host "Please enter Y or N." -ForegroundColor Red
                $validInput = $false
            }
        } while (-not $validInput)

        # OFFICE
        do {
            $office = Read-Host "Please enter user's office location"
            if ([string]::IsNullOrWhiteSpace($office)) {
                Write-Host "Invalid input" -ForegroundColor Red
                $validInput = $false
            }
            else {
                $validInput = $true
            }
        } while (-not $validInput)

        # DEPARTMENT
        do {
            $department = Read-Host "Please enter user's department"
            if ([string]::IsNullOrWhiteSpace($department)) {
                Write-Host "Invalid input" -ForegroundColor Red
                $validInput = $false
            }
            else {
                $validInput = $true
            }
        } while (-not $validInput)

        # ROLE & GROUPS
        if (-not (Test-Path ".\roles.json")) {
            Write-Host "roles.json not found. Exiting." -ForegroundColor Red
            exit
        }

        try {
            $rolesData = Get-Content ".\roles.json" -Raw | ConvertFrom-Json
        }
        catch {
            Write-Host "roles.json could not be parsed. Check formatting." -ForegroundColor Red
            exit
        }

        do {
            $role = Read-Host "Please enter user's role"
            $selectedRole = $rolesData.PSObject.Properties |
            Where-Object { $_.Name -ieq $role } |
            Select-Object -ExpandProperty Value
            if ($null -eq $selectedRole) {
                Write-Host "Invalid role. Please try again." -ForegroundColor Red
                $validInput = $false
            }
            else {
                Write-Host "Title:       $($selectedRole.title)"
                Write-Host "Description: $($selectedRole.description)"
                Write-Host "Groups:      $($selectedRole.groups -join ', ')"
                $validInput = $true
            }
        } while (-not $validInput)


        # CREATE USER
        try {
            # SET PASSWORD
            do {
                $passwordInput = Read-Host "Enter password for '$username'" -AsSecureString
                $passwordConfirm = Read-Host "Confirm password" -AsSecureString

                # Convert both to plaintext to compare
                $p1 = [System.Net.NetworkCredential]::new('', $passwordInput).Password
                $p2 = [System.Net.NetworkCredential]::new('', $passwordConfirm).Password

                if ($p1 -ne $p2) {
                    Write-Host "Passwords do not match. Try again." -ForegroundColor Red
                    $validInput = $false
                }
                else {
                    $password = $passwordInput
                    $validInput = $true
                }
            } while (-not $validInput)

            New-ADUser `
                -Name              "$firstName $lastName" `
                -GivenName         $firstName `
                -Surname           $lastName `
                -SamAccountName    $username `
                -DisplayName       "$firstName $lastName" `
                -UserPrincipalName "$username@EXAMPLE.org/com" `
                -AccountPassword   $password `
                -Enabled           $true `
                -Company           "EXAMPLE ORGANIZATION" `
                -Department        $department `
                -Office            $office `
                -Title             $selectedRole.title `
                -Description       $selectedRole.description `
                -Path              "OU=ExampleCleanUserOU,OU=ExampleUsersOU,OU=ExampleManagedUsersOU,DC=ExampleDC,DC=com" `
                -Server            $server `
                -Credential        $cred

            Write-Host "AD account created for '$username'." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to create user: $_" -ForegroundColor Red
            exit
        }

        # SET PHONE
        if ($telephoneNum) {
            try {
                Set-ADUser -Identity $username -OfficePhone $telephoneNum -Server $server -Credential $cred
                Write-Host "Phone number set." -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to set phone number: $_" -ForegroundColor Red
            }
        }

        # ASSIGN AD GROUPS
        foreach ($group in $selectedRole.groups) {
            try {
                Add-ADGroupMember -Identity $group -Members $username -Server $server -Credential $cred
                Write-Host "AD: Added to '$group'." -ForegroundColor Green
            }
            catch {
                Write-Host "AD: Failed to add to '$group': $_" -ForegroundColor Yellow
            }
        }
        # COPY AZURE AD / EXCHANGE GROUPS FROM TEMPLATE USER
        try {
            Write-Host "Connecting to Microsoft Graph for Azure AD group assignment..." -ForegroundColor Cyan
            Connect-MgGraph -Scopes "GroupMember.ReadWrite.All", "User.Read.All", "Group.Read.All" -ErrorAction Stop

            # Get template user to copy distribution lists / M365 groups from
            $templateUpn = Read-Host "Enter UPN of an existing active user with the same role to copy groups from (e.g. john.doe@example.org/com)"
            $templateUser = Get-MgUser -Filter "userPrincipalName eq '$templateUpn'" -ErrorAction Stop

            if ($null -eq $templateUser) {
                Write-Host "Azure AD: Template user '$templateUpn' not found. Skipping Azure group assignment." -ForegroundColor Yellow
            }
            else {
                # Get template user's groups — filter to distribution lists and M365 groups only (skip AD security groups synced to AAD)
                $templateGroups = Get-MgUserMemberOf -UserId $templateUser.Id -All |
                    Where-Object {
                        $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group" -and
                        (
                            $_.AdditionalProperties["mailEnabled"] -eq $true -or
                            ($_.AdditionalProperties["groupTypes"] -contains "Unified")
                        )
                    }

                if (-not $templateGroups) {
                    Write-Host "Azure AD: No distribution lists or M365 groups found on template user." -ForegroundColor Yellow
                }
                else {
                    # Wait for new user to appear in AAD
                    $mgUser = $null
                    $retries = 0
                    while ($null -eq $mgUser -and $retries -lt 5) {
                        Start-Sleep -Seconds 3
                        $mgUser = Get-MgUser -Filter "userPrincipalName eq '$username@example.org/com'" -ErrorAction SilentlyContinue
                        $retries++
                    }

                    if ($null -eq $mgUser) {
                        Write-Host "Azure AD: New user '$username@example.org/com' not found after retries. Skipping Azure group assignment." -ForegroundColor Yellow
                    }
                    else {
                        foreach ($group in $templateGroups) {
                            $groupName = $group.AdditionalProperties["displayName"]
                            try {
                                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $mgUser.Id -ErrorAction Stop
                                Write-Host "Azure AD: Added to '$groupName'." -ForegroundColor Green
                            }
                            catch {
                                Write-Host "Azure AD: Failed to add to '$groupName': $_" -ForegroundColor Yellow
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "Azure AD group assignment failed: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "Invalid operation. Please enter 'on' or 'off'." -ForegroundColor Red
    }
}
catch {
    Write-Host "Unexpected error: $_" -ForegroundColor Red
}