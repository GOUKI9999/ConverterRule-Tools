import unittest
from pathlib import Path
from policy import members, flag, group_line, BLOCKED_CODES


class PolicyTests(unittest.TestCase):
    def test_multiple_usable_regions_and_priority(self):
        names = ['[标签] 香港', '日本 01', '韩国 01', '荷兰 01', 'Ireland 01', 'HK 01', '[SS] 日本']
        selected = members(names)
        self.assertEqual(set(selected), set(names+['REJECT']))
        self.assertLess(selected.index('日本 01'), selected.index('[标签] 香港'))
        self.assertLess(selected.index('HK 01'), selected.index('日本 01'))

    def test_blocked_labels_codes_and_flags(self):
        names = ['美国01', 'SG 01', 'TW-02', 'Germany 01', '香港->美国', 'Ontario 01',
                 'United States', flag('FR')+' 01', 'UK 01', 'Russia 02']
        self.assertEqual(members(names), ['REJECT'])

    def test_no_whole_country_block_for_partial_restrictions(self):
        self.assertEqual(members(['Canada 01', 'Ukraine 02']), ['Canada 01', 'Ukraine 02', 'REJECT'])

    def test_probe_is_polymarket_api(self):
        self.assertIn('https://clob.polymarket.com/?polyclaw-health=1`', group_line())
        self.assertNotIn('/time', group_line())
        self.assertNotIn('香港`', group_line())

    def test_all_documented_country_flags_are_excluded(self):
        self.assertEqual(members([flag(code)+' node' for code in BLOCKED_CODES]), ['REJECT'])

    def test_protocol_tag_is_not_south_sudan(self):
        self.assertEqual(members(['[SS]日本', 'South Sudan']), ['[SS]日本', 'REJECT'])

    def test_congo_restriction_is_not_whole_region(self):
        self.assertEqual(members(['Congo Brazzaville', 'Congo Kinshasa']), ['Congo Brazzaville', 'REJECT'])

    def test_formal_template_matches_generator(self):
        root = Path(__file__).resolve().parents[2]
        lines = (root/'Subconverter/config/GOUKI_Local.ini').read_text(encoding='utf-8').splitlines()
        actual = [line for line in lines if line.startswith('custom_proxy_group=Fallback_Polymarket`')]
        self.assertEqual(actual, [group_line()])
        self.assertIn('ruleset=Polymarket,rules/GOUKI/Polymarket.list', lines)
        self.assertNotIn('DOMAIN-SUFFIX,polymarket.com', (root/'Subconverter/rules/GOUKI/Weather.list').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
