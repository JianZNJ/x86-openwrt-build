'require baseclass';
'require fs';

function fmtBytes(n) {
	n = parseFloat(n) || 0;
	if (n >= 1099511627776) return (n / 1099511627776).toFixed(2) + ' TB';
	if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
	if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
	return Math.round(n) + ' B';
}

function daysLeft(epoch) {
	if (!epoch) return null;
	return Math.floor((epoch * 1000 - Date.now()) / 86400000);
}

return baseclass.extend({
	title: _('订阅套餐'),

	load: function() {
		return fs.exec('/usr/sbin/subinfo', []).then(function(r) {
			try { return JSON.parse((r.stdout || '{}').trim()); }
			catch (e) { return { ok: 0, error: '解析失败: ' + e.message }; }
		}).catch(function(e) {
			return { ok: 0, error: '执行失败: ' + e.message };
		});
	},

	render: function(d) {
		if (!d || !d.ok)
			return E('div', { 'class': 'alert-message warning' },
				_('无法读取订阅套餐信息：') + ((d && d.error) || _('未知错误')));

		var total = parseFloat(d.total) || 0;
		var used = parseFloat(d.used) || 0;
		var left = parseFloat(d.left) || 0;
		var pct = total > 0 ? Math.min(100, used / total * 100) : 0;
		var color = pct > 90 ? '#e04a4a' : (pct > 75 ? '#f0a020' : '#2fa84f');

		var usageCell = total > 0
			? E('td', { 'class': 'td' }, [
				fmtBytes(used) + ' / ' + fmtBytes(total) + ' (' + pct.toFixed(1) + '%)',
				E('div', { 'style': 'height:10px;background:#e8e8e8;border-radius:3px;overflow:hidden;margin-top:4px;max-width:420px' }, [
					E('div', { 'style': 'height:100%;width:' + pct.toFixed(1) + '%;background:' + color }, [])
				])
			])
			: E('td', { 'class': 'td' }, [ _('未知') ]);

		var dl = daysLeft(d.expire);
		var expText = d.expire_text || (d.expire ? new Date(d.expire * 1000).toLocaleDateString() : _('未知'));
		if (dl != null) expText += '（' + (dl >= 0 ? _('剩 %d 天').format(dl) : _('已过期')) + '）';

		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:30%' }, _('已用 / 总量')),
				usageCell
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, _('剩余')),
				E('td', { 'class': 'td' }, fmtBytes(left))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, _('到期')),
				E('td', { 'class': 'td' }, expText)
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, _('来源')),
				E('td', { 'class': 'td' }, (d.host || '-') +
					(d.source === 'node' ? ' · ' + _('从节点名解析') : ''))
			])
		]);
	}
});
