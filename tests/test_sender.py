import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'proxmox-sync.sh'


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.configs = self.root / 'lxc'
        self.configs.mkdir()
        self.script = self.root / 'sender.sh'
        source = SOURCE.read_text().replace('/etc/pve/local/lxc/', str(self.configs) + '/')
        self.script.write_text(source)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        ssh = self.bin / 'ssh'
        ssh.write_text('#!/bin/sh\ncat > "$CAPTURE"\n')
        ssh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        CAPTURE=str(self.root / 'published'))

    def config(self, vmid, hostname, ip, vlan):
        (self.configs / f'{vmid}.conf').write_text(
            f'hostname: {hostname}\nnet0: name=eth0,ip={ip},tag={vlan}\n')

    def run_sender(self, *args):
        return subprocess.run(['bash', str(self.script), *args], env=self.env,
                              text=True, capture_output=True)

    def test_preview_and_complete_apply_skip_dhcp(self):
        self.config(100, 'web', '10.47.20.8/24', 20)
        self.config(101, 'dynamic', 'dhcp', 20)
        preview = self.run_sender()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn('10.47.20.8 web.servers.home.digitaltrainwreck.com', preview.stdout)
        self.assertIn('Skipping DHCP-managed CT 101', preview.stderr)
        self.assertFalse((self.root / 'published').exists())
        applied = self.run_sender('--apply')
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertEqual((self.root / 'published').read_text(),
                         '10.47.20.8 web.servers.home.digitaltrainwreck.com\n')

    def test_invalid_inventory_never_publishes_partial_records(self):
        self.config(100, 'web', '10.47.20.8/24', 20)
        self.config(101, 'bad', '10.47.30.8/24', 20)
        result = self.run_sender('--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mismatch', result.stderr)
        self.assertFalse((self.root / 'published').exists())

    def test_empty_or_dhcp_only_inventory_fails_closed(self):
        self.config(101, 'dynamic', 'dhcp', 20)
        result = self.run_sender('--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'published').exists())

    def test_unsupported_vlan_and_invalid_hostname_fail(self):
        for hostname, vlan in [('web', 99), ('Bad_Name', 20)]:
            with self.subTest(hostname=hostname, vlan=vlan):
                self.config(100, hostname, '10.47.20.8/24', vlan)
                self.assertNotEqual(self.run_sender('--apply').returncode, 0)
                self.assertFalse((self.root / 'published').exists())


if __name__ == '__main__':
    unittest.main()
