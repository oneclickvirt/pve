import os,json,sys,wmi
from cloudbaseinit.osutils import factory as osutils_factory
from cloudbaseinit.utils import network



def load_json_variable(file_path,variable):
    with open(file_path) as file:
        data = json.load(file)
    return data.get(variable)

def find_drive(file_path):
    for number in range(65,91):
        drive_letter = chr(number)
        if os.path.exists(drive_letter+file_path):
            return drive_letter+file_path
    print("\n Searched file could not be found on any drive with path:" + file_path)
    return False

def get_name_by_mac(mac):
    osutils = osutils_factory.get_os_utils()
    name = osutils.get_network_adapter_name_by_mac_address(mac)
    return name

def activate_dhcp(name, family):
    osutils = osutils_factory.get_os_utils()
    osutils._fix_network_adapter_dhcp(name, True, family)


# variables
meta_data_path = find_drive(r":\OPENSTACK\LATEST\META_DATA.json")
# 2 for ipv4 and 6 for ipv6
family = 2
# execute
if meta_data_path:
    macs = load_json_variable(meta_data_path,"dhcp") or []
    
    for mac in macs:
        name = get_name_by_mac(mac)
        if name:
            activate_dhcp(name, family)
    if macs:
        sys.exit(1001)
    sys.exit(0)
else:
    sys.exit(0)
