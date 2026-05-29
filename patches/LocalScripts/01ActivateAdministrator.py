import os,json,sys,subprocess,configparser,platform

def find_drive(file_path):
    for number in range(65,91):
        drive_letter = chr(number)
        if os.path.exists(drive_letter+file_path):
            return drive_letter+file_path
    print("\n Searched file could not be found on any drive with path:" + file_path)
    return False

def load_json_file(file_path,variable):
    file = open(file_path)
    data = json.load(file)
    file.close()
    return data.get(variable)

def get_administrator_status():
    command = "(Get-LocalUser | Where-Object{$_.SID -like \"S-1-5-*-500\"}).Enabled"
    run = subprocess.run(["powershell", "-Command", command], stdout=subprocess.PIPE, universal_newlines=True)
    print("Is admin account enabled already: " + run.stdout)
    return run.stdout

def get_administrator_name():
    command = "(Get-LocalUser | Where-Object{$_.SID -like \"S-1-5-*-500\"}).Name"
    run = subprocess.run(["powershell", "-Command", command], stdout=subprocess.PIPE, universal_newlines=True)
    print("Administrator username: " + run.stdout)
    return run.stdout

def enable_administrator_account():
    command = "(Get-LocalUser | Where-Object{$_.SID -like \"S-1-5-*-500\"}).Name | Enable-LocalUser"
    run = subprocess.run(["powershell", "-Command", command], stdout=subprocess.PIPE, universal_newlines=True)
    print("\n Administrator account is activated by localscript")
    return run.stdout

def is_os_64bit():
    return platform.machine().endswith('64')

def get_data(variable,path):
    configParser = configparser.RawConfigParser()
    configParser.read(path)
    data = configParser.get('DEFAULT',variable)
    return data


# variables
meta_data_path = find_drive(":\OPENSTACK\LATEST\META_DATA.json")
admin_name = get_administrator_name()

# execute
if (meta_data_path) and ("admin_username" in load_json_file(meta_data_path,"meta")):
    meta_data = load_json_file(meta_data_path,"meta")
    meta_username = meta_data["admin_username"]
    print("Meta_Data admin_username is :" + meta_username)
else:
    if is_os_64bit():
        conf_path = r'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
        print("System architecture is 64 bit.")

    else:
        conf_path = r'C:\Program Files (x86)\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
        print("System architecture is 32 bit.")

    meta_username = get_data('username', conf_path)
    print("Conf username:"+meta_username)

if meta_username in admin_name and "False" in get_administrator_status():
    run = enable_administrator_account()
    sys.exit(1001)
else:
    print("Cloud-init user is not Administrateur/Administrator or Admin account is already enabled, script aborted.")
    sys.exit(0)
