'use strict';
'require view';
'require fs';
'require ui';
'require poll';

function fmtBytes(n) {
	n = parseFloat(n) || 0;
	if (n >= 1099511627776) return (n / 1099511627776).toFixed(2) + ' TB';
	if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
	if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
	return Math.round(n) + ' B';
}

function fmtDate(epoch, text) {
	if (text) return text;
	if (!epoch) return '未知';
	var d = new Date(epoch * 1000);
	return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' +
		String(d.getDate()).padStart(2, '0') + ' ' +
		String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

return view.extend({
	load: function() {
		return fs.exec('/usr/sbin/subinfo', []).then(function(r) {
			try { return JSON.parse((r.stdout || '{}').trim()); }
			catch (e) { return { ok: 0, error: '解析失败: ' + e.message }; }
		}).catch(function(e) {
			return { ok: 0, error: '执行失败: ' + e.message };
		});
	},

	render: function(d) {
		var self = this;
		var container = E('div', { 'class': 'cbi-map' }, [ E('h2', {}, _('订阅套餐')) ]);
		var body = E('div', { 'class': 'cbi-section' });
		container.appendChild(body);

		function draw(data) {
			while (body.firstChild) body.removeChild(body.firstChild);

			if (!data || !data.ok) {
				body.appendChild(E('p', { 'class': 'alert-message warning' },
					_('读取失败：') + ((data && data.error) || '未知错误')));
				body.appendChild(E('p', {}, E('em', {},
					_('如果还没配置订阅地址，执行：uci set subinfo.config.url=\'https://…\' && uci commit subinfo'))));
				return;
			}

			var total = parseFloat(data.total) || 0;
			var used = parseFloat(data.used) || 0;
			var left = parseFloat(data.left) || 0;
			var pct = total > 0 ? Math.min(100, used / total * 100) : 0;
			var barColor = pct > 90 ? '#e04a4a' : (pct > 75 ? '#f0a020' : '#2fa84f');

			var rows = [];
			if (total > 0) {
				rows.push(E('p', {}, [
					E('strong', {}, _('已用：')), fmtBytes(used),
					'  /  ', E('strong', {}, _('总量：')), fmtBytes(total),
					'  （' + pct.toFixed(1) + '%）'
				]));
				rows.push(E('div', { 'style': 'height:16px;background:#e8e8e8;border-radius:4px;overflow:hidden;margin:8px 0' }, [
					E('div', { 'style': 'height:100%;width:' + pct.toFixed(1) + '%;background:' + barColor }, [])
				]));
			}
			rows.push(E('p', {}, [ E('strong', {}, _('剩余：')), fmtBytes(left) ]));
			rows.push(E('p', {}, [ E('strong', {}, _('到期：')), fmtDate(data.expire, data.expire_text) ]));
			rows.push(E('p', {}, [ E('strong', {}, _('来源：')), data.host || '—',
				data.source === 'node' ? _('（从节点名解析）') : '' ]));
			rows.push(E('p', { 'style': 'color:#888;font-size:12px' },
				_('数据刷新于 ') + new Date((data.fetched_at || 0) * 1000).toLocaleString()));

			rows.forEach(function(r) { body.appendChild(r); });

			body.appendChild(E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(self, function() {
						return fs.exec('/usr/sbin/subinfo', [ 'refresh' ]).then(function(r) {
							try { draw(JSON.parse((r.stdout || '{}').trim())); }
							catch (e) { draw({ ok: 0, error: e.message }); }
						});
					})
				}, [ _('刷新') ])
			]));
		}

		draw(d);

		poll.add(function() {
			return fs.exec('/usr/sbin/subinfo', []).then(function(r) {
				try { draw(JSON.parse((r.stdout || '{}').trim())); } catch (e) {}
			}).catch(function() {});
		}, 60);

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
