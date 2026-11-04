"""Name filtering for jurisdictions with documented API new-order restrictions."""
import re

# Mihomo probes with HEAD; /time only supports GET and returns 405 for HEAD.
# Isolate status history from older groups probing the same host with status '*'.
API_URL = 'https://clob.polymarket.com/?polyclaw-health=1'
GROUP = 'Fallback_Polymarket'
# Frontend-only restrictions (JP/KR/IE/NL/MT) deliberately do not appear here.
BLOCKED_CODES = 'AR AU BY BE BI BR CF CD ET FR DE IQ IT LB LY MM NZ NI KP PL RU SG SO SK SS SD TW TH GB US UM VE YE ZW IR SY CU'.split()
ALIASES = [
    '美国', '美國', 'United[ -]*States', 'USA', '新加坡', '狮城', 'Singapore',
    '台湾', '台灣', 'Taiwan', '英国', '英國', 'United[ -]*Kingdom', 'Great[ -]*Britain',
    '德国', '德國', 'Germany', '法国', '法國', 'France', '澳大利亚', '澳洲', 'Australia',
    '阿根廷', 'Argentina', '白俄罗斯', 'Belarus', '比利时', 'Belgium', '布隆迪', 'Burundi',
    '巴西', 'Brazil', '中非', 'Central[ -]*African', '刚果[（(]金[）)]',
    'Congo[ -]*Kinshasa', 'Democratic[ -]*Republic[ -]*of[ -]*the[ -]*Congo', 'DRC',
    '埃塞俄比亚', 'Ethiopia',
    '伊拉克', 'Iraq', '意大利', 'Italy', '黎巴嫩', 'Lebanon', '利比亚', 'Libya',
    '缅甸', 'Myanmar', 'Burma', '新西兰', 'New[ -]*Zealand', '尼加拉瓜', 'Nicaragua',
    '朝鲜', '北韩', '北韓', 'North[ -]*Korea', '波兰', 'Poland', '俄罗斯', 'Russia',
    '索马里', 'Somalia', '斯洛伐克', 'Slovakia', '南苏丹', 'South[ -]*Sudan',
    '苏丹', 'Sudan', '泰国', '泰國', 'Thailand', '委内瑞拉', 'Venezuela',
    '也门', 'Yemen', '津巴布韦', 'Zimbabwe', '伊朗', 'Iran', '叙利亚', 'Syria', '古巴', 'Cuba',
    # Canada and Ukraine are partially restricted; do not ban the whole country label.
    '安大略', 'Ontario', '多伦多', 'Toronto', '不列颠哥伦比亚', 'British[ -]*Columbia',
    '温哥华', 'Vancouver', '艾伯塔', 'Alberta', '魁北克', 'Quebec',
    '克里米亚', 'Crimea', '顿涅茨克', 'Donetsk', '卢甘斯克', 'Luhansk',
]


def flag(code):
    return ''.join(chr(0x1F1E6+ord(c)-ord('A')) for c in code)


def selectors():
    # SS is also a protocol tag, so only its full country name/flag is blocked.
    codes = [c for c in BLOCKED_CODES if c != 'SS'] + ['UK']
    denied = '(?:'+'|'.join(ALIASES+[flag(c) for c in BLOCKED_CODES]) + '|(?:^|[^A-Za-z])(?:'+'|'.join(codes)+')(?:[^A-Za-z]|$))'
    clean = '(?i)^(?!.*\\[)(?!.*'+denied+')'
    # Prefer the previously verified HK path, without making HK an eligibility rule.
    hk = '(?:香港|Hong[ -]*Kong|(?:^|[^A-Za-z])HK(?:[^A-Za-z]|$))'
    return [clean+'.*'+hk+'.*', clean+'.+', '(?i)^(?!.*'+denied+').+']


def members(names):
    selected = []
    for pattern in selectors():
        for name in names:
            if re.search(pattern, name) and name not in selected:
                selected.append(name)
    return selected+['REJECT']


def group_line():
    return 'custom_proxy_group='+GROUP+'`fallback`'+'`'.join(selectors())+'`[]REJECT`'+API_URL+'`300,5'
