'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

return view.extend({
	load: function() {
		return fs.exec('/usr/sbin/fw-ota', [ 'version' ]).catch(function() {
			return { stdout: '', stderr: '' };
		});
	},

	/* 查询一次进度，返回解析后的对象 */
	fetchProgress: function() {
		return fs.exec('/usr/sbin/fw-ota', [ 'progress' ]).then(function(res) {
			try {
				return JSON.parse((res.stdout || '{}').trim());
			} catch (e) {
				return { state: 'idle', bytes: 0, total: 0, percent: 0, tag: '' };
			}
		}).catch(function() {
			return { state: 'idle', bytes: 0, total: 0, percent: 0, tag: '' };
		});
	},

	/* 把进度对象渲染到页面 */
	renderProgress: function(p, outNode) {
		var bar = document.getElementById('ota-bar');
		var txt = document.getElementById('ota-bar-text');
		var pct = Math.max(0, Math.min(100, parseInt(p.percent) || 0));
		var mb = function(n) { return (n / 1048576).toFixed(1); };

		if (p.state === 'downloading') {
			if (bar) { bar.style.width = pct + '%'; bar.style.background = '#2f7ed8'; }
			if (txt) {
				txt.textContent = '下载中 ' + pct + '%  (' + mb(p.bytes) + ' / ' + mb(p.total) + ' MB)';
			}
		}
		else if (p.state === 'verifying') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#f0a020'; }
			if (txt) txt.textContent = '下载完成，正在校验 SHA256…';
		}
		else if (p.state === 'installing') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#e04a4a'; }
			if (txt) txt.textContent = '正在刷写固件，设备即将重启…';
		}
		else if (p.state === 'error') {
			if (bar) { bar.style.background = '#e04a4a'; }
			if (txt) txt.textContent = '升级失败，请查看下方输出';
		}
		else {
			if (bar) { bar.style.width = '0%'; }
			if (txt) txt.textContent = '空闲';
		}

		/* 完成后把日志尾部取回 */
		if (p.state === 'idle' && outNode && outNode.dataset.running === '1') {
			outNode.dataset.running = '0';
			return fs.exec('/bin/cat', [ '/var/log/fw-ota-update.log' ]).then(function(r) {
				outNode.textContent = (r.stdout || '').trim() || '(无输出)';
			}).catch(function() {});
		}
		return Promise.resolve();
	},

	handleCheck: function() {
		var node = document.getElementById('ota-out');
		node.textContent = '检查中…';
		return fs.exec('/usr/sbin/fw-ota', [ 'check' ]).then(function(res) {
			node.textContent = (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
		}).catch(function(e) {
			node.textContent = '执行失败: ' + e.message;
		});
	},

	handleUpgrade: function() {
		var self = this;
		var node = document.getElementById('ota-out');

		return this.fetchProgress().then(function(p) {
			if (p.state === 'downloading' || p.state === 'verifying' || p.state === 'installing') {
				node.textContent = '已有升级任务在进行中…';
				return;
			}

			node.textContent = '已启动后台升级…';
			node.dataset.running = '1';

			return fs.exec('/usr/sbin/fw-ota', [ 'start' ]).then(function() {
				/* 立即刷新一次，然后交给全局 poll */
				return self.fetchProgress().then(function(p2) {
					self.renderProgress(p2, node);
				});
			});
		}).catch(function(e) {
			node.textContent = '启动失败: ' + e.message;
		});
	},

	render: function(res) {
		var self = this;
		var ver = (res.stdout || '').trim() || '未知';

		/* 页面加载时先同步一次进度 */
		setTimeout(function() {
			self.fetchProgress().then(function(p) {
				self.renderProgress(p, document.getElementById('ota-out'));
			});
		}, 200);

		/* 每秒轮询进度 */
		poll.add(function() {
			return self.fetchProgress().then(function(p) {
				var node = document.getElementById('ota-out');
				if (!node) return;
				/* 只在有任务时持续更新，避免空闲时反复请求 */
				if (p.state !== 'idle' || node.dataset.running === '1') {
					self.renderProgress(p, node);
				}
			});
		}, 1);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('固件 OTA 升级')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从 GitHub Release 检查并升级固件。升级会重启设备，请确保网络稳定。')),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ E('strong', {}, _('当前版本：')), ver ]),

				/* 进度条 */
				E('div', { 'style': 'margin:12px 0 6px 0' }, [
					E('div', {
						'style': 'height:18px;background:#e8e8e8;border-radius:4px;overflow:hidden'
					}, [
						E('div', {
							'id': 'ota-bar',
							'style': 'height:100%;width:0%;background:#2f7ed8;transition:width .3s'
						}, [])
					]),
					E('div', {
						'id': 'ota-bar-text',
						'style': 'font-size:13px;color:#666;margin-top:4px'
					}, [ _('空闲') ])
				]),

				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleCheck')
					}, [ _('检查更新') ]),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, 'handleUpgrade')
					}, [ _('立即升级并重启') ])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('输出')),
				E('pre', {
					'id': 'ota-out',
					'data-running': '0',
					'style': 'white-space:pre-wrap;background:#f5f5f5;padding:10px;border-radius:4px;min-height:80px'
				}, [ '' ])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
