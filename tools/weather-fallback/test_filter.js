const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(root, 'Subconverter/snippets/weather_filter.js'), 'utf8'), context);
const flag = code => String.fromCodePoint(...[...code].map(c => 0x1f1e6 + c.charCodeAt(0) - 65));
const select = names => context.filter(names.map(Remark => ({ Remark }))).split('\n').filter(Boolean);

assert.deepEqual(select(['Japan 01', '香港 01', '[标签]香港', 'Korea 01']), ['香港 01', 'Japan 01', 'Korea 01', '[标签]香港']);
assert.deepEqual(select(['美国', 'US01', 'SG 01', 'Germany', '香港->美国', 'Ontario', flag('FR')]), []);
assert.deepEqual(select(['[SS] 日本', 'South Sudan']), ['[SS] 日本']);
assert.deepEqual(select(['Canada', 'Ukraine', 'Congo Brazzaville', 'Congo Kinshasa']), ['Canada', 'Ukraine', 'Congo Brazzaville']);
assert.deepEqual(select(['HK 01', 'HK 01', 'Ireland', 'Netherlands', 'South Korea']), ['HK 01', 'Ireland', 'Netherlands', 'South Korea']);
for (const code of context.BLOCKED.map(item => item[0])) assert.deepEqual(select([flag(code)]), []);
assert.throws(() => context.filter([{}]), /Remark/);
const ini = fs.readFileSync(path.join(root, 'Subconverter/config/GOUKI_Local.ini'), 'utf8');
assert(!/^custom_proxy_group=(?:Polymarket|Fallback_Polymarket)`/m.test(ini));
assert(ini.includes('script:snippets/weather_filter.js'));
const selector = ini.split(/\r?\n/).find(line => line.startsWith('custom_proxy_group=Weather`'));
assert(selector.includes('[]Proxies`'));
assert(selector.includes('[]ProxiesFree`'));
assert(selector.includes('[]DIRECT'));
assert(!/^ruleset=Polymarket,/m.test(ini));
assert(fs.readFileSync(path.join(root, 'Subconverter/rules/GOUKI/Weather.list'), 'utf8').includes('DOMAIN-SUFFIX,polymarket.com'));
console.log('Weather filter and template checks passed (8 behavior cases + template invariants)');
