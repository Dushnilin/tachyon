'use strict';
'require view';

return view.extend({
	load: function() {
		var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
		var timer = controller ? setTimeout(function() { controller.abort(); }, 1500) : null;
		return fetch('/cgi-bin/tachyon-sub?panel_port=1', {
			cache: 'no-store',
			signal: controller ? controller.signal : undefined
		})
			.then(function(res) { return res && res.ok ? res.json() : null; })
			.then(function(data) {
				var p = Number(data && data.port);
				return Number.isInteger(p) && p >= 1 && p <= 65535 ? p : 1680;
			})
			.catch(function() { return 1680; })
			.finally(function() {
				if (timer) clearTimeout(timer);
			});
	},

	render: function(resolvedPort) {
		var port = Number.isInteger(resolvedPort) && resolvedPort >= 1 && resolvedPort <= 65535 ? resolvedPort : 1680;
		var basePath = '/';
		var rawHost = window.location.hostname || '192.168.1.1';
		var host = rawHost.indexOf(':') !== -1 && rawHost.charAt(0) !== '['
			? '[' + rawHost + ']'
			: rawHost;
		var targetUrl = 'http://' + host + ':' + port + basePath;
		var isRu = (document.documentElement.lang || navigator.language || '')
			.toLowerCase()
			.indexOf('ru') === 0;

		var popupOpened = false;
		try {
			var win = window.open(targetUrl, '_blank', 'noopener,noreferrer');
			if (win) {
				popupOpened = true;
			}
		} catch (e) {}

		var titleText = 'Tachyon';
		var descText = popupOpened
			? (isRu
				? 'Веб-панель Tachyon открыта в новой вкладке браузера.'
				: 'Tachyon web panel has been opened in a new browser tab.')
			: (isRu
				? 'Нажмите кнопку ниже, чтобы открыть веб-панель управления Tachyon.'
				: 'Click the button below to open the Tachyon control panel.');
		var openNewTabLabel = isRu ? 'Открыть в новой вкладке' : 'Open in new tab';
		var openHereLabel = isRu ? 'Открыть в этой вкладке' : 'Open in current tab';

		return E('div', {
			'class': 'cbi-map',
			'style': 'max-width: 640px; margin: 28px auto; padding: 24px 28px; border-radius: 12px; background: rgba(24, 24, 28, 0.92); border: 1px solid rgba(255, 255, 255, 0.10); color: #f4f4f6; box-shadow: 0 12px 32px rgba(0, 0, 0, 0.28);'
		}, [
			E('div', { 'style': 'display: flex; align-items: center; gap: 12px; margin-bottom: 12px;' }, [
				E('div', {
					'style': 'width: 36px; height: 36px; border-radius: 9px; display: flex; align-items: center; justify-content: center; background: rgba(255, 255, 255, 0.07); border: 1px solid rgba(255, 255, 255, 0.12); font-weight: 700; font-size: 16px; color: #e4e4e7;'
				}, 'T'),
				E('div', {}, [
					E('h2', { 'style': 'margin: 0; font-size: 18px; line-height: 1.3; font-weight: 600; color: #fafafa;' }, titleText),
					E('div', { 'style': 'font-size: 12px; color: #a1a1aa; font-variant-numeric: tabular-nums;' }, targetUrl)
				])
			]),
			E('p', { 'style': 'margin: 0 0 20px 0; font-size: 14px; line-height: 1.5; color: #d4d4d8;' }, descText),
			E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: 10px;' }, [
				E('a', {
					'class': 'cbi-button cbi-button-apply',
					'href': targetUrl,
					'target': '_blank',
					'rel': 'noopener noreferrer',
					'style': 'text-decoration: none; display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px; font-weight: 500;'
				}, openNewTabLabel),
				E('a', {
					'class': 'cbi-button',
					'href': targetUrl,
					'style': 'text-decoration: none; display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px;'
				}, openHereLabel)
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
