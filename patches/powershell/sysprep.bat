@Echo off
cd "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
C:\Windows\System32\sysprep\sysprep.exe /generalize /oobe /unattend:Unattend.xml /shutdown
