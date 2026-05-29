# Replace in conf file Administrator username and group by the system's local language

$adminname = 'username=' + (Get-WmiObject win32_useraccount | Where-Object{$_.SID -like "S-1-5-*-500"}).Name
$admingroupname = 'groups=' + (Get-WmiObject win32_group | Where-Object{$_.SID -like "S-1-5-32-544"}).Name

if ((gwmi win32_operatingsystem | select osarchitecture).osarchitecture.Contains('64'))
{
    $fileNames = Get-ChildItem "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf" -Recurse | select -expand fullname
    foreach ($filename in $filenames) { (Get-Content $fileName) -replace 'username=Administrator', $adminname | Set-Content $fileName }
    foreach ($filename in $filenames) { (Get-Content $fileName) -replace 'groups=Administrators', $admingroupname | Set-Content $fileName }
}
elseif ((gwmi win32_operatingsystem | select osarchitecture).osarchitecture.Contains('32'))
{
    $fileNames = Get-ChildItem "C:\Program Files (x86)\Cloudbase Solutions\Cloudbase-Init\conf" -Recurse | select -expand fullname
    foreach ($filename in $filenames) { (Get-Content $fileName) -replace 'username=Administrator', $adminname | Set-Content $fileName }
    foreach ($filename in $filenames) { (Get-Content $fileName) -replace 'groups=Administrators', $admingroupname | Set-Content $fileName }
}
