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

	/* 查询一次进度 */
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

	formatSize: function(n) {
		n = parseInt(n) || 0;
		if (n >= 1048576)
			return (n / 1048576).toFixed(1) + ' MB';
		if (n >= 1024)
			return (n / 1024).toFixed(0) + ' KB';
		return n + ' B';
	},

	/* 按钮状态控制 */
	setButtons: function(p) {
		var st = p.state || 'idle';
		var busy = (st === 'downloading' || st === 'verifying' || st === 'installing');
		var btnDl = document.getElementById('ota-btn-download');
		var btnCc = document.getElementById('ota-btn-cancel');
		var btnIn = document.getElementById('ota-btn-install');

		if (btnDl) {
			btnDl.disabled = busy;
			btnDl.textContent = (st === 'ready') ? '重新下载' : '开始下载';
		}
		if (btnCc) {
			btnCc.disabled = !(st === 'downloading' || st === 'verifying' || st === 'ready');
		}
		if (btnIn) {
			btnIn.disabled = (st !== 'ready');
		}
	},

	/* 渲染进度 */
	renderProgress: function(p) {
		var bar = document.getElementById('ota-bar');
		var txt = document.getElementById('ota-bar-text');
		var st = p.state || 'idle';
		var pct = Math.max(0, Math.min(100, parseInt(p.percent) || 0));
		var mb = function(n) { return ((n / 1048576) || 0).toFixed(1); };

		this.setButtons(p);

		if (st === 'downloading') {
			if (bar) { bar.style.width = pct + '%'; bar.style.background = '#2f7ed8'; }
			if (txt) txt.textContent = '下载中 ' + pct + '%  (' + mb(p.bytes) + ' / ' + mb(p.total) + ' MB)';
		}
		else if (st === 'verifying') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#f0a020'; }
			if (txt) txt.textContent = '下载完成，正在校验 SHA256…';
		}
		else if (st === 'ready') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#2fa84f'; }
			if (txt) txt.textContent = '版本 ' + (p.tag || '?') + ' 已就绪（' + mb(p.bytes) + ' MB，SHA256 校验通过）— 点击「刷写固件…」选择是否保留配置';
		}
		else if (st === 'installing') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#e04a4a'; }
			if (txt) txt.textContent = (p.mode === 'nokeep')
				? '正在刷写（不保留配置），设备即将重启…'
				: '正在刷写（保留配置），设备即将重启…';
		}
		else if (st === 'error') {
			if (bar) { bar.style.background = '#e04a4a'; }
			if (txt) txt.textContent = '升级失败，请查看下方输出';
		}
		else if (st === 'latest') {
			if (bar) { bar.style.width = '100%'; bar.style.background = '#888'; }
			if (txt) txt.textContent = '已是最新版本，无需升级';
		}
		else {
			if (bar) { bar.style.width = '0%'; }
			if (txt) txt.textContent = '空闲';
		}
	},

	/* 拉取日志尾部 */
	refreshLog: function() {
		var node = document.getElementById('ota-out');
		if (!node) return Promise.resolve();
		return fs.exec('/bin/cat', [ '/var/log/fw-ota-update.log' ]).then(function(r) {
			var t = (r.stdout || '').trim();
			if (t) node.textContent = t;
		}).catch(function() {});
	},

	handleCheck: function() {
		var self = this;
		var node = document.getElementById('ota-out');
		node.textContent = '检查中…';
		return fs.exec('/usr/sbin/fw-ota', [ 'check' ]).then(function(res) {
			node.textContent = (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
			return self.fetchProgress().then(function(p) { self.renderProgress(p); });
		}).catch(function(e) {
			node.textContent = '执行失败: ' + e.message;
		});
	},

	handleDownload: function() {
		var self = this;
		var node = document.getElementById('ota-out');
		node.textContent = '已启动后台下载…';
		return fs.exec('/usr/sbin/fw-ota', [ 'start' ]).then(function() {
			return self.fetchProgress().then(function(p) { self.renderProgress(p); });
		}).catch(function(e) {
			node.textContent = '启动失败: ' + e.message;
		});
	},

	handleCancel: function() {
		var self = this;
		var node = document.getElementById('ota-out');
		node.textContent = '正在取消…';
		return fs.exec('/usr/sbin/fw-ota', [ 'cancel' ]).then(function(res) {
			node.textContent = (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
			return self.fetchProgress().then(function(p) { self.renderProgress(p); });
		}).catch(function(e) {
			node.textContent = '取消失败: ' + e.message;
		});
	},

	/* 刷写确认对话框：是否刷写 + 是否保留配置 */
	handleInstall: function() {
		var self = this;
		var node = document.getElementById('ota-out');

		return this.fetchProgress().then(function(p) {
			if (p.state !== 'ready') {
				node.textContent = '固件尚未就绪，请先下载并等待校验完成。';
				return;
			}

			var keepBox = E('input', { 'type': 'checkbox', 'checked': 'checked', 'id': 'ota-keep' });
			var warn = E('p', {
				'class': 'alert-message warning',
				'style': 'display:none'
			}, [
				_('不保留配置 = 清除全部设置并恢复出厂：网络、密码、daed 订阅、证书、DDNS、Docker 配置全部丢失，刷机后需要重新配置。')
			]);

			keepBox.addEventListener('change', function() {
				warn.style.display = keepBox.checked ? 'none' : '';
			});

			var body = [
				E('p', {}, _('固件已下载并通过 SHA256 校验，下面是本次刷写的目标版本：')),
				E('ul', { 'style': 'margin:6px 0 10px 0' }, [
					E('li', {}, [ E('strong', {}, _('版本：')), p.tag || _('未知') ]),
					p.built ? E('li', {}, [ E('strong', {}, _('构建时间：')), p.built ]) : '',
					p.upstream ? E('li', {}, [ E('strong', {}, _('上游：')), p.upstream ]) : '',
					E('li', {}, [ E('strong', {}, _('大小：')), self.formatSize(p.bytes) ]),
					p.sha ? E('li', { 'style': 'word-break:break-all' }, [ E('strong', {}, 'SHA256：'), p.sha ]) : ''
				]),
				E('p', {}, E('label', { 'class': 'btn' }, [
					keepBox, ' ', _('保留配置（不勾选则清空全部设置，恢复出厂）')
				])),
				warn,
				E('p', { 'class': 'alert-message' }, [
					_('刷写期间设备会立即重启并中断网络 1–2 分钟，切勿断电。')
				]),
				E('hr'),
				E('div', { 'class': 'right' }, [
					E('a', {
						'class': 'btn',
						'href': L.env.cgi_base + '/cgi-backup',
						'target': '_blank'
					}, [ _('先下载配置备份') ]),
					' ',
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('取消') ]),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-negative important',
						'click': function() {
							var mode = keepBox.checked ? 'keep' : 'nokeep';
							ui.hideModal();
							node.textContent = (mode === 'keep')
								? '正在刷写（保留配置），设备即将重启…'
								: '正在刷写（不保留配置），设备即将重启…';
							document.getElementById('ota-bar-text').textContent = node.textContent;

							fs.exec('/usr/sbin/fw-ota', [ 'install', mode ]).then(function(res) {
								var out = (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
								node.textContent = out || '已提交刷写请求。';
								if (res.code === 6) {
									ui.addNotification(null, E('p', _('镜像自检未通过，已拒绝刷写，详见输出。')));
									return self.fetchProgress().then(function(q) { self.renderProgress(q); });
								}
								ui.awaitReconnect(window.location.host);
							}).catch(function(e) {
								node.textContent = '刷写失败: ' + e.message;
							});
						}
					}, [ _('确认刷入并重启') ])
				])
			];

			ui.showModal(_('刷写固件？'), body);
		});
	},

	render: function(res) {
		var self = this;
		var ver = (res.stdout || '').trim() || '未知';

		setTimeout(function() {
			self.fetchProgress().then(function(p) { self.renderProgress(p); });
		}, 200);

		poll.add(function() {
			return self.fetchProgress().then(function(p) {
				if (!document.getElementById('ota-bar')) return;
				self.renderProgress(p);
				if (p.state === 'installing') self.refreshLog();
			});
		}, 1);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('固件 OTA 升级')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从内网构建服务器（192.168.2.130）下载固件。流程：下载 → 校验 SHA256 → 确认刷写（可选择是否保留配置）→ 重启。')),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ E('strong', {}, _('当前版本：')), ver ]),

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
						'id': 'ota-btn-download',
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleDownload')
					}, [ _('开始下载') ]),
					' ',
					E('button', {
						'id': 'ota-btn-cancel',
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(self, 'handleCancel')
					}, [ _('取消') ]),
					' ',
					E('button', {
						'id': 'ota-btn-install',
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, 'handleInstall')
					}, [ _('刷写固件…') ])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('输出')),
				E('pre', {
					'id': 'ota-out',
					'style': 'white-space:pre-wrap;background:#f5f5f5;padding:10px;border-radius:4px;min-height:80px'
				}, [ '' ])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
