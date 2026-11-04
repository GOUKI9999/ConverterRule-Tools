// Maintain one row per API-restricted country. Frontend-only restrictions stay eligible.
// Reviewed 2026-11-04: https://docs.polymarket.com/api-reference/geoblock
var BLOCKED = [
    ['US', /美国|美國|United[ -]*States|USA/i],
    ['SG', /新加坡|狮城|Singapore/i],
    ['TW', /台湾|台灣|Taiwan/i],
    ['GB', /英国|英國|United[ -]*Kingdom|Great[ -]*Britain/i],
    ['DE', /德国|德國|Germany/i],
    ['FR', /法国|法國|France/i],
    ['AU', /澳大利亚|澳洲|Australia/i],
    ['AR', /阿根廷|Argentina/i],
    ['BY', /白俄罗斯|Belarus/i],
    ['BE', /比利时|Belgium/i],
    ['BI', /布隆迪|Burundi/i],
    ['BR', /巴西|Brazil/i],
    ['CF', /中非|Central[ -]*African/i],
    ['CD', /刚果[（(]金[）)]|Congo[ -]*Kinshasa|Democratic[ -]*Republic[ -]*of[ -]*the[ -]*Congo|DRC/i],
    ['ET', /埃塞俄比亚|Ethiopia/i],
    ['IQ', /伊拉克|Iraq/i],
    ['IT', /意大利|Italy/i],
    ['LB', /黎巴嫩|Lebanon/i],
    ['LY', /利比亚|Libya/i],
    ['MM', /缅甸|Myanmar|Burma/i],
    ['NZ', /新西兰|New[ -]*Zealand/i],
    ['NI', /尼加拉瓜|Nicaragua/i],
    ['KP', /朝鲜|北韩|北韓|North[ -]*Korea/i],
    ['PL', /波兰|Poland/i],
    ['RU', /俄罗斯|Russia/i],
    ['SO', /索马里|Somalia/i],
    ['SK', /斯洛伐克|Slovakia/i],
    ['SS', /南苏丹|South[ -]*Sudan/i],
    ['SD', /苏丹|Sudan/i],
    ['TH', /泰国|泰國|Thailand/i],
    ['UM', /United[ -]*States[ -]*Minor[ -]*Outlying/i],
    ['VE', /委内瑞拉|Venezuela/i],
    ['YE', /也门|Yemen/i],
    ['ZW', /津巴布韦|Zimbabwe/i],
    ['IR', /伊朗|Iran/i],
    ['SY', /叙利亚|Syria/i],
    ['CU', /古巴|Cuba/i]
];
// Canada and Ukraine are partly restricted, not whole-country exclusions.
var PARTIAL = /安大略|Ontario|多伦多|Toronto|不列颠哥伦比亚|British[ -]*Columbia|温哥华|Vancouver|艾伯塔|Alberta|魁北克|Quebec|克里米亚|Crimea|顿涅茨克|Donetsk|卢甘斯克|Luhansk/i;

function countryFlag(code) {
    return String.fromCharCode(0xd83c, 0xdde6 + code.charCodeAt(0) - 65,
                               0xd83c, 0xdde6 + code.charCodeAt(1) - 65);
}

function excluded(name) {
    return PARTIAL.test(name) || BLOCKED.some(function (entry) {
        if (entry[1].test(name) || name.indexOf(countryFlag(entry[0])) >= 0) return true;
        // SS is also a protocol label. Its full country name/flag is still excluded.
        if (entry[0] === 'SS') return false;
        var code = entry[0] === 'GB' ? 'GB|UK' : entry[0];
        return new RegExp('(?:^|[^A-Za-z])(?:' + code + ')(?:[^A-Za-z]|$)', 'i').test(name);
    });
}

function priority(name) {
    if (name.indexOf('[') >= 0) return 2;
    return /香港|Hong[ -]*Kong|(?:^|[^A-Za-z])HK(?:[^A-Za-z]|$)/i.test(name) ? 0 : 1;
}

// Native subconverter contract: filter(node objects) returns newline-separated names.
function filter(nodes) {
    var names = [];
    nodes.forEach(function (node) {
        if (typeof node.Remark !== 'string' || !node.Remark) throw new Error('Missing Remark');
        if (!excluded(node.Remark) && names.indexOf(node.Remark) < 0) names.push(node.Remark);
    });
    return names.map(function (name, index) { return {name: name, index: index}; })
        .sort(function (a, b) { return priority(a.name) - priority(b.name) || a.index - b.index; })
        .map(function (item) { return item.name; }).join('\n');
}
