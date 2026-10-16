import importlib.util
import ipaddress as ip
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('public_ipv4',Path(__file__).resolve().parents[1]/'extra_scripts'/'public_ipv4.py')
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)

class PublicIPv4Tests(unittest.TestCase):
 def setUp(self):
  self.addresses=[{'ifname':'vmbr0','addr_info':[{'family':'inet','local':'198.51.100.194','prefixlen':27,'scope':'global'}]}]
  self.routes=[{'dst':'default','dev':'vmbr0','gateway':'198.51.100.193'}]
 def choose(self,mode,requested='',used=()):
  return helper.choose(mode,requested,self.addresses,self.routes,set(map(ip.IPv4Address,used)))
 def test_auto_uses_real_subnet_and_reserves_existing_guests(self):
  value=self.choose('auto',used=['198.51.100.195','198.51.100.196'])
  self.assertEqual(tuple(map(str,value)),('198.51.100.197','27','198.51.100.193','198.51.100.194'))
 def test_manual_rejects_host_gateway_broadcast_and_wrong_mask(self):
  for value in ['198.51.100.192/27','198.51.100.193/27','198.51.100.194/27','198.51.100.223/27','198.51.100.224/27','198.51.100.195/24']:
   with self.subTest(value=value),self.assertRaises(ValueError):self.choose('manual',value)
  with self.assertRaises(ValueError):self.choose('manual','198.51.100.195/27',used=['198.51.100.195'])
 def test_fullnat_requires_separate_host_alias(self):
  with self.assertRaises(ValueError):self.choose('fullnat','198.51.100.218')
  self.addresses[0]['addr_info'].append({'family':'inet','local':'198.51.100.218','prefixlen':27,'scope':'global'})
  self.assertEqual(self.choose('fullnat','198.51.100.218')[0],ip.IPv4Address('198.51.100.218'))
  with self.assertRaises(ValueError):self.choose('manual','198.51.100.218/27')
  with self.assertRaises(ValueError):self.choose('fullnat','198.51.100.194')
 def test_missing_or_unrelated_gateway_fails_closed(self):
  self.routes[0]['dev']='management0'
  with self.assertRaises(ValueError):self.choose('auto')
 def test_live_fullnat_rejects_reserved_alias_even_after_partial_failure(self):
  self.addresses[0]['addr_info'].append({'family':'inet','local':'198.51.100.218','prefixlen':32,'scope':'global'})
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);config=root/'node/qemu-server/210.conf';config.parent.mkdir(parents=True)
   for label in ('oneclickvirt-fullnat-ipv4','外网IP地址-ipv4','外网IPV4-ipv4'):
    with self.subTest(label=label):
     config.write_text('# '+label+' 198.51.100.218\nipconfig0: ip=172.16.1.210/24,gw=172.16.1.1\n')
     with mock.patch.object(helper,'Path',return_value=root),mock.patch.object(helper.subprocess,'check_output',side_effect=[json.dumps(self.addresses),json.dumps(self.routes)]):
      with self.assertRaises(ValueError):helper.live('fullnat','198.51.100.218')

if __name__=='__main__':unittest.main()
